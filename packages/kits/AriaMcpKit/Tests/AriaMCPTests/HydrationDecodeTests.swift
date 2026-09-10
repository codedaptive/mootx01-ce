import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Tests that `moot_federated_recall` correctly rejects non-string values for
/// `hydration_level` with `invalidParams`, and validates the `limit` clamp guard.
///
/// The dispatcher is built in single-estate mode; `requester_estate_id` is the
/// handle's own UUID. With no other estate to search the call reaches
/// `decodeHydration` before any federation work takes place (the requester
/// resolution and hydration decode happen in that order).
///
/// ## What these tests prove
///
///   A. Number as hydration_level → invalidParams (the P2-26 bug fix target).
///      Before the fix, a non-nil non-string JSON value caused `value?.stringValue`
///      to return nil, and the guard fell through to `.structured` silently.
///
///   B. Valid string values unchanged — "structured", "full", "bitmapOnly" all
///      succeed (or return the no-grant isError:true), not invalidParams.
///
///   C. Unknown string value → invalidParams (existing behaviour, regression guard).
///
///   D. Absent hydration_level (key not present) → no invalidParams thrown (defaults
///      to .full inside runFederatedSearch, which is separate from the .structured
///      default of the bare decodeHydration utility).
@Suite("HydrationDecode dispatch", .serialized)
struct HydrationDecodeTests {

    // MARK: - Helpers

    /// Build a ToolDispatcher and return both it and the requester estate UUID
    /// (needed as the `requester_estate_id` argument to `moot_federated_recall`).
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

    /// A JSON integer sent as hydration_level must throw invalidParams.
    /// Before the fix this silently returned .structured (the default), accepting
    /// semantically invalid input without error. P2-26 regression guard.
    @Test func numberHydrationLevelThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_federated_recall",
                arguments: .object([
                    "requester_estate_id": .string(requesterID.uuidString),
                    "hydration_level": .integer(1),
                ])
            )
            Issue.record("Integer hydration_level must throw invalidParams, but did not throw")
        } catch let error as JSONRPCError {
            #expect(
                error.code == JSONRPCErrorCode.invalidParams,
                "Integer hydration_level must throw invalidParams; got code \(error.code)"
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
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
                "hydration_level": .string("structured"),
            ])
        )
    }

    /// "full" must not throw invalidParams.
    @Test func fullHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
                "hydration_level": .string("full"),
            ])
        )
    }

    /// "bitmapOnly" must not throw invalidParams.
    @Test func bitmapOnlyHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
                "hydration_level": .string("bitmapOnly"),
            ])
        )
    }

    // MARK: - C. Unknown string value → error response (regression guard)

    /// An unknown hydration_level string must produce an error response.
    ///
    /// In v2 the dispatch path is non-throwing — `dispatchV2` is `async -> JSONValue`,
    /// not `async throws`. Operational errors (including unsupported hydration values)
    /// are caught inside `executeV2Core` and returned as `isError: true` responses.
    /// The pinned assertion is preserved: an unknown hydration level must never
    /// silently succeed with a default.
    @Test func unknownHydrationLevelStringThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
                "hydration_level": .string("ultraHydrated"),
            ])
        )
        // v2 wraps operational errors (AriaV2OrchestrationLowerError.unsupportedHydration)
        // as isError:true responses rather than throwing JSONRPCError. An unrecognised
        // hydration_level string must produce an error result — not silent success.
        guard case let .object(obj) = result else {
            Issue.record("Expected object result; got: \(result)")
            return
        }
        #expect(
            obj["isError"] == .bool(true),
            "Unknown hydration_level string must produce an error response (isError:true); got: \(result)"
        )
    }

    // MARK: - D. Absent hydration_level does not throw

    /// Omitting hydration_level entirely must not throw. runFederatedSearch defaults
    /// to .full (not .structured) when the key is absent; no decodeHydration call
    /// is made at all. Regression guard: callers that never supply the field must
    /// be unaffected by the fix.
    @Test func absentHydrationLevelDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        _ = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
            ])
        )
    }

    // MARK: - E. clampLimit guards on moot_federated_recall (Finding 3)

    /// A negative `limit` on `moot_federated_recall` must throw `invalidParams`.
    /// Before the fix, the limit bypassed clampLimit and reached the substrate raw.
    @Test func federatedSearchNegativeLimitThrowsInvalidParams() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_federated_recall",
                arguments: .object([
                    "requester_estate_id": .string(requesterID.uuidString),
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

    /// An over-ceiling `limit` on `moot_federated_recall` must be silently clamped.
    @Test func federatedSearchOverCeilingLimitDoesNotThrow() async throws {
        let (dispatcher, requesterID) = try await makeDispatcher()
        // Should not throw — clamped to 500 before reaching the substrate.
        _ = try await dispatcher.dispatch(
            name: "moot_federated_recall",
            arguments: .object([
                "requester_estate_id": .string(requesterID.uuidString),
                "limit": .integer(1_000_000),
            ])
        )
    }
}
