import Foundation
import Testing
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Verifies the TunnelKind.wireString contract at two levels:
///
/// 1. Direct: all ten cases produce the exact ARIA v2 wire vocabulary.
/// 2. End-to-end: both response paths that emit tunnel kind strings —
///    moot_memory_get depth:full (AriaV2MemoryOperations.loadTunnels) and
///    moot_connection_search (AriaV2KnowledgeJournal.connectionSearch) —
///    carry the correct wire value through to the JSON response.
///
/// `.serialized`: each end-to-end test opens a live in-memory estate.
@Suite("TunnelKind wire-string contract", .serialized)
struct TunnelKindWireTests {

    // MARK: - Direct mapping

    /// Enumerates all ten TunnelKind cases and asserts the exact wire string
    /// for each.  TunnelKind is not CaseIterable; the explicit array ensures
    /// every case appears and a new case in the enum must also be listed here.
    @Test("wireString covers all ten TunnelKind cases with exact ARIA v2 contract values")
    func wireStringCoversAllCases() {
        let cases: [(TunnelKind, String)] = [
            (.supersedes,  "supersedes"),
            (.references,  "references"),
            (.blocks,      "blocks"),
            (.validates,   "validates"),
            (.contradicts, "contradicts"),
            (.derivesFrom, "derivesFrom"),
            (.covers,      "covers"),
            (.elaborates,  "elaborates"),
            (.respondsTo,  "respondsTo"),
            (.parent,      "parent"),
        ]
        for (kind, expected) in cases {
            #expect(kind.wireString == expected,
                    "TunnelKind.\(kind).wireString must be \"\(expected)\"")
        }
    }

    // MARK: - End-to-end harness

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "tunnel-kind-wire-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    private func fileMemory(dispatcher: ARIA_MCPDispatcher, content: String) async throws -> String {
        let request = JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_memory"),
                "arguments": .object([
                    "content": .string(content),
                    "subject": .string(String(content.prefix(120))),
                    "location": .string("tunnel-kind-wire-tests"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError,
                               message: "moot_file_memory returned JSON-RPC error: \(response.payload)")
        }
        let firstLine = result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue?
            .split(separator: "\n").first.map(String.init) ?? ""
        let id = firstLine.replacingOccurrences(of: "filed memory ", with: "")
        guard !id.isEmpty, id != firstLine else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError,
                               message: "could not parse memory ID from: \(firstLine)")
        }
        return id
    }

    private func link(
        dispatcher: ARIA_MCPDispatcher,
        from fromID: String,
        to toID: String,
        relationship: String
    ) async throws {
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
            throw JSONRPCError(code: JSONRPCErrorCode.internalError,
                               message: "moot_link_memories returned JSON-RPC error: \(response.payload)")
        }
        let obj = try #require(result.objectValue)
        guard obj["isError"]?.boolValue != true else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError,
                               message: "moot_link_memories returned isError=true")
        }
    }

    // MARK: - End-to-end: moot_memory_get depth:full (AriaV2MemoryOperations path)

    /// Links two memories with relationship "supersedes", then calls
    /// moot_memory_get with depth:full on the source memory and asserts the
    /// tunnels array carries kind="supersedes".
    ///
    /// This exercises the AriaV2MemoryOperations.loadTunnels path (line 806),
    /// which now calls tunnel.kind.wireString instead of String(describing:).
    @Test("moot_memory_get depth:full emits correct wire kind via loadTunnels path")
    func memoryGetDepthFullEmitsCorrectTunnelKind() async throws {
        let dispatcher = try await makeDispatcher()

        let fromID = try await fileMemory(dispatcher: dispatcher, content: "source for kind wire test")
        let toID = try await fileMemory(dispatcher: dispatcher, content: "target for kind wire test")
        try await link(dispatcher: dispatcher, from: fromID, to: toID, relationship: "supersedes")

        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_memory_get"),
                "arguments": .object([
                    "memory_id": .string(fromID),
                    "depth": .string("full"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_memory_get returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] != .bool(true), "memory_get must succeed")

        let memories = obj["structuredContent"]?.objectValue?["data"]?
            .objectValue?["memories"]?.arrayValue
        let memory = try #require(memories?.first?.objectValue,
                                  "response must contain at least one memory")
        let tunnels = try #require(memory["tunnels"]?.arrayValue,
                                   "depth:full memory must carry a tunnels array")
        #expect(!tunnels.isEmpty, "tunnels array must be non-empty after moot_link_memories")
        let firstTunnel = try #require(tunnels.first?.objectValue)
        let kind = try #require(firstTunnel["kind"]?.stringValue,
                                "tunnel must carry a kind string")
        #expect(kind == "supersedes",
                "loadTunnels path must emit \"supersedes\" for a supersedes tunnel; got \"\(kind)\"")
    }

    // MARK: - End-to-end: moot_connection_search (AriaV2KnowledgeJournal path)

    /// Links two memories with relationship "supersedes", then calls
    /// moot_connection_search and asserts the edges array carries kind="supersedes".
    ///
    /// This exercises the AriaV2KnowledgeJournal.connectionSearch path (line 430),
    /// which now calls row.0.kind.wireString instead of String(describing:).
    @Test("moot_connection_search emits correct wire kind via KnowledgeJournal path")
    func connectionSearchEmitsCorrectTunnelKind() async throws {
        let dispatcher = try await makeDispatcher()

        let fromID = try await fileMemory(dispatcher: dispatcher, content: "journal source for kind wire test")
        let toID = try await fileMemory(dispatcher: dispatcher, content: "journal target for kind wire test")
        try await link(dispatcher: dispatcher, from: fromID, to: toID, relationship: "supersedes")

        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_connection_search"),
                "arguments": .object([
                    "memory_id": .string(fromID),
                    "direction": .string("outgoing"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_connection_search returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] != .bool(true), "connection_search must succeed")

        let edges = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue?["edges"]?.arrayValue,
            "response must carry an edges array"
        )
        #expect(!edges.isEmpty, "edges must be non-empty after moot_link_memories")
        let firstEdge = try #require(edges.first?.objectValue)
        let kind = try #require(firstEdge["kind"]?.stringValue,
                                "edge must carry a kind string")
        #expect(kind == "supersedes",
                "connectionSearch path must emit \"supersedes\" for a supersedes tunnel; got \"\(kind)\"")
    }
}
