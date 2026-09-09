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
/// the dispatcher end-to-end; concurrent estates contend under parallel
/// execution, so the suite runs one case at a time.
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
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
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
                    "subject": .string("aria-mcp end-to-end test row"),
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

    /// `MOOTX01_BUILD_SERIAL` env override is honored by `deriveBuildSerial`.
    ///
    /// We cannot set process env vars in Swift Testing without side-effects,
    /// so we test the override path by constructing a `ToolDispatcher` with
    /// an explicit `buildSerial` value (the same codepath the env override
    /// drives at server startup).

    // MARK: - Version-skew advisory

    /// When the host injects a version-skew advisory, both `moot_estate_ping`
    /// and `moot_estate_status` surface it verbatim under a `version_skew:`
    /// line. The default (`nil`) case is covered implicitly by every other
    /// test in this file — none of them mention "version_skew".

    /// The default (no advisory injected) case must not mention
    /// `version_skew` at all — the field is opt-in, not a fixed empty slot.
    @Test func testNoVersionSkewAdvisoryOmitsField() async throws {
        let dispatcher = try await makeDispatcher()
        let request = JSONRPCRequest(
            id: .integer(63),
            method: "tools/call",
            params: .object([
                "name": .string("moot_estate_status"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("estate_status returned error: \(response.payload)")
            return
        }
        let content = try #require(result.objectValue?["content"]?.arrayValue)
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        #expect(!text.contains("version_skew"),
                "no version_skew field expected when the host injected no advisory; got: \(text)")
    }

    // MARK: - Upstream-release advisory (update_available)

    /// When the host injects an update-advisory provider, both
    /// `moot_estate_ping` and `moot_estate_status` surface its line under
    /// `update_available:`. A provider returning nil (up to date / feed
    /// unreachable — the host's advisor collapses both to nil) must leave
    /// the field out entirely, mirroring version_skew's opt-in shape. The
    /// no-provider default is covered implicitly by every other test in
    /// this file — none of them mention "update_available".

    /// A wired provider that answers nil (the common up-to-date case) must
    /// leave `update_available` out entirely — opt-in field, never an empty
    /// slot.
    @Test func testNilUpdateAdvisoryOmitsField() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-update-nil-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())

        let tooling = ToolDispatcher(
            kit: kit, handle: handle,
            updateAdvisoryProvider: { nil }
        )
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        for toolName in ["moot_estate_ping", "moot_estate_status"] {
            let request = JSONRPCRequest(
                id: .integer(65),
                method: "tools/call",
                params: .object([
                    "name": .string(toolName),
                    "arguments": .object([:]),
                ])
            )
            let rawResponse = await dispatcher.handle(request)
            let response = try #require(rawResponse)
            guard case .result(let result) = response.payload else {
                Issue.record("\(toolName) returned error: \(response.payload)")
                continue
            }
            let content = try #require(result.objectValue?["content"]?.arrayValue)
            let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
            #expect(!text.contains("update_available"),
                    "\(toolName) must omit update_available when the provider answers nil; got: \(text)")
        }
    }
}

// MARK: - Truthful first-party serverInfo
//
// `DaemonReadiness.handshakeAgrees` requires five values to match the verified
// descriptor, two of which — instance and estate identifiers — the dispatcher
// did not emit before this mission. These cases pin both halves: that the
// authenticated lane now reports them, and that the third-party lane's bytes
// did not move.

@Suite("Server dispatch — first-party identity", .serialized)
struct ServerFirstPartyIdentityTests {

    typealias Vectors = FirstPartyAuthProtocolTests

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-identity-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        return ARIA_MCPDispatcher(info: info, tooling: ToolDispatcher(kit: kit, handle: handle))
    }

    private func initialize(_ dispatcher: ARIA_MCPDispatcher) async throws -> [String: JSONValue] {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .integer(1), method: "initialize",
            params: .object(["protocolVersion": .string("2025-11-25")])
        )
        let response = try #require(await dispatcher.handle(request))
        guard case .result(let value) = response.payload, let object = value.objectValue else {
            Issue.record("initialize did not return a result object")
            return [:]
        }
        return object
    }

    @Test("Without an identity the response is exactly what it was before this lane existed")
    func thirdPartyInitializeUnchanged() async throws {
        let result = try await initialize(try await makeDispatcher())
        let serverInfo = try #require(result["serverInfo"]?.objectValue)
        // Exactly two keys — no first-party field leaks onto the public lane.
        #expect(serverInfo.count == 2)
        #expect(serverInfo["name"]?.stringValue == "ARIA_MCP")
        #expect(serverInfo["version"]?.stringValue == "test")
        let capabilities = try #require(result["capabilities"]?.objectValue)
        #expect(capabilities["authenticated-first-party"] == nil)
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        #expect(capabilities["prompts"] != nil)
        #expect(capabilities["logging"] != nil)
    }

    @Test("With a verified identity serverInfo reports every field readiness checks")
    func firstPartyInitializeIsTruthful() async throws {
        var descriptor = Vectors.vectorDescriptor(mac: [])
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput()
        )
        let identity = FirstPartyServerIdentity(verifiedDescriptor: descriptor, serverName: "ARIA_MCP")
        let dispatcher = try await makeDispatcher().withFirstPartyIdentity(identity)
        let result = try await initialize(dispatcher)

        let serverInfo = try #require(result["serverInfo"]?.objectValue)
        // Every value is drawn from the same verified descriptor the client
        // checked, so a truthful serverInfo and a verified descriptor cannot
        // disagree.
        #expect(serverInfo["name"]?.stringValue == "ARIA_MCP")
        #expect(serverInfo["version"]?.stringValue == descriptor.binaryVersion)
        #expect(serverInfo["instanceIdentifier"]?.stringValue == descriptor.instanceIdentifier.uuidString)
        #expect(serverInfo["estateIdentifier"]?.stringValue == descriptor.estateIdentifier.uuidString)
        #expect(serverInfo["contractRevision"] == .integer(Int64(descriptor.contractRevision)))
        // Generations are decimal STRINGS: they are UInt64, and both Int64 and
        // JSON's safe-integer range are too small to carry them without either
        // trapping or losing exactness.
        #expect(serverInfo["descriptorGeneration"] == .string(String(descriptor.descriptorGeneration)))
        #expect(serverInfo["credentialGeneration"] == .string(String(descriptor.credentialGeneration)))
        #expect(serverInfo["mcpProtocolVersion"]?.stringValue == descriptor.mcpProtocolVersion)

        let capabilities = try #require(result["capabilities"]?.objectValue)
        #expect(capabilities["authenticated-first-party"] != nil)
        // The existing capabilities are additive, never displaced.
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        #expect(capabilities["prompts"] != nil)
        #expect(capabilities["logging"] != nil)
    }

    @Test("Attaching an identity does not mutate the dispatcher it came from")
    func identityAttachmentIsNonMutating() async throws {
        var descriptor = Vectors.vectorDescriptor(mac: [])
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput()
        )
        let base = try await makeDispatcher()
        let identity = FirstPartyServerIdentity(verifiedDescriptor: descriptor, serverName: "ARIA_MCP")
        _ = base.withFirstPartyIdentity(identity)
        // The original is a value type and must still be dark — otherwise
        // arming one lane would silently arm the other.
        #expect(base.firstPartyIdentity == nil)
        let serverInfo = try #require(try await initialize(base)["serverInfo"]?.objectValue)
        #expect(serverInfo.count == 2)
    }

    @Test("Generations above Int64.max are reported exactly, not trapped")
    func generationsAboveInt64MaxAreExact() async throws {
        // `Int64(someUInt64)` traps above Int64.max, and a monotonic counter has
        // no business being capped by a JSON encoder's signed range.
        var descriptor = Vectors.vectorDescriptor(mac: [])
        descriptor.credentialGeneration = UInt64.max
        descriptor.descriptorGeneration = UInt64(Int64.max) + 1
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput()
        )
        let identity = FirstPartyServerIdentity(verifiedDescriptor: descriptor, serverName: "ARIA_MCP")
        let result = try await initialize(try await makeDispatcher().withFirstPartyIdentity(identity))
        let serverInfo = try #require(result["serverInfo"]?.objectValue)
        #expect(serverInfo["credentialGeneration"] == .string("18446744073709551615"))
        #expect(serverInfo["descriptorGeneration"] == .string("9223372036854775808"))
        // And the whole response still encodes.
        #expect((try? JSONValue.object(result).encoded()) != nil)
    }
}

// MARK: - Resident product-tool lane

private struct EmptyCommunityHandler: CommunityToolHandler {
    func isCommunityTool(_ name: String) -> Bool { false }
    var communityToolList: [ProjectedTool] { [] }
    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "not found")
    }
}

private actor FirstPartyToolHandlerSpy: FirstPartyToolHandler {
    private(set) var calls: [String] = []

    func isFirstPartyTool(_ name: String) -> Bool {
        name == "fulcrum.context.read"
    }

    var firstPartyToolList: [ProjectedTool] {
        get async {
            [ProjectedTool(
                name: "fulcrum.context.read",
                description: "Read planning context.",
                inputSchema: .object(["type": .string("object")]),
                provenance: .product
            )]
        }
    }

    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        calls.append(name)
        return .object(["source": .string("product")])
    }
}

@Suite("Server dispatch — resident product tools", .serialized)
struct ServerFirstPartyProductToolTests {
    typealias Vectors = FirstPartyAuthProtocolTests

    private func dispatcher(_ handler: any FirstPartyToolHandler) -> ARIA_MCPDispatcher {
        ARIA_MCPDispatcher(
            info: .init(name: "mootx01", version: "test"),
            communityHandler: EmptyCommunityHandler(),
            firstPartyHandler: handler
        )
    }

    private func identity() -> FirstPartyServerIdentity {
        var descriptor = Vectors.vectorDescriptor(mac: [])
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput()
        )
        return FirstPartyServerIdentity(verifiedDescriptor: descriptor, serverName: "mootx01")
    }

    private func listedNames(_ dispatcher: ARIA_MCPDispatcher) async throws -> [String] {
        let response = try #require(await dispatcher.handle(JSONRPCRequest(
            id: .integer(1), method: "tools/list", params: nil
        )))
        guard case .result(let value) = response.payload else { return [] }
        return value.objectValue?["tools"]?.arrayValue?.compactMap {
            $0.objectValue?["name"]?.stringValue
        } ?? []
    }

    @Test("Product tools are absent and uncallable without first-party identity")
    func productToolsAreDarkOnOrdinaryDispatch() async throws {
        let spy = FirstPartyToolHandlerSpy()
        let base = dispatcher(spy)
        #expect(try await listedNames(base).isEmpty)
        let response = try #require(await base.handle(JSONRPCRequest(
            id: .integer(2), method: "tools/call",
            params: .object([
                "name": .string("fulcrum.context.read"),
                "arguments": .object([:]),
            ])
        )))
        guard case .error(let error) = response.payload else {
            Issue.record("ordinary lane unexpectedly called a product tool")
            return
        }
        #expect(error.code == JSONRPCErrorCode.methodNotFound)
        #expect(await spy.calls.isEmpty)
    }

    @Test("publicLane strips product tools even from an identity-bearing dispatcher")
    func publicLaneStripsProductTools() async throws {
        let spy = FirstPartyToolHandlerSpy()
        let publicLane = dispatcher(spy).withFirstPartyIdentity(identity()).publicLane
        #expect(publicLane.firstPartyHandler == nil)
        #expect(try await listedNames(publicLane).isEmpty)
    }
}
