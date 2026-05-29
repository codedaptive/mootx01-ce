import Foundation
import Testing
@testable import LocusKit

@Suite("DiaryOperationalTests")
struct DiaryOperationalTests {

    // MARK: - DiaryEventClass raw values (spec § 5.6, bits 0–3)

    @Test("DiaryEventClass.capture raw value is 0")
    func diaryEventClassCapture() { #expect(DiaryEventClass.capture.rawValue == 0) }

    @Test("DiaryEventClass.mutation raw value is 1")
    func diaryEventClassMutation() { #expect(DiaryEventClass.mutation.rawValue == 1) }

    @Test("DiaryEventClass.withdraw raw value is 2")
    func diaryEventClassWithdraw() { #expect(DiaryEventClass.withdraw.rawValue == 2) }

    @Test("DiaryEventClass.expunge raw value is 3")
    func diaryEventClassExpunge() { #expect(DiaryEventClass.expunge.rawValue == 3) }

    @Test("DiaryEventClass.propose raw value is 4")
    func diaryEventClassPropose() { #expect(DiaryEventClass.propose.rawValue == 4) }

    @Test("DiaryEventClass.associate raw value is 5")
    func diaryEventClassAssociate() { #expect(DiaryEventClass.associate.rawValue == 5) }

    @Test("DiaryEventClass.learn raw value is 6")
    func diaryEventClassLearn() { #expect(DiaryEventClass.learn.rawValue == 6) }

    @Test("DiaryEventClass.signalEmission raw value is 7")
    func diaryEventClassSignalEmission() { #expect(DiaryEventClass.signalEmission.rawValue == 7) }

    @Test("DiaryEventClass.maintenance raw value is 8")
    func diaryEventClassMaintenance() { #expect(DiaryEventClass.maintenance.rawValue == 8) }

    @Test("DiaryEventClass.migration raw value is 9")
    func diaryEventClassMigration() { #expect(DiaryEventClass.migration.rawValue == 9) }

    @Test("DiaryEventClass.training raw value is 10")
    func diaryEventClassTraining() { #expect(DiaryEventClass.training.rawValue == 10) }

    @Test("DiaryEventClass.auditTombstone raw value is 11")
    func diaryEventClassAuditTombstone() { #expect(DiaryEventClass.auditTombstone.rawValue == 11) }

    @Test("DiaryEventClass reserved raw values return nil")
    func diaryEventClassReservedAreNil() {
        // Raw values 12–15 are reserved per spec § 5.6.
        #expect(DiaryEventClass(rawValue: 12) == nil)
        #expect(DiaryEventClass(rawValue: 15) == nil)
        #expect(DiaryEventClass(rawValue: -1) == nil)
    }

    @Test("DiaryEventClass round-trips through Codable")
    func diaryEventClassCodableRoundTrip() throws {
        let original = DiaryEventClass.learn
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiaryEventClass.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - DiarySeverity raw values (spec § 5.6, bits 4–6, scale-gapped)

    @Test("DiarySeverity.trace raw value is 0")
    func diarySeverityTrace() { #expect(DiarySeverity.trace.rawValue == 0) }

    @Test("DiarySeverity.info raw value is 2")
    func diarySeverityInfo() { #expect(DiarySeverity.info.rawValue == 2) }

    @Test("DiarySeverity.warning raw value is 4")
    func diarySeverityWarning() { #expect(DiarySeverity.warning.rawValue == 4) }

    @Test("DiarySeverity.error raw value is 6")
    func diarySeverityError() { #expect(DiarySeverity.error.rawValue == 6) }

    // MARK: - DiarySeverity scale-gap nil sentinels

    @Test("DiarySeverity raw value 1 returns nil (scale gap)")
    func diarySeverityGap1() { #expect(DiarySeverity(rawValue: 1) == nil) }

    @Test("DiarySeverity raw value 3 returns nil (scale gap)")
    func diarySeverityGap3() { #expect(DiarySeverity(rawValue: 3) == nil) }

    @Test("DiarySeverity raw value 5 returns nil (scale gap)")
    func diarySeverityGap5() { #expect(DiarySeverity(rawValue: 5) == nil) }

    @Test("DiarySeverity is Comparable in scale order")
    func diarySeverityOrdering() {
        #expect(DiarySeverity.trace < DiarySeverity.info)
        #expect(DiarySeverity.info < DiarySeverity.warning)
        #expect(DiarySeverity.warning < DiarySeverity.error)
    }

    @Test("DiarySeverity is Codable")
    func diarySeverityCodable() throws {
        let data = try JSONEncoder().encode(DiarySeverity.warning)
        let decoded = try JSONDecoder().decode(DiarySeverity.self, from: data)
        #expect(decoded == .warning)
    }

    // MARK: - DiaryActorClass raw values (spec § 5.6, bits 7–9)

    @Test("DiaryActorClass.user raw value is 0")
    func diaryActorClassUser() { #expect(DiaryActorClass.user.rawValue == 0) }

    @Test("DiaryActorClass.substrateDaemon raw value is 1")
    func diaryActorClassSubstrateDaemon() { #expect(DiaryActorClass.substrateDaemon.rawValue == 1) }

    @Test("DiaryActorClass.mcpAgent raw value is 2")
    func diaryActorClassMcpAgent() { #expect(DiaryActorClass.mcpAgent.rawValue == 2) }

    @Test("DiaryActorClass.migrationTool raw value is 3")
    func diaryActorClassMigrationTool() { #expect(DiaryActorClass.migrationTool.rawValue == 3) }

    @Test("DiaryActorClass.federationPeer raw value is 4")
    func diaryActorClassFederationPeer() { #expect(DiaryActorClass.federationPeer.rawValue == 4) }

    @Test("DiaryActorClass is Codable")
    func diaryActorClassCodable() throws {
        let data = try JSONEncoder().encode(DiaryActorClass.mcpAgent)
        let decoded = try JSONDecoder().decode(DiaryActorClass.self, from: data)
        #expect(decoded == .mcpAgent)
    }

    // MARK: - DiaryBatchMembership raw values (spec § 5.6, bits 10–12)

    @Test("DiaryBatchMembership.standalone raw value is 0")
    func diaryBatchMembershipStandalone() { #expect(DiaryBatchMembership.standalone.rawValue == 0) }

    @Test("DiaryBatchMembership.batchStart raw value is 1")
    func diaryBatchMembershipBatchStart() { #expect(DiaryBatchMembership.batchStart.rawValue == 1) }

    @Test("DiaryBatchMembership.batchMember raw value is 2")
    func diaryBatchMembershipBatchMember() { #expect(DiaryBatchMembership.batchMember.rawValue == 2) }

    @Test("DiaryBatchMembership.batchEnd raw value is 3")
    func diaryBatchMembershipBatchEnd() { #expect(DiaryBatchMembership.batchEnd.rawValue == 3) }

    @Test("DiaryBatchMembership is Codable")
    func diaryBatchMembershipCodable() throws {
        let data = try JSONEncoder().encode(DiaryBatchMembership.batchMember)
        let decoded = try JSONDecoder().decode(DiaryBatchMembership.self, from: data)
        #expect(decoded == .batchMember)
    }

    // MARK: - Accessor round-trip suite

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeEntry(operationalBitmap: Int64) -> DiaryEntry {
        DiaryEntry(
            id: "d-test",
            agentName: "bilby",
            entry: "fixture",
            topic: "test",
            wing: "wing_bilby",
            room: "diary",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model",
            operationalBitmap: operationalBitmap
        )
    }

    /// Composite fixture per mission spec:
    ///   eventClass = learn (6)            bits 0–3   = 0x6
    ///   severity   = warning (4)          bits 4–6   = 4  << 4  = 0x040
    ///   actorClass = mcpAgent (2)         bits 7–9   = 2  << 7  = 0x100
    ///   batch      = batchMember (2)      bits 10–12 = 2  << 10 = 0x800
    ///   followup   = requires_action (1)  bit 13     = 1  << 13 = 0x2000
    ///   operationalBitmap = 0x2946
    @Test("Composite 0x2946 round-trips through all five accessors")
    func compositeBitmapRoundTrip() {
        let entry = makeEntry(operationalBitmap: 0x2946)
        #expect(entry.eventClass == .learn)
        #expect(entry.severity == .warning)
        #expect(entry.actorClass == .mcpAgent)
        #expect(entry.batchMembership == .batchMember)
        #expect(entry.requiresFollowup == true)
    }

    @Test("Default-zero bitmap decodes to the zero case of every axis")
    func zeroBitmapDefaults() {
        let entry = makeEntry(operationalBitmap: 0)
        #expect(entry.eventClass == .capture)
        #expect(entry.severity == .trace)
        #expect(entry.actorClass == .user)
        #expect(entry.batchMembership == .standalone)
        #expect(entry.requiresFollowup == false)
    }
}
