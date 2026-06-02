// MigrationRanking.swift
//
// The DETERMINISTIC DECISION CORE of MigrationBenchmark, factored out of
// the estate-driven recipe so it can be conformance-gated against the
// Rust version (CognitionKit/rust/src/migration_ranking.rs). Per CLAUDE.md
// neither version leads; both implement the same spec and agree on shared
// fixtures.
//
// Everything here is a PURE function of its inputs — no estate, no
// branch handles, no UUIDs, no clock, no randomness, no unordered
// iteration that reaches the output. That is exactly what makes it
// portable and gateable: `MigrationBenchmark.run` does the estate I/O
// (Swift-only, needs the GLK handle) and delegates every *decision* —
// the C-13 gate, the lost-concept union, the survivor ranking, the
// duplicate-plan guard — to these functions. The Rust crate implements these
// same functions and its tests assert identical outputs on the same
// fixtures the Swift `MigrationRankingTests` use.

import Foundation

/// Pure decision logic shared by the Swift recipe and the Rust version.
public enum MigrationRanking {

    /// One plan's benchmark outcome, stripped of any estate identity
    /// (no branch handle / UUID) so the ranking is a pure function.
    public struct PlanOutcome: Sendable, Equatable {
        public let name: String
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        /// Concepts this plan lost (dropped ∪ benchmark not-found). A
        /// non-empty set disqualifies the plan (C-13).
        public let lost: [String]

        public init(
            name: String, recallOverlap: Float,
            meanReciprocalRank: Float, lost: [String]
        ) {
            self.name = name
            self.recallOverlap = recallOverlap
            self.meanReciprocalRank = meanReciprocalRank
            self.lost = lost
        }
    }

    /// A surviving plan's rank line — identity-free counterpart of
    /// `BranchRanking` (the recipe rehydrates the branch id by name).
    public struct RankedPlan: Sendable, Equatable {
        public let name: String
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        public let combinedScore: Float
    }

    /// A disqualified plan — identity-free counterpart of `DisqualifiedPlan`.
    public struct DisqualifiedCore: Sendable, Equatable {
        public let name: String
        public let lostConcepts: [String]
    }

    /// The ranking outcome: survivors (ranked), disqualified plans, and
    /// the advisory winner name (top survivor, nil if none).
    public struct Result: Sendable, Equatable {
        public let rankings: [RankedPlan]
        public let disqualified: [DisqualifiedCore]
        public let winner: String?
    }

    /// The first value that appears more than once in `names`, scanning in
    /// order, or nil when every value is unique. (Plan-name uniqueness
    /// guard — see `RecipeError.duplicatePlanName`.)
    public static func firstDuplicate(_ names: [String]) -> String? {
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            return name
        }
        return nil
    }

    /// The lost-concept set for one plan: the union of concepts never
    /// captured (`dropped`) and concepts captured but not recalled by the
    /// benchmark (`notFound`), de-duplicated and sorted for a
    /// deterministic, cross-version-identical result.
    public static func lostConcepts(
        dropped: [String], notFound: [String]
    ) -> [String] {
        Set(dropped).union(notFound).sorted()
    }

    /// Partition origin `(id, content)` pairs into the ids worth migrating
    /// (non-empty after trimming) and the ids dropped as unmigratable.
    /// Order-preserving within each bucket. Mirrors the partition
    /// `MigrationBenchmark.run` performs over `ExternalEntry`.
    public static func partitionOrigin(
        _ entries: [(id: String, content: String)]
    ) -> (migratable: [String], dropped: [String]) {
        var migratable: [String] = []
        var dropped: [String] = []
        for entry in entries {
            if entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                dropped.append(entry.id)
            } else {
                migratable.append(entry.id)
            }
        }
        return (migratable, dropped)
    }

    /// Apply the C-13 gate and rank the survivors.
    ///
    /// - A plan with a non-empty `lost` set is disqualified (neither
    ///   scored nor ranked).
    /// - A survivor's `combinedScore` is `recallOverlap × meanReciprocalRank`.
    /// - Survivors sort by `combinedScore` descending, ties broken by
    ///   `name` ascending, so the order is reproducible across versions and
    ///   across the recipe's concurrent execution.
    /// - The advisory `winner` is the top survivor's name, or nil.
    ///
    /// `outcomes` is consumed in the given order; callers pass plans in a
    /// deterministic (input) order so the disqualified list and the
    /// tie-break baseline do not depend on task-completion order.
    public static func rank(_ outcomes: [PlanOutcome]) -> Result {
        var rankings: [RankedPlan] = []
        var disqualified: [DisqualifiedCore] = []
        for outcome in outcomes {
            if outcome.lost.isEmpty {
                rankings.append(RankedPlan(
                    name: outcome.name,
                    recallOverlap: outcome.recallOverlap,
                    meanReciprocalRank: outcome.meanReciprocalRank,
                    combinedScore: outcome.recallOverlap * outcome.meanReciprocalRank))
            } else {
                disqualified.append(DisqualifiedCore(
                    name: outcome.name, lostConcepts: outcome.lost))
            }
        }
        rankings.sort { lhs, rhs in
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
            }
            return lhs.name < rhs.name
        }
        return Result(
            rankings: rankings,
            disqualified: disqualified,
            winner: rankings.first?.name)
    }
}
