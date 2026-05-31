import XCTest
import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// MCP-MULTI-01 — multi-estate routing at the ARIA_MCP surface.
///
/// Two behaviors are under test. First, `estateID` routing: a tool call
/// that carries an `estateID` targets that registered estate, and a call
/// that omits it targets the default estate exactly as the v1.0
/// single-estate path does (the regression guard). Second,
/// `cross_estate_recall`: a grant-authorized federated read that fans
/// across the locally-open estates the caller is entitled to read,
/// narrows each contribution to its grant's scope, and refuses cleanly
/// (a result with `isError == true`, not a JSON-RPC error) when no
/// authorizing grant is present.
///
/// All estates are registry entries in one kit instance — the locally
/// mediated federation surface, never a device-boundary crossing (I-13).
/// Recalls use `.unconfirmed` so the default `.userConfirmed` prepend
/// does not prune freshly-captured rows (provenance == 0), matching the
/// GLK federation tests.
final class MultiEstateRoutingTests: XCTestCase {

    // MARK: - Harness

    /// Open one fresh in-memory estate through `GeniusLocusKit`. Each
    /// call uses isolated storage, so estates have distinct UUIDs and
    /// mutually isolated content.
    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner)
    }

    /// Build the `arguments` object for a `capture_drawer` call, with an
    /// optional `estateID`. Room is tagged so a scope-narrowing test can
    /// address it.
    private func captureArgs(
        content: String,
        room: String = "mm-tests",
        estateID: UUID? = nil
    ) -> JSONValue {
        var args: [String: JSONValue] = [
            "content": .string(content),
            "room": .string(room),
            "udcCode": .string("004"),
            "addedBy": .string("mm-tests"),
            "embeddingModelID": .string("test-model-v1"),
        ]
        if let estateID { args["estateID"] = .string(estateID.uuidString) }
        return .object(args)
    }

    /// Build the `arguments` object for a `drawer_recall` call. Uses the
    /// `unconfirmed` filter so freshly-captured rows are visible.
    private func recallArgs(estateID: UUID? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["filter": .string("unconfirmed")]
        if let estateID { args["estateID"] = .string(estateID.uuidString) }
        return .object(args)
    }

    /// Pull the single text content block out of a `tools/call` result.
    private func text(of result: JSONValue) -> String? {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue
    }

    /// Whether a `tools/call` result is an error result (`isError`).
    private func isError(_ result: JSONValue) -> Bool {
        result.objectValue?["isError"]?.boolValue ?? false
    }

    // MARK: - 1. estateID routes to the named estate; default is isolated

    func testEstateIDRoutesToNamedEstateAndLeavesDefaultUntouched() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-routing")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // Capture into B explicitly by estateID.
        let captured = try await dispatcher.dispatch(
            name: "moot_capture_drawer",
            arguments: captureArgs(content: "row-in-B", estateID: hB.estateUUID)
        )
        XCTAssertFalse(isError(captured))

        // Recall from B by estateID sees the row.
        let fromB = try await dispatcher.dispatch(
            name: "moot_drawer_recall", arguments: recallArgs(estateID: hB.estateUUID)
        )
        XCTAssertTrue(text(of: fromB)?.contains("row-in-B") ?? false,
            "estateID-targeted recall must see the row captured into that estate")

        // Recall from the default estate (A) must NOT see B's row.
        let fromDefault = try await dispatcher.dispatch(
            name: "moot_drawer_recall", arguments: recallArgs()
        )
        XCTAssertFalse(text(of: fromDefault)?.contains("row-in-B") ?? false,
            "the default estate must not see a row captured into estate B")
    }

    // MARK: - 2. Omitted estateID hits the default estate (v1.0 regression)

    func testOmittedEstateIDHitsDefaultEstate() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-default")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // Capture with no estateID — the v1.0 path — targets the default.
        let captured = try await dispatcher.dispatch(
            name: "moot_capture_drawer", arguments: captureArgs(content: "row-in-default")
        )
        XCTAssertFalse(isError(captured))

        // Recall with no estateID sees it; recall from B does not.
        let fromDefault = try await dispatcher.dispatch(
            name: "moot_drawer_recall", arguments: recallArgs()
        )
        XCTAssertTrue(text(of: fromDefault)?.contains("row-in-default") ?? false,
            "omitted estateID must behave exactly as the single-estate v1.0 path")

        let fromB = try await dispatcher.dispatch(
            name: "moot_drawer_recall", arguments: recallArgs(estateID: hB.estateUUID)
        )
        XCTAssertFalse(text(of: fromB)?.contains("row-in-default") ?? false,
            "the default row must not leak into estate B")
    }

    // MARK: - 3. Unknown / malformed estateID is an out-of-band invalidParams

    func testUnknownEstateIDReturnsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-unknown")
        let hA = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA)

        // A well-formed UUID that names no registered estate.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_drawer_recall", arguments: recallArgs(estateID: UUID())
            )
            XCTFail("unknown estateID should throw invalidParams")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams)
        }

        // A malformed (non-UUID) estateID is the same out-of-band error.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_drawer_recall",
                arguments: .object(["filter": .string("unconfirmed"),
                                    "estateID": .string("not-a-uuid")])
            )
            XCTFail("malformed estateID should throw invalidParams")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCErrorCode.invalidParams)
        }
    }

    // MARK: - Federation harness

    /// A grant naming `grantee` as grantee, default whole-estate.
    private func grantOptions(
        to grantee: EstateHandle, scope: GrantScope = .wholeEstate
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee.estateUUID,
            scope: scope,
            custodyMode: .mediated,
            lifetime: .permanent
        )
    }

    /// Arguments for a `cross_estate_recall` call by `requester`.
    private func crossArgs(requester: EstateHandle) -> JSONValue {
        .object([
            "requesterEstateID": .string(requester.estateUUID.uuidString),
            "filter": .string("unconfirmed"),
        ])
    }

    // MARK: - 4. cross_estate_recall fans across authorized estates

    func testCrossEstateRecallFansAcrossAuthorizedEstates() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-fan")
        let hA = try await openEstate(in: kit, owner: owner)   // requester
        let hB = try await openEstate(in: kit, owner: owner)
        let hC = try await openEstate(in: kit, owner: owner)
        let hD = try await openEstate(in: kit, owner: owner)   // ungranted
        let dispatcher = ToolDispatcher(kit: kit, handle: hA)
            .registering(hB).registering(hC).registering(hD)

        // B and C grant whole-estate read to A; D grants nothing.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await kit.issueGrant(hC, grantOptions(to: hA))

        // Each estate captures a uniquely-tagged row.
        for (handle, tag) in [(hB, "row-from-B"), (hC, "row-from-C"), (hD, "row-from-D")] {
            _ = try await dispatcher.dispatch(
                name: "moot_capture_drawer",
                arguments: captureArgs(content: tag, estateID: handle.estateUUID)
            )
        }

        let result = try await dispatcher.dispatch(
            name: "moot_cross_estate_recall", arguments: crossArgs(requester: hA)
        )
        XCTAssertFalse(isError(result), "an authorized fan must succeed")
        let body = try XCTUnwrap(text(of: result))
        XCTAssertTrue(body.contains("row-from-B"), "B's grant admits A — B contributes")
        XCTAssertTrue(body.contains("row-from-C"), "C's grant admits A — C contributes")
        XCTAssertFalse(body.contains("row-from-D"),
            "D granted nothing — its rows must not appear")
    }

    // MARK: - 5. No-grant cross_estate_recall is refused cleanly

    func testNoGrantCrossEstateRecallRefusedAsErrorResult() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-nogrant")
        let hA = try await openEstate(in: kit, owner: owner)   // requester
        let hB = try await openEstate(in: kit, owner: owner)   // grants nothing
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // B captures content but issues no grant to A.
        _ = try await dispatcher.dispatch(
            name: "moot_capture_drawer",
            arguments: captureArgs(content: "secret-B", estateID: hB.estateUUID)
        )

        // The call must come back as an error RESULT (isError == true),
        // not a thrown JSON-RPC error: the read reached the
        // substrate-mediated surface and was refused (A-versus-C, §13).
        let result = try await dispatcher.dispatch(
            name: "moot_cross_estate_recall", arguments: crossArgs(requester: hA)
        )
        XCTAssertTrue(isError(result),
            "a no-grant cross-estate call must be refused with isError == true")
        XCTAssertFalse(text(of: result)?.contains("secret-B") ?? false,
            "refused call must not leak the ungranted estate's content")
    }

    // MARK: - 6. Scope narrowing — a room grant discloses only that room

    func testRoomScopedGrantNarrowsToThatRoom() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-scope")
        let hA = try await openEstate(in: kit, owner: owner)   // requester
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // B grants A only the "kitchen" room, then captures into two rooms.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, scope: .room("kitchen")))
        _ = try await dispatcher.dispatch(
            name: "moot_capture_drawer",
            arguments: captureArgs(content: "kitchen-row", room: "kitchen", estateID: hB.estateUUID)
        )
        _ = try await dispatcher.dispatch(
            name: "moot_capture_drawer",
            arguments: captureArgs(content: "garage-row", room: "garage", estateID: hB.estateUUID)
        )

        let result = try await dispatcher.dispatch(
            name: "moot_cross_estate_recall", arguments: crossArgs(requester: hA)
        )
        XCTAssertFalse(isError(result))
        let body = try XCTUnwrap(text(of: result))
        XCTAssertTrue(body.contains("kitchen-row"),
            "the room-scoped grant admits the kitchen row")
        XCTAssertFalse(body.contains("garage-row"),
            "§10 answer-assembly narrowing must exclude rows outside the granted room")
    }
}
