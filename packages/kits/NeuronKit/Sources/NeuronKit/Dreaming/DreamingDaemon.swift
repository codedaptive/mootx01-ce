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
// write surface. But the current GLK verb surface cannot satisfy this
// daemon's substrate needs: `propose` throws
// `VerbError.notSupportedByEstate` (Brain layer not present,
// VerbSurface.swift:198), and there is no estate verb that reads
// RecallTraceItem rows, reads existing Tunnels, or writes a DiaryEntry.
// So the daemon depends on NeuronKit-owned seam protocols
// (`DreamingSubstrateReader` for reads, `DreamingProposalSink` for the
// two write kinds, `DreamingPolicyStore` for the manifest-resident
// policy, `RewardSource` for the reward signal). The production adapter
// that binds these seams to real estate verbs lands when the GLK Brain
// layer ships — exactly the staged posture of the GLK `DreamingSignal`
// scaffold, which today emits canned shapes for the same reason. The
// daemon references the substrate VALUE types (RecallTraceItem,
// DiaryEntry, Tunnel, ProposeFrame) but calls no substrate method, so
// B-1 holds.
//
// ── Determinism ───────────────────────────────────────────────────────
// Per CLAUDE.md every computation is deterministic: the daemon never
// calls `Date()` internally. The caller passes `now` into every cycle
// and pump. The conformance tests drive an injected clock by advancing
// the `now` they pass; there are no wall-clock sleeps anywhere.

import Foundation
import GeniusLocusKit
import LocusKit

/// Read surface the dreaming daemon mines (NEURONKIT_SPEC § 3.1 tick
/// steps 1–2 and 5). Net-new seam; the production adapter binds it to
/// estate reads when the GLK surface exposes them. All three reads are
/// pure inputs — the daemon mutates nothing through this protocol.
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
/// exactly two operations — emit a proposal, and record the cycle diary
/// entry — and deliberately has NO Tunnel-creation method, which is how
/// the never-create-Tunnels invariant is enforced structurally: the
/// daemon cannot create a Tunnel because nothing it can reach does.
///
/// The production adapter implements `propose(_:)` by forwarding to the
/// estate handle's `propose` verb (the legal B-1 write path) once the GLK
/// Brain layer makes that verb live.
public protocol DreamingProposalSink: Sendable {

    /// Emit a proposal for a novel candidate alignment (step 6). Maps to
    /// the estate `propose` verb in production.
    func propose(_ frame: ProposeFrame) async throws

    /// Record exactly one diary entry summarising the cycle (step 7).
    func recordCycleDiary(_ entry: DiaryEntry) async throws
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

    // MARK: - Mutable state (actor-isolated)

    /// Current discovery parameters. Mutated by `registerDreamingPolicy`,
    /// persisted through `policyStore`.
    private var policy: DreamingPolicy

    /// The trigger mode seam (default `.timer`). Carries no SolverBandit
    /// dependency; NK-BANDIT attaches here later.
    private let triggerMode: DreamingTriggerMode

    /// Last cycle time, for the tick-cadence decision in `pump`.
    private var lastTickAt: Date?

    /// Candidate keys already proposed in a prior cycle. The idempotency
    /// memory (B-4): a key here is never proposed again.
    private var proposedKeys: Set<String> = []

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
    public init(
        reader: DreamingSubstrateReader,
        sink: DreamingProposalSink,
        rewardSource: RewardSource = RecallTraceRewardSource(),
        policyStore: DreamingPolicyStore,
        triggerMode: DreamingTriggerMode = .default,
        policy: DreamingPolicy = .default
    ) {
        self.reader = reader
        self.sink = sink
        self.rewardSource = rewardSource
        self.policyStore = policyStore
        self.triggerMode = triggerMode
        self.policy = policy
    }

    // MARK: - Policy registration (§ 3.1 registration API)

    /// Register the dreaming discovery parameters and persist them to the
    /// manifest seam. Spec defaults match NEURONKIT_SPEC § 3.1.
    public func registerDreamingPolicy(
        minSuccessRate: Float = 0.6,
        minConfidence: Float = 0.7,
        minAttempts: Int = 3,
        tickIntervalMs: Int = 30_000
    ) async throws {
        let next = DreamingPolicy(
            minSuccessRate: minSuccessRate,
            minConfidence: minConfidence,
            minAttempts: minAttempts,
            tickIntervalMs: tickIntervalMs
        )
        policy = next
        try await policyStore.savePolicy(next)
    }

    /// Load the persisted policy from the manifest seam, if any, replacing
    /// the in-memory policy. Call once after construction to pick up a
    /// policy a prior run registered.
    public func loadPersistedPolicy() async throws {
        if let stored = try await policyStore.loadPolicy() {
            policy = stored
        }
    }

    /// The current policy. Exposed for the manifest round-trip test.
    public func currentPolicy() -> DreamingPolicy { policy }

    /// The configured trigger mode. Exposed so callers can confirm the
    /// v1 default with no SolverBandit dependency.
    public func currentTriggerMode() -> DreamingTriggerMode { triggerMode }

    /// The wired reward source's kind. Exposed for C-15 (assert the
    /// reward seam is present and defaulted to the recall-trace source).
    public func rewardSourceKind() -> RewardSourceKind { rewardSource.kind }

    // MARK: - Tick driving

    /// Run one cycle iff the configured tick interval has elapsed since
    /// the last cycle (the autonomic timer path, § 3.1). Returns the
    /// cycle report when it fires, or `nil` when the interval has not yet
    /// elapsed. The caller advances `now` from its own clock; the daemon
    /// performs no sleeping. The first pump (no prior tick) always fires.
    ///
    /// Conformance C-1 allows ±10% jitter on the cadence; this scheduler
    /// fires as soon as the full interval has elapsed, so the realised
    /// spacing equals the configured interval (well within tolerance).
    public func pump(now: Date) async throws -> DreamingCycleReport? {
        if let last = lastTickAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000.0
            guard elapsedMs >= Double(policy.tickIntervalMs) else { return nil }
        }
        return try await runCycle(now: now)
    }

    /// Run one cycle on demand, regardless of the timer (§ 3.1
    /// `triggerDreamingCycle()`). `now` is explicit for determinism per
    /// CLAUDE.md; the spec's no-argument signature cannot satisfy the
    /// "never call Date() in an engine" rule.
    @discardableResult
    public func triggerDreamingCycle(now: Date) async throws -> DreamingCycleReport {
        try await runCycle(now: now)
    }

    // MARK: - The seven-step tick (§ 3.1)

    private func runCycle(now: Date) async throws -> DreamingCycleReport {
        // ── Step 1: reward retrieval via the RewardSource seam ──────────
        // v1 single-source: recent RecallTraceItem rows, mapped through
        // the reward source (used → 1.0, unused → 0.0). The explicit
        // DiaryEntry.reward source is the seam's documented future second
        // input; it is NOT read here (the field does not exist yet).
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

        // ── Step 2: extract latent co-occurrence candidates ────────────
        let observations = try await reader.coOccurrenceObservations()

        // ── Step 5 (prep): existing Tunnel keys for duplicate suppression
        let tunnelKeys = Set(try await reader.existingTunnels().compactMap(Self.tunnelKey))

        // ── Steps 3–6: delegate every DECISION to the pure core ────────
        // The actor only gathers seam inputs and enacts the result; the
        // contrastive score, EWC++ blend, duplicate suppression, and
        // confidence-AND-attempts gate all live in `DreamingDecision` so
        // the math is portable and conformance-gated against the Rust port
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

        lastTickAt = now
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

    // MARK: - Pure helpers (deterministic; Rust port matches)

    /// The agent name the cycle diary entries are filed under.
    static let agentName = "dreaming-daemon"

    /// The wing the cycle diary entries are filed under, following the
    /// `wing_<agentName>` convention DiaryEntry documents.
    static let diaryWing = "wing_dreaming-daemon"

    /// Canonical, order-independent key for a candidate endpoint pair, so
    /// A↔B and B↔A collapse to one candidate (matches the Tunnel
    /// symmetric-id spirit). Delegates to the portable `DreamingDecision`
    /// core so the actor and the Rust port share one definition.
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
