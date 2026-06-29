import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

/// Five-level ancestor chain proof: flat drawers wired into a deep
/// outline via `.parent` tunnels, demonstrating that the containment
/// tree (parent_node_id) and the outline graph (typed parent edges)
/// are fully orthogonal.  ADR-017 §11 / NT-L5 Part 3.
@Suite("OutlineProofTests — five-level ancestor chain on flat drawers")
struct OutlineProofTests {

    // MARK: - Helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeStore() async throws -> DrawerStore {
        let name = "locuskit-outline-test-\(UUID().uuidString).sqlite"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        return try await DrawerStore(storage: TestStorage.sqlite(url))
    }

    /// Create a drawer with deterministic content.
    private func sampleDrawer(
        id: String,
        filedAt: Date? = nil
    ) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "content-\(id)",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    /// Add a `.parent` tunnel: child→parent with the given order key.
    /// Convention: sourceDrawerId = child, targetDrawerId = parent.
    private func addParentEdge(
        store: DrawerStore,
        child: String,
        parent: String,
        orderKey: Double,
        now: Date
    ) async throws {
        let tunnel = Tunnel(
            id: UUID().uuidString,
            sourceWing: "w", sourceRoom: "r",
            sourceDrawerId: TestStorage.tid(child),
            targetWing: "w", targetRoom: "r",
            targetDrawerId: TestStorage.tid(parent),
            label: "parent",
            kind: .parent,
            addedBy: "bilby",
            filedAt: now,
            orderKey: orderKey
        )
        try await store.addTunnel(tunnel)
    }

    // MARK: - Five-level chain

    /// Build a five-level outline:  A ← B ← C ← D ← E
    /// (A is root, E is deepest leaf). All five drawers live in the
    /// same wing/room — demonstrating containment-tree independence.
    /// Walk ancestors from E and verify [A, B, C, D] root-first.
    @Test("five-level ancestor chain returns root-first path")
    func fiveLevelAncestorChain() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)

        // Create five flat drawers — all in the same room.
        for id in ["a", "b", "c", "d", "e"] {
            try await store.addDrawer(sampleDrawer(id: id, filedAt: now), now: now)
        }

        // Wire parent edges: B→A, C→B, D→C, E→D
        try await addParentEdge(store: store, child: "b", parent: "a", orderKey: 1.0, now: now)
        try await addParentEdge(store: store, child: "c", parent: "b", orderKey: 1.0, now: now)
        try await addParentEdge(store: store, child: "d", parent: "c", orderKey: 1.0, now: now)
        try await addParentEdge(store: store, child: "e", parent: "d", orderKey: 1.0, now: now)

        // Walk ancestors of E — expect [A, B, C, D] root-first.
        let ancestors = try await store.outlineAncestors(of: TestStorage.tid("e"))
        #expect(ancestors.count == 4)
        #expect(ancestors[0] == TestStorage.tid("a"))
        #expect(ancestors[1] == TestStorage.tid("b"))
        #expect(ancestors[2] == TestStorage.tid("c"))
        #expect(ancestors[3] == TestStorage.tid("d"))
    }

    /// Root node has no ancestors — outlineAncestors returns empty.
    @Test("root drawer has empty ancestor chain")
    func rootHasNoAncestors() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)
        try await store.addDrawer(sampleDrawer(id: "root", filedAt: now), now: now)

        let ancestors = try await store.outlineAncestors(of: TestStorage.tid("root"))
        #expect(ancestors.isEmpty)
    }

    // MARK: - Children ordering

    /// Three children under one parent, each with a distinct order key.
    /// outlineChildren returns them sorted by order_key ascending.
    @Test("outlineChildren returns sorted by order_key ascending")
    func childrenSortedByOrderKey() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)

        for id in ["p", "x", "y", "z"] {
            try await store.addDrawer(sampleDrawer(id: id, filedAt: now), now: now)
        }

        // Wire: x→p (order 3.0), y→p (order 1.0), z→p (order 2.0)
        try await addParentEdge(store: store, child: "x", parent: "p", orderKey: 3.0, now: now)
        try await addParentEdge(store: store, child: "y", parent: "p", orderKey: 1.0, now: now)
        try await addParentEdge(store: store, child: "z", parent: "p", orderKey: 2.0, now: now)

        let children = try await store.outlineChildren(of: TestStorage.tid("p"))
        #expect(children.count == 3)
        // Sorted: y(1.0), z(2.0), x(3.0)
        #expect(children[0].sourceDrawerId == TestStorage.tid("y"))
        #expect(children[1].sourceDrawerId == TestStorage.tid("z"))
        #expect(children[2].sourceDrawerId == TestStorage.tid("x"))
    }

    /// A drawer with no children returns an empty list.
    @Test("leaf drawer has no outline children")
    func leafHasNoChildren() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)
        try await store.addDrawer(sampleDrawer(id: "leaf", filedAt: now), now: now)

        let children = try await store.outlineChildren(of: TestStorage.tid("leaf"))
        #expect(children.isEmpty)
    }

    // MARK: - Reparent

    /// Reparent a child from one parent to another. The old ancestor
    /// chain changes, the new one is correct.
    @Test("reparentDrawer moves child to new parent")
    func reparentMovesChild() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)
        let later = t(1_700_000_100)

        for id in ["a", "b", "c"] {
            try await store.addDrawer(sampleDrawer(id: id, filedAt: now), now: now)
        }

        // Initial: B→A, C→B
        try await addParentEdge(store: store, child: "b", parent: "a", orderKey: 1.0, now: now)
        try await addParentEdge(store: store, child: "c", parent: "b", orderKey: 1.0, now: now)

        // Ancestors of C: [A, B]
        let before = try await store.outlineAncestors(of: TestStorage.tid("c"))
        #expect(before == [TestStorage.tid("a"), TestStorage.tid("b")])

        // Reparent C under A directly.
        try await store.reparentDrawer(
            TestStorage.tid("c"),
            newParentId: TestStorage.tid("a"),
            orderKey: 2.0,
            wing: "w", room: "r",
            addedBy: "bilby",
            now: later
        )

        // Ancestors of C should now be just [A].
        let after = try await store.outlineAncestors(of: TestStorage.tid("c"))
        #expect(after == [TestStorage.tid("a")])

        // A's children should include both B and C.
        let aChildren = try await store.outlineChildren(of: TestStorage.tid("a"))
        let childIds = aChildren.map(\.sourceDrawerId)
        #expect(childIds.contains(TestStorage.tid("b")))
        #expect(childIds.contains(TestStorage.tid("c")))
    }

    /// Reparent to nil (make a root) — ancestor chain becomes empty.
    @Test("reparentDrawer with nil makes child an outline root")
    func reparentToRoot() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)
        let later = t(1_700_000_100)

        for id in ["a", "b"] {
            try await store.addDrawer(sampleDrawer(id: id, filedAt: now), now: now)
        }

        try await addParentEdge(store: store, child: "b", parent: "a", orderKey: 1.0, now: now)
        #expect(try await store.outlineAncestors(of: TestStorage.tid("b")) == [TestStorage.tid("a")])

        try await store.reparentDrawer(
            TestStorage.tid("b"),
            newParentId: nil,
            orderKey: 0.0,
            wing: "w", room: "r",
            addedBy: "bilby",
            now: later
        )

        #expect(try await store.outlineAncestors(of: TestStorage.tid("b")).isEmpty)
    }

    // MARK: - One-parent-per-child enforcement

    /// Adding a second parent edge for the same child should fail
    /// with invalidContent.
    @Test("one-parent-per-child enforced on addTunnel")
    func oneParentPerChild() async throws {
        let store = try await makeStore()
        let now = t(1_700_000_000)

        for id in ["a", "b", "c"] {
            try await store.addDrawer(sampleDrawer(id: id, filedAt: now), now: now)
        }

        try await addParentEdge(store: store, child: "c", parent: "a", orderKey: 1.0, now: now)

        // Second parent edge for C should throw.
        await #expect(throws: LocusKitError.self) {
            try await addParentEdge(store: store, child: "c", parent: "b", orderKey: 2.0, now: now)
        }
    }
}
