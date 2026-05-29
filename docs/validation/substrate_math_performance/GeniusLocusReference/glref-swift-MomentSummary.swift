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

public struct TimeRange: Sendable, Equatable {
    /// HLC lower bound, inclusive.
    public let start: HLC
    /// HLC upper bound, inclusive.
    public let end: HLC

    public init(start: HLC, end: HLC) {
        precondition(!(end < start), "TimeRange end must not precede start")
        self.start = start
        self.end = end
    }

    /// Returns true if the supplied HLC is within [start, end].
    public func contains(_ hlc: HLC) -> Bool {
        return !(hlc < start) && !(end < hlc)
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

    /// OR-reduce a sequence of fingerprints. Mirrors
    /// glref-swift-ORReduce.swift; redeclared inline for
    /// standalone readability.
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

// MARK: - Standalone fingerprint redeclaration
//
// In a wired-in package context, import Fingerprint256 from
// glref-swift-Fingerprint256.swift. Here a lightweight alias is
// declared so the file is readable as a standalone reference.

// The canonical `Fingerprint256` struct lives in
// glref-swift-Fingerprint256.swift and is imported via the
// GeniusLocusReference module. The previously redeclared
// stand-in here (originally named Fingerprint256Lite for
// standalone readability) is now removed to resolve the
// duplicate-type error at link time.


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
