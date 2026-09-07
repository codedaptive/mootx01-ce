// UpgradeMaintenanceStorageTests.swift
//
// `mootx01 upgrade` opens a fresh SQLiteStorage for its vector reclaim and
// span-encode steps after the estate it migrated through GeniusLocusKit is
// closed. A SQLiteStorage carries no table declarations until a schema is
// opened on it, and the row store derives the primary key of a delete from
// the declared table (`tableDeclarations[table]?.table.primaryKey.first ??
// "row_id"`): on a bare connection the pre-delete key query names a
// `row_id` column the `vectors` table does not have, so on this build the
// rows go but no deleted key parses and the storage observer is told
// nothing. These tests pin both halves: a maintenance storage opened with
// `VectorStore.schemaDeclaration` reclaims by the declared key and announces
// every deleted row under it, and a bare storage over the same file
// announces none.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit

@Suite("Upgrade maintenance storage opens the vector schema", .serialized)
struct UpgradeMaintenanceStorageTests {

    private static let retiredModelID = "lsa-v1"
    private static let filedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func scratchConfiguration() -> (EstateConfiguration, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-upgrade-maintenance-\(UUID().uuidString).sqlite")
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0))
        return (configuration, url)
    }

    /// Three binary rows under a retired dense-family model id, written
    /// through a store whose storage declared the vector schema.
    private static func seedRetiredRows(_ configuration: EstateConfiguration) async throws {
        let storage = try SQLiteStorage(configuration: configuration)
        try await storage.open(schema: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)
        for i in 0..<3 {
            try await store.addPayload(
                itemID: "retired-\(i)", vectorIndex: 0,
                payload: VectorPayload(kind: .binary, dim: 256, bytes: Self.fingerprint(i)),
                modelID: retiredModelID, modelVersion: "v1", filedAt: filedAt)
        }
        try await store.flush()
        await storage.close()
    }

    /// A 32-byte binary fingerprint with one distinct bit per row.
    private static func fingerprint(_ i: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[i] = 1
        return bytes
    }

    private static func binaryRowCount(_ storage: SQLiteStorage) async throws -> Int {
        try await storage.rowStore.query(
            table: "vectors", where: .isTrue, orderBy: [], limit: nil, offset: nil).count
    }

    @Test("a maintenance storage opened with the vector schema reclaims retired rows by the declared primary key")
    func openedStorageReclaims() async throws {
        let (configuration, url) = Self.scratchConfiguration()
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.seedRetiredRows(configuration)

        // The upgrade's fresh connection, opened the way runVectorReclaim opens it.
        let reclaimStorage = try SQLiteStorage(configuration: configuration)
        try await reclaimStorage.open(schema: VectorStore.schemaDeclaration)
        let vectors = VectorStore(storage: reclaimStorage)
        let counts = try await vectors.reclaimRetiredVectorRows(retiredModelIDs: [Self.retiredModelID])
        #expect(counts.retiredModelRows == 3, "every retired-family row is reclaimed; got \(counts)")
        #expect(try await Self.binaryRowCount(reclaimStorage) == 0, "the vectors table is empty after the reclaim")
        await reclaimStorage.close()
    }

    /// The delete events the reclaim announces, read off the storage observer
    /// with a deadline so an absent announcement does not hang the test.
    private static func deleteAnnouncements(
        _ stream: AsyncStream<TableChange>, upTo expected: Int
    ) async -> [TableChange] {
        await withTaskGroup(of: [TableChange].self) { group in
            group.addTask {
                var out: [TableChange] = []
                for await change in stream {
                    out.append(change)
                    if out.count == expected { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    @Test("a bare maintenance storage deletes without the declared primary key: the reclaim announces no row")
    func bareStorageDeletesWithoutTheDeclaredKey() async throws {
        let (configuration, url) = Self.scratchConfiguration()
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.seedRetiredRows(configuration)

        // A connection constructed and never opened with a declaration, the
        // shape the scan finding named. The row store then derives the key of
        // every deleted row from the fallback column name `row_id`, which the
        // `vectors` table does not carry: the rows go, but no announced key
        // parses, so the observer and everything downstream of it (audit,
        // replication) see no delete at all.
        let bareStorage = try SQLiteStorage(configuration: configuration)
        let bareStream = bareStorage.observer.observe(table: "vectors", events: [.delete])
        let vectors = VectorStore(storage: bareStorage)
        let counts = try await vectors.reclaimRetiredVectorRows(retiredModelIDs: [Self.retiredModelID])
        #expect(counts.retiredModelRows == 3)
        let announced = await Self.deleteAnnouncements(bareStream, upTo: 3)
        #expect(announced.isEmpty, "without a declaration the delete announces no key; got \(announced.count)")
        await bareStorage.close()
    }

    @Test("a maintenance storage opened with the vector schema announces every deleted row by its declared primary key")
    func openedStorageAnnouncesTheDeclaredKeys() async throws {
        let (configuration, url) = Self.scratchConfiguration()
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.seedRetiredRows(configuration)

        let storage = try SQLiteStorage(configuration: configuration)
        try await storage.open(schema: VectorStore.schemaDeclaration)
        let ids = try await storage.rowStore.query(
            table: "vectors", where: .isTrue, orderBy: [], limit: nil, offset: nil)
            .compactMap { row -> UUID? in
                if case let .uuid(u) = row["id"] ?? .null { return u }
                return nil
            }
        #expect(ids.count == 3, "precondition: three rows keyed by the declared `id` column")
        let stream = storage.observer.observe(table: "vectors", events: [.delete])
        let vectors = VectorStore(storage: storage)
        let counts = try await vectors.reclaimRetiredVectorRows(retiredModelIDs: [Self.retiredModelID])
        #expect(counts.retiredModelRows == 3)
        let announced = await Self.deleteAnnouncements(stream, upTo: 3)
        #expect(Set(announced.compactMap(\.rowKey)) == Set(ids),
                "the reclaim deletes by the declared primary key: every deleted row is announced under its `id`")
        await storage.close()
    }
}
