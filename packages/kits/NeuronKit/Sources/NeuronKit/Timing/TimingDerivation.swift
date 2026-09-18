// TimingDerivation.swift
//
// C3 + A6 (benchmark reset 2026-08-13): ONE derivation from audit markers to
// the INGEST and CYCLE timing metrics, TWO consumers — the benchmark harness
// (via the `moot_timing_report` MCP tool) and the daily performance-health
// duty (A7, future) — per the §6b one-derivation-two-consumers ruling. Two
// implementations would eventually disagree with no way to tell which is
// right; this file is the single source.
//
// Inputs are the A2/A3/C3 audit markers:
//   capture           — per-row start (the write landing)
//   encodeComplete    — per drain unit, anchored on the unit's first drawer,
//                       reason "session=<id> rows=<n>" (A2)
//   dreamStart/dreamEnd — estate-anchored cycle brackets (A3)
//   reindexComplete   — estate-anchored basis-retrain completion (C3), the
//                       CYCLE tier-3 boundary
//
// Outputs (M11/M12): INGEST samples and bulk-throughput samples, and the four
// CYCLE tiers per captured row:
//   tier 1 lexical    — 0 by construction (the row lands at capture)
//   tier 2 vector     — encode completion for the row's unit (== INGEST)
//   tier 3 novel-term — first reindexComplete AFTER the capture (nil when no
//                       retrain has happened yet — the tier is UNBOUNDED, the
//                       honest production state finding P1 describes)
//   tier 4 dreamt     — first dreamEnd AFTER the capture
//
// READ and WRITE times stay client-side stopwatches (C3): HLC physical time
// is millisecond-grained, reads need finer, and the write ack is a client
// observation by definition.
//
// WATERMARK (A6 hard requirement): the audit log is append-only and grows
// forever; a daily full scan is O(corpus) on exactly the estates the duty
// exists to protect. Callers page events via the audit log's
// `iterate(after:…)` and feed them here with the previous watermark; the
// returned watermark is the HLC physical time of the last event consumed.
// Pure and deterministic: no clock, no I/O.

import Foundation

/// One audit event reduced to the fields the derivation reads. Constructed by
/// the caller from its port's audit-event type so this engine stays free of
/// storage dependencies.
public struct TimingAuditEvent: Sendable {
    public let verb: String
    /// HLC physical time, epoch milliseconds.
    public let physicalTimeMs: Int64
    /// The event's row anchor (a drawer id for capture/encodeComplete; the
    /// estate uuid for the estate-anchored markers).
    public let rowID: UUID
    /// The marker payload column ("session=<id> rows=<n>") — nil for most
    /// mutation events.
    public let reason: String?

    public init(verb: String, physicalTimeMs: Int64, rowID: UUID, reason: String?) {
        self.verb = verb
        self.physicalTimeMs = physicalTimeMs
        self.rowID = rowID
        self.reason = reason
    }
}

/// The derived timing samples for one scan window.
public struct TimingDerivation: Sendable {
    /// Exact per-row INGEST milliseconds: encode-complete marker time minus
    /// the anchor row's capture time, ONLY for single-row drain units
    /// (rows=1 — a production single write is its own unit, so the marker is
    /// exact; A2's design). Sorted ascending for stable percentiles.
    public let ingestExactMs: [Int64]
    /// Bulk-unit throughput samples: (rows, wallMs) per drain unit with
    /// rows > 1 — one marker per unit instead of N (M9/M10).
    public let ingestBulk: [(rows: Int, wallMs: Int64)]
    /// CYCLE tier-2 (vector within existing vocabulary) per anchored row, ms.
    /// Identical inputs to ingestExactMs by construction; kept as its own
    /// field so a report can name the tier without re-deriving (M11).
    public let cycleVectorMs: [Int64]
    /// CYCLE tier-3 (row's own novel terms) per captured row, ms — nil-free:
    /// rows with NO subsequent retrain are counted in `cycleNovelUnbounded`
    /// instead, because averaging in an open-ended wait would flatter nobody
    /// and dropping it silently would hide P1.
    public let cycleNovelMs: [Int64]
    /// Captured rows the window saw with no reindexComplete after them —
    /// tier 3 unbounded. Nonzero on any estate with no retrain cadence (P1).
    public let cycleNovelUnbounded: Int
    /// CYCLE tier-4 (dreamt) per captured row, ms; rows with no subsequent
    /// dreamEnd are counted in `cycleDreamtUnbounded`.
    public let cycleDreamtMs: [Int64]
    public let cycleDreamtUnbounded: Int
    /// HLC physical time of the last event consumed — the caller persists
    /// this and passes it as `sinceExclusiveMs` next scan (A6 watermark).
    public let watermarkMs: Int64
}

/// Derives INGEST and CYCLE samples from one window of audit events.
///
/// `events` must be the full window in HLC order (the audit log's `iterate`
/// returns HLC-ascending); `sinceExclusiveMs` is the previous watermark and
/// only bounds the CAPTURES measured — marker events earlier in the window
/// never pair with captures at or before the watermark, so a row is measured
/// exactly once across successive scans.
///
/// Boundary semantics are deliberate and simple: tier boundaries pair a
/// capture with the FIRST qualifying marker strictly after it. A marker in
/// the same millisecond as the capture pairs (delta 0) — sub-millisecond
/// encode is real on an in-memory estate.
public func deriveTimings(
    events: [TimingAuditEvent],
    sinceExclusiveMs: Int64
) -> TimingDerivation {
    var captures: [(rowID: UUID, t: Int64)] = []
    var encodeMarkers: [(anchor: UUID, t: Int64, rows: Int)] = []
    var reindexTimes: [Int64] = []
    var dreamEndTimes: [Int64] = []
    var watermark = sinceExclusiveMs

    for e in events {
        watermark = max(watermark, e.physicalTimeMs)
        switch e.verb {
        case "capture":
            if e.physicalTimeMs > sinceExclusiveMs {
                captures.append((e.rowID, e.physicalTimeMs))
            }
        case "encodeComplete":
            let rows = markerRows(e.reason) ?? 1
            encodeMarkers.append((e.rowID, e.physicalTimeMs, rows))
        case "reindexComplete":
            reindexTimes.append(e.physicalTimeMs)
        case "dreamEnd":
            dreamEndTimes.append(e.physicalTimeMs)
        default:
            continue
        }
    }

    var captureByRow: [UUID: Int64] = [:]
    for c in captures { captureByRow[c.rowID] = captureByRow[c.rowID] ?? c.t }

    var ingestExact: [Int64] = []
    var bulk: [(rows: Int, wallMs: Int64)] = []
    for m in encodeMarkers {
        guard let t0 = captureByRow[m.anchor], m.t >= t0 else { continue }
        if m.rows == 1 {
            ingestExact.append(m.t - t0)
        } else {
            bulk.append((rows: m.rows, wallMs: m.t - t0))
        }
    }
    ingestExact.sort()

    // Tier 3/4: first qualifying estate-level marker strictly-or-equal after
    // each capture. Marker lists are small (one per retrain / dream cycle);
    // a linear scan per capture over sorted lists stays cheap.
    reindexTimes.sort()
    dreamEndTimes.sort()
    var novel: [Int64] = []
    var novelUnbounded = 0
    var dreamt: [Int64] = []
    var dreamtUnbounded = 0
    for c in captures {
        if let t = firstAtOrAfter(c.t, in: reindexTimes) {
            novel.append(t - c.t)
        } else {
            novelUnbounded += 1
        }
        if let t = firstAtOrAfter(c.t, in: dreamEndTimes) {
            dreamt.append(t - c.t)
        } else {
            dreamtUnbounded += 1
        }
    }
    novel.sort()
    dreamt.sort()

    return TimingDerivation(
        ingestExactMs: ingestExact,
        ingestBulk: bulk,
        cycleVectorMs: ingestExact,
        cycleNovelMs: novel,
        cycleNovelUnbounded: novelUnbounded,
        cycleDreamtMs: dreamt,
        cycleDreamtUnbounded: dreamtUnbounded,
        watermarkMs: watermark
    )
}

/// Parses `rows=<n>` out of a marker reason ("session=<id> rows=<n>").
/// nil when the reason is absent or carries no rows field.
func markerRows(_ reason: String?) -> Int? {
    guard let reason else { return nil }
    for token in reason.split(separator: " ") where token.hasPrefix("rows=") {
        return Int(token.dropFirst("rows=".count))
    }
    return nil
}

/// First element >= t in an ascending-sorted array (binary search).
func firstAtOrAfter(_ t: Int64, in sorted: [Int64]) -> Int64? {
    var lo = 0, hi = sorted.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
    }
    return lo < sorted.count ? sorted[lo] : nil
}
