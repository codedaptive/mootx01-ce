// IncrementalReplicationTests.swift
//
// §10 incremental replication conformance suite.
//
// Tests exercise:
//   §10.1  Only dirty rows replicated: insert rows, baseline flush, update 3 → only 3 written
//   §10.2  Delete propagation: delete a row on source → deleted on destination
//   §10.3  Restart-resume from watermark: new session uses saved cursor, only new audit events sent
//   §10.4  Corrupt-value abort: corrupt a dirty row's non-PK column via raw SQL → sync throws,
//          no partial commit
//   §10.5  Full-snapshot path unchanged (smoke: full flush still works alongside session)
//   §10.6  Empty dirty-set returns fromCursor unchanged
//   §10.7  Session observes multiple tables
//   §10.8  Audit event delta: only new audit events after watermark replicated
//   §10.9  Abort-then-retry: aborted session restores dirty keys so the next run re-syncs them
//   §10.10 Keys dirtied during a failed run survive alongside restored keys from the abort
//   §10.B  Blob propagation via incremental replication (including SQLite observer and abort-retry)

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
// @testable import for dirtySet (internal) and DirtySet.accumulate/count inspection.
@testable import PersistenceKitReplication

// MARK: - Synthetic schema

private enum IncSyntheticSchema {
    static let kitID = "IncrementalReplicationTestKit"
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
                .timestamp("tombstoned_at", nullable: true),
            ],
            primaryKey: ["id"],
            generatedColumns: [
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
            primaryKey: ["topic_id", "seq"],
            appendOnly: true
        )
    }
}

// MARK: - Storage factories

private func makeInMemory(estateID: UUID = UUID()) async throws -> InMemoryStorage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: estateID,
        backend: .inMemory
    ))
    try await storage.open(schema: IncSyntheticSchema.declaration)
    return storage
}

private func makeSQLite(estateID: UUID = UUID()) async throws -> (SQLiteStorage, URL) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("inc-replication-test-\(UUID().uuidString).sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: estateID,
        backend: .sqlite(url: url)
    ))
    try await storage.open(schema: IncSyntheticSchema.declaration)
    return (storage, url)
}

private func removeSQLite(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

// MARK: - Row fixtures

private func itemRow(
    id: UUID = UUID(),
    adjectiveBitmap: Int64 = 0b0101,
    payload: Data = Data([0xDE, 0xAD])
) -> [String: TypedValue] {
    [
        "id": .uuid(id),
        "adjective_bitmap": .bitmap(adjectiveBitmap),
        "payload": .blob(payload),
        "tombstoned_at": .null,
    ]
}

private func eventRow(topicID: UUID, seq: Int64, hlc: HLC, content: String = "evt") -> [String: TypedValue] {
    [
        "topic_id": .uuid(topicID),
        "seq": .int(seq),
        "hlc_stamp": .hlc(hlc),
        "content": .text(content),
    ]
}

private func makeAuditEvent(estateID: UUID, rowID: UUID, physicalTime: Int64) -> AuditEvent {
    AuditEvent(
        eventID: UUID(),
        estateUuid: estateID,
        rowId: rowID,
        hlc: HLC(physicalTime: physicalTime, logicalCount: 0, nodeID: 1),
        verb: "capture",
        beforeBitmaps: nil,
        afterBitmaps: (adjective: 0, operational: 0, provenance: 0),
        beforeLatticeAnchor: nil,
        afterLatticeAnchor: LatticeAnchor(udcCode: 0, qidPointer: 0),
        actor: "test"
    )
}

// MARK: - §10 Incremental Replication Tests

/// Poll `condition` up to ~5 s (50 × 100 ms) rather than waiting one fixed
/// interval for the observer AsyncStream to drain into the dirty-set.
/// `observe()` registers synchronously, but delivery runs on a detached task,
/// and under the parallel full-lane's load that task can land past any single
/// fixed sleep — the flake class fixed in 9629d17a (ObserverSink) and 14d4dc4a
/// (PK-TEST-01). Returns as soon as the condition holds; the trailing
/// assertion then confirms it (and reports the real value if it never did).
private func pollObserver(_ condition: () async -> Bool) async throws {
    for _ in 0..<50 where !(await condition()) {
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
    }
}


@Suite("IncrementalReplicationTests")
struct IncrementalReplicationTests {

    // MARK: - §10.1 Only dirty rows replicated

    /// §10.1 — Only dirty rows replicated.
    ///
    /// Strategy:
    ///   1. Full-flush 100 rows to destination (baseline).
    ///   2. Start session after baseline (observer fires only on future writes).
    ///   3. Update exactly 3 rows — those 3 are dirtied by the observer.
    ///   4. Incremental sync → exactly 3 rows written to destination.
    ///
    /// This confirms that incremental sync writes only the dirty-set, not all 100 rows.
    @Test func onlyDirtyRowsReplicated() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Insert 100 rows. No session yet — these don't go into the dirty-set.
        var allIDs: [UUID] = []
        for _ in 0..<100 {
            let id = UUID()
            allIDs.append(id)
            _ = try await source.rowStore.upsert(
                table: "items",
                values: itemRow(id: id),
                conflictColumns: ["id"]
            )
        }

        // Full-flush all 100 to destination as the baseline. Session starts AFTER
        // this flush so the 100 inserts are not in the dirty-set.
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 100, "Baseline full flush should copy all 100 rows")

        // Start the incremental session. Only writes AFTER this point are tracked.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Update exactly 3 rows — these 3 become dirty.
        let dirtyIDs = Array(allIDs.prefix(3))
        for id in dirtyIDs {
            _ = try await source.rowStore.upsert(
                table: "items",
                values: itemRow(id: id, adjectiveBitmap: 0b1111, payload: Data([0xFF])),
                conflictColumns: ["id"]
            )
        }

        // Allow the observer AsyncStream to deliver the 3 update events.
        try await pollObserver { await session.dirtySet.count() >= 3 }

        // Incremental sync — should write exactly 3 rows.
        let incCursor = try await session.sync(
            from: source,
            to: destination,
            fromCursor: fullCursor
        )
        #expect(incCursor.rowsWritten == 3, "Incremental sync must write only the 3 dirty rows")

        // Destination total must still be 100 rows (updates, not inserts).
        let dstCount = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCount == 100, "Destination should still have 100 rows")

        // The 3 dirtied rows must have updated values.
        for id in dirtyIDs {
            let rows = try await destination.rowStore.query(
                table: "items",
                where: .eq(Column(table: "items", name: "id"), .uuid(id)),
                orderBy: [], limit: nil, offset: nil
            )
            #expect(rows.count == 1)
            #expect(rows[0]["adjective_bitmap"] == .bitmap(0b1111),
                    "Dirty row \(id) should have updated adjective_bitmap")
        }
    }

    // MARK: - §10.2 Delete propagation

    /// §10.2 — Delete a row on source → destination deletes it on next incremental sync.
    ///
    /// When the session observes a delete event, the DirtySet accumulates the PK.
    /// The re-scan finds no matching row (it was deleted), so a delete is issued on
    /// the destination.
    @Test func deletePropagation() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Insert and full-flush one row to get it into destination.
        let rowID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID),
            conflictColumns: ["id"]
        )
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 1)

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Verify destination has the row.
        let countBefore = try await destination.rowStore.count(table: "items", where: nil)
        #expect(countBefore == 1)

        // Delete from source. Observer fires delete event, dirtying the PK.
        _ = try await source.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )

        // Allow observer to deliver the delete event.
        try await pollObserver { await session.dirtySet.count() >= 1 }

        // Sync — re-scan finds no row → delete issued to destination.
        let delCursor = try await session.sync(
            from: source,
            to: destination,
            fromCursor: fullCursor
        )
        // rowsWritten includes the delete operation.
        #expect(delCursor.rowsWritten == 1, "Delete sync should record 1 operation")

        // Destination row must be gone.
        let countAfter = try await destination.rowStore.count(table: "items", where: nil)
        #expect(countAfter == 0, "Destination must not have the deleted row")
    }

    // MARK: - §10.3 Restart-resume from watermark

    /// §10.3 — Process restart: new session with saved cursor, only new audit events sent.
    ///
    /// Session 1 syncs rows + audit events and produces watermark W1.
    /// After session 1 is discarded (simulating restart), session 2 starts.
    /// A new row + audit event are added AFTER W1.
    /// Session 2 sync delivers only the new row and new audit event.
    @Test func restartResumeFromWatermark() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()
        let estateID = source.configuration.estateID

        // Session 1: insert row, audit event, full-flush baseline to destination.
        let id1 = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: id1),
            conflictColumns: ["id"]
        )
        let auditEvent1 = makeAuditEvent(estateID: estateID, rowID: id1, physicalTime: 1_000)
        try await source.auditLog.append(auditEvent1)

        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        // The watermark from the full flush includes auditEvent1's HLC.
        let capturedWatermark = fullCursor.hlcWatermark
        #expect(capturedWatermark != nil, "Watermark should be non-nil after flush with audit events")

        // Session 2: new session using full-flush cursor as starting watermark.
        // This simulates a restart — the previous session's dirty-set is gone but
        // the cursor (watermark) was persisted by the caller.
        let session2 = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Insert a new row and a new audit event with HLC strictly AFTER the watermark.
        let id2 = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: id2, adjectiveBitmap: 0b1010),
            conflictColumns: ["id"]
        )
        let auditEvent2 = makeAuditEvent(estateID: estateID, rowID: id2, physicalTime: 2_000)
        try await source.auditLog.append(auditEvent2)

        try await pollObserver { await session2.dirtySet.count() >= 1 }

        let cursor2 = try await session2.sync(from: source, to: destination, fromCursor: fullCursor)

        // Only the new row and new audit event should be synced.
        #expect(cursor2.rowsWritten == 1, "Second session should sync only the new row")
        // Only auditEvent2 (after the watermark) should be sent.
        #expect(cursor2.auditEventsWritten == 1,
                "Second session should sync only the new audit event (after watermark)")

        // Destination must have both rows.
        let dstCount = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCount == 2, "Destination must have both rows after restart + incremental sync")

        // Destination must have both audit events (auditEvent1 was there from baseline).
        let dstAuditCount = try await destination.auditLog.count()
        #expect(dstAuditCount == 2, "Destination must have both audit events")
    }

    // MARK: - §10.4 Corrupt-value abort

    /// §10.4 — Corrupt a dirty row's non-PK column via raw SQL → sync throws, no partial commit.
    ///
    /// We corrupt the `tombstoned_at` column (a non-PK timestamp column) by writing
    /// a non-ISO8601 string. The row is found by PK, but parsing the corrupt timestamp
    /// fires StorageError.corruptStoredValue, which aborts the sync. (The
    /// `adjective_bitmap` bitmap column is not used because the bitmap type tolerates
    /// SQLITE_TEXT without throwing — only UUID and timestamp columns enforce the
    /// parse-or-throw contract in readColumn.)
    ///
    /// The destination transaction rolls back, leaving it in its last clean state.
    @Test func corruptValueAbortsSyncWithNoPartialCommit() async throws {
        let (source, sourceURL) = try await makeSQLite()
        let destination = try await makeInMemory()
        defer { removeSQLite(at: sourceURL) }

        // Insert two rows: one clean, one that will be corrupted.
        let cleanID = UUID()
        let corruptID = UUID()

        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: cleanID, adjectiveBitmap: 0b0001),
            conflictColumns: ["id"]
        )
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: corruptID, adjectiveBitmap: 0b0010),
            conflictColumns: ["id"]
        )

        // Baseline full-flush: both rows in destination.
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 2)

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Corrupt the tombstoned_at column of corruptID row via raw SQLite.
        // Write a non-ISO8601 string into a timestamp column. PersistenceKit reads
        // timestamp columns as SQLITE_TEXT and parses them as ISO-8601; a
        // non-parseable value fires StorageError.corruptStoredValue.
        // (We use tombstoned_at rather than adjective_bitmap because the bitmap
        //  type reads SQLITE_TEXT as .text without throwing — only UUID and timestamp
        //  columns enforce the parse-or-throw contract in readColumn.)
        let db = try SQLiteDirectWriter(url: sourceURL)
        // UUIDs are stored uppercase in the kit (UUID.uuidString is uppercase).
        // Use UPPER() to match case-insensitively, or use the uppercase form directly.
        try db.exec(
            "UPDATE items SET tombstoned_at = 'not-a-timestamp' WHERE id = '\(corruptID.uuidString)'"
        )
        db.close()

        // Manually dirty the corruptID row in the session's dirty-set by synthesising
        // the TableChange that an observer would have emitted for an update on that row.
        // This bypasses the observer (which didn't see the raw SQL write) and directly
        // marks the row for re-scan, which is exactly the scenario we want to test.
        let syntheticChange = TableChange(
            table: "items",
            event: .update,
            rowKey: nil,
            values: ["id": .uuid(corruptID), "adjective_bitmap": .bitmap(0b0011)],
            hlc: nil
        )
        await session.dirtySet.accumulate(syntheticChange)

        // Sync must throw because re-scanning the corrupt row produces a decode error.
        var syncThrew = false
        do {
            _ = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        } catch {
            // The error is StorageError.corruptStoredValue or a wrapped ReplicationError.
            syncThrew = true
        }
        #expect(syncThrew, "Sync must throw when a dirty row read encounters a corrupt value")

        // Destination must still have exactly 2 rows — the transaction rolled back.
        let dstCountAfter = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCountAfter == 2, "Destination must be unchanged after failed incremental sync")
    }

    // MARK: - §10.5 Full-snapshot path unchanged

    /// §10.5 — Full snapshot still works alongside an active incremental session.
    @Test func fullSnapshotPathUnchangedBesideSession() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Start session first (will accumulate the inserts below).
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Insert 5 rows.
        for _ in 0..<5 {
            _ = try await source.rowStore.upsert(
                table: "items",
                values: itemRow(),
                conflictColumns: ["id"]
            )
        }

        // Full flush — independent of session, copies all 5 rows.
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 5)

        let dstCountAfterFull = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCountAfterFull == 5)

        // Subsequent full flush is idempotent (no duplicates).
        let fullCursor2 = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor2.rowsWritten == 5)
        let dstCountAfterFull2 = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCountAfterFull2 == 5, "Second full flush must not duplicate rows")

        // Session still usable after full flush.
        let _ = session
    }

    // MARK: - §10.6 Empty dirty-set returns cursor unchanged

    /// §10.6 — When the dirty-set is empty, sync returns the fromCursor unchanged.
    @Test func emptyDirtySetReturnsCursorUnchanged() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        let hlc = HLC(physicalTime: 42_000, logicalCount: 7, nodeID: 3)
        let inputCursor = ReplicationCursor(hlcWatermark: hlc, rowsWritten: 17, auditEventsWritten: 5)

        // No writes → empty dirty-set.
        let outputCursor = try await session.sync(from: source, to: destination, fromCursor: inputCursor)

        #expect(outputCursor.hlcWatermark == hlc, "Empty sync must return the input watermark")
        #expect(outputCursor.rowsWritten == 17, "Empty sync must return the input rowsWritten")
        #expect(outputCursor.auditEventsWritten == 5, "Empty sync must return the input auditEventsWritten")
    }

    // MARK: - §10.7 Session observes multiple tables

    /// §10.7 — Session subscribes to all schema-declared tables, accumulating dirty keys
    /// from each one independently.
    @Test func sessionObservesMultipleTables() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Insert one item row (items table) and one event row (events table).
        let itemID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: itemID),
            conflictColumns: ["id"]
        )

        let topicID = UUID()
        let hlc = HLC(physicalTime: 5_000, logicalCount: 0, nodeID: 1)
        _ = try await source.rowStore.upsert(
            table: "events",
            values: eventRow(topicID: topicID, seq: 1, hlc: hlc),
            conflictColumns: ["topic_id", "seq"]
        )

        // Allow observer to deliver both events.
        try await pollObserver { await session.dirtySet.count() >= 2 }

        let dirtyCount = await session.dirtySet.count()
        // Both tables should have contributed a dirty key.
        #expect(dirtyCount == 2, "Session should have 2 dirty keys: 1 item + 1 event, got \(dirtyCount)")

        let zeroCursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        let cursor = try await session.sync(from: source, to: destination, fromCursor: zeroCursor)
        #expect(cursor.rowsWritten == 2, "Sync should write one item row and one event row")

        let dstItemCount = try await destination.rowStore.count(table: "items", where: nil)
        let dstEventCount = try await destination.rowStore.count(table: "events", where: nil)
        #expect(dstItemCount == 1)
        #expect(dstEventCount == 1)
    }

    // MARK: - §10.8 Audit event delta

    /// §10.8 — Only audit events after the watermark are sent on incremental sync.
    ///
    /// iterate(after:) is an exclusive lower bound: events with HLC > watermark.
    /// Events at or below the watermark were delivered in a previous sync.
    @Test func auditEventDeltaOnlyNewEventsAfterWatermark() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()
        let estateID = source.configuration.estateID

        // Append 2 audit events and insert a row; full-flush as baseline.
        let event1 = makeAuditEvent(estateID: estateID, rowID: UUID(), physicalTime: 1_000)
        let event2 = makeAuditEvent(estateID: estateID, rowID: UUID(), physicalTime: 2_000)
        try await source.auditLog.appendBatch([event1, event2])

        let id1 = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: id1),
            conflictColumns: ["id"]
        )

        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        let dstAuditAfterFull = try await destination.auditLog.count()
        #expect(dstAuditAfterFull == 2, "Baseline flush should deliver both initial audit events")

        // Start incremental session AFTER baseline.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Append a third event with HLC strictly after fullCursor's watermark.
        let event3 = makeAuditEvent(estateID: estateID, rowID: UUID(), physicalTime: 3_000)
        try await source.auditLog.append(event3)

        // Insert another row so the dirty-set is non-empty (sync requires dirty rows to proceed).
        let id2 = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: id2, adjectiveBitmap: 0b1000),
            conflictColumns: ["id"]
        )
        try await pollObserver { await session.dirtySet.count() >= 1 }

        // Incremental sync: only event3 should be sent (events 1 and 2 are before the watermark).
        let cursor2 = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        #expect(cursor2.auditEventsWritten == 1,
                "Incremental sync should deliver only the new audit event (after watermark)")

        // Destination must have all 3 audit events total.
        let dstAuditCount2 = try await destination.auditLog.count()
        #expect(dstAuditCount2 == 3, "Destination must have all 3 audit events after incremental sync")

        // appendBatch is idempotent on (eventID, hlc): re-delivering events 1+2 would not
        // create duplicates, but we verify the incremental path only sends event3.
        // (Idempotence is tested separately in §9.2.)
    }

    // MARK: - §10.9 Abort-then-retry restores dirty keys

    /// §10.9 — Abort-then-retry: corrupt a dirty row, sync throws, fix the corruption,
    /// retry sync succeeds and the SAME rows replicate.
    ///
    /// This is the gate-return criterion from commit 654418f7:
    ///   1. Dirty corruptID (raw SQL corrupt).
    ///   2. sync throws (destination clean, rolls back).
    ///   3. After throw, dirtySet still contains corruptID (keys were restored).
    ///   4. Fix the corruption via raw SQL.
    ///   5. retry sync → corruptID replicates successfully.
    @Test func abortThenRetryRestoresDirtyKeys() async throws {
        let (source, sourceURL) = try await makeSQLite()
        let destination = try await makeInMemory()
        defer { removeSQLite(at: sourceURL) }

        // Insert two rows: one clean (cleanID), one that will be corrupted (corruptID).
        let cleanID = UUID()
        let corruptID = UUID()

        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: cleanID, adjectiveBitmap: 0b0001),
            conflictColumns: ["id"]
        )
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: corruptID, adjectiveBitmap: 0b0010),
            conflictColumns: ["id"]
        )

        // Baseline full-flush: both rows in destination.
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 2)

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Corrupt the tombstoned_at column of corruptID via raw SQL.
        let db = try SQLiteDirectWriter(url: sourceURL)
        try db.exec(
            "UPDATE items SET tombstoned_at = 'not-a-timestamp' WHERE id = '\(corruptID.uuidString)'"
        )
        db.close()

        // Manually dirty corruptID in the session by injecting the synthetic change.
        let syntheticChange = TableChange(
            table: "items",
            event: .update,
            rowKey: nil,
            values: ["id": .uuid(corruptID), "adjective_bitmap": .bitmap(0b0011)],
            hlc: nil
        )
        await session.dirtySet.accumulate(syntheticChange)

        // --- First sync attempt must throw. ---
        var syncThrew = false
        do {
            _ = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        } catch {
            syncThrew = true
        }
        #expect(syncThrew, "Sync must throw when a dirty row read encounters a corrupt value")

        // Destination unchanged after the failed sync (transaction rolled back).
        let dstCountAfterAbort = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCountAfterAbort == 2, "Destination must be unchanged after failed incremental sync")

        // Dirty-set must still contain corruptID — the restore is AWAITED inside
        // sync's catch, so it is complete the instant the throw reaches us. NO
        // sleep: an immediate inspection (and immediate retry below) IS the race
        // regression test for the fire-and-forget restore bug.
        let dirtyCountAfterAbort = await session.dirtySet.count()
        #expect(dirtyCountAfterAbort >= 1,
                "Dirty-set must still contain the failed key after abort, got \(dirtyCountAfterAbort)")

        // --- Fix the corruption via raw SQL. ---
        let db2 = try SQLiteDirectWriter(url: sourceURL)
        try db2.exec(
            "UPDATE items SET tombstoned_at = NULL WHERE id = '\(corruptID.uuidString)'"
        )
        db2.close()

        // --- Retry sync must succeed and replicate corruptID. ---
        let retryCursor = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        #expect(retryCursor.rowsWritten >= 1,
                "Retry sync must replicate at least the previously-failed row, got \(retryCursor.rowsWritten)")

        // corruptID must now have been replicated to destination with correct values.
        let rows = try await destination.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(corruptID)),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1, "corruptID must be present in destination after retry")
    }

    // MARK: - §10.10 Keys dirtied during failed run survive alongside restored keys

    /// §10.10 — Keys dirtied DURING a failed sync run survive in the dirty-set alongside
    /// the restored drained keys. Neither overwrites the other.
    ///
    /// Setup:
    ///   - Dirty rowA before the (failed) sync → it is drained and then restored.
    ///   - Dirty rowB to simulate a change that arrives during the failed run.
    ///     In practice we inject rowB AFTER the first failed sync returns (not
    ///     truly concurrent); the restore has union semantics so the injection
    ///     order relative to the restore does not affect correctness.
    ///   - After the abort, both rowA and rowB must be in the dirty-set.
    ///
    /// Because the async observer tasks run concurrently, we simulate "dirtied during
    /// failed run" by injecting a synthetic change AFTER the first failed sync returns
    /// (the restore has union semantics so the order of injection relative to the
    /// restore does not affect correctness — both keys end up in the set).
    @Test func keysDirtiedDuringFailedRunSurviveAlongsideRestoredKeys() async throws {
        let (source, sourceURL) = try await makeSQLite()
        let destination = try await makeInMemory()
        defer { removeSQLite(at: sourceURL) }

        let rowAID = UUID()
        let rowBID = UUID()

        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowAID, adjectiveBitmap: 0b0001),
            conflictColumns: ["id"]
        )
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowBID, adjectiveBitmap: 0b0010),
            conflictColumns: ["id"]
        )

        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 2)

        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Corrupt rowA via raw SQL.
        let db = try SQLiteDirectWriter(url: sourceURL)
        try db.exec(
            "UPDATE items SET tombstoned_at = 'bad-stamp' WHERE id = '\(rowAID.uuidString)'"
        )
        db.close()

        // Dirty rowA (the corrupt one) so the first sync attempt fails.
        let changeA = TableChange(
            table: "items",
            event: .update,
            rowKey: nil,
            values: ["id": .uuid(rowAID), "adjective_bitmap": .bitmap(0b1111)],
            hlc: nil
        )
        await session.dirtySet.accumulate(changeA)

        // First sync throws on rowA.
        do {
            _ = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        } catch {
            // Expected — rowA is corrupt.
        }

        // No sleep: restore completed before the catch released the throw.
        // Inject rowB as "dirtied during the failed run" — simulates an observer event
        // that fired while the sync was in flight or between drain and restore.
        let changeB = TableChange(
            table: "items",
            event: .update,
            rowKey: nil,
            values: ["id": .uuid(rowBID), "adjective_bitmap": .bitmap(0b1010)],
            hlc: nil
        )
        await session.dirtySet.accumulate(changeB)

        // Both rowA and rowB must be in the dirty-set: rowA restored, rowB newly dirtied.
        let dirtyCount = await session.dirtySet.count()
        #expect(dirtyCount == 2,
                "Dirty-set must contain both the restored key (rowA) and the new key (rowB), got \(dirtyCount)")

        // Fix rowA's corruption.
        let db2 = try SQLiteDirectWriter(url: sourceURL)
        try db2.exec(
            "UPDATE items SET tombstoned_at = NULL WHERE id = '\(rowAID.uuidString)'"
        )
        db2.close()

        // Update rowB on source so it has a new value to replicate.
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowBID, adjectiveBitmap: 0b1010),
            conflictColumns: ["id"]
        )

        // Retry must succeed and replicate both rowA and rowB.
        let retryCursor = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        #expect(retryCursor.rowsWritten == 2,
                "Retry must replicate both rowA and rowB, got \(retryCursor.rowsWritten)")
    }

    // MARK: - §10.B Blob propagation via incremental replication

    /// §10.B1 — Blob write propagates on next incremental sync, byte-identical.
    ///
    /// Start session, put a blob, sync → blob arrives at destination.
    @Test func incrementalBlobWritePropagates() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Put a blob on source. Observer fires put event.
        let blobKey = "incremental-blob-key"
        let blobBytes = Data([0xFE, 0xED, 0xFA, 0xCE])
        try await source.blobStore.put(key: blobKey, bytes: blobBytes)

        // Also insert a row so the dirty-set has something (sync requires non-empty).
        let rowID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID),
            conflictColumns: ["id"]
        )

        // Allow observer to deliver events.
        try await pollObserver {
            let blobs = await session.blobDirtySet.count()
            let rows = await session.dirtySet.count()
            return blobs >= 1 && rows >= 1
        }

        let zeroCursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        let cursor = try await session.sync(from: source, to: destination, fromCursor: zeroCursor)
        #expect(cursor.blobsWritten >= 1, "Incremental sync must propagate the blob put")

        let result = try await destination.blobStore.get(key: blobKey)
        #expect(result == blobBytes, "Blob at destination must be byte-identical to source")
    }

    /// §10.B2 — Blob delete propagates on next incremental sync.
    @Test func incrementalBlobDeletePropagates() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Pre-populate blob on both source and destination (simulates prior full flush).
        let blobKey = "delete-me-blob"
        let blobBytes = Data([0x11, 0x22, 0x33])
        try await source.blobStore.put(key: blobKey, bytes: blobBytes)
        try await destination.blobStore.put(key: blobKey, bytes: blobBytes)

        // Start session after pre-population.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Delete the blob from source. Observer fires delete event.
        try await source.blobStore.delete(key: blobKey)

        // Insert a row to make dirty-set non-empty.
        let rowID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID),
            conflictColumns: ["id"]
        )

        try await pollObserver {
            let blobs = await session.blobDirtySet.count()
            let rows = await session.dirtySet.count()
            return blobs >= 1 && rows >= 1
        }

        let zeroCursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        let cursor = try await session.sync(from: source, to: destination, fromCursor: zeroCursor)
        #expect(cursor.blobsWritten >= 1, "Incremental sync must propagate the blob delete")

        let result = try await destination.blobStore.get(key: blobKey)
        #expect(result == nil, "Deleted blob must be absent from destination after sync")
    }

    // MARK: - §10.B4 SQLite backend emits real blob change events

    /// §10.B4 — SQLiteObserver.observeBlobs() delivers live BlobChange events.
    ///
    /// Verifies that the SQLite backend emits real incremental blob events after
    /// putBlob and deleteBlob, rather than returning an empty stream.
    ///
    /// MECHANISM: putBlob/deleteBlob in SQLiteBackend call
    /// registry.notifyBlob(_:) after each successful write. observeBlobs()
    /// registers into the registry's blob-subscriber list and delivers those
    /// notifications as a live async stream.
    @Test func sqliteObserverDeliversRealBlobChangeEvents() async throws {
        let (source, sourceURL) = try await makeSQLite()
        let destination = try await makeInMemory()
        defer { removeSQLite(at: sourceURL) }

        // Start session so blob observer is live before any blobs are written.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Put a blob — the SQLite backend must emit a put event to the registry.
        let blobKey = "sqlite-obs-blob"
        let blobBytes = Data([0x01, 0x02, 0x03, 0x04])
        try await source.blobStore.put(key: blobKey, bytes: blobBytes)

        // Also insert a row so the row dirty-set is non-empty.
        let rowID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID),
            conflictColumns: ["id"]
        )

        // Allow the observer tasks to deliver the events.
        try await pollObserver {
            let blobs = await session.blobDirtySet.count()
            let rows = await session.dirtySet.count()
            return blobs >= 1 && rows >= 1
        }

        // Blob dirty-set must contain the put event — proving the SQLite backend
        // emitted a real event rather than an empty stream.
        let blobCountAfterPut = await session.blobDirtySet.count()
        #expect(blobCountAfterPut >= 1,
                "SQLite blob observer must deliver the put event (got \(blobCountAfterPut))")

        // Sync — blob must replicate to destination.
        let zeroCursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        let cursor = try await session.sync(from: source, to: destination, fromCursor: zeroCursor)
        #expect(cursor.blobsWritten >= 1, "Incremental sync on SQLite must propagate the blob put")

        let got = try await destination.blobStore.get(key: blobKey)
        #expect(got == blobBytes, "Blob at destination must be byte-identical to source")

        // Now delete the blob — must emit a delete event.
        try await source.blobStore.delete(key: blobKey)
        try await pollObserver { await session.blobDirtySet.count() >= 1 }

        // Also dirty a row so sync proceeds.
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID, adjectiveBitmap: 0b1111),
            conflictColumns: ["id"]
        )
        try await pollObserver { await session.dirtySet.count() >= 1 }

        let cursor2 = try await session.sync(from: source, to: destination, fromCursor: cursor)
        #expect(cursor2.blobsWritten >= 1, "Incremental sync on SQLite must propagate the blob delete")

        let gone = try await destination.blobStore.get(key: blobKey)
        #expect(gone == nil, "Deleted blob must be absent from destination after sync")
    }

    // MARK: - §10.B5 Real-abort restores dirty blob keys (SQLite)

    /// §10.B5 — A real sync failure (corrupt row) AFTER blob ops are drained from the
    /// BlobDirtySet restores both the row dirty-set and the blob dirty-set before
    /// rethrowing. A subsequent retry replicates the same blob ops.
    ///
    /// This is the mirror of the row-side §10.9 abort-then-retry test (abortThenRetryRestoresDirtyKeys).
    /// It proves the REAL restore path: the blob accumulator is drained before any fallible
    /// work; if the sync aborts (here: a corrupt row causes snapshotDirtyRows to throw), the
    /// drained blob ops are restored in the same catch that restores the row dirty-set, BEFORE
    /// the error is rethrown. The retry picks up both the row and the blob from the restored sets.
    @Test func realAbortRestoresDirtyBlobsAlongsideRows() async throws {
        let (source, sourceURL) = try await makeSQLite()
        let destination = try await makeInMemory()
        defer { removeSQLite(at: sourceURL) }

        // Insert a row that will be corrupted after the session starts.
        let corruptID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: corruptID, adjectiveBitmap: 0b0001),
            conflictColumns: ["id"]
        )

        // Full-flush baseline — destination gets the clean row.
        let fullCursor = try await StorageReplicator.flush(
            from: source,
            into: destination,
            schema: IncSyntheticSchema.declaration
        )
        #expect(fullCursor.rowsWritten == 1)

        // Start session AFTER baseline — blob and row observers are now live.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Put a blob on source — SQLite backend emits the event to blobDirtySet.
        let blobKey = "real-abort-blob"
        let blobBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        try await source.blobStore.put(key: blobKey, bytes: blobBytes)

        // Allow the blob observer task to deliver the event.
        try await pollObserver { await session.blobDirtySet.count() >= 1 }

        let blobCountBeforeAbort = await session.blobDirtySet.count()
        #expect(blobCountBeforeAbort >= 1,
                "BlobDirtySet must have the put event before the abort (got \(blobCountBeforeAbort))")

        // Corrupt the row via raw SQL so the re-scan throws.
        let db = try SQLiteDirectWriter(url: sourceURL)
        try db.exec(
            "UPDATE items SET tombstoned_at = 'bad-date' WHERE id = '\(corruptID.uuidString)'"
        )
        db.close()

        // Dirty the corrupt row via a synthetic change so sync picks it up.
        let syntheticChange = TableChange(
            table: "items",
            event: .update,
            rowKey: nil,
            values: ["id": .uuid(corruptID), "adjective_bitmap": .bitmap(0b1111)],
            hlc: nil
        )
        await session.dirtySet.accumulate(syntheticChange)

        // --- First sync must throw on the corrupt row. ---
        // The sync path is: drain blobDirtySet → drain dirtySet → snapshotDirtyRows (throws here)
        // → catch → restore(dirtyKeys) AND restore(dirtyBlobs) → rethrow.
        var syncThrew = false
        do {
            _ = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        } catch {
            syncThrew = true
        }
        #expect(syncThrew, "Sync must throw when the dirty row read encounters a corrupt value")

        // Destination must be unchanged (transaction rolled back).
        let dstCountAfterAbort = try await destination.rowStore.count(table: "items", where: nil)
        #expect(dstCountAfterAbort == 1, "Destination must be unchanged after the failed sync")

        let blobAfterAbort = try await destination.blobStore.get(key: blobKey)
        #expect(blobAfterAbort == nil, "Blob must not be in destination after the failed sync")

        // Blob dirty-set must have been restored — the blob op was drained and then
        // restored in the same catch that restored the row dirty-set. No sleep: the
        // restore is AWAITED inside sync before the throw reaches us.
        let blobCountAfterAbort = await session.blobDirtySet.count()
        // RETRY-PRESERVATION: blobs and rows are restored in the same catch, atomically.
        // If this count is 0 the restore contract is broken — retry would silently drop blobs.
        #expect(blobCountAfterAbort >= 1,
                "BlobDirtySet must be restored after abort; retry-preservation contract requires blobs and rows restored together (got \(blobCountAfterAbort))")

        // Row dirty-set must also still contain the corrupt key.
        let rowCountAfterAbort = await session.dirtySet.count()
        #expect(rowCountAfterAbort >= 1,
                "Row dirty-set must be restored after abort (got \(rowCountAfterAbort))")

        // Fix the corruption.
        let db2 = try SQLiteDirectWriter(url: sourceURL)
        try db2.exec(
            "UPDATE items SET tombstoned_at = NULL WHERE id = '\(corruptID.uuidString)'"
        )
        db2.close()

        // --- Retry sync must succeed and replicate BOTH the row and the blob. ---
        let retryCursor = try await session.sync(from: source, to: destination, fromCursor: fullCursor)
        #expect(retryCursor.rowsWritten >= 1,
                "Retry must replicate the previously-failed row (got \(retryCursor.rowsWritten))")
        #expect(retryCursor.blobsWritten >= 1,
                "Retry must replicate the blob that was drained-then-restored (got \(retryCursor.blobsWritten))")

        // Verify the blob is now at destination, byte-identical.
        let blobAfterRetry = try await destination.blobStore.get(key: blobKey)
        #expect(blobAfterRetry == blobBytes,
                "Blob must be byte-identical at destination after retry sync")
    }

    /// §10.B3 — Abort-then-retry restores dirty blob keys: blob appears after retry.
    ///
    /// Simulates a failed sync by manually draining and restoring the blob dirty-set,
    /// then verifying a clean sync propagates the blob.
    @Test func abortThenRetryRestoresDirtyBlobKeys() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let session = IncrementalReplicationSession.start(
            source: source,
            schema: IncSyntheticSchema.declaration
        )

        // Put a blob on source.
        let blobKey = "retry-blob"
        let blobBytes = Data([0xAB, 0xCD, 0xEF])
        try await source.blobStore.put(key: blobKey, bytes: blobBytes)

        // Insert a row to make dirty-set non-empty.
        let rowID = UUID()
        _ = try await source.rowStore.upsert(
            table: "items",
            values: itemRow(id: rowID),
            conflictColumns: ["id"]
        )

        try await pollObserver { await session.blobDirtySet.count() >= 1 }

        // Drain the blob dirty-set, simulating a failed sync drain.
        let drained = await session.blobDirtySet.drain()
        #expect(drained.count >= 1, "Blob dirty-set must contain the put event")

        // Verify blob is absent from destination (sync hasn't run).
        let beforeRetry = try await destination.blobStore.get(key: blobKey)
        #expect(beforeRetry == nil, "Blob must not be in destination before sync")

        // Restore the drained blobs (simulates retry-preservation).
        await session.blobDirtySet.restore(drained)
        let countAfterRestore = await session.blobDirtySet.count()
        #expect(countAfterRestore >= 1, "Blob dirty-set must still contain the key after restore")

        // Clean sync — blob must propagate.
        let zeroCursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        let cursor = try await session.sync(from: source, to: destination, fromCursor: zeroCursor)
        #expect(cursor.blobsWritten >= 1, "Retry sync must replicate the blob")

        let afterRetry = try await destination.blobStore.get(key: blobKey)
        #expect(afterRetry == blobBytes, "Blob must be byte-identical at destination after retry sync")
    }
}

// MARK: - SQLiteDirectWriter helper (corruption and retry tests)

/// Minimal synchronous SQLite writer used by the corruption and retry tests
/// (§10.4, §10.9, §10.10, §10.B5, §10.B3).
/// Opens the database file directly, executes a raw SQL statement, and closes.
/// This bypasses the PersistenceKit layer intentionally — corruption is the point.
private final class SQLiteDirectWriter {
    private var db: OpaquePointer?

    init(url: URL) throws {
        let code = sqlite3_open(url.path, &db)
        guard code == SQLITE_OK else {
            throw TestError.sqliteOpen(code: code)
        }
    }

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>? = nil
        let code = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if code != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw TestError.sqliteExec(sql: sql, message: msg)
        }
    }

    func close() { sqlite3_close(db) }
}

import SQLCipher

private enum TestError: Error {
    case sqliteOpen(code: Int32)
    case sqliteExec(sql: String, message: String)
}
