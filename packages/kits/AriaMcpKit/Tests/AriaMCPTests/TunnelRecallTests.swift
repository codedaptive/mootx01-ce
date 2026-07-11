import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// ARIA_MCP dispatch tests for the Tier 2 connection tools:
/// `moot_link_memories` and `moot_connection_search` (MCP-INT-01
/// surface replacement for `moot_capture_tunnel` / `moot_tunnel_recall`).
///
/// Tests mirror the semantics of the Rust dispatch_tests.rs §13–14:
/// - link creates an outgoing connection
/// - connection_search returns outgoing connections for a memory
/// - connection_search on an ID with no connections returns zero, not an error
/// - missing required `from_id` on connection_search is invalidParams
///
/// `.serialized`: each test opens a live in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("Connection dispatch", .serialized)
struct TunnelRecallTests {

    // MARK: - Harness

    /// Build a fresh dispatcher wired to a clean in-memory estate.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "connection-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// File a memory and return its row ID. Parses "filed memory <id>"
    /// from the first line of the tool result text.
    private func fileMemory(
        dispatcher: ARIA_MCPDispatcher,
        content: String,
        location: String = "connection-tests"
    ) async throws -> String {
        let request = JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_memory"),
                "arguments": .object([
                    "content": .string(content),
                    "location": .string(location),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "moot_file_memory returned JSON-RPC error in test setup: \(response.payload)"
            )
        }
        let obj = try #require(result.objectValue)
        guard obj["isError"]?.boolValue != true else {
            let msg = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? "unknown"
            throw JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "moot_file_memory returned isError=true: \(msg)"
            )
        }
        // First line is "filed memory <id>".
        let firstLine = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?
            .split(separator: "\n").first.map(String.init) ?? ""
        let id = firstLine.replacingOccurrences(of: "filed memory ", with: "")
        guard !id.isEmpty, id != firstLine else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "could not parse memory ID from: \(firstLine)"
            )
        }
        return id
    }

    /// Link two memories and return the raw result.
    private func link(
        dispatcher: ARIA_MCPDispatcher,
        from fromID: String,
        to toID: String,
        kind: String = "relates"
    ) async throws -> JSONValue {
        let request = JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_link_memories"),
                "arguments": .object([
                    "from_id": .string(fromID),
                    "to_id": .string(toID),
                    "kind": .string(kind),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.internalError,
                message: "moot_link_memories returned JSON-RPC error: \(response.payload)"
            )
        }
        return result
    }

    // MARK: - Happy path: full round-trip via moot_link_memories + moot_connection_search

    /// A connection created through moot_link_memories is returned by
    /// moot_connection_search for the source memory.
    ///
    /// Mirrors Rust: `tunnel_recall_returns_outgoing_tunnels_for_wing` —
    /// result is a success (isError false), text contains the count line.
    @Test("moot_connection_search returns connections for the source memory (full round-trip)")
    func connectionSearchReturnsCapturedConnection() async throws {
        let dispatcher = try await makeDispatcher()

        // File two memories — setup.
        let fromID = try await fileMemory(dispatcher: dispatcher, content: "source memory")
        let toID = try await fileMemory(dispatcher: dispatcher, content: "target memory")

        // Link them through moot_link_memories.
        let linkResult = try await link(dispatcher: dispatcher, from: fromID, to: toID, kind: "relates")
        let linkObj = try #require(linkResult.objectValue)
        #expect(linkObj["isError"] == .bool(false), "link must succeed")

        // Search connections from the source memory.
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object(["from_id": .string(fromID)]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_connection_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "connection_search must be a success result")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(
            text.hasPrefix("connections from \(fromID): 1"),
            "result must report one connection; got: \(text)"
        )
    }

    // MARK: - Memory with no outgoing connections returns zero, not an error

    /// Searching connections from an ID that has no outgoing connections
    /// returns a zero-count success result, not an error.
    ///
    /// Mirrors Rust: `tunnel_recall_empty_wing_returns_zero_tunnels`.
    @Test("moot_connection_search returns zero connections for a memory with no outgoing edges")
    func connectionSearchForIsolatedMemoryReturnsZero() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory but do not link it to anything.
        let isolatedID = try await fileMemory(dispatcher: dispatcher, content: "isolated memory")

        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object(["from_id": .string(isolatedID)]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_connection_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "zero-connection search must be a success result")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(
            text.hasPrefix("connections from \(isolatedID): 0"),
            "isolated memory must report zero connections; got: \(text)"
        )
    }

    // MARK: - Missing required `from_id` argument → invalidParams

    /// Omitting the required `from_id` argument is an out-of-band
    /// invalidParams transport fault, not a tool-level error result.
    ///
    /// Mirrors Rust: `tunnel_recall_missing_wing_returns_invalid_params`.
    @Test("moot_connection_search without from_id returns invalidParams")
    func connectionSearchMissingFromIDReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()

        let request = JSONRPCRequest(
            id: .integer(3),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing from_id must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(
            error.code == JSONRPCErrorCode.invalidParams,
            "missing from_id must map to invalidParams; got code \(error.code)"
        )
    }

    // MARK: - Schema assertions

    /// `moot_connection_search` must carry `from_id` as a required field and
    /// `estateID` as an optional property.
    @Test("moot_connection_search schema lists from_id as required and estateID as optional")
    func connectionSearchSchemaHasFromIDRequiredAndEstateIDOptional() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_connection_search" }) else {
            Issue.record("moot_connection_search must appear in the projected tool list")
            return
        }
        guard case .interface = tool.provenance else {
            Issue.record("moot_connection_search must have .interface provenance, got: \(tool.provenance)")
            return
        }
        let schema = tool.inputSchema.objectValue
        let properties = schema?["properties"]?.objectValue ?? [:]
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        #expect(required.contains("from_id"), "from_id must be required; got: \(required)")
        #expect(properties["estateID"] != nil, "estateID must be an optional property")
        #expect(!required.contains("estateID"), "estateID must not be required")
    }

    /// `moot_link_memories` must carry `from_id`, `to_id`, and `kind` as
    /// required fields and `estateID` as an optional property.
    @Test("moot_link_memories schema lists from_id, to_id, kind as required")
    func linkMemoriesSchemaHasRequiredFields() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_link_memories" }) else {
            Issue.record("moot_link_memories must appear in the projected tool list")
            return
        }
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        #expect(required.contains("from_id"), "from_id must be required")
        #expect(required.contains("to_id"), "to_id must be required")
        #expect(required.contains("kind"), "kind must be required")
        #expect(!required.contains("estateID"), "estateID must not be required")
    }
}
