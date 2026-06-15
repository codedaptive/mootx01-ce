import Testing
import Foundation
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
/// `moot_federated_search`: a grant-authorized federated read that fans
/// across the locally-open estates the caller is entitled to read,
/// narrows each contribution to its grant's scope, and refuses cleanly
/// (a result with `isError == true`, not a JSON-RPC error) when no
/// authorizing grant is present.
///
/// All estates are registry entries in one kit instance — the locally
/// mediated federation surface, never a device-boundary crossing (I-13).
///
/// `.serialized`: every case opens multiple live in-memory estates,
/// issues grants, and runs multi-step capture/search sequences; preserve
/// the one-at-a-time execution the suite ran under XCTest.
@Suite("Multi-estate routing", .serialized)
struct MultiEstateRoutingTests {

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

    /// Build the `arguments` object for a `moot_file_memory` call, with an
    /// optional `estateID`. Location is tagged so a scope-narrowing test
    /// can address it.
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

    // MARK: - 1. estateID routes to the named estate; default is isolated

    @Test func testEstateIDRoutesToNamedEstateAndLeavesDefaultUntouched() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mm-routing")
        let hA = try await openEstate(in: kit, owner: owner)   // default
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // File into B explicitly by estateID.
        let filed = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "row-in-B", estateID: hB.estateUUID)
        )
        #expect(!isError(filed))

        // Search in B by estateID — must find the row.
        let fromB = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: searchArgs(query: "row-in-B", estateID: hB.estateUUID)
        )
        #expect(!isError(fromB),
            "estateID-targeted search must succeed in estate B")

        // Search in the default estate (A) — must NOT find B's row.
        let fromDefault = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: searchArgs(query: "row-in-B")
        )
        #expect(!(text(of: fromDefault)?.contains("row-in-B") ?? false),
            "the default estate must not see a row filed into estate B")
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

        // Search in B — must NOT find the default row.
        let fromB = try await dispatcher.dispatch(
            name: "moot_memory_search",
            arguments: searchArgs(query: "row-in-default", estateID: hB.estateUUID)
        )
        #expect(!(text(of: fromB)?.contains("row-in-default") ?? false),
            "the default row must not leak into estate B")
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

    /// Arguments for a `moot_federated_search` call by `requester`.
    private func federatedArgs(requester: EstateHandle) -> JSONValue {
        .object([
            "requesterEstateID": .string(requester.estateUUID.uuidString),
            "filter": .string("userConfirmed"),
        ])
    }

    // MARK: - 4. moot_federated_search fans across authorized estates

    @Test func testFederatedSearchFansAcrossAuthorizedEstates() async throws {
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

        // Each estate files a uniquely-tagged memory.
        for (handle, tag) in [(hB, "row-from-B"), (hC, "row-from-C"), (hD, "row-from-D")] {
            _ = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: fileArgs(content: tag, estateID: handle.estateUUID)
            )
        }

        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs(requester: hA)
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
        let hA = try await openEstate(in: kit, owner: owner)   // requester
        let hB = try await openEstate(in: kit, owner: owner)   // grants nothing
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // B files content but issues no grant to A.
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "secret-B", estateID: hB.estateUUID)
        )

        // The call must come back as an error RESULT (isError == true),
        // not a thrown JSON-RPC error: the read reached the
        // substrate-mediated surface and was refused (A-versus-C, §13).
        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs(requester: hA)
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
        let hA = try await openEstate(in: kit, owner: owner)   // requester
        let hB = try await openEstate(in: kit, owner: owner)
        let dispatcher = ToolDispatcher(kit: kit, handle: hA).registering(hB)

        // B grants A only the "kitchen" room, then files into two locations.
        _ = try await kit.issueGrant(hB, grantOptions(to: hA, scope: .room("kitchen")))
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "kitchen-row", location: "kitchen", estateID: hB.estateUUID)
        )
        _ = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: fileArgs(content: "garage-row", location: "garage", estateID: hB.estateUUID)
        )

        let result = try await dispatcher.dispatch(
            name: ToolDispatcher.federatedSearchToolName,
            arguments: federatedArgs(requester: hA)
        )
        #expect(!isError(result))
        let body = try #require(text(of: result))
        #expect(body.contains("kitchen-row"),
            "the room-scoped grant admits the kitchen row")
        #expect(!body.contains("garage-row"),
            "§10 answer-assembly narrowing must exclude rows outside the granted room")
    }
}
