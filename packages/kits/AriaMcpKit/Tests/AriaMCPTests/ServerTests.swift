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

    // MARK: - Protocol-version negotiation

    /// A client requesting a supported version gets that exact version echoed.
    @Test func testInitializeSupportedVersion2024_11_05EchoedExactly() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(100),
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error: \(response.payload)")
            return
        }
        #expect(result.objectValue?["protocolVersion"] == .string("2024-11-05"))
    }

    /// A client requesting the second supported version (2025-03-26) gets it echoed.
    @Test func testInitializeSupportedVersion2025_03_26EchoedExactly() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(101),
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-03-26")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error: \(response.payload)")
            return
        }
        #expect(result.objectValue?["protocolVersion"] == .string("2025-03-26"))
    }

    /// Claude Desktop's current version (2025-11-25) gets echoed exactly.
    @Test func testInitializeSupportedVersion2025_11_25EchoedExactly() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(105),
            method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error: \(response.payload)")
            return
        }
        #expect(result.objectValue?["protocolVersion"] == .string("2025-11-25"))
    }

    /// An unsupported protocol version yields the server's latest supported
    /// version per MCP spec §3. The initialize does NOT produce a JSON-RPC error
    /// — the client receives a valid response and decides whether to proceed.
    @Test func testInitializeUnsupportedVersionYieldsLatestSupportedVersion() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(102),
            method: "initialize",
            params: .object(["protocolVersion": .string("9999-01-01")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        // Per MCP spec §3: server responds at the JSON-RPC level with its latest
        // version — no error. The client inspects the returned version and aborts
        // if it cannot speak that version.
        guard case .result(let result) = response.payload else {
            Issue.record("initialize must not return JSON-RPC error for unsupported version; got: \(response.payload)")
            return
        }
        let returned = result.objectValue?["protocolVersion"]?.stringValue
        #expect(returned == ARIA_MCPDispatcher.latestSupportedProtocolVersion,
                "unsupported version must yield latest supported (\(ARIA_MCPDispatcher.latestSupportedProtocolVersion)); got \(returned ?? "nil")")
    }

    /// A client that omits protocolVersion entirely gets the latest supported version.
    @Test func testInitializeMissingVersionYieldsLatestSupportedVersion() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(103),
            method: "initialize",
            params: .object([:])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize returned error for missing version: \(response.payload)")
            return
        }
        let returned = result.objectValue?["protocolVersion"]?.stringValue
        #expect(returned == ARIA_MCPDispatcher.latestSupportedProtocolVersion,
                "missing version must yield latest supported; got \(returned ?? "nil")")
    }

    /// Malformed version string (not a date-format string) yields the latest
    /// supported version — not a hard error — per MCP spec §3.
    @Test func testInitializeMalformedVersionStringYieldsLatestSupportedVersion() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(104),
            method: "initialize",
            params: .object(["protocolVersion": .string("not-a-version-at-all")])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("initialize must not return JSON-RPC error for malformed version string; got: \(response.payload)")
            return
        }
        let returned = result.objectValue?["protocolVersion"]?.stringValue
        #expect(returned == ARIA_MCPDispatcher.latestSupportedProtocolVersion,
                "malformed version must yield latest supported; got \(returned ?? "nil")")
    }

    /// The supported-versions list contains the expected canonical versions.
    @Test func testSupportedProtocolVersionsContainsExpectedVersions() {
        let versions = ARIA_MCPDispatcher.supportedProtocolVersions
        #expect(versions.contains("2024-11-05"), "2024-11-05 must be in supported list")
        #expect(versions.contains("2025-03-26"), "2025-03-26 must be in supported list")
        #expect(versions.contains("2025-11-25"), "2025-11-25 (Claude Desktop version) must be in supported list")
        // The latest supported version must be the first element (most recent).
        #expect(ARIA_MCPDispatcher.latestSupportedProtocolVersion == versions[0])
        #expect(ARIA_MCPDispatcher.latestSupportedProtocolVersion == "2025-11-25")
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

    // MARK: - tools/call: live verb with nonexistent ID surfaces as result-isError

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

    // MARK: - Build serial in estate_ping

    /// `moot_estate_ping` response includes a non-empty build segment.
    ///
    /// The stable prefix/shape assertion (starts with "pong: estate",
    /// contains "is live") must hold even after the serial is appended.
    /// The serial itself is non-empty and follows "— build ".
    @Test func testEstatePingIncludesBuildSerial() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(60),
            method: "tools/call",
            params: .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("estate_ping returned error: \(response.payload)")
            return
        }
        // Must not be a tool-level error result.
        #expect(result.objectValue?["isError"] != .bool(true),
                "estate_ping must not return isError:true")
        // Extract the text content.
        let content = try #require(result.objectValue?["content"]?.arrayValue)
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        // Stable shape assertions — these must hold regardless of the serial value.
        #expect(text.hasPrefix("pong: estate"),
                "estate_ping must start with 'pong: estate'; got: \(text)")
        #expect(text.contains("is live"),
                "estate_ping must contain 'is live'; got: \(text)")
        // Build segment: "— build <non-empty-serial>" must be present.
        #expect(text.contains("— build "),
                "estate_ping must contain '— build <serial>'; got: \(text)")
        // The part after "— build " must be non-empty.
        if let buildRange = text.range(of: "— build ") {
            let serial = String(text[buildRange.upperBound...])
            #expect(!serial.isEmpty,
                    "build serial must be non-empty; got empty string after '— build '")
        }
    }

    /// `MOOTX01_BUILD_SERIAL` env override is honored by `deriveBuildSerial`.
    ///
    /// We cannot set process env vars in Swift Testing without side-effects,
    /// so we test the override path by constructing a `ToolDispatcher` with
    /// an explicit `buildSerial` value (the same codepath the env override
    /// drives at server startup).
    @Test func testEstatePingHonorsBuildSerialOverride() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-serial-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Inject a known serial to simulate MOOTX01_BUILD_SERIAL=ABC123.
        let knownSerial = "ABC123"
        let tooling = ToolDispatcher(kit: kit, handle: handle, buildSerial: knownSerial)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        let request = JSONRPCRequest(
            id: .integer(61),
            method: "tools/call",
            params: .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("estate_ping returned error: \(response.payload)")
            return
        }
        let content = try #require(result.objectValue?["content"]?.arrayValue)
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        // The known serial must appear verbatim in the response.
        #expect(text.contains("build \(knownSerial)"),
                "estate_ping must echo the injected serial 'ABC123'; got: \(text)")
    }
}
