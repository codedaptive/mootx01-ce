// TemporalCausalityFold.swift
//
// Temporal causality fold — cookbook §6.4 algorithm implementation.
//
// This engine processes a sorted slice of audit entries and produces
// delta cells for the T (temporal causality) matrix. The fold is
// pure, deterministic, and off-hot-path: it is invoked by the hourly
// T-population signal (TemporalCausalitySignal in GeniusLocusKit),
// not on the capture hot path.
//
// Design note — local types vs. GeniusLocusKit types:
//
//   TemporalCausalityFold lives in SubstrateML, which cannot import
//   GeniusLocusKit (that would invert the dependency graph).
//   GeniusLocusKit types such as UnifiedAuditEntry, MatrixTemporalKey,
//   and MatrixValueCoord are therefore not directly usable here.
//
//   The fold operates on `TemporalAuditEntry` (a GeniusLocusKit-neutral
//   struct) and returns `TemporalCausalityKey` results. The caller at
//   the GeniusLocusKit boundary converts UnifiedAuditEntry→TemporalAuditEntry
//   on input and TemporalCausalityKey→MatrixTemporalKey on output.
//
//   This is the standard layering bridge: the algorithm is pure and
//   substrate-type-independent; the composition kit owns the mapping.
//
// Algorithm (cookbook §6.4):
//
//   For each new entry E (HLC > startWatermark):
//     evict from buffer entries where minuteDiff(E, older) > windowMinutes
//     for each older entry O in buffer:
//       deltaMinutes = minuteDiff(E.hlc, O.hlc)
//       bucket = lagBucket(forMinutes: deltaMinutes)
//       for each srcCoord in O.fieldCoords:
//         for each tgtCoord in E.fieldCoords:
//           emit delta[(srcCoord, tgtCoord, bucket)] += 1
//     add E to buffer
//     advance newWatermark to E.hlc
//
// Determinism: same sorted input → same delta sequence in same order.
// No clocks, no randomness.
//
// Cookbook references:
//   §6.4   Temporal causality matrix T definition, update rule
//   §6.8   Lazy multiplicative decay (applied by caller, not here)
//
// Design council 2026-06-04 decision: hourly batch cadence (3600 s),
// superseding the weekly cadence specified in cookbook §6.4.
// See DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md.

import Foundation
import SubstrateTypes

// MARK: - Input types

/// A field-value coordinate as seen by TemporalCausalityFold.
///
/// Maps to `MatrixValueCoord` in GeniusLocusKit; the caller converts
/// at the kit boundary. A stable string representation is used for
/// the value so the fold can function without importing the
/// GeniusLocusKit-defined `UnifiedAuditValue` enum.
public struct TemporalFieldCoord: Hashable, Sendable, Codable {
    /// Field identifier — same string as `UnifiedAuditEntry.fieldPath`
    /// in GeniusLocusKit.
    public let fieldPath: String
    /// Stable string representation of the after-value.
    ///
    /// Callers encode values as:
    ///   - `.bitmap(v)`  → "bitmap:\(v)"
    ///   - `.string(s)`  → "string:\(s)"
    ///   - `.integer(v)` → "integer:\(v)"
    ///   - `.bytes(b)`   → "bytes:\(b.count):\(b.prefix(4)…)"
    ///   - `.null`       → "null"
    ///
    /// Consistent with how GeniusLocusKit builds MatrixValueCoord for
    /// the O-matrix, adjusted to a flat string to avoid referencing
    /// UnifiedAuditValue here.
    public let valueRepr: String

    public init(fieldPath: String, valueRepr: String) {
        self.fieldPath = fieldPath
        self.valueRepr = valueRepr
    }
}

/// One entry presented to TemporalCausalityFold.
///
/// Maps to `UnifiedAuditEntry` in GeniusLocusKit; only the fields the
/// fold needs are carried here. The caller extracts these fields at the
/// GeniusLocusKit boundary.
///
/// `fieldCoords` carries the (field, value) coordinate set for this
/// entry — one element per contributing field. For bitmap fields the
/// caller collapses the bitmap into one coordinate whose `valueRepr`
/// is "bitmap:\(v)". For other field types the caller maps one coord
/// per field. Only `capture` and `expunge` verbs contribute coordinates
/// (all other verbs are filtered out before constructing a
/// TemporalAuditEntry); the field is not verified here.
public struct TemporalAuditEntry: Sendable {
    /// HLC of the event — used for ordering and minute-delta math.
    public let hlc: HLC
    /// Field-value coordinate set for this entry.
    ///
    /// Non-empty for capture/expunge entries; empty entries do not
    /// contribute to T (they advance the watermark if HLC > startWatermark
    /// but emit no pairs).
    public let fieldCoords: [TemporalFieldCoord]

    public init(hlc: HLC, fieldCoords: [TemporalFieldCoord]) {
        self.hlc = hlc
        self.fieldCoords = fieldCoords
    }
}

// MARK: - Output types

/// A directional lag-bucketed key for the T matrix, as produced by
/// TemporalCausalityFold.
///
/// Maps to `MatrixTemporalKey` in GeniusLocusKit; the caller converts
/// at the GeniusLocusKit boundary before writing to MatrixTier.
public struct TemporalCausalityKey: Hashable, Sendable, Codable {
    /// Earlier field-value coordinate (source in the causal pair).
    public let source: TemporalFieldCoord
    /// Later field-value coordinate (target in the causal pair).
    public let target: TemporalFieldCoord
    /// Log-spaced lag bucket in minutes: one of {1, 2, 4, 8, 16, 32, 64, 128}.
    public let lagBucket: Int

    public init(source: TemporalFieldCoord,
                target: TemporalFieldCoord,
                lagBucket: Int) {
        self.source = source
        self.target = target
        self.lagBucket = lagBucket
    }
}

// MARK: - The fold

/// Pure engine for the T-matrix temporal causality population pass.
///
/// Each call to `fold(entries:windowMinutes:startWatermark:)` processes
/// entries whose HLC > startWatermark, pairs them with earlier entries
/// within the window, and returns per-key count deltas to add to T.
///
/// The caller (GeniusLocusKit's `MatrixTier.rebuildTemporal`) is
/// responsible for:
/// - Pre-sorting entries ascending by HLC (required for determinism).
/// - Converting UnifiedAuditEntry → TemporalAuditEntry before the call.
/// - Converting TemporalCausalityKey → MatrixTemporalKey after the call.
/// - Writing the returned deltas into MatrixTier via applyTemporalEvent.
public enum TemporalCausalityFold {

    /// Log-spaced lag bucket boundaries in minutes (cookbook §6.4).
    /// Must mirror `MatrixTier.lagBuckets` exactly.
    public static let lagBuckets: [Int] = [1, 2, 4, 8, 16, 32, 64, 128]

    /// Window cap for T — pairs whose capture-time delta exceeds
    /// `windowMinutes` are excluded (cookbook §6.4: 256 minutes).
    public static let defaultWindowMinutes: Int = 256

    /// Map a minute delta to the smallest lag bucket >= deltaMinutes.
    ///
    /// Out-of-window inputs are rejected upstream by the buffer eviction
    /// inside `fold`; this function therefore operates on values in
    /// [1, windowMinutes]. The largest bucket (128) is returned for any
    /// value > 128 (which cannot happen after eviction when windowMinutes
    /// == 256, but is defensive against custom windowMinutes values).
    ///
    /// This is the canonical implementation; GeniusLocusKit's
    /// `MatrixTier.lagBucket(forMinutes:)` delegates to this so a single
    /// authoritative definition exists in SubstrateML.
    public static func lagBucket(forMinutes minutes: Int) -> Int {
        // Walk boundaries in ascending order; return the first that
        // is >= the input. The list is small (8 elements) so linear
        // scan is correct and fast.
        for b in lagBuckets {
            if minutes <= b { return b }
        }
        // Clamp: values above 128 map to 128. Only reachable when
        // callers pass a windowMinutes > 128 and a delta between
        // 128 and windowMinutes. Normal operation: unreachable because
        // the buffer eviction excludes entries > windowMinutes apart.
        return lagBuckets.last ?? 128
    }

    /// Process a sorted entry sequence and return T-matrix deltas.
    ///
    /// - Parameters:
    ///   - entries: All entries visible to this fold pass, sorted
    ///     ascending by HLC. The caller MUST pre-sort; the fold does
    ///     not re-sort. Entries whose HLC ≤ startWatermark that fall
    ///     within the preceding windowMinutes boundary are included for
    ///     pair-matching as "earlier" entries; only entries with
    ///     HLC > startWatermark are treated as "new" and generate deltas.
    ///   - windowMinutes: Maximum lag in minutes for a pair to count.
    ///     Defaults to `defaultWindowMinutes` (256).
    ///   - startWatermark: Only entries with HLC > startWatermark are
    ///     "new" for this pass. Entries at or before the watermark that
    ///     are within windowMinutes of a new entry still serve as
    ///     sources for pair-matching.
    ///
    /// - Returns: A tuple of:
    ///   - `deltas`: [(TemporalCausalityKey, Int64)] — aggregated
    ///     per-key deltas in stable emission order (source HLC ascending).
    ///     Caller adds each delta to the MatrixTier's T matrix.
    ///   - `newWatermark`: The HLC of the last new entry processed, or
    ///     `startWatermark` if no new entries were found.
    ///
    /// Determinism: same sorted input, same startWatermark, same
    /// windowMinutes → same deltas in the same order. No clocks or
    /// randomness inside this function.
    public static func fold(
        entries: [TemporalAuditEntry],
        windowMinutes: Int = defaultWindowMinutes,
        startWatermark: HLC
    ) -> (deltas: [(TemporalCausalityKey, Int64)], newWatermark: HLC) {
        // Rolling buffer of earlier entries whose HLC is within
        // windowMinutes of the current entry. Buffer is maintained in
        // ascending HLC order so the eviction check is a prefix scan.
        var buffer: [TemporalAuditEntry] = []

        // Accumulated delta map; keys are aggregated to avoid emitting
        // one tuple per pair occurrence. Stable ordering is recovered
        // after aggregation.
        var deltaMap: [TemporalCausalityKey: Int64] = [:]

        // Stable ordering key for the delta map: records insertion
        // order for each key so that equal-HLC new entries produce a
        // deterministic output sequence.
        var keyOrder: [(TemporalCausalityKey, Int)] = []
        var keyIndex: [TemporalCausalityKey: Int] = [:]
        var ordinal = 0

        var newWatermark = startWatermark

        for entry in entries {
            // Evict entries from the buffer that are too old to pair
            // with this entry. The minute delta is computed from
            // physicalTime (milliseconds since epoch).
            buffer = buffer.filter { older in
                let deltaMs = entry.hlc.physicalTime - older.hlc.physicalTime
                let deltaMin = Int(deltaMs / 60_000)
                return deltaMin <= windowMinutes
            }

            if entry.hlc > startWatermark {
                // This is a "new" entry — generate deltas against buffer.
                if !entry.fieldCoords.isEmpty {
                    for older in buffer where !older.fieldCoords.isEmpty {
                        let deltaMs = entry.hlc.physicalTime - older.hlc.physicalTime
                        // deltaMs < 0 should never occur (entries are pre-sorted),
                        // but guard defensively. A 0-ms delta rounds to 0 minutes;
                        // the pair would map to bucket 1 (smallest boundary ≥ 0)
                        // which is correct — same-HLC entries are considered
                        // "within the 1-minute bucket."
                        let deltaMin = max(1, Int(deltaMs / 60_000))
                        let bucket = lagBucket(forMinutes: deltaMin)
                        for src in older.fieldCoords {
                            for tgt in entry.fieldCoords {
                                let key = TemporalCausalityKey(
                                    source: src,
                                    target: tgt,
                                    lagBucket: bucket)
                                if let idx = keyIndex[key] {
                                    // Key already seen; aggregate.
                                    keyOrder[idx] = (key, keyOrder[idx].1)
                                } else {
                                    // First occurrence; record insertion order.
                                    keyIndex[key] = ordinal
                                    keyOrder.append((key, ordinal))
                                    ordinal += 1
                                }
                                deltaMap[key, default: 0] += 1
                            }
                        }
                    }
                }
                // Advance the watermark to this entry's HLC.
                if entry.hlc > newWatermark {
                    newWatermark = entry.hlc
                }
            }

            // Add this entry to the buffer for future pair-matching,
            // regardless of whether it was "new". Entries at or before
            // the watermark serve as sources when later new entries arrive
            // within the window.
            buffer.append(entry)
        }

        // Reconstruct deltas in stable insertion order.
        let orderedDeltas: [(TemporalCausalityKey, Int64)] = keyOrder
            .sorted { $0.1 < $1.1 }
            .compactMap { (key, _) in
                guard let count = deltaMap[key], count > 0 else { return nil }
                return (key, count)
            }

        return (deltas: orderedDeltas, newWatermark: newWatermark)
    }
}
