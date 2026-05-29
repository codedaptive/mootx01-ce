// MaintenanceDaemon.swift
//
// The maintenance daemon (NEURONKIT_SPEC § 3.2). An always-on autonomic
// process that scans substrate state for health violations and PROPOSES
// remediation, never remediating directly. It sits alongside the
// dreaming daemon (§ 3.1) as a second background `actor` and is built on
// the exact same seam architecture: injected reader / sink / policy-store
// seams, actor-isolated mutable state, an injectable clock (`now` passed
// in, never read from the system clock), and idempotent proposal emission
// across cycles.
//
// ── What one cycle does (§ 3.2 + § 3.5) ──────────────────────────────
//   0. Audit-chain monitor: re-verify the unified audit log on its own
//      cadence via the live `AuditChainVerifier`; on a break, propose an
//      audit-integrity remediation.
//   1. Forbidden-combination scan (invariant I-3).
//   2. Decay-candidate scan.
//   3. Tombstone/expunge-candidate scan.
//   4. Fingerprint-drift scan.
//   5. byReference-validity scan.
//   6. Write exactly one cycle diary entry.
//
// ── Why this daemon talks to seams, not to GLK verbs ─────────────────
// B-1: NeuronKit never executes SQL and never calls LocusKit / VectorKit
// / CorpusKit directly. The GLK verb surface cannot satisfy a daemon's
// substrate needs today (the `propose` verb raises
// `VerbError.notSupportedByEstate`, and no verb reads drawers, reads a
// `UnifiedAuditLog`, or writes a `DiaryEntry`). So the daemon depends on
// the NeuronKit-owned seams in `MaintenanceSeams.swift`. It references
// substrate VALUE types and calls the pure `AuditChainVerifier.verify`,
// but calls no substrate method, so B-1 holds structurally. NeuronKit
// owns the scheduling and the proposal; GeniusLocusKit owns the chain
// verification math (the daemon does NOT reimplement it).
//
// ── Determinism ───────────────────────────────────────────────────────
// Every computation is deterministic: the daemon never reads the system
// clock. The caller passes `now` into every cycle and pump. Conformance tests
// drive an injected clock by advancing `now`; there are no wall-clock
// sleeps anywhere.

import Foundation
import GeniusLocusKit
import LocusKit

/// The maintenance daemon — a background actor so it never blocks the
/// caller (§ 3 autonomic contract). Idempotent across cycles (B-4):
/// re-running over unchanged state emits no duplicate proposals. Emits
/// proposals only; it has no remediation path (the sink exposes none),
/// which is the structural enforcement of the never-remediate invariant.
public actor MaintenanceDaemon {

    // MARK: - Injected seams

    private let reader: MaintenanceSubstrateReader
    private let sink: MaintenanceProposalSink
    private let policyStore: MaintenancePolicyStore

    // MARK: - Mutable state (actor-isolated)

    /// Current health-scan parameters. Mutated by
    /// `registerMaintenancePolicy`, persisted through `policyStore`.
    private var policy: MaintenancePolicy

    /// Last cycle time, for the tick-cadence decision in `pump`.
    private var lastTickAt: Date?

    /// Last time the audit chain was verified, for the independent
    /// audit-check cadence. `nil` until the first verification.
    private var lastAuditCheckAt: Date?

    /// Candidate keys already proposed in a prior cycle. The idempotency
    /// memory (B-4): a key here is never proposed again.
    private var proposedKeys: Set<String> = []

    /// Number of cycles run. Recorded in the cycle diary entry.
    private var cycleCount: Int = 0

    // MARK: - Init

    /// Construct a daemon over the injected seams.
    ///
    /// - Parameters:
    ///   - reader: substrate read seam (the five scans + audit log).
    ///   - sink: proposal + diary write seam (the only write path).
    ///   - policyStore: manifest-resident policy persistence seam.
    ///   - policy: initial in-memory policy. Defaults to the spec
    ///     defaults; `loadPersistedPolicy()` overrides it from the store.
    public init(
        reader: MaintenanceSubstrateReader,
        sink: MaintenanceProposalSink,
        policyStore: MaintenancePolicyStore,
        policy: MaintenancePolicy = .default
    ) {
        self.reader = reader
        self.sink = sink
        self.policyStore = policyStore
        self.policy = policy
    }

    // MARK: - Policy registration (§ 3.2 registration API)

    /// Register the maintenance health-scan parameters and persist them
    /// to the manifest seam. Spec defaults match NEURONKIT_SPEC § 3.2.
    public func registerMaintenancePolicy(
        tickIntervalMs: Int = 300_000,
        auditCheckIntervalMs: Int = 300_000,
        decayWindowSeconds: Double = 2_592_000,
        tombstoneGraceSeconds: Double = 604_800,
        fingerprintDriftThreshold: Float = 0.25,
        byReferenceDriftThreshold: Float = 0.25
    ) async throws {
        let next = MaintenancePolicy(
            tickIntervalMs: tickIntervalMs,
            auditCheckIntervalMs: auditCheckIntervalMs,
            decayWindowSeconds: decayWindowSeconds,
            tombstoneGraceSeconds: tombstoneGraceSeconds,
            fingerprintDriftThreshold: fingerprintDriftThreshold,
            byReferenceDriftThreshold: byReferenceDriftThreshold
        )
        policy = next
        try await policyStore.savePolicy(next)
    }

    /// Load the persisted policy from the manifest seam, if any,
    /// replacing the in-memory policy. Call once after construction to
    /// pick up a policy a prior run registered.
    public func loadPersistedPolicy() async throws {
        if let stored = try await policyStore.loadPolicy() {
            policy = stored
        }
    }

    /// The current policy. Exposed for the manifest round-trip test.
    public func currentPolicy() -> MaintenancePolicy { policy }

    // MARK: - Tick driving

    /// Run one cycle iff the configured tick interval has elapsed since
    /// the last cycle (the autonomic timer path, § 3.2). Returns the
    /// cycle report when it fires, or `nil` when the interval has not yet
    /// elapsed. The caller advances `now` from its own clock; the daemon
    /// performs no sleeping. The first pump (no prior tick) always fires.
    public func pump(now: Date) async throws -> MaintenanceCycleReport? {
        if let last = lastTickAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000.0
            guard elapsedMs >= Double(policy.tickIntervalMs) else { return nil }
        }
        return try await runCycle(now: now)
    }

    /// Run one maintenance cycle on demand, regardless of the timer
    /// (§ 3.2 `triggerMaintenanceCycle()`). `now` is explicit for
    /// determinism per CLAUDE.md; the spec's no-argument signature cannot
    /// satisfy the rule against reading the system clock inside an engine.
    @discardableResult
    public func triggerMaintenanceCycle(now: Date) async throws -> MaintenanceCycleReport {
        try await runCycle(now: now)
    }

    // MARK: - The cycle (§ 3.2 + § 3.5)

    private func runCycle(now: Date) async throws -> MaintenanceCycleReport {
        var emitted: [ProposeFrame] = []
        var suppressed = 0

        // ── Step 0: audit-chain integrity monitor (§ 3.5) ──────────────
        // Verify on the audit-check cadence, tracked independently of the
        // scan tick so a slow full-chain verification need not run every
        // tick. First run always checks (lastAuditCheckAt == nil).
        var auditChecked = false
        var auditReport: AuditChainReport? = nil
        let auditDue: Bool = {
            guard let last = lastAuditCheckAt else { return true }
            let elapsedMs = now.timeIntervalSince(last) * 1000.0
            return elapsedMs >= Double(policy.auditCheckIntervalMs)
        }()
        if auditDue {
            let log = try await reader.currentAuditLog()
            // Reuse the live verifier (GLK-03). The daemon owns scheduling
            // and the proposal; GeniusLocusKit owns the verification math.
            let report = AuditChainVerifier.verify(log)
            auditChecked = true
            auditReport = report
            lastAuditCheckAt = now
            if !report.valid {
                // Derive a stable RowID for the proposal target from the
                // first broken entry's timestamp (epoch milliseconds) so
                // re-detecting the SAME break re-derives the SAME key and
                // is idempotently suppressed. `firstBrokenAt` is set
                // whenever `valid == false` in the current verifier, but
                // we guard nil defensively and fall back to a stable
                // sentinel so the proposal is never lost.
                let brokenTag: String
                if let brokenAt = report.firstBrokenAt {
                    brokenTag = String(Int(brokenAt.timeIntervalSince1970 * 1000.0))
                } else {
                    brokenTag = "unknown"
                }
                let target: RowID = "audit-break-\(brokenTag)"
                let key = "audit_integrity|\(brokenTag)"
                let frame = ProposeFrame(
                    target: target,
                    // No typed ProposalKind case exists for audit
                    // integrity; use the documented `.other` escape hatch
                    // rather than adding a case to GLK's ProposalKind.
                    kind: .other("audit_integrity"),
                    justification:
                        "maintenance: audit chain integrity violation; "
                        + "first broken entry at \(brokenTag) "
                        + "(entries \(report.entryCount))"
                )
                if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
                else { suppressed += 1 }
            }
        }

        // ── Step 1: forbidden-combination scan (invariant I-3) ─────────
        // I-3: a row may not be both secret AND publicly exportable. Scan
        // active drawers and propose a discipline-violation for each.
        let active = try await reader.activeDrawers()
        var forbiddenCombinations = 0
        for drawer in active where Self.isForbiddenCombination(drawer) {
            forbiddenCombinations += 1
            let key = "discipline|\(drawer.id)"
            let frame = ProposeFrame(
                target: drawer.id,
                kind: .disciplineViolation,
                justification:
                    "maintenance: forbidden combination (secret AND public) on drawer \(drawer.id)"
            )
            if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
            else { suppressed += 1 }
        }

        // ── Step 2: decay-candidate scan ───────────────────────────────
        // Active drawers whose age (ingest clock `filedAt`, the
        // monotonic when-we-learned-it timestamp) past `now` exceeds the
        // decay window. The ingest clock is used rather than `eventTime`
        // because decay tracks how long the row has lived in the store;
        // the production adapter may switch to event-time once two-clock
        // semantics ship. Proposed as a mutate-candidate (§ 11.1: decay
        // routed through propose for confirmation); the daemon never
        // applies the decay.
        var decayCandidates = 0
        for drawer in active where now.timeIntervalSince(drawer.filedAt) > policy.decayWindowSeconds {
            decayCandidates += 1
            let key = "decay|\(drawer.id)"
            let frame = ProposeFrame(
                target: drawer.id,
                kind: .mutateCandidate,
                justification:
                    "maintenance: decay candidate; drawer \(drawer.id) older than decay window"
            )
            if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
            else { suppressed += 1 }
        }

        // ── Step 3: tombstone/expunge-candidate scan ───────────────────
        // Tombstoned drawers tombstoned longer ago than the grace window.
        // `tombstonedAt` is always set on a tombstoned row, but guard nil
        // defensively (a malformed row is simply skipped, not crashed).
        let tombstoned = try await reader.tombstonedDrawers()
        var tombstoneCandidates = 0
        for drawer in tombstoned {
            guard let tombstonedAt = drawer.tombstonedAt else { continue }
            guard now.timeIntervalSince(tombstonedAt) > policy.tombstoneGraceSeconds else { continue }
            tombstoneCandidates += 1
            let key = "tombstone|\(drawer.id)"
            let frame = ProposeFrame(
                target: drawer.id,
                kind: .mutateCandidate,
                justification:
                    "maintenance: expunge candidate; drawer \(drawer.id) tombstoned past grace window"
            )
            if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
            else { suppressed += 1 }
        }

        // ── Step 4: fingerprint-drift scan ─────────────────────────────
        // Observations whose drift fraction meets or exceeds the policy
        // threshold. The scope key (room/wing) is the stable target — a
        // drifted fingerprint is a property of the scope, not a single
        // row. No typed ProposalKind case exists; use `.other`.
        let fingerprintObs = try await reader.fingerprintBaselines()
        var fingerprintDrifts = 0
        for obs in fingerprintObs where obs.driftFraction >= policy.fingerprintDriftThreshold {
            fingerprintDrifts += 1
            let key = "fingerprint_drift|\(obs.scopeKey)"
            let frame = ProposeFrame(
                target: obs.scopeKey,
                kind: .other("fingerprint_drift"),
                justification:
                    "maintenance: fingerprint drift \(obs.driftFraction) on scope \(obs.scopeKey)"
            )
            if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
            else { suppressed += 1 }
        }

        // ── Step 5: byReference-validity scan ──────────────────────────
        // Learned references whose source content has drifted past the
        // threshold. Proposed as a byReference-drift (the typed case).
        let references = try await reader.learnedReferences()
        var byReferenceDrifts = 0
        for obs in references where obs.sourceDriftFraction >= policy.byReferenceDriftThreshold {
            byReferenceDrifts += 1
            let key = "byref|\(obs.referenceRowID)"
            let frame = ProposeFrame(
                target: obs.referenceRowID,
                kind: .byReferenceDrift,
                justification:
                    "maintenance: byReference source drift \(obs.sourceDriftFraction) "
                    + "on reference \(obs.referenceRowID)"
            )
            if register(key: key) { try await sink.propose(frame); emitted.append(frame) }
            else { suppressed += 1 }
        }

        // ── Step 6: write exactly one diary entry recording the cycle ──
        cycleCount += 1
        let entry = DiaryEntry(
            agentName: Self.agentName,
            entry: "maintenance cycle \(cycleCount): "
                + "audit-checked \(auditChecked), "
                + "forbidden \(forbiddenCombinations), decay \(decayCandidates), "
                + "tombstone \(tombstoneCandidates), fingerprint-drift \(fingerprintDrifts), "
                + "byReference-drift \(byReferenceDrifts), "
                + "proposed \(emitted.count), suppressed \(suppressed)",
            topic: "maintenance-cycle",
            wing: Self.diaryWing,
            room: "diary",
            filedAt: now,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)

        lastTickAt = now
        return MaintenanceCycleReport(
            tickedAt: now,
            auditChecked: auditChecked,
            auditReport: auditReport,
            proposalsEmitted: emitted,
            decayCandidates: decayCandidates,
            tombstoneCandidates: tombstoneCandidates,
            forbiddenCombinations: forbiddenCombinations,
            fingerprintDrifts: fingerprintDrifts,
            byReferenceDrifts: byReferenceDrifts,
            suppressedDuplicates: suppressed,
            diaryEntry: entry
        )
    }

    // MARK: - Idempotency helper

    /// Record `key` as proposed and report whether it was new. A key
    /// already in `proposedKeys` returns false (the caller suppresses and
    /// counts it); a fresh key is inserted and returns true (the caller
    /// emits the proposal). This is the B-4 idempotency memory.
    private func register(key: String) -> Bool {
        if proposedKeys.contains(key) { return false }
        proposedKeys.insert(key)
        return true
    }

    // MARK: - Pure helpers (deterministic; Rust port matches)

    /// The agent name the cycle diary entries are filed under.
    static let agentName = "maintenance-daemon"

    /// The wing the cycle diary entries are filed under, following the
    /// `wing_<agentName>` convention DiaryEntry documents.
    static let diaryWing = "wing_maintenance-daemon"

    /// Invariant I-3: a drawer may not be both secret and publicly
    /// exportable. Reads the two adjective-bitmap accessors (computed,
    /// no Bool stored property); a row failing I-3 is a discipline
    /// violation the daemon proposes for remediation.
    static func isForbiddenCombination(_ drawer: Drawer) -> Bool {
        drawer.adjectiveSensitivity == .secret && drawer.exportability == .public_
    }
}
