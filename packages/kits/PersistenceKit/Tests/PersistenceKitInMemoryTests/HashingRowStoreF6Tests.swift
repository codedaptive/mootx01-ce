// HashingRowStoreF6Tests.swift
//
// Regression tests for SECFIX-WS2-PK F6 — hash-on-write correctness.
//
// F6: `update` and `upsert` (on the update path) used to compute the
// ContentHash from the partial SET-column dict, not the full committed row.
// This meant the stored `content_hash` diverged from the actual row state:
// - `update(table:values:where:)` with two columns hashed only those two columns,
//   ignoring all other columns already on the row.
// - `upsert(table:values:conflictColumns:)` on an existing row hashed only the
//   incoming values dict, ignoring unchanged columns.
//
// After the fix:
// - `update` pre-reads the current row, merges SET values over it, and hashes
//   the merged (full) state.
// - `upsert` on the update path does the same merge before hashing.
//
// These tests verify that the hash stored in `content_hash` after an update or
// upsert matches the hash the caller would compute from the full row, not just
// the columns that appeared in the write dict.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Helpers (local to this file — do not share with HashingRowStoreTests)

private actor EventCollector {
    var events: [DirtyChainEvent] = []
    func append(_ event: DirtyChainEvent) { events.append(event) }
    var count: Int { events.count }
    func get(_ index: Int) -> DirtyChainEvent { events[index] }
}

/// A hash function that takes the full values dict as its source of truth.
/// It encodes sorted column names in bytes 16-31 so the caller can predict what
/// hash a specific column set should produce and verify that the stored hash
/// matches `deterministicHash(table, id, fullValues)` — not a partial values dict.
///
/// Key property: DIFFERENT column sets produce DIFFERENT fingerprints because
/// the sorted key string differs. A hash from partial values will not match
/// a hash from the full merged row, making mis-hashes detectable in tests.
private func deterministicHash(
    _ table: String,
    _ rowKey: RowKey,   // RowKey = UUID (typealias)
    _ values: [String: TypedValue]
) -> ContentHash {
    var bytes = [UInt8](repeating: 0, count: 32)
    // Bytes 0-15: row key UUID bytes.
    let idBytes = withUnsafeBytes(of: rowKey.uuid) { Array($0) }
    for i in 0..<16 {
        bytes[i] = idBytes[i]
    }
    // Bytes 16-31: fingerprint of the sorted column-name set.
    // Different column sets → different sorted-key strings → different fingerprint.
    let sortedKeys = values.keys.sorted()
    let keyString = sortedKeys.joined(separator: ",")
    let keyBytes = Array(keyString.utf8)
    for i in 0..<min(16, keyBytes.count) {
        bytes[16 + i] = keyBytes[i]
    }
    return ContentHash(bytes: bytes)
}

private func deterministicParentChain(
    _ table: String,
    _ rowKey: RowKey
) -> (parentNodeId: UUID, grandparentNodeId: UUID)? {
    (
        parentNodeId: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        grandparentNodeId: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    )
}

private func makeStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

private func openHashableSchema(_ storage: InMemoryStorage) async throws {
    try await storage.open(schema: SchemaDeclaration(
        kitID: "F6TestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "entries",
                columns: [
                    .uuid("id"),
                    .text("title"),
                    .text("body", nullable: true),
                    .bitmap("flags"),
                    .blob("content_hash", nullable: true)
                ],
                primaryKey: ["id"],
                hashable: true
            )
        ]
    ))
}

private func makeHashingStore(
    _ storage: InMemoryStorage,
    sink: EventCollector
) -> HashingRowStore {
    let config = HashOnWriteConfig(
        hashableTables: ["entries"],
        hashProvider: deterministicHash,
        parentChainProvider: deterministicParentChain
    )
    return HashingRowStore(
        backing: storage.rowStore,
        config: config,
        dirtyChainSink: { event in await sink.append(event) }
    )
}

// MARK: - Tests

@Suite("HashingRowStoreF6Tests — hash correctness for update and upsert")
struct HashingRowStoreF6Tests {

    /// After inserting a row with all columns, calling `update` with only a
    /// subset of columns must produce a hash computed from the FULL committed
    /// row (all columns merged), not from the partial SET dict.
    ///
    /// The regression: before the fix, `update` with {"body": "new"} produced
    /// a hash equivalent to `deterministicHash("entries", id, ["body": "new"])`,
    /// which omits "id", "title", and "flags" — diverging from the actual row.
    @Test func updateHashesFullMergedRow() async throws {
        let storage = makeStorage()
        try await openHashableSchema(storage)
        let sink = EventCollector()
        let store = makeHashingStore(storage, sink: sink)

        let id = UUID()
        // Insert with all columns populated.
        _ = try await store.insert(
            table: "entries",
            values: [
                "id": .uuid(id),
                "title": .text("original title"),
                "body": .text("original body"),
                "flags": .bitmap(0)
            ]
        )

        // Update only the "body" column.
        _ = try await store.update(
            table: "entries",
            values: ["body": .text("updated body")],
            where: .eq(Column(table: "entries", name: "id"), .uuid(id))
        )

        // Fetch the stored row to verify its actual state.
        let rows = try await store.query(table: "entries")
        #expect(rows.count == 1)
        let row = rows[0]

        // Compute what the hash SHOULD be: all four data columns merged.
        // `content_hash` is excluded from the hash input — the hash function always
        // receives data columns only (consistent with the INSERT path, which computes
        // the hash BEFORE writing `content_hash` into the row).
        let fullValues: [String: TypedValue] = [
            "id": .uuid(id),
            "title": .text("original title"),
            "body": .text("updated body"),
            "flags": .bitmap(0)
        ]
        let expectedHash = deterministicHash("entries", id, fullValues)
        let expectedHashData = Data(expectedHash.bytes)

        // Verify the stored content_hash matches the full-row hash.
        guard case .blob(let storedHashData) = row["content_hash"] else {
            Issue.record("content_hash column missing or wrong type after update")
            return
        }
        #expect(
            storedHashData == expectedHashData,
            "content_hash after update must reflect full committed row, not just the SET columns"
        )
    }

    /// Calling `upsert` on an already-existing row must hash the full merged row
    /// (current state merged with incoming values), not just the incoming values dict.
    ///
    /// The regression: `upsert` on an existing row with {"id": id, "title": "new"}
    /// produced `deterministicHash("entries", id, {"id": id, "title": "new"})`,
    /// omitting "body" and "flags" which were already on the row.
    @Test func upsertOnExistingRowHashesFullMergedRow() async throws {
        let storage = makeStorage()
        try await openHashableSchema(storage)
        let sink = EventCollector()
        let store = makeHashingStore(storage, sink: sink)

        let id = UUID()
        // Insert a row with all columns.
        _ = try await store.insert(
            table: "entries",
            values: [
                "id": .uuid(id),
                "title": .text("initial title"),
                "body": .text("initial body"),
                "flags": .bitmap(7)
            ]
        )

        // Upsert with only id + title (conflict column + one updated column).
        _ = try await store.upsert(
            table: "entries",
            values: ["id": .uuid(id), "title": .text("revised title")],
            conflictColumns: ["id"]
        )

        let rows = try await store.query(table: "entries")
        #expect(rows.count == 1)
        let row = rows[0]

        // The full committed row: body and flags unchanged, title updated.
        // `content_hash` is excluded from the hash input — it is stripped before
        // the hash function is called, consistent with the INSERT path.
        let fullValues: [String: TypedValue] = [
            "id": .uuid(id),
            "title": .text("revised title"),
            "body": .text("initial body"),
            "flags": .bitmap(7)
        ]
        let expectedHash = deterministicHash("entries", id, fullValues)
        let expectedHashData = Data(expectedHash.bytes)

        guard case .blob(let storedHashData) = row["content_hash"] else {
            Issue.record("content_hash missing or wrong type after upsert")
            return
        }
        #expect(
            storedHashData == expectedHashData,
            "content_hash after upsert on existing row must reflect full committed row, not just incoming values"
        )
    }

    /// On an INSERT path (upsert where the row does not exist yet), the hash must
    /// be computed from the incoming values (there is no prior row to merge with).
    @Test func upsertOnNewRowHashesIncomingValues() async throws {
        let storage = makeStorage()
        try await openHashableSchema(storage)
        let sink = EventCollector()
        let store = makeHashingStore(storage, sink: sink)

        let id = UUID()
        let incomingValues: [String: TypedValue] = [
            "id": .uuid(id),
            "title": .text("brand new"),
            "flags": .bitmap(1)
        ]

        _ = try await store.upsert(
            table: "entries",
            values: incomingValues,
            conflictColumns: ["id"]
        )

        let rows = try await store.query(table: "entries")
        #expect(rows.count == 1)

        // For a new insert, incoming values ARE the full row.
        let expectedHash = deterministicHash("entries", id, incomingValues)
        let expectedHashData = Data(expectedHash.bytes)

        guard case .blob(let storedHashData) = rows[0]["content_hash"] else {
            Issue.record("content_hash missing after upsert-insert")
            return
        }
        #expect(storedHashData == expectedHashData)
    }
}
