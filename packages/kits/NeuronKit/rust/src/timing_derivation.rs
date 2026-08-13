//! timing_derivation.rs — Rust twin of `TimingDerivation.swift`.
//!
//! C3 + A6 (benchmark reset 2026-08-13): ONE derivation from audit markers to
//! the INGEST and CYCLE timing metrics, TWO consumers — the benchmark harness
//! (via the `moot_timing_report` MCP tool) and the daily performance-health
//! duty (A7, future) — per the §6b one-derivation-two-consumers ruling.
//!
//! Inputs are the A2/A3/C3 audit markers:
//!   capture           — per-row start (the write landing)
//!   encodeComplete    — per drain unit, anchored on the unit's first drawer,
//!                       reason "session=<id> rows=<n>" (A2)
//!   dreamStart/dreamEnd — estate-anchored cycle brackets (A3)
//!   reindexComplete   — estate-anchored basis-retrain completion (C3), the
//!                       CYCLE tier-3 boundary
//!
//! Outputs (M11/M12): INGEST samples and bulk-throughput samples, and the four
//! CYCLE tiers per captured row — tier 1 lexical is 0 by construction, tier 2
//! vector == INGEST, tier 3 novel-term = first reindexComplete after the
//! capture (UNBOUNDED when no retrain has happened — the honest P1 state),
//! tier 4 dreamt = first dreamEnd after the capture.
//!
//! READ and WRITE times stay client-side stopwatches (C3).
//!
//! WATERMARK (A6): the audit log is append-only; callers page events via the
//! audit log's `iterate(after: …)` and feed them here with the previous
//! watermark; the returned watermark is the HLC physical time of the last
//! event consumed. Pure and deterministic: no clock, no I/O.
//!
//! Pairing semantics mirror the Swift engine exactly: a marker in the same
//! millisecond as the capture pairs (delta 0) — sub-millisecond encode is
//! real on an in-memory estate — and only captures strictly after the
//! watermark are measured, so a row is measured exactly once across scans.

use std::collections::HashMap;

/// One audit event reduced to the fields the derivation reads. Constructed by
/// the caller from its port's audit-event type so this engine stays free of
/// storage dependencies. Twin of Swift `TimingAuditEvent`.
#[derive(Debug, Clone)]
pub struct TimingAuditEvent {
    pub verb: String,
    /// HLC physical time, epoch milliseconds.
    pub physical_time_ms: i64,
    /// The event's row anchor (a drawer id for capture/encodeComplete; the
    /// estate uuid for the estate-anchored markers). String form — the
    /// engine only needs equality, and the ports' uuid types differ.
    pub row_id: String,
    /// The marker payload column ("session=<id> rows=<n>") — None for most
    /// mutation events.
    pub reason: Option<String>,
}

/// The derived timing samples for one scan window.
/// Twin of Swift `TimingDerivation` (see that file for per-field rationale).
#[derive(Debug, Clone, Default)]
pub struct TimingDerivation {
    /// Exact per-row INGEST ms (rows=1 units only), sorted ascending.
    pub ingest_exact_ms: Vec<i64>,
    /// Bulk-unit throughput samples: (rows, wall_ms) per unit with rows > 1.
    pub ingest_bulk: Vec<(usize, i64)>,
    /// CYCLE tier-2 (vector) per anchored row — identical to ingest_exact_ms
    /// by construction; named so reports need not re-derive (M11).
    pub cycle_vector_ms: Vec<i64>,
    /// CYCLE tier-3 (novel-term) per captured row, sorted; unbounded rows are
    /// COUNTED, not averaged in and not silently dropped (P1 honesty).
    pub cycle_novel_ms: Vec<i64>,
    pub cycle_novel_unbounded: usize,
    /// CYCLE tier-4 (dreamt) per captured row, sorted; unbounded counted.
    pub cycle_dreamt_ms: Vec<i64>,
    pub cycle_dreamt_unbounded: usize,
    /// HLC physical time of the last event consumed (A6 watermark).
    pub watermark_ms: i64,
}

/// Derives INGEST and CYCLE samples from one window of audit events.
/// `events` must be in HLC order; `since_exclusive_ms` is the previous
/// watermark and bounds only the CAPTURES measured. Twin of Swift
/// `deriveTimings(events:sinceExclusiveMs:)`.
pub fn derive_timings(events: &[TimingAuditEvent], since_exclusive_ms: i64) -> TimingDerivation {
    let mut captures: Vec<(&str, i64)> = Vec::new();
    let mut encode_markers: Vec<(&str, i64, usize)> = Vec::new();
    let mut reindex_times: Vec<i64> = Vec::new();
    let mut dream_end_times: Vec<i64> = Vec::new();
    let mut watermark = since_exclusive_ms;

    for e in events {
        watermark = watermark.max(e.physical_time_ms);
        match e.verb.as_str() {
            "capture" => {
                if e.physical_time_ms > since_exclusive_ms {
                    captures.push((e.row_id.as_str(), e.physical_time_ms));
                }
            }
            "encodeComplete" => {
                let rows = marker_rows(e.reason.as_deref()).unwrap_or(1);
                encode_markers.push((e.row_id.as_str(), e.physical_time_ms, rows));
            }
            "reindexComplete" => reindex_times.push(e.physical_time_ms),
            "dreamEnd" => dream_end_times.push(e.physical_time_ms),
            _ => {}
        }
    }

    // First capture per row wins (matches Swift's `?? existing` insert).
    let mut capture_by_row: HashMap<&str, i64> = HashMap::new();
    for (row, t) in &captures {
        capture_by_row.entry(row).or_insert(*t);
    }

    let mut ingest_exact: Vec<i64> = Vec::new();
    let mut bulk: Vec<(usize, i64)> = Vec::new();
    for (anchor, t, rows) in &encode_markers {
        let Some(&t0) = capture_by_row.get(anchor) else { continue };
        if *t < t0 {
            continue;
        }
        if *rows == 1 {
            ingest_exact.push(*t - t0);
        } else {
            bulk.push((*rows, *t - t0));
        }
    }
    ingest_exact.sort_unstable();

    reindex_times.sort_unstable();
    dream_end_times.sort_unstable();
    let mut novel: Vec<i64> = Vec::new();
    let mut novel_unbounded = 0usize;
    let mut dreamt: Vec<i64> = Vec::new();
    let mut dreamt_unbounded = 0usize;
    for (_, t) in &captures {
        match first_at_or_after(*t, &reindex_times) {
            Some(m) => novel.push(m - t),
            None => novel_unbounded += 1,
        }
        match first_at_or_after(*t, &dream_end_times) {
            Some(m) => dreamt.push(m - t),
            None => dreamt_unbounded += 1,
        }
    }
    novel.sort_unstable();
    dreamt.sort_unstable();

    TimingDerivation {
        cycle_vector_ms: ingest_exact.clone(),
        ingest_exact_ms: ingest_exact,
        ingest_bulk: bulk,
        cycle_novel_ms: novel,
        cycle_novel_unbounded: novel_unbounded,
        cycle_dreamt_ms: dreamt,
        cycle_dreamt_unbounded: dreamt_unbounded,
        watermark_ms: watermark,
    }
}

/// Parses `rows=<n>` out of a marker reason ("session=<id> rows=<n>").
/// Twin of Swift `markerRows`.
fn marker_rows(reason: Option<&str>) -> Option<usize> {
    reason?
        .split(' ')
        .find_map(|tok| tok.strip_prefix("rows=").and_then(|n| n.parse().ok()))
}

/// First element >= t in an ascending-sorted slice (binary search).
/// Twin of Swift `firstAtOrAfter`.
fn first_at_or_after(t: i64, sorted: &[i64]) -> Option<i64> {
    let idx = sorted.partition_point(|&x| x < t);
    sorted.get(idx).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(verb: &str, t: i64, row: &str, reason: Option<&str>) -> TimingAuditEvent {
        TimingAuditEvent {
            verb: verb.to_string(),
            physical_time_ms: t,
            row_id: row.to_string(),
            reason: reason.map(str::to_string),
        }
    }

    /// Single-row unit: exact INGEST sample, tier 2 == INGEST, watermark at
    /// the last event.
    #[test]
    fn single_row_unit_exact_ingest() {
        let events = vec![
            ev("capture", 1000, "r1", None),
            ev("encodeComplete", 1040, "r1", Some("session=s1 rows=1")),
        ];
        let d = derive_timings(&events, 0);
        assert_eq!(d.ingest_exact_ms, vec![40]);
        assert_eq!(d.cycle_vector_ms, vec![40]);
        assert!(d.ingest_bulk.is_empty());
        assert_eq!(d.watermark_ms, 1040);
    }

    /// Bulk unit (rows>1): a throughput sample against the ANCHOR row's
    /// capture, never an exact per-row sample (M9/M10).
    #[test]
    fn bulk_unit_is_throughput_not_exact() {
        let events = vec![
            ev("capture", 1000, "r1", None),
            ev("capture", 1001, "r2", None),
            ev("encodeComplete", 1500, "r1", Some("session=s1 rows=2")),
        ];
        let d = derive_timings(&events, 0);
        assert!(d.ingest_exact_ms.is_empty());
        assert_eq!(d.ingest_bulk, vec![(2, 500)]);
    }

    /// Tier 3/4 pair each capture with the FIRST estate marker at-or-after
    /// it; rows with none are counted unbounded (P1), never dropped.
    #[test]
    fn cycle_tiers_and_unbounded_counts() {
        let events = vec![
            ev("capture", 1000, "r1", None),
            ev("reindexComplete", 1200, "estate", Some("session=x rows=5")),
            ev("capture", 1300, "r2", None),
            ev("dreamEnd", 1400, "estate", None),
        ];
        let d = derive_timings(&events, 0);
        assert_eq!(d.cycle_novel_ms, vec![200]); // r1 → 1200
        assert_eq!(d.cycle_novel_unbounded, 1); // r2: no reindex after 1300
        assert_eq!(d.cycle_dreamt_ms, vec![100, 400]); // r2→1400, r1→1400
        assert_eq!(d.cycle_dreamt_unbounded, 0);
    }

    /// Watermark: captures at or before it are NOT re-measured, but the
    /// window's markers still advance the returned watermark — the exactly-
    /// once contract across successive scans.
    #[test]
    fn watermark_excludes_prior_captures() {
        let events = vec![
            ev("capture", 900, "r0", None), // at/before watermark: skip
            ev("capture", 1100, "r1", None),
            ev("encodeComplete", 1150, "r0", Some("session=s rows=1")),
            ev("encodeComplete", 1160, "r1", Some("session=s rows=1")),
        ];
        let d = derive_timings(&events, 1000);
        assert_eq!(d.ingest_exact_ms, vec![60]); // r1 only
        assert_eq!(d.watermark_ms, 1160);
    }

    /// Same-millisecond marker pairs with delta 0 (in-memory estates are
    /// genuinely sub-millisecond), and a missing rows= field defaults to 1.
    #[test]
    fn same_ms_pairs_and_reason_default() {
        let events = vec![
            ev("capture", 500, "r1", None),
            ev("encodeComplete", 500, "r1", None),
        ];
        let d = derive_timings(&events, 0);
        assert_eq!(d.ingest_exact_ms, vec![0]);
        assert_eq!(marker_rows(Some("session=abc rows=17")), Some(17));
        assert_eq!(marker_rows(Some("session=abc")), None);
        assert_eq!(marker_rows(None), None);
    }
}
