import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Lifecycle tests for `GeniusLocusKit`'s coordinator surface.
///
/// Three estates, three handles, close one, two remain. Confirms the
/// registry semantics that downstream sub-missions build on: handles
/// are unique per estate UUID, `handles` reports the live set, and
/// `close` is observable through subsequent lookups.
@Suite("Coordinator lifecycle")
struct CoordinatorLifecycleTests {

    /// Build an in-memory `Storage` open for one estate. Each call
    /// produces an isolated storage instance because every
    /// `InMemoryStorage` carries its own state actor; estates built on
    /// distinct storages cannot see one another's data.
    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
        return InMemoryStorage(configuration: config)
    }

    /// Opening three estates yields three distinct live handles.
    @Test
    func openThreeEstatesYieldsThreeHandles() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-A")

        let s1 = makeStorage(); let s2 = makeStorage(); let s3 = makeStorage()
        _ = try await LocusKit.Estate.create(storage: s1, owner: owner)
        _ = try await LocusKit.Estate.create(storage: s2, owner: owner)
        _ = try await LocusKit.Estate.create(storage: s3, owner: owner)

        let h1 = try await kit.open(storage: s1, owner: owner)
        let h2 = try await kit.open(storage: s2, owner: owner)
        let h3 = try await kit.open(storage: s3, owner: owner)

        let count = await kit.openEstateCount
        let handles = await kit.handles
        #expect(count == 3)
        #expect(Set(handles) == Set([h1, h2, h3]))
    }

    /// Closing one of three handles leaves two open and the closed
    /// handle stale.
    @Test
    func closeLeavesRemainingHandlesLive() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-A")

        let s1 = makeStorage(); let s2 = makeStorage(); let s3 = makeStorage()
        _ = try await LocusKit.Estate.create(storage: s1, owner: owner)
        _ = try await LocusKit.Estate.create(storage: s2, owner: owner)
        _ = try await LocusKit.Estate.create(storage: s3, owner: owner)

        let h1 = try await kit.open(storage: s1, owner: owner)
        let h2 = try await kit.open(storage: s2, owner: owner)
        let h3 = try await kit.open(storage: s3, owner: owner)

        try await kit.close(h2)

        let count = await kit.openEstateCount
        let live = Set(await kit.handles)
        #expect(count == 2)
        #expect(live == Set([h1, h3]))

        // h2 is stale — lookup must raise estateNotOpen.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.estate(for: h2)
        }
        if case .estateNotOpen(let uuid)? = thrown {
            #expect(uuid == h2.estateUUID)
        } else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }

    /// Opening the same estate twice raises `duplicateEstate`.
    @Test
    func duplicateOpenIsRejected() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-A")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let h1 = try await kit.open(storage: storage, owner: owner)
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.open(storage: storage, owner: owner)
        }
        if case .duplicateEstate(let uuid)? = thrown {
            #expect(uuid == h1.estateUUID)
        } else {
            Issue.record("expected .duplicateEstate, got \(String(describing: thrown))")
        }
    }

    /// Newly initialized kit holds no estates.
    @Test
    func kitInitializesWithEmptyRegistry() async throws {
        let kit = GeniusLocusKit()
        let count = await kit.openEstateCount
        #expect(count == 0)
    }
}
