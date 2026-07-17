// TombstoneGC.swift
//
// Compaction for stale tombstone HLC entries in sync side tables.
//
// Both sync backends use a side table to persist the HLC for deleted rows
// so subsequent stale inserts for the same (table, rowKey) are gated by
// the standard LWW comparison even after the application row is gone (A6).
//
//   CloudKit:   `_ck_sync_meta` (schema version 2 adds `is_deleted`)
//   Federation: `_fed_sync_meta` (same schema, version 1)
//
// WHY GC is needed: tombstone entries must outlive the row, but they cannot
// accumulate indefinitely. After `SyncTombstone.gcRetentionSeconds` the entry
// is safe to remove: any peer that could carry a stale insert for that row
// should have synced well within the retention window.
//
// WHY the retention window matters:
// The window must STRICTLY exceed the slot-eviction long window
// (SlotLongInactivityWindow, 30 d): 90 days (SyncTombstone.
// gcRetentionSeconds, 3x the eviction window) guarantees a device that
// returns near the eviction boundary still finds every tombstone.

import Foundation
import PersistenceKit

/// GC utilities for stale tombstone HLC entries in sync side tables.
///
/// Both the CloudKit (`_ck_sync_meta`) and Federation (`_fed_sync_meta`)
/// backends share the same side-table schema; `TombstoneGC.compact` works
/// on either by accepting a `sideTable` parameter.
public enum TombstoneGC {

    /// Compact stale tombstone entries from a sync HLC side table.
    ///
    /// Queries all rows where `is_deleted = 1` (tombstone entries), unpacks
    /// the `sync_hlc` physical time, and deletes entries whose physical time
    /// is older than `SyncTombstone.gcRetentionSeconds` ago. The retention
    /// window ensures in-flight stale resurrects from peers that have not
    /// recently synced are still gated by a live tombstone HLC entry.
    ///
    /// - Parameters:
    ///   - storage: Storage instance containing the side table.
    ///   - sideTable: Table name — `"_ck_sync_meta"` or `"_fed_sync_meta"`.
    ///   - nowMillis: Current wall-clock milliseconds (injectable for testing).
    /// - Returns: Count of compacted entries.
    /// - Throws: `StorageError` if the side table cannot be queried.
    @discardableResult
    public static func compact(
        from storage: any Storage,
        sideTable: String,
        nowMillis: Int64
    ) async throws -> Int {
        // Compaction threshold: physical time (ms) below which tombstone
        // entries are eligible for deletion.
        //
        // CRITICAL: the stored sync_hlc physical field is 40-bit-truncated
        // (HLC.packed masks phys with 0xFF_FFFF_FFFF), while nowMillis is
        // full-width Unix ms (~1.75e12 in 2026 > 2^40 ≈ 1.10e12). Comparing
        // an unmasked cutoff against truncated stored values would make EVERY
        // tombstone look ~35 years old and compact them all instantly,
        // silently destroying the A6 stale-resurrect guard (Perkins P4-M4
        // finding; same failure class as the SlotTable eviction bug fixed at
        // the Adams P1 gate). Mask the cutoff into the same 40-bit space so
        // both sides of the comparison wrap identically.
        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        let cutoffMs = (nowMillis - retentionMs) & 0xFF_FFFF_FFFF

        // Query all tombstone entries for this side table.
        // WHY query-then-delete rather than a single DELETE WHERE: the packed
        // HLC stores physical time in the lowest 40 bits with node/logical in
        // the upper bits. A direct SQL comparison on the packed int64 would
        // not correctly isolate physical time; we unpack in Swift instead.
        let tombstones = try await storage.rowStore.query(
            table: sideTable,
            where: .eq(Column(table: sideTable, name: "is_deleted"), .int(1))
        )

        var compacted = 0
        for row in tombstones {
            guard case .int(let packedI64) = row["sync_hlc"] else { continue }

            // Unpack physical time from the Int64-stored packed HLC.
            // Packed layout (cookbook §12.3): (node 8 bits << 56) |
            //   (logicalCount 16 bits << 40) | (physicalTime 40 bits).
            // Extract the low 40 bits as the physical time in milliseconds.
            let physicalMs = Int64(UInt64(bitPattern: packedI64) & 0xFF_FFFF_FFFF)
            guard physicalMs <= cutoffMs else {
                // Tombstone is within the retention window — keep it.
                continue
            }

            // Tombstone is beyond the retention window. Delete by (table_name, primary_key).
            guard case .text(let tname) = row["table_name"],
                  case .text(let pk) = row["primary_key"] else { continue }

            let predicate = StoragePredicate.and([
                .eq(Column(table: sideTable, name: "table_name"), .text(tname)),
                .eq(Column(table: sideTable, name: "primary_key"), .text(pk))
            ])
            _ = try await storage.rowStore.delete(table: sideTable, where: predicate)
            compacted += 1
        }
        return compacted
    }
}
