import Foundation
import SQLite3
import Testing
@testable import LocusKit

@Suite("SummariesTests")
struct SummariesTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-summaries-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    // MARK: - Fixture

    /// Bundles the two stores that share a single SQLite file.
    private struct TestFixture {
        let drawerStore: DrawerStore
        let nodeStore: NodeStore
        let url: URL
    }

    /// Creates a DrawerStore and a NodeStore over the same SQLite file.
    /// Both stores share the opened schema so node rows are visible to
    /// DrawerStore's node-tree queries (listWings / listRooms).
    private func makeFixture() async throws -> TestFixture {
        let url = makeTempURL()
        let storage = TestStorage.sqlite(url)
        let drawerStore = try await DrawerStore(storage: storage)
        let nodeStore = NodeStore(storage: storage)
        return TestFixture(drawerStore: drawerStore, nodeStore: nodeStore, url: url)
    }

    /// Build a Drawer rooted at `parentNodeId` (a room node's UUID string).
    /// `listWings` / `listRooms` resolve via the node tree using this ID.
    private func d(id: String, parentNodeId: String, filedAt: Date? = nil) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "c-\(id)",
            parentNodeId: parentNodeId,
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    /// Tombstone a drawer directly via the underlying SQLite handle.
    /// `addDrawer` does not expose tombstoning at the store level, so
    /// the test fixture writes the tombstone column directly.
    private func tombstone(drawerId: String, in url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let opened = handle else {
            Issue.record("could not reopen SQLite for tombstone fixture")
            return
        }
        defer { sqlite3_close_v2(opened) }
        let sql = "UPDATE drawers SET tombstonedAt = '2026-01-01T00:00:00.000Z' WHERE id = ?"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(opened, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, drawerId, -1, TRANSIENT)
        sqlite3_step(stmt)
    }

    @Test("listWings on an empty store returns an empty array")
    func listWingsEmpty() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }
        #expect(try await fixture.drawerStore.listWings().isEmpty)
    }

    @Test("listWings counts drawers and distinct rooms per wing")
    func listWingsCounts() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }

        // Build the node tree: root → wing-a / wing-b → rooms.
        let root  = try await fixture.nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wingA = try await fixture.nodeStore.createNode(displayName: "wing-a", parentId: root.id, now: t(1))
        let wingB = try await fixture.nodeStore.createNode(displayName: "wing-b", parentId: root.id, now: t(2))
        let r1a   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingA.id, now: t(3))
        let r2a   = try await fixture.nodeStore.createNode(displayName: "r2", parentId: wingA.id, now: t(4))
        let r1b   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingB.id, now: t(5))

        try await fixture.drawerStore.addDrawer(d(id: "1", parentNodeId: r1a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "2", parentNodeId: r1a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "3", parentNodeId: r2a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "4", parentNodeId: r1b.id.uuidString))

        let wings = try await fixture.drawerStore.listWings()
        #expect(wings.count == 2)
        let a = wings.first { $0.name == "wing-a" }
        let b = wings.first { $0.name == "wing-b" }
        #expect(a?.drawerCount == 3)
        #expect(a?.roomCount == 2)
        #expect(b?.drawerCount == 1)
        #expect(b?.roomCount == 1)
    }

    @Test("listWings excludes tombstoned drawers")
    func listWingsExcludesTombstoned() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }

        let root  = try await fixture.nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wingA = try await fixture.nodeStore.createNode(displayName: "wing-a", parentId: root.id, now: t(1))
        let r1    = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingA.id, now: t(2))

        try await fixture.drawerStore.addDrawer(d(id: "1", parentNodeId: r1.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "2", parentNodeId: r1.id.uuidString))
        try tombstone(drawerId: TestStorage.tid("2"), in: fixture.url)

        let wings = try await fixture.drawerStore.listWings()
        #expect(wings.count == 1)
        #expect(wings.first?.drawerCount == 1)
    }

    @Test("listRooms(in: nil) returns rooms across all wings")
    func listRoomsAcrossAllWings() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }

        let root  = try await fixture.nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wingA = try await fixture.nodeStore.createNode(displayName: "wing-a", parentId: root.id, now: t(1))
        let wingB = try await fixture.nodeStore.createNode(displayName: "wing-b", parentId: root.id, now: t(2))
        let r1a   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingA.id, now: t(3))
        let r2a   = try await fixture.nodeStore.createNode(displayName: "r2", parentId: wingA.id, now: t(4))
        let r1b   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingB.id, now: t(5))

        try await fixture.drawerStore.addDrawer(d(id: "1", parentNodeId: r1a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "2", parentNodeId: r2a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "3", parentNodeId: r1b.id.uuidString))

        let rooms = try await fixture.drawerStore.listRooms(in: nil)
        #expect(rooms.count == 3)
        let pairs = Set(rooms.map { "\($0.wing)/\($0.name)" })
        #expect(pairs == ["wing-a/r1", "wing-a/r2", "wing-b/r1"])
    }

    @Test("listRooms(in: wing) filters by wing")
    func listRoomsFilteredByWing() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }

        let root  = try await fixture.nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wingA = try await fixture.nodeStore.createNode(displayName: "wing-a", parentId: root.id, now: t(1))
        let wingB = try await fixture.nodeStore.createNode(displayName: "wing-b", parentId: root.id, now: t(2))
        let r1a   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingA.id, now: t(3))
        let r2a   = try await fixture.nodeStore.createNode(displayName: "r2", parentId: wingA.id, now: t(4))
        let r1b   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingB.id, now: t(5))

        try await fixture.drawerStore.addDrawer(d(id: "1", parentNodeId: r1a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "2", parentNodeId: r2a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "3", parentNodeId: r1b.id.uuidString))

        let rooms = try await fixture.drawerStore.listRooms(in: "wing-a")
        #expect(rooms.count == 2)
        #expect(Set(rooms.map(\.name)) == ["r1", "r2"])
        #expect(rooms.allSatisfy { $0.wing == "wing-a" })
    }

    @Test("taxonomy mirrors listWings output")
    func taxonomyMirrorsListWings() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture.url) }

        let root  = try await fixture.nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wingA = try await fixture.nodeStore.createNode(displayName: "wing-a", parentId: root.id, now: t(1))
        let wingB = try await fixture.nodeStore.createNode(displayName: "wing-b", parentId: root.id, now: t(2))
        let r1a   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingA.id, now: t(3))
        let r1b   = try await fixture.nodeStore.createNode(displayName: "r1", parentId: wingB.id, now: t(4))

        try await fixture.drawerStore.addDrawer(d(id: "1", parentNodeId: r1a.id.uuidString))
        try await fixture.drawerStore.addDrawer(d(id: "2", parentNodeId: r1b.id.uuidString))

        let taxonomy = try await fixture.drawerStore.taxonomy()
        let wings = try await fixture.drawerStore.listWings()
        #expect(taxonomy == wings)
    }
}
