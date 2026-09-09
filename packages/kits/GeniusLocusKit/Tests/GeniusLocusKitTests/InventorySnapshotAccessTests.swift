import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import GeniusLocusKit

@Suite("GeniusLocusKit inventory snapshot access")
struct InventorySnapshotAccessTests {
    @Test("captures production-bounded inventory only for a registered handle")
    func registeredHandleOnly() async throws {
        let storage = InMemoryStorage(configuration: .init(estateID: UUID(), backend: .inMemory))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: .init(ownerIdentifier: "snapshot-test"))

        let snapshot = try await kit.captureInventorySnapshot(for: handle)
        #expect(!snapshot.nodes.isEmpty)

        try await kit.close(handle)
        do {
            _ = try await kit.captureInventorySnapshot(for: handle)
            Issue.record("closed handle unexpectedly retained snapshot access")
        } catch let error as GeniusLocusKitError {
            guard case .estateNotOpen(let estateID) = error else {
                Issue.record("closed handle returned unexpected error \(error)")
                return
            }
            #expect(estateID == handle.estateUUID)
        }
    }
}
