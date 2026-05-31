// BenchmarkScoring.swift
//
// The DETERMINISTIC SCORING CORE of the migration recall-fidelity
// benchmark (NEURONKIT_SPEC § 4.7), factored out of `benchmark(...)` so
// it is a pure function of its inputs — no branch handle, no estate, no
// recall I/O, no clock. This is the Swift side of NeuronKit's Rust-parity
// Bucket A: the Rust port at `NeuronKit/rust/src/benchmark_scoring.rs`
// implements the same function and both gate on shared fixtures.
//
// What stays in `benchmark(...)`: the ONLY substrate touch — calling
// `branch.recall(_:)` once per query to produce `foundPerQuery`. What
// moves here: every metric computation (recallOverlap, recallPrecision,
// MRR, notFoundInBranch, newInBranch), which depends only on the expected
// concept ids and the recalled id lists. Splitting the I/O from the math
// is exactly what makes the math portable and conformance-gateable while
// the live recall stays Swift-only (it needs the GLK branch).

import Foundation

/// Pure recall-fidelity scoring shared by the Swift `benchmark(...)` and
/// the Rust port. Identity-free: a function of the expected concept ids
/// and the per-query recalled id lists.
public enum BenchmarkScoring {

    /// The scored metrics — the `BenchmarkReport` fields that are a pure
    /// function of the recall results (everything except `branchID` and
    /// `evaluatedAt`, which the caller supplies). Mirrored field-for-field
    /// by the Rust `BenchmarkScore`.
    public struct Score: Sendable, Equatable {
        public let queryCount: Int
        public let recallOverlap: Float
        public let recallPrecision: Float
        public let meanReciprocalRank: Float
        public let notFoundInBranch: [String]
        public let newInBranch: [String]
    }

    /// Score a benchmark from its recall results.
    ///
    /// - `expectedIDs`: the origin concept ids, in corpus order. The MRR
    ///   pairing scores expected concept `i` against query `i`.
    /// - `foundPerQuery`: the recalled id lists, one per query, index-
    ///   aligned with the queries (and, on the default path, with
    ///   `expectedIDs`). Each inner list is in the branch's ranked order.
    ///
    /// Metrics (every denominator guarded; empty ⇒ 0, never a trap):
    /// - `recallOverlap`  = |expected ∩ foundUnion| / |expected ∪ foundUnion|
    /// - `recallPrecision`= |expected ∩ foundUnion| / |foundUnion|
    /// - `meanReciprocalRank` = mean over paired concepts of 1/(rank), where
    ///   rank is the 1-based first position of `expectedIDs[i]` in
    ///   `foundPerQuery[i]` (0 when absent). Only indices `i <
    ///   expectedIDs.count` are paired.
    /// - `notFoundInBranch` = expected − foundUnion (the C-13 zero-loss
    ///   signal), `newInBranch` = foundUnion − expected. Both sorted.
    ///
    /// `foundUnion` is the union across ALL queries: a concept counts as
    /// recalled if ANY query surfaced it (C-13).
    public static func score(
        expectedIDs: [String],
        foundPerQuery: [[String]]
    ) -> Score {
        let expectedSet = Set(expectedIDs)

        var foundSet = Set<String>()
        var reciprocalRanks: [Float] = []
        for index in foundPerQuery.indices {
            let ids = foundPerQuery[index]
            foundSet.formUnion(ids)

            // MRR pairing: query `index` scores expected concept `index`.
            guard index < expectedIDs.count else { continue }
            let expectedID = expectedIDs[index]
            if let position = ids.firstIndex(of: expectedID) {
                reciprocalRanks.append(1.0 / Float(position + 1))
            } else {
                reciprocalRanks.append(0.0)
            }
        }

        let notFoundInBranch = expectedSet.subtracting(foundSet).sorted()
        let newInBranch = foundSet.subtracting(expectedSet).sorted()

        let intersectionCount = expectedSet.intersection(foundSet).count
        let unionCount = expectedSet.union(foundSet).count
        let recallOverlap = unionCount == 0
            ? Float(0)
            : Float(intersectionCount) / Float(unionCount)
        let recallPrecision = foundSet.isEmpty
            ? Float(0)
            : Float(intersectionCount) / Float(foundSet.count)
        let meanReciprocalRank = reciprocalRanks.isEmpty
            ? Float(0)
            : reciprocalRanks.reduce(0, +) / Float(reciprocalRanks.count)

        return Score(
            queryCount: foundPerQuery.count,
            recallOverlap: recallOverlap,
            recallPrecision: recallPrecision,
            meanReciprocalRank: meanReciprocalRank,
            notFoundInBranch: notFoundInBranch,
            newInBranch: newInBranch)
    }
}
