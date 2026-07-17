// PendingSkewQueue.swift
//
// Durable queue for SyncRecords whose schemaVersion exceeds the local
// manifest's schemaVersion at pull time (R9, CVK-ICLOUD P3-M4).
//
// PROBLEM: when a sender is on a newer schema version than the receiver,
// the pull path encounters a schemaVersion mismatch. The old behavior
// counted that record as a conflict and dropped it — the change token
// advanced past it, so the record was permanently lost even after the
// receiving app updated its schema. Sync silently stalled between app
// versions.
//
// SOLUTION: hold future-schema records in this queue. At enable() time,
// records whose schema_version matches the newly-enabled manifest version
// are replayed through the normal applyInbound path (echo suppressor
// active by construction). Records with an even higher version remain in
// the queue for the next schema migration.
//
// Table schema (both _ck_pending_skew and _fed_pending_skew):
//   id             UUID — primary key assigned at enqueue time.
//   table_name     TEXT — application table the record belongs to.
//   row_key        TEXT — UUID as TEXT (primary key of the application row).
//   schema_version INT  — schemaVersion from the wire record (sender's version).
//   received_at    TEXT — ISO8601 wall-clock (used for oldest-eviction ordering).
//                         Date storage is TEXT per schema invariants.
//   payload        BLOB — JSON-encoded SyncRecord (full wire format; round-trips
//                         through JSONDecoder().decode(SyncRecord.self, from:)).
//
// Payload encoding: SyncRecord is the shared wire format for both backends.
// CloudKit converts DecodedRecord → SyncRecord before enqueueing (conversion
// in PullCycle.swift). Federation enqueues the original SyncRecord directly.
//
// Cap rule (Playground Rule 8 — bounded-queue relief valve):
// When the held count exceeds `cap` (512), oldest entries by received_at
// are evicted and the caller is expected to log a warning. This bounds
// storage growth when a device is offline across many schema migrations.
// The evicted records are not permanently lost: the peer resends them on
// its next push cycle after the remote device updates its schema.

import Foundation
import PersistenceKit
import SubstrateTypes

/// Durable queue operations for schema-skew pending records.
///
/// Both CloudKit and Federation backends share this module via the
/// `ConvergenceKit` target. The table name is a parameter so the same
/// functions serve `_ck_pending_skew` and `_fed_pending_skew`.
///
/// All write operations use the sync-tagged storage variants
/// (upsertSync / deleteSync) so the storage observer does not capture
/// side-table writes as outbound changes (I-10 echo suppression).
public enum PendingSkewQueue {

    /// Maximum held entries before oldest-eviction fires.
    ///
    /// 512 bounds the queue against unbounded growth during extended offline
    /// periods spanning multiple schema versions. When exceeded, the oldest
    /// entries by received_at are evicted — the record is not permanently
    /// lost because the peer resends after the remote device updates its
    /// schema. (Playground Rule 8 — bounded-queue relief valve.)
    public static let cap = 512

    // MARK: - Enqueue

    /// Enqueue a SyncRecord in the pending-skew side table.
    ///
    /// Writes the entry with a fresh UUID primary key, then calls
    /// `evictIfNeeded` to keep the table at or below `cap`.
    ///
    /// - Parameters:
    ///   - record: The SyncRecord to hold. Typically a future-schema record
    ///             from the pull path (record.schemaVersion > manifest.schemaVersion).
    ///   - storage: The local PersistenceKit storage.
    ///   - sideTable: The table name to write to — `CKSideSchema.pendingSkewTable`
    ///                for CloudKit; `FederationStateActor.fedPendingSkewTable` for
    ///                Federation.
    public static func enqueue(
        _ record: SyncRecord,
        to storage: any Storage,
        sideTable: String
    ) async throws {
        let payload = try JSONEncoder().encode(record)
        let id = UUID()
        let receivedAt = ISO8601DateFormatter().string(from: Date())
        // upsertSync stamps origin: .syncApply so the storage observer does
        // not re-enter the outbox for this internal side-table write (I-10).
        _ = try await storage.rowStore.upsertSync(
            table: sideTable,
            values: [
                "id":             .uuid(id),
                "table_name":     .text(record.table),
                "row_key":        .text(record.rowKey.uuidString),
                "schema_version": .int(Int64(record.schemaVersion)),
                "received_at":    .text(receivedAt),
                "payload":        .blob(payload),
            ],
            conflictColumns: ["id"]
        )
        _ = try await evictIfNeeded(cap: cap, from: storage, sideTable: sideTable)
    }

    // MARK: - Tombstone purge (P5-M1b)

    /// Purge skew-queue entries for a (table, rowKey) whose stored record HLC
    /// is strictly OLDER than the winning tombstone HLC.
    ///
    /// WHY only older entries are removed:
    /// A future-schema entry whose HLC is NEWER than the tombstone represents a
    /// write that postdates the delete event. On replay (after a schema update),
    /// that newer record would win the LWW gate and override the delete, which is
    /// correct — it is a legitimate re-create. Removing it here would silence a
    /// valid write. Only entries that the tombstone's own LWW gate would have
    /// defeated are safe to discard.
    ///
    /// - Parameters:
    ///   - tableName: Application table of the deleted row.
    ///   - rowKey: UUID of the deleted row.
    ///   - tombstoneHLC: The HLC of the winning tombstone. Entries with a stored
    ///                   record HLC strictly less than this value are deleted.
    ///   - storage: The local PersistenceKit storage.
    ///   - sideTable: Pending-skew table name (`_ck_pending_skew` or `_fed_pending_skew`).
    @discardableResult
    public static func deleteMatchingOlderThan(
        tableName: String,
        rowKey: UUID,
        tombstoneHLC: PackedHLC,
        from storage: any Storage,
        sideTable: String
    ) async throws -> Int {
        // Query all entries for this (table_name, row_key). The per-row count is
        // typically 0–2 (a row rarely accumulates multiple held schema versions),
        // so loading them all to decode the payload HLC is inexpensive.
        let candidates = try await storage.rowStore.query(
            table: sideTable,
            where: .and([
                .eq(Column(table: sideTable, name: "table_name"), .text(tableName)),
                .eq(Column(table: sideTable, name: "row_key"),    .text(rowKey.uuidString)),
            ])
        )
        guard !candidates.isEmpty else { return 0 }

        // Decode each payload to read its HLC; delete entries older than the tombstone.
        var purgedCount = 0
        for row in candidates {
            guard case .blob(let payloadData) = row["payload"],
                  let record = try? JSONDecoder().decode(SyncRecord.self, from: payloadData)
            else { continue }

            // Compare using the substrate's HLC natural ordering (packed uint64 comparison
            // is not used here; we compare the HLC triple directly via its Comparable
            // conformance provided by SubstrateTypes).
            if record.hlc.asHLC < tombstoneHLC.asHLC {
                // This entry predates the tombstone. Deleting it prevents indefinite
                // retention of a payload that the tombstone has already superseded.
                if case .uuid(let entryID) = row["id"] {
                    _ = try? await storage.rowStore.deleteSync(
                        table: sideTable,
                        where: .eq(Column(table: sideTable, name: "id"), .uuid(entryID))
                    )
                    purgedCount += 1
                }
            }
            // Entries whose HLC >= tombstoneHLC survive: they represent writes that
            // postdate the delete and may override it on schema-skew replay.
        }
        return purgedCount
    }

    // MARK: - Cap enforcement

    /// Evict the oldest entries when the table exceeds `cap`.
    ///
    /// Oldest is defined by `received_at` ascending (ISO8601 sorts
    /// lexicographically, equivalent to chronological oldest-first).
    /// Uses `deleteSync` so eviction writes do not produce outbox entries.
    ///
    /// The caller is responsible for logging when eviction occurs; this
    /// function returns the count so the engine can log at the appropriate
    /// severity (warning-level, since eviction implies records may be lost
    /// until the peer resends).
    ///
    /// - Returns: Number of entries evicted. Zero when at or below cap.
    @discardableResult
    public static func evictIfNeeded(
        cap: Int,
        from storage: any Storage,
        sideTable: String
    ) async throws -> Int {
        let total = try await storage.rowStore.count(table: sideTable, where: nil)
        guard total > cap else { return 0 }
        let excess = total - cap
        // Fetch the oldest `excess` entries by received_at ascending.
        let oldest = try await storage.rowStore.query(
            table: sideTable,
            where: nil,
            orderBy: [OrderClause(
                column: Column(table: sideTable, name: "received_at"),
                direction: .ascending
            )],
            limit: excess,
            offset: nil
        )
        let ids = oldest.compactMap { row -> TypedValue? in
            guard case .uuid(let id) = row["id"] else { return nil }
            return .uuid(id)
        }
        guard !ids.isEmpty else { return 0 }
        // deleteSync so eviction does not produce outbox entries (I-10).
        _ = try? await storage.rowStore.deleteSync(
            table: sideTable,
            where: .in(Column(table: sideTable, name: "id"), ids)
        )
        return ids.count
    }
}
