import Testing
import Foundation
import AriaLexiconLib
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// ARIA_MCP dispatch tests for moot_tunnel_recall (Swift parity with Rust v2b-p1).
///
/// These tests mirror the semantics of the Rust dispatch_tests.rs §13
/// (`tunnel_recall_returns_outgoing_tunnels_for_wing`,
/// `tunnel_recall_empty_wing_returns_zero_tunnels`,
/// `tunnel_recall_missing_wing_returns_invalid_params`) and the §14
/// schema-key assertion for `moot_tunnel_recall`. The Swift
/// `moot_capture_tunnel` tool handler is not yet wired, so tunnel
/// capture for test setup goes through GLK directly
/// (`GeniusLocusKit.estate(for:)` → `Estate.capture(TunnelCaptureFrame)`),
/// matching the pattern the GLK RecallTunnelsTests already use.
///
/// `.serialized`: each test opens a live in-memory estate; preserve
/// one-at-a-time execution to prevent GeniusLocusKit actor contention.
@Suite("Tunnel recall dispatch", .serialized)
struct TunnelRecallTests {

    // MARK: - Harness

    /// Build a fresh dispatcher wired to a clean in-memory estate.
    private func makeDispatcher() async throws -> (ARIA_MCPDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "tunnel-recall-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        return (dispatcher, kit, handle)
    }

    /// Capture one outgoing tunnel into the estate via GLK (estate-direct,
    /// not through the MCP surface — the Swift capture_tunnel handler is
    /// not yet wired). Mirrors the setup pattern in GLK RecallTunnelsTests.
    private func captureTunnel(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        sourceWing: String,
        targetWing: String,
        label: String = "relates"
    ) async throws {
        let estate = try await kit.estate(for: handle)
        _ = try await estate.capture(
            TunnelCaptureFrame(
                sourceWing: sourceWing, sourceRoom: "room-src",
                targetWing: targetWing, targetRoom: "room-dst",
                label: label,
                addedBy: "tunnel-recall-tests",
                sourceDrawerId: nil,
                targetDrawerId: nil,
                kind: .references
            )
        )
    }

    // MARK: - Happy path: capture then recall by wing

    /// A tunnel captured into the estate is returned by moot_tunnel_recall.
    ///
    /// Mirrors Rust: `tunnel_recall_returns_outgoing_tunnels_for_wing` —
    /// result is a success (isError false), text starts with the count line.
    @Test("moot_tunnel_recall returns tunnels for the source wing")
    func recallReturnsCapturedTunnel() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()

        // Capture a tunnel via GLK so the estate has outgoing edges for alpha-wing.
        try await captureTunnel(
            kit: kit, handle: handle,
            sourceWing: "alpha-wing", targetWing: "beta-wing"
        )

        // Recall tunnels for alpha-wing through the MCP dispatch surface.
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "tools/call",
            params: .object([
                "name": .string("moot_tunnel_recall"),
                "arguments": .object([
                    "wing": .string("alpha-wing"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_tunnel_recall returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "tunnel_recall must be a success result")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(
            text.hasPrefix("recalled 1 tunnel(s) from wing alpha-wing"),
            "result must report the tunnel count and wing; got: \(text)"
        )
    }

    // MARK: - Empty wing returns zero count, not an error

    /// Recalling from a wing with no outgoing tunnels returns a zero-count
    /// success result, not an error.
    ///
    /// Mirrors Rust: `tunnel_recall_empty_wing_returns_zero_tunnels`.
    @Test("moot_tunnel_recall returns zero tunnels for a wing with no outgoing edges")
    func recallEmptyWingReturnsSuccessWithZeroCount() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        // No tunnels captured — the estate is empty for this wing.
        let request = JSONRPCRequest(
            id: .integer(2),
            method: "tools/call",
            params: .object([
                "name": .string("moot_tunnel_recall"),
                "arguments": .object([
                    "wing": .string("unlinked-wing"),
                ]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .result(let result) = response.payload else {
            Issue.record("moot_tunnel_recall (empty wing) returned JSON-RPC error: \(response.payload)")
            return
        }
        let obj = try #require(result.objectValue)
        #expect(obj["isError"] == .bool(false), "empty-wing tunnel_recall must be a success result")
        let text = try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue,
            "content[0].text must be present"
        )
        #expect(
            text.hasPrefix("recalled 0 tunnel(s)"),
            "empty wing result must report zero tunnels; got: \(text)"
        )
    }

    // MARK: - Missing required `wing` argument → invalidParams

    /// Omitting the required `wing` argument is an out-of-band invalidParams
    /// transport fault, not a tool-level error result.
    ///
    /// Mirrors Rust: `tunnel_recall_missing_wing_returns_invalid_params`.
    @Test("moot_tunnel_recall without wing argument returns invalidParams")
    func recallMissingWingReturnsInvalidParams() async throws {
        let (dispatcher, _, _) = try await makeDispatcher()

        let request = JSONRPCRequest(
            id: .integer(3),
            method: "tools/call",
            params: .object([
                "name": .string("moot_tunnel_recall"),
                "arguments": .object([:]),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        let response = try #require(rawResponse)
        guard case .error(let error) = response.payload else {
            Issue.record("missing wing must produce JSON-RPC error, got: \(response.payload)")
            return
        }
        #expect(
            error.code == JSONRPCErrorCode.invalidParams,
            "missing wing must map to invalidParams; got code \(error.code)"
        )
    }

    // MARK: - tools/list schema assertion

    /// moot_tunnel_recall appears in tools/list with `wing` as a required
    /// field and `estateID` as an optional property.
    ///
    /// Mirrors Rust dispatch_tests.rs §14 schema-key assertion for
    /// moot_tunnel_recall: required includes "wing", properties includes "estateID".
    @Test("moot_tunnel_recall schema lists wing as required and carries optional estateID")
    func tunnelRecallSchemaHasWingRequiredAndEstateIDOptional() async throws {
        // ToolProjection.tools() is the source of truth for the projected surface.
        // tools/list is built from it; reading the projection directly avoids
        // the dispatcher round-trip and tests the schema itself, not encoding.
        let tool = try #require(
            ToolProjection.tools().first(where: { $0.name == "moot_tunnel_recall" }),
            "moot_tunnel_recall must appear in the projected tool list"
        )

        // Verify provenance is a lexicon pair (.recall, .tunnel).
        guard case .lexicon(let verb, let noun) = tool.provenance else {
            Issue.record("moot_tunnel_recall must have lexicon provenance, got: \(tool.provenance)")
            return
        }
        #expect(verb == .recall)
        #expect(noun == .tunnel)

        // Schema structure checks.
        let schema = try #require(tool.inputSchema.objectValue, "inputSchema must be an object")
        let properties = try #require(schema["properties"]?.objectValue, "properties must be present")
        let required = schema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // wing is the only required field (Rust parity).
        #expect(required.contains("wing"), "wing must be in required; got: \(required)")
        // estateID is present as an optional property (injected by withEstateID wrapper).
        #expect(properties["estateID"] != nil, "estateID must be an optional property")
        // estateID must not be required.
        #expect(!required.contains("estateID"), "estateID must not be required")
        // wing itself must be in properties.
        #expect(properties["wing"] != nil, "wing must be in properties")
    }
}
