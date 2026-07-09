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
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
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
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
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
        #expect(!tools.isEmpty, "tools/list must project the tool surface")
    }

    /// Verifies the frame size cap (CAND-051): a frame that exceeds the cap
    /// without a newline terminator causes the server to close input cleanly
    /// rather than growing the buffer unboundedly. The writer gets no response
    /// (the server never dispatched a frame) and the server exits without panic.
    @Test func testOversizedFrameClosesInputCleanly() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-oversize-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ARIA_MCPDispatcher(
            info: .init(name: "ARIA_MCP", version: "test"),
            tooling: ToolDispatcher(kit: kit, handle: handle)
        )
        let server = StdioServer(dispatcher: dispatcher)

        // Use a small maxFrameBytes so the test runs quickly without allocating 4 MiB.
        // 64 bytes cap, 65 bytes payload: same logic, much less memory.
        //
        // A prior version of this test also staged a literal 4 MiB + 1 byte
        // payload on a separate, never-drained `inPipe`/`outPipe` pair to
        // exercise the cap "for real" before the smaller/faster case was
        // introduced below. That write was never read by anything: the OS
        // pipe buffer (~64 KiB on macOS) filled and the synchronous
        // `FileHandle.write(contentsOf:)` call blocked in the `write(2)`
        // syscall forever (confirmed via `sample` on the hung process —
        // stack bottoms out in `NSFileHandle.write` → `write`). Every run of
        // this test hung the `.serialized` "Stdio framing" suite
        // indefinitely, stalling the full test binary. The behavior this
        // test proves (frame-size cap trips and the server exits cleanly
        // with no response) is fully covered by the smallCap/smallPayload
        // case below, so the oversized/unread pipe setup was dead weight,
        // not additional coverage — removed rather than fixed-in-place.
        let smallCap = 64
        let smallPayload = Data(repeating: 0x42 /* 'B' */, count: smallCap + 1)

        let inPipe = Pipe()
        let outPipe = Pipe()
        try inPipe.fileHandleForWriting.write(contentsOf: smallPayload)
        try inPipe.fileHandleForWriting.close()

        await server.run(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting,
            maxFrameBytes: smallCap
        )
        try outPipe.fileHandleForWriting.close()

        // No newline was ever sent, so no frame was dispatched — output must be empty.
        let response = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(response.isEmpty, "oversized frame with no newline must produce no response; got \(response.count) bytes")
    }

    @Test func testParseErrorEmitsNullIDResponse() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-pipe-tests-3")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
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
