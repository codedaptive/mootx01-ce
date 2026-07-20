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
import SubstrateTypes

/// GC utilities for stale tombstone HLC entries in sync side tables.
///
/// Both the CloudKit (`_ck_sync_meta`) and Federation (`_fed_sync_meta`)
/// backends share the same side-table schema; `TombstoneGC.compact` works
/// on either by accepting a `sideTable` parameter.
public enum TombstoneGC {

    /// Compact stale tombstone entries from a sync HLC side table.
    ///
    /// Queries all rows where `is_deleted = 1` (tombstone entries), decodes
    /// the full-width `sync_hlc_wire` physical time, and deletes entries
    /// whose physical time is older than `SyncTombstone.gcRetentionSeconds`
    /// ago. The retention window ensures in-flight stale resurrects from
    /// peers that have not recently synced are still gated by a live
    /// tombstone HLC entry.
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
        // GAP 6 (2026-07, D38.1): the stored `sync_hlc_wire` field is now
        // full-width (HLC.wireBytes, no bit-packing — see SyncMetaStore.swift
        // and ColumnHLCStore.swift file headers for the truncation defect
        // this replaces), so `nowMillis` is compared directly against the
        // decoded physical time with NO masking. The 40-bit mask compensation
        // this function used to apply (`& 0xFF_FFFF_FFFF` on the cutoff) is
        // REMOVED: it existed only to keep both sides of the comparison
        // wrapped into the same lossy 40-bit space as the legacy `sync_hlc`
        // packed column. Re-applying it here now would ITself reintroduce
        // truncation on data that is no longer truncated — the exact
        // regression Kong flagged when auditing the gap-6 narrow fix.
        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        let cutoffMs = nowMillis - retentionMs

        // Query all tombstone entries for this side table.
        // WHY query-then-delete rather than a single DELETE WHERE: the wire
        // BLOB is opaque to SQL; we decode in Swift instead.
        let tombstones = try await storage.rowStore.query(
            table: sideTable,
            where: .eq(Column(table: sideTable, name: "is_deleted"), .int(1))
        )

        var compacted = 0
        for row in tombstones {
            guard case .blob(let wire) = row["sync_hlc_wire"],
                  let hlc = try? HLC(wireBytes: [UInt8](wire)) else { continue }

            guard hlc.physicalTime <= cutoffMs else {
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
