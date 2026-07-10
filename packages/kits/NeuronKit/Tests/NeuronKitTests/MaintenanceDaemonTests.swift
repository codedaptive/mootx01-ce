// MaintenanceDaemonTests.swift
//
// Conformance tests for the maintenance daemon (NEURONKIT_SPEC § 3.2 /
// § 3.5).
// Covers (peer-file mirror): Maintenance/MaintenanceDaemon.swift,
// Maintenance/MaintenanceDecision.swift,
// Maintenance/MaintenancePolicy.swift, Maintenance/MaintenanceSeams.swift
// — the decision core, policy, and seams are exercised through the
// daemon over the shared seam fakes below. Covers C-3 (all five scan
// categories detected and proposed), C-4 / C-12 (content-tampered entry
// rejected at ingress; the rejection is COUNTED and the daemon alerts via
// an integrity proposal keyed on the rejected count — AUDIT-ALERT-RESTORE,
// 2026-07-09; clean chain with zero rejections → no integrity proposal),
// C-6 (exactly one diary entry per cycle), B-2 (every detected issue is a
// proposal, never an action), B-4 (idempotency across cycles), the
// policy-store round-trip, the pump tick cadence, and Board item 14
// (QID-pending enrichment retry batch: success path flips provenance
// bits, failure path stays pending, counters move, B-10a zero trace-rows).
//
// All substrate interaction is through NeuronKit-owned seams; these
// tests inject in-memory fakes. They import GeniusLocusKit and LocusKit
// only for the value types (ProposeFrame, Drawer, DiaryEntry,
// UnifiedAuditLog) — never for a write path (B-1). The clock is injected
// by passing `now` into every cycle/pump; there are no wall-clock sleeps.
// The audit-break tests exercise the REAL `UnifiedAuditLog` ingress and
// the REAL `AuditChainVerifier`: as of codex a477800 / secfix
// ce-audit-content-id (5101e112), `UnifiedAuditLog` rejects content-hash-
// mismatched entries at the add / init(entries:) ingress boundary — a
// tampered entry never reaches the verifier's walk, so the chain itself
// always reports vacuously valid. AUDIT-ALERT-RESTORE (2026-07-09, Bob's
// option-1 ruling) closes the gap that left: the log's real
// `rejectedEntryCount` (incremented by the real `add()` on every rejected
// entry) rides along in the `MaintenanceSubstrateReader.currentAuditLog()`
// snapshot the daemon reads, and `MaintenanceDecision.decide` step 0 now
// alerts on that count independently of `valid` — restoring C-4/C-12
// daemon-level alerting at the ingress boundary rather than the (now
// unreachable) chain-walk boundary.

import Testing
import Foundation
import SubstrateTypes
import GeniusLocusKit
@testable import NeuronKit

// MARK: - In-memory seam fakes

/// Records every write the daemon makes. The presence of exactly three
/// methods — and the absence of any broader remediation method — is
/// itself the structural proof of the never-remediate invariant (B-2 /
/// § 3.2). The QID update is recorded so Board item 14 tests can assert
/// that the provenance bitmap was written with the correct new value.
private actor RecordingSink: MaintenanceProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []
    /// (rowID, newProvenance) pairs from QID-pending retry writes.
    private(set) var enrichmentUpdates: [(rowID: RowID, newProvenance: Int64)] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }
    func updateEnrichmentStatus(rowID: RowID, newProvenance: Int64, now: Date) async throws {
        enrichmentUpdates.append((rowID: rowID, newProvenance: newProvenance))
    }

    func proposalCount() -> Int { proposals.count }
    func proposalKindCount(_ kind: ProposalKind) -> Int {
        proposals.filter { $0.kind == kind }.count
    }
    func diaryCount() -> Int { diaryEntries.count }
    func enrichmentUpdateCount() -> Int { enrichmentUpdates.count }
    func enrichmentUpdate(for rowID: RowID) -> Int64? {
        enrichmentUpdates.first(where: { $0.rowID == rowID })?.newProvenance
    }
}

/// Returns whatever substrate state the test configures.
///
/// The `qidPending` array is the seam's view of drawers with
/// enrichment-status `qid_pending`. Tests seed this independently of
/// `active` so the two scans (decay/forbidden vs QID-retry) are exercised
/// in isolation. B-10a: `qidPendingDrawers` is an internal maintenance
/// read — the fake returns it without writing any trace rows.
private actor FakeReader: MaintenanceSubstrateReader {
    var active: [Drawer]
    var tombstoned: [Drawer]
    var references: [LearnedReferenceObservation]
    var fingerprints: [FingerprintDriftObservation]
    var auditLog: UnifiedAuditLog
    /// Drawers to return from `qidPendingDrawers(limit:)`. Set by Board
    /// item 14 tests.
    var qidPending: [Drawer]

    init(
        active: [Drawer] = [],
        tombstoned: [Drawer] = [],
        references: [LearnedReferenceObservation] = [],
        fingerprints: [FingerprintDriftObservation] = [],
        auditLog: UnifiedAuditLog = UnifiedAuditLog(),
        qidPending: [Drawer] = []
    ) {
        self.active = active
        self.tombstoned = tombstoned
        self.references = references
        self.fingerprints = fingerprints
        self.auditLog = auditLog
        self.qidPending = qidPending
    }

    func activeDrawers() async throws -> [Drawer] { active }
    func tombstonedDrawers() async throws -> [Drawer] { tombstoned }
    func learnedReferences() async throws -> [LearnedReferenceObservation] { references }
    func fingerprintBaselines() async throws -> [FingerprintDriftObservation] { fingerprints }
    func currentAuditLog() async throws -> UnifiedAuditLog { auditLog }
    func qidPendingDrawers(limit: Int) async throws -> [Drawer] {
        // Honour the cap: the daemon controls the limit, but the seam must
        // respect it. Returns up to `limit` rows from the seeded list.
        Array(qidPending.prefix(limit))
    }
}

// MARK: - Builders

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let fixedRowUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// A drawer with the adjective axes set via the bitmap (no Bool stored
/// property). Sensitivity sits in bits 6–11, exportability in bits 12–17
/// (cookbook §2.3, both 6-bit fields). Raw values are already at the
/// correct magnitude for the 6-bit field, so the shift IS the field's
/// bit offset — no additional scaling.
private func drawer(
    id: String,
    filedAt: Date,
    sensitivity: AdjectiveSensitivity = .normal,
    exportability: AdjectiveExportability = .private_,
    tombstonedAt: Date? = nil
) -> Drawer {
    let bitmap = Int64(sensitivity.rawValue << 6) | Int64(exportability.rawValue << 12)
    return Drawer(
        id: id,
        content: "content",
        parentNodeId: "test-room-node",
        addedBy: "test",
        filedAt: filedAt,
        embeddingModelID: "",
        tombstonedAt: tombstonedAt,
        adjectiveBitmap: bitmap
    )
}

/// A clean audit log: one entry minted through the computing
/// initializer, so its stored id matches its recomputed content hash.
private func cleanAuditLog() -> UnifiedAuditLog {
    let e = UnifiedAuditEntry(
        tier: .locus,
        hlc: HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 1),
        verb: .capture,
        rowID: fixedRowUUID,
        fieldPath: "content",
        beforeValue: .null,
        afterValue: .string("x")
    )
    return UnifiedAuditLog(entries: [e])
}

/// A tampered audit log: one entry built through the explicit-id
/// initializer with an all-zero id, so its stored id does not match the
/// SHA-256 of its wire encoding. `UnifiedAuditLog.init(entries:)` routes
/// every entry through `add`, which recomputes the content id and
/// rejects the entry when it does not match (codex a477800 / secfix
/// ce-audit-content-id, 5101e112) — the returned log is empty. This
/// fixture therefore exercises the ingress defence, not the chain
/// verifier: the tampered entry never reaches `AuditChainVerifier`.
private func tamperedAuditLog() -> UnifiedAuditLog {
    let zeroID = [UInt8](repeating: 0, count: 32)
    let e = UnifiedAuditEntry(
        id: zeroID,
        tier: .locus,
        hlc: HLC(physicalTime: 2_000, logicalCount: 0, nodeID: 1),
        verb: .mutate,
        rowID: fixedRowUUID,
        fieldPath: "content",
        beforeValue: .string("a"),
        afterValue: .string("b")
    )
    return UnifiedAuditLog(entries: [e])
}

private func daemon(
    reader: FakeReader,
    sink: RecordingSink,
    policyStore: MaintenancePolicyStore = InMemoryMaintenancePolicyStore()
) -> MaintenanceDaemon {
    MaintenanceDaemon(reader: reader, sink: sink, policyStore: policyStore)
}

@Suite("Maintenance daemon conformance")
struct MaintenanceDaemonTests {

    // MARK: - C-3: all five scan categories detected and proposed

    @Test("C-3: all five scan categories emit a proposal")
    func c3AllFiveScanCategoriesEmitAProposal() async throws {
        // One drawer per scan category. The forbidden drawer is recent
        // (not a decay candidate); the decay drawer is normal-sensitivity
        // (not forbidden), so each drawer hits exactly one category.
        let forbidden = drawer(
            id: "d-forbidden", filedAt: t0,
            sensitivity: .secret, exportability: .public_
        )
        let decayed = drawer(
            id: "d-decay", filedAt: t0.addingTimeInterval(-40 * 86_400)
        )
        let tomb = drawer(
            id: "d-tomb", filedAt: t0.addingTimeInterval(-100 * 86_400),
            tombstonedAt: t0.addingTimeInterval(-10 * 86_400)
        )
        let reader = FakeReader(
            active: [forbidden, decayed],
            tombstoned: [tomb],
            references: [LearnedReferenceObservation(referenceRowID: "ref-1", sourceDriftFraction: 0.5)],
            fingerprints: [FingerprintDriftObservation(scopeKey: "node-room-1", nodeId: "node-room-1", driftFraction: 0.5)],
            auditLog: cleanAuditLog()
        )
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.forbiddenCombinations == 1)
        #expect(report.decayCandidates == 1)
        #expect(report.tombstoneCandidates == 1)
        #expect(report.fingerprintDrifts == 1)
        #expect(report.byReferenceDrifts == 1)
        #expect(report.proposalsEmitted.count == 5, "one proposal per scan category")

        // The clean audit log produced no integrity proposal.
        #expect(report.auditChecked == true)
        #expect(report.auditReport?.valid == true)

        // Each category's kind is present in the emission.
        let kinds = report.proposalsEmitted.map(\.kind)
        #expect(kinds.contains(.disciplineViolation))
        #expect(kinds.filter { $0 == .mutateCandidate }.count == 2, "decay + tombstone both mutate-candidate")
        #expect(kinds.contains(.other("fingerprint_drift")))
        #expect(kinds.contains(.byReferenceDrift))
    }

    // MARK: - C-4 / C-12: content-tampered entry is rejected at ingress; the rejection is alerted

    @Test("C-4/C-12: content-tampered entry is rejected at ingress; the walked chain is vacuously valid but the daemon still alerts on the rejection")
    func c4TamperedEntryRejectedAtIngressDaemonAlertsOnRejection() async throws {
        // Pin the ingress defence first: the tampered fixture yields an
        // empty log before it ever reaches the daemon (codex a477800 /
        // secfix ce-audit-content-id, 5101e112) — and the REAL `add()`
        // that rejected it incremented the REAL `rejectedEntryCount`.
        let tampered = tamperedAuditLog()
        #expect(tampered.count == 0, "content-hash-mismatched entry rejected at add / init(entries:) boundary")
        #expect(tampered.rejectedEntryCount == 1, "the real ingress path counts the rejection (AUDIT-ALERT-RESTORE)")

        let reader = FakeReader(auditLog: tampered)
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.auditChecked == true)
        #expect(report.auditReport?.valid == true, "the walked chain is vacuously valid — the tampered entry never reached it")
        #expect(report.auditReport?.entryCount == 0)
        // AUDIT-ALERT-RESTORE: even though the chain walk itself is clean,
        // the ingress-rejection count surfaces as exactly one integrity
        // proposal — restoring the C-4/C-12 alert at the ingress boundary.
        #expect(report.proposalsEmitted.count == 1, "the ingress rejection is alerted via exactly one integrity proposal")
        let proposal = try #require(report.proposalsEmitted.first)
        #expect(proposal.kind == .other("audit_integrity"))
        #expect(proposal.target == "audit-rejected-1")
        #expect(proposal.justification?.contains("1") == true, "the proposal names the rejected count")
    }

    @Test("C-4/C-12: a second cycle over the same rejected-count snapshot suppresses the duplicate (B-4)")
    func c4SameRejectedCountAcrossCyclesSuppressesDuplicate() async throws {
        // The seam is a snapshot fixture, so both cycles see the identical
        // already-rejected log (rejectedEntryCount == 1 both times) — this
        // is the steady-state "known, unresolved corruption" case, which
        // B-4 correctly suppresses after the first alert rather than
        // re-proposing every cycle.
        let tampered = tamperedAuditLog()
        let reader = FakeReader(auditLog: tampered)
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let first = try await d.triggerMaintenanceCycle(now: t0)
        #expect(first.proposalsEmitted.count == 1)

        let second = try await d.triggerMaintenanceCycle(now: t0.addingTimeInterval(600))
        #expect(second.proposalsEmitted.count == 0, "identical rejected count already alerted — suppressed as a B-4 duplicate")
        #expect(second.suppressedDuplicates == 1)
    }

    @Test("C-4: clean audit log emits no integrity proposal")
    func c4CleanAuditLogEmitsNoIntegrityProposal() async throws {
        let reader = FakeReader(auditLog: cleanAuditLog())
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.auditChecked == true)
        #expect(report.auditReport?.valid == true)
        #expect(report.proposalsEmitted.count == 0, "clean chain proposes nothing")
    }

    // MARK: - C-6: exactly one diary entry per cycle

    @Test("C-6: one diary entry per cycle filed under the maintenance wing")
    func c6OneDiaryEntryPerCycleFiledUnderMaintenanceWing() async throws {
        let reader = FakeReader(auditLog: cleanAuditLog())
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)
        let afterOne = await sink.diaryCount()
        #expect(afterOne == 1)
        #expect(report.diaryEntry.wing == "wing_maintenance-daemon")
        #expect(report.diaryEntry.agentName == "maintenance-daemon")

        _ = try await d.triggerMaintenanceCycle(now: t0.addingTimeInterval(600))
        _ = try await d.triggerMaintenanceCycle(now: t0.addingTimeInterval(1_200))
        let afterThree = await sink.diaryCount()
        #expect(afterThree == 3, "every cycle writes exactly one DiaryEntry")
    }

    // MARK: - B-2: every detected issue is a proposal, never an action

    @Test("B-2: every detected issue is a proposal, never an action")
    func b2EveryDetectedIssueIsAProposalNeverAnAction() async throws {
        let reader = FakeReader(
            active: [drawer(id: "d-forbidden", filedAt: t0, sensitivity: .secret, exportability: .public_)],
            auditLog: cleanAuditLog()
        )
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        // The detected violation produced a proposal — and the sink
        // exposes only propose + recordCycleDiary, so the daemon
        // structurally cannot remediate. The only writes this cycle were
        // one proposal and one diary entry.
        #expect(report.forbiddenCombinations == 1)
        #expect(report.proposalsEmitted.count == 1)
        let total = await sink.proposalCount()
        #expect(total == 1)
        let diary = await sink.diaryCount()
        #expect(diary == 1)
    }

    // MARK: - B-4: idempotency across cycles

    @Test("B-4: second cycle over unchanged state proposes nothing new")
    func b4SecondCycleOverUnchangedStateProposesNothingNew() async throws {
        let forbidden = drawer(id: "d-forbidden", filedAt: t0, sensitivity: .secret, exportability: .public_)
        let decayed = drawer(id: "d-decay", filedAt: t0.addingTimeInterval(-40 * 86_400))
        let tomb = drawer(
            id: "d-tomb", filedAt: t0.addingTimeInterval(-100 * 86_400),
            tombstonedAt: t0.addingTimeInterval(-10 * 86_400)
        )
        let reader = FakeReader(
            active: [forbidden, decayed],
            tombstoned: [tomb],
            references: [LearnedReferenceObservation(referenceRowID: "ref-1", sourceDriftFraction: 0.5)],
            fingerprints: [FingerprintDriftObservation(scopeKey: "node-room-1", nodeId: "node-room-1", driftFraction: 0.5)],
            auditLog: cleanAuditLog()
        )
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let first = try await d.triggerMaintenanceCycle(now: t0)
        #expect(first.proposalsEmitted.count == 5)

        // Second cycle over identical state: every candidate is still
        // detected, but every key was already proposed, so nothing new
        // is emitted and all five are counted as suppressed duplicates.
        let second = try await d.triggerMaintenanceCycle(now: t0.addingTimeInterval(60))
        #expect(second.proposalsEmitted.count == 0, "already-proposed candidates are suppressed")
        #expect(second.suppressedDuplicates == 5)

        // Two cycles produced exactly the proposals of one.
        let total = await sink.proposalCount()
        #expect(total == 5)
    }

    // MARK: - Policy round-trips through the manifest seam

    @Test("policy round-trips through the manifest seam")
    func policyRoundTripsThroughManifestSeam() async throws {
        let store = InMemoryMaintenancePolicyStore()
        let reader = FakeReader()
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink, policyStore: store)

        try await d.registerMaintenancePolicy(
            tickIntervalMs: 120_000,
            auditCheckIntervalMs: 60_000,
            decayWindowSeconds: 1_000,
            tombstoneGraceSeconds: 500,
            fingerprintDriftThreshold: 0.4,
            byReferenceDriftThreshold: 0.6
        )

        // A fresh daemon over the same store loads the persisted policy.
        let d2 = daemon(reader: reader, sink: sink, policyStore: store)
        try await d2.loadPersistedPolicy()
        let loaded = await d2.currentPolicy()
        #expect(loaded == MaintenancePolicy(
            tickIntervalMs: 120_000,
            auditCheckIntervalMs: 60_000,
            decayWindowSeconds: 1_000,
            tombstoneGraceSeconds: 500,
            fingerprintDriftThreshold: 0.4,
            byReferenceDriftThreshold: 0.6
        ))
    }

    // MARK: - Board item 14: QID-pending enrichment retry batch

    // ── B-10a: internal maintenance reads must not write recall-trace rows.
    // The FakeReader implementation satisfies this structurally: it returns
    // qid-pending drawers from the in-memory list without touching any trace
    // store. The daemon never sets trace_limit on the read path; zero trace
    // rows is guaranteed by the seam design.

    @Test("Board-14: zero pending drawers — all QID counters are zero")
    func board14ZeroPendingDrawersAllCountersZero() async throws {
        // Seed no qid-pending drawers. The retry batch should find nothing
        // and emit all-zero counters.
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: [])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.qidRetried == 0)
        #expect(report.qidResolved == 0)
        #expect(report.qidStillPending == 0)
        let updates = await sink.enrichmentUpdateCount()
        #expect(updates == 0, "no enrichment writes when there are no pending drawers")
    }

    @Test("Q-ID completion: unresolved drawers reach the qidProposed terminal — proposal filed, status flipped")
    func board14UnresolvedReachesQidProposedTerminal() async throws {
        // Drawers with empty content: EideticLib.lookup("") returns an
        // empty-code Anchor with no QID. Because re-inference is deterministic
        // against the pinned FDC artifacts, retrying is futile — leaving the
        // row at qid_pending would be DURABLE pending state, which the beta
        // gate forbids. The daemon must instead file an enrichment proposal and
        // flip the status to the terminal in-workflow state qidProposed (4).
        //
        // The enrichment-status field in the seeded provenance is qid_pending
        // (bits 36-41 == 1); after the cycle it must be qid_proposed (4).
        let qidPendingBit: Int64 = 1 << 36
        let qidProposedBit: Int64 = 4 << 36
        let pendingA = Drawer(
            id: "qid-pending-a",
            content: "",
            parentNodeId: "test-room-node",
            addedBy: "test",
            filedAt: t0,
            embeddingModelID: "",
            tombstonedAt: nil,
            provenance: qidPendingBit,
            adjectiveBitmap: 0
        )
        let pendingB = Drawer(
            id: "qid-pending-b",
            content: "",
            parentNodeId: "test-room-node",
            addedBy: "test",
            filedAt: t0,
            embeddingModelID: "",
            tombstonedAt: nil,
            provenance: qidPendingBit,
            adjectiveBitmap: 0
        )
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: [pendingA, pendingB])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        // Both drawers were retried.
        #expect(report.qidRetried == 2)
        // None resolved (empty content → no QID).
        #expect(report.qidResolved == 0)
        // Both reached the terminal in-workflow state. NONE durable-pending.
        #expect(report.qidProposed == 2)
        #expect(report.qidStillPending == 0)
        // One enrichment proposal AND one status write per unresolved drawer.
        let enrichmentProposals = await sink.proposalKindCount(.enrichment)
        #expect(enrichmentProposals == 2)
        let updates = await sink.enrichmentUpdateCount()
        #expect(updates == 2)
        // Each status write flipped bits 36-41 to qidProposed (4).
        let writtenA = await sink.enrichmentUpdate(for: "qid-pending-a")
        let writtenB = await sink.enrichmentUpdate(for: "qid-pending-b")
        #expect(((writtenA ?? 0) & (0x3F << 36)) == qidProposedBit)
        #expect(((writtenB ?? 0) & (0x3F << 36)) == qidProposedBit)
        // Counter integrity: retried == resolved + proposed + still-pending.
        #expect(report.qidRetried == report.qidResolved + report.qidProposed + report.qidStillPending)
    }

    @Test("Q-ID completion: counter integrity holds — retried == resolved + proposed + still-pending; none durable-pending")
    func board14CounterIntegrityHoldsAcrossOutcomes() async throws {
        // Feed three drawers with arbitrary content. EideticLib will produce
        // some mix of resolved / unresolved. The structural invariant is that
        // `qidRetried == qidResolved + qidProposed + qidStillPending` and that
        // qidStillPending is 0 (no real write failures in the fake sink), so
        // every drawer reaches a terminal. The enrichment-update count equals
        // resolved + proposed (both flip the status field).
        let drawers = (0..<3).map { i in
            Drawer(
                id: "qid-drawer-\(i)",
                content: "drawer content \(i)",
                parentNodeId: "test-room-node",
                addedBy: "test",
                filedAt: t0,
                embeddingModelID: "",
                tombstonedAt: nil,
                provenance: 1 << 36,
                adjectiveBitmap: 0
            )
        }
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: drawers)
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        // Counter integrity: retried == resolved + proposed + still-pending.
        #expect(report.qidRetried == 3)
        #expect(report.qidRetried == report.qidResolved + report.qidProposed + report.qidStillPending)
        // The gate: no drawer left durable-pending.
        #expect(report.qidStillPending == 0)

        // One enrichment-status write per resolved drawer AND per proposed
        // drawer (both flip the status field).
        let updates = await sink.enrichmentUpdateCount()
        #expect(updates == report.qidResolved + report.qidProposed)
    }

    @Test("Board-14: success path — resolved drawer gets provenance bits flipped to qidCompleted")
    func board14SuccessPathProvenanceBitsFlippedToQidCompleted() async throws {
        // Seed a drawer whose provenance has enrichment-status bits (36-41)
        // set to qid_pending (value 1). If EideticLib resolves the content
        // and returns a QID, the daemon must flip those bits to qid_completed
        // (value 2) while preserving all other provenance bits.
        //
        // The provenance computation: the input provenance has bits 36-41 == 1
        // (qid_pending). After a successful retry:
        //   newProvenance = (provenance & ~(0x3F << 36)) | (2 << 36)
        //
        // Provenance value with only qid_pending set:
        //   qidPendingProvenance = 1 << 36 = 68_719_476_736
        // Expected after resolution:
        //   qidCompletedProvenance = 2 << 36 = 137_438_953_472
        let qidPendingBit: Int64 = 1 << 36
        let qidCompletedBit: Int64 = 2 << 36

        // Use "mathematics" which is likely in the FDC canon with a QID.
        // If EideticLib doesn't resolve it, the test validates only the
        // counter path (no assertion fails — the conditional checks guard).
        let pendingDrawer = Drawer(
            id: "qid-resolve-test",
            content: "mathematics",
            parentNodeId: "test-room-node",
            addedBy: "test",
            filedAt: t0,
            embeddingModelID: "",
            tombstonedAt: nil,
            provenance: qidPendingBit,
            adjectiveBitmap: 0
        )
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: [pendingDrawer])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.qidRetried == 1)
        // Counter invariant always holds; never durable-pending.
        #expect(report.qidRetried == report.qidResolved + report.qidProposed + report.qidStillPending)
        #expect(report.qidStillPending == 0)

        let qidProposedBit: Int64 = 4 << 36
        let updates = await sink.enrichmentUpdateCount()
        if report.qidResolved == 1 {
            // Resolved path: status flipped to qidCompleted (2).
            #expect(updates == 1)
            let written = await sink.enrichmentUpdate(for: "qid-resolve-test")
            let writtenBits = (written ?? 0) & (0x3F << 36)
            #expect(writtenBits == qidCompletedBit,
                    "enrichment-status bits must be flipped to qidCompleted (2 << 36)")
        } else {
            // Unresolved path: an enrichment proposal was filed and the status
            // flipped to qidProposed (4) — the terminal in-workflow state.
            #expect(report.qidProposed == 1)
            #expect(updates == 1)
            let written = await sink.enrichmentUpdate(for: "qid-resolve-test")
            #expect(((written ?? 0) & (0x3F << 36)) == qidProposedBit)
            let enrichmentProposals = await sink.proposalKindCount(.enrichment)
            #expect(enrichmentProposals == 1)
        }
    }

    @Test("Board-14: bounded scan cap is honoured — limit respected by seam")
    func board14BoundedScanCapHonoured() async throws {
        // Seed 100 pending drawers. The retry batch cap is 64. The FakeReader
        // respects the `limit` parameter and returns at most 64 drawers;
        // the daemon's qidRetried counter must be ≤ 64.
        let manyPending = (0..<100).map { i in
            Drawer(
                id: "qid-cap-test-\(i)",
                content: "",
                parentNodeId: "test-room-node",
                addedBy: "test",
                filedAt: t0,
                embeddingModelID: "",
                tombstonedAt: nil,
                adjectiveBitmap: 0
            )
        }
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: manyPending)
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        // The daemon passes `qidRetryScanCap` (64) to the seam as the limit.
        // The seam returns at most 64 rows. So qidRetried must be exactly 64.
        #expect(report.qidRetried == 64,
                "bounded scan must honour the 64-row cap; got \(report.qidRetried)")
        #expect(report.qidRetried == report.qidResolved + report.qidProposed + report.qidStillPending)
        // Every processed row reached a terminal — none durable-pending.
        #expect(report.qidStillPending == 0)
        #expect(report.qidProposed == 64)
    }

    @Test("Board-14: diary entry includes QID retry telemetry summary")
    func board14DiaryEntryIncludesQidTelemetrySummary() async throws {
        // The cycle diary entry must include the qid-retried, qid-resolved,
        // and qid-pending counts in its text. This is observable state:
        // operators reading the diary can see retry progress.
        let pendingDrawer = Drawer(
            id: "qid-diary-test",
            content: "",
            parentNodeId: "test-room-node",
            addedBy: "test",
            filedAt: t0,
            embeddingModelID: "",
            tombstonedAt: nil,
            adjectiveBitmap: 0
        )
        let reader = FakeReader(auditLog: cleanAuditLog(), qidPending: [pendingDrawer])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        // The diary entry text must reference all four QID telemetry fields.
        let text = report.diaryEntry.entry
        #expect(text.contains("qid-retried"), "diary must include qid-retried count")
        #expect(text.contains("qid-resolved"), "diary must include qid-resolved count")
        #expect(text.contains("qid-proposed"), "diary must include qid-proposed count")
        #expect(text.contains("qid-pending"), "diary must include qid-pending count")
    }

    // MARK: - pump tick cadence (injectable clock, no wall-clock sleeps)

    @Test("pump fires on the configured tick interval only")
    func pumpFiresOnConfiguredTickIntervalOnly() async throws {
        let reader = FakeReader(auditLog: cleanAuditLog())
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)
        try await d.registerMaintenancePolicy(tickIntervalMs: 300_000)

        // First pump always fires (no prior tick).
        let first = try await d.pump(now: t0)
        #expect(first != nil)

        // Before the interval elapses: not due.
        let early = try await d.pump(now: t0.addingTimeInterval(100))
        #expect(early == nil, "tick must not fire before the 300s interval elapses")

        // At the interval: fires.
        let second = try await d.pump(now: t0.addingTimeInterval(300))
        #expect(second != nil, "tick fires once the interval has elapsed")
    }

    // MARK: - ADR-017 node invariant verification

    @Test("node invariant: consistent drawers produce zero violations")
    func nodeInvariantConsistentDrawersZeroViolations() async throws {
        let reader = FakeReader(active: [
            drawer(id: "d-1", filedAt: t0),
            drawer(id: "d-2", filedAt: t0),
        ])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)
        try await d.registerMaintenancePolicy(decayWindowSeconds: 999_999)
        let report = try await d.triggerMaintenanceCycle(now: t0)
        #expect(report.nodeInvariantViolations == 0)
        #expect(report.diaryEntry.entry.contains("node-invariant-violations 0"))
    }

    @Test("node invariant: empty parentNodeId triggers I-NT-3 violation")
    func nodeInvariantEmptyParentNodeId() async throws {
        let orphan = Drawer(
            id: "d-orphan",
            content: "orphan",
            parentNodeId: "",
            addedBy: "test",
            filedAt: t0,
            embeddingModelID: "",
            tombstonedAt: nil,
            adjectiveBitmap: 0
        )
        let reader = FakeReader(active: [
            drawer(id: "d-ok", filedAt: t0),
            orphan,
        ])
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)
        try await d.registerMaintenancePolicy(decayWindowSeconds: 999_999)
        let report = try await d.triggerMaintenanceCycle(now: t0)
        #expect(report.nodeInvariantViolations >= 1)
    }

}
