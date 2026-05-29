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

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func d(id: String, wing: String, room: String,
                   filedAt: Date? = nil) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "c-\(id)",
            wing: wing, room: room,
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    /// Tombstone a drawer directly via the underlying SQLite handle.
    /// `addDrawer` does not expose tombstoning at this revision, so
    /// the test fixture writes the column itself. This mirrors the
    /// way LOCI-2 / Rev 2.0 will manage tombstones once the
    /// soft-delete machinery lands.
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
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.listWings().isEmpty)
    }

    @Test("listWings counts drawers and distinct rooms per wing")
    func listWingsCounts() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(d(id: "1", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "2", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "3", wing: "wing-a", room: "r2"))
        try await store.addDrawer(d(id: "4", wing: "wing-b", room: "r1"))
        let wings = try await store.listWings()
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
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(d(id: "1", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "2", wing: "wing-a", room: "r1"))
        try tombstone(drawerId: TestStorage.tid("2"), in: url)
        let wings = try await store.listWings()
        #expect(wings.count == 1)
        #expect(wings.first?.drawerCount == 1)
    }

    @Test("listRooms(in: nil) returns rooms across all wings")
    func listRoomsAcrossAllWings() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(d(id: "1", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "2", wing: "wing-a", room: "r2"))
        try await store.addDrawer(d(id: "3", wing: "wing-b", room: "r1"))
        let rooms = try await store.listRooms(in: nil)
        #expect(rooms.count == 3)
        let pairs = Set(rooms.map { "\($0.wing)/\($0.name)" })
        #expect(pairs == ["wing-a/r1", "wing-a/r2", "wing-b/r1"])
    }

    @Test("listRooms(in: wing) filters by wing")
    func listRoomsFilteredByWing() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(d(id: "1", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "2", wing: "wing-a", room: "r2"))
        try await store.addDrawer(d(id: "3", wing: "wing-b", room: "r1"))
        let rooms = try await store.listRooms(in: "wing-a")
        #expect(rooms.count == 2)
        #expect(Set(rooms.map(\.name)) == ["r1", "r2"])
        #expect(rooms.allSatisfy { $0.wing == "wing-a" })
    }

    @Test("taxonomy mirrors listWings output")
    func taxonomyMirrorsListWings() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(d(id: "1", wing: "wing-a", room: "r1"))
        try await store.addDrawer(d(id: "2", wing: "wing-b", room: "r1"))
        let taxonomy = try await store.taxonomy()
        let wings = try await store.listWings()
        #expect(taxonomy == wings)
    }
}
