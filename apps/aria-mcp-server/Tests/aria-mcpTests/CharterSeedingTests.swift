import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit
@testable import aria_mcp

/// Charter-seeding tests: verify that `AriaMCPMain.seedChartersIfRegistered` seeds
/// exactly seven `AI_Charter_Hint`-room drawers when `registered` is true, and
/// produces zero drawers when `registered` is false.
///
/// Both tests call `AriaMCPMain.seedChartersIfRegistered` directly — the extracted
/// static helper — so a mutation that removes or inverts the `guard registered`
/// check inside the helper makes the appropriate test red.
///
/// Rust twin: `tests/estate_selection.rs` (`registered_opening_seeds_seven_charter_drawers`
/// and `transient_opening_seeds_no_charter_drawers`).
///
/// The suite is serialized because `EstateCatalog.configurationDirectoryOverride`
/// is process-global and shared with EstateSelectionTests.
@Suite("aria-mcp charter seeding", .serialized)
struct CharterSeedingTests {

    private static let testOwner = OwnerCredentials(ownerIdentifier: "charter-seeding-tests")
    private static let testNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// Open a fresh in-memory estate and return its kit and handle.
    private func freshEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        let handle = try await kit.open(
            storage: storage,
            owner: Self.testOwner
        )
        return (kit, handle)
    }

    /// Count drawers whose parent room is `AI_Charter_Hint`.
    private func charterDrawerCount(
        kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> Int {
        let all = try await kit.allDrawers(in: handle)
        let names = try await kit.resolveNodeNames(handle, parentNodeIds: all.map(\.parentNodeId))
        return all.filter { names[$0.parentNodeId]?.room == LocusKit.hintRoom }.count
    }

    /// A registered opening seeds exactly seven charter drawers, one per default wing.
    /// Calls `AriaMCPMain.seedChartersIfRegistered` with `registered: true`; disabling
    /// the seeding call inside that function makes this test red.
    @Test func registeredOpeningSeedsSevenCharterDrawers() async throws {
        let (kit, handle) = try await freshEstate()
        await AriaMCPMain.seedChartersIfRegistered(kit: kit, handle: handle, registered: true, now: Self.testNow)
        let count = try await charterDrawerCount(kit: kit, handle: handle)
        #expect(count == 7,
                "registered opening must seed exactly 7 charter drawers, got \(count)")
    }

    /// A transient opening produces zero charter drawers.
    /// Calls `AriaMCPMain.seedChartersIfRegistered` with `registered: false`; removing
    /// the `guard registered` check in that function makes this test red, because the
    /// guard is what keeps a transient opening clean.
    @Test func transientOpeningSeedsNoCharterDrawers() async throws {
        let (kit, handle) = try await freshEstate()
        await AriaMCPMain.seedChartersIfRegistered(kit: kit, handle: handle, registered: false, now: Self.testNow)
        let count = try await charterDrawerCount(kit: kit, handle: handle)
        #expect(count == 0,
                "transient opening must seed zero charter drawers, got \(count)")
    }
}
