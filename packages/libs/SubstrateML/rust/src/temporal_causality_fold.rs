// temporal_causality_fold.rs
//
// Temporal causality fold — cookbook §6.4 algorithm implementation.
// Rust port of TemporalCausalityFold.swift; conformance-gated against
// shared test vectors at docs/engineering/substrate_reference/
// test-harness/vectors/temporal_causality_fold.json.
//
// Design council 2026-06-04 decision: hourly batch cadence (3600 s),
// superseding the weekly cadence in cookbook §6.4.
// See hourly temporal-matrix scheduling.
//
// Types mirror the Swift port: TemporalFieldCoord, TemporalAuditEntry,
// TemporalCausalityKey, TemporalCausalityFold. The caller maps
// GeniusLocusKit UnifiedAuditEntry → TemporalAuditEntry on input and
// TemporalCausalityKey → MatrixTemporalKey on output, same as Swift.
//
// Algorithm contracts (must match Swift bit-for-bit on the canonical
// test vectors, seed 0xCAFEBABEDEADBEEF):
//
//   1. entries must be pre-sorted ascending by HLC (physicalTime,
//      logicalCount, nodeID). The fold does not re-sort.
//   2. Only entries with HLC > startWatermark are "new" and generate
//      deltas. Entries at or before startWatermark within windowMinutes
//      serve as sources for pair-matching.
//   3. lagBucket(deltaMinutes) → smallest boundary in
//      {1,2,4,8,16,32,64,128} >= deltaMinutes; clamped to 128 above.
//   4. 0-ms delta rounds to deltaMin = max(1, 0) = 1; maps to bucket 1.
//   5. deltaMap aggregates per-key; output in stable insertion order.

use std::collections::HashMap;
use substrate_types::HLC;

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

/// A field-value coordinate as seen by TemporalCausalityFold.
/// Maps to MatrixValueCoord in GeniusLocusKit (via TemporalFieldCoord
/// in the Swift port).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TemporalFieldCoord {
    /// Field identifier — same string as UnifiedAuditEntry.field_path.
    pub field_path: String,
    /// Stable string representation of the after-value. Encoding:
    ///   bitmap v  → "bitmap:{v}"
    ///   string s  → "string:{s}"
    ///   integer v → "integer:{v}"
    ///   bytes     → "bytes:{count}:..."
    ///   null      → "null"
    pub value_repr: String,
}

impl TemporalFieldCoord {
    pub fn new(field_path: impl Into<String>, value_repr: impl Into<String>) -> Self {
        TemporalFieldCoord {
            field_path: field_path.into(),
            value_repr: value_repr.into(),
        }
    }
}

/// One entry presented to TemporalCausalityFold. Maps to
/// TemporalAuditEntry in the Swift port; only capture/expunge verb
/// entries with non-empty field coords contribute to T.
#[derive(Debug, Clone)]
pub struct TemporalAuditEntry {
    /// HLC of the event — used for ordering and minute-delta math.
    pub hlc: HLC,
    /// Field-value coordinate set for this entry.
    pub field_coords: Vec<TemporalFieldCoord>,
}

impl TemporalAuditEntry {
    pub fn new(hlc: HLC, field_coords: Vec<TemporalFieldCoord>) -> Self {
        TemporalAuditEntry { hlc, field_coords }
    }
}

// ---------------------------------------------------------------------------
// Output type
// ---------------------------------------------------------------------------

/// A directional lag-bucketed key for the T matrix, as produced by
/// TemporalCausalityFold. Maps to MatrixTemporalKey in GeniusLocusKit
/// (via TemporalCausalityKey in the Swift port).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TemporalCausalityKey {
    pub source: TemporalFieldCoord,
    pub target: TemporalFieldCoord,
    /// Log-spaced lag bucket in minutes: one of {1,2,4,8,16,32,64,128}.
    pub lag_bucket: i32,
}

impl TemporalCausalityKey {
    pub fn new(source: TemporalFieldCoord, target: TemporalFieldCoord, lag_bucket: i32) -> Self {
        TemporalCausalityKey { source, target, lag_bucket }
    }
}

// ---------------------------------------------------------------------------
// The fold
// ---------------------------------------------------------------------------

/// Log-spaced lag bucket boundaries in minutes (cookbook §6.4).
/// Must mirror MatrixTier.lagBuckets and TemporalCausalityFold.lagBuckets
/// in Swift exactly.
pub const LAG_BUCKETS: [i32; 8] = [1, 2, 4, 8, 16, 32, 64, 128];

/// Window cap for T — pairs > defaultWindowMinutes apart are excluded.
pub const DEFAULT_WINDOW_MINUTES: i32 = 256;

/// Occupancy cap for the pairing buffer (cookbook §6.4, occupancy-cap
/// amendment). A new entry pairs against at most the `MAX_WINDOW_OCCUPANCY`
/// most-recent in-window sources; older in-window entries are dropped as
/// sources. This bounds the fold to O(entries × MAX_WINDOW_OCCUPANCY),
/// converting the otherwise-quadratic cost on a degenerate window (e.g. a
/// bulk historical import where tens of thousands of events fall inside one
/// 256-minute window) into a linear pass. The dropped sources are the oldest
/// in the window — the weakest temporal proximity — so the near-lag causal
/// signal the T matrix exists to capture is preserved. Must mirror Swift
/// `TemporalCausalityFold.maxWindowOccupancy` exactly for bit-identical
/// conformance. See the 512-source temporal-matrix bound.
pub const MAX_WINDOW_OCCUPANCY: usize = 512;

/// Map a minute delta to the smallest lag bucket >= deltaMinutes.
/// Mirrors Swift TemporalCausalityFold.lagBucket(forMinutes:) exactly.
pub fn lag_bucket(minutes: i32) -> i32 {
    for &b in &LAG_BUCKETS {
        if minutes <= b {
            return b;
        }
    }
    // Clamp: values above 128 map to 128. Normally unreachable after
    // the buffer eviction excludes entries > window_minutes apart.
    *LAG_BUCKETS.last().unwrap_or(&128)
}

/// Result of a fold pass.
pub struct FoldResult {
    /// Aggregated per-key deltas in stable insertion order.
    pub deltas: Vec<(TemporalCausalityKey, i64)>,
    /// HLC of the last new entry processed, or startWatermark if none.
    pub new_watermark: HLC,
}

/// Process a sorted entry sequence and return T-matrix deltas.
///
/// Mirrors Swift `TemporalCausalityFold.fold(entries:windowMinutes:startWatermark:)`
/// exactly. Same algorithm; Rust idioms only in syntax.
///
/// Preconditions (same as Swift):
/// - entries is sorted ascending by HLC.
/// - Only entries with hlc > start_watermark are "new".
/// - Entries at or before the watermark within window_minutes serve as
///   sources for pair-matching.
pub fn fold(
    entries: &[TemporalAuditEntry],
    window_minutes: i32,
    start_watermark: HLC,
) -> FoldResult {
    // Rolling buffer of earlier entries within window_minutes.
    let mut buffer: Vec<&TemporalAuditEntry> = Vec::new();

    // Aggregated delta map.
    let mut delta_map: HashMap<TemporalCausalityKey, i64> = HashMap::new();

    // Stable insertion-order tracking.
    let mut key_order: Vec<TemporalCausalityKey> = Vec::new();
    let mut key_index: HashMap<TemporalCausalityKey, usize> = HashMap::new();

    let mut new_watermark = start_watermark;

    for entry in entries {
        // Evict entries too old to pair with this entry.
        buffer.retain(|older| {
            let delta_ms = entry.hlc.physical_time - older.hlc.physical_time;
            let delta_min = (delta_ms / 60_000) as i32;
            delta_min <= window_minutes
        });

        if entry.hlc > start_watermark {
            // New entry — generate deltas against buffer.
            if !entry.field_coords.is_empty() {
                for older in &buffer {
                    if older.field_coords.is_empty() {
                        continue;
                    }
                    let delta_ms = entry.hlc.physical_time - older.hlc.physical_time;
                    // Clamp to 1 minimum (same-ms → 1-minute bucket).
                    let delta_min = std::cmp::max(1, (delta_ms / 60_000) as i32);
                    let bucket = lag_bucket(delta_min);
                    for src in &older.field_coords {
                        for tgt in &entry.field_coords {
                            let key = TemporalCausalityKey::new(
                                src.clone(),
                                tgt.clone(),
                                bucket,
                            );
                            if !key_index.contains_key(&key) {
                                let idx = key_order.len();
                                key_index.insert(key.clone(), idx);
                                key_order.push(key.clone());
                            }
                            *delta_map.entry(key).or_insert(0) += 1;
                        }
                    }
                }
            }
            if entry.hlc > new_watermark {
                new_watermark = entry.hlc;
            }
        }

        buffer.push(entry);

        // Occupancy cap: retain only the MAX_WINDOW_OCCUPANCY most-recent
        // in-window entries as pairing sources. The buffer is ascending by
        // clock, so the oldest sit at the front — drop them. This keeps the
        // per-entry eviction scan and pairing loop bounded regardless of how
        // many events share a window, and is applied identically in Swift.
        if buffer.len() > MAX_WINDOW_OCCUPANCY {
            let excess = buffer.len() - MAX_WINDOW_OCCUPANCY;
            buffer.drain(0..excess);
        }
    }

    // Reconstruct deltas in stable insertion order, filtering zero counts.
    let deltas: Vec<(TemporalCausalityKey, i64)> = key_order
        .into_iter()
        .filter_map(|key| {
            let count = delta_map.get(&key).copied().unwrap_or(0);
            if count > 0 { Some((key, count)) } else { None }
        })
        .collect();

    FoldResult {
        deltas,
        new_watermark,
    }
}

// ---------------------------------------------------------------------------
// Convenience wrapper matching the Swift enum API style
// ---------------------------------------------------------------------------

/// Namespace wrapper — mirrors the Swift `TemporalCausalityFold` enum.
pub struct TemporalCausalityFold;

impl TemporalCausalityFold {
    pub const LAG_BUCKETS: [i32; 8] = LAG_BUCKETS;
    pub const DEFAULT_WINDOW_MINUTES: i32 = DEFAULT_WINDOW_MINUTES;

    pub fn lag_bucket(minutes: i32) -> i32 {
        lag_bucket(minutes)
    }

    pub fn fold(
        entries: &[TemporalAuditEntry],
        window_minutes: i32,
        start_watermark: HLC,
    ) -> FoldResult {
        fold(entries, window_minutes, start_watermark)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn hlc(physical_ms: i64) -> HLC {
        HLC { physical_time: physical_ms, logical_count: 0, node_id: 0 }
    }

    fn coord(field: &str, value: &str) -> TemporalFieldCoord {
        TemporalFieldCoord::new(field, value)
    }

    fn entry(ms: i64, coords: Vec<TemporalFieldCoord>) -> TemporalAuditEntry {
        TemporalAuditEntry::new(hlc(ms), coords)
    }

    #[test]
    fn empty_entries_returns_no_deltas_and_unchanged_watermark() {
        let wm = hlc(1_000);
        let result = fold(&[], DEFAULT_WINDOW_MINUTES, wm);
        assert!(result.deltas.is_empty());
        assert_eq!(result.new_watermark, wm);
    }

    #[test]
    fn single_entry_produces_no_pairs() {
        let wm = HLC::ZERO;
        let entries = vec![entry(60_000, vec![coord("f", "bitmap:1")])];
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);
        assert!(result.deltas.is_empty());
        assert_eq!(result.new_watermark, hlc(60_000));
    }

    #[test]
    fn two_entries_within_window_produce_one_pair() {
        let wm = HLC::ZERO;
        // 0 ms and 60_000 ms (1 minute apart) — within 256-minute window.
        let entries = vec![
            entry(0, vec![coord("f", "bitmap:1")]),
            entry(60_000, vec![coord("g", "bitmap:2")]),
        ];
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);
        assert_eq!(result.deltas.len(), 1);
        let (key, count) = &result.deltas[0];
        assert_eq!(key.source, coord("f", "bitmap:1"));
        assert_eq!(key.target, coord("g", "bitmap:2"));
        assert_eq!(key.lag_bucket, 1); // 1 minute → bucket 1
        assert_eq!(*count, 1);
        assert_eq!(result.new_watermark, hlc(60_000));
    }

    #[test]
    fn two_entries_outside_window_produce_no_pairs() {
        let wm = HLC::ZERO;
        // 0 ms and (256+1) minutes = 15_360_000+60_000 ms — outside window.
        let outside_ms = (DEFAULT_WINDOW_MINUTES as i64 + 1) * 60_000;
        let entries = vec![
            entry(0, vec![coord("f", "bitmap:1")]),
            entry(outside_ms, vec![coord("g", "bitmap:2")]),
        ];
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);
        assert!(result.deltas.is_empty());
        assert_eq!(result.new_watermark, hlc(outside_ms));
    }

    #[test]
    fn watermark_respected_no_double_counting() {
        // Entry at t=0 is before watermark; entry at t=60_000 is new.
        // Pair should still be generated (t=0 serves as source).
        let wm = hlc(30_000); // watermark between the two entries
        let entries = vec![
            entry(0, vec![coord("f", "bitmap:1")]),     // ≤ watermark → source only
            entry(60_000, vec![coord("g", "bitmap:2")]), // > watermark → new
        ];
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);
        assert_eq!(result.deltas.len(), 1);
        assert_eq!(result.new_watermark, hlc(60_000));
    }

    #[test]
    fn lag_bucket_boundaries_are_correct() {
        assert_eq!(lag_bucket(1), 1);
        assert_eq!(lag_bucket(2), 2);
        assert_eq!(lag_bucket(3), 4);
        assert_eq!(lag_bucket(4), 4);
        assert_eq!(lag_bucket(5), 8);
        assert_eq!(lag_bucket(8), 8);
        assert_eq!(lag_bucket(9), 16);
        assert_eq!(lag_bucket(16), 16);
        assert_eq!(lag_bucket(17), 32);
        assert_eq!(lag_bucket(32), 32);
        assert_eq!(lag_bucket(33), 64);
        assert_eq!(lag_bucket(64), 64);
        assert_eq!(lag_bucket(65), 128);
        assert_eq!(lag_bucket(128), 128);
        assert_eq!(lag_bucket(200), 128); // above 128 → clamp to 128
    }

    #[test]
    fn occupancy_cap_bounds_sources_to_max() {
        // 514 entries, each 1 second apart (all inside the 256-minute window),
        // each carrying one distinct source coord "s"="{i}". The last entry
        // (index 513) must pair against only the MAX_WINDOW_OCCUPANCY (512)
        // most-recent in-window sources — indices 1..=512 — because the cap
        // drops the oldest as the buffer fills. Source 0 is dropped; source 1
        // and source 512 survive. This bounds the fold to O(entries × cap) on a
        // degenerate window and must be byte-identical to the Swift port.
        let wm = HLC::ZERO;
        let n = MAX_WINDOW_OCCUPANCY + 2; // 514
        let entries: Vec<TemporalAuditEntry> = (0..n)
            .map(|i| entry((i as i64) * 1000, vec![coord("s", &format!("{i}"))]))
            .collect();
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);

        // Collect the distinct source value_reprs that paired with the last
        // target (index 513).
        let last_target = format!("{}", n - 1);
        let sources_for_last: std::collections::HashSet<String> = result
            .deltas
            .iter()
            .filter(|(k, _)| k.target.value_repr == last_target)
            .map(|(k, _)| k.source.value_repr.clone())
            .collect();

        assert_eq!(
            sources_for_last.len(),
            MAX_WINDOW_OCCUPANCY,
            "last target must pair against exactly the cap-many most-recent sources"
        );
        assert!(
            !sources_for_last.contains("0"),
            "oldest source (0) must be dropped by the occupancy cap"
        );
        assert!(
            sources_for_last.contains("1"),
            "source 1 is the oldest surviving source"
        );
        assert!(
            sources_for_last.contains(&format!("{}", MAX_WINDOW_OCCUPANCY)),
            "source 512 (most-recent before target) must survive"
        );
    }

    #[test]
    fn bucket_at_exactly_128_minutes() {
        let wm = HLC::ZERO;
        let ms_128 = 128i64 * 60_000;
        let entries = vec![
            entry(0, vec![coord("f", "bitmap:1")]),
            entry(ms_128, vec![coord("g", "bitmap:2")]),
        ];
        let result = fold(&entries, DEFAULT_WINDOW_MINUTES, wm);
        assert_eq!(result.deltas.len(), 1);
        assert_eq!(result.deltas[0].0.lag_bucket, 128);
    }
}
