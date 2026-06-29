// MomentSummary.swift
//
// Moment-summary fingerprint per cookbook § 8.7.
//
// A "moment" is a window of time. The moment-summary fingerprint
// is the OR-reduction of the fingerprints of every row "active
// during" that window, producing a single 256-bit signature that
// captures "everything observed in the window."
//
//   moment_summary(window) =
//       or_reduce([row.fingerprint for row in active_during(window)])
//
// Empty window ⇒ all-zeros fingerprint.
//
// "Active during" admits three definitions (cookbook § 8.7),
// any subset of which the caller may select:
//
//   1. captured_during    — row.capture_time ∈ window
//   2. active_during      — row was in row-state.active at any
//                            point within window (requires audit
//                            log fold; see § 8.15)
//   3. bucket_within      — for AmbientSamples whose bucket
//                            falls within window
//
// The reference takes a predicate `(Row) -> Bool` so callers can
// compose any combination. Production code consults the bit-slice
// tensor on the relevant columns (capture_time bit-slice plus the
// state field bit-slice) for sub-millisecond scans on million-row
// estates.
//
// Used by CognitionKit § 11.15 (recall_moment_summary) and
// § 11.16 (recall_similar_moments_by_summary, which first computes
// the anchor moment-summary, then hamming-NN against the cached
// hour-summary fingerprints).
//
// Cookbook references:
//   § 8.7   Moment-summary fingerprint definition
//   § 8.5   OR-reduction (the underlying operation)
//   § 11.15 recall_moment_summary primitive
//   § 11.16 recall_similar_moments_by_summary primitive

import Foundation
import SubstrateTypes

// Phase 6.8 (decision 2026-05-28 §6.6): TimeRange moved to
// SubstrateTypes. Visible here via `import SubstrateTypes`.

/// Lightweight row companion for moment-summary and other
/// fingerprint-only operations. Mirrors Rust's `RowLite`
/// (substrate-ml/src/moment_summary.rs); 40 bytes vs the full
/// production `Row` at 180+ bytes. Used by the dreaming daemon
/// and the test harness where the OR-reduce only needs the
/// fingerprint and the active-during predicate only needs the
/// capture HLC.
public struct RowLite: Sendable, Hashable {
    public let fingerprint: Fingerprint256
    public let captureHLC: HLC

    public init(fingerprint: Fingerprint256, captureHLC: HLC) {
        self.fingerprint = fingerprint
        self.captureHLC = captureHLC
    }
}

public enum MomentSummary {

    /// Compute the moment-summary fingerprint over the rows that
    /// satisfy `activeDuring(window)`. Identical to the cookbook
    /// pseudocode except that "active during" is a caller-supplied
    /// predicate rather than a fixed semantics.
    public static func summarize(
        rows: [Row],
        window: TimeRange,
        activeDuring: (Row, TimeRange) -> Bool
    ) -> Fingerprint256 {
        let matched = rows.filter { activeDuring($0, window) }
        return orReduce(matched.map { $0.fingerprint })
    }

    /// Lightweight overload — `[RowLite]` carries only the
    /// fingerprint + capture HLC, mirroring Rust's `RowLite`
    /// (decision 2026-05-28 §6.6). Use this when the caller
    /// already has the fingerprint and capture HLC in hand and
    /// doesn't need the full production `Row`: ~4-5× faster on
    /// 100k+ row windows because the inner loop walks 40 bytes
    /// per row instead of 180+. Output is byte-identical to the
    /// `[Row]` overload because the OR-reduce only consumes
    /// `fingerprint` either way; the moment_summary conformance
    /// vector (CRC 0x6762440b) PASSes through both call paths.
    public static func summarize(
        rows: [RowLite],
        window: TimeRange,
        activeDuring: (RowLite, TimeRange) -> Bool
    ) -> Fingerprint256 {
        let matched = rows.filter { activeDuring($0, window) }
        return orReduce(matched.map { $0.fingerprint })
    }

    /// Convenience predicate: row captured within the window.
    /// Matches Rust's `MomentSummary::captured_during`.
    public static func capturedDuring(_ row: RowLite, _ window: TimeRange) -> Bool {
        return window.contains(row.captureHLC)
    }

    /// OR-reduce a sequence of fingerprints. Imports Fingerprint256
    /// from SubstrateTypes; OR reduction is implemented inline.
    public static func orReduce(_ fps: [Fingerprint256]) -> Fingerprint256 {
        var b0: UInt64 = 0, b1: UInt64 = 0, b2: UInt64 = 0, b3: UInt64 = 0
        for f in fps {
            b0 |= f.block0
            b1 |= f.block1
            b2 |= f.block2
            b3 |= f.block3
        }
        return Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }
}

// MARK: - Properties
//
//   identity:     summarize over rows whose predicate is never
//                 true returns Fingerprint256.zero.
//   monotone:     adding more rows to the input set never clears
//                 a set bit (OR is monotone-non-decreasing).
//   idempotent:   summarize(rows ++ rows, ...) == summarize(rows, ...)
//                 (OR is idempotent).
//   commutative:  permuting the input rows does not change the
//                 result (OR is commutative).
//
// MARK: - Cookbook references
//   § 8.5   OR-reduction
//   § 8.7   Moment-summary definition and predicate options
//   § 11.15 recall_moment_summary
//   § 11.16 recall_similar_moments_by_summary
