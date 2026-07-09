import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// MCP-MULTI-01 — multi-estate routing at the ARIA_MCP surface (secfix/batch2-aria).
///
/// Three security behaviors are under test:
///
/// 1. **Direct-routing restriction (Item 3):** `estateID` in direct MCP tools is
///    restricted to the default estate. Non-default estate IDs are refused with
///    `invalidParams`; the default UUID is accepted; omitted uses the default.
///
/// 2. **Requester anti-spoof (Item 2):** `requesterEstateID` in `moot_federated_search`
///    is optional. Omitted → default estate. Supplied and matching → accepted.
///    Supplied and different → refused (anti-spoof gate).
///
/// 3. **Federation fan-out and scope narrowing:** grant-authorized federated reads
///    fan across locally-open estates the requester is entitled to read, narrowed
///    to each grant's scope.
///
/// All estates are registry entries in one kit instance — locally mediated
/// federation, never a device-boundary crossing (I-13).
///
/// `.serialized`: every case opens multiple live in-memory estates and runs
/// multi-step capture/search sequences.
@Suite("Multi-estate routing", .serialized)
struct MultiEstateRoutingTests {

    // MARK: - Harness

    /// Open one fresh in-memory estate through `GeniusLocusKit`. Each call
    /// uses isolated storage, so estates have distinct UUIDs and mutually
    /// isolated content.
    private func openEstate(
        in kit: GeniusLocusKit,
        owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Seed content directly into any estate by calling `kit.capture`, bypassing
    /// the MCP direct-routing gate. Required for non-default estate seeding after
    /// Item 3 restricts `moot_file_memory` to the default estate.
    private func seedMemory(
        _ content: String,
        location: String = "mm-tests",
        in handle: EstateHandle,
        kit: GeniusLocusKit
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: location,
            latticeAnchor: .udc("004"),
            addedBy: "aria-mcp-tests",
            embeddingModelID: "test-model-v1")
        _ = try await kit.capture(handle, frame)
    }

    /// Build the `arguments` object for a `moot_file_memory` call, with an
    /// optional `estateID`.
    private func fileArgs(
        content: String,
        location: String = "mm-tests",
        estateID: UUID? = nil
    ) -> JSONValue {
        var args: [String: JSONValue] = [
            "content": .string(content),
            "location": .string(location),
        ]
        if let estateID { args["estateID"] = .string(estateID.uuidString) }
        return .object(args)
    }

    /// Build the `arguments` object for a `moot_memory_search` call.
    private func searchArgs(query: String, estateID: UUID? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["query": .string(query)]
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

    // MARK: - 1. Direct routing to non-default estate is refused (Item 3)

    @Test func testNonDefaultEstateIDIsRefused() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-routing")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // Filing to non-default estate B by direct estateID must be refused
        // with invalidParams (security gate, Item 3 hardening).
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: fileArgs(content: "row-in-B", estateID: hB.estateUUID)
            )
            Issue.record("routing to non-default estate must throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                "non-default estate routing must throw invalidParams")
        }

        // Routing to the default estate by explicit UUID is accepted.
        let filedToDefault = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "row-in-A", estateID: hA.estateUUID)
        )
        #expect(!isError(filedToDefault), "default estate routing by explicit UUID must succeed")

        // Seed B's content directly (bypassing the gate, as intended for cross-estate
        // seeding) and verify the default estate doesn't see it.
        try await seedMemory("row-seeded-in-B", in: hB, kit: kit)
        let fromDefault = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: searchArgs(query: "row-seeded-in-B")
        )
        #expect(!(text(of: fromDefault)?.contains("row-seeded-in-B") ?? false),
            "the default estate must not see a row seeded directly into estate B")
    }

    // MARK: - 2. Omitted estateID hits the default estate (v1.0 regression)

    @Test func testOmittedEstateIDHitsDefaultEstate() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-default")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // File with no estateID — the v1.0 path — targets the default.
        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "row-in-default")
        )
        #expect(!isError(filed))

        // Search in the default estate must find the row.
        let fromDefault = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: searchArgs(query: "row-in-default")
        )
        #expect(text(of: fromDefault)?.contains("row-in-default") ?? false,
            "default estate must contain the filed row")

        // Direct routing to non-default estate B must throw (Item 3 gate).
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: searchArgs(query: "row-in-default", estateID: hB.estateUUID)
            )
            Issue.record("non-default estateID must throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }
    }

    // MARK: - 3. Unknown / malformed estateID is an out-of-band invalidParams

    @Test func testUnknownEstateIDReturnsInvalidParams() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-unknown")
        let hA = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA)

        // A well-formed UUID that names no registered estate.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: searchArgs(query: "anything", estateID: UUID())
            )
            Issue.record("unknown estateID should throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
        }

        // A malformed (non-UUID) estateID is the same out-of-band error.
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_memory_search",
                arguments: .object(["query": .string("anything"),
                                    "estateID": .string("not-a-uuid")])
            )
            Issue.record("malformed estateID should throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams)
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

    /// Arguments for a `moot_federated_search` call.
    /// `requesterEstateID` is omitted — the default (authenticated caller) estate
    /// is bound automatically (Item 2 hardening).
    private func federatedArgs() -> JSONValue {
        .object([
            "filter": .string("unconfirmed"),
        ])
    }

    /// Arguments for a `moot_federated_search` call with an explicit requesterEstateID.
    /// Used to test both the "matching default" acceptance and the anti-spoof rejection.
    private func federatedArgsWithRequester(_ requesterID: UUID) -> JSONValue {
        .object([
            "requesterEstateID": .string(requesterID.uuidString),
            "filter": .string("unconfirmed"),
        ])
    }

    // MARK: - 3b. requesterEstateID anti-spoof gate (Item 2)

    @Test func testSpoofedRequesterEstateIDIsRefused() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-antispoof")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        _ = try await kit.issueGrant(hB, grantOptions(to: hA))

        // Supplying B's UUID as requesterEstateID spoofs a different estate identity.
        // The gate refuses it with invalidParams.
        do {
            _ = try await dispatcher.dispatch(
                name: ToolDispatcher.federatedSearchToolName,
                arguments: federatedArgsWithRequester(hB.estateUUID)
            )
            Issue.record("spoofed requesterEstateID must throw invalidParams")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                "requesterEstateID mismatch must throw invalidParams")
        }

        // Supplying the default estate's own UUID is accepted (redundant but valid).
        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgsWithRequester(hA.estateUUID)
        )
        #expect(!isError(result),
            "requesterEstateID matching the default estate must be accepted")
    }

    // MARK: - 4. moot_federated_search fans across authorized estates

    @Test func testFederatedSearchFansAcrossAuthorizedEstates() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-fan")
        let hA = try await openEstate(in: kit, owner: owner)   // requester (default)
        let hB = try await openEstate(in: kit, owner: owner)
        let hC = try await openEstate(in: kit, owner: owner)
        let hD = try await openEstate(in: kit, owner: owner)   // ungranted
        let dispatcher = ToolDispatcher(kit: kit, handle: hA)
            .registering(hB).registering(hC).registering(hD)

        // B and C grant whole-estate read to A; D grants nothing.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA))
        _ = try await kit.issueGrant(hC, grantOptions(to: hA))

        // Seed content directly into non-default estates (Item 3: moot_file_memory
        // is restricted to the default estate; seedMemory calls kit.capture directly).
        try await seedMemory("row-from-B", in: hB, kit: kit)
        try await seedMemory("row-from-C", in: hC, kit: kit)
        try await seedMemory("row-from-D", in: hD, kit: kit)

        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs()
        )
        #expect(!isError(result), "an authorized federation fan must succeed")
        let body = try #require(text(of: result))
        #expect(body.contains("row-from-B"), "B's grant admits A — B contributes")
        #expect(body.contains("row-from-C"), "C's grant admits A — C contributes")
        #expect(!body.contains("row-from-D"),
            "D granted nothing — its rows must not appear")
    }

    // MARK: - 5. No-grant federated search is refused cleanly

    @Test func testNoGrantFederatedSearchRefusedAsErrorResult() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-nogrant")
        let hA = try await openEstate(in: kit, owner: owner)   // requester (default)
        let hB = try await openEstate(in: kit, owner: owner)   // grants nothing
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // Seed content directly into B (bypassing the direct-routing gate).
        try await seedMemory("secret-B", in: hB, kit: kit)

        // The call must come back as an error RESULT (isError == true),
        // not a thrown JSON-RPC error: the read reached the
        // substrate-mediated surface and was refused (A-versus-C, §13).
        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs()
        )
        #expect(isError(result),
            "a no-grant federated search must be refused with isError == true")
        #expect(!(text(of: result)?.contains("secret-B") ?? false),
            "refused call must not leak the ungranted estate's content")
    }

    // MARK: - 6. Scope narrowing — a room grant discloses only that location

    @Test func testLocationScopedGrantNarrowsToThatRoom() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-scope")
        let hA = try await openEstate(in: kit, owner: owner)   // requester (default)
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // B grants A only the "kitchen" room, then files into two locations.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, scope: .room("kitchen")))

        // Seed directly into non-default estate B (Item 3 gate bypassed by design).
        try await seedMemory("kitchen-row", location: "kitchen", in: hB, kit: kit)
        try await seedMemory("garage-row", location: "garage", in: hB, kit: kit)

        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs()
        )
        #expect(!isError(result))
        let body = try #require(text(of: result))
        #expect(body.contains("kitchen-row"),
            "the room-scoped grant admits the kitchen row")
        #expect(!body.contains("garage-row"),
            "§10 answer-assembly narrowing must exclude rows outside the granted room")
    }
}
