import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@_spi(EstateMaintenance) @testable import GeniusLocusKit

@Suite("Estate maintenance SPI")
struct EstateMaintenanceTests {

    /// Verifies deduplication and idempotency of `recordPhysicalRemovalEvents`.
    ///
    /// First call: two IDs but the same drawer twice → deduplicated to one unique
    /// drawer → one expunge event appended, zero already-non-live, zero missing.
    /// Second call with the same drawer: the drawer already has a live Matrix row
    /// count of zero (the first expunge zeroed it) → zero appended, one
    /// already-non-live.
    @Test
    func physicalRemovalAuditIsBalancedOnce() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "estate-maintenance-tests")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: owner)
        defer { Task { try? await kit.close(handle) } }

        let estate = try await kit.estate(for: handle)
        let drawer = try await estate.capture(CaptureFrame(
            content: "physical removal audit target",
            channel: .typed,
            room: "maintenance-room",
            latticeAnchor: .udc("004"),
            addedBy: "estate-maintenance-tests",
            embeddingModelID: "test-model-v1"))

        // Two IDs but the same drawer → deduplicated to one unique → one event.
        let first = try await kit.recordPhysicalRemovalEvents(
            for: handle,
            drawerIDs: [drawer.id, drawer.id],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first.requested == 1)
        #expect(first.appended == 1)
        #expect(first.alreadyNonLive == 0)
        #expect(first.missing == 0)

        // Second call: the drawer's live Matrix row count is now zero → non-live.
        let second = try await kit.recordPhysicalRemovalEvents(
            for: handle,
            drawerIDs: [drawer.id],
            now: Date(timeIntervalSince1970: 1_800_000_001))
        #expect(second.appended == 0)
        #expect(second.alreadyNonLive == 1)

        // Exactly one expunge event in the audit trail.
        let trail = try await estate.auditTrail(rowID: drawer.id)
        #expect(trail.filter { $0.verb == "expunge" }.count == 1)
    }
}
