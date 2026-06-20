// DreamingDaemon.swift
//
// The dreaming daemon (NEURONKIT_SPEC § 3.1). Mines substrate state for
// latent associations the user has not explicitly made and PROPOSES
// Tunnel nouns for novel alignments clearing a confidence threshold. It
// never creates Tunnels directly (§ 3.1 invariant) — the human confirms
// via the `associate` verb. It is autonomic: it ticks on a schedule and
// on demand, and its only writes are proposals plus one cycle diary
// entry.
//
// ── Why this daemon talks to seams, not to GLK verbs ──────────────────
// MOOTx01 invariant B-1: NeuronKit never executes SQL and never calls
// LocusKit / VectorKit / CorpusKit directly; the estate handle is the only
// write surface. Even with `propose` now live (Brain layer landed in
// GLK-02), no estate verb reads RecallTraceItem rows, reads existing
// Tunnels, or writes a DiaryEntry. So the daemon depends on
// NeuronKit-owned seam protocols (`DreamingSubstrateReader` for reads,
// `DreamingProposalSink` for the two write kinds, `DreamingPolicyStore`
// for the manifest-resident policy, `RewardSource` for the reward
// signal). The production adapters (`EstateDreamingReader`,
// `EstateDreamingSink`) bind these seams to real estate calls through
// the GLK surface. The daemon references the substrate VALUE types
// (RecallTraceItem, DiaryEntry, Tunnel, ProposeFrame) but calls no
// substrate method, so B-1 holds.
//
// ── Determinism ───────────────────────────────────────────────────────
// Per CLAUDE.md every computation is deterministic: the daemon never
// calls `Date()` internally. The caller passes `now` into every cycle
// and pump. The conformance tests drive an injected clock by advancing
// the `now` they pass; there are no wall-clock sleeps anywhere.

import Foundation
import GeniusLocusKit
import IntellectusLib

/// Read surface the dreaming daemon mines (NEURONKIT_SPEC § 3.1 tick
/// steps 1–2 and 5). Dependency seam; `EstateDreamingReader` is the
/// production adapter that binds each method to the corresponding GLK
/// estate read. All three reads are pure inputs — the daemon mutates
/// nothing through this protocol.
public protocol DreamingSubstrateReader: Sendable {

    /// Recall-trace rows in the recent reward window. The daemon derives
    /// reward from each via the `RewardSource` seam (step 1b). `since`
    /// and `now` bound the window; the adapter filters by `recalledAt`.
    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]

    /// Latent co-occurrence candidates extracted from diary content and
    /// bitmap state (step 2). Each observation names a candidate endpoint
    /// pair, how many times the pair co-occurred (`attempts`), and the
    /// recalled rows that evidence the pair (so the daemon can join them
    /// to the reward map for scoring).
    func coOccurrenceObservations() async throws -> [CoOccurrenceObservation]

    /// Existing Tunnel nouns, consulted to suppress candidates that duplicate
    /// an alignment the substrate already records (step 5).
    func existingTunnels() async throws -> [Tunnel]
}

/// Write surface the dreaming daemon emits through (NEURONKIT_SPEC § 3.1
/// tick steps 6–7). This is the daemon's ONLY write path. It exposes
/// exactly three operations — emit a proposal, record the cycle diary
/// entry, and prune stale recall-trace rows after the reward sweep — and
/// deliberately has NO Tunnel-creation method, which is how the
/// never-create-Tunnels invariant is enforced structurally: the daemon
/// cannot create a Tunnel because nothing it can reach does.
///
/// `EstateDreamingSink` is the production adapter; it implements
/// `propose(_:)` by forwarding to the estate handle's `propose` verb
/// (the legal B-1 write path), `recordCycleDiary(_:)` by forwarding
/// to `addDiaryEntry`, and `pruneRecallTraces(olderThan:)` by forwarding
/// to `GeniusLocusKit.pruneRecallTraces(in:olderThan:)`.
public protocol DreamingProposalSink: Sendable {

    /// Emit a proposal for a novel candidate alignment (step 6). Maps to
    /// the estate `propose` verb in production.
    func propose(_ frame: ProposeFrame) async throws

    /// Record exactly one diary entry summarising the cycle (step 7).
    func recordCycleDiary(_ entry: DiaryEntry) async throws

    /// Delete recall-trace rows whose `recalledAt` is strictly before
    /// `cutoff`. Called after the reward sweep to keep the table bounded.
    /// Returns the number of rows deleted. Implementations that do not
    /// persist trace rows may return 0 without error (e.g. in-memory
    /// test fakes).
    ///
    /// - Parameter cutoff: rows with recalledAt < cutoff are deleted.
    @discardableResult
    func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int
}

/// A latent co-occurrence the daemon may propose as a Tunnel.
public struct CoOccurrenceObservation: Sendable, Equatable, Hashable {

    /// One endpoint of the candidate alignment (a drawer RowID).
    public let endpointA: RowID

    /// The other endpoint (a drawer RowID).
    public let endpointB: RowID

    /// How many times the pair co-occurred. Gated against
    /// `DreamingPolicy.minAttempts` (§ 3.1 step 6).
    public let attempts: Int

    /// Recalled rows that evidence this co-occurrence. The daemon looks
    /// each up in the reward map to score the candidate contrastively.
    public let evidenceTargets: [RowID]

    public init(endpointA: RowID, endpointB: RowID, attempts: Int, evidenceTargets: [RowID]) {
        self.endpointA = endpointA
        self.endpointB = endpointB
        self.attempts = attempts
        self.evidenceTargets = evidenceTargets
    }
}

/// What one dreaming cycle did. Returned by `triggerDreamingCycle` and
/// `pump` so callers (and conformance tests) can inspect the cycle
/// without reading the substrate back.
public struct DreamingCycleReport: Sendable, Equatable {

    /// The `now` the cycle ran at.
    public let tickedAt: Date

    /// Co-occurrence observations considered this cycle.
    public let candidatesConsidered: Int

    /// Proposals emitted this cycle (step 6), in emission order.
    public let proposalsEmitted: [ProposeFrame]

    /// Candidates suppressed as duplicates of an existing Tunnel or of a
    /// proposal already emitted in a prior cycle (step 5 + idempotency).
    public let suppressedDuplicates: Int

    /// Candidates that cleared duplicate suppression but failed the
    /// confidence or attempts gate (step 6).
    public let belowThreshold: Int

    /// Effective (post-EWC++) confidence by candidate key. Exposed so the
    /// EWC++ consolidation contract (step 4) is testable directly.
    public let candidateScores: [String: Float]

    /// Derived reward by recall-trace target (step 1). Exposed so C-15
    /// (reads `RecallTraceItem.used` as reward) is testable directly:
    /// used → 1.0, unused → 0.0.
    public let rewardByTarget: [RowID: Float]

    /// The single diary entry written this cycle (step 7).
    public let diaryEntry: DiaryEntry
}

/// The dreaming daemon — a background actor so it never blocks the
/// caller (§ 3 autonomic contract). Idempotent across cycles (B-4):
/// re-running over unchanged state emits no duplicate proposals.
public actor DreamingDaemon {

    // MARK: - Scoring constants

    /// InfoNCE softmax temperature for the contrastive score (step 3).
    /// Lower temperature sharpens the separation between a high-reward
    /// candidate and the negative baseline. 0.2 gives a comfortable
    /// margin around the 0.7 `minConfidence` default: a fully-used
    /// candidate scores ≈ 0.88 and a fully-unused one ≈ 0.05.
    /// The value lives in `DreamingDecision` (the portable decision core);
    /// this alias keeps the actor's own references reading naturally.
    static let temperature: Double = DreamingDecision.temperature

    /// EWC++ retention factor (step 4). A consolidated confidence from an
    /// earlier cycle decays by at most this factor per cycle in the absence
    /// of fresh evidence, rather than being overwritten by a low fresh
    /// score. This is the bounded, documented approximation the mission
    /// permits for v1: it implements the contract "prior associations are
    /// not catastrophically overwritten" without the full Fisher-matrix
    /// machinery. 0.9 keeps a consolidated 0.88 above the 0.7 gate for
    /// several barren cycles before it lapses. Defined in the portable
    /// `DreamingDecision` core; aliased here for the actor's references.
    static let ewcRetention: Float = DreamingDecision.ewcRetention

    // MARK: - Injected seams

    private let reader: DreamingSubstrateReader
    private let sink: DreamingProposalSink
    private let rewardSource: RewardSource
    private let policyStore: DreamingPolicyStore

    /// Optional corpus growth probe for the auto-reindex step. When non-nil,
    /// the daemon measures corpus growth at the end of each cycle and triggers
    /// `CorpusGrowthProbe.reindex(now:)` when growth since the last retrain
    /// exceeds `reindexGrowthThreshold`. Nil disables auto-reindex (correct
    /// for test environments that do not wire a live Corpus).
    private let growthProbe: (any CorpusGrowthProbe)?

    /// Growth threshold (in chunks) above which the daemon triggers a corpus
    /// basis retrain. Defaults to `autoReindexGrowthThreshold` (25 chunks).
    /// See `autoReindexGrowthThreshold` for the vocabulary-coverage rationale.
    private let reindexGrowthThreshold: Int

    // MARK: - Mutable state (actor-isolated)

    /// Current discovery parameters. Mutated by `registerDreamingPolicy`,
    /// persisted through `policyStore`.
    private var policy: DreamingPolicy

    /// The current trigger mode, updated by the bandit after each cycle.
    /// Starts at the injected value (default `.timer`); the bandit
    /// re-selects each cycle via Thompson Sampling once reward is observed.
    private var triggerMode: DreamingTriggerMode

    /// Thompson-Sampling Beta bandit that selects the trigger mode per
    /// estate from observed dreaming-cycle reward (NEURONKIT_SPEC § 3.4).
    /// Mutable because each cycle updates the selected arm's posterior
    /// and re-selects. Not persisted by the daemon itself (B-4); the host
    /// layer persists and restores it via `policyStore.loadBandit()`.
    private var bandit: SolverBandit

    /// Last timer-path cycle time, for the tick-cadence decision in `pump`.
    /// Tracks only timer-triggered fires so event-path fires in `.hybrid`
    /// mode do not reset the timer countdown; the two paths are independent.
    private var lastTickAt: Date?

    /// Candidate keys already proposed in a prior cycle. The idempotency
    /// memory (B-4): a key here is never proposed again.
    private var proposedKeys: Set<String> = []

    /// Chunk count at the time of the most recent corpus basis retrain (or
    /// at daemon initialisation, whichever is later). The auto-reindex gate
    /// fires when `liveChunkCount − lastReindexChunkCount >= reindexGrowthThreshold`.
    /// Initialised to −1 (sentinel) so the first cycle always reads the live
    /// count and establishes the baseline before any threshold comparison.
    private var lastReindexChunkCount: Int = -1

    /// EWC++ consolidated confidence by candidate key (step 4).
    private var consolidated: [String: Float] = [:]

    /// Number of cycles run. Recorded in the cycle diary entry.
    private var cycleCount: Int = 0

    // MARK: - Init

    /// Construct a daemon over the injected seams.
    ///
    /// - Parameters:
    ///   - reader: substrate read seam.
    ///   - sink: proposal + diary write seam (the only write path).
    ///   - rewardSource: reward-signal seam. Defaults to the v1
    ///     single-source `RecallTraceRewardSource` (`RecallTraceItem.used`).
    ///   - policyStore: manifest-resident policy persistence seam.
    ///   - triggerMode: trigger seam. Defaults to `.timer`.
    ///   - policy: initial in-memory policy. Defaults to the spec
    ///     defaults; `loadPersistedPolicy()` overrides it from the store.
    ///   - growthProbe: optional corpus-growth probe for the auto-reindex
    ///     step. When non-nil, each cycle measures corpus growth and
    ///     triggers a basis retrain when growth exceeds `reindexGrowthThreshold`.
    ///     Defaults to nil (auto-reindex disabled). Production callers pass
    ///     an `EstateCorpusGrowthProbe` to light the auto-reindex lane.
    ///   - reindexGrowthThreshold: chunk-count delta above which a corpus
    ///     basis retrain is triggered. Defaults to `autoReindexGrowthThreshold`
    ///     (25 chunks). Override for estates with very dense or very sparse
    ///     ingestion patterns.
    public init(
        reader: DreamingSubstrateReader,
        sink: DreamingProposalSink,
        rewardSource: RewardSource = RecallTraceRewardSource(),
        policyStore: DreamingPolicyStore,
        triggerMode: DreamingTriggerMode = .default,
        bandit: SolverBandit = SolverBandit(),
        policy: DreamingPolicy = .default,
        growthProbe: (any CorpusGrowthProbe)? = nil,
        reindexGrowthThreshold: Int = autoReindexGrowthThreshold
    ) {
        self.reader = reader
        self.sink = sink
        self.rewardSource = rewardSource
        self.policyStore = policyStore
        self.triggerMode = triggerMode
        self.bandit = bandit
        self.policy = policy
        self.growthProbe = growthProbe
        self.reindexGrowthThreshold = reindexGrowthThreshold
    }

    // MARK: - Policy registration (§ 3.1 registration API)

    /// Register the dreaming discovery parameters and persist them to the
    /// manifest seam. Spec defaults match NEURONKIT_SPEC § 3.1.
    ///
    /// - Parameters:
    ///   - minSuccessRate: reward threshold above which a row is a success. Default 0.6.
    ///   - minConfidence: minimum contrastive confidence to propose. Default 0.7.
    ///   - minAttempts: minimum co-occurrence count to be eligible. Default 3.
    ///   - tickIntervalMs: timer cadence in milliseconds. Default 30_000.
    ///   - eventObservationThreshold: observation count at which an event-mode
    ///     cycle fires. Default 1 (any non-empty observation set triggers).
    public func registerDreamingPolicy(
        minSuccessRate: Float = 0.6,
        minConfidence: Float = 0.7,
        minAttempts: Int = 3,
        tickIntervalMs: Int = 30_000,
        eventObservationThreshold: Int = 1
    ) async throws {
        let next = DreamingPolicy(
            minSuccessRate: minSuccessRate,
            minConfidence: minConfidence,
            minAttempts: minAttempts,
            tickIntervalMs: tickIntervalMs,
            eventObservationThreshold: eventObservationThreshold
        )
        policy = next
        try await policyStore.savePolicy(next)
    }

    /// Load the persisted policy and bandit state from the manifest seam,
    /// if any. Call once after construction to pick up state a prior run
    /// registered. The bandit reverts to a fresh uniform prior if no
    /// persisted state is found.
    public func loadPersistedPolicy() async throws {
        if let stored = try await policyStore.loadPolicy() {
            policy = stored
        }
        if let stored = try await policyStore.loadBandit() {
            bandit = stored
        }
    }

    /// The current policy. Exposed for the manifest round-trip test.
    public func currentPolicy() -> DreamingPolicy { policy }

    /// The current bandit-selected trigger mode. Updated after each cycle
    /// via Thompson Sampling; callers (e.g. the host loop) read this to
    /// decide scheduling strategy for the next cycle.
    public func currentTriggerMode() -> DreamingTriggerMode { triggerMode }

    /// The current bandit state. Exposed so the host layer can persist
    /// it via the policy seam after each pump/cycle.
    public func currentBandit() -> SolverBandit { bandit }

    /// The wired reward source's kind. Exposed for C-15 (assert the
    /// reward seam is present and defaulted to the recall-trace source).
    public func rewardSourceKind() -> RewardSourceKind { rewardSource.kind }

    // MARK: - Tick driving

    /// Run one cycle iff the trigger-mode timer condition is satisfied.
    ///
    /// - **`.timer`** and **`.hybrid`**: fires when `tickIntervalMs` has
    ///   elapsed since the last TIMER fire (C-1 ±10% jitter allowed), or on
    ///   the first call when no prior timer tick exists. Returns `nil` when
    ///   the interval has not elapsed. Sets `lastTickAt` on fire so the
    ///   cadence tracks only timer fires.
    /// - **`.event`**: the timer path is inactive for this mode. Returns
    ///   `nil` unconditionally; use `pumpOnEvent(observationCount:now:)` to
    ///   trigger event-mode cycles.
    ///
    /// The caller advances `now` from its own clock; the daemon performs
    /// no sleeping. Conformance C-1 allows ±10% jitter on the cadence.
    public func pump(now: Date) async throws -> DreamingCycleReport? {
        // `.event` mode: timer path is inactive. The caller must use
        // `pumpOnEvent` to drive this mode — a timer that fires for an
        // event-only mode would make `.event` an alias for `.timer`,
        // violating the mode-naming contract.
        guard triggerMode != .event else { return nil }

        if let last = lastTickAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000.0
            guard elapsedMs >= Double(policy.tickIntervalMs) else { return nil }
        }
        // Advance the timer baseline AT THE CADENCE GATE — before running the
        // cycle — so a failed cycle (one that throws) does not leave lastTickAt
        // nil and cause the next pump call to fire again immediately. A skipped
        // or failed cadence slot is still consumed: the interval resets from
        // `now`, preventing a rapid-retry hammering of the substrate on repeated
        // errors. Event-path fires (pumpOnEvent) do NOT update lastTickAt —
        // the two paths are fully independent.
        lastTickAt = now
        let report = try await runCycle(now: now)
        return report
    }

    /// Run one cycle iff the trigger-mode event condition is satisfied.
    ///
    /// - **`.event`**: fires when `observationCount` is at or above
    ///   `policy.eventObservationThreshold`, indicating the estate has
    ///   accumulated sufficient new activity (co-occurrence observations)
    ///   to warrant dreaming. Returns `nil` when below threshold.
    /// - **`.hybrid`**: fires on the event condition in addition to the
    ///   timer path in `pump`. Allows the same daemon to fire from either
    ///   source so neither signal is missed.
    /// - **`.timer`**: the event path is inactive for this mode. Returns
    ///   `nil` unconditionally; use `pump(now:)` instead.
    ///
    /// The caller derives `observationCount` by calling
    /// `DreamingSubstrateReader.coOccurrenceObservations()` and passing
    /// the count; this keeps the seam contract intact (the daemon itself
    /// calls the reader inside `runCycle`).
    ///
    /// - Parameters:
    ///   - observationCount: the current co-occurrence observation count
    ///     from the estate reader, used to gate the event threshold.
    ///   - now: deterministic clock supplied by the caller.
    /// - Returns: a `DreamingCycleReport` when the cycle fires, `nil`
    ///   when the event threshold is not met or the mode is `.timer`.
    public func pumpOnEvent(observationCount: Int, now: Date) async throws -> DreamingCycleReport? {
        // `.timer` mode: event path is inactive. The caller must use
        // `pump(now:)` to drive this mode.
        guard triggerMode != .timer else { return nil }

        // Fire when the observation count meets or exceeds the threshold —
        // the estate has accumulated enough activity to warrant dreaming.
        guard observationCount >= policy.eventObservationThreshold else { return nil }

        return try await runCycle(now: now)
    }

    /// Run one cycle on demand, regardless of the timer or event threshold
    /// (§ 3.1 `triggerDreamingCycle()`). `now` is explicit for determinism
    /// per CLAUDE.md; the spec's no-argument signature cannot satisfy the
    /// "never call Date() in an engine" rule.
    ///
    /// On-demand fires update `lastTickAt` (the timer baseline) so the next
    /// `pump` call measures cadence from this moment. This matches the
    /// spec's intent: an explicit trigger resets the autonomic schedule.
    @discardableResult
    public func triggerDreamingCycle(now: Date) async throws -> DreamingCycleReport {
        let report = try await runCycle(now: now)
        lastTickAt = now
        return report
    }

    // MARK: - The seven-step tick (§ 3.1)

    private func runCycle(now: Date) async throws -> DreamingCycleReport {
        // Emit cycle-start event. The ts is the caller-supplied `now` converted
        // to epoch seconds — deterministic; no clock called here. When monitoring
        // is off (the default), the autoclosure is never evaluated.
        // `neuronkit.dream.cycle` with status "start" marks the boundary where
        // the daemon begins reading the substrate (Activity view, GUI §4.4).
        let cycleStartTs = now.timeIntervalSince1970
        Intellectus.report(.metric(
            name: "neuronkit.dream.cycle",
            value: 1.0,
            tags: ["status": "start", "cycle": "\(cycleCount + 1)"],
            ts: cycleStartTs
        ))

        // ── Step 1: reward retrieval via the RewardSource seam ──────────
        // The reward source is caller-supplied (default RecallTraceRewardSource,
        // implicit). Callers that have explicit diary rewards can wire
        // ExplicitDiaryRewardSource instead (NEURONKIT_SPEC § 3.1 step 1a).
        // Both sources implement the same `RewardSource` protocol so this
        // loop is source-agnostic.
        let windowSeconds = Double(policy.tickIntervalMs) / 1000.0
        let since = now.addingTimeInterval(-windowSeconds)
        let traces = try await reader.recentRecallTraces(since: since, now: now)
        var rewardByTarget: [RowID: Float] = [:]
        for trace in traces {
            let r = rewardSource.reward(for: trace)
            // Keep the strongest signal per target: a row used at least
            // once counts as used for reward purposes.
            rewardByTarget[trace.target] = max(rewardByTarget[trace.target] ?? 0, r)
        }

        // ── Post-step-1 prune: delete trace rows older than the retention
        // window so the table does not accumulate unboundedly. The retention
        // constant is in calendar days; the cutoff is derived from `now`
        // (never from Date()) per the deterministic-engine rule.
        //
        // recallTraceRetentionDays = 30: a month of reward signal is sufficient
        // for Bradley-Terry convergence; rows older than this are stale and
        // will never enter a future reward window. Discarded silently so a
        // storage fault does not abort the cycle.
        let recallTraceRetentionDays: Double = 30
        let pruneCutoff = now.addingTimeInterval(-recallTraceRetentionDays * 86400)
        _ = try? await sink.pruneRecallTraces(olderThan: pruneCutoff)

        // ── Step 2: extract latent co-occurrence candidates ────────────
        let observations = try await reader.coOccurrenceObservations()

        // ── Step 5 (prep): existing Tunnel keys for duplicate suppression
        let tunnelKeys = Set(try await reader.existingTunnels().compactMap(Self.tunnelKey))

        // ── Steps 3–6: delegate every DECISION to the pure core ────────
        // The actor only gathers seam inputs and enacts the result; the
        // contrastive score, EWC++ blend, duplicate suppression, and
        // confidence-AND-attempts gate all live in `DreamingDecision` so
        // the math is portable and conformance-gated against the Rust version
        // (NeuronKit/rust/src/dreaming_decision.rs). See DreamingDecision.swift.
        let outcome = DreamingDecision.decide(
            observations: observations.map {
                DreamingDecision.Observation(
                    endpointA: $0.endpointA,
                    endpointB: $0.endpointB,
                    attempts: $0.attempts,
                    evidenceTargets: $0.evidenceTargets)
            },
            rewardByTarget: rewardByTarget,
            existingTunnelKeys: tunnelKeys,
            alreadyProposedKeys: proposedKeys,
            consolidated: consolidated,
            minConfidence: policy.minConfidence,
            minAttempts: policy.minAttempts,
            minSuccessRate: policy.minSuccessRate
        )

        // Fold the core's decisions back into actor state and the substrate.
        // `updatedConsolidated` covers every observation considered (EWC++
        // retains scores that did not clear the gate); `emitted` is in the
        // observations' order, so proposals are issued deterministically.
        consolidated = outcome.updatedConsolidated
        let scores = outcome.scores
        let suppressedDuplicates = outcome.suppressedDuplicates
        let belowThreshold = outcome.belowThreshold

        var emitted: [ProposeFrame] = []
        for candidate in outcome.emitted {
            let frame = ProposeFrame(
                target: candidate.endpointA,
                kind: .miningPattern,
                justification:
                    "dreaming: latent alignment \(candidate.endpointA)↔\(candidate.endpointB) "
                    + "(attempts \(candidate.attempts), confidence \(candidate.confidence))"
            )
            try await sink.propose(frame)
            proposedKeys.insert(candidate.key)
            emitted.append(frame)
        }

        // ── Step 7: write exactly one diary entry recording the cycle ───
        cycleCount += 1
        let entry = DiaryEntry(
            agentName: Self.agentName,
            entry: "dreaming cycle \(cycleCount): considered \(observations.count), "
                + "proposed \(emitted.count), suppressed \(suppressedDuplicates), "
                + "below-threshold \(belowThreshold)",
            topic: "dreaming-cycle",
            wing: Self.diaryWing,
            room: "diary",
            filedAt: now,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)

        // Emit cycle-complete event. `drawers_touched` is the number of
        // co-occurrence observations considered (the substrate rows the daemon
        // mined this cycle). `proposals` is the emission count. Both are
        // metadata-only — no drawer content crosses the telemetry boundary.
        // `neuronkit.dream.cycle` with status "complete" closes the boundary
        // pair opened by the "start" event above (GUI §4.4 Activity: blue
        // recall-class lexicon, dreaming-daemon cycle).
        Intellectus.report(.metric(
            name: "neuronkit.dream.cycle",
            value: Double(emitted.count),
            tags: [
                "status": "complete",
                "cycle": "\(cycleCount)",
                "drawers_touched": "\(observations.count)",
                "proposals": "\(emitted.count)",
            ],
            ts: now.timeIntervalSince1970
        ))

        // ── Auto-reindex step: trigger corpus basis retrain on growth ──────
        // Distributional embedding providers (RI / PPMI / LSA / NMF) freeze
        // their vocabulary at training time. Content ingested after the last
        // retrain is OOV and produces zero-vectors in the dense lane, silently
        // missing novel terms. The growth probe measures the live chunk count
        // and fires a full `Corpus.reindex(now:)` when growth since the last
        // retrain crosses `reindexGrowthThreshold` (default 25 chunks).
        //
        // Idempotency / safety:
        //   • On the first cycle, `lastReindexChunkCount == -1` (sentinel).
        //     We read the live count and store it as the baseline WITHOUT firing
        //     a retrain — the corpus was just trained on first ingest, or it was
        //     opened from a persisted basis. Firing on the first cycle would
        //     unconditionally retrain on every daemon restart, which is wasteful.
        //   • After baseline is set, the gate fires when delta >= threshold.
        //     After firing, `lastReindexChunkCount` advances to the post-reindex
        //     live count so the next window resets correctly.
        //   • Reindex failures are caught and logged (OSLog) but do not abort
        //     the cycle — a stale basis is better than a broken dreaming daemon.
        //   • When no probe is injected (nil), this block is a no-op.
        if let probe = growthProbe {
            do {
                let liveCount = try await probe.chunkCount()
                if lastReindexChunkCount == -1 {
                    // First cycle: establish baseline. No retrain.
                    lastReindexChunkCount = liveCount
                } else if liveCount - lastReindexChunkCount >= reindexGrowthThreshold {
                    // Growth threshold crossed — retrain the basis so dense recall
                    // vocabulary stays current with ingested content.
                    Intellectus.report(.metric(
                        name: "neuronkit.dream.auto_reindex",
                        value: Double(liveCount - lastReindexChunkCount),
                        tags: [
                            "cycle": "\(cycleCount)",
                            "live_chunks": "\(liveCount)",
                            "since_last_reindex": "\(liveCount - lastReindexChunkCount)",
                            "threshold": "\(reindexGrowthThreshold)",
                        ],
                        ts: now.timeIntervalSince1970
                    ))
                    try await probe.reindex(now: now)
                    // Advance baseline to the count at retrain time so the next
                    // window measures growth from this retrain, not the original.
                    lastReindexChunkCount = liveCount
                }
            } catch {
                // Reindex failure (storage error, stale handle, etc.) is non-fatal.
                // Log at error level so operators can investigate, but the cycle
                // continues — a stale basis degrades recall, it does not break the
                // daemon's proposal and diary functions.
                Intellectus.report(.metric(
                    name: "neuronkit.dream.auto_reindex_error",
                    value: 1.0,
                    tags: ["cycle": "\(cycleCount)", "error": "\(error)"],
                    ts: now.timeIntervalSince1970
                ))
            }
        }

        // ── Bandit reward observation and re-selection (NEURONKIT_SPEC § 3.4) ─
        // Reward is the mean recall-trace reward this cycle: high when callers
        // acted on the substrate state the trigger mode surfaced (used → 1.0),
        // low when the substrate returned rows no one acted on (unused → 0.0).
        // An empty reward window (no recall traces) gets a neutral 0.5 so the
        // arm is neither credited nor penalised.
        let cycleReward: Double
        if rewardByTarget.isEmpty {
            cycleReward = 0.5
        } else {
            let sum = rewardByTarget.values.reduce(0.0) { $0 + Double($1) }
            cycleReward = sum / Double(rewardByTarget.count)
        }
        bandit.observe(arm: triggerMode, reward: cycleReward)
        // Re-select the trigger mode for the next cycle. The seed is derived
        // from the cycle timestamp's bit pattern — deterministic for the same
        // `now`, the same pattern as SpreadingActivation's walk seed.
        let banditSeed = UInt64(bitPattern: Int64(now.timeIntervalSince1970 * 1_000))
        triggerMode = bandit.select(seed: banditSeed)
        try await policyStore.saveBandit(bandit)

        // `lastTickAt` is NOT updated here — the calling path (pump vs
        // pumpOnEvent) is responsible: the timer path sets `lastTickAt` so
        // the cadence tracks only timer fires; the event path leaves it
        // unchanged so event fires in `.hybrid` mode do not reset the
        // timer countdown. The two paths are fully independent.
        return DreamingCycleReport(
            tickedAt: now,
            candidatesConsidered: observations.count,
            proposalsEmitted: emitted,
            suppressedDuplicates: suppressedDuplicates,
            belowThreshold: belowThreshold,
            candidateScores: scores,
            rewardByTarget: rewardByTarget,
            diaryEntry: entry
        )
    }

    // MARK: - Pure helpers (deterministic; Rust version matches)

    /// The agent name the cycle diary entries are filed under.
    static let agentName = "dreaming-daemon"

    /// The wing the cycle diary entries are filed under, following the
    /// `wing_<agentName>` convention DiaryEntry documents.
    static let diaryWing = "wing_dreaming-daemon"

    /// Canonical, order-independent key for a candidate endpoint pair, so
    /// A↔B and B↔A collapse to one candidate (matches the Tunnel
    /// symmetric-id spirit). Delegates to the portable `DreamingDecision`
    /// core so the actor and the Rust version share one definition.
    static func candidateKey(_ a: RowID, _ b: RowID) -> String {
        DreamingDecision.candidateKey(a, b)
    }

    /// Candidate key for an existing Tunnel, or `nil` when the tunnel is
    /// not a drawer-to-drawer link (room-level tunnels have nil drawer
    /// ids and cannot duplicate a drawer-pair candidate).
    static func tunnelKey(_ tunnel: Tunnel) -> String? {
        guard let a = tunnel.sourceDrawerId, let b = tunnel.targetDrawerId else { return nil }
        return candidateKey(a, b)
    }

    /// InfoNCE-inspired contrastive confidence in `[0, 1]` (step 3).
    ///
    /// The positive logit is the mean derived reward of the candidate's
    /// evidence targets; the negative logit is the `minSuccessRate`
    /// baseline. A two-way softmax over (positive, negative) at
    /// `temperature` gives the confidence — high when the candidate's
    /// rows were acted on (reward near 1), low when they were ignored
    /// (reward near 0). A candidate with no evidence scores 0. Delegates to
    /// the portable `DreamingDecision` core (Rust-parity Bucket A), the
    /// single definition shared with `dreaming_decision.rs`.
    static func contrastiveConfidence(
        evidenceTargets: [RowID],
        rewardByTarget: [RowID: Float],
        baseline: Float
    ) -> Float {
        DreamingDecision.contrastiveConfidence(
            evidenceTargets: evidenceTargets,
            rewardByTarget: rewardByTarget,
            baseline: baseline)
    }
}
