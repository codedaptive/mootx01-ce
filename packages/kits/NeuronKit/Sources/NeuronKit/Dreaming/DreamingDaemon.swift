// DreamingDaemon.swift
//
// The dreaming daemon (NEURONKIT_SPEC § 3.1). Mines substrate state for
// latent associations the user has not explicitly made and PROPOSES
// Tunnel nouns for novel alignments clearing a confidence threshold. It
// never creates Tunnels directly (§ 3.1 invariant) — the human confirms
// via the `associate` verb. It is autonomic: it ticks on a schedule and
// on demand. Its write surface (DreamingProposalSink) covers proposals,
// diary entries, recall-trace pruning, and dreamed-tunnel retirement (OMEGA).
//
// ── Why this daemon talks to seams, not to GLK verbs ──────────────────
// MOOTx01 invariant B-1: NeuronKit never executes SQL and never calls
// LocusKit / VectorKit / CorpusKit directly; the estate handle is the only
// write surface. Even with `propose` now live (Brain layer landed in
// GLK-02), no estate verb reads RecallTraceItem rows, reads existing
// Tunnels, or writes a DiaryEntry. So the daemon depends on
// NeuronKit-owned seam protocols (`DreamingSubstrateReader` for reads,
// `DreamingProposalSink` for writes (proposals, diary, trace-prune, retire),
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

    /// Drained dreaming-queue windows for the estate (step 2). Each inner
    /// array is the set of drawer IDs from one `DreamingItem` — a single
    /// recall event that co-recalled ≥ 2 distinct drawers. The daemon
    /// enumerates all distinct pairs within each window and bumps
    /// `coRecallCounts` once per pair per window, so counts accumulate
    /// across drain events. The adapter delegates to
    /// `GeniusLocusKit.drainDreamingItems(for:)`, which drains the
    /// estate's dreaming queue and replies Done to consumed jobs.
    func drainDreamingWindow() async throws -> [[String]]

    /// Existing Tunnel nouns, consulted to suppress candidates that duplicate
    /// an alignment the substrate already records (step 5).
    func existingTunnels() async throws -> [Tunnel]

    /// All non-retired tunnels whose `isDreamed` bit is set.
    ///
    /// OMEGA calls this to enumerate the active dreamed-tunnel population.
    /// The retire predicate is: `isDreamed AND not reinforced by recall in the
    /// OMEGA window`. Declared tunnels (`isDreamed == false`) are never returned
    /// and are therefore never retired (§ 12.8 guard). Retired tunnels are excluded
    /// so they do not appear in both the retire sweep and the suppression set.
    func dreamedActiveTunnels() async throws -> [Tunnel]
}

/// Write surface the dreaming daemon emits through (NEURONKIT_SPEC § 3.1
/// tick steps 6–7). This is the daemon's ONLY write path. It exposes
/// four operations — emit a proposal, record the cycle diary entry,
/// prune stale recall-trace rows after the reward sweep, and retire
/// unreinforced dreamed tunnels (OMEGA / T13) — and deliberately has NO
/// Tunnel-creation method, which is how the never-create-Tunnels invariant
/// is enforced structurally: the daemon cannot create a Tunnel because
/// nothing it can reach does.
///
/// `EstateDreamingSink` is the production adapter; it implements
/// `propose(_:)` by forwarding to the estate handle's `propose` verb
/// (the legal B-1 write path), `recordCycleDiary(_:)` by forwarding
/// to `addDiaryEntry`, `pruneRecallTraces(olderThan:)` by forwarding
/// to `GeniusLocusKit.pruneRecallTraces(in:olderThan:)`, and
/// `retireTunnel(id:changedBy:now:)` by forwarding to the GLK tunnel-
/// retirement verb.
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

    /// Retire a tunnel by flipping bit 13 of its `operationalBitmap`.
    ///
    /// Called by OMEGA after determining that the dreamed tunnel is unreinforced
    /// within the OMEGA window. The tunnel is removed from active reads but
    /// preserved for audit — reversible if future co-recall reinforces it again.
    /// Implementations that do not persist tunnels (e.g. in-memory test fakes)
    /// may no-op or track the call for test inspection.
    ///
    /// - Parameters:
    ///   - id:        the tunnel row id to retire.
    ///   - changedBy: agent name performing the retirement.
    ///   - now:       deterministic clock value from the caller.
    func retireTunnel(id: String, changedBy: String, now: Date) async throws
}

// MARK: - Protocol default implementations for test-fake compatibility

/// Default implementations so that existing test fakes (which pre-date T13)
/// continue to compile without modification. Production adapters
/// (`EstateDreamingReader`, `EstateDreamingSink`) provide real implementations.
public extension DreamingSubstrateReader {
    /// Default: return empty — fakes that do not set up dreamed tunnels get
    /// a no-op OMEGA sweep (nothing to retire). Override in production adapter.
    func dreamedActiveTunnels() async throws -> [Tunnel] { [] }
}

public extension DreamingProposalSink {
    /// Default: no-op — fakes that do not test OMEGA retirement do not need
    /// to track retired tunnels. Override in production adapter.
    func retireTunnel(id: String, changedBy: String, now: Date) async throws {}
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
    /// the daemon measures VOCABULARY growth at the end of each cycle and triggers
    /// `CorpusGrowthProbe.reindex(now:)` when growth since the last retrain
    /// crosses the vocab-growth fraction/floor. Nil disables auto-reindex (correct
    /// for test environments that do not wire a live Corpus).
    private let growthProbe: (any CorpusGrowthProbe)?

    /// Fractional vocabulary growth above which the daemon triggers a corpus
    /// basis retrain. Defaults to `autoReindexVocabGrowthFraction` (0.10). See
    /// that constant for the vocabulary-drift rationale.
    private let reindexVocabGrowthFraction: Double

    /// Absolute floor on new vocabulary terms before a retrain, regardless of the
    /// fraction. Defaults to `autoReindexVocabGrowthFloor` (25 terms).
    private let reindexVocabGrowthFloor: Int

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
    /// and re-selects. Persisted by the daemon after each cycle via
    /// `policyStore.saveBandit(bandit)`; restored on restart via
    /// `policyStore.loadBandit()`.
    private var bandit: SolverBandit

    /// Last timer-path cycle time, for the tick-cadence decision in `pump`.
    /// Tracks only timer-triggered fires so event-path fires in `.hybrid`
    /// mode do not reset the timer countdown; the two paths are independent.
    private var lastTickAt: Date?

    /// Candidate keys already proposed in a prior cycle. The idempotency
    /// memory (B-4): a key here is never proposed again.
    private var proposedKeys: Set<String> = []

    /// Vocabulary size at the time of the most recent corpus basis retrain (or
    /// at daemon initialisation, whichever is later). The auto-reindex gate fires
    /// when `liveVocab − lastReindexVocab` crosses the vocab-growth fraction/floor.
    /// Initialised to −1 (sentinel) so the first cycle always reads the live
    /// vocabulary and establishes the baseline before any threshold comparison.
    private var lastReindexVocab: Int = -1

    /// EWC++ consolidated confidence by candidate key (step 4).
    private var consolidated: [String: Float] = [:]

    /// Number of cycles run. Recorded in the cycle diary entry.
    private var cycleCount: Int = 0

    /// Per-pair co-recall counts: how many distinct recall events have co-recalled
    /// the drawer pair (a, b). Keyed by the canonical pair key (same "min|max"
    /// format as `consolidated` and `proposedKeys`). Bumped by T8 drain — not
    /// by this module — via `bumpCoRecall(_:_:)`. Consumed by T8 decide for the
    /// `minAttempts` gate. Persisted through `DreamingDaemonState.coRecallCounts`
    /// so counts survive daemon restarts via the governor's F6 persist path.
    private var coRecallCounts: [String: Int] = [:]

    // MARK: - Periodic cycle last-run timestamps (REM dispatch table — T11)

    /// Wall-clock instant of the last REM-THETA (daily consolidation) run.
    /// Nil = never run. The dispatch table's THETA due-check gates on
    /// `now >= lastThetaRunAt + 24 h` (D5a cadence). Persisted in
    /// `DreamingDaemonState.lastThetaRunAt` via the /manifest-backed daemon state path so the
    /// gate survives restarts (D5c: stdio-only estates consolidate lazily on
    /// invocation, not on a clock). Mirrors Rust `last_theta_run_secs`.
    private var lastThetaRunAt: Date? = nil

    /// Wall-clock instant of the last REM-BETA (weekly prune) run.
    /// Nil = never run. `runBetaCycle` (T12) is live. Persisted
    /// alongside THETA and OMEGA.
    private var lastBetaRunAt: Date? = nil

    /// Wall-clock instant of the last REM-OMEGA (biweekly retire) run.
    /// Nil = never run. `runOmegaCycle` (T13) is live. Persisted
    /// alongside THETA and BETA.
    private var lastOmegaRunAt: Date? = nil

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
    ///     step. When non-nil, each cycle measures vocabulary growth and
    ///     triggers a basis retrain when growth crosses the fraction/floor.
    ///     Defaults to nil (auto-reindex disabled). Production callers pass
    ///     an `EstateCorpusGrowthProbe` to light the auto-reindex lane.
    ///   - reindexVocabGrowthFraction: fractional vocabulary growth above which a
    ///     corpus basis retrain is triggered. Defaults to
    ///     `autoReindexVocabGrowthFraction` (0.10).
    ///   - reindexVocabGrowthFloor: absolute floor on new vocabulary terms before
    ///     a retrain, regardless of the fraction. Defaults to
    ///     `autoReindexVocabGrowthFloor` (25 terms).
    public init(
        reader: DreamingSubstrateReader,
        sink: DreamingProposalSink,
        rewardSource: RewardSource = RecallTraceRewardSource(),
        policyStore: DreamingPolicyStore,
        triggerMode: DreamingTriggerMode = .default,
        bandit: SolverBandit = SolverBandit(),
        policy: DreamingPolicy = .default,
        growthProbe: (any CorpusGrowthProbe)? = nil,
        reindexVocabGrowthFraction: Double = autoReindexVocabGrowthFraction,
        reindexVocabGrowthFloor: Int = autoReindexVocabGrowthFloor
    ) {
        self.reader = reader
        self.sink = sink
        self.rewardSource = rewardSource
        self.policyStore = policyStore
        self.triggerMode = triggerMode
        self.bandit = bandit
        self.policy = policy
        self.growthProbe = growthProbe
        self.reindexVocabGrowthFraction = reindexVocabGrowthFraction
        self.reindexVocabGrowthFloor = reindexVocabGrowthFloor
    }

    // MARK: - Policy registration (§ 3.1 registration API)

    /// Register the dreaming discovery parameters and persist them to the
    /// manifest seam. Spec defaults match NEURONKIT_SPEC § 3.1.
    ///
    /// - Parameters:
    ///   - minSuccessRate: reward threshold above which a row is a success. Default 0.6.
    ///   - minConfidence: minimum contrastive confidence to propose. Default 0.7.
    ///   - minAttempts: minimum co-recall count to be eligible. Default 3.
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
            // Guard: a malformed persisted bandit (wrong arm count) could crash
            // select() on arms[0] or silently drop trigger modes. SolverBandit's
            // custom Decodable already resets to a uniform prior in that case,
            // but validate the arm count explicitly before assigning to actor
            // state so even a programmatically-constructed invalid bandit is
            // rejected. A zero-arm bandit must never replace the in-memory prior.
            if stored.arms.count == DreamingTriggerMode.allCases.count {
                bandit = stored
            }
            // else: malformed persisted bandit — keep the in-memory uniform prior
        }
        //  / manifest-backed daemon state: restore the daemon's idempotency/cycle memory so a restart
        // does not re-propose already-proposed candidates, re-consolidate, or reset
        // the cycle counter. Absent state leaves the in-memory defaults in place.
        // T11: also restore the periodic-cycle last-run timestamps so THETA/BETA/OMEGA
        // cadences gate correctly after a restart (D5c: stdio-only estates consolidate
        // lazily on invocation using these persisted timestamps).
        if let state = try await policyStore.loadDaemonState() {
            lastTickAt = state.lastTickAt
            proposedKeys = Set(state.proposedKeys)
            lastReindexVocab = state.lastReindexVocab
            consolidated = state.consolidated
            cycleCount = state.cycleCount
            coRecallCounts = state.coRecallCounts
            lastThetaRunAt = state.lastThetaRunAt
            lastBetaRunAt = state.lastBetaRunAt
            lastOmegaRunAt = state.lastOmegaRunAt
        }
    }

    /// Snapshot the current daemon cycle state for persistence. `proposedKeys`
    /// is emitted sorted so the serialized manifest value is byte-stable.
    /// Includes the T11 periodic-cycle last-run timestamps so THETA/BETA/OMEGA
    /// cadences survive restarts (D5c). Mirrors Rust `DreamingDaemon::daemon_state`.
    private func currentDaemonState() -> DreamingDaemonState {
        DreamingDaemonState(
            lastTickAt: lastTickAt,
            proposedKeys: proposedKeys.sorted(),
            lastReindexVocab: lastReindexVocab,
            consolidated: consolidated,
            cycleCount: cycleCount,
            coRecallCounts: coRecallCounts,
            lastThetaRunAt: lastThetaRunAt,
            lastBetaRunAt: lastBetaRunAt,
            lastOmegaRunAt: lastOmegaRunAt
        )
    }

    /// Testable snapshot accessor — exposes `currentDaemonState()` to
    /// `@testable import NeuronKit` test targets so the persistence round-trip
    /// (CR-4) can assert that co-recall counts and other cycle-state fields are
    /// correctly serialized without running a full dreaming cycle.
    func currentDaemonState_testOnly() -> DreamingDaemonState {
        currentDaemonState()
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

    // MARK: - Co-recall counts (NEURONKIT_SPEC § 12.4)

    /// Increment the co-recall count for the canonical pair (a, b) by 1.
    ///
    /// The pair is canonicalized order-independently: whichever endpoint
    /// sorts lower lexicographically is placed first, so
    /// `bumpCoRecall("x", "y")` and `bumpCoRecall("y", "x")` update the
    /// same counter. The canonical key format is `"min|max"`, identical to
    /// `DreamingDecision.candidateKey` used for `consolidated` and
    /// `proposedKeys`.
    ///
    /// Each call is one increment — the caller (T8 drain) is responsible
    /// for calling once per distinct recall event. The count is persisted
    /// in `DreamingDaemonState.coRecallCounts` via the governor's F6 path.
    /// Mirrors Rust `DreamingDaemon::bump_co_recall`.
    public func bumpCoRecall(_ a: String, _ b: String) {
        let key = DreamingDecision.candidateKey(a, b)
        coRecallCounts[key, default: 0] += 1
    }

    /// Return the co-recall count for the canonical pair (a, b).
    ///
    /// Returns 0 when the pair has not been co-recalled yet. The lookup is
    /// order-independent: `coRecallCount("x", "y")` and
    /// `coRecallCount("y", "x")` return the same value. Consumed by T8
    /// (not this module) for the `minAttempts` gate.
    /// Mirrors Rust `DreamingDaemon::co_recall_count`.
    public func coRecallCount(_ a: String, _ b: String) -> Int {
        let key = DreamingDecision.candidateKey(a, b)
        return coRecallCounts[key] ?? 0
    }

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
    /// Cheap predicate: would the timer path of `pump(now:)` fire at `now`?
    ///
    /// Lets the resident governor SKIP building the (expensive) substrate-reader
    /// snapshot on ticks where the timer interval has not elapsed. Without this,
    /// the governor builds an EstateDreamingReader — a full `recall_trace` window
    /// scan and dreaming-queue probe — on every base tick (sub-second), even though
    /// dreaming fires only every `tickIntervalMs` (30 s default); on a high-traffic
    /// estate that contends the estate connection with the encode drain. Mirrors the
    /// gate inside `pump`; does NOT mutate state. `.event` mode never fires on the
    /// timer path, so it returns false. Rust twin: `DreamingDaemon::timer_due`.
    public func timerDue(now: Date) -> Bool {
        guard triggerMode != .event else { return false }
        guard let last = lastTickAt else { return true }
        return now.timeIntervalSince(last) * 1000.0 >= Double(policy.tickIntervalMs)
    }

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
    ///   accumulated sufficient new activity (dreaming-queue items pending)
    ///   to warrant dreaming. Returns `nil` when below threshold.
    /// - **`.hybrid`**: fires on the event condition in addition to the
    ///   timer path in `pump`. Allows the same daemon to fire from either
    ///   source so neither signal is missed.
    /// - **`.timer`**: the event path is inactive for this mode. Returns
    ///   `nil` unconditionally; use `pump(now:)` instead.
    ///
    /// The caller derives `observationCount` from the estate's pending
    /// dreaming-queue job count and passes it here; this keeps the seam
    /// contract intact (the daemon itself drains the queue inside
    /// `runCycle` via `DreamingSubstrateReader.drainDreamingWindow()`).
    ///
    /// - Parameters:
    ///   - observationCount: the current pending dreaming-queue job count
    ///     for the estate, used to gate the event threshold.
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

        // ── Step 2: drain dreaming-queue windows and build co-recall pairs ─
        // Each window is the drawer-ID set from one DreamingItem (one recall
        // event that co-recalled ≥ 2 drawers). We enumerate every distinct
        // unordered pair within each window and bump `coRecallCounts` once
        // per pair per window — the bump accumulates across drain events so
        // the count reflects how often the estate has co-recalled the pair
        // since the daemon last ran. The drain is non-exclusive (no lease
        // held across calls); consumed jobs are replied Done inside the
        // adapter before the call returns, so they do not reappear.
        let windows = try await reader.drainDreamingWindow()
        // Track the set of distinct pairs seen across ALL windows this cycle
        // so we can build the Observation list for `decide()`. Use String
        // pairs (drawer IDs) because that is what coRecallCount() keys on.
        var distinctPairs: [(a: String, b: String)] = []
        var seenPairKeys: Set<String> = []
        for window in windows {
            // Enumerate all distinct unordered pairs in this window.
            // Inner-loop guard: skip windows with < 2 drawers (cannot form a pair).
            guard window.count >= 2 else { continue }
            for i in 0 ..< window.count {
                for j in (i + 1) ..< window.count {
                    let a = window[i]
                    let b = window[j]
                    // Bump the count for this drain event regardless of whether
                    // the pair is new this cycle — each window is one co-recall
                    // event, and each event is one increment per pair.
                    bumpCoRecall(a, b)
                    // Collect the pair for the decide() input list; deduplicate
                    // across windows so decide() sees each pair once per cycle.
                    let key = DreamingDecision.candidateKey(a, b)
                    if seenPairKeys.insert(key).inserted {
                        // Canonical order: DreamingDecision.candidateKey places
                        // the lexicographically-smaller endpoint first.
                        let (first, second) = a <= b ? (a, b) : (b, a)
                        distinctPairs.append((a: first, b: second))
                    }
                }
            }
        }

        // Build the Observation list for `decide()`. `attempts` is read from
        // `coRecallCounts` AFTER bumping so it reflects the cumulative count
        // across all drain events, not just this cycle's windows. `evidenceTargets`
        // for a pair is [endpointA, endpointB] — the co-recalled drawers are their
        // own evidence (the reward map is keyed by RowID, same values).
        let observations: [DreamingDecision.Observation] = distinctPairs.map { pair in
            DreamingDecision.Observation(
                endpointA: pair.a,
                endpointB: pair.b,
                attempts: coRecallCount(pair.a, pair.b),
                evidenceTargets: [pair.a, pair.b]
            )
        }

        // ── Step 5 (prep): ACTIVE dreamed Tunnel keys for duplicate suppression.
        // Uses dreamedActiveTunnels() (not existingTunnels()) to exclude tunnels
        // that have been tombstoned by the OMEGA stage. Using existingTunnels() here
        // would permanently block re-formation of associations whose dreamed tunnel
        // was retired: the retired tunnel's key would always appear in tunnelKeys,
        // suppressing ALPHA forever even when the evidence warrants a new association.
        // dreamedActiveTunnels() filters to non-tombstoned tunnels with
        // addedBy == "dreaming-daemon" (the dreamed tunnel origin marker).
        let tunnelKeys = Set(try await reader.dreamedActiveTunnels().compactMap(Self.tunnelKey))

        // ── Steps 3–6: delegate every DECISION to the pure core ────────
        // The actor only gathers seam inputs and enacts the result; the
        // contrastive score, EWC++ blend, duplicate suppression, and
        // confidence-AND-attempts gate all live in `DreamingDecision` so
        // the math is portable and conformance-gated against the Rust version
        // (NeuronKit/rust/src/dreaming_decision.rs). See DreamingDecision.swift.
        let outcome = DreamingDecision.decide(
            observations: observations,
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
        // co-recall observations considered (the dreaming-queue windows the daemon
        // drained this cycle). `proposals` is the emission count. Both are
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

        // ── Auto-reindex step: trigger corpus basis retrain on vocab growth ─
        // Distributional embedding providers (RI / PPMI / LSA / NMF) freeze
        // their vocabulary at training time. Terms ingested after the last
        // retrain are OOV and produce zero-vectors in the dense lane, silently
        // missing novel content. The growth probe reads the maintained VOCABULARY
        // anchor (P3 counts table) and fires a full `Corpus.reindex(now:)` when
        // the vocabulary has grown by `reindexVocabGrowthFraction` (or the
        // absolute `reindexVocabGrowthFloor`, whichever is larger) since the last
        // retrain. Vocabulary drift — not raw chunk count — is what degrades
        // dense recall, and the counts table makes the live vocabulary a cheap read.
        //
        // Idempotency / safety:
        //   • On the first cycle, `lastReindexVocab == -1` (sentinel). We read the
        //     live vocabulary and store it as the baseline WITHOUT firing a
        //     retrain — the corpus was just trained on first ingest, or opened
        //     from a persisted basis. Firing on the first cycle would
        //     unconditionally retrain on every daemon restart, which is wasteful.
        //   • After baseline is set, the gate fires when the vocabulary delta
        //     reaches the trigger. After firing, `lastReindexVocab` advances to
        //     the post-reindex vocabulary so the next window resets correctly.
        //   • Reindex failures are caught and logged (OSLog) but do not abort
        //     the cycle — a stale basis is better than a broken dreaming daemon.
        //   • When no probe is injected (nil), this block is a no-op.
        if let probe = growthProbe {
            do {
                let liveVocab = try await probe.vocabAnchor()
                if lastReindexVocab == -1 {
                    // First cycle: establish baseline. No retrain.
                    lastReindexVocab = liveVocab
                } else {
                    // Trigger = max(absolute floor, fraction × baseline). The floor
                    // dominates at small vocabularies (no thrashing); the fraction
                    // dominates at large ones (proportional drift tolerance).
                    let fractional = Int(
                        (Double(lastReindexVocab) * reindexVocabGrowthFraction).rounded(.up))
                    let trigger = max(reindexVocabGrowthFloor, fractional)
                    let delta = liveVocab - lastReindexVocab
                    if delta >= trigger {
                        // Vocabulary drift crossed the trigger — retrain so dense
                        // recall vocabulary stays current with ingested content.
                        Intellectus.report(.metric(
                            name: "neuronkit.dream.auto_reindex",
                            value: Double(delta),
                            tags: [
                                "cycle": "\(cycleCount)",
                                "live_vocab": "\(liveVocab)",
                                "since_last_reindex": "\(delta)",
                                "trigger": "\(trigger)",
                            ],
                            ts: now.timeIntervalSince1970
                        ))
                        try await probe.reindex(now: now)
                        // Advance baseline to the vocabulary at retrain time so the
                        // next window measures growth from this retrain.
                        lastReindexVocab = liveVocab
                    }
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

        //  / manifest-backed daemon state: persist the daemon's idempotency/cycle memory after every
        // cycle so a restart resumes from here (no re-proposing, no re-consolidating,
        // no cycle-counter reset). All cycle mutations — cycleCount, consolidated,
        // proposedKeys, lastReindexVocab — are complete by this point; lastTickAt
        // was set by the calling pump path before runCycle. Default store impl is a
        // no-op, so in-memory/test daemons are unaffected.
        try await policyStore.saveDaemonState(currentDaemonState())

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

    // MARK: - REM dispatch table — due-checks

    /// True iff the REM-THETA daily-consolidation cycle is due at `now`.
    ///
    /// Due when `now >= lastThetaRunAt + 24 h`, OR when THETA has never run
    /// (nil → overdue on first invocation, which is the correct cold-start
    /// behaviour — a fresh estate with recall_trace data should consolidate
    /// immediately). Mirrors Rust `DreamingDaemon::theta_due`.
    public func thetaDue(now: Date) -> Bool {
        guard let last = lastThetaRunAt else { return true }
        // THETA_CADENCE_SECS = 86 400 s (24 h, D5a default).
        return now.timeIntervalSince(last) >= Self.thetaCadenceSecs
    }

    /// True iff the REM-BETA weekly-prune cycle is due at `now`.
    ///
    /// Due when `now >= lastBetaRunAt + 7 d`, or when BETA has never run
    /// (nil → overdue on first invocation). Mirrors Rust
    /// `DreamingDaemon::beta_due`.
    public func betaDue(now: Date) -> Bool {
        guard let last = lastBetaRunAt else { return true }
        return now.timeIntervalSince(last) >= Self.betaCadenceSecs
    }

    /// True iff the REM-OMEGA biweekly-retire cycle is due at `now`.
    ///
    /// Due when `now >= lastOmegaRunAt + 14 d`, or when OMEGA has never run
    /// (nil → overdue on first invocation). Mirrors Rust
    /// `DreamingDaemon::omega_due`.
    public func omegaDue(now: Date) -> Bool {
        guard let last = lastOmegaRunAt else { return true }
        return now.timeIntervalSince(last) >= Self.omegaCadenceSecs
    }

    // MARK: - REM-THETA cycle

    /// Daily bounded consolidation sweep (NEURONKIT_SPEC § 12.6 THETA row).
    ///
    /// Window: the last 24 h of `recall_trace`, bounded by the recalled set²
    /// (never estate shape). The cycle:
    ///
    /// 1. Reads `recentRecallTraces(since: now-24h, now: now)` — the same
    ///    seam ALPHA uses for its reward window, but with the THETA window.
    /// 2. Collects the set of drawer IDs that appear as `used` targets in the
    ///    window (the "recalled set"). Items that are not used carry no
    ///    co-recall signal; pairs are formed only from used drawers.
    /// 3. Builds reward by target from ALL traces in the window (used → 1.0,
    ///    unused → 0.0) — the same `RewardSource` logic as ALPHA, but over
    ///    the full 24 h instead of the 30 s ALPHA window.
    /// 4. Enumerates all distinct co-recall pairs within the used-drawer set
    ///    and bumps `coRecallCounts` once per pair — the "attempts" bump that
    ///    THETA contributes across the day's events (cross-event accumulation).
    /// 5. Calls `DreamingDecision.decide` with the 24 h reward map + the
    ///    bumped co-recall counts — the same decide math as ALPHA (§ 12.5
    ///    unchanged). EWC++ decay is applied by `decide` via `consolidated`.
    /// 6. Emits proposals + updates `consolidated` (propose + adjust, per
    ///    the § 12.6 THETA "Tunnel writes" column).
    /// 7. Records one diary entry and persists daemon state.
    ///
    /// Determinism: `now` is injected by the caller (never `Date()` here).
    /// Bounded by recalled-set²: the largest possible THETA observation set
    /// is |used_drawers|² / 2 — NEVER |all_drawers|² (no estate scan).
    ///
    /// - Returns: the cycle report, or nil if there were no used traces in the
    ///   24 h window (nothing to consolidate — consistent with ALPHA's behaviour
    ///   on an empty queue).
    @discardableResult
    public func runThetaCycle(now: Date) async throws -> DreamingCycleReport? {
        let windowSecs = Self.thetaCadenceSecs
        let since = now.addingTimeInterval(-windowSecs)

        // Step 1: read the 24 h recall_trace window.
        let traces = try await reader.recentRecallTraces(since: since, now: now)

        // Step 2: build reward by target (used → 1.0, unused → 0.0).
        var rewardByTarget: [RowID: Float] = [:]
        for trace in traces {
            // Keep the strongest signal per target across the full window.
            // `RecallTraceRewardSource` maps used → 1.0, unused → 0.0; replicate
            // inline to avoid constructing a source instance mid-cycle.
            let r: Float = trace.used ? 1.0 : 0.0
            rewardByTarget[trace.target] = max(rewardByTarget[trace.target] ?? 0, r)
        }

        // Collect the used-drawer set: only drawers with a `used` trace in the
        // window are eligible for co-recall pairing. An unused drawer carries
        // no co-recall signal; it may appear in reward_by_target (with 0.0) but
        // it is excluded from pair generation so the observation set stays
        // bounded by the recalled set, not the window set.
        let usedDrawers = traces.filter { $0.used }.map(\.target)
        // Deduplicate while preserving canonical (sorted) order so the observation
        // list is deterministic across two calls on the same `now`.
        // Cap at THETA_USED_DRAWER_CAP to bound pair-enumeration cost: an
        // uncapped N-drawer set produces N×(N-1)/2 pairs. At the cap of 200
        // the worst case is 19 900 pairs — comparable to a busy ALPHA cycle
        // and well within memory budget. Drawers beyond the cap are sorted
        // away deterministically (sorted → first 200 lexicographically).
        let usedSetFull = Array(Set(usedDrawers)).sorted()
        let usedSet = Array(usedSetFull.prefix(Self.thetaUsedDrawerCap))

        // Nothing to consolidate if no drawers were used in the window.
        guard usedSet.count >= 2 else {
            // Advance last-run timestamp even on a no-op so the next cadence
            // gate measures from this run (avoids a burst of empty theta cycles
            // on a low-recall estate).
            lastThetaRunAt = now
            try await policyStore.saveDaemonState(currentDaemonState())
            return nil
        }

        // Step 3 & 4: enumerate all distinct co-recall pairs over the used set,
        // bump coRecallCounts once per pair. THETA bumps represent the day's
        // cross-event co-recall accumulation (the window is one logical "event").
        var distinctPairs: [(a: String, b: String)] = []
        var seenPairKeys: Set<String> = []
        for i in 0 ..< usedSet.count {
            for j in (i + 1) ..< usedSet.count {
                let a = usedSet[i]
                let b = usedSet[j]
                bumpCoRecall(a, b)
                let key = DreamingDecision.candidateKey(a, b)
                if seenPairKeys.insert(key).inserted {
                    distinctPairs.append((a: a, b: b))
                }
            }
        }

        // Build the Observation list for decide(). `attempts` is read AFTER
        // bumping so the count reflects the cumulative co-recall history
        // including the bump THETA just applied.
        let observations: [DreamingDecision.Observation] = distinctPairs.map { pair in
            DreamingDecision.Observation(
                endpointA: pair.a,
                endpointB: pair.b,
                attempts: coRecallCount(pair.a, pair.b),
                evidenceTargets: [pair.a, pair.b]
            )
        }

        // Step 5 (prep): ACTIVE dreamed tunnels for duplicate suppression.
        // Same as the ALPHA path: use dreamedActiveTunnels() not existingTunnels(),
        // so tombstoned (OMEGA-retired) tunnels do not permanently suppress
        // re-formation of the same association when evidence warrants it.
        let tunnelKeys = Set(try await reader.dreamedActiveTunnels().compactMap(Self.tunnelKey))

        // Step 5: delegate decide to the portable core (§ 12.5 math unchanged).
        // EWC++ decay is applied by `decide` via the `consolidated` map —
        // the same `max(raw, consolidated[key] · ewcRetention)` blend as ALPHA.
        let outcome = DreamingDecision.decide(
            observations: observations,
            rewardByTarget: rewardByTarget,
            existingTunnelKeys: tunnelKeys,
            alreadyProposedKeys: proposedKeys,
            consolidated: consolidated,
            minConfidence: policy.minConfidence,
            minAttempts: policy.minAttempts,
            minSuccessRate: policy.minSuccessRate
        )

        // Step 6: fold consolidation + emit proposals ("propose + adjust").
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
                    "theta: cross-event consolidation \(candidate.endpointA)↔\(candidate.endpointB) "
                    + "(attempts \(candidate.attempts), confidence \(candidate.confidence))"
            )
            try await sink.propose(frame)
            proposedKeys.insert(candidate.key)
            emitted.append(frame)
        }

        // Step 7: write one diary entry for this THETA cycle.
        cycleCount += 1
        let entry = DiaryEntry(
            agentName: Self.agentName,
            entry: "theta cycle \(cycleCount): window 24h, "
                + "used-set \(usedSet.count), pairs \(observations.count), "
                + "proposed \(emitted.count), suppressed \(suppressedDuplicates), "
                + "below-threshold \(belowThreshold)",
            topic: "dreaming-theta",
            wing: Self.diaryWing,
            room: "diary",
            filedAt: now,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)

        // Advance the THETA last-run timestamp and persist daemon state.
        lastThetaRunAt = now
        try await policyStore.saveDaemonState(currentDaemonState())

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

    // MARK: - REM-BETA cycle

    /// Confidence floor — a `consolidated` entry strictly below this value
    /// is pruned by REM-BETA. An entry below `betaPruneFloor` has decayed to
    /// a value where even repeated `ewcRetention` applications can never
    /// drive it above any reasonable `minConfidence` gate (default 0.7).
    /// At 0.01 × 0.9 (one more THETA decay) = 0.009 — orders of magnitude
    /// below every supported gate value. Any entry at this level is
    /// effectively zero for decision purposes and wastes space in the
    /// consolidated map forever without fresh evidence.
    ///
    /// Chosen as an absolute constant (not policy-derived) so BETA's GC
    /// boundary is stable across policy changes — if `minConfidence` is
    /// raised from 0.7 to 0.9, the pruned set should widen at that point
    /// via THETA decay, not retroactively by BETA reading a new policy value.
    /// Mirrors Rust `BETA_PRUNE_FLOOR`.
    public static let betaPruneFloor: Float = 0.01

    /// REM-BETA (weekly prune/GC) — recall-driven dreaming
    ///
    /// Memory-only GC that keeps the two in-memory dreaming stores bounded
    /// by recall activity. Mutates only `consolidated` and `coRecallCounts`
    /// (the two in-memory maps), then persists the shrunken state via the
    /// existing `saveDaemonState` path. Makes no tunnel writes and does not
    /// touch recall_trace, the dreaming queue, or any estate row — the
    /// "Tunnel writes: none" column of the § 12.6 BETA row is enforced
    /// here: the function has no `sink` parameter, so it is structurally
    /// unable to write proposals, diary entries, or tunnel prunes.
    ///
    /// ## Prune rules (both symmetric, documented)
    ///
    /// **`consolidated` prune:** drop keys whose confidence has decayed
    /// below `betaPruneFloor` (0.01). At that level the entry cannot
    /// meaningfully influence any future `decide()` outcome via the EWC++
    /// path without fresh raw evidence — `0.01 × ewcRetention (0.9) = 0.009`,
    /// which is orders of magnitude below the minimum meaningful
    /// `minConfidence` gate.  Fresh raw evidence (from a new real recall)
    /// will re-insert the pair into `consolidated` at full raw strength, so
    /// pruning here causes no loss of signal.
    ///
    /// **`coRecallCounts` prune:** drop keys that are no longer present
    /// in `consolidated` after the prune above. A co-recall count for a
    /// pruned pair is orphaned — the pair has no live confidence to anchor
    /// it — and keeping the count would mean the `minAttempts` gate applies
    /// a memory of recall activity that the EWC confidence store no longer
    /// supports. When fresh evidence re-establishes the pair's consolidated
    /// entry, the count resumes from the subsequent `bumpCoRecall` calls.
    ///
    /// Determinism: `now` is injected by the caller; no `Date()` inside.
    @discardableResult
    public func runBetaCycle(now: Date) async throws -> DreamingCycleReport? {
        // ── Prune consolidated: drop entries decayed below betaPruneFloor ──
        // Collect the keys to remove first into an Array (iterating a Swift
        // Dictionary while mutating it is undefined — the keys snapshot
        // prevents that). removeValue is O(1) amortised.
        let beforeConsolidatedCount = consolidated.count
        let consolidatedKeysToRemove = consolidated.keys.filter { key in
            (consolidated[key] ?? 0) < Self.betaPruneFloor
        }
        for key in consolidatedKeysToRemove {
            consolidated.removeValue(forKey: key)
        }
        let prunedConsolidated = beforeConsolidatedCount - consolidated.count

        // ── Prune co_recall_counts: drop orphaned keys (no consolidated entry) ──
        // A co-recall count is orphaned when its pair was just pruned from
        // consolidated. Keeping orphaned counts would let them gate future
        // minAttempts checks for pairs that no longer have EWC support.
        // Same snapshot-first pattern to avoid mutation-during-iteration.
        let beforeCoRecallCount = coRecallCounts.count
        let coRecallKeysToRemove = coRecallCounts.keys.filter { key in
            consolidated[key] == nil
        }
        for key in coRecallKeysToRemove {
            coRecallCounts.removeValue(forKey: key)
        }
        let prunedCoRecall = beforeCoRecallCount - coRecallCounts.count

        // ── Advance last-run timestamp and persist the shrunken state ────────
        // Persisting here (not just advancing the timestamp) is what makes
        // the GC durable: the shrunken consolidated + co_recall_counts maps
        // survive a daemon restart via the existing /manifest-backed daemon state path.
        lastBetaRunAt = now
        try await policyStore.saveDaemonState(currentDaemonState())

        // BETA returns nil: it produces no proposals and writes no diary
        // entry (the § 12.6 "Tunnel writes: none" column). The GC metrics
        // are observable only through the in-memory state change, which the
        // test suite verifies directly via `currentDaemonState_testOnly()`.
        // If telemetry were wired here it would be a metric-only event, not
        // a proposal. For now, no telemetry: the cycle is internal bookkeeping.
        _ = prunedConsolidated  // used by tests; suppress unused-result warning
        _ = prunedCoRecall
        return nil
    }

    // MARK: - REM-OMEGA cycle

    /// REM-OMEGA (biweekly retire) — recall-driven dreaming
    ///
    /// Retires dreamed tunnels that have not been reinforced by co-recall
    /// within the 14-day OMEGA window. The retire predicate is:
    ///
    ///   `isDreamed AND NOT reinforced`
    ///
    /// where "reinforced" means BOTH tunnel endpoints (`sourceDrawerId`,
    /// `targetDrawerId`) appear in at least one recall-trace row in the
    /// `[now − omegaCadenceSecs, now]` window.  Tunnels with a `used` or
    /// `unused` trace for each endpoint satisfy reinforcement; a tunnel
    /// with neither endpoint touched is unreinforced and is retired.
    ///
    /// §12.8 guard: declared tunnels (`isDreamed == false`) are NEVER
    /// retired.  `dreamedActiveTunnels()` on the reader seam enforces this
    /// at the source — it returns only tunnels where `isDreamed == true` —
    /// so the body never even sees declared tunnels.
    ///
    /// Retirement is reversible: a subsequent `associate` verb can re-promote
    /// a retired tunnel (by clearing bit 13 via `unretireTunnel`).  The
    /// retired tunnel remains in `allTunnels()` for full audit history.
    ///
    /// After retirement, the recall-trace table is pruned of rows older than
    /// `windowStart` (= `now − omegaCadenceSecs`), preserving rows still
    /// within the OMEGA reinforcement window for the next run.
    ///
    /// Determinism: `now` is injected by the caller; no `Date()` inside.
    ///
    /// - Parameter now: The deterministic clock value for this cycle.
    /// - Returns: A `DreamingCycleReport` summarising the retire run, or
    ///   `nil` if there are no dreamed active tunnels to evaluate.
    @discardableResult
    public func runOmegaCycle(now: Date) async throws -> DreamingCycleReport? {
        // ── Step 1: fetch dreamed active tunnels (§12.8 guard baked in) ──────
        // `dreamedActiveTunnels()` returns only tunnels where
        // `isDreamed == true` AND `isRetired == false`.  Declared tunnels
        // (isDreamed == false) are excluded at the source.
        let candidates = try await reader.dreamedActiveTunnels()

        // No dreamed-active tunnels → advance cadence and exit.
        // This is the common case on LocusOnly or newly-seeded estates.
        guard !candidates.isEmpty else {
            lastOmegaRunAt = now
            try await policyStore.saveDaemonState(currentDaemonState())
            return nil
        }

        // ── Step 2: build the reinforcement set from the OMEGA window ─────────
        // Fetch every recall-trace row whose `recalledAt` falls in
        // `[now − omegaCadenceSecs, now]`.  Both `used` and `unused` traces
        // count for reinforcement: an endpoint that appeared in any recall
        // during the window — whether the user opened it or not — shows the
        // context is still active.  Reinforcement does not require a reward;
        // it requires presence.
        let windowStart = Date(timeIntervalSince1970: now.timeIntervalSince1970 - Self.omegaCadenceSecs)
        let traces = try await reader.recentRecallTraces(since: windowStart, now: now)

        // Collapse traces to a flat set of drawer IDs.  A drawer ID that
        // appears in ANY trace (used or unused) during the window is
        // "reinforced" for OMEGA purposes.
        let reinforcedDrawers: Set<String> = Set(traces.map { $0.target })

        // ── Step 3: classify and retire ───────────────────────────────────────
        // For each candidate tunnel, test whether BOTH endpoints are
        // reinforced.  If either endpoint is absent from the window, the
        // tunnel is unreinforced and is retired.
        var retiredCount = 0
        for tunnel in candidates {
            // Tunnel endpoints are Optional (room-level tunnels have no drawer IDs).
            // OMEGA only operates on drawer-pair tunnels; room-level dreamed tunnels
            // (both or either endpoint nil) are skipped — `dreamedActiveTunnels()` in
            // production returns only drawer-pair tunnels, but the guard is defensive.
            guard let sourceId = tunnel.sourceDrawerId,
                  let targetId = tunnel.targetDrawerId else {
                continue
            }
            let sourceReinforced = reinforcedDrawers.contains(sourceId)
            let targetReinforced = reinforcedDrawers.contains(targetId)
            guard sourceReinforced && targetReinforced else {
                // Retire: flip bit 13.  `retireTunnel` delegates through the
                // DreamingProposalSink seam → GLK → Estate → DrawerStore (B-1
                // compliant).  The "dreaming-daemon" changedBy tag lets audit
                // logs distinguish OMEGA retirements from manual ones.
                try await sink.retireTunnel(
                    id: tunnel.id,
                    changedBy: Self.agentName,
                    now: now
                )
                retiredCount += 1
                continue
            }
        }

        // ── Step 4: prune recall-trace table ─────────────────────────────────
        // Remove rows older than `windowStart` to keep the recall_trace
        // table bounded.  The cutoff mirrors ALPHA's prune-after-sweep
        // pattern (pass `windowStart` as cutoff so rows in the OMEGA window
        // are preserved for the next run's reinforcement check).
        _ = try await sink.pruneRecallTraces(olderThan: windowStart)

        // ── Step 5: write diary entry ─────────────────────────────────────────
        cycleCount += 1
        let entry = DiaryEntry(
            agentName: Self.agentName,
            entry: "omega cycle \(cycleCount): window 14d, "
                + "dreamed-active \(candidates.count), reinforced \(candidates.count - retiredCount), "
                + "retired \(retiredCount), recall-traces \(traces.count)",
            topic: "dreaming-omega",
            wing: Self.diaryWing,
            room: "diary",
            filedAt: now,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)

        // ── Step 6: advance last-run timestamp and persist ────────────────────
        lastOmegaRunAt = now
        try await policyStore.saveDaemonState(currentDaemonState())

        // ── Step 7: build report ──────────────────────────────────────────────
        // OMEGA has no candidates-considered / proposals-emitted / scores in
        // the ALPHA/THETA sense.  Map the retire counts onto the report fields:
        //   candidatesConsidered = dreamed-active tunnels evaluated
        //   proposalsEmitted     = [] (OMEGA emits no proposals; see §12.6)
        //   suppressedDuplicates = reinforced tunnels (kept, not retired)
        //   belowThreshold       = 0 (no threshold gate in OMEGA)
        //   candidateScores      = [:] (no scoring in OMEGA)
        //   rewardByTarget       = [:] (OMEGA does not use the reward model)
        return DreamingCycleReport(
            tickedAt: now,
            candidatesConsidered: candidates.count,
            proposalsEmitted: [],
            suppressedDuplicates: candidates.count - retiredCount,
            belowThreshold: 0,
            candidateScores: [:],
            rewardByTarget: [:],
            diaryEntry: entry
        )
    }

    // MARK: - Unified dispatch (used by both governor and dream_runner)

    /// Run one entry from the REM dispatch table.
    ///
    /// Called by both the resident governor's `tick()` and the dream_runner's
    /// one-shot loop. Returns the cycle report if the cycle ran (it may return
    /// nil for ALPHA — queue empty — or THETA — no used traces in window). Does
    /// NOT perform the due-check — callers gate via `timerDue`, `thetaDue`,
    /// `betaDue`, or `omegaDue` (plus the ALPHA pending-count check).
    ///
    /// Mirrors Rust `DreamingDaemon::run_cycle_for_kind`.
    @discardableResult
    public func runCycleForKind(_ kind: RemCycleKind, now: Date) async throws -> DreamingCycleReport? {
        switch kind {
        case .alpha:
            // ALPHA: the caller (governor or dream_runner) has already checked
            // the pending count and passes control here only when the queue is
            // non-empty. Run the timer pump (which also updates lastTickAt and
            // persists bandit + daemon state).
            return try await pump(now: now)
        case .theta:
            return try await runThetaCycle(now: now)
        case .beta:
            return try await runBetaCycle(now: now)
        case .omega:
            return try await runOmegaCycle(now: now)
        }
    }

    // MARK: - Cadence constants (§ 12.6 D5a defaults; Rust mirrors these)

    /// Maximum used-drawer set size for THETA pair enumeration. (NK-15 planned hardening)
    ///
    /// An uncapped N-drawer set produces N×(N-1)/2 pairs, which is O(N²) in
    /// memory and CPU. At 200 the worst case is 19 900 pairs — comparable to a
    /// busy ALPHA cycle and well within memory budget. Drawers beyond the cap
    /// are sorted away deterministically (sorted → first 200 lexicographically).
    /// Mirrors Rust `THETA_USED_DRAWER_CAP`.
    public static let thetaUsedDrawerCap: Int = 200

    /// THETA cadence: 24 h in seconds (D5a daily default).
    public static let thetaCadenceSecs: TimeInterval = 86_400
    /// BETA cadence: 7 days in seconds (D5a weekly default).
    public static let betaCadenceSecs: TimeInterval = 604_800
    /// OMEGA cadence: 14 days in seconds (D5a biweekly default).
    public static let omegaCadenceSecs: TimeInterval = 1_209_600

    // MARK: - Exposed for testing (last-run timestamps)

    /// The last-run timestamp for the given periodic cycle, or nil.
    /// Exposed for the persistence round-trip tests (T11 test discipline:
    /// last-run advances, persisted, restores correctly).
    public func lastRunAt(for kind: RemCycleKind) -> Date? {
        switch kind {
        case .alpha: return lastTickAt
        case .theta: return lastThetaRunAt
        case .beta: return lastBetaRunAt
        case .omega: return lastOmegaRunAt
        }
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
