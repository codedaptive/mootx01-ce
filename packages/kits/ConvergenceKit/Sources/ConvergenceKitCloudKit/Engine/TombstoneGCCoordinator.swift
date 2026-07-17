// TombstoneGCCoordinator.swift
//
// CloudKit-backend GC seam: reads and writes the last-GC wall time from the
// `_ck_change_token` side table, then calls `TombstoneGC.compact` when the
// daily interval has elapsed.
//
// STORAGE CHOICE — _ck_change_token sentinel row:
// `_ck_change_token` is a key-value store keyed by `zone_name` (one row per
// CloudKit zone): `zone_name TEXT PK`, `token BLOB NOT NULL`, `updated_at
// TEXT NOT NULL`. We insert a sentinel row with
//   zone_name  = "_gc_tombstone_sweep"
//   token      = Data()  (empty placeholder; never read back or interpreted
//                         as a CKServerChangeToken — documented here)
//   updated_at = ISO8601 wall-clock string of the last successful GC run
// The leading underscore on the sentinel zone name matches the convention
// for all internal sentinel keys and cannot collide with a real CloudKit
// zone name (CloudKit zone names are caller-chosen bare identifiers, never
// prefixed with underscore in the SDK). Reusing this table avoids a new
// side table (which would require a CKSideSchema version bump and a
// migration entry) for a single sentinel row.
//
// CRITICAL INVARIANT:
// The retention window (SyncTombstone.gcRetentionSeconds) MUST exceed the
// slot-eviction long window (P1-M3 DeviceSlotRegistry, not yet shipped). A
// fenced-out device that is offline must not miss a delete — if its tombstone
// HLC is GC'd before the device resumes syncing, a stale insert can resurrect
// the deleted row, violating the A6 adjudication. The 90 d retention window
// (2 592 000 s) provides a conservative offline buffer that dwarfs the current
// maximum offline expectation; once P1-M3 ships its slot-eviction constant,
// verify gcRetentionSeconds >= that value.
//
// CVK-WB7.

import Foundation
import ConvergenceKit
import PersistenceKit

// MARK: - Sentinel key

private let gcSentinelZone = "_gc_tombstone_sweep"

// MARK: - CloudKitStateActor GC extension

extension CloudKitStateActor {

    /// Run tombstone GC if the daily interval has elapsed since the last sweep.
    ///
    /// Convenience entry point for the production scheduler closure — reads
    /// `self.storage` and delegates to the testable overload.
    ///
    /// - Parameter nowMs: Current wall-clock ms from the scheduler's injected
    ///   clock. The same value is used for both the interval check and the GC
    ///   compact call so the 40-bit mask comparison in `TombstoneGC.compact`
    ///   is consistent with the timestamp written to the sentinel row.
    func gcIfDue(nowMs: Int64) async throws {
        guard let storage else { return }
        try await gcIfDue(storage: storage, nowMs: nowMs)
    }

    /// Testable GC entry point. Takes `storage` explicitly so unit tests can
    /// call this without going through `enable()` or setting actor state.
    ///
    /// - Parameters:
    ///   - storage: Storage instance containing the side tables.
    ///   - nowMs: Current wall-clock ms (injectable for tests).
    func gcIfDue(storage: any Storage, nowMs: Int64) async throws {
        // Read the persisted last-GC time from the sentinel row.
        let lastGCMs = try await readLastGCMs(from: storage)

        // CRITICAL INVARIANT: gcRetentionSeconds (90 d = 7 776 000 s) MUST STRICTLY
        // exceed the slot-eviction long window once P1-M3 ships. A device
        // offline during the retention window must still find its tombstone
        // when it reconnects so stale inserts are gated (A6).
        // The interval check (24 h vs. 90 d) is separate: once per day is
        // safe because we only GC entries older than 90 d, not all tombstones.
        guard (nowMs - lastGCMs) >= TombstoneGCSchedule.gcIntervalMs else { return }

        // Compact stale tombstone entries from the CloudKit sync-meta table.
        _ = try await TombstoneGC.compact(
            from: storage,
            sideTable: CKSideSchema.syncMetaTable,
            nowMillis: nowMs
        )

        // Persist the new last-GC wall time so the next call knows when to
        // run again.
        try await writeLastGCMs(nowMs, to: storage)
    }

    // MARK: - Sentinel helpers

    private func readLastGCMs(from storage: any Storage) async throws -> Int64 {
        let rows = try await storage.rowStore.query(
            table: CKSideSchema.changeTokenTable,
            where: .eq(
                Column(table: CKSideSchema.changeTokenTable, name: "zone_name"),
                .text(gcSentinelZone)
            )
        )
        guard let row = rows.first,
              case .text(let isoDate) = row["updated_at"],
              let date = ISO8601DateFormatter().date(from: isoDate) else {
            // No prior GC run recorded. Return 0 so the interval check
            // evaluates to (nowMs - 0) which is always >= gcIntervalMs for
            // any reasonable nowMs (> 24 h since the Unix epoch).
            return 0
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func writeLastGCMs(_ ms: Int64, to storage: any Storage) async throws {
        let isoDate = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(ms) / 1_000)
        )
        // `token` column is NOT NULL in the schema. We store Data() as a
        // documented placeholder — this sentinel row is never read back as a
        // CKServerChangeToken; only `updated_at` is consumed by this module.
        _ = try await storage.rowStore.upsert(
            table: CKSideSchema.changeTokenTable,
            values: [
                "zone_name":  .text(gcSentinelZone),
                "token":      .blob(Data()),
                "updated_at": .text(isoDate),
            ],
            conflictColumns: ["zone_name"]
        )
    }
}
