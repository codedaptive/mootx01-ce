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
        // ── Step 0: audit-chain integrity monitor (§ 3.5) ──────────────
        // Verify on the audit-check cadence, tracked independently of the
        // scan tick so a slow full-chain verification need not run every
        // tick. First run always checks (lastAuditCheckAt == nil). The
        // verification math is GLK-owned (`AuditChainVerifier.verify`); the
        // daemon owns the scheduling and turns the verdict into the pure
        // core's `AuditVerdict` input.
        var auditChecked = false
        var auditReport: AuditChainReport? = nil
        var auditVerdict: MaintenanceDecision.AuditVerdict? = nil
        let auditDue: Bool = {
            guard let last = lastAuditCheckAt else { return true }
            let elapsedMs = now.timeIntervalSince(last) * 1000.0
            return elapsedMs >= Double(policy.auditCheckIntervalMs)
        }()
        if auditDue {
            let log = try await reader.currentAuditLog()
            let report = AuditChainVerifier.verify(log)
            auditChecked = true
            auditReport = report
            lastAuditCheckAt = now
            // First broken entry's epoch-milliseconds, when supplied, is
            // the stable break identity so re-detecting the SAME break
            // re-derives the SAME key and is idempotently suppressed.
            let brokenMillis = report.firstBrokenAt.map {
                Int64($0.timeIntervalSince1970 * 1000.0)
            }
            auditVerdict = MaintenanceDecision.AuditVerdict(
                valid: report.valid, firstBrokenAtMillis: brokenMillis)
        }

        // ── Steps 1–5 input gathering: read the seams and project each
        // scan into the pure core's identity-free shape. The `now`-relative
        // age subtractions and the I-3 secret-AND-public bitmap read (on
        // the substrate `Drawer` type) stay here; the THRESHOLDS, KEY
        // FORMATS, SCAN ORDER, and B-4 dedup all live in the core.
        let active = try await reader.activeDrawers()
        let forbiddenDrawerIDs = active.filter(Self.isForbiddenCombination).map(\.id)
        let agedActive = active.map {
            MaintenanceDecision.AgedRow(id: $0.id, ageSeconds: now.timeIntervalSince($0.filedAt))
        }
        let tombstoned = try await reader.tombstonedDrawers()
        // `tombstonedAt` is always set on a tombstoned row, but guard nil
        // defensively (a malformed row is simply skipped, not crashed).
        let agedTombstoned = tombstoned.compactMap { drawer -> MaintenanceDecision.AgedRow? in
            guard let tombstonedAt = drawer.tombstonedAt else { return nil }
            return MaintenanceDecision.AgedRow(
                id: drawer.id, ageSeconds: now.timeIntervalSince(tombstonedAt))
        }
        let fingerprintObs = try await reader.fingerprintBaselines()
        let fingerprintDrift = fingerprintObs.map {
            MaintenanceDecision.DriftRow(key: $0.scopeKey, driftFraction: $0.driftFraction)
        }
        let references = try await reader.learnedReferences()
        let referenceDrift = references.map {
            MaintenanceDecision.DriftRow(key: $0.referenceRowID, driftFraction: $0.sourceDriftFraction)
        }

        // ── Delegate every DECISION to the pure core (steps 0–5) ───────
        // Conformance-gated against the Rust port
        // (NeuronKit/rust/src/maintenance_decision.rs). See MaintenanceDecision.swift.
        let outcome = MaintenanceDecision.decide(
            audit: auditVerdict,
            forbiddenDrawerIDs: forbiddenDrawerIDs,
            agedActive: agedActive,
            decayWindowSeconds: policy.decayWindowSeconds,
            agedTombstoned: agedTombstoned,
            tombstoneGraceSeconds: policy.tombstoneGraceSeconds,
            fingerprintDrift: fingerprintDrift,
            fingerprintDriftThreshold: policy.fingerprintDriftThreshold,
            referenceDrift: referenceDrift,
            byReferenceDriftThreshold: policy.byReferenceDriftThreshold,
            alreadyProposedKeys: proposedKeys
        )
        proposedKeys = outcome.updatedProposedKeys

        // Enact the decisions: build one ProposeFrame per emitted decision
        // (in the core's scan order), choosing the ProposalKind and
        // justification from the category. The audit entry-count comes from
        // the in-scope `auditReport`; the drift fractions come from each
        // decision's `detailValue`.
        var emitted: [ProposeFrame] = []
        for decision in outcome.emitted {
            let frame = frame(for: decision, auditReport: auditReport)
            try await sink.propose(frame)
            emitted.append(frame)
        }
        let suppressed = outcome.suppressedDuplicates
        let forbiddenCombinations = outcome.forbiddenCombinations
        let decayCandidates = outcome.decayCandidates
        let tombstoneCandidates = outcome.tombstoneCandidates
        let fingerprintDrifts = outcome.fingerprintDrifts
        let byReferenceDrifts = outcome.byReferenceDrifts

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

    // MARK: - Proposal frame construction

    /// Build the `ProposeFrame` for one core decision, choosing the
    /// `ProposalKind` and the human-facing justification from the decision's
    /// category. The justification text is Swift-side (not part of the
    /// portable conformance contract — the same boundary the dreaming port
    /// drew); its variable parts come from the decision's `target` /
    /// `detailValue` and, for the audit category, the in-scope
    /// `auditReport`.
    private func frame(
        for decision: MaintenanceDecision.Decision,
        auditReport: AuditChainReport?
    ) -> ProposeFrame {
        switch decision.category {
        case .auditIntegrity:
            // The break tag is the suffix of the audit key after the "|".
            let tag = decision.key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "unknown"
            return ProposeFrame(
                target: decision.target,
                // No typed ProposalKind case exists for audit integrity;
                // use the documented `.other` escape hatch rather than
                // adding a case to GLK's ProposalKind.
                kind: .other("audit_integrity"),
                justification:
                    "maintenance: audit chain integrity violation; "
                    + "first broken entry at \(tag) "
                    + "(entries \(auditReport?.entryCount ?? 0))")
        case .disciplineViolation:
            return ProposeFrame(
                target: decision.target,
                kind: .disciplineViolation,
                justification:
                    "maintenance: forbidden combination (secret AND public) on drawer \(decision.target)")
        case .decay:
            return ProposeFrame(
                target: decision.target,
                kind: .mutateCandidate,
                justification:
                    "maintenance: decay candidate; drawer \(decision.target) older than decay window")
        case .tombstone:
            return ProposeFrame(
                target: decision.target,
                kind: .mutateCandidate,
                justification:
                    "maintenance: expunge candidate; drawer \(decision.target) tombstoned past grace window")
        case .fingerprintDrift:
            return ProposeFrame(
                target: decision.target,
                kind: .other("fingerprint_drift"),
                justification:
                    "maintenance: fingerprint drift \(decision.detailValue ?? 0) on scope \(decision.target)")
        case .byReferenceDrift:
            return ProposeFrame(
                target: decision.target,
                kind: .byReferenceDrift,
                justification:
                    "maintenance: byReference source drift \(decision.detailValue ?? 0) "
                    + "on reference \(decision.target)")
        }
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
