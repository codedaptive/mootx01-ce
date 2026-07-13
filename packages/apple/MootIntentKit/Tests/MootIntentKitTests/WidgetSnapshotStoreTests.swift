import Testing
import Foundation
import MootIntentKit

// MARK: - WidgetSnapshotStore tests
//
// The widget-process side of the recall widget reads ONLY this snapshot —
// it never opens the estate (one estate, one host). The app writes the
// snapshot from a publicOnly recall (the same export gate Spotlight
// donation uses), so nothing non-public can reach the home screen.

@Suite("WidgetSnapshotStore — derived projection for the recall widget")
struct WidgetSnapshotStoreTests {

    private func makeTempStore() throws -> WidgetSnapshotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-store-tests-\(UUID().uuidString)", isDirectory: true)
        return try WidgetSnapshotStore(directory: dir)
    }

    @Test("write then read round-trips entries and freshness")
    func roundTrip() throws {
        let store = try makeTempStore()
        let written = WidgetSnapshot(
            entries: [
                .init(id: "550e8400-e29b-41d4-a716-446655440000", content: "a public memory", room: "workspace"),
                .init(id: "f47ac10b-58cc-4372-a567-0e02b2c3d479", content: "another one", room: "archive"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_752_000_000))
        try store.write(written)
        #expect(store.read() == written)
    }

    @Test("read returns nil when no snapshot exists")
    func absentReadsNil() throws {
        let store = try makeTempStore()
        #expect(store.read() == nil)
    }

    @Test("read returns nil (not a crash) on a corrupt snapshot file")
    func corruptReadsNil() throws {
        let store = try makeTempStore()
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    @Test("from(drawers:) maps DrawerEntity previews into snapshot entries in order")
    func fromDrawers() {
        let snapshot = WidgetSnapshot.from(
            drawers: [
                DrawerEntity(id: "id-1", content: "first", room: "r1"),
                DrawerEntity(id: "id-2", content: "second", room: "r2"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1))
        #expect(snapshot.entries.map(\.id) == ["id-1", "id-2"])
        #expect(snapshot.entries.map(\.content) == ["first", "second"])
        #expect(snapshot.entries.map(\.room) == ["r1", "r2"])
    }
}
