// BenchmarkAlgorithm.swift
//
// The migration recall-fidelity benchmark (NEURONKIT_SPEC § 4.7) and
// its report type. The benchmark scores how faithfully a COW branch
// recalls the concepts of an external origin corpus. Its defining
// invariant is C-13: `notFoundInBranch` is the zero-tolerance
// migration-loss signal — any non-empty value disqualifies the branch
// from tournament ranking downstream.

import Foundation
import GeniusLocusKit
import LocusKit

/// Recall-fidelity report for a branch measured against an external
/// origin corpus (spec § 4.7). `notFoundInBranch` is the zero-tolerance
/// migration-loss signal (conformance C-13): any non-empty value means
/// the migration silently dropped at least one concept, and the branch
/// is disqualified from tournament ranking downstream.
public struct BenchmarkReport: Sendable, Equatable {
    /// The branch this report scores.
    public let branchID: BranchID
    /// Number of queries evaluated (one per corpus entry unless the
    /// caller supplied an explicit `queries` override).
    public let queryCount: Int
    /// Jaccard overlap of expected vs found ID sets:
    /// `|found ∩ expected| / |found ∪ expected|`. By convention 0 when
    /// both sets are empty (no concepts to recall, nothing recalled).
    public let recallOverlap: Float
    /// `|found ∩ expected| / |found|` — precision of branch recall.
    /// By convention 0 when nothing was recalled (empty `found`).
    public let recallPrecision: Float
    /// Mean of `1/rank` over each corpus concept, where `rank` is the
    /// 1-based position of the concept's ID in its own query's results
    /// (0 when the concept is not located). 0 when there are no
    /// concept↔query pairings to score.
    public let meanReciprocalRank: Float
    /// Concept IDs present in the origin corpus but absent from branch
    /// recall. MUST be empty for a conforming migration (C-13). Sorted
    /// for deterministic output.
    public let notFoundInBranch: [String]
    /// Concept IDs found in the branch recall but not present in the
    /// origin corpus. Sorted for deterministic output.
    public let newInBranch: [String]
    /// Caller-supplied evaluation timestamp (never `Date()` — the fleet
    /// determinism rule; the algorithm takes `now` as a parameter).
    public let evaluatedAt: Date

    public init(
        branchID: BranchID,
        queryCount: Int,
        recallOverlap: Float,
        recallPrecision: Float,
        meanReciprocalRank: Float,
        notFoundInBranch: [String],
        newInBranch: [String],
        evaluatedAt: Date
    ) {
        self.branchID = branchID
        self.queryCount = queryCount
        self.recallOverlap = recallOverlap
        self.recallPrecision = recallPrecision
        self.meanReciprocalRank = meanReciprocalRank
        self.notFoundInBranch = notFoundInBranch
        self.newInBranch = newInBranch
        self.evaluatedAt = evaluatedAt
    }
}

public extension NeuronKit {

    /// Score a branch's recall fidelity against an external corpus
    /// (spec § 4.7).
    ///
    /// For each query (defaulting to `origin.asRecallFrames()` when
    /// `queries` is empty), recall from `branch` and compare the returned
    /// `Drawer.id` set against the corpus's expected IDs.
    ///
    /// Concept↔query pairing for MRR: frame `i` is paired with
    /// `origin.entries[i].id`. `asRecallFrames()` is 1:1 with `entries`,
    /// so the default path is always aligned. When the caller supplies
    /// `queries`, those frames are paired with `entries` by index up to
    /// the shorter of the two counts — so a caller-supplied override
    /// should stay index-aligned with `origin.entries` for MRR to mean
    /// what it says. The set-based metrics (overlap, precision,
    /// not-found, new-in-branch) do not depend on this pairing: they use
    /// the union of all recalled IDs against the full expected set.
    ///
    /// READ-ONLY: this function calls ONLY `branch.recall(_:)`. It issues
    /// no estate write verbs (no capture/mutate/propose) — the C-13
    /// corollary. The branch it measures is never perturbed.
    ///
    /// - Parameters:
    ///   - branch: the branch to score.
    ///   - origin: the external reference corpus.
    ///   - queries: optional explicit query override; when empty,
    ///     `origin.asRecallFrames()` is used.
    ///   - now: evaluation instant, recorded in the report. Supplied so
    ///     the benchmark is deterministic and testable.
    static func benchmark(
        branch: any BranchHandle,
        against origin: ExternalCorpus,
        queries: [RecallFrame] = [],
        now: Date
    ) async throws -> BenchmarkReport {
        // 1. Query set + expected-ID set from the corpus. The expected
        //    ids are index-aligned with `asRecallFrames()` so the MRR
        //    pairing is well-defined on the default path.
        let frames = queries.isEmpty ? origin.asRecallFrames() : queries
        let expectedIDs = origin.entries.map(\.id)

        // 2. Recall each frame — the ONLY substrate call this function
        //    makes — collecting each query's ranked id list. This is the
        //    estate I/O that keeps `benchmark` Swift-only.
        var foundPerQuery: [[String]] = []
        foundPerQuery.reserveCapacity(frames.count)
        for frame in frames {
            let drawers = try await branch.recall(frame)
            foundPerQuery.append(drawers.map(\.id))
        }

        // 3. Every metric is a pure function of (expectedIDs, foundPerQuery),
        //    delegated to the conformance-gated `BenchmarkScoring.score` —
        //    the same core the Rust version implements. `branchID` and
        //    `evaluatedAt` are the only estate-/clock-supplied fields.
        let s = BenchmarkScoring.score(
            expectedIDs: expectedIDs, foundPerQuery: foundPerQuery)

        return BenchmarkReport(
            branchID: branch.branchID,
            queryCount: s.queryCount,
            recallOverlap: s.recallOverlap,
            recallPrecision: s.recallPrecision,
            meanReciprocalRank: s.meanReciprocalRank,
            notFoundInBranch: s.notFoundInBranch,
            newInBranch: s.newInBranch,
            evaluatedAt: now
        )
    }
}
