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
                    "subject": .string(String(content.prefix(120))),
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
    ///
    /// v2 reshape: `moot_link_memories` requires `relationship` (an enum of
    /// named relationship kinds) in place of v1's `kind` argument — the
    /// argument decoder rejects unknown keys (AriaV2MemoryMutations.swift:154-156,
    /// `AriaV2LinkMemoriesRequest.init`'s `allowedKeys`), so `kind` is renamed
    /// to `relationship` here to match the current schema; "relates" is a
    /// member of both the v1 kind vocabulary and the v2 relationship enum
    /// (AriaV2SelectedCatalog.swift:828-832).
    private func link(
        dispatcher: ARIA_MCPDispatcher,
        from fromID: String,
        to toID: String,
        relationship: String = "relates"
    ) async throws -> JSONValue {
        let request = JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_link_memories"),
                "arguments": .object([
                    "from_id": .string(fromID),
                    "to_id": .string(toID),
                    "relationship": .string(relationship),
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
    //
    // v2 reshape: `moot_connection_search` takes `memory_id` (UUID, required)
    // and `direction` (outgoing|incoming|both) in place of v1's `from_id`;
    // response text is "Found N authorized connections." in place of v1's
    // "found N outgoing connection(s)" — see
    // Sources/AriaMCP/AriaV2KnowledgeJournal.swift:473-477.

    /// A connection created through moot_link_memories is returned by
    /// moot_connection_search for the source memory.
    ///
    /// Mirrors Rust: `tunnel_recall_returns_outgoing_tunnels_for_wing` —
    /// result is a success (isError false), text contains the count line.
    @Test("moot_connection_search returns connections for the source memory (full round-trip, v2 memory_id/direction shape)")
    func connectionSearchReturnsCapturedConnection() async throws {
        let dispatcher = try await makeDispatcher()

        // File two memories — setup.
        let fromID = try await fileMemory(dispatcher: dispatcher, content: "source memory")
        let toID = try await fileMemory(dispatcher: dispatcher, content: "target memory")

        // Link them through moot_link_memories.
        let linkResult = try await link(dispatcher: dispatcher, from: fromID, to: toID, relationship: "relates")
        let linkObj = try #require(linkResult.objectValue)
        #expect(linkObj["isError"] == .bool(false), "link must succeed")

        // Search connections from the source memory.
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object(["memory_id": .string(fromID), "direction": .string("outgoing")]),
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
            text == "Found 1 authorized connections.",
            "result must report one authorized connection; got: \(text)"
        )
    }

    // MARK: - Memory with no outgoing connections returns zero, not an error

    /// Searching connections from an ID that has no outgoing connections
    /// returns a zero-count success result, not an error.
    ///
    /// Mirrors Rust: `tunnel_recall_empty_wing_returns_zero_tunnels`.
    @Test("moot_connection_search returns zero connections for a memory with no outgoing edges (v2 memory_id/direction shape)")
    func connectionSearchForIsolatedMemoryReturnsZero() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory but do not link it to anything.
        let isolatedID = try await fileMemory(dispatcher: dispatcher, content: "isolated memory")

        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object(["memory_id": .string(isolatedID), "direction": .string("outgoing")]),
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
            text == "Found 0 authorized connections.",
            "isolated memory must report zero authorized connections; got: \(text)"
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

    /// `moot_connection_search` must carry `memory_id` as a required field
    /// and `estate_id` as an optional property.
    ///
    /// v2 reshape: v1 asserted `from_id` required / `estateID` optional;
    /// the descriptor now declares `required: ["memory_id"]` with
    /// `estate_id` (snake_case) as an optional property
    /// (AriaV2SelectedCatalog.swift:474-485) — `from_id` no longer exists
    /// on this tool at all, and `ToolProjection.tools()` delegates to
    /// `AriaV2SelectedCatalog.registry(...).projectedTools`
    /// (ToolProjection.swift:171), so the old `from_id`/`estateID`-shaped
    /// descriptor at ToolProjection.swift:352 is dead and not what this
    /// assertion reaches.
    @Test("moot_connection_search schema lists memory_id as required and estate_id as optional (v2 reshape: from_id -> memory_id)")
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

        #expect(Set(required) == Set(["memory_id"]), "required must be exactly memory_id; got: \(required)")
        #expect(properties["estate_id"] != nil, "estate_id must be an optional property")
        #expect(!required.contains("estate_id"), "estate_id must not be required")
    }

    /// `moot_link_memories` must carry `from_id`, `to_id`, and `relationship`
    /// as required fields and `estate_id` as an optional property.
    ///
    /// v2 reshape: v1 asserted `kind` as a required field alongside
    /// `from_id`/`to_id`; the current descriptor drops `kind` entirely and
    /// requires `relationship` instead (AriaV2SelectedCatalog.swift:821-836,
    /// `AriaV2LinkMemoriesRequest.init`'s `allowedKeys`,
    /// AriaV2MemoryMutations.swift:154-156).
    @Test("moot_link_memories schema lists from_id, to_id, relationship as required")
    func linkMemoriesSchemaHasRequiredFields() {
        guard let tool = ToolProjection.tools().first(where: { $0.name == "moot_link_memories" }) else {
            Issue.record("moot_link_memories must appear in the projected tool list")
            return
        }
        let schema = tool.inputSchema.objectValue
        let required = schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        #expect(
            Set(required) == Set(["from_id", "to_id", "relationship"]),
            "required must be exactly from_id, to_id, relationship (v2 dropped kind); got: \(required)"
        )
        #expect(!required.contains("estate_id"), "estate_id must not be required")
    }
}
