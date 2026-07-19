// OutboxStore.swift
//
// Durable operations on the _ck_outbox side table.
//
// OutboxStore is transport-agnostic: it knows how to persist, coalesce, read,
// confirm, park, and retry outbox entries, but it does not know about CloudKit,
// CKRecord, or any other transport detail. The push cycle (PushCycle.swift in
// the CloudKit target) owns the transport seam.
//
// COALESCING RULE:
// Multiple changes to the same (table_name, row_key) collapse to the entry
// with the highest packed HLC. Rationale: the outbox is a queue of net
// changes, not a history. If a row is inserted and then updated before the
// next push, only the update needs to be sent — the insert is subsumed. If a
// row is inserted and then deleted, only the delete needs to be sent. The
// coalescing bounds hot-row growth in high-write workloads.
//
// PER-RECORD PUSH RESULTS (R6, CVK-ICLOUD P1-M6):
// PushCycle.push() now consumes the per-record result dictionaries from
// modifyRecords(atomically:false) and classifies each result via CKErrorTaxonomy.
// confirm(ids:from:) removes successfully pushed entries; park(id:from:) marks
// permanently-failed entries as is_parked=1 (excluded from readBatch);
// incrementRetryCount(id:from:) bumps retry_count on retryable failures.
// parkedEntries(from:) exposes parked entries for host-app diagnostics.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - OutboxStore

/// Stateless namespace for durable outbox operations on PersistenceKit storage.
///
/// All functions are static; the storage instance is passed explicitly so the
/// store has no lifecycle coupling. Callers are responsible for ensuring the
/// side schema exists (via `CKSideSchema.ensure(storage:)`) before calling any
/// of these functions.
public enum OutboxStore {

    private static let table = CKSideSchema.outboxTable

    // MARK: - Append with coalescing

    /// Append `entry` to the durable outbox, coalescing with any existing entry
    /// for the same `(tableName, rowKey)`.
    ///
    /// **Coalescing rule (newest-wins by HLC):** if the outbox already holds an
    /// entry for `(entry.tableName, entry.rowKey)` and that entry's `packedHLC`
    /// is strictly less than `entry.packedHLC`, the existing entry is deleted and
    /// `entry` is inserted in its place. If the existing entry's HLC is
    /// greater-or-equal (stale write — should not happen under normal operation,
    /// but guards against clock skew), the append is a no-op and the newer
    /// existing entry is preserved.
    ///
    /// The coalescing key is `(table_name, row_key)`, not the entry's UUID —
    /// each surviving entry carries a fresh UUID minted at its own append time.
    public static func append(entry: OutboxEntry, to storage: any Storage) async throws {
        try await append(entry: entry, to: storage.rowStore)
    }

    /// Transactional variant of `append(entry:to:)`.
    ///
    /// Gap 3 fix: `recordOutbound`'s local-write path calls this overload from
    /// inside an open `storage.transaction { txn in ... }` block so the durable
    /// outbox append commits atomically with the local column-HLC bookkeeping
    /// write (`ColumnHLCStore.writeAll`) that now runs alongside it — closing
    /// the window where a device's own local edit could otherwise be recorded
    /// in the outbox (and shipped to peers) without ever gaining a truthful
    /// local `_ck_sync_meta_cols` baseline, letting a later stale remote edit
    /// clobber it (N1-shaped atomicity guarantee, same as the gap-4 fix).
    public static func append(entry: OutboxEntry, to transaction: any StorageTransaction) async throws {
        try await append(entry: entry, to: transaction.rowStore)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private static func append(entry: OutboxEntry, to rowStore: any RowStore) async throws {
        // Check for an existing entry for the same (table, row_key).
        let existing = try await rowStore.query(
            table: table,
            where: .and([
                .eq(Column(table: table, name: "table_name"), .text(entry.tableName)),
                .eq(Column(table: table, name: "row_key"),    .text(entry.rowKey)),
            ])
        )

        if let existingRow = existing.first {
            // Extract the stored packed HLC.
            guard case .int(let existingHLC) = existingRow["hlc"] else {
                // Corrupt row; delete and replace.
                if case .uuid(let oldID) = existingRow["id"] {
                    _ = try await rowStore.delete(
                        table: table,
                        where: .eq(Column(table: table, name: "id"), .uuid(oldID))
                    )
                }
                try await insertEntry(entry, to: rowStore)
                return
            }

            // Newest-wins: if the stored entry is already newer (or equal), skip.
            if existingHLC >= entry.packedHLC {
                return
            }

            // Incoming is newer: delete the stale entry and insert the new one.
            // For fieldLevelLWW entries, MERGE column HLC maps so that columns
            // present only in the stale entry are not silently discarded.
            //
            // WHY merge rather than replace:
            // The outbox coalesces hot-row writes into a single entry (newest HLC
            // wins). But the "newer" write may cover only a subset of columns
            // written in the "stale" entry. Replacing column HLCs entirely would
            // drop the per-column records for the older-but-not-yet-pushed columns,
            // and the receiver would see an incomplete column HLC map — it would
            // treat the missing columns as "first write" and potentially apply
            // a stale value from a concurrent peer. Merging keeps the highest HLC
            // per column, guaranteeing the CKRecord carries the full column timeline.
            var entryToInsert = entry
            if let existingID = existingRow["id"], case .uuid(let oldID) = existingID {
                // Decode the stale entry's column HLCs, if any.
                let staleColumnHLCsData: Data?
                switch existingRow["column_hlcs"] {
                case .blob(let d): staleColumnHLCsData = d
                default:           staleColumnHLCsData = nil
                }

                if let staleData = staleColumnHLCsData,
                   let incomingData = entry.columnHLCsData,
                   let staleMap = try? JSONDecoder().decode(ColumnHLCMap.self, from: staleData),
                   let incomingMap = try? JSONDecoder().decode(ColumnHLCMap.self, from: incomingData) {
                    // Both entries have column HLC data — merge keeping newest per column.
                    let merged = staleMap.merge(with: incomingMap)
                    if let mergedData = try? JSONEncoder().encode(merged) {
                        entryToInsert = OutboxEntry(
                            id: entry.id,
                            tableName: entry.tableName,
                            rowKey: entry.rowKey,
                            event: entry.event,
                            valuesData: entry.valuesData,
                            packedHLC: entry.packedHLC,
                            enqueuedAt: entry.enqueuedAt,
                            retryCount: entry.retryCount,
                            isParked: entry.isParked,
                            columnHLCsData: mergedData
                        )
                    }
                }
                // No merge needed if only one side has column HLC data (or neither does);
                // the incoming entry's columnHLCsData is used as-is.

                _ = try await rowStore.delete(
                    table: table,
                    where: .eq(Column(table: table, name: "id"), .uuid(oldID))
                )
            }

            try await insertEntry(entryToInsert, to: rowStore)
            return
        }

        // No existing entry for (tableName, rowKey) — insert fresh.
        try await insertEntry(entry, to: rowStore)
    }

    // MARK: - Read batch

    /// Read up to `limit` pending outbox entries, ordered by HLC ascending
    /// (oldest first, so re-delivery after a failure preserves chronological order).
    ///
    /// **Parked entries are excluded.** Entries with `is_parked == 1` have
    /// permanently failed and are filtered out here; use `parkedEntries(from:)`
    /// for diagnostics access.
    ///
    /// Does NOT delete the entries — they remain in the outbox until the caller
    /// confirms them via `confirm(ids:from:)`. This is the read-without-consume
    /// pattern: the transport failure path is a no-op (entries stay intact).
    public static func readBatch(from storage: any Storage, limit: Int = 256) async throws -> [OutboxEntry] {
        let rows = try await storage.rowStore.query(
            table: table,
            where: nil,
            orderBy: [OrderClause(column: Column(table: table, name: "hlc"), direction: .ascending)],
            limit: limit,
            offset: nil
        )
        // Filter parked entries in Swift. The is_parked column may be absent on
        // rows written before the v3 migration; decodeRow defaults it to false,
        // so pre-migration rows are treated as active (correct behaviour).
        return rows.compactMap { decodeRow($0) }.filter { !$0.isParked }
    }

    // MARK: - Confirm (delete on transport success)

    /// Delete the outbox entries identified by `ids`, signalling that the
    /// transport has successfully delivered those records.
    ///
    /// Only the entries listed in `ids` are removed; any entries not in `ids`
    /// (e.g. entries appended after the batch was read) remain in the outbox
    /// for the next push cycle.
    public static func confirm(ids: [UUID], from storage: any Storage) async throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            _ = try await storage.rowStore.delete(
                table: table,
                where: .eq(Column(table: table, name: "id"), .uuid(id))
            )
        }
    }

    // MARK: - Park (permanent failure)

    /// Mark the entry identified by `id` as permanently failed.
    ///
    /// Sets `is_parked = 1`. Parked entries are excluded from `readBatch` and
    /// will never be pushed again. They remain in the table and are visible via
    /// `parkedEntries(from:)` so the host app can surface a diagnostic warning
    /// (e.g. "some changes could not be synced because your iCloud storage is
    /// full").
    public static func park(id: UUID, from storage: any Storage) async throws {
        _ = try await storage.rowStore.update(
            table: table,
            values: ["is_parked": .int(1)],
            where: .eq(Column(table: table, name: "id"), .uuid(id))
        )
    }

    // MARK: - Increment retry count

    /// Increment the `retry_count` for the entry identified by `id`.
    ///
    /// Called after a retryable or conflict error so the host app can surface
    /// entries that are stuck in a retry loop. The count is informational —
    /// OutboxStore does not apply a retry cap; callers decide when to give up
    /// and park an entry.
    public static func incrementRetryCount(id: UUID, from storage: any Storage) async throws {
        // Read the current count, increment, write back.
        // This is a read-modify-write; safe here because the outbox is single-
        // writer (the CloudKitStateActor's serial push cycle).
        let rows = try await storage.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "id"), .uuid(id))
        )
        guard let row = rows.first else { return }
        let current: Int
        if case .int(let c) = row["retry_count"] {
            current = Int(c)
        } else {
            current = 0
        }
        _ = try await storage.rowStore.update(
            table: table,
            values: ["retry_count": .int(Int64(current + 1))],
            where: .eq(Column(table: table, name: "id"), .uuid(id))
        )
    }

    // MARK: - Diagnostics: parked entries

    /// Read all parked outbox entries.
    ///
    /// Returns entries that have been marked `is_parked = 1` due to a permanent
    /// push failure (quota exceeded or record too large). These entries are
    /// excluded from normal push batches but remain in the table so the host app
    /// can surface a user-visible warning.
    ///
    /// Ordered by HLC ascending (oldest first).
    public static func parkedEntries(from storage: any Storage) async throws -> [OutboxEntry] {
        let rows = try await storage.rowStore.query(
            table: table,
            where: nil,
            orderBy: [OrderClause(column: Column(table: table, name: "hlc"), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { decodeRow($0) }.filter { $0.isParked }
    }

    // MARK: - Tombstone purge (P5-M1b)

    /// Purge parked outbox entries for a (tableName, rowKey) after a tombstone wins.
    ///
    /// WHY only parked entries are removed:
    /// Parked entries (is_parked = 1) have permanently failed transport delivery
    /// and will never be pushed. Once a remote tombstone wins the LWW gate and
    /// hard-deletes the local row, these parked payloads can never be reconciled —
    /// retaining them is indefinite storage waste (Perkins P4-M4 advisory).
    ///
    /// WHY active entries are NOT removed:
    /// A NEWER active outbox entry for the same (table, rowKey) would have beaten
    /// the tombstone LWW gate and prevented the tombstone from applying in the first
    /// place (the caller never reaches this path in that scenario). At tombstone-apply
    /// time, no newer active entry exists for this row; if one were present, the
    /// tombstone would not have won.
    ///
    /// Uses `deleteSync` so the purge does not produce a new outbox entry (I-10).
    ///
    /// - Parameters:
    ///   - tableName: Application table of the deleted row.
    ///   - rowKey: UUID string of the deleted row (matches the TEXT column format).
    ///   - storage: The local PersistenceKit storage.
    /// - Returns: Number of parked entries removed.
    @discardableResult
    public static func deleteMatchingParked(
        tableName: String,
        rowKey: String,
        from storage: any Storage
    ) async throws -> Int {
        // Query parked entries for (table_name, row_key) first; delete by id so
        // we touch only the targeted rows and avoid a broad DELETE without a PK gate.
        let parked = try await storage.rowStore.query(
            table: table,
            where: .and([
                .eq(Column(table: table, name: "table_name"), .text(tableName)),
                .eq(Column(table: table, name: "row_key"),    .text(rowKey)),
                .eq(Column(table: table, name: "is_parked"),  .int(1)),
            ])
        )
        guard !parked.isEmpty else { return 0 }

        var purgedCount = 0
        for row in parked {
            guard case .uuid(let entryID) = row["id"] else { continue }
            // deleteSync so this internal purge does not emit a new outbox entry (I-10).
            _ = try? await storage.rowStore.deleteSync(
                table: table,
                where: .eq(Column(table: table, name: "id"), .uuid(entryID))
            )
            purgedCount += 1
        }
        return purgedCount
    }

    // MARK: - Drain leftovers on enable

    /// Read all pending outbox entries that survived from a previous process
    /// lifetime. Called by `CloudKitStateActor.enable()` to discover unconfirmed
    /// changes so a push cycle can be scheduled immediately after enable.
    ///
    /// Returns only active (non-parked) entries; parked entries are skipped
    /// because they will not be pushed regardless.
    ///
    /// Semantically equivalent to `readBatch(limit: Int.max)`. The separate
    /// function name documents the enable-time intent and lets callers distinguish
    /// it from normal push-cycle batch reads.
    public static func drainLeftovers(from storage: any Storage) async throws -> [OutboxEntry] {
        try await readBatch(from: storage, limit: Int.max)
    }

    // MARK: - Re-mint on re-enrollment (A2)

    /// Re-mint the HLC of every pending outbox entry under a new nodeID.
    ///
    /// Called by `CloudKitStateActor` when re-enrolling after `reenrollRequired`:
    /// either from `EpochFence.heartbeat` at push time, or when `enable()` discovers
    /// the claimed slot differs from the previously stored slot.
    ///
    /// WHY RE-MINT IS SAFE:
    /// Outbox entries are UNPUSHED LOCAL STATE — they have never been delivered to
    /// CloudKit. No remote replica has seen these HLCs, so there are no existing
    /// comparisons to invalidate. LWW treats re-minted HLCs as the latest local
    /// writes, which is exactly what they are. The invariant is that re-minted HLCs
    /// must be physically newer than all previously-pushed HLCs from this device;
    /// a fresh HLCGenerator seeded from the current wall clock guarantees this
    /// because wall time is monotonically non-decreasing and the new nodeID is
    /// different from the old one (no namespace collision).
    ///
    /// Entries are processed in ascending HLC order (readBatch default) so the
    /// generator mints strictly increasing HLCs, preserving relative ordering
    /// among the re-minted entries.
    ///
    /// - Parameters:
    ///   - storage: The PersistenceKit storage instance.
    ///   - newNodeID: The newly claimed HLC node ID (1–15) from the fresh slot.
    ///   - nowMillis: Current wall-clock in milliseconds for the HLC generator seed.
    public static func remintAll(
        from storage: any Storage,
        newNodeID: Int32,
        nowMillis: Int64
    ) async throws {
        var generator = HLCGenerator(nodeID: newNodeID)
        // readBatch returns entries in ascending HLC order (oldest first).
        // Minting new HLCs in that order preserves relative ordering.
        let entries = try await readBatch(from: storage, limit: Int.max)
        for entry in entries {
            // Remove the entry with its old HLC and outbox-ID.
            _ = try await storage.rowStore.delete(
                table: table,
                where: .eq(Column(table: table, name: "id"), .uuid(entry.id))
            )
            // Mint a fresh HLC under the new nodeID.
            let newHLC = generator.send(now: nowMillis)
            let reminted = OutboxEntry(
                id: UUID(),
                tableName: entry.tableName,
                rowKey: entry.rowKey,
                event: entry.event,
                valuesData: entry.valuesData,
                packedHLC: Int64(bitPattern: newHLC.packed),
                // Preserve original enqueue time for observability (not for ordering).
                enqueuedAt: entry.enqueuedAt,
                retryCount: 0,
                isParked: false,
                // WHY columnHLCsData is preserved as-is (not re-minted):
                // Column HLCs are logical timestamps identifying which column was
                // written at which point in the HLC timeline — they record events,
                // not device identity. Re-enrollment changes only the nodeID used
                // for future outbox HLCs; the column HLC timeline from capture
                // time remains valid. The receiver uses column HLCs for per-column
                // LWW comparison, not for device identity. Passing stale column HLCs
                // would cause the receiver to reject re-minted columns whose HLCs
                // appear older than the local side-table record. Preserve as-is.
                columnHLCsData: entry.columnHLCsData
            )
            try await insertEntry(reminted, to: storage)
        }
    }

    // MARK: - Internal helpers
    //
    // insertEntry is internal (not private) so remintAll and future within-module
    // callers can share the insert path without duplicating the column map.

    static func insertEntry(_ entry: OutboxEntry, to storage: any Storage) async throws {
        try await insertEntry(entry, to: storage.rowStore)
    }

    /// Transactional variant of `insertEntry(_:to:)`. See `append(entry:to
    /// transaction:)` above for why this overload exists (gap 3).
    static func insertEntry(_ entry: OutboxEntry, to transaction: any StorageTransaction) async throws {
        try await insertEntry(entry, to: transaction.rowStore)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private static func insertEntry(_ entry: OutboxEntry, to rowStore: any RowStore) async throws {
        var values: [String: TypedValue] = [
            "id":           .uuid(entry.id),
            "table_name":   .text(entry.tableName),
            "row_key":      .text(entry.rowKey),
            "event":        .text(entry.event.rawValue),
            "hlc":          .int(entry.packedHLC),
            "enqueued_at":  .text(entry.enqueuedAt),
            "retry_count":  .int(Int64(entry.retryCount)),
            "is_parked":    .int(entry.isParked ? 1 : 0),
        ]
        if let blob = entry.valuesData {
            values["values"] = .blob(blob)
        }
        // column_hlcs is nullable; only set when present (fieldLevelLWW entries).
        if let colBlob = entry.columnHLCsData {
            values["column_hlcs"] = .blob(colBlob)
        }
        // Use insert (not upsert) because coalescing already guarantees no
        // existing entry for this (table_name, row_key) by the time we reach
        // this point. The `id` UUID is fresh per entry.
        _ = try await rowStore.insert(table: table, values: values)
    }

    private static func decodeRow(_ row: StorageRow) -> OutboxEntry? {
        guard
            case .uuid(let id)          = row["id"],
            case .text(let tableName)   = row["table_name"],
            case .text(let rowKey)      = row["row_key"],
            case .text(let eventRaw)    = row["event"],
            case .int(let hlc)          = row["hlc"],
            case .text(let enqueuedAt)  = row["enqueued_at"],
            let event = SyncEventKind(rawValue: eventRaw)
        else { return nil }

        // values is nullable; absent or .null both map to nil.
        let valuesData: Data?
        switch row["values"] {
        case .blob(let d): valuesData = d
        default:           valuesData = nil
        }

        // retry_count and is_parked may be absent on rows written before the v3
        // migration. Default both to 0/false so pre-migration rows behave as active.
        let retryCount: Int
        if case .int(let c) = row["retry_count"] { retryCount = Int(c) } else { retryCount = 0 }

        let isParked: Bool
        if case .int(let p) = row["is_parked"] { isParked = p != 0 } else { isParked = false }

        // column_hlcs is nullable; absent on rows written before v6 migration.
        let columnHLCsData: Data?
        switch row["column_hlcs"] {
        case .blob(let d): columnHLCsData = d
        default:           columnHLCsData = nil
        }

        return OutboxEntry(
            id: id,
            tableName: tableName,
            rowKey: rowKey,
            event: event,
            valuesData: valuesData,
            packedHLC: hlc,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount,
            isParked: isParked,
            columnHLCsData: columnHLCsData
        )
    }
}
