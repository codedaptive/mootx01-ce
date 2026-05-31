// MigrationOrchestration.swift
//
// The PORTABLE ORCHESTRATION of MigrationBenchmark — the call sequence
// (derive → capture-each → benchmark, per plan) and the report assembly,
// expressed over a `RecipeSubstrate` seam so it has NO dependency on the
// GeniusLocusKit estate, no actor, no UUID minting, no clock. This is the
// Swift side of CognitionKit's Rust-parity Pass 2.
//
// Why a seam (the same deferral pattern Rust GLK's Surface and NeuronKit's
// daemon seams already use): the recipe BODY cannot run live in Rust —
// the Rust LocusKit estate does not exist (every Rust GLK verb is stubbed)
// and building it is the substrate missions' lane, not CognitionKit's. But
// the recipe's *sequencing logic* — what calls it makes, in what order,
// and how it threads the minted ids and benchmark results into the ranked
// report — IS portable. Abstracting the three substrate operations behind
// `RecipeSubstrate` lets that logic exist identically in Swift and Rust
// and be conformance-gated against a deterministic in-memory fake.
//
// Relationship to the production `MigrationBenchmark.run`:
//   - `run` is the live, async, GLK-backed, parallel-per-plan path.
//   - `MigrationOrchestration.run` is the synchronous, single-threaded,
//     substrate-agnostic REFERENCE for the same sequence.
//   - Both delegate every DECISION (C-13 gate, combined-score, ranking,
//     tie-break, duplicate-plan guard, lost-concept union) to the shared,
//     already-conformance-gated `MigrationRanking`. So the two cannot
//     disagree on outcomes; the seam adds only the portable call sequence.
//
// Determinism: a pure function of (substrate, plans, origin). The fake
// substrate mints deterministic ids so the Swift and Rust assembled
// reports — and the recorded call sequences — are identical.

import Foundation

/// The three substrate operations a migration recipe sequences, abstracted
/// so the orchestration is portable and testable without an estate.
///
/// A live adapter (a future bridge over the async GLK actor) and the
/// deterministic test fake both conform; the orchestration neither knows
/// nor cares which. `AnyObject` so a conformer can record call state by
/// reference without `inout` threading.
public protocol RecipeSubstrate: AnyObject {
    /// Derive a COW branch for `planName`; return its branch id.
    func deriveBranch(planName: String) -> String

    /// Capture one entry into `branchID`; return the MINTED drawer id.
    /// (Capture mints a fresh id — the reason the recipe must correlate
    /// the benchmark corpus to minted ids rather than origin ids.)
    func capture(
        branchID: String,
        content: String,
        room: String,
        latticeCode: String,
        embeddingModelID: String,
        sensitivity: Int
    ) -> String

    /// Benchmark `branchID` against `corpus` (the captured entries, keyed
    /// by minted id); return the recall-fidelity outcome.
    func benchmark(
        branchID: String,
        corpus: [MigrationOrchestration.CorpusEntry]
    ) -> MigrationOrchestration.BenchmarkOutcome
}

/// Portable migration-benchmark orchestration over the `RecipeSubstrate`
/// seam. All types here are identity-free value types so the Rust port
/// mirrors them exactly.
public enum MigrationOrchestration {

    /// One origin reference entry — `(id, content)`, estate-free.
    public struct OriginEntry: Sendable, Equatable {
        public let id: String
        public let content: String
        public init(id: String, content: String) {
            self.id = id
            self.content = content
        }
    }

    /// One candidate plan's parameters, estate-free (mirrors the fields
    /// the shipped capture path honours).
    public struct PlanInput: Sendable, Equatable {
        public let name: String
        public let room: String
        public let latticeCode: String
        public let embeddingModelID: String
        public let sensitivity: Int
        public init(
            name: String, room: String, latticeCode: String,
            embeddingModelID: String, sensitivity: Int
        ) {
            self.name = name
            self.room = room
            self.latticeCode = latticeCode
            self.embeddingModelID = embeddingModelID
            self.sensitivity = sensitivity
        }
    }

    /// A captured entry keyed by its minted drawer id — what `benchmark`
    /// scores against.
    public struct CorpusEntry: Sendable, Equatable {
        public let id: String
        public let content: String
        public init(id: String, content: String) {
            self.id = id
            self.content = content
        }
    }

    /// The recall-fidelity outcome a substrate returns for one branch.
    /// `notFound` is keyed by minted id (corpus id) — the benchmark's
    /// not-recalled signal.
    public struct BenchmarkOutcome: Sendable, Equatable {
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        public let notFound: [String]
        public init(
            recallOverlap: Float, meanReciprocalRank: Float, notFound: [String]
        ) {
            self.recallOverlap = recallOverlap
            self.meanReciprocalRank = meanReciprocalRank
            self.notFound = notFound
        }
    }

    /// One plan's full per-plan result, in input order — the branch id the
    /// substrate minted, its benchmark numbers, and its lost-concept set.
    public struct PlanResultCore: Sendable, Equatable {
        public let name: String
        public let branchID: String
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        public let lost: [String]
    }

    /// The assembled orchestration report: per-plan results (input order),
    /// the ranked survivors, the disqualified plans, and the advisory
    /// winner. The ranking fields come straight from `MigrationRanking`.
    public struct CoreReport: Sendable, Equatable {
        public let planResults: [PlanResultCore]
        public let rankings: [MigrationRanking.RankedPlan]
        public let disqualified: [MigrationRanking.DisqualifiedCore]
        public let winner: String?
    }

    /// Run the migration-benchmark orchestration over `substrate`.
    ///
    /// Sequence, per plan in input order: derive a branch, capture each
    /// migratable origin entry (recording the minted id), benchmark the
    /// branch against the id-correlated corpus, compute the lost set.
    /// Then the shared `MigrationRanking.rank` applies the C-13 gate and
    /// ranks survivors.
    ///
    /// - Throws: `RecipeError.duplicatePlanName` if two plans share a
    ///   name; `RecipeError.insufficientBranches` if `plans` is empty —
    ///   the same guards the production `run` applies.
    public static func run(
        substrate: RecipeSubstrate,
        plans: [PlanInput],
        origin: [OriginEntry]
    ) throws -> CoreReport {
        guard !plans.isEmpty else {
            throw RecipeError.insufficientBranches(minimum: 1, provided: 0)
        }
        if let dup = MigrationRanking.firstDuplicate(plans.map(\.name)) {
            throw RecipeError.duplicatePlanName(dup)
        }

        // Partition the origin ONCE — migratable vs dropped is plan-
        // independent (mirrors the production hoist).
        var migratable: [OriginEntry] = []
        var dropped: [String] = []
        for entry in origin {
            if entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dropped.append(entry.id)
            } else {
                migratable.append(entry)
            }
        }

        var planResults: [PlanResultCore] = []
        var outcomes: [MigrationRanking.PlanOutcome] = []
        for plan in plans {
            let branchID = substrate.deriveBranch(planName: plan.name)
            var corpus: [CorpusEntry] = []
            for entry in migratable {
                let mintedID = substrate.capture(
                    branchID: branchID,
                    content: entry.content,
                    room: plan.room,
                    latticeCode: plan.latticeCode,
                    embeddingModelID: plan.embeddingModelID,
                    sensitivity: plan.sensitivity)
                corpus.append(CorpusEntry(id: mintedID, content: entry.content))
            }
            let outcome = substrate.benchmark(branchID: branchID, corpus: corpus)
            let lost = MigrationRanking.lostConcepts(
                dropped: dropped, notFound: outcome.notFound)
            planResults.append(PlanResultCore(
                name: plan.name,
                branchID: branchID,
                recallOverlap: outcome.recallOverlap,
                meanReciprocalRank: outcome.meanReciprocalRank,
                lost: lost))
            outcomes.append(MigrationRanking.PlanOutcome(
                name: plan.name,
                recallOverlap: outcome.recallOverlap,
                meanReciprocalRank: outcome.meanReciprocalRank,
                lost: lost))
        }

        let ranked = MigrationRanking.rank(outcomes)
        return CoreReport(
            planResults: planResults,
            rankings: ranked.rankings,
            disqualified: ranked.disqualified,
            winner: ranked.winner)
    }
}
