// SkewReplay.swift
//
// Replay helper for the schema-skew pending queue (R9, CVK-ICLOUD P3-M4).
//
// Called from enable() after the side schema is ensured. Drains records
// from the pending-skew table whose schema_version equals the now-active
// manifest schema version and re-applies them through the normal inbound
// path. Records whose schema_version is STILL above the manifest version
// remain in the table for the next enable() after the next schema update.
//
// Echo suppression (I-10) is active by construction: enable() is called
// before the storage observers are started, so the replay writes via
// applyInbound (upsertSync / deleteSync) cannot re-enter the outbox —
// the observers are not yet listening.
//
// Applies and deletes are separate steps so the caller can log success
// and failure counts before removing entries. deleteApplied removes only
// the IDs of successfully replayed records; entries that failed to apply
// are left in the table for the next enable() attempt.

import Foundation
import PersistenceKit

/// Stateless helper for draining and replaying entries from the pending-skew
/// table. Table name is a parameter so the same functions serve
/// `_ck_pending_skew` (CloudKit) and `_fed_pending_skew` (Federation).
public enum SkewReplay {

    // MARK: - Drain ready entries

    /// Fetch all entries whose `schema_version` equals `currentVersion`.
    ///
    /// Does NOT delete the entries — the caller must confirm successful apply
    /// by passing IDs to `deleteApplied`. This read-without-consume pattern
    /// means a process death during replay leaves entries intact for the
    /// next enable().
    ///
    /// - Parameters:
    ///   - currentVersion: The manifest's schemaVersion after the update.
    ///   - storage: The local PersistenceKit storage.
    ///   - sideTable: The pending-skew table name.
    /// - Returns: Array of `(id: UUID, record: SyncRecord)` ready for replay.
    ///            Entries with corrupt payloads are silently skipped (decoding
    ///            failures leave the entry in the table; the caller may want
    ///            to clean them up on subsequent replays).
    public static func drainReady(
        currentVersion: Int,
        from storage: any Storage,
        sideTable: String
    ) async throws -> [(id: UUID, record: SyncRecord)] {
        let rows = try await storage.rowStore.query(
            table: sideTable,
            where: .eq(
                Column(table: sideTable, name: "schema_version"),
                .int(Int64(currentVersion))
            )
        )
        let decoder = JSONDecoder()
        var result: [(id: UUID, record: SyncRecord)] = []
        for row in rows {
            guard case .uuid(let id) = row["id"],
                  case .blob(let payload) = row["payload"],
                  let record = try? decoder.decode(SyncRecord.self, from: payload)
            else { continue }
            result.append((id: id, record: record))
        }
        return result
    }

    // MARK: - Confirm applied entries

    /// Delete the entries with the given IDs from the pending-skew table.
    ///
    /// Called after successful `applyInbound` for each replayed entry.
    /// Uses `deleteSync` so the removal does not produce outbox entries (I-10).
    ///
    /// - Parameters:
    ///   - ids: UUIDs of entries to remove (primary keys in the side table).
    ///   - storage: The local PersistenceKit storage.
    ///   - sideTable: The pending-skew table name.
    public static func deleteApplied(
        ids: [UUID],
        from storage: any Storage,
        sideTable: String
    ) async throws {
        guard !ids.isEmpty else { return }
        let uuids = ids.map { TypedValue.uuid($0) }
        // deleteSync so the removal does not fire the storage observer (I-10).
        _ = try? await storage.rowStore.deleteSync(
            table: sideTable,
            where: .in(Column(table: sideTable, name: "id"), uuids)
        )
    }

    // MARK: - Count held entries

    /// Return the total number of entries in the pending-skew table,
    /// regardless of schema_version. Used to emit
    /// `SyncEvent.recordsHeldForMigration(count:)` after replay when
    /// higher-version records remain.
    ///
    /// - Parameters:
    ///   - storage: The local PersistenceKit storage.
    ///   - sideTable: The pending-skew table name.
    /// - Returns: Total count of held records (applied + not yet ready).
    public static func countHeld(
        from storage: any Storage,
        sideTable: String
    ) async throws -> Int {
        try await storage.rowStore.count(table: sideTable, where: nil)
    }
}
