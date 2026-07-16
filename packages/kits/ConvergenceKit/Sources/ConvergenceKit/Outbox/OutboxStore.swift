// OutboxStore.swift
//
// Durable operations on the _ck_outbox side table.
//
// OutboxStore is transport-agnostic: it knows how to persist, coalesce, read,
// and confirm outbox entries, but it does not know about CloudKit, CKRecord,
// or any other transport detail. The push cycle (PushCycle.swift in the
// CloudKit target) owns the transport seam.
//
// COALESCING RULE:
// Multiple changes to the same (table_name, row_key) collapse to the entry
// with the highest packed HLC. Rationale: the outbox is a queue of net
// changes, not a history. If a row is inserted and then updated before the
// next push, only the update needs to be sent — the insert is subsumed. If a
// row is inserted and then deleted, only the delete needs to be sent. The
// coalescing bounds hot-row growth in high-write workloads.
//
// P1-M6 SEAM (per-record push results):
// Until P1-M6 lands, PushCycle confirms the full batch on transport success
// and retains the full batch on transport failure. Per-record confirmation
// (partial success from modifyRecords(atomically: false)) is wired in P1-M6.
// OutboxStore's confirm(ids:from:) already accepts a list of IDs so the P1-M6
// upgrade is a call-site change in PushCycle, not a schema or API change here.

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
        return rows.compactMap { decodeRow($0) }
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

    // MARK: - Drain leftovers on enable

    /// Read all pending outbox entries that survived from a previous process
    /// lifetime. Called by `CloudKitStateActor.enable()` to discover unconfirmed
    /// changes so a push cycle can be scheduled immediately after enable.
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
                enqueuedAt: entry.enqueuedAt
            )
            try await insertEntry(reminted, to: storage)
        }
    }

    // MARK: - Internal helpers
    //
    // insertEntry is internal (not private) so remintAll and future within-module
    // callers can share the insert path without duplicating the column map.

    static func insertEntry(_ entry: OutboxEntry, to storage: any Storage) async throws {
        var values: [String: TypedValue] = [
            "id":          .uuid(entry.id),
            "table_name":  .text(entry.tableName),
            "row_key":     .text(entry.rowKey),
            "event":       .text(entry.event.rawValue),
            "hlc":         .int(entry.packedHLC),
            "enqueued_at": .text(entry.enqueuedAt),
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
            case .uuid(let id)       = row["id"],
            case .text(let tableName) = row["table_name"],
            case .text(let rowKey)   = row["row_key"],
            case .text(let eventRaw) = row["event"],
            case .int(let hlc)       = row["hlc"],
            case .text(let enqueuedAt) = row["enqueued_at"],
            let event = SyncEventKind(rawValue: eventRaw)
        else { return nil }

        // values is nullable; absent or .null both map to nil.
        let valuesData: Data?
        switch row["values"] {
        case .blob(let d): valuesData = d
        default:           valuesData = nil
        }

        return OutboxEntry(
            id: id,
            tableName: tableName,
            rowKey: rowKey,
            event: event,
            valuesData: valuesData,
            packedHLC: hlc,
            enqueuedAt: enqueuedAt
        )
    }
}
