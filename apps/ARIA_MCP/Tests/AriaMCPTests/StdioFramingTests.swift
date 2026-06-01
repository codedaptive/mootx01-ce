import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Coverage that the stdio loop pipes one newline-delimited request
/// frame through the dispatcher and writes one newline-delimited
/// response frame back, with stdout staying clean JSON-RPC.
///
/// The tests run the server against an in-memory pipe pair instead of
/// the process's real stdin/stdout so they can assert against the
/// bytes that would have been written.
///
/// `.serialized`: each case drives a real `Pipe()` pair and the stdio
/// read loop end-to-end; preserve the one-at-a-time execution the suite
/// ran under XCTest.
@Suite("Stdio framing", .serialized)
struct StdioFramingTests {

    @Test func testInitializeRoundTripsOverPipes() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-pipe-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let dispatcher = ARIA_MCPDispatcher(
            info: .init(name: "ARIA_MCP", version: "test"),
            tooling: ToolDispatcher(kit: kit, handle: handle)
        )
        let server = StdioServer(dispatcher: dispatcher)

        let inPipe = Pipe()
        let outPipe = Pipe()

        // Stage one inbound frame, then close the write side so the
        // server's read loop sees EOF and the await returns.
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2024-11-05")]),
        ])
        var payload = try frame.encoded()
        payload.append(0x0A)
        try inPipe.fileHandleForWriting.write(contentsOf: payload)
        try inPipe.fileHandleForWriting.close()

        await server.run(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )
        try outPipe.fileHandleForWriting.close()

        let response = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        // Server must terminate every response with a single newline.
        #expect(response.last == 0x0A)
        let trimmed = response.dropLast()
        let parsed = try JSONValue.parse(trimmed)
        let object = try #require(parsed.objectValue)
        #expect(object["jsonrpc"] == .string("2.0"))
        #expect(object["id"] == .integer(1))
        #expect(object["result"] != nil)
    }

    @Test func testToolsListRoundTripsOverPipes() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-pipe-tests-2")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let dispatcher = ARIA_MCPDispatcher(
            info: .init(name: "ARIA_MCP", version: "test"),
            tooling: ToolDispatcher(kit: kit, handle: handle)
        )
        let server = StdioServer(dispatcher: dispatcher)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(7),
            "method": .string("tools/list"),
        ])
        var payload = try frame.encoded()
        payload.append(0x0A)
        try inPipe.fileHandleForWriting.write(contentsOf: payload)
        try inPipe.fileHandleForWriting.close()

        await server.run(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )
        try outPipe.fileHandleForWriting.close()

        let response = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(response.last == 0x0A)
        let parsed = try JSONValue.parse(response.dropLast())
        let object = try #require(parsed.objectValue)
        let result = try #require(object["result"]?.objectValue)
        let tools = try #require(result["tools"]?.arrayValue)
        #expect(!tools.isEmpty, "tools/list must project the lexicon surface")
    }

    @Test func testParseErrorEmitsNullIDResponse() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-pipe-tests-3")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let dispatcher = ARIA_MCPDispatcher(
            info: .init(name: "ARIA_MCP", version: "test"),
            tooling: ToolDispatcher(kit: kit, handle: handle)
        )
        let server = StdioServer(dispatcher: dispatcher)

        let inPipe = Pipe()
        let outPipe = Pipe()
        // Garbage line: not valid JSON.
        try inPipe.fileHandleForWriting.write(contentsOf: Data("{ not json\n".utf8))
        try inPipe.fileHandleForWriting.close()

        await server.run(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )
        try outPipe.fileHandleForWriting.close()

        let response = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let parsed = try JSONValue.parse(response.dropLast())
        let object = try #require(parsed.objectValue)
        #expect(object["id"] == .null)
        let error = try #require(object["error"]?.objectValue)
        #expect(error["code"] == .integer(Int64(JSONRPCErrorCode.parseError)))
    }
}
