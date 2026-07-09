import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Tests that `decodeHydration` in `ToolDispatcher` correctly rejects non-string
/// values for `hydrationLevel` with `invalidParams`.
///
/// `decodeHydration` is exercised only by `runFederatedSearch`, so all tests
/// use `moot_federated_search`. The dispatcher is built in single-estate mode;
/// the requesterEstateID is the handle's own UUID. With no other estate to search
/// the call reaches `decodeHydration` before any federation work takes place
/// (the requester resolution and hydration decode happen in that order).
///
/// ## What these tests prove
///
///   A. Number as hydrationLevel → invalidParams (the P2-26 bug fix target).
///      Before the fix, a non-nil non-string JSON value caused `value?.stringValue`
///      to return nil, and the guard fell through to `.structured` silently.
///
///   B. Valid string values unchanged — "structured", "full", "bitmapOnly" all
///      succeed (or return the no-grant isError:true), not invalidParams.
///
///   C. Unknown string value → invalidParams (existing behaviour, regression guard).
///
///   D. Absent hydrationLevel (key not present) → no invalidParams thrown (defaults
///      to .full inside runFederatedSearch, which is separate from the .structured
///      default of the bare decodeHydration utility).
@Suite("HydrationDecode dispatch", .serialized)
struct HydrationDecodeTests {

    // MARK: - Helpers

    /// Build a ToolDispatcher and return both it and the requester estate UUID
    /// (needed as the `requesterEstateID` argument to `moot_federated_search`).
    private func makeDispatcher() async throws -> (ToolDispatcher, UUID) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "hydration-decode-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        return (dispatcher, handle.estateUUID)
    }

    // MARK: - A. Non-string number → invalidParams

    /// A JSON integer sent as hydrationLevel must throw invalidParams.
    /// Before the fix this silently returned .structured (the default), accepting
    /// semantically invalid input without error.
    @Test func numberHydrationLevelThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_federated_search",
                arguments: .object([
                    "requesterEstateID": .string(requesterID.uuidString),
                    "hydrationLevel": .integer(1),
                ])
            )
            Issue.record("Integer hydrationLevel must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Integer hydrationLevel must throw invalidParams; got code \(error.code)"
            )
        }
    }

    // MARK: - B. Valid string values do not throw invalidParams

    /// "structured" must not throw invalidParams (call may return isError:true due
    /// to no-grant refusal, but must not throw an out-of-band invalidParams error).
    @Test func structuredHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        // No throw expected — if no-grant refusal happens that is a tool-level
        // isError:true result, not a JSONRPCError.
        _ = try await dispatcher.dispatch(
            name: "moot_federated_search",
            arguments: .object([
                "requesterEstateID": .string(requesterID.uuidString),
                "hydrationLevel": .string("structured"),
            ])
        )
    }

    /// "full" must not throw invalidParams.
    @Test func fullHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_search",
            arguments: .object([
                "requesterEstateID": .string(requesterID.uuidString),
                "hydrationLevel": .string("full"),
            ])
        )
    }

    /// "bitmapOnly" must not throw invalidParams.
    @Test func bitmapOnlyHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_search",
            arguments: .object([
                "requesterEstateID": .string(requesterID.uuidString),
                "hydrationLevel": .string("bitmapOnly"),
            ])
        )
    }

    // MARK: - C. Unknown string value → invalidParams (regression guard)

    /// An unknown string must throw invalidParams. This was correct before the fix
    /// and must remain correct after.
    @Test func unknownHydrationLevelStringThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_federated_search",
                arguments: .object([
                    "requesterEstateID": .string(requesterID.uuidString),
                    "hydrationLevel": .string("ultraHydrated"),
                ])
            )
            Issue.record("Unknown hydrationLevel string must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Unknown hydrationLevel string must throw invalidParams; got code \(error.code)"
            )
        }
    }

    // MARK: - D. Absent hydrationLevel does not throw

    /// Omitting hydrationLevel entirely must not throw. runFederatedSearch defaults
    /// to .full (not .structured) when the key is absent; no decodeHydration call
    /// is made at all. Regression guard: callers that never supply the field must
    /// be unaffected by the fix.
    @Test func absentHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_search",
            arguments: .object([
                "requesterEstateID": .string(requesterID.uuidString),
            ])
        )
    }

    // MARK: - E. clampLimit guards on moot_federated_search (Finding 3)

    /// A negative `limit` on `moot_federated_search` must throw `invalidParams`.
    /// Before the fix, the limit bypassed clampLimit and reached the substrate raw.
    @Test func federatedSearchNegativeLimitThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_federated_search",
                arguments: .object([
                    "requesterEstateID": .string(requesterID.uuidString),
                    "limit": .integer(-1),
                ])
            )
            Issue.record("Negative limit must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Negative limit must throw invalidParams; got code \(error.code)"
            )
        }
    }

    /// An over-ceiling `limit` on `moot_federated_search` must be silently clamped.
    @Test func federatedSearchOverCeilingLimitDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        // Should not throw — clamped to 500 before reaching the substrate.
        _ = try await dispatcher.dispatch(
            name: "moot_federated_search",
            arguments: .object([
                "requesterEstateID": .string(requesterID.uuidString),
                "limit": .integer(1_000_000),
            ])
        )
    }
}
