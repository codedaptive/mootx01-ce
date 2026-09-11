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
    //
    // v2 reshape: `moot_connection_search` no longer takes `from_id`/`to_id`
    // string args; it takes `memory_id` (UUID, required) plus `direction`
    // (outgoing|incoming|both, default both) and routes through
    // `AriaV2KnowledgeJournalService.connectionSearch`
    // (Sources/AriaMCP/AriaV2KnowledgeJournal.swift:473-477), which still calls
    // `estate.activeTunnelsFrom(drawerId:)` / `activeTunnelsTo(drawerId:)` —
    // the same LocusKit-level lifecycle/retirement bitmap filter v1 exercised
    // (see doc comment above `runConnectionSearch`, ToolDispatch.swift:3079-3095,
    // now dead code but describing the same storage-layer predicate the v2
    // backend still uses). Response text is reshaped from "found N outgoing
    // connections" to "Found N authorized connections." — the exact new
    // string is pinned below.
    //
    // Endpoint IDs must be REAL, admissible drawers in v2, not bare UUID
    // strings: `AriaV2GeniusLocusKnowledgeJournalBackend.visibleTunnels`
    // resolves every non-nil sourceDrawerId/targetDrawerId against
    // `estate.getDrawers(ids:...)` and drops the tunnel entirely if either
    // endpoint does not resolve to a drawer at or below the sensitivity
    // ceiling (AriaV2KnowledgeJournal.swift:399-413). A tunnel whose
    // endpoints are unminted UUIDs is excluded for that reason ALONE,
    // regardless of lifecycle — which would make every "excludes" assertion
    // below pass vacuously (0 results because nothing is visible, not
    // because lifecycle filtering worked) and prove nothing. Both endpoints
    // are captured as real drawers via `captureDrawer` so the exclusion
    // assertion actually exercises the lifecycle predicate in
    // activeTunnelsFrom/activeTunnelsTo, not endpoint invisibility.

    @Test("connection_search excludes proposed tunnels (FIND4, v2 memory_id/direction shape)")
    func connectionSearchExcludesProposed() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cs-excl-proposed-src", room: "find4/cs", in: harness)
        let tgt = try await captureDrawer(content: "cs-excl-proposed-tgt", room: "find4/cs", in: harness)
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt.id, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["memory_id": .string(src.id), "direction": .string("outgoing")]
        )
        #expect(
            text == "Found 0 authorized connections.",
            "proposed tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search excludes withdrawn tunnels (FIND4, v2 memory_id/direction shape)")
    func connectionSearchExcludesWithdrawn() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cs-excl-withdrawn-src", room: "find4/cs", in: harness)
        let tgt = try await captureDrawer(content: "cs-excl-withdrawn-tgt", room: "find4/cs", in: harness)
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt.id, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["memory_id": .string(src.id), "direction": .string("outgoing")]
        )
        #expect(
            text == "Found 0 authorized connections.",
            "withdrawn tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search excludes superseded tunnels (FIND4, v2 memory_id/direction shape)")
    func connectionSearchExcludesSuperseded() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cs-excl-superseded-src", room: "find4/cs", in: harness)
        let tgt = try await captureDrawer(content: "cs-excl-superseded-tgt", room: "find4/cs", in: harness)
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt.id, lifecycle: .superseded)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["memory_id": .string(src.id), "direction": .string("outgoing")]
        )
        #expect(
            text == "Found 0 authorized connections.",
            "superseded tunnel must not appear in connection_search; got: \(text)"
        )
    }

    @Test("connection_search returns active tunnels and excludes proposed on the same source (FIND4, v2 memory_id/direction shape)")
    func connectionSearchReturnsActiveExcludesProposedSameSource() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cs-mixed-src", room: "find4/cs", in: harness)
        let tgt1 = try await captureDrawer(content: "cs-mixed-tgt-active", room: "find4/cs", in: harness)
        let tgt2 = try await captureDrawer(content: "cs-mixed-tgt-proposed", room: "find4/cs", in: harness)

        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt1.id, lifecycle: .active)
        )
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt2.id, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_search",
            args: ["memory_id": .string(src.id), "direction": .string("outgoing")]
        )
        #expect(
            text == "Found 1 authorized connections.",
            "exactly one active tunnel must appear; proposed must be excluded; got: \(text)"
        )
    }


    // MARK: - connection_map lifecycle gate
    //
    // v2 reshape: `moot_connection_map` is no longer "find who points at
    // to_id" — it takes `memory_id` (UUID, required) plus `depth`/`limit` and
    // does a bounded bidirectional graph traversal from `memory_id`
    // (`AriaV2GeniusLocusKnowledgeJournalBackend.connectionMap`,
    // AriaV2KnowledgeJournal.swift:283-304). With the default depth (1), the
    // first (and only, at depth 1) BFS iteration collects
    // `activeTunnelsFrom(memory_id)` and `activeTunnelsTo(memory_id)` — same
    // lifecycle-filtered storage query as before — so calling connection_map
    // with `memory_id` set to the tunnel's TARGET endpoint reproduces the v1
    // "who points at this drawer, excluding non-active lifecycles" check.
    // Response text reshapes from "found N incoming connections" to
    // "Mapped N authorized connections." Endpoints are captured as real
    // drawers for the same reason as the connection_search block above:
    // `visibleTunnels` drops any tunnel whose endpoints do not resolve to
    // an admissible drawer, independent of lifecycle.

    @Test("connection_map excludes proposed tunnels (FIND4, v2 memory_id/depth shape)")
    func connectionMapExcludesProposed() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cm-excl-proposed-src", room: "find4/cm", in: harness)
        let tgt = try await captureDrawer(content: "cm-excl-proposed-tgt", room: "find4/cm", in: harness)
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt.id, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["memory_id": .string(tgt.id)]
        )
        #expect(
            text == "Mapped 0 authorized connections.",
            "proposed tunnel must not appear in connection_map; got: \(text)"
        )
    }

    @Test("connection_map excludes withdrawn tunnels (FIND4, v2 memory_id/depth shape)")
    func connectionMapExcludesWithdrawn() async throws {
        let harness = try await makeHarness()
        let src = try await captureDrawer(content: "cm-excl-withdrawn-src", room: "find4/cm", in: harness)
        let tgt = try await captureDrawer(content: "cm-excl-withdrawn-tgt", room: "find4/cm", in: harness)
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src.id, targetDrawerId: tgt.id, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["memory_id": .string(tgt.id)]
        )
        #expect(
            text == "Mapped 0 authorized connections.",
            "withdrawn tunnel must not appear in connection_map; got: \(text)"
        )
    }

    @Test("connection_map returns active tunnels and excludes proposed on the same target (FIND4, v2 memory_id/depth shape)")
    func connectionMapReturnsActiveExcludesProposedSameTarget() async throws {
        let harness = try await makeHarness()
        let tgt = try await captureDrawer(content: "cm-mixed-tgt", room: "find4/cm", in: harness)
        let src1 = try await captureDrawer(content: "cm-mixed-src-active", room: "find4/cm", in: harness)
        let src2 = try await captureDrawer(content: "cm-mixed-src-proposed", room: "find4/cm", in: harness)

        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src1.id, targetDrawerId: tgt.id, lifecycle: .active)
        )
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: src2.id, targetDrawerId: tgt.id, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_connection_map",
            args: ["memory_id": .string(tgt.id)]
        )
        #expect(
            text == "Mapped 1 authorized connections.",
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

    // MARK: - memory_get tunnel-lifecycle gate — BLOCKED (v2 dropped the field)
    //
    // v1's `moot_memory_get` full-record path filtered linked tunnels by
    // lifecycle == .active before rendering a "tunnels: N" summary line
    // (still present, unchanged, at ToolDispatch.swift:2568-2579 and
    // ToolDispatch.swift:2630-2641 — `runMemoryGet`'s `FullRecordData.tunnels`
    // field). But `moot_memory_get` in the v2 production dispatch path does
    // NOT reach `runMemoryGet` at all: `ToolDispatcher.dispatch(name:arguments:)`
    // (ToolDispatch.swift:599-600) decodes every call through
    // `AriaSurfaceDecoder.decode` + `dispatchV2`, and the `.memoryGet` case
    // (ToolDispatch.swift:782-783) routes to `memoryOperations.get(getRequest)`
    // → `AriaV2MemoryOperations.get` → `AriaV2GeniusLocusMemoryBackend.get`
    // (AriaV2MemoryOperations.swift:590-605), which builds an
    // `AriaV2MemoryRecord` via `record(for:authorized:)`
    // (AriaV2MemoryOperations.swift:613-626). `AriaV2MemoryRecord`
    // (AriaV2MemoryOperations.swift:305-321) has no `tunnels` field and
    // `record(for:)` never queries `estate.allTunnels()` — the v2 response has
    // no tunnel-count line in any form, so there is nothing to assert
    // inclusion or exclusion against. `runMemoryGet` (ToolDispatch.swift:2402)
    // is unreachable from `dispatch(name:arguments:)`: `InterfaceTools.dispatch`,
    // the only caller of `runMemoryGet`, has zero call sites anywhere in
    // Sources/ (confirmed by repo-wide grep) — it is dead code, not an
    // alternate live path, and the brief's mandated dispatcher
    // (`ToolDispatcher.dispatch(name:arguments:)`) never reaches it.
    // Pinned v1 assertion ("tunnels: 0") cannot pass against v2 behavior.
    // Awaiting catalog decision on whether memory_get's v2 record should
    // regain a tunnel summary. Do not delete; do not weaken to pass.

    @Test(.disabled("BLOCKED: v2 moot_memory_get (AriaV2MemoryOperations.swift:590-605, AriaV2MemoryOperations.swift:305-321) builds an AriaV2MemoryRecord with no tunnels field at all — record(for:) never queries estate.allTunnels() (AriaV2MemoryOperations.swift:613-626). The v1 lifecycle-filtered 'tunnels: N' summary line only exists on the dead runMemoryGet path (ToolDispatch.swift:2402), unreachable from ToolDispatcher.dispatch(name:arguments:). Pinned assertion 'tunnels: 0' cannot pass against v2 behavior. Do not delete; do not weaken to pass."))
    func memoryGetExcludesProposedTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = UUID().uuidString
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .proposed)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["memory_id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "proposed tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }

    @Test(.disabled("BLOCKED: v2 moot_memory_get (AriaV2MemoryOperations.swift:590-605, AriaV2MemoryOperations.swift:305-321) builds an AriaV2MemoryRecord with no tunnels field at all — record(for:) never queries estate.allTunnels() (AriaV2MemoryOperations.swift:613-626). The v1 lifecycle-filtered 'tunnels: N' summary line only exists on the dead runMemoryGet path (ToolDispatch.swift:2402), unreachable from ToolDispatcher.dispatch(name:arguments:). Pinned assertion 'tunnels: 0' cannot pass against v2 behavior. Do not delete; do not weaken to pass."))
    func memoryGetExcludesWithdrawnTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = UUID().uuidString
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .withdrawn)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["memory_id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "withdrawn tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }

    @Test(.disabled("BLOCKED: v2 moot_memory_get (AriaV2MemoryOperations.swift:590-605, AriaV2MemoryOperations.swift:305-321) builds an AriaV2MemoryRecord with no tunnels field at all — record(for:) never queries estate.allTunnels() (AriaV2MemoryOperations.swift:613-626). The v1 lifecycle-filtered 'tunnels: N' summary line only exists on the dead runMemoryGet path (ToolDispatch.swift:2402), unreachable from ToolDispatcher.dispatch(name:arguments:). Pinned assertion 'tunnels: 0' cannot pass against v2 behavior. Do not delete; do not weaken to pass."))
    func memoryGetExcludesSupersededTunnels() async throws {
        let harness = try await makeHarness()
        let drawer = try await captureDrawer(in: harness)
        let otherID = UUID().uuidString
        try await harness.estate.addTunnel(
            tunnelWith(sourceDrawerId: drawer.id, targetDrawerId: otherID, lifecycle: .superseded)
        )

        let text = await dispatchAndExtractText(
            dispatcher: harness.dispatcher,
            toolName: "moot_memory_get",
            args: ["memory_id": .string(drawer.id)]
        )
        #expect(
            text.contains("tunnels: 0"),
            "superseded tunnel must not appear in memory_get tunnel summary; got: \(text)"
        )
    }
}
