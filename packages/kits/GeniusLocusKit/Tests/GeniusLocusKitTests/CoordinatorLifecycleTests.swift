import XCTest
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
final class CoordinatorLifecycleTests: XCTestCase {

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
    func testOpenThreeEstatesYieldsThreeHandles() async throws {
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
        XCTAssertEqual(count, 3)
        XCTAssertEqual(Set(handles), Set([h1, h2, h3]))
    }

    /// Closing one of three handles leaves two open and the closed
    /// handle stale.
    func testCloseLeavesRemainingHandlesLive() async throws {
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
        XCTAssertEqual(count, 2)
        XCTAssertEqual(live, Set([h1, h3]))

        // h2 is stale — lookup must raise estateNotOpen.
        await XCTAssertThrowsErrorAsync(try await kit.estate(for: h2)) { error in
            guard case GeniusLocusKitError.estateNotOpen(let uuid) = error else {
                return XCTFail("expected .estateNotOpen, got \(error)")
            }
            XCTAssertEqual(uuid, h2.estateUUID)
        }
    }

    /// Opening the same estate twice raises `duplicateEstate`.
    func testDuplicateOpenIsRejected() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-A")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let h1 = try await kit.open(storage: storage, owner: owner)
        await XCTAssertThrowsErrorAsync(try await kit.open(storage: storage, owner: owner)) { error in
            guard case GeniusLocusKitError.duplicateEstate(let uuid) = error else {
                return XCTFail("expected .duplicateEstate, got \(error)")
            }
            XCTAssertEqual(uuid, h1.estateUUID)
        }
    }

    /// Newly initialized kit holds no estates.
    func testKitInitializesWithEmptyRegistry() async throws {
        let kit = GeniusLocusKit()
        let count = await kit.openEstateCount
        XCTAssertEqual(count, 0)
    }
}

// MARK: - Async XCTest helper

/// XCTest does not ship an async `XCTAssertThrowsError` overload as of
/// Swift 6.0, so the suite defines its own. Captures the thrown error
/// and forwards it to the `errorHandler` for case-pattern matching.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw, none thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
