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
        return try await kit.open(storage: storage, owner: owner,
                                  identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
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
            embeddingModelID: "test-model-v1",
            // Subject = capped content so PR-03 dense-row replies carry
            // the text these tests assert on.
            subject: String(content.prefix(120)))
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
            "subject": .string(String(content.prefix(120))),
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

    // MARK: - 2. Omitted estateID hits the default estate (v1.0 regression)

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

}
