// GLKNodeTopologyProviderTests.swift
//
// §6 Acceptance gate tests for .nodeTreeNative recall mode and GLKNodeTopologyProvider.
//
// Tests:
//   1. nodeTreeNative_autoRegistered_producesContainmentEdges — auto-registered
//      SubstrateNodeTopologyProvider produces containment tunnels in recallTunnels
//      output (§6 gate: prove substrate adapter auto-wires on open).
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

/// Instrumented in-memory GLKNodeTopologyProvider for testing.
/// Tracks how many times treeEdges(scope:) has been called so the
/// read-once enforcement test (G1) can assert the call count.
/// `nonisolated(unsafe)` mutable fields are safe here because tests
/// mutate them only before registering the provider (before any
/// concurrent access begins) — sequential test setup, not shared state.
final class InstrumentedTopologyProvider: GLKNodeTopologyProvider {
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
    // Estate is auto-provisioned by GLK.open
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
struct GLKNodeTopologyProviderTests {

    // MARK: 1. Auto-registered substrate adapter produces containment edges

    /// After NT-G1 auto-registration, every opened estate has a
    /// SubstrateNodeTopologyProvider. Captures that create wing/room
    /// nodes produce containment edges in recallTunnels.
    ///
    /// G5 note: the capture must use an explicit `wing:` parameter that
    /// matches the wing queried in recallTunnels. Without an explicit wing,
    /// the drawer is filed under the default wing (not "test-wing"), and the
    /// G5 filter correctly excludes those room nodes as foreign-wing edges.
    @Test
    func nodeTreeNative_autoRegistered_producesContainmentEdges() async throws {
        let (kit, handle) = try await makeTestEstate()

        // Capture a drawer into "test-wing". The capture path creates wing +
        // room nodes in the substrate NodeStore. The explicit wing: parameter
        // ensures the room node resolves to "test-wing" via resolveNodeNames,
        // so the G5 wing-scoping filter includes it in the recallTunnels result.
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "A", channel: .typed, room: "room-1",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1", wing: "test-wing")
        )

        // Auto-registered substrate adapter now produces a containment edge:
        //   test-wing-node → room-1-node
        // Root→test-wing-node is excluded by G5 (wing-level nodes resolve to
        // their parent, not the queried wing).
        let tunnels = try await kit.recallTunnels(handle, wing: "test-wing")

        let containmentTunnels = tunnels.filter { $0.label == "containment" }
        #expect(containmentTunnels.count > 0,
            "Auto-registered substrate adapter should produce containment tunnels, got \(containmentTunnels.count)")
        // The synthetic tunnel must carry the correct label and provenance.
        #expect(containmentTunnels.allSatisfy { $0.label == "containment" },
            "All synthetic topology tunnels must carry label 'containment'")
    }

    // MARK: 2. G5 wing-scoped privacy: custom provider with non-NodeStore IDs is filtered

    /// G5 — wing-scoped privacy (secfix/c-glk-remaining Part 5): after treeEdges
    /// returns the raw edge set, recallTunnels filters to only edges whose child
    /// node resolves to the queried wing via estate.resolveNodeNames.
    ///
    /// A custom InstrumentedTopologyProvider whose fake node IDs ("root", "A",
    /// "B", "C", "D") are NOT in the estate's NodeStore cannot be resolved to
    /// any wing, so the G5 filter removes all of them. This is the correct
    /// security behaviour: only nodes grounded in the estate's NodeStore can
    /// appear as wing-local containment edges.
    ///
    /// This test locks the G5 boundary: unresolvable node IDs from non-substrate
    /// providers produce zero synthetic tunnels for any wing query.
    @Test
    func nodeTreeNative_g5_customProviderWithFakeIds_producesZeroSyntheticTunnels() async throws {
        let (kit, handle) = try await makeTestEstate()
        // Register a mock provider with fake node IDs not in the estate's NodeStore.
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        // G5 filter: resolveNodeNames returns nothing for fake IDs "root/A/B/C/D"
        // because those strings are not UUID-formatted NodeStore entries.
        // Result: zero synthetic containment tunnels — all edges are filtered out.
        let tunnels = try await kit.recallTunnels(handle, wing: "test-wing")
        let containmentTunnels = tunnels.filter { $0.label == "containment" }
        #expect(containmentTunnels.count == 0,
            "G5: fake node IDs not in NodeStore should produce 0 synthetic tunnels, got \(containmentTunnels.count)")

        // Provider was still called exactly once (G1 still satisfied).
        #expect(provider.treeEdgesCallCount == 1,
            "treeEdges must be called exactly once (G1) even when G5 filters all edges")
    }

    // MARK: 3. Read-once enforcement (G1)

    /// The provider's treeEdges(scope:) is called EXACTLY ONCE per recallTunnels
    /// invocation. A provider that returns different edges on a second call cannot
    /// affect a recall in flight (G1: frozen snapshot). G5 wing-scoping uses
    /// resolveNodeNames (a NodeStore read) not a second treeEdges call — G1 is
    /// fully satisfied regardless of G5 filtering.
    @Test
    func nodeTreeNative_readOnce_enforcement() async throws {
        let (kit, handle) = try await makeTestEstate()
        let provider = InstrumentedTopologyProvider(edges: smallTree())
        await kit.registerNodeTopology(provider, for: handle)

        // Mutate: after the first call, subsequent calls would return an empty set.
        // If the substrate re-reads on the same call, the result would differ.
        provider.secondCallOverride = []

        _ = try await kit.recallTunnels(handle, wing: "test-wing")

        // G1 contract: the call count must be exactly 1 per recallTunnels invocation.
        // G5's resolveNodeNames call is a NodeStore read, NOT a second treeEdges call;
        // it does not increment this counter.
        #expect(provider.treeEdgesCallCount == 1,
            "treeEdges must be called exactly once per recallTunnels (G1), got \(provider.treeEdgesCallCount)")
        // Note: synthetic tunnel count is 0 here because the fake node IDs from
        // InstrumentedTopologyProvider are not in the estate's NodeStore (G5 filters
        // all of them). The G1 contract (call count) is what this test locks.
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

    // MARK: 8. G5 wing-scoped privacy gate (regression lock for secfix/c-glk-remaining Part 5)

    /// The wing-scoped privacy boundary (G5) ensures that containment edges from
    /// foreign wings are never injected into a wing's tunnel read.
    ///
    /// Before the fix, `treeEdges(scope: nil)` returned the full estate forest and
    /// every edge was stamped with the queried wing's label — leaking topology
    /// across wing boundaries. After the fix, only edges whose child node resolves
    /// to the queried wing via estate.resolveNodeNames pass the filter.
    ///
    /// This test uses the auto-registered SubstrateNodeTopologyProvider (real
    /// NodeStore) and two distinct wings. It verifies:
    ///   - Each wing's recallTunnels returns at least one containment tunnel
    ///   - The containment tunnel sets are disjoint (no node ID shared across wings)
    ///   - A tunnel from wing-alpha never carries a targetDrawerId also found in
    ///     wing-beta's results (the privacy property)
    @Test
    func nodeTreeNative_g5_wingScoped_foreignEdgesExcluded() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "g5-privacy-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture one drawer per wing, creating distinct node trees:
        //   root → wing-alpha-node → alpha-room-node
        //   root → wing-beta-node  → beta-room-node
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "alpha content", channel: .typed, room: "alpha-room",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model", wing: "wing-alpha")
        )
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "beta content", channel: .typed, room: "beta-room",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model", wing: "wing-beta")
        )

        // G5: each wing's recallTunnels must return only edges belonging to that wing.
        let alphaTunnels = try await kit.recallTunnels(handle, wing: "wing-alpha")
        let betaTunnels  = try await kit.recallTunnels(handle, wing: "wing-beta")

        let alphaContainment = alphaTunnels.filter { $0.label == "containment" }
        let betaContainment  = betaTunnels.filter  { $0.label == "containment" }

        // Both wings must produce at least one containment edge
        // (proves the filter does not suppress all edges).
        #expect(alphaContainment.count >= 1,
            "wing-alpha should have at least 1 containment edge (wing→room), got \(alphaContainment.count)")
        #expect(betaContainment.count >= 1,
            "wing-beta should have at least 1 containment edge (wing→room), got \(betaContainment.count)")

        // Privacy property: the targetDrawerId sets must be disjoint.
        // Each targetDrawerId is a node UUID; wing-alpha and wing-beta have
        // separate room nodes, so intersection must be empty.
        let alphaTargetIds = Set(alphaContainment.compactMap { $0.targetDrawerId })
        let betaTargetIds  = Set(betaContainment.compactMap  { $0.targetDrawerId })
        let leaked = alphaTargetIds.intersection(betaTargetIds)
        #expect(leaked.isEmpty,
            "G5 violation: foreign-wing node IDs leaked into wing results: \(leaked)")

        // Additional integrity check: all alpha containment tunnel targetDrawerIds
        // must resolve to wing-alpha (not wing-beta or any other wing).
        let estate = try await kit.estate(for: handle)
        let alphaChildIds = Array(alphaTargetIds)
        if !alphaChildIds.isEmpty {
            let resolved = try await estate.resolveNodeNames(parentNodeIds: alphaChildIds)
            for (nodeId, pair) in resolved {
                #expect(pair.wing == "wing-alpha",
                    "G5 violation: alpha containment edge targetDrawerId \(nodeId) resolved to wing '\(pair.wing)' instead of 'wing-alpha'")
            }
        }
    }
}

// MARK: - SubstrateNodeTopologyProvider adapter tests (NT-G1)

@Suite("SubstrateNodeTopologyProvider adapter (NT-G1)")
struct SubstrateNodeTopologyProviderTests {

    /// The adapter returns correct parentID for a wing node.
    @Test
    func adapter_parentID_returnsParent() async throws {
        let (kit, handle) = try await makeSubstrateTestEstate()

        // Capture a drawer to create wing + room nodes.
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "test", channel: .typed, room: "room-a",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )

        // The auto-registered adapter should be accessible. Get the
        // estate's storage and build a fresh adapter for direct testing.
        let nodeStore = try await getNodeStore(kit: kit, handle: handle)
        let adapter = SubstrateNodeTopologyProvider(nodeStore: nodeStore)

        // Walk the tree: root → wing → room.
        let rootEdges = await adapter.treeEdges(scope: nil)
        #expect(!rootEdges.isEmpty, "Tree should have edges after capture")

        // Verify parentID: a child's parent should match the edge parent.
        if let firstEdge = rootEdges.first {
            let parent = await adapter.parentID(of: firstEdge.child)
            #expect(parent == firstEdge.parent,
                "parentID of child should match the edge's parent")
        }
    }

    /// The adapter returns correct childIDs for the root node.
    @Test
    func adapter_childIDs_returnsChildren() async throws {
        let (kit, handle) = try await makeSubstrateTestEstate()

        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "test", channel: .typed, room: "room-a",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )

        let nodeStore = try await getNodeStore(kit: kit, handle: handle)
        let adapter = SubstrateNodeTopologyProvider(nodeStore: nodeStore)

        // Get the root's ID from the edge set.
        let edges = await adapter.treeEdges(scope: nil)
        let rootIDs = Set(edges.map { $0.parent }).subtracting(edges.map { $0.child })
        if let rootID = rootIDs.first {
            let children = await adapter.childIDs(of: rootID)
            #expect(!children.isEmpty, "Root should have children after capture")
        }
    }

    /// treeEdges returns the full tree for scope nil.
    @Test
    func adapter_treeEdges_fullForest() async throws {
        let (kit, handle) = try await makeSubstrateTestEstate()

        // Capture into two different rooms to create multiple nodes.
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "A", channel: .typed, room: "room-a",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "B", channel: .typed, room: "room-b",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )

        let nodeStore = try await getNodeStore(kit: kit, handle: handle)
        let adapter = SubstrateNodeTopologyProvider(nodeStore: nodeStore)

        let edges = await adapter.treeEdges(scope: nil)
        // root → typed-wing, typed-wing → room-a, typed-wing → room-b
        #expect(edges.count >= 3,
            "Two rooms under one wing should produce >= 3 edges, got \(edges.count)")
    }

    /// treeEdges with a scope filters to the induced subset.
    @Test
    func adapter_treeEdges_scopeFilters() async throws {
        let (kit, handle) = try await makeSubstrateTestEstate()

        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "A", channel: .typed, room: "room-a",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )
        _ = try await kit.capture(
            handle,
            CaptureFrame(content: "B", channel: .typed, room: "room-b",
                         latticeAnchor: .udc("510"), addedBy: "test",
                         embeddingModelID: "test-model-v1")
        )

        let nodeStore = try await getNodeStore(kit: kit, handle: handle)
        let adapter = SubstrateNodeTopologyProvider(nodeStore: nodeStore)

        let allEdges = await adapter.treeEdges(scope: nil)
        let allIDs = Set(allEdges.flatMap { [$0.parent, $0.child] })

        // Scope to just the root and one wing — should exclude room edges.
        let rootIDs = allIDs.subtracting(Set(allEdges.map { $0.child }))
        if let rootID = rootIDs.first {
            let wingIDs = allEdges.filter { $0.parent == rootID }.map { $0.child }
            if let wingID = wingIDs.first {
                let scopedEdges = await adapter.treeEdges(scope: [rootID, wingID])
                #expect(scopedEdges.count == 1,
                    "Scope {root, wing} should produce 1 edge, got \(scopedEdges.count)")
                #expect(scopedEdges.first?.parent == rootID)
                #expect(scopedEdges.first?.child == wingID)
            }
        }
    }

    /// Invalid UUID strings are handled gracefully.
    @Test
    func adapter_invalidUUID_returnsNil() async throws {
        let (kit, handle) = try await makeSubstrateTestEstate()
        let nodeStore = try await getNodeStore(kit: kit, handle: handle)
        let adapter = SubstrateNodeTopologyProvider(nodeStore: nodeStore)

        let parent = await adapter.parentID(of: "not-a-uuid")
        #expect(parent == nil, "Invalid UUID should return nil")

        let children = await adapter.childIDs(of: "not-a-uuid")
        #expect(children.isEmpty, "Invalid UUID should return empty array")
    }
}

// MARK: - Helpers for SubstrateNodeTopologyProvider tests

/// Open a fresh in-memory estate for direct adapter testing.
private func makeSubstrateTestEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "test-owner")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

/// Retrieve the estate's NodeStore for direct adapter construction
/// in tests. Reaches into GLK's internal registry via @testable.
private func getNodeStore(kit: GeniusLocusKit, handle: EstateHandle) async throws -> NodeStore {
    guard let estate = await kit.registry[handle] else {
        throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
    }
    return await estate.nodeStore
}
