import Testing
import Foundation
import GeniusLocusKit
@testable import LocusKit        // @testable: accesses internal Estate.addTunnel (advisory fix)
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// MCP disclosure boundary enforcement for tunnel lifecycle states (FIND4).
///
/// Verifies that `moot_connection_search` and `moot_connection_map` exclude
/// proposed, withdrawn, and superseded tunnels — only confirmed-active
/// (lifecycle == .active) tunnels are surfaced to AI clients.
///
/// Test strategy: create a LocusKit.Estate backed by InMemoryStorage, insert
/// tunnels with non-active lifecycle states directly into the store, then drive
/// the ARIA MCP dispatcher and assert they do NOT appear in results.
///
/// `.serialized`: each test opens live in-memory estates; preserves one-at-a-time
/// execution to prevent GeniusLocusKit actor contention.
@Suite("Tunnel lifecycle disclosure enforcement (FIND4)", .serialized)
struct TunnelLifecycleDisclosureTests {

    // MARK: - Harness

    /// Paired dispatcher + estate so tests can insert tunnels directly.
    private struct TestHarness {
        let dispatcher: ARIA_MCPDispatcher
        /// The underlying LocusKit estate — used for direct tunnel insertion
        /// via `estate.addTunnel` (internal, reached via @testable import LocusKit).
        /// Shares InMemoryStorage with the GeniusLocusKit instance, so mutations
        /// are immediately visible.
        let estate: LocusKit.Estate
        /// The GeniusLocusKit instance — used by memory_get lifecycle tests to
        /// capture real drawers (via `kit.capture`) before inserting lifecycle
        /// tunnels and asserting they are hidden from MCP responses.
        let kit: GeniusLocusKit
        /// The estate handle — required parameter for `kit.capture`.
        let handle: EstateHandle
    }

    private func makeHarness() async throws -> TestHarness {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "find4-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        let estate = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return TestHarness(
            dispatcher: ARIA_MCPDispatcher(info: info, tooling: tooling),
            estate: estate,
            kit: kit,
            handle: handle
        )
    }

    /// Build a Tunnel with a given lifecycle state.
    ///
    /// Sets `operationalBitmap` to encode `lifecycle` in bits 3–5.
    /// `adjectiveSensitivity` defaults to Normal (bulk-exportable).
    private func tunnelWith(
        id: String = UUID().uuidString,
        sourceDrawerId: String,
        targetDrawerId: String,
        lifecycle: TunnelLifecycle
    ) -> Tunnel {
        let lifecycleBits: Int64 = Int64(lifecycle.rawValue) << 3
        return Tunnel(
            id: id,
            sourceWing: "src", sourceRoom: "r1",
            sourceDrawerId: sourceDrawerId,
            targetWing: "tgt", targetRoom: "r2",
            targetDrawerId: targetDrawerId,
            label: "lc-edge",
            kind: .references,
            adjectiveBitmap: 0,          // Normal sensitivity — bulk-exportable
            operationalBitmap: lifecycleBits,
            provenanceBitmap: 0,
            addedBy: "test",
            filedAt: Date(timeIntervalSinceReferenceDate: 0),
            tombstonedAt: nil,
            removedByBatch: nil,
            orderKey: nil
        )
    }

    /// Dispatch a tool call and return the text content from the first result item.
    private func dispatchAndExtractText(
        dispatcher: ARIA_MCPDispatcher,
        toolName: String,
        args: [String: JSONValue]
    ) async -> String {
        let request = JSONRPCRequest(
            id: .integer(0),
            method: "tools/call",
            params: .object([
                "name": .string(toolName),
                "arguments": .object(args),
            ])
        )
        let rawResponse = await dispatcher.handle(request)
        guard let response = rawResponse,
              case .result(let result) = response.payload,
              let obj = result.objectValue,
              let text = obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue else {
            return ""
        }
        return text
    }

    // MARK: - connection_search lifecycle gate

    @Test("connection_search excludes proposed tunnels (FIND4)")
    func connectionSearchExcludesProposed() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-src-proposed-\(UUID().uuidString)"
        let tgtID = "find4-tgt-proposed-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgtID, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["from_id": .string(srcID)]
        )
        #expect(
            text.contains(": 0"),
            "proposed tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search excludes withdrawn tunnels (FIND4)")
    func connectionSearchExcludesWithdrawn() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-src-withdrawn-\(UUID().uuidString)"
        let tgtID = "find4-tgt-withdrawn-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgtID, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["from_id": .string(srcID)]
        )
        #expect(
            text.contains(": 0"),
            "withdrawn tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search excludes superseded tunnels (FIND4)")
    func connectionSearchExcludesSuperseded() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-src-superseded-\(UUID().uuidString)"
        let tgtID = "find4-tgt-superseded-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgtID, lifecycle: .superseded)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["from_id": .string(srcID)]
        )
        #expect(
            text.contains(": 0"),
            "superseded tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search returns active tunnels and excludes proposed on the same source (FIND4)")
    func connectionSearchReturnsActiveExcludesProposedSameSource() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-src-mixed-\(UUID().uuidString)"
        let tgt1 = "find4-tgt-mixed-active-\(UUID().uuidString)"
        let tgt2 = "find4-tgt-mixed-proposed-\(UUID().uuidString)"

        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgt1, lifecycle: .active)
        )
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgt2, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["from_id": .string(srcID)]
        )
        #expect(
            text.contains(": 1"),
            "exactly one active tunnel must appear; proposed must be excluded; got: \(text)"
        )
    }

    // MARK: - connection_map lifecycle gate

    @Test("connection_map excludes proposed tunnels (FIND4)")
    func connectionMapExcludesProposed() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-map-src-proposed-\(UUID().uuidString)"
        let tgtID = "find4-map-tgt-proposed-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgtID, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["to_id": .string(tgtID)]
        )
        #expect(
            text.contains(": 0"),
            "proposed tunnel must not appear in connection_map; got: \(text)"
        )
    }

    @Test("connection_map excludes withdrawn tunnels (FIND4)")
    func connectionMapExcludesWithdrawn() async throws {
        let harness = try await makeHarness()
        let srcID = "find4-map-src-withdrawn-\(UUID().uuidString)"
        let tgtID = "find4-map-tgt-withdrawn-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: srcID, targetDrawerId: tgtID, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["to_id": .string(tgtID)]
        )
        #expect(
            text.contains(": 0"),
            "withdrawn tunnel must not appear in connection_map; got: \(text)"
        )
    }

    @Test("connection_map returns active tunnels and excludes proposed on the same target (FIND4)")
    func connectionMapReturnsActiveExcludesProposedSameTarget() async throws {
        let harness = try await makeHarness()
        let tgtID = "find4-map-tgt-mixed-\(UUID().uuidString)"
        let src1 = "find4-map-src-mixed-active-\(UUID().uuidString)"
        let src2 = "find4-map-src-mixed-proposed-\(UUID().uuidString)"

        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src1, targetDrawerId: tgtID, lifecycle: .active)
        )
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src2, targetDrawerId: tgtID, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["to_id": .string(tgtID)]
        )
        #expect(
            text.contains(": 1"),
            "exactly one active tunnel must appear; proposed must be excluded; got: \(text)"
        )
    }

    // MARK: - memory_get lifecycle gate (FIND4 residual)

    /// Capture a drawer in the harness estate and return it.
    private func captureDrawer(
        content: String = "find4-memory-get-test",
        room: String = "find4/mg",
        in harness: TestHarness
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "find4-mg-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await harness.kit.capture(harness.handle, frame)
    }

    @Test("memory_get excludes proposed tunnels from linked-tunnel summary (FIND4 residual)")
    func memoryGetExcludesProposedTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = "find4-mg-proposed-other-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "proposed tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }

    @Test("memory_get excludes withdrawn tunnels from linked-tunnel summary (FIND4 residual)")
    func memoryGetExcludesWithdrawnTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = "find4-mg-withdrawn-other-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "withdrawn tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }

    @Test("memory_get excludes superseded tunnels from linked-tunnel summary (FIND4 residual)")
    func memoryGetExcludesSupersededTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = "find4-mg-superseded-other-\(UUID().uuidString)"
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .superseded)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "superseded tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }
}
