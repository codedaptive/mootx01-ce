// MaintenanceDaemonTests.swift
//
// Conformance tests for the maintenance daemon (NEURONKIT_SPEC § 3.2 /
// § 3.5). Covers C-3 (all five scan categories detected and proposed),
// C-4 / C-12 (audit-chain break → integrity proposal; clean chain →
// none), C-6 (exactly one diary entry per cycle), B-2 (every detected
// issue is a proposal, never an action), B-4 (idempotency across
// cycles), the policy-store round-trip, and the pump tick cadence.
//
// All substrate interaction is through NeuronKit-owned seams; these
// tests inject in-memory fakes. They import GeniusLocusKit and LocusKit
// only for the value types (ProposeFrame, Drawer, DiaryEntry,
// UnifiedAuditLog) — never for a write path (B-1). The clock is injected
// by passing `now` into every cycle/pump; there are no wall-clock sleeps.
// The audit-break test exercises the REAL `AuditChainVerifier`, building
// a tampered `UnifiedAuditLog` via the explicit-id entry initializer so
// the stored id no longer matches the recomputed content hash.

import Testing
import Foundation
import SubstrateTypes
import GeniusLocusKit
import LocusKit
@testable import NeuronKit

// MARK: - In-memory seam fakes

/// Records every write the daemon makes. The presence of exactly two
/// methods — and the absence of any remediation method — is itself the
/// structural proof of the never-remediate invariant (B-2 / § 3.2).
private actor RecordingSink: MaintenanceProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }

    func proposalCount() -> Int { proposals.count }
    func diaryCount() -> Int { diaryEntries.count }
}

/// Returns whatever substrate state the test configures.
private actor FakeReader: MaintenanceSubstrateReader {
    var active: [Drawer]
    var tombstoned: [Drawer]
    var references: [LearnedReferenceObservation]
    var fingerprints: [FingerprintDriftObservation]
    var auditLog: UnifiedAuditLog

    init(
        active: [Drawer] = [],
        tombstoned: [Drawer] = [],
        references: [LearnedReferenceObservation] = [],
        fingerprints: [FingerprintDriftObservation] = [],
        auditLog: UnifiedAuditLog = UnifiedAuditLog()
    ) {
        self.active = active
        self.tombstoned = tombstoned
        self.references = references
        self.fingerprints = fingerprints
        self.auditLog = auditLog
    }

    func activeDrawers() async throws -> [Drawer] { active }
    func tombstonedDrawers() async throws -> [Drawer] { tombstoned }
    func learnedReferences() async throws -> [LearnedReferenceObservation] { references }
    func fingerprintBaselines() async throws -> [FingerprintDriftObservation] { fingerprints }
    func currentAuditLog() async throws -> UnifiedAuditLog { auditLog }
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
        wing: "w",
        room: "r",
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
/// initializer with an all-zero id. The verifier recomputes the id from
/// the entry's fields and finds it does not match the stored (zero) id,
/// so the chain reports `valid == false`. firstBrokenAt is the entry's
/// HLC physical time (2000 ms → 2.0s epoch). This drives the REAL
/// AuditChainVerifier — no mock.
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
            fingerprints: [FingerprintDriftObservation(scopeKey: "wing_a/room_b", driftFraction: 0.5)],
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

    // MARK: - C-4 / C-12: audit-chain break → integrity proposal

    @Test("C-4/C-12: tampered audit log emits an integrity proposal")
    func c4TamperedAuditLogEmitsIntegrityProposal() async throws {
        let reader = FakeReader(auditLog: tamperedAuditLog())
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerMaintenanceCycle(now: t0)

        #expect(report.auditChecked == true)
        #expect(report.auditReport?.valid == false, "real AuditChainVerifier flags the tampered entry")
        #expect(report.proposalsEmitted.count == 1, "exactly the audit-integrity proposal")
        let frame = try #require(report.proposalsEmitted.first)
        #expect(frame.kind == .other("audit_integrity"))
        // firstBrokenAt is 2000ms epoch → "2000" tag in the target RowID.
        #expect(frame.target == "audit-break-2000")
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
            fingerprints: [FingerprintDriftObservation(scopeKey: "wing_a/room_b", driftFraction: 0.5)],
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
}
