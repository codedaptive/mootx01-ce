// MigrationBenchmark.swift
//
// A conscious comparison recipe: given an origin corpus and N candidate
// migration plans, derive one COW branch per plan, populate each branch
// per its plan's parameters, benchmark each branch's recall fidelity
// against the origin (zero-silent-loss gate, C-13), rank the survivors,
// and surface an advisory winner. Promotion is a SEPARATE, explicitly
// confirmed call — `run` never promotes or discards (spec B-3).
//
// ── Two source-verified realities shape this recipe ──
//
// 1. ID correlation. `NeuronKit.benchmark` compares the `Drawer.id`
//    values recalled from a branch against the `ExternalEntry.id`
//    values of the corpus it is scored against (an identity compare).
//    `BranchHandle.capture` mints a FRESH `Drawer.id` per row
//    (CaptureFrame has no id field). So a branch benchmarked against the
//    raw origin corpus reports total loss. This recipe closes the gap
//    honestly: as it captures each origin entry it records the minted
//    `Drawer.id` and builds a per-branch benchmark corpus whose
//    `ExternalEntry.id` equals that minted id. The benchmark then
//    measures real recall fidelity.
//
// 2. Why not `runTournament`. `NeuronKit.runTournament` benchmarks every
//    branch against ONE shared baseline corpus. Because each branch mints
//    its own ids (reality 1), a single shared corpus can id-correlate to
//    at most one branch — Tournament.swift's own header documents this.
//    So this recipe benchmarks each branch against ITS OWN id-correlated
//    corpus via `NeuronKit.benchmark`, applies the C-13 gate per branch,
//    and ranks survivors by the same product `runTournament` uses
//    (`recallOverlap × meanReciprocalRank`). Computing a product and
//    sorting is sequencing, not algorithm implementation (spec C-4 holds:
//    the benchmark metrics are NeuronKit's; the recipe only gates and
//    orders).
//
// ── Documented limitation (not a deferral) ──
// The shipped recall path is content-match (BM25/substring) only; the
// vector tier is deferred until VectorKit ships. The plan parameters that
// differ between candidate plans (room, lattice anchor, embedding model)
// do NOT affect content-match recall, so two non-lossy plans score
// identically and the ranking tie-breaks deterministically by plan name.
// Differential ranking becomes meaningful when structure-aware recall
// lands; the gate, correlation, and ranking machinery are correct today.
//
// Boundary discipline (B-1/B-2): the recipe holds no substrate state.
// Branch derivation, capture, benchmark, promote, and discard all flow
// through NeuronKit / the GLK branch verbs.

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit

/// One candidate migration plan. The fields are exactly those the
/// shipped `capture` path honours — not the v0.1 spec's aspirational
/// `LatticeStrategy` / `[String: Any]`, which have no shipped consumer.
public struct MigrationPlan: Sendable, Equatable, Codable {
    /// Human-readable plan name; also the branch name and the key the
    /// caller uses to confirm promotion.
    public let name: String
    /// Room every migrated drawer is filed into under this plan.
    public let room: String
    /// UDC lattice code every migrated drawer is anchored to.
    public let latticeCode: String
    /// Embedding model id tagged on every migrated drawer.
    public let embeddingModelID: String
    /// Sensitivity tier applied to every migrated drawer.
    public let sensitivity: AdjectiveSensitivity

    public init(
        name: String,
        room: String,
        latticeCode: String,
        embeddingModelID: String,
        sensitivity: AdjectiveSensitivity = .normal
    ) {
        self.name = name
        self.room = room
        self.latticeCode = latticeCode
        self.embeddingModelID = embeddingModelID
        self.sensitivity = sensitivity
    }
}

/// A surviving plan's rank line. Value type — id-only, MCP-serializable.
public struct BranchRanking: Sendable, Equatable, Codable {
    public let branchID: BranchID
    public let planName: String
    public let recallOverlap: Float
    public let meanReciprocalRank: Float
    /// `recallOverlap × meanReciprocalRank` — the tournament product.
    public let combinedScore: Float

    public init(
        branchID: BranchID, planName: String,
        recallOverlap: Float, meanReciprocalRank: Float, combinedScore: Float
    ) {
        self.branchID = branchID
        self.planName = planName
        self.recallOverlap = recallOverlap
        self.meanReciprocalRank = meanReciprocalRank
        self.combinedScore = combinedScore
    }
}

/// A plan disqualified by the zero-silent-loss gate (C-13), with the
/// origin concept ids it failed to migrate.
public struct DisqualifiedPlan: Sendable, Equatable, Codable {
    public let branchID: BranchID
    public let planName: String
    /// Origin `ExternalEntry.id` values lost: never captured (e.g. empty
    /// content) or captured-but-unrecallable. Sorted, deterministic.
    public let lostConcepts: [String]

    public init(branchID: BranchID, planName: String, lostConcepts: [String]) {
        self.branchID = branchID
        self.planName = planName
        self.lostConcepts = lostConcepts
    }
}

/// The plan-comparison summary. Pure value type (no live handles) so it
/// can be returned, logged, or rendered to MCP without owning substrate
/// state. `winnerPlanName` is advisory — promotion is a separate
/// confirmed call.
public struct MigrationComparisonReport: Sendable, Equatable, Codable {
    /// The top-ranked survivor's branch id, or nil if none survived.
    public let winnerBranchID: BranchID?
    /// The top-ranked survivor's plan name, or nil if none survived.
    public let winnerPlanName: String?
    /// Survivors, score-descending, ties broken by plan name ascending.
    public let rankings: [BranchRanking]
    /// Plans excluded by the C-13 gate, each with its lost concepts.
    public let disqualified: [DisqualifiedPlan]

    public init(
        winnerBranchID: BranchID?, winnerPlanName: String?,
        rankings: [BranchRanking], disqualified: [DisqualifiedPlan]
    ) {
        self.winnerBranchID = winnerBranchID
        self.winnerPlanName = winnerPlanName
        self.rankings = rankings
        self.disqualified = disqualified
    }
}

/// Compare candidate migration plans by branch recall fidelity.
public struct MigrationBenchmark: Recipe {

    /// Recipe input: the origin corpus and the candidate plans.
    public struct Input: Sendable {
        public let origin: ExternalCorpus
        public let plans: [MigrationPlan]

        public init(origin: ExternalCorpus, plans: [MigrationPlan]) {
            self.origin = origin
            self.plans = plans
        }
    }

    /// Recipe output: per-plan benchmark reports, the comparison summary,
    /// and the live branch handles keyed by plan name (so the gated
    /// `confirmPromotion` step can act on them). `run` never promotes
    /// (B-3) — the promoted branch is nil until `confirmPromotion`.
    public struct Output: Sendable {
        public let benchmarkReports: [BenchmarkReport]
        public let comparisonReport: MigrationComparisonReport
        /// Live branch handles for every plan, keyed by plan name.
        /// Carried so the caller can confirm promotion of the winner and
        /// discard of the losers in a second, explicit step.
        public let branchesByPlan: [String: any BranchHandle]

        public init(
            benchmarkReports: [BenchmarkReport],
            comparisonReport: MigrationComparisonReport,
            branchesByPlan: [String: any BranchHandle]
        ) {
            self.benchmarkReports = benchmarkReports
            self.comparisonReport = comparisonReport
            self.branchesByPlan = branchesByPlan
        }
    }

    public init() {}

    public let name = "migration_benchmark"
    public let version = "1.0.0"
    public let description =
        "Derive one branch per migration plan, benchmark each branch's recall fidelity against the origin (zero-silent-loss gate), and rank survivors."

    /// Sequences branch derivation, benchmarking, and (in the confirm
    /// step) promotion. `runTournament` is intentionally NOT used — see
    /// the file header for the id-correlation reason.
    public let requiredCapabilities: [NeuronKitCapability] = [
        .deriveBranch, .benchmark, .promoteBranch,
    ]

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // Spec B-5: capability gate before any substrate touch.
        try verifyCapabilities(required: requiredCapabilities)
        guard !input.plans.isEmpty else {
            throw RecipeError.insufficientBranches(minimum: 1, provided: 0)
        }

        // Recipe-entry wall clock stamps each benchmark's evaluatedAt. A
        // conscious action happens at a real instant; this value affects
        // only the report timestamp, not any logic.
        let now = Date()

        var benchmarkReports: [BenchmarkReport] = []
        var rankings: [BranchRanking] = []
        var disqualified: [DisqualifiedPlan] = []
        var branchesByPlan: [String: any BranchHandle] = [:]

        for plan in input.plans {
            // 1. Derive a COW branch for this plan (parent untouched, I-15).
            let branch = try await NeuronKit.deriveBranch(
                name: plan.name, from: estate, in: kit)
            branchesByPlan[plan.name] = branch

            // 2. Populate the branch per the plan. Record the minted
            //    Drawer.id ↔ content correlation; track concepts that
            //    cannot be migrated (empty content) as dropped.
            var correlated: [ExternalEntry] = []
            var dropped: [String] = []
            for entry in input.origin.entries {
                let trimmed = entry.content.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    dropped.append(entry.id)
                    continue
                }
                let frame = LocusKit.CaptureFrame(
                    content: entry.content,
                    channel: .typed,
                    room: plan.room,
                    latticeAnchor: LocusKit.LatticeAnchor.udc(plan.latticeCode),
                    addedBy: "migration-\(plan.name)",
                    embeddingModelID: plan.embeddingModelID,
                    sensitivity: plan.sensitivity)
                let drawer = try await branch.capture(frame)
                // Correlate the benchmark id to the MINTED drawer id so
                // the benchmark's identity compare is meaningful.
                correlated.append(ExternalEntry(
                    id: drawer.id, content: entry.content, tags: entry.tags))
            }

            // 3. Benchmark the branch against its own id-correlated corpus.
            let corpus = ExternalCorpus(
                name: "\(input.origin.name)#\(plan.name)", entries: correlated)
            let report = try await NeuronKit.benchmark(
                branch: branch, against: corpus, now: now)
            benchmarkReports.append(report)

            // 4. C-13 gate: lost = never-captured (dropped) ∪ captured-
            //    but-unrecallable (benchmark notFound). Non-empty ⇒
            //    disqualified; the branch is neither scored nor ranked.
            let lost = Set(dropped).union(report.notFoundInBranch).sorted()
            if lost.isEmpty {
                let combined = report.recallOverlap * report.meanReciprocalRank
                rankings.append(BranchRanking(
                    branchID: branch.branchID,
                    planName: plan.name,
                    recallOverlap: report.recallOverlap,
                    meanReciprocalRank: report.meanReciprocalRank,
                    combinedScore: combined))
            } else {
                disqualified.append(DisqualifiedPlan(
                    branchID: branch.branchID,
                    planName: plan.name,
                    lostConcepts: lost))
            }
        }

        // 5. Rank survivors: combined score descending, ties by plan name
        //    ascending so the ordering is reproducible (the documented
        //    tie-degeneracy lives here until structure-aware recall lands).
        rankings.sort { lhs, rhs in
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
            }
            return lhs.planName < rhs.planName
        }

        let comparison = MigrationComparisonReport(
            winnerBranchID: rankings.first?.branchID,
            winnerPlanName: rankings.first?.planName,
            rankings: rankings,
            disqualified: disqualified)

        return Output(
            benchmarkReports: benchmarkReports,
            comparisonReport: comparison,
            branchesByPlan: branchesByPlan)
    }

    /// Confirm promotion of the winning plan's branch into the estate and
    /// discard the losing branches. This is the explicit human-gated
    /// second step (spec B-3) — `run` never promotes on its own.
    ///
    /// - Throws:
    ///   - `RecipeError.silentConceptLoss` if `winnerPlanName` names a
    ///     plan the C-13 gate disqualified (spec C-5: a disqualified
    ///     plan is never promoted).
    ///   - `RecipeError.userConfirmationRequired` if `winnerPlanName`
    ///     does not name a branch in the output.
    public func confirmPromotion(
        winnerPlanName: String,
        output: Output,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws {
        // Guard: never promote a disqualified plan (C-5).
        if let dq = output.comparisonReport.disqualified.first(
            where: { $0.planName == winnerPlanName }) {
            throw RecipeError.silentConceptLoss(
                branchID: dq.branchID, lostConcepts: dq.lostConcepts)
        }
        guard let winner = output.branchesByPlan[winnerPlanName] else {
            throw RecipeError.userConfirmationRequired(
                action: "promote unknown plan '\(winnerPlanName)'")
        }
        // Promote the winner into the parent estate (writes descend
        // through the GLK branch verb).
        try await NeuronKit.promoteBranch(winner, replacing: estate, in: kit)
        // Discard the losers; their rows are retained for audit (I-15).
        for (planName, branch) in output.branchesByPlan
        where planName != winnerPlanName {
            try await branch.discard()
        }
    }

    /// Confirm promotion across a STATELESS boundary, by branch id.
    ///
    /// The handle-based `confirmPromotion(winnerPlanName:output:...)` above
    /// is the in-process path: it holds the live `Output` and enforces the
    /// C-5 disqualification guard from the report it carries. But a
    /// stateless caller (the ARIA_MCP recipe surface) cannot keep the
    /// `Output` between the run call and the confirm call — those are two
    /// separate `tools/call` invocations. It keeps only the ids the run
    /// report surfaced. This variant resolves each id back to its live
    /// branch through the kit's retained registry
    /// (`GeniusLocusKit.branchHandle(for:)`) and performs the same
    /// promote-winner + discard-losers sequence.
    ///
    /// C-5 across the boundary: the run report surfaced the disqualified
    /// branch ids to the conscious caller (MCP↔CognitionKit is the R/W
    /// teaching channel — a human or agent is in the loop and saw the
    /// report). The caller echoes that set back as `disqualifiedBranchIDs`
    /// so the guard is still enforced server-side: promoting a branch the
    /// report disqualified raises `silentConceptLoss`, exactly as the
    /// in-process path does. An empty set means the caller asserts no
    /// disqualification applies.
    ///
    /// - Throws:
    ///   - `RecipeError.silentConceptLoss` if `winnerBranchID` is in
    ///     `disqualifiedBranchIDs` (spec C-5).
    ///   - `RecipeError.userConfirmationRequired` if `winnerBranchID` does
    ///     not resolve to a branch tracked by `kit`.
    public func confirmPromotion(
        winnerBranchID: BranchID,
        discardBranchIDs: [BranchID],
        disqualifiedBranchIDs: Set<BranchID> = [],
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws {
        // C-5: never promote a branch the report disqualified.
        if disqualifiedBranchIDs.contains(winnerBranchID) {
            throw RecipeError.silentConceptLoss(
                branchID: winnerBranchID, lostConcepts: [])
        }
        guard let winner = await kit.branchHandle(for: winnerBranchID) else {
            throw RecipeError.userConfirmationRequired(
                action: "promote unknown branch \(winnerBranchID)")
        }
        // Promote the winner; writes descend through the GLK branch verb.
        try await NeuronKit.promoteBranch(winner, replacing: estate, in: kit)
        // Discard the losers; rows retained for audit (I-15). An id that
        // no longer resolves is skipped — discarding is idempotent intent.
        for id in discardBranchIDs where id != winnerBranchID {
            if let branch = await kit.branchHandle(for: id) {
                try await branch.discard()
            }
        }
    }
}
