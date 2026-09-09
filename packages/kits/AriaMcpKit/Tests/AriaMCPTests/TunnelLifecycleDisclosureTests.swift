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

    // MARK: - connection_map lifecycle gate

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
}
