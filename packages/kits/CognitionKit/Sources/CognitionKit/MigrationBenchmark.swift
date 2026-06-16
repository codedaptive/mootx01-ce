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
// ── Intentional benchmark contract ──
// The benchmark recall path is LocusKit content-match (BM25/substring) via
// `asRecallFrames()` — this is deliberate. VectorKit and CorpusKit have shipped
// and their vector recall lane (Lane D) is live at runtime, but the benchmark
// intentionally measures structural recall fidelity: whether a migration plan
// preserves content recallability, independent of embedding-space ranking.
// The plan parameters that differ between candidate plans (room, lattice anchor,
// embedding model) do NOT affect content-match recall, so two non-lossy plans
// score identically and the ranking tie-breaks deterministically by plan name.
// Differential ranking by vector score is possible but is a separate recipe
// concern; the gate (C-13), correlation, and ranking machinery are correct today.
//
// Boundary discipline (B-1/B-2): the recipe holds no substrate state.
// Branch derivation, capture, benchmark, promote, and discard all flow
// through NeuronKit / the GLK branch verbs.

import Foundation
import GeniusLocusKit
import IntellectusLib
import LocusKit
import NeuronKit

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
        // Plan names key the branch map and the confirm step; a duplicate
        // would silently collide (last wins) and leak a derived branch.
        // Reject it up front so the failure is explicit, not a leak. The
        // uniqueness check is part of the shared, conformance-gated
        // decision core.
        if let dup = MigrationRanking.firstDuplicate(input.plans.map(\.name)) {
            throw RecipeError.duplicatePlanName(dup)
        }

        // Capability and guard checks passed — the recipe will execute.
        // Capture the recipe-start timestamp once at the validated entry.
        // Emit is placed AFTER the precondition checks so the start metric
        // only fires when the recipe body will actually run. When monitoring
        // is disabled, emitRecipeStart is a single atomic load + branch:
        // zero allocation, no clock read wasted.
        let startTs = Date().timeIntervalSince1970
        // Emit cognitionkit.recipe.run with status "start". The step_count
        // for the paired "complete" event will be input.plans.count (the
        // number of plans benchmarked — the unit of work for this recipe).
        emitRecipeStart(name: name, ts: startTs)

        // Recipe-entry wall clock stamps each benchmark's evaluatedAt. A
        // conscious action happens at a real instant; this value affects
        // only the report timestamp, not any logic. Captured once so every
        // parallel branch is benchmarked at the same deterministic instant.
        let now = Date()

        // Partition the origin ONCE, before the per-plan fan-out. Which
        // entries are migratable (non-empty content) vs droppable is a
        // function of the origin alone — it does NOT vary by plan. Computing
        // it per plan re-trimmed every entry N_plans times; hoisting it here
        // makes that an O(entries) pass instead of O(plans × entries) and
        // hands each plan an already-filtered set to capture. Behaviour is
        // identical: every plan's lost set is still droppedIDs ∪ its own
        // benchmark notFound, and droppedIDs is the same value each plan saw.
        var migratableEntries: [ExternalEntry] = []
        migratableEntries.reserveCapacity(input.origin.entries.count)
        var droppedIDs: [String] = []
        for entry in input.origin.entries {
            if entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                droppedIDs.append(entry.id)
            } else {
                migratableEntries.append(entry)
            }
        }
        let originName = input.origin.name
        // Bind the finished partitions to immutable `let`s before the task
        // group. Each concurrent task captures these by value; capturing a
        // mutable `var` would risk a data race under Swift 6 strict
        // concurrency (the closure is a `sending` parameter). They are never
        // mutated after this point — read-only shared input to every plan.
        let migratable = migratableEntries
        let dropped = droppedIDs

        // Per-plan work runs CONCURRENTLY. Each plan derives its own COW
        // branch — an independent in-memory estate that shares nothing with
        // the others until the deterministic ranking merge below. The GLK
        // actor serializes branch-registry mutation; captures target
        // distinct branch estates and run in parallel, so N plans cost ~1
        // plan's wall-clock instead of N. Determinism is unaffected:
        // ranking is a pure sort over the collected results, independent of
        // task completion order (the C-13 gate and tie-break are applied in
        // the serial merge, not in the concurrent tasks).
        var resultsByName: [String: PlanResult] = [:]
        resultsByName.reserveCapacity(input.plans.count)
        try await withThrowingTaskGroup(of: PlanResult.self) { group in
            for plan in input.plans {
                group.addTask {
                    try await Self.processPlan(
                        plan, migratable: migratable, dropped: dropped,
                        originName: originName, estate: estate, kit: kit, now: now)
                }
            }
            for try await result in group {
                resultsByName[result.planName] = result
            }
        }

        // Deterministic assembly: walk plans in INPUT order so the
        // benchmark-report collection and the ranking's tie-break baseline
        // do not depend on which concurrent task finished first. Build the
        // identity-free PlanOutcome list and hand it to the shared,
        // conformance-gated decision core; the recipe then rehydrates the
        // branch identity (UUIDs, which are not part of the pure core)
        // by plan name.
        var benchmarkReports: [BenchmarkReport] = []
        benchmarkReports.reserveCapacity(input.plans.count)
        var branchesByPlan: [String: any BranchHandle] = [:]
        branchesByPlan.reserveCapacity(input.plans.count)
        var outcomes: [MigrationRanking.PlanOutcome] = []
        outcomes.reserveCapacity(input.plans.count)
        for plan in input.plans {
            guard let result = resultsByName[plan.name] else { continue }
            branchesByPlan[plan.name] = result.branch
            benchmarkReports.append(result.report)
            outcomes.append(MigrationRanking.PlanOutcome(
                name: plan.name,
                recallOverlap: result.report.recallOverlap,
                meanReciprocalRank: result.report.meanReciprocalRank,
                lost: result.lost))
        }

        // The C-13 gate, the combined-score, the survivor ranking, and the
        // tie-break all live in MigrationRanking.rank — the same function
        // the Rust version implements and both test suites gate on shared
        // fixtures.
        let ranked = MigrationRanking.rank(outcomes)

        // Rehydrate branch identity by name. Every name in `ranked` came
        // from `outcomes`, which came from `resultsByName`, so the lookups
        // resolve; compactMap is defensive belt-and-suspenders.
        let rankings: [BranchRanking] = ranked.rankings.compactMap { r in
            guard let branch = resultsByName[r.name]?.branch else { return nil }
            return BranchRanking(
                branchID: branch.branchID,
                planName: r.name,
                recallOverlap: r.recallOverlap,
                meanReciprocalRank: r.meanReciprocalRank,
                combinedScore: r.combinedScore)
        }
        let disqualified: [DisqualifiedPlan] = ranked.disqualified.compactMap { d in
            guard let branch = resultsByName[d.name]?.branch else { return nil }
            return DisqualifiedPlan(
                branchID: branch.branchID,
                planName: d.name,
                lostConcepts: d.lostConcepts)
        }

        let comparison = MigrationComparisonReport(
            winnerBranchID: ranked.winner.flatMap { resultsByName[$0]?.branch.branchID },
            winnerPlanName: ranked.winner,
            rankings: rankings,
            disqualified: disqualified)

        // Emit cognitionkit.recipe.run with status "complete". The step_count
        // is input.plans.count — the number of plans benchmarked during this
        // recipe invocation. Byte-identical output regardless of monitoring
        // state (C-Det: the return value is already assembled above).
        emitRecipeComplete(name: name, stepCount: input.plans.count, ts: startTs)

        return Output(
            benchmarkReports: benchmarkReports,
            comparisonReport: comparison,
            branchesByPlan: branchesByPlan)
    }

    /// The concurrent unit of `run`: derive one plan's COW branch,
    /// populate it from the pre-filtered migratable entries, benchmark it,
    /// and compute its lost-concept set. Pure with respect to the recipe
    /// (no shared mutable state) so it runs safely inside the task group.
    /// `static` so the task closure captures no `self`.
    ///
    /// `migratable` and `dropped` are computed once by `run` (they are
    /// plan-independent) and passed in, so this function does no redundant
    /// content filtering.
    private static func processPlan(
        _ plan: MigrationPlan,
        migratable: [ExternalEntry],
        dropped: [String],
        originName: String,
        estate: EstateHandle,
        kit: GeniusLocusKit,
        now: Date
    ) async throws -> PlanResult {
        // Derive a COW branch for this plan (parent untouched, I-15).
        let branch = try await NeuronKit.deriveBranch(
            name: plan.name, from: estate, in: kit)

        // Populate the branch from the pre-filtered migratable entries.
        // Record the minted Drawer.id ↔ content correlation. Captures into
        // one branch estate are serialized by that estate's actor; that is
        // correct — the parallelism is ACROSS branches, not within one.
        var correlated: [ExternalEntry] = []
        correlated.reserveCapacity(migratable.count)
        for entry in migratable {
            let frame = LocusKit.CaptureFrame(
                content: entry.content,
                channel: .typed,
                room: plan.room,
                latticeAnchor: LocusKit.LatticeAnchor.udc(plan.latticeCode),
                addedBy: "migration-\(plan.name)",
                embeddingModelID: plan.embeddingModelID,
                sensitivity: plan.sensitivity)
            let drawer = try await branch.capture(frame)
            // Correlate the benchmark id to the MINTED drawer id so the
            // benchmark's identity compare is meaningful.
            correlated.append(ExternalEntry(
                id: drawer.id, content: entry.content, tags: entry.tags))
        }

        // Benchmark the branch against its own id-correlated corpus.
        let corpus = ExternalCorpus(
            name: "\(originName)#\(plan.name)", entries: correlated)
        let report = try await NeuronKit.benchmark(
            branch: branch, against: corpus, now: now)

        // lost = never-captured (dropped) ∪ captured-but-unrecallable
        // (benchmark notFound), via the shared conformance-gated core.
        let lost = MigrationRanking.lostConcepts(
            dropped: dropped, notFound: report.notFoundInBranch)
        return PlanResult(
            planName: plan.name, branch: branch, report: report, lost: lost)
    }

    /// The result of processing one plan concurrently. `any BranchHandle`
    /// is `Sendable`, so this value type crosses the task-group boundary
    /// cleanly. Private — an internal carrier between `processPlan` and
    /// the serial merge in `run`.
    private struct PlanResult: Sendable {
        let planName: String
        let branch: any BranchHandle
        let report: BenchmarkReport
        let lost: [String]
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
