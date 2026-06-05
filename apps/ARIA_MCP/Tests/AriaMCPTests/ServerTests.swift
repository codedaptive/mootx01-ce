import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// End-to-end coverage for the server: initialize, tools/list, and
/// tools/call against a live in-memory GeniusLocusKit estate. The
/// tests construct the dispatcher directly (no stdio loop) and pass
/// JSON-RPC requests through `ARIA_MCPDispatcher.handle(_:)`.
///
/// `.serialized`: every case opens a live in-memory estate and drives
/// the dispatcher end-to-end; preserve the one-at-a-time execution the
/// suite ran under XCTest.
@Suite("Server dispatch", .serialized)
struct ServerTests {

    /// Build a dispatcher wired to a fresh in-memory estate. Each test
    /// gets its own kit so state does not leak between cases.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    // MARK: - initialize

    @Test func testInitializeReturnsServerInfo() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error: \(response.payload)")
            return
        }
        let object = try #require(result.objectValue)
        #expect(object["protocolVersion"] == .string("2024-11-05"))
        let info = try #require(object["serverInfo"]?.objectValue)
        #expect(info["name"] == .string("ARIA_MCP"))
        let capabilities = try #require(object["capabilities"]?.objectValue)
        #expect(capabilities["tools"] != nil)
    }

    // MARK: - ping

    @Test func testPingReturnsEmptyObject() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(2),
            method: "ping",
            params: nil
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("ping returned error")
            return
        }
        #expect(result == .object([:]))
    }

    // MARK: - notifications

    @Test func testNotificationProducesNoResponse() async throws {
        let dispatcher = try await makeDispatcher()
        let notification = JSONRPCRequest(
            id: nil,
            method: "notifications/initialized",
            params: nil
        )
        let response = await dispatcher.handle(notification)
        #expect(response == nil)
    }

    // MARK: - tools/list

    @Test func testToolsListReturnsProjectedSurface() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(id: .integer(3), method: "tools/list", params: nil)
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("tools/list returned error")
            return
        }
        let object = try #require(result.objectValue)
        let tools = try #require(object["tools"]?.arrayValue)
        #expect(!tools.isEmpty)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("moot_file_memory"))
        #expect(names.contains("moot_memory_search"))
        // No substrate-driven verbs or old lexicon names on the surface.
        #expect(!names.contains("moot_capture_drawer"))
        #expect(!names.contains("moot_drawer_recall"))
        #expect(!names.contains(where: { $0.hasPrefix("propose_") }))
        #expect(!names.contains(where: { $0.hasPrefix("associate_") }))
    }

    // MARK: - tools/call: capture then recall

    @Test func testFileMemoryThenSearchRoundTripsThroughTheServer() async throws {
        let dispatcher = try await makeDispatcher()

        // File a memory with the AI-client surface (no infrastructure fields).
        let fileRequest = JSONRPCRequest(
            id: .integer(10),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_memory"),
                "arguments": .object([
                    "content": .string("aria-mcp end-to-end test row"),
                    "location": .string("aria-mcp-tests"),
                ]),
            ])
        )
        let fileRaw = await dispatcher.handle(fileRequest)
        let fileResponse = try #require(fileRaw)
        guard case .result(let fileResult) = fileResponse.payload else {
            Issue.record("moot_file_memory returned error: \(fileResponse.payload)")
            return
        }
        let fileObject = try #require(fileResult.objectValue)
        #expect(fileObject["isError"] == .bool(false))

        // Search for the memory using the new query surface.
        let searchRequest = JSONRPCRequest(
            id: .integer(11),
            method: "tools/call",
            params: .object([
                "name": .string("moot_memory_search"),
                "arguments": .object([
                    "query": .string("aria-mcp end-to-end test row"),
                ]),
            ])
        )
        let searchRaw = await dispatcher.handle(searchRequest)
        let searchResponse = try #require(searchRaw)
        guard case .result(let searchResult) = searchResponse.payload else {
            Issue.record("moot_memory_search returned error: \(searchResponse.payload)")
            return
        }
        let searchObject = try #require(searchResult.objectValue)
        #expect(searchObject["isError"] == .bool(false))
    }

    // MARK: - tools/call: stubbed verb surfaces as result-isError

    @Test func testEraseMemoryForNonexistentIDReturnsIsError() async throws {
        let dispatcher = try await makeDispatcher()
        // moot_erase_memory with a nonexistent row ID must return a tool-call
        // result with isError=true (not a JSON-RPC protocol error) so AI clients
        // can handle the failure gracefully.
        let request = JSONRPCRequest(
            id: .integer(20),
            method: "tools/call",
            params: .object([
                "name": .string("moot_erase_memory"),
                "arguments": .object([
                    "id": .string("nonexistent-row-id"),
                    "reason": .string("test erasure of nonexistent row"),
                    "confirmed": .bool(true),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_erase_memory returned JSON-RPC error: \(response.payload)")
            return
        }
        let object = try #require(result.objectValue)
        #expect(object["isError"] == .bool(true))
    }

    // MARK: - tools/call: unknown tool

    @Test func testUnknownToolReturnsMethodNotFoundError() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(30),
            method: "tools/call",
            params: .object([
                "name": .string("imaginary_tool"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("unknown tool did not produce JSON-RPC error")
            return
        }
        #expect(error.code == JSONRPCErrorCode.methodNotFound)
    }

    // MARK: - tools/call: malformed parameters

    @Test func testToolsCallWithoutNameReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(40),
            method: "tools/call",
            params: .object([:])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing name did not produce JSON-RPC error")
            return
        }
        #expect(error.code == JSONRPCErrorCode.invalidParams)
    }

    // MARK: - method not found

    @Test func testUnknownMethodReturnsMethodNotFound() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(id: .integer(50), method: "nope/nope", params: nil)
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("unknown method did not produce JSON-RPC error")
            return
        }
        #expect(error.code == JSONRPCErrorCode.methodNotFound)
    }
}
