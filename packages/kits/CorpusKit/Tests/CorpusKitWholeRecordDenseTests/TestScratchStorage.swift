import Foundation
import PersistenceKit
import PersistenceKitSQLite

// Tests run on the REAL persistent backend (on-disk SQLite), never the in-RAM
// backend. InMemoryStorage preserves the inserted semantic TypedValues
// (.uuid/.hlc/.timestamp) on read, while SQLite — the backend production and the
// gauntlet actually use, and the on-disk equivalent of MemPalace's Chroma —
// hands back the primitive forms (.text/.int). Testing on the in-RAM backend hid
// real reopen bugs (chunks/vectors silently failing to decode). One scratch
// SQLite file per call, in the temp dir.
func makeScratchStorage() throws -> any Storage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corpuskit-test-\(UUID().uuidString).sqlite3")
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
}
