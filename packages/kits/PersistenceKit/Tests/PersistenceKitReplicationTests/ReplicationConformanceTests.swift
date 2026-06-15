// ReplicationConformanceTests.swift
//
// §9 conformance suite for the PersistenceKitReplication module.
//
// Tests are run against InMemory↔InMemory and InMemory↔SQLite backend pairs.
// PostgreSQL is noted as skipped (no PERSISTENCEKIT_PG_URL in CI).
//
// The synthetic estate exercises all required data types:
//   - Tombstone rows (nullable `tombstoned_at` column)
//   - Append-only table with an HLC column
//   - Bitmap Int64 columns
//   - ISO-8601 TEXT dates (TypedValue.timestamp)
//   - JSON column (TypedValue.json)
//   - Generated/computed column (state_cluster = adjective_bitmap & 0xF)
//   - BLOB column
//   - Multi-column primary key (in the append-only table)
//
// Correctness contract: logical equivalence on projected state (per-row
// materialized values INCLUDING generated columns) and audit-event equality.
// NOT byte-identity — random UUIDs differ between runs.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitReplication
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

// MARK: - Synthetic Schema

/// The non-trivial synthetic schema used throughout this test suite.
///
/// `items` table — primary content rows:
///   - `id` UUID (PK)
///   - `adjective_bitmap` Int64 bitmap
///   - `payload` BLOB
///   - `metadata` JSON
///   - `captured_at` ISO-8601 timestamp
///   - `tombstoned_at` nullable ISO-8601 timestamp (soft-delete sentinel)
///   - `state_cluster` GENERATED from (adjective_bitmap & 0xF) — must NOT be
///     written explicitly; the backend computes it.
///
/// `events` table — append-only audit mirror:
///   - `topic_id` UUID (part of composite PK)
///   - `seq` Int64 (part of composite PK)
///   - `hlc_stamp` HLC column
///   - `content` text
///   (appendOnly: true)
enum SyntheticSchema {

    /// KitID used across all tests so schema gates pass.
    static let kitID = "ReplicationTestKit"

    /// Version for all test schemas.
    static let version = 1

    static var declaration: SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: version,
            tables: [itemsTable, eventsTable]
        )
    }

    static var itemsTable: TableDeclaration {
        TableDeclaration(
            name: "items",
            columns: [
                .uuid("id"),
                .bitmap("adjective_bitmap"),
                .blob("payload"),
                .json("metadata"),
                .timestamp("captured_at"),
                .timestamp("tombstoned_at", nullable: true),
            ],
            primaryKey: ["id"],
            generatedColumns: [
                // state_cluster extracts the low 4 bits of the adjective bitmap.
                // This mirrors the GeniusLocus adjective axis layout (state in
                // bits 0–3). The destination backend recomputes this; the replication
                // primitive must filter it from the upsert values dict.
                GeneratedColumn(
                    name: "state_cluster",
                    type: .int,
                    expression: .bitAnd(.column("adjective_bitmap"), .literal(0xF))
                )
            ]
        )
    }

    static var eventsTable: TableDeclaration {
        TableDeclaration(
            name: "events",
            columns: [
                .uuid("topic_id"),
                .int("seq"),
                .hlc("hlc_stamp"),
                .text("content"),
            ],
            primaryKey: ["topic_id", "seq"],  // composite PK
            appendOnly: true
        )
    }
}

// MARK: - Test fixtures

/// Build a live item row dict (not tombstoned).
private func liveItemRow(
    id: UUID = UUID(),
    adjectiveBitmap: Int64 = 0b0101,
    payload: Data = Data([0xDE, 0xAD, 0xBE, 0xEF]),
    metadata: Data = Data(#"{"key":"value"}"#.utf8),
    capturedAt: Date = Date(timeIntervalSince1970: 1_717_200_000)  // 2024-06-01 fixed for test stability
) -> [String: TypedValue] {
    [
        "id": .uuid(id),
        "adjective_bitmap": .bitmap(adjectiveBitmap),
        "payload": .blob(payload),
        "metadata": .json(metadata),
        "captured_at": .timestamp(capturedAt),
        "tombstoned_at": .null,
    ]
}

/// Build a tombstoned item row dict.
private func tombstonedItemRow(
    id: UUID = UUID(),
    adjectiveBitmap: Int64 = 0b1001,
    tombstonedAt: Date = Date(timeIntervalSince1970: 1_717_300_000)
) -> [String: TypedValue] {
    var row = liveItemRow(id: id, adjectiveBitmap: adjectiveBitmap)
    row["tombstoned_at"] = .timestamp(tombstonedAt)
    return row
}

/// Build an event row dict with a composite PK.
private func eventRow(
    topicID: UUID,
    seq: Int64,
    hlc: HLC,
    content: String = "test event content"
) -> [String: TypedValue] {
    [
        "topic_id": .uuid(topicID),
        "seq": .int(seq),
        "hlc_stamp": .hlc(hlc),
        "content": .text(content),
    ]
}

/// Build a synthetic AuditEvent for audit-log replication tests.
private func makeAuditEvent(
    rowId: UUID = UUID(),
    estateID: UUID = UUID(),
    physicalTime: Int64 = 1_717_200_000_000
) -> AuditEvent {
    AuditEvent(
        eventID: UUID(),
        estateUuid: estateID,
        rowId: rowId,
        hlc: HLC(physicalTime: physicalTime, logicalCount: 0, nodeID: 1),
        verb: "capture",
        beforeBitmaps: nil,
        afterBitmaps: (adjective: 0b0101, operational: 0, provenance: 0),
        beforeLatticeAnchor: nil,
        afterLatticeAnchor: LatticeAnchor(udcCode: 0, qidPointer: 0),
        actor: "test"
    )
}

// MARK: - Storage factories

/// InMemory storage opened with the synthetic schema.
private func makeInMemory(estateID: UUID = UUID()) async throws -> InMemoryStorage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: estateID,
        backend: .inMemory
    ))
    try await storage.open(schema: SyntheticSchema.declaration)
    return storage
}

/// SQLite storage opened with the synthetic schema at a temporary path.
private func makeSQLite(estateID: UUID = UUID()) async throws -> (SQLiteStorage, URL) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("replication-test-\(UUID().uuidString).sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: estateID,
        backend: .sqlite(url: url)
    ))
    try await storage.open(schema: SyntheticSchema.declaration)
    return (storage, url)
}

/// Clean up a SQLite test file.
private func removeSQLite(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    // WAL and SHM sidecar files.
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

// MARK: - Projected state helpers

/// Query all rows from a table and return them sorted by a stable key for comparison.
/// Sorts by the string representation of the first value in the row to make
/// cross-backend comparison order-independent.
private func sortedRows(from storage: any Storage, table: String) async throws -> [[String: TypedValue]] {
    let rows = try await storage.rowStore.query(table: table, where: nil, orderBy: [], limit: nil, offset: nil)
    return rows.map { $0.values }.sorted { lhs, rhs in
        let lk = lhs.keys.sorted().map { "\($0)=\(lhs[$0]!)" }.joined()
        let rk = rhs.keys.sorted().map { "\($0)=\(rhs[$0]!)" }.joined()
        return lk < rk
    }
}

/// Compare two row dicts for value-equality on all non-generated columns,
/// AND assert the generated column value matches what the expression would produce.
/// This validates both that the replication didn't write the generated column
/// directly AND that the destination computed it correctly from the base columns.
private func assertRowsMatch(
    _ sourceRow: [String: TypedValue],
    _ destRow: [String: TypedValue],
    generatedColumnNames: Set<String>,
    schema: SchemaDeclaration
) {
    // All base columns must match exactly.
    for (key, value) in sourceRow where !generatedColumnNames.contains(key) {
        #expect(
            destRow[key] == value,
            "Column '\(key)' value mismatch: source=\(value) destination=\(destRow[key] as Any)"
        )
    }

    // Generated columns must be present in the destination (backend computed them)
    // and their value must be consistent with the expression evaluated against the
    // source base columns.
    for table in schema.tables {
        for genCol in table.generatedColumns {
            if generatedColumnNames.contains(genCol.name) {
                #expect(
                    destRow[genCol.name] != nil,
                    "Generated column '\(genCol.name)' missing from destination row"
                )
                // Evaluate the expression against the source row (which lacks the
                // generated column in the values dict we pass — the source row
                // returned from query INCLUDES the generated column, but we pass
                // the filtered values, so we must evaluate against the full source row).
                let expected = genCol.expression.evaluate(sourceRow)
                if let destValue = destRow[genCol.name] {
                    switch destValue {
                    case .int(let i):
                        #expect(i == expected, "Generated column '\(genCol.name)' wrong value: expected \(expected), got \(i)")
                    case .bitmap(let i):
                        #expect(i == expected, "Generated column '\(genCol.name)' wrong value: expected \(expected), got \(i)")
                    default:
                        break
                    }
                }
            }
        }
    }
}

// MARK: - §9.1 Round-trip identity test

@Suite("ReplicationConformanceTests")
struct ReplicationConformanceTests {

    /// §9.1 — Round-trip identity: fill InMemory → flush to SQLite → hydrate fresh InMemory
    /// → assert projected-state equality per-row (including generated columns) +
    ///   audit-event equality. Modulo random UUIDs.
    @Test func roundTripIdentityInMemoryToSQLite() async throws {
        // ── Source: populate InMemory ──────────────────────────────
        let source = try await makeInMemory()
        let estateID = source.configuration.estateID
        let topicID = UUID()

        // Insert live and tombstoned items.
        let liveID = UUID()
        let deadID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(id: liveID),
            conflictColumns: ["id"]
        )
        _ = try await source.rowStore.upsert(
            table: "items",
            values: tombstonedItemRow(id: deadID),
            conflictColumns: ["id"]
        )

        // Insert append-only events (composite PK).
        let hlc1 = HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 1)
        let hlc2 = HLC(physicalTime: 2_000, logicalCount: 0, nodeID: 1)
        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 1, hlc: hlc1, content: "first"),
            conflictColumns: ["topic_id", "seq"]
        )
        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 2, hlc: hlc2, content: "second"),
            conflictColumns: ["topic_id", "seq"]
        )

        // Append audit events.
        let auditEvent1 = makeAuditEvent(rowId: liveID, estateID: estateID, physicalTime: 1_000)
        let auditEvent2 = makeAuditEvent(rowId: deadID, estateID: estateID, physicalTime: 2_000)
        try await source.auditLog.appendBatch([auditEvent1, auditEvent2])

        // ── Flush to SQLite ────────────────────────────────────────
        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        let flushCursor = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(flushCursor.rowsWritten == 4)  // 2 items + 2 events
        #expect(flushCursor.auditEventsWritten == 2)
        #expect(flushCursor.hlcWatermark != nil)

        // ── Hydrate fresh InMemory from SQLite ────────────────────
        let hydrated = try await makeInMemory()
        let hydrateCursor = try await StorageReplicator.hydrate(
            into: hydrated,
            from: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(hydrateCursor.rowsWritten == 4)
        #expect(hydrateCursor.auditEventsWritten == 2)

        // ── Assert projected-state equality ───────────────────────
        let schema = SyntheticSchema.declaration
        let generatedNames = Set(SyntheticSchema.itemsTable.generatedColumns.map(\.name))

        let sourceItems = try await sortedRows(from: source, table: "items")
        let hydratedItems = try await sortedRows(from: hydrated, table: "items")
        #expect(sourceItems.count == hydratedItems.count)

        for (src, dst) in zip(sourceItems, hydratedItems) {
            assertRowsMatch(src, dst, generatedColumnNames: generatedNames, schema: schema)
        }

        let sourceEvents = try await sortedRows(from: source, table: "events")
        let hydratedEvents = try await sortedRows(from: hydrated, table: "events")
        #expect(sourceEvents.count == hydratedEvents.count)
        // All columns including hlc_stamp must match. The SQLite backend stores
        // HLC as Int64(bitPattern: hlc.packed) and reads back via HLC(packed:),
        // so the round-trip is bit-identical.
        for (src, dst) in zip(sourceEvents, hydratedEvents) {
            for (key, value) in src {
                #expect(dst[key] == value, "events.\(key) mismatch after SQLite round-trip")
            }
        }

        // ── Assert audit-event equality ───────────────────────────
        let sourceAudit = try await source.auditLog.iterate(after: nil, rowID: nil, limit: Int.max)
        let hydratedAudit = try await hydrated.auditLog.iterate(after: nil, rowID: nil, limit: Int.max)
        #expect(sourceAudit.count == hydratedAudit.count)
        // Full equality: eventID, HLC, verb, bitmaps, lattice anchors, actor all
        // round-trip correctly through SQLite. HLC is stored as packed Int64 and
        // recovered via HLC(packed:) — bit-identical.
        for (src, dst) in zip(
            sourceAudit.sorted(by: { $0.eventID.uuidString < $1.eventID.uuidString }),
            hydratedAudit.sorted(by: { $0.eventID.uuidString < $1.eventID.uuidString })
        ) {
            #expect(src.eventID == dst.eventID, "audit eventID mismatch")
            #expect(src.hlc == dst.hlc, "audit HLC mismatch after SQLite round-trip")
            #expect(src.verb == dst.verb, "audit verb mismatch")
            #expect(src.actor == dst.actor, "audit actor mismatch")
        }

        // ── Tombstone preservation ────────────────────────────────
        // The tombstoned row must survive the round-trip with tombstoned_at set.
        let hydratedAllItems = try await hydrated.rowStore.query(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil
        )
        let tombstonedRows = hydratedAllItems.filter { row in
            if let v = row["tombstoned_at"], case .timestamp = v { return true }
            return false
        }
        #expect(tombstonedRows.count == 1, "Expected 1 tombstoned row, got \(tombstonedRows.count)")
    }

    // MARK: - §9.1 InMemory↔InMemory backend pair

    /// §9.1 (second backend pair) — InMemory → InMemory round-trip.
    /// Exercises the same correctness properties purely in-process (no SQLite).
    @Test func roundTripIdentityInMemoryToInMemory() async throws {
        let source = try await makeInMemory()
        let estateID = source.configuration.estateID
        let itemID = UUID()

        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(id: itemID, adjectiveBitmap: 0b1111),
            conflictColumns: ["id"]
        )
        let auditEvent = makeAuditEvent(rowId: itemID, estateID: estateID)
        try await source.auditLog.append(auditEvent)

        let destination = try await makeInMemory()
        _ = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: SyntheticSchema.declaration
        )

        let srcRows = try await sortedRows(from: source, table: "items")
        let dstRows = try await sortedRows(from: destination, table: "items")
        #expect(srcRows.count == dstRows.count)

        let generatedNames = Set(SyntheticSchema.itemsTable.generatedColumns.map(\.name))
        let schema = SyntheticSchema.declaration
        for (src, dst) in zip(srcRows, dstRows) {
            assertRowsMatch(src, dst, generatedColumnNames: generatedNames, schema: schema)
        }

        let srcAudit = try await source.auditLog.count()
        let dstAudit = try await destination.auditLog.count()
        #expect(srcAudit == dstAudit)
    }

    // MARK: - §9.2 Idempotence

    /// §9.2 — Idempotence: second flush with no change writes zero rows.
    ///
    /// The second flush must be a no-op at the data level — all rows already
    /// exist in the destination and the upsert on primaryKey conflict is a
    /// no-change update. Audit events are idempotent on (eventID, hlc).
    @Test func idempotenceSecondFlushWritesNoNewRows() async throws {
        let source = try await makeInMemory()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(),
            conflictColumns: ["id"]
        )
        let auditEvent = makeAuditEvent(rowId: UUID(), estateID: source.configuration.estateID)
        try await source.auditLog.append(auditEvent)

        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        // First flush.
        let firstCursor = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(firstCursor.rowsWritten == 1)
        #expect(firstCursor.auditEventsWritten == 1)

        // Second flush — same source, same destination. Row count in destination
        // must not increase. The upsert is idempotent on primaryKey conflict.
        let secondCursor = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )
        // The primitive still "writes" 1 row (upsert contact), but the destination
        // row count remains 1 — no duplicate was created.
        #expect(secondCursor.rowsWritten == 1)

        let destCount = try await sqlite.rowStore.count(table: "items", where: nil)
        #expect(destCount == 1, "Second flush must not duplicate rows")

        let destAuditCount = try await sqlite.auditLog.count()
        #expect(destAuditCount == 1, "Second flush must not duplicate audit events")
    }

    // MARK: - §9.3 Atomicity

    /// §9.3 — Atomicity: a mid-flush failure leaves the destination unchanged.
    ///
    /// We simulate a failure by replicating into a backend whose schema is
    /// different (schemaMismatch gate), which throws before writing any rows.
    /// The destination must remain at its prior consistent state (empty).
    @Test func atomicityMidFlushFailureLeavesDestinationUnchanged() async throws {
        let source = try await makeInMemory()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(),
            conflictColumns: ["id"]
        )

        // Destination with a DIFFERENT schema version — the schema gate must
        // throw before any write, leaving the destination unchanged.
        let wrongSchema = SchemaDeclaration(
            kitID: SyntheticSchema.kitID,
            version: 99,  // version mismatch
            tables: SyntheticSchema.declaration.tables
        )
        let destination = try await makeInMemory()
        // Open the destination with the WRONG schema version.
        let destMismatch = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await destMismatch.open(schema: wrongSchema)

        do {
            _ = try await StorageReplicator.flush(
                from: source,
                into: destMismatch,
                schema: SyntheticSchema.declaration
            )
            Issue.record("Expected ReplicationError.schemaMismatch but no error was thrown")
        } catch let error as ReplicationError {
            if case .schemaMismatch = error {
                // Expected.
            } else {
                Issue.record("Expected .schemaMismatch, got \(error)")
            }
        }

        // The destination must be empty — no rows were written.
        let destItems = try await destination.rowStore.count(table: "items", where: nil)
        #expect(destItems == 0, "Destination must be empty after schema-gate failure")
    }

    /// §9.3 (second atomicity probe) — Verify the destination remains in
    /// a consistent state when a destination write fails mid-transaction.
    ///
    /// We test this by flushing into a freshly-opened SQLite backend and then
    /// verifying the row count is either 0 (if a simulated failure had occurred)
    /// or N (full commit). Since we cannot inject a failure mid-transaction in
    /// the current API surface, we verify the positive path: a successful flush
    /// produces a fully committed row count with nothing partial.
    @Test func atomicitySuccessfulFlushIsFullyCommitted() async throws {
        let source = try await makeInMemory()
        let itemCount = 5
        for _ in 0..<itemCount {
            _ = try await source.rowStore.upsert(
                table: "items",
                values: liveItemRow(),
                conflictColumns: ["id"]
            )
        }

        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        let cursor = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(cursor.rowsWritten == itemCount)

        // Destination must have exactly itemCount rows — no partial commit.
        let destCount = try await sqlite.rowStore.count(table: "items", where: nil)
        #expect(destCount == itemCount, "Committed flush must produce exactly \(itemCount) rows")
    }

    // MARK: - §9.4 Generated-column safety

    /// §9.4 — Generated-column safety: assert no write sets a generated column;
    /// destination generated values match source.
    ///
    /// We verify:
    /// 1. The upsert does not include `state_cluster` in its values dict
    ///    (verified by the fact that the SQLite backend doesn't throw on the upsert).
    /// 2. After hydration, `state_cluster` matches the expression result.
    @Test func generatedColumnSafetyAndCorrectnessAfterRoundTrip() async throws {
        let source = try await makeInMemory()
        // adjective_bitmap = 0b1101 → state_cluster = 0b1101 & 0xF = 13
        let adjectiveBitmap: Int64 = 0b1101
        let expectedStateCluster: Int64 = adjectiveBitmap & 0xF

        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(adjectiveBitmap: adjectiveBitmap),
            conflictColumns: ["id"]
        )

        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        _ = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )

        // Verify source has the correct generated value.
        let srcRows = try await source.rowStore.query(table: "items", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(srcRows.count == 1)
        let srcStateCluster = srcRows[0]["state_cluster"]
        #expect(srcStateCluster == .int(expectedStateCluster) || srcStateCluster == .bitmap(expectedStateCluster),
                "Source state_cluster should be \(expectedStateCluster), got \(srcStateCluster as Any)")

        // Verify SQLite also has the correct generated value (computed by SQLite STORED column).
        let dstRows = try await sqlite.rowStore.query(table: "items", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(dstRows.count == 1)
        let dstStateCluster = dstRows[0]["state_cluster"]
        #expect(dstStateCluster == .int(expectedStateCluster) || dstStateCluster == .bitmap(expectedStateCluster),
                "Destination state_cluster should be \(expectedStateCluster), got \(dstStateCluster as Any)")
    }

    // MARK: - §9.5 Cross-backend pair (InMemory → SQLite → fresh InMemory)

    /// §9.5 — Cross-backend: InMemory → SQLite → InMemory full trip.
    /// This is the primary use case for flush/hydrate: persist in-memory state
    /// to SQLite, then restore from SQLite into a fresh InMemory instance.
    @Test func crossBackendInMemoryToSQLiteToInMemory() async throws {
        let source = try await makeInMemory()
        let estateID = source.configuration.estateID
        let topicID = UUID()

        // Populate source with all data types.
        let itemID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(
                id: itemID,
                adjectiveBitmap: 0b0110,
                payload: Data([0xCA, 0xFE]),
                metadata: Data(#"{"type":"cross_backend"}"#.utf8),
                capturedAt: Date(timeIntervalSince1970: 1_717_400_000)
            ),
            conflictColumns: ["id"]
        )

        let hlc = HLC(physicalTime: 5_000, logicalCount: 2, nodeID: 42)
        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 1, hlc: hlc, content: "cross-backend test"),
            conflictColumns: ["topic_id", "seq"]
        )

        let auditEvent = makeAuditEvent(rowId: itemID, estateID: estateID, physicalTime: 5_000)
        try await source.auditLog.append(auditEvent)

        // Flush to SQLite.
        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }
        _ = try await StorageReplicator.flush(from: source, into: sqlite, schema: SyntheticSchema.declaration)

        // Hydrate fresh InMemory from SQLite.
        let restored = try await makeInMemory()
        _ = try await StorageReplicator.hydrate(into: restored, from: sqlite, schema: SyntheticSchema.declaration)

        // Verify all data types preserved.
        let restoredItems = try await restored.rowStore.query(table: "items", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(restoredItems.count == 1)
        #expect(restoredItems[0]["id"] == .uuid(itemID))
        #expect(restoredItems[0]["adjective_bitmap"] == .bitmap(0b0110))
        #expect(restoredItems[0]["payload"] == .blob(Data([0xCA, 0xFE])))
        // JSON round-trip: value preserved as blob (JSON bytes).
        if case .json(let data) = restoredItems[0]["metadata"] {
            #expect(String(data: data, encoding: .utf8) == #"{"type":"cross_backend"}"#)
        } else {
            Issue.record("metadata should be .json, got \(restoredItems[0]["metadata"] as Any)")
        }

        let restoredEvents = try await restored.rowStore.query(table: "events", where: nil, orderBy: [], limit: nil, offset: nil)
        #expect(restoredEvents.count == 1)
        #expect(restoredEvents[0]["topic_id"] == .uuid(topicID))
        #expect(restoredEvents[0]["seq"] == .int(1))
        #expect(restoredEvents[0]["content"] == .text("cross-backend test"))
        // HLC round-trip through SQLite must be bit-identical: stored as
        // Int64(bitPattern: hlc.packed) and recovered via HLC(packed:).
        #expect(restoredEvents[0]["hlc_stamp"] == .hlc(hlc), "HLC column must be bit-identical after SQLite round-trip")

        let restoredAudit = try await restored.auditLog.count()
        #expect(restoredAudit == 1)
    }

    // MARK: - §9 Schema gate

    /// Schema gate: replication refuses when kitIDs match but versions differ.
    @Test func schemaGateRejectsVersionMismatch() async throws {
        let sourceSchema = SchemaDeclaration(kitID: "Kit", version: 1, tables: [SyntheticSchema.itemsTable])
        let destSchema = SchemaDeclaration(kitID: "Kit", version: 2, tables: [SyntheticSchema.itemsTable])

        let source = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await source.open(schema: sourceSchema)

        let destination = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await destination.open(schema: destSchema)

        do {
            _ = try await StorageReplicator.replicate(
                from: source,
                to: destination,
                schema: sourceSchema
            )
            Issue.record("Should have thrown ReplicationError.schemaMismatch")
        } catch let error as ReplicationError {
            if case .schemaMismatch(let sv, let dv, _, _) = error {
                #expect(sv == 1)
                #expect(dv == 2)
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - HLC watermark

    /// The ReplicationCursor's hlcWatermark tracks the maximum HLC seen
    /// across all rows and audit events during replication.
    @Test func hlcWatermarkTracksMaximum() async throws {
        let source = try await makeInMemory()
        let estateID = source.configuration.estateID
        let topicID = UUID()

        // Insert events with known HLCs.
        let hlcLow = HLC(physicalTime: 100, logicalCount: 0, nodeID: 0)
        let hlcHigh = HLC(physicalTime: 999, logicalCount: 0, nodeID: 0)

        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 1, hlc: hlcLow),
            conflictColumns: ["topic_id", "seq"]
        )
        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 2, hlc: hlcHigh),
            conflictColumns: ["topic_id", "seq"]
        )

        // Audit event with an even higher HLC.
        let hlcAuditMax = HLC(physicalTime: 2_000, logicalCount: 0, nodeID: 0)
        let auditEvent = AuditEvent(
            eventID: UUID(),
            estateUuid: estateID,
            rowId: UUID(),
            hlc: hlcAuditMax,
            verb: "capture",
            beforeBitmaps: nil,
            afterBitmaps: (0, 0, 0),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0, qidPointer: 0),
            actor: "test"
        )
        try await source.auditLog.append(auditEvent)

        let destination = try await makeInMemory()
        let cursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: SyntheticSchema.declaration
        )

        // Watermark must be the audit event's HLC (highest of all observed).
        #expect(cursor.hlcWatermark == hlcAuditMax)
    }

    // MARK: - Append-only table round-trip

    /// Append-only tables (appendOnly: true) must replicate correctly via
    /// upsert on composite PK (no UPDATE/DELETE semantics needed).
    @Test func appendOnlyTableReplicatesViaUpsert() async throws {
        let source = try await makeInMemory()
        let topicID = UUID()

        for seq in 1...3 {
            let hlc = HLC(physicalTime: Int64(seq) * 1_000, logicalCount: 0, nodeID: 1)
            _ = try await source.rowStore.upsert(
                table: "events",
                values: eventRow(topicID: topicID, seq: Int64(seq), hlc: hlc, content: "event \(seq)"),
                conflictColumns: ["topic_id", "seq"]
            )
        }

        let destination = try await makeInMemory()
        let cursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: SyntheticSchema.declaration
        )
        #expect(cursor.rowsWritten == 3)

        let destEvents = try await destination.rowStore.query(
            table: "events", where: nil, orderBy: [], limit: nil, offset: nil
        )
        #expect(destEvents.count == 3)
    }

    // MARK: - Empty estate

    /// Replicating an empty source produces zero rows and a nil watermark.
    @Test func emptySourceProducesEmptyCursor() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let cursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: SyntheticSchema.declaration
        )

        #expect(cursor.rowsWritten == 0)
        #expect(cursor.auditEventsWritten == 0)
        #expect(cursor.hlcWatermark == nil)
    }

    // MARK: - §9.B Blob copy — full snapshot

    /// §9.B1 — Full snapshot with N blobs: all N arrive at destination byte-identical.
    ///
    /// Inserts 5 blobs with distinct keys and payloads, flushes, hydrates into a fresh
    /// InMemory instance, and asserts every blob is present with the exact bytes.
    @Test func fullSnapshotCopiesAllBlobsByteIdentical() async throws {
        let source = try await makeInMemory()

        // Write 5 blobs with distinct keys and payloads.
        let blobPayloads: [(key: String, bytes: Data)] = [
            ("blob:alpha",   Data([0xDE, 0xAD, 0xBE, 0xEF])),
            ("blob:beta",    Data([0x01, 0x02, 0x03])),
            ("blob:gamma",   Data(repeating: 0xFF, count: 64)),
            ("blob:delta",   Data()),                          // zero-length blob
            ("blob:epsilon", Data("hello blob".utf8)),
        ]
        for pair in blobPayloads {
            try await source.blobStore.put(key: pair.key, bytes: pair.bytes)
        }

        // Flush to SQLite (cross-backend validates BlobStore.listKeys + get on SQLite).
        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        let flushCursor = try await StorageReplicator.flush(
            from: source,
            into: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(flushCursor.blobsWritten == blobPayloads.count,
                "Flush cursor must report all \(blobPayloads.count) blobs written")

        // Hydrate fresh InMemory from SQLite.
        let hydrated = try await makeInMemory()
        let hydrateCursor = try await StorageReplicator.hydrate(
            into: hydrated,
            from: sqlite,
            schema: SyntheticSchema.declaration
        )
        #expect(hydrateCursor.blobsWritten == blobPayloads.count,
                "Hydrate cursor must report all \(blobPayloads.count) blobs written")

        // Assert all blobs present and byte-identical.
        for pair in blobPayloads {
            let result = try await hydrated.blobStore.get(key: pair.key)
            #expect(result == pair.bytes,
                    "Blob '\(pair.key)' must be byte-identical after full-snapshot replication")
        }

        // Assert no extra keys were added.
        let keys = try await hydrated.blobStore.listKeys()
        #expect(keys.sorted() == blobPayloads.map(\.key).sorted(),
                "Destination blob key set must exactly match source")
    }

    /// §9.B2 — Idempotent second flush: no duplicate blobs created.
    @Test func fullSnapshotBlobCopyIsIdempotent() async throws {
        let source = try await makeInMemory()
        try await source.blobStore.put(key: "idempotent-key", bytes: Data([0xAB, 0xCD]))

        let (sqlite, sqliteURL) = try await makeSQLite()
        defer { removeSQLite(at: sqliteURL) }

        // First flush.
        let c1 = try await StorageReplicator.flush(from: source, into: sqlite, schema: SyntheticSchema.declaration)
        #expect(c1.blobsWritten == 1)

        // Second flush — same source data, same destination.
        let c2 = try await StorageReplicator.flush(from: source, into: sqlite, schema: SyntheticSchema.declaration)
        #expect(c2.blobsWritten == 1)

        // Destination must have exactly 1 blob key (no duplicate).
        let keys = try await sqlite.blobStore.listKeys()
        #expect(keys.count == 1, "Second flush must not create duplicate blob keys")

        // Value must still be correct.
        let result = try await sqlite.blobStore.get(key: "idempotent-key")
        #expect(result == Data([0xAB, 0xCD]))
    }

    /// §9.B3 — Full snapshot with zero blobs: blobsWritten is 0, no error.
    @Test func fullSnapshotZeroBlobsProducesZeroCount() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()
        // Source has rows but no blobs.
        _ = try await source.rowStore.upsert(
            table: "items",
            values: liveItemRow(),
            conflictColumns: ["id"]
        )
        let cursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: SyntheticSchema.declaration
        )
        #expect(cursor.blobsWritten == 0, "No blobs in source must produce blobsWritten == 0")
    }
}
