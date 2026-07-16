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
        // Check for an existing entry for the same (table, row_key).
        let existing = try await storage.rowStore.query(
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
                    _ = try await storage.rowStore.delete(
                        table: table,
                        where: .eq(Column(table: table, name: "id"), .uuid(oldID))
                    )
                }
                try await insertEntry(entry, to: storage)
                return
            }

            // Newest-wins: if the stored entry is already newer (or equal), skip.
            if existingHLC >= entry.packedHLC {
                return
            }

            // Incoming is newer: delete the stale entry and insert the new one.
            if case .uuid(let oldID) = existingRow["id"] {
                _ = try await storage.rowStore.delete(
                    table: table,
                    where: .eq(Column(table: table, name: "id"), .uuid(oldID))
                )
            }
        }

        try await insertEntry(entry, to: storage)
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

    // MARK: - Private helpers

    private static func insertEntry(_ entry: OutboxEntry, to storage: any Storage) async throws {
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
        // Use insert (not upsert) because coalescing already guarantees no
        // existing entry for this (table_name, row_key) by the time we reach
        // this point. The `id` UUID is fresh per entry.
        _ = try await storage.rowStore.insert(table: table, values: values)
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

        return OutboxEntry(
            id: id,
            tableName: tableName,
            rowKey: rowKey,
            event: event,
            valuesData: valuesData,
            packedHLC: hlc,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount,
            isParked: isParked
        )
    }
}
