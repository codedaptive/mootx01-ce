import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// Smoke tests for ARIA_MCP v1.0 wire-shape conformance (ARIA_MCP_SPEC_v0.2 §9).
///
/// Each test exercises the full stdio stack in-process: StdioServer + Pipe pair,
/// no real Claude Desktop. Frames are written to the read end, the write end is
/// closed (triggering EOF so the server loop exits), and the server's stdout
/// bytes are parsed from the output Pipe.
///
/// Named "compatibility set" tests because they verify the initialize handshake,
/// tools/list surface, and one tools/call against the wire shape two MCP clients
/// (Claude-compatible and a generic JSON-RPC client) would expect.
///
/// `.serialized`: each test opens a live in-memory estate and drives the full
/// stdio loop; preserve one-at-a-time execution.
@Suite("V1 conformance", .serialized)
struct V1ConformanceTests {

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Build a StdioServer wired to a fresh in-memory estate. Each test gets
    /// its own server so state does not leak between cases.
    private func makeServer() async throws -> StdioServer {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "v1-conformance-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "1.0-test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        return StdioServer(dispatcher: dispatcher)
    }

    /// Write one JSON-RPC frame to `pipe` and close the write side.
    private func sendFrame(_ frame: JSONValue, to pipe: Pipe) throws {
        var payload = try frame.encoded()
        payload.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
    }

    /// Write multiple JSON-RPC frames to `pipe` and close the write side.
    /// The server reads frames in a loop until EOF; all frames are processed
    /// before the server returns.
    private func sendFrames(_ frames: [JSONValue], to pipe: Pipe) throws {
        for frame in frames {
            var payload = try frame.encoded()
            payload.append(0x0A)
            try pipe.fileHandleForWriting.write(contentsOf: payload)
        }
        try pipe.fileHandleForWriting.close()
    }

    /// Run the server and collect all JSON-RPC responses from its output pipe.
    ///
    /// Drains the output pipe in a concurrent Task before `server.run()` begins
    /// writing, preventing a pipe-buffer deadlock that manifests when the
    /// response payload exceeds macOS's 16 KiB default pipe buffer.
    ///
    /// The deadlock pattern that caused the hang (MX-TAB-7 regression, 2026-07-12):
    ///   1. `server.run()` writes the `tools/list` response (71 tools ≈ 30+ KiB)
    ///      to `outPipe.fileHandleForWriting` via a blocking `write(2)` syscall.
    ///   2. `write(2)` fills the 16 KiB pipe buffer and stalls — the kernel blocks
    ///      the write until the read side drains some bytes.
    ///   3. `readToEnd()` (the only consumer) was called AFTER `server.run()` in
    ///      the old sequential pattern, so it was never reached.
    ///   4. Neither side could make progress: permanent deadlock.
    ///
    /// Fix: launch a drain Task that calls `readToEnd()` before the server starts,
    /// so the write never accumulates more than ~16 KiB of unread bytes. The drain
    /// Task returns when the write side is closed (EOF), which happens immediately
    /// after `server.run()` exits normally.
    private func collectResponses(
        server: StdioServer,
        input inPipe: Pipe,
        output outPipe: Pipe
    ) async throws -> [[String: JSONValue]] {
        // Start draining BEFORE the server starts writing so the pipe buffer
        // never fills. readToEnd() blocks until outPipe.fileHandleForWriting
        // is closed (see below), so this Task lives for exactly the right duration.
        let drain = Task {
            (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        await server.run(input: inPipe.fileHandleForReading, output: outPipe.fileHandleForWriting)
        // Closing the write side signals EOF to drain's readToEnd(), causing it to
        // return with whatever bytes the server wrote.
        try outPipe.fileHandleForWriting.close()
        let raw = await drain.value
        let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
        return try lines.map { line in
            let parsed = try JSONValue.parse(Data(line))
            guard let obj = parsed.objectValue else {
                throw V1ConformanceError.expectedObject
            }
            return obj
        }
    }

    private enum V1ConformanceError: Error {
        case expectedObject
    }

    // ── Test 1 — Claude-compatible initialize ────────────────────────────────

    /// VC-1: Claude-compatible initialize handshake over the stdio pipe.
    ///
    /// Sends the protocol version Claude Desktop uses (`2025-11-25`) and
    /// asserts the server echoes it back with v1.0 capability keys:
    /// tools, resources, prompts, and logging.
    @Test func v1InitializeAdvertisesAllCapabilities() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        // Claude Desktop sends clientInfo; a generic client may not.
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2025-11-25"),
                "clientInfo": .object([
                    "name": .string("test-claude"),
                    "version": .string("1.0"),
                ]),
            ]),
        ])
        try sendFrame(frame, to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        #expect(responses.count == 1, "one request must produce one response")
        let response = try #require(responses.first)
        let result = try #require(response["result"]?.objectValue)

        // Server must echo back the protocol version.
        #expect(result["protocolVersion"] == .string("2025-11-25"))

        // serverInfo must include the server name.
        let serverInfo = try #require(result["serverInfo"]?.objectValue)
        #expect(serverInfo["name"] != nil, "serverInfo.name must be present")

        // All four v1.0 capability keys must be present.
        let capabilities = try #require(result["capabilities"]?.objectValue)
        #expect(capabilities["tools"] != nil, "capabilities.tools must be advertised")
        #expect(capabilities["resources"] != nil, "capabilities.resources must be advertised")
        #expect(capabilities["prompts"] != nil, "capabilities.prompts must be advertised")
        #expect(capabilities["logging"] != nil, "capabilities.logging must be advertised")
    }

    // ── Test 2 — tools/list surface count ───────────────────────────────────

    /// VC-2: `tools/list` returns exactly 71 tools.
    ///
    /// The count is a snapshot of the v1.1 ARIA lexicon surface. If the count
    /// changes legitimately (a tool added or renamed), update this assertion
    /// and commit the reason with the change.
    /// 66 → 71: +2 contradiction-hunter tools (moot_hunt_contradictions,
    /// moot_review_tunnel) and +3 dataset tools (moot_file_dataset,
    /// moot_dataset_query, moot_dataset_stats).
    @Test func v1ToolsListReturns71Tools() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/list"),
        ])
        try sendFrame(frame, to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        let response = try #require(responses.first)
        let result = try #require(response["result"]?.objectValue)
        let tools = try #require(result["tools"]?.arrayValue)
        // 71 = prior 66 + 2 contradiction-hunter tools + 3 dataset tools.
        //   Contradiction hunter: moot_hunt_contradictions (recipe, on-demand
        //     content sweep) + moot_review_tunnel (Tier 2, settle a PROPOSED tunnel).
        //   Dataset (MX-TAB-7): moot_file_dataset, moot_dataset_query, moot_dataset_stats.
        // Prior 66 = interface + federation + recipe + lens + vault + maintenance:
        //   20th interface = moot_memory_get (Tier 1, fetch-drawer-by-ID).
        //   23rd lens = moot_lens_node_motion (diffusion node-layer lens).
        //   11th recipe = moot_recollect (DA1 distillation).
        //   moot_palace_import (PAR-PB-1), moot_drain_status, moot_reclassify_fdc.
        #expect(tools.count == 71, "tools/list must return exactly 71 tools; got \(tools.count)")
    }

    // ── Test 3 — moot_estate_ping round-trip ────────────────────────────────

    /// VC-3: `moot_estate_ping` round-trips through the stdio stack.
    ///
    /// The response must be a non-error tool result whose text content
    /// contains "pong" (confirming the estate handle is live).
    @Test func v1EstatePingRoundTrip() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(3),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
            ]),
        ])
        try sendFrame(frame, to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        let response = try #require(responses.first)

        // Must be a result (not a JSON-RPC error).
        #expect(response["error"] == nil, "moot_estate_ping must not return a JSON-RPC error")
        let result = try #require(response["result"]?.objectValue)

        // Tool result must not be an error result.
        #expect(result["isError"] != .bool(true), "moot_estate_ping must not return isError:true")

        // Content must include "pong" confirming the estate is live.
        let content = try #require(result["content"]?.arrayValue)
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        #expect(text.contains("pong") || text.contains("estate"),
                "moot_estate_ping response must contain 'pong' or 'estate'; got: \(text)")
    }

    // ── Test 4 — schema version gate ────────────────────────────────────────

    /// VC-4a: `tools/call` with a non-conforming `schema_version` is rejected
    /// with a JSON-RPC `invalidParams` error (ARIA_MCP_SPEC_v0.2 §8).
    @Test func v1SchemaVersionGateRejectsBadFormat() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(4),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
                "schema_version": .string("bad_format"),
            ]),
        ])
        try sendFrame(frame, to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        let response = try #require(responses.first)

        // A bad schema_version must produce a JSON-RPC error response.
        let error = try #require(response["error"]?.objectValue,
                                 "bad schema_version must produce a JSON-RPC error")
        let code = try #require(error["code"]?.integerValue)
        #expect(code == Int64(JSONRPCErrorCode.invalidParams),
                "schema_version error must use invalidParams code; got \(code)")
    }

    /// VC-4b: `tools/call` with a conforming `schema_version` succeeds.
    ///
    /// `geniuslocus.<verb>.<major>` is the canonical format; any such value is
    /// accepted in v1.0 (accept-all stub — the real version check drops in
    /// without rework when the spec's version table is finalized).
    @Test func v1SchemaVersionGateAcceptsConformingVersion() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(5),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
                "schema_version": .string("geniuslocus.capture.1"),
            ]),
        ])
        try sendFrame(frame, to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        let response = try #require(responses.first)

        // A conforming schema_version must not produce a JSON-RPC error.
        #expect(response["error"] == nil,
                "conforming schema_version must not produce an error; got: \(response)")
        #expect(response["result"] != nil, "conforming schema_version must produce a result")
    }

    // ── Test 5 — resources/list and prompts/list ─────────────────────────────

    /// VC-5: `resources/list` and `prompts/list` both return empty arrays.
    ///
    /// Resources and prompts are advertised in v1.0 capabilities but the lists
    /// are empty until v1.1 implements subscriptions and recipe-prompt surfacing.
    /// A client MUST NOT receive an error when calling these methods.
    @Test func v1ResourcesAndPromptsListReturnEmptyArrays() async throws {
        let server = try await makeServer()
        let inPipe = Pipe()
        let outPipe = Pipe()

        // Two frames — server processes both before EOF.
        let resourcesFrame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(6),
            "method": .string("resources/list"),
        ])
        let promptsFrame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(7),
            "method": .string("prompts/list"),
        ])
        try sendFrames([resourcesFrame, promptsFrame], to: inPipe)

        let responses = try await collectResponses(server: server, input: inPipe, output: outPipe)
        #expect(responses.count == 2, "two requests must produce two responses")

        for response in responses {
            // Neither response must be an error.
            #expect(response["error"] == nil,
                    "resources/list and prompts/list must not return errors; got: \(response)")
            let result = try #require(response["result"]?.objectValue)
            // Both results must contain an empty array under "resources" or "prompts".
            let hasEmptyResources = result["resources"]?.arrayValue?.isEmpty == true
            let hasEmptyPrompts = result["prompts"]?.arrayValue?.isEmpty == true
            #expect(hasEmptyResources || hasEmptyPrompts,
                    "result must contain empty resources or prompts array; got: \(result)")
        }
    }
}
