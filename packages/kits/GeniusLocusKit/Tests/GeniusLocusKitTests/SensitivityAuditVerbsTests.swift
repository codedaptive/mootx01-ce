import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// out-of-band sensitivity grants (Audit) — the sensitivity-unlock audit seam. Mirrors
/// GRT_AuditEmissionTests' harness (FUP-C's federation-grant audit seam),
/// applied to the four NEW sensitivity-unlock verbs.
@Suite("Sensitivity-unlock audit emission")
struct SensitivityAuditVerbsTests {

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "sensitivity-audit-owner")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func recordSensitivityGrantIssuedEmitsExpectedEntry() async throws {
        let (kit, handle) = try await openOneEstate()
        let grantID = UUID()
        let expiresAt = now.addingTimeInterval(30 * 60)
        try await kit.recordSensitivityGrantIssued(handle, tier: .secret, grantID: grantID, expiresAt: expiresAt, now: now)

        let log = try await kit.auditLog(for: handle)
        let entries = log.orderedEntries.filter { $0.verb == .sensitivityGrantIssued }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.rowID == grantID)
        #expect(entry.fieldPath == "secret")
        guard case let .integer(storedExpiry) = entry.afterValue else {
            Issue.record("expected .integer afterValue carrying the expiry epoch-ms"); return
        }
        #expect(storedExpiry == Int64((expiresAt.timeIntervalSince1970 * 1000).rounded()),
                "the issued entry must carry its own expiry timestamp (out-of-band sensitivity grants: expiry is passive)")
    }

    @Test
    func recordSensitivityGrantDeniedEmitsExpectedEntry() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.recordSensitivityGrantDenied(handle, tier: .restricted, now: now)

        let log = try await kit.auditLog(for: handle)
        let entries = log.orderedEntries.filter { $0.verb == .sensitivityGrantDenied }
        #expect(entries.count == 1)
        #expect(entries.first?.fieldPath == "restricted")
    }

    @Test
    func recordSensitivityGrantRevokedCorrelatesWithIssuedByRowID() async throws {
        let (kit, handle) = try await openOneEstate()
        let grantID = UUID()
        try await kit.recordSensitivityGrantIssued(handle, tier: .restricted, grantID: grantID, expiresAt: now.addingTimeInterval(3600), now: now)
        try await kit.recordSensitivityGrantRevoked(handle, tier: .restricted, grantID: grantID, now: now.addingTimeInterval(60))

        let log = try await kit.auditLog(for: handle)
        let issued = log.orderedEntries.filter { $0.verb == .sensitivityGrantIssued }
        let revoked = log.orderedEntries.filter { $0.verb == .sensitivityGrantRevoked }
        #expect(issued.count == 1 && revoked.count == 1)
        #expect(issued.first?.rowID == revoked.first?.rowID,
                "the revoked entry must correlate with its issued entry by rowID (the shared grant id)")
    }

    @Test
    func recordSensitivityReadUnderGrantUsesDrawerIDAsRowID() async throws {
        let (kit, handle) = try await openOneEstate()
        let drawerID = UUID()
        try await kit.recordSensitivityReadUnderGrant(handle, tier: .secret, drawerID: drawerID.uuidString, now: now)

        let log = try await kit.auditLog(for: handle)
        let entries = log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }
        #expect(entries.count == 1)
        #expect(entries.first?.rowID == drawerID, "a read-under-grant entry's rowID is the DRAWER's own id, not a grant id")
        #expect(entries.first?.fieldPath == "secret")
    }

    @Test
    func recordSensitivityReadUnderGrantSilentlySkipsAMalformedDrawerID() async throws {
        let (kit, handle) = try await openOneEstate()
        // Must not throw — audit recording is best-effort observability,
        // never a gate on the read path.
        try await kit.recordSensitivityReadUnderGrant(handle, tier: .secret, drawerID: "not-a-uuid", now: now)
        let log = try await kit.auditLog(for: handle)
        #expect(log.orderedEntries.filter { $0.verb == .sensitivityReadUnderGrant }.isEmpty)
    }

    @Test
    func sensitivityGrantVerbsNeverReuseFederationReservedVerbs() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.recordSensitivityGrantIssued(handle, tier: .restricted, grantID: UUID(), expiresAt: now.addingTimeInterval(60), now: now)
        let log = try await kit.auditLog(for: handle)
        #expect(log.orderedEntries.filter { $0.verb == .grantIssued }.isEmpty,
                "sensitivity-unlock must never write the federation-reserved .grantIssued verb")
        #expect(log.orderedEntries.filter { $0.verb == .grantRevoked }.isEmpty)
    }
}
