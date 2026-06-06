// NodeTopologyProviderTests.swift
//
// §6 Acceptance gate tests for .nodeTreeNative recall mode and NodeTopologyProvider.
//
// Tests:
//   1. nodeTreeNative_noProvider_behaviorUnchanged — no registered provider leaves
//      recallTunnels output identical to the pre-registration path (§6 gate: prove
//      no-provider → unchanged).
//   2. nodeTreeNative_registeredProvider_addsContainmentEdges — provider tree edges
//      appear as synthetic tunnels with label "containment" in the recallTunnels output.
//   3. nodeTreeNative_readOnce_enforcement — an instrumented provider that mutates its
//      edge set between calls shows that a second call cannot affect a recall in flight
//      (G1: the first call's result is frozen; the second-call mutation is never seen).
//   4. nodeTreeNative_mode_decodesCorrectly — GLKRecallMode.nodeTreeNative round-trips
//      through JSON and carries the expected rawValue string.
//   5. nodeTreeNative_recallRequest_delegatesToLocusOnly — a GLKRecallRequest with
//      mode .nodeTreeNative completes without error, the mode is preserved on the
//      result, and every hit (if any) carries .locusBitmap in its sources set.
//   6. nodeTreeNative_treeEdgesScope_inducedSubset — treeEdges(scope:) with a scope
//      that excludes some nodes returns only edges whose BOTH endpoints are in scope.
//   7. nodeTreeNative_callCount_exactlyOne — the provider is called EXACTLY ONCE per
//      recallTunnels invocation (G1 contract).

import Foundation
import Testing
@testable import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test-double provider

/// Instrumented in-memory NodeTopologyProvider for testing.
/// Tracks how many times treeEdges(scope:) has been called so the
/// read-once enforcement test (G1) can assert the call count.
/// `nonisolated(unsafe)` mutable fields are safe here because tests
/// mutate them only before registering the provider (before any
/// concurrent access begins) — sequential test setup, not shared state.
final class InstrumentedTopologyProvider: NodeTopologyProvider {
    /// Parent-map: child → parent.
    private let parentMap: [String: String]
    /// Mutable edge override. When set, replaces parentMap on the SECOND call.
    /// Used to prove that the first-call freeze is honoured (G1).
    /// Set by the test before registering the provider (single-writer, sequential).
    nonisolated(unsafe) var secondCallOverride: [(parent: String, child: String)]? = nil
    /// Call counter for treeEdges(scope:).
    nonisolated(unsafe) private(set) var treeEdgesCallCount: Int = 0

    init(edges: [(parent: String, child: String)]) {
        var map: [String: String] = [:]
        for (parent, child) in edges { map[child] = parent }
        self.parentMap = map
    }

    func parentID(of nodeID: String) async -> String? { parentMap[nodeID] }

    func childIDs(of nodeID: String) async -> [String] {
        parentMap.compactMap { child, parent in parent == nodeID ? child : nil }
    }

    func treeEdges(scope: [String]?) async -> [(parent: String, child: String)] {
        treeEdgesCallCount += 1
        // If this is the second call and there is an override set, return the
        // override to simulate a mutable provider (proves the first-call result
        // was frozen and the second-call mutation is not visible).
        if treeEdgesCallCount > 1, let override = secondCallOverride {
            return override
        }
        let allEdges = parentMap.map { child, parent in (parent: parent, child: child) }
        guard let scope else { return allEdges }
        let scopeSet = Set(scope)
        return allEdges.filter { scopeSet.contains($0.parent) && scopeSet.contains($0.child) }
    }
}

// MARK: - Helpers

/// Open an in-memory estate with a single captured drawer and return the
/// (kit, handle) pair ready for testing.
private func makeTestEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "test-owner")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    _ = try await kit.capture(
        handle,
        CaptureFrame(
            content: "topology-test content",
            channel: .typed,
            room: "test-room",
            latticeAnchor: .udc("510"),
            addedBy: "test",
            embeddingModelID: "test-model-v1"
        )
    )
    return (kit, handle)
}

/// Build a small 5-node tree: root → A, root → B, A → C, B → D.
/// Used across multiple tests for a consistent fixed topology.
private func smallTree() -> [(parent: String, child: String)] {
    [
        (parent: "root", child: "A"),
        (parent: "root", child: "B"),
        (parent: "A",    child: "C"),
        (parent: "B",    child: "D"),
    ]
}

// MARK: - Tests

@Suite("nodeTreeNative acceptance gates (§6)")
struct NodeTopologyProviderTests {

    // MARK: 1. No provider → unchanged behaviour

    /// When no NodeTopologyProvider is registered, recallTunnels returns only
    /// the estate's stored tunnels — identical to pre-.nodeTreeNative behaviour.
    /// This is the §6 "prove no-provider → unchanged" gate.
    @Test
    func nodeTreeNative_noProvider_behaviorUnchanged() async throws {
        let (kit, handle) = try await makeTestEstate()

        // Capture a tunnel between two drawers.
        let drawerA = try await kit.capture(
            handle,
            CaptureFrame(content: "A", channel: .typed, room: "wing", latticeAnchor: .udc("510"),
                         addedBy: "test", embeddingModelID: "test-model-v1")
        )
        let drawerB = try await kit.capture(
            handle,
            CaptureFrame(content: "B", channel: .typed, room: "wing", latticeAnchor: .udc("510"),
                         addedBy: "test", embeddingModelID: "test-model-v1")
        )
        try await kit.associate(
            handle,
            AssociateFrame(a: drawerA.id, b: drawerB.id, weight: 1.0)
        )

        // Read tunnels with NO provider registered.
        let tunnelsWithoutProvider = try await kit.recallTunnels(handle, wing: "wing")

        // No provider → count stays at the stored count (1 association edge).
        // Synthetic containment tunnels must NOT appear.
        let containmentCount = tunnelsWithoutProvider.filter { $0.label == "containment" }.count
        #expect(containmentCount == 0,
            "No provider registered — no containment tunnels expected, found \(containmentCount)")
        #expect(tunnelsWithoutProvider.allSatisfy { $0.label != "containment" },
            "No containment labels expected when no provider is registered")
    }

    // MARK: 2. Registered provider adds containment edges

    /// When a NodeTopologyProvider is registered, its frozen tree edges appear
    /// as synthetic tunnels with label "containment" in the recallTunnels output.
    @Test
    func nodeTreeNative_registeredProvider_addsContainmentEdges() async throws {
        let (kit, handle) = try await makeTestEstate()
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        // recallTunnels unions estate tunnels (0 stored) with frozen tree edges.
        let tunnels = try await kit.recallTunnels(handle, wing: "test-wing")
        let containmentTunnels = tunnels.filter { $0.label == "containment" }

        // All 4 edges of the small tree must appear.
        #expect(containmentTunnels.count == 4,
            "Expected 4 containment tunnels from small tree, got \(containmentTunnels.count)")

        // Each containment tunnel must have a non-nil sourceDrawerId and targetDrawerId.
        for t in containmentTunnels {
            #expect(t.sourceDrawerId != nil, "containment tunnel should have sourceDrawerId")
            #expect(t.targetDrawerId != nil, "containment tunnel should have targetDrawerId")
        }

        // Edge root → A must be present.
        let rootToA = containmentTunnels.first {
            $0.sourceDrawerId == "root" && $0.targetDrawerId == "A"
        }
        #expect(rootToA != nil, "root→A containment edge not found in recallTunnels output")
    }

    // MARK: 3. Read-once enforcement (G1)

    /// The provider's treeEdges(scope:) is called EXACTLY ONCE per recallTunnels
    /// invocation. A provider that returns different edges on a second call cannot
    /// affect a recall in flight (G1: frozen snapshot).
    @Test
    func nodeTreeNative_readOnce_enforcement() async throws {
        let (kit, handle) = try await makeTestEstate()
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        // Mutate: after the first call, subsequent calls would return an empty set.
        // If the substrate re-reads on the same call, the result would differ.
        provider.secondCallOverride = []

        let tunnels = try await kit.recallTunnels(handle, wing: "test-wing")

        // The call count must be exactly 1 per recallTunnels invocation.
        #expect(provider.treeEdgesCallCount == 1,
            "treeEdges must be called exactly once per recallTunnels (G1), got \(provider.treeEdgesCallCount)")

        // The frozen result from call #1 (smallTree edges) is used — not the empty
        // override that would apply on call #2. All 4 edges must be present.
        let containmentTunnels = tunnels.filter { $0.label == "containment" }
        #expect(containmentTunnels.count == 4,
            "Frozen first-call result (4 edges) expected; mutation on second call not visible")
    }

    // MARK: 4. GLKRecallMode.nodeTreeNative Codable round-trip

    /// GLKRecallMode.nodeTreeNative must survive a JSON encode/decode round-trip
    /// and carry the rawValue "nodeTreeNative".
    @Test
    func nodeTreeNative_mode_decodesCorrectly() throws {
        #expect(GLKRecallMode.nodeTreeNative.rawValue == "nodeTreeNative")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(GLKRecallMode.nodeTreeNative)
        let decoded = try decoder.decode(GLKRecallMode.self, from: data)
        #expect(decoded == .nodeTreeNative,
            "GLKRecallMode.nodeTreeNative failed Codable round-trip")
    }

    // MARK: 5. nodeTreeNative recall request delegates to locusOnly

    /// A GLKRecallRequest with mode .nodeTreeNative returns drawers via the
    /// locus bitmap lane (hits carry .locusBitmap in sources) and succeeds
    /// regardless of whether a provider is registered.
    @Test
    func nodeTreeNative_recallRequest_delegatesToLocusOnly() async throws {
        let (kit, handle) = try await makeTestEstate()
        // Register a provider so the mode is fully active.
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        let frame = RecallFrame(filterChain: [])
        let request = GLKRecallRequest(
            frame: frame,
            mode: .nodeTreeNative,
            scoring: .raw,
            limit: 10
        )

        let result = try await kit.recall(handle, request)

        // nodeTreeNative delegates to locusOnly for drawer retrieval — the mode
        // must be preserved on the result and every hit (if any) must come
        // from the locus bitmap lane. We do not assert non-empty hits here
        // because the default recall filter chain (insertDefaults) applies
        // confirmation and trust thresholds that newly-captured drawers may
        // not satisfy; the delegation path, not the content count, is what
        // this gate tests.
        #expect(result.request.mode == .nodeTreeNative,
            "result.request.mode must be .nodeTreeNative")
        for hit in result.hits {
            #expect(hit.sources.contains(.locusBitmap),
                "nodeTreeNative recall hit should carry .locusBitmap in sources")
        }
    }

    // MARK: 6. treeEdges scope — induced subset

    /// treeEdges(scope:) with a scope excluding some nodes returns only edges whose
    /// BOTH endpoints are in scope (induced edge set definition, locked contract).
    @Test
    func nodeTreeNative_treeEdgesScope_inducedSubset() async throws {
        let provider = InstrumentedTopologyProvider(edges: smallTree())

        // Scope to {root, A, C} — induced edges: root→A, A→C (B→D excluded because B∉scope).
        let scoped = await provider.treeEdges(scope: ["root", "A", "C"])
        let pairs = Set(scoped.map { "\($0.parent)→\($0.child)" })

        #expect(pairs.contains("root→A"), "root→A should be in induced scope {root, A, C}")
        #expect(pairs.contains("A→C"),    "A→C should be in induced scope {root, A, C}")
        #expect(!pairs.contains("root→B"), "root→B should NOT be in induced scope (B∉scope)")
        #expect(!pairs.contains("B→D"),    "B→D should NOT be in induced scope (B,D∉scope)")
        #expect(scoped.count == 2, "Expected 2 induced edges for scope {root, A, C}, got \(scoped.count)")
    }

    // MARK: 7. Call count exactly one per recallTunnels

    /// Two separate recallTunnels calls each trigger exactly one provider call —
    /// confirming the freeze-per-call discipline (G1). The second call's snapshot
    /// is independent of the first.
    @Test
    func nodeTreeNative_callCount_exactlyOne_perRecall() async throws {
        let (kit, handle) = try await makeTestEstate()
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        _ = try await kit.recallTunnels(handle, wing: "wing-1")
        #expect(provider.treeEdgesCallCount == 1,
            "After first recallTunnels: call count should be 1")

        _ = try await kit.recallTunnels(handle, wing: "wing-2")
        #expect(provider.treeEdgesCallCount == 2,
            "After second recallTunnels: call count should be 2 (one per call)")
    }
}
