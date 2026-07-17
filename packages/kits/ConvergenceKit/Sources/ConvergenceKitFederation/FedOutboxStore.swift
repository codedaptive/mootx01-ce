// FedOutboxStore.swift
//
// Durable outbox for the Federation sync backend (_fed_outbox side table).
//
// The Federation outbox stores post-encoded SyncRecord payloads rather than
// raw SyncValueMap blobs. At observe time (recordOutbound), the engine
// converts the TableChange to a SyncRecord immediately and persists the
// JSON-encoded result here. On push(), entries are read, decoded, and
// batched into a SignedEnvelope — the relay transport is the only consumer.
//
// DESIGN DIFFERENCE FROM CloudKit outbox (_ck_outbox):
// CloudKit stores a SyncValueMap blob + event kind + column HLCs separately
// (transport-agnostic). Federation stores the complete wire-ready SyncRecord
// JSON because Federation encodes at observe time (not at push time), and
// because the in-process relay is always synchronous and never fails in v1.
//
// COALESCING RULE:
// Multiple changes to the same (table_name, row_key) collapse to the entry
// with the highest packed_hlc. Newer-HLC write subsumes the older one,
// bounding hot-row growth in high-write workloads. Column HLC merging is not
// needed here because the payload IS the final SyncRecord; a newer SyncRecord
// already carries the up-to-date column HLC map.
//
// CONFIRMATION SEMANTICS (WC2, in-process relay):
// relay.send is synchronous. confirm(ids:from:) is called after every
// successful relay.send batch; entries are cleared from the table immediately.
// For the hosted relay (WC7), relay.send throws on transport failure;
// in that case confirm is NOT called — entries remain in _fed_outbox for
// the next push cycle's retry.
//
// ECHO SUPPRESSION INVARIANT (I-10):
// Entries are written from recordOutbound, which already guards
// change.origin != .syncApply. Entries loaded from the durable outbox on
// restart are SyncRecords (post-encoding); they carry no origin field.
// They are by definition local writes — the echo-suppression guard fired
// at observe time and is not re-evaluated on reload. Durability does not
// break echo suppression.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - FedOutboxEntry

/// A single pending outbound sync record in the Federation durable outbox.
///
/// Stored in the `_fed_outbox` side table managed by `FederationStateActor`.
/// The `payload` blob is a JSON-encoded `SyncRecord` — the complete wire unit
/// the push path passes to the relay transport.
///
/// Unlike CloudKit's `OutboxEntry`, there is no separate `values` blob,
/// `column_hlcs` blob, or `event` field — all are embedded in the SyncRecord
/// payload. This keeps the Federation outbox schema minimal.
public struct FedOutboxEntry: Sendable {
    /// Stable row identity used for per-record confirmation after successful
    /// relay delivery. Generated at append time; never reused even if the
    /// same (tableName, rowKey) is coalesced into a newer entry.
    public let id: UUID

    /// Name of the application table this change belongs to.
    /// Stored for coalescing: two entries with the same (tableName, rowKey)
    /// are candidates for newest-HLC coalescing.
    public let tableName: String

    /// UUID string of the changed application row.
    /// TEXT column per schema invariants (UUID stored as text, not blob).
    public let rowKey: String

    /// Packed HLC for this change, stored as Int64 bit-pattern of the
    /// `SubstrateTypes.HLC.packed` UInt64. Used for coalescing: the entry
    /// with the lower packed HLC is discarded when two entries share the
    /// same (tableName, rowKey). The MSB-node layout (`SubstrateTypes.HLC`)
    /// guarantees correct chronological ordering by packed integer compare
    /// — matches `_fed_outbox.packed_hlc` documented in SPEC §4.
    public let packedHLC: Int64

    /// JSON-encoded SyncRecord — the complete wire unit the push path
    /// delivers to the relay. Pre-encoded at observe time so the push
    /// drain path is a straight read → batch → sign → send, with no
    /// per-record re-encoding of values or column HLCs.
    public let payload: Data

    /// ISO8601 wall-clock timestamp recorded at append time. Observability
    /// only — not used for ordering (packedHLC is the ordering primitive).
    /// TEXT per schema invariants (never REAL).
    public let enqueuedAt: String

    public init(
        id: UUID,
        tableName: String,
        rowKey: String,
        packedHLC: Int64,
        payload: Data,
        enqueuedAt: String
    ) {
        self.id = id
        self.tableName = tableName
        self.rowKey = rowKey
        self.packedHLC = packedHLC
        self.payload = payload
        self.enqueuedAt = enqueuedAt
    }
}

// MARK: - FedOutboxStore

/// Stateless namespace for durable outbox operations on the `_fed_outbox`
/// side table.
///
/// All functions are static; the storage instance and table name are passed
/// explicitly. The side-schema must exist (via
/// `FederationStateActor.ensureFedSyncMetaTable`) before calling any of
/// these functions.
///
/// The table name is passed explicitly (not hardcoded here) so unit tests
/// can verify operations against a known name without coupling to the
/// actor's private constant.
public enum FedOutboxStore {

    // MARK: - Append with coalescing

    /// Append `entry` to the durable outbox table, coalescing with any
    /// existing entry for the same `(tableName, rowKey)`.
    ///
    /// **Coalescing rule (newest-wins by packed HLC):** if an entry already
    /// exists for `(entry.tableName, entry.rowKey)` and its `packed_hlc` is
    /// strictly less than `entry.packedHLC`, the existing entry is deleted
    /// and `entry` is inserted in its place. If the existing entry's HLC is
    /// greater-or-equal, the append is a no-op (stale write, preserves newer
    /// existing entry).
    ///
    /// WHY no column HLC merge (unlike CloudKit OutboxStore.append):
    /// The payload IS the complete SyncRecord, which already embeds the
    /// column HLC map for fieldLevelLWW tables. A newer SyncRecord payload
    /// subsumes the older one in full; there is no partial per-column merge
    /// to perform.
    public static func append(
        entry: FedOutboxEntry,
        to storage: any Storage,
        table: String
    ) async throws {
        // Check for an existing entry for the same (table_name, row_key).
        let existing = try await storage.rowStore.query(
            table: table,
            where: .and([
                .eq(Column(table: table, name: "table_name"), .text(entry.tableName)),
                .eq(Column(table: table, name: "row_key"),    .text(entry.rowKey)),
            ])
        )

        if let existingRow = existing.first {
            guard case .int(let existingHLC) = existingRow["packed_hlc"] else {
                // Corrupt row — delete and replace.
                if case .uuid(let oldID) = existingRow["id"] {
                    _ = try await storage.rowStore.delete(
                        table: table,
                        where: .eq(Column(table: table, name: "id"), .uuid(oldID))
                    )
                }
                try await insertEntry(entry, to: storage, table: table)
                return
            }

            // Newest-wins: existing entry is already newer-or-equal — skip.
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
            try await insertEntry(entry, to: storage, table: table)
            return
        }

        // No existing entry for (tableName, rowKey) — insert fresh.
        try await insertEntry(entry, to: storage, table: table)
    }

    // MARK: - Read batch

    /// Read all pending outbox entries, ordered by packed_hlc ascending
    /// (oldest first for chronological delivery ordering).
    ///
    /// Does NOT delete the entries — they remain until the caller confirms
    /// them via `confirm(ids:from:table:)` after successful relay delivery.
    /// This is the read-without-consume pattern: if relay send fails, the
    /// entries stay for the next push cycle's retry.
    public static func readBatch(
        from storage: any Storage,
        table: String
    ) async throws -> [FedOutboxEntry] {
        let rows = try await storage.rowStore.query(
            table: table,
            where: nil,
            orderBy: [OrderClause(column: Column(table: table, name: "packed_hlc"),
                                  direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { decodeRow($0) }
    }

    // MARK: - Confirm (delete on transport success)

    /// Delete the outbox entries identified by `ids`, signalling that the
    /// relay transport has successfully delivered those records.
    ///
    /// Only the entries listed in `ids` are removed; any entries appended
    /// after the batch was read remain in the outbox for the next cycle.
    public static func confirm(
        ids: [UUID],
        from storage: any Storage,
        table: String
    ) async throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            _ = try await storage.rowStore.delete(
                table: table,
                where: .eq(Column(table: table, name: "id"), .uuid(id))
            )
        }
    }

    // MARK: - Drain leftovers on enable

    /// Read all pending entries that survived from a prior process lifetime.
    ///
    /// Called from `FederationStateActor.enable()` to discover unconfirmed
    /// changes so the host knows to trigger a push cycle. Returns all entries
    /// in packed_hlc ascending order. Semantically equivalent to
    /// `readBatch(from:table:)` with an explicit enable-time intent.
    public static func drainLeftovers(
        from storage: any Storage,
        table: String
    ) async throws -> [FedOutboxEntry] {
        try await readBatch(from: storage, table: table)
    }

    // MARK: - Count (for enable-time logging)

    /// Count pending outbox entries. Cheap alternative to drainLeftovers
    /// when the host only needs to know whether leftover entries exist.
    /// Delegates to RowStore.count(table:where:) for an O(1) SQL COUNT.
    public static func count(
        from storage: any Storage,
        table: String
    ) async throws -> Int {
        try await storage.rowStore.count(table: table, where: nil)
    }

    // MARK: - Internal helpers

    static func insertEntry(
        _ entry: FedOutboxEntry,
        to storage: any Storage,
        table: String
    ) async throws {
        let values: [String: TypedValue] = [
            "id":          .uuid(entry.id),
            "table_name":  .text(entry.tableName),
            "row_key":     .text(entry.rowKey),
            "packed_hlc":  .int(entry.packedHLC),
            "payload":     .blob(entry.payload),
            "enqueued_at": .text(entry.enqueuedAt),
        ]
        // Use insert (not upsert) because coalescing above guarantees no
        // existing entry for this (table_name, row_key) by the time we arrive.
        _ = try await storage.rowStore.insert(table: table, values: values)
    }

    private static func decodeRow(_ row: StorageRow) -> FedOutboxEntry? {
        guard
            case .uuid(let id)         = row["id"],
            case .text(let tableName)  = row["table_name"],
            case .text(let rowKey)     = row["row_key"],
            case .int(let packedHLC)   = row["packed_hlc"],
            case .blob(let payload)    = row["payload"],
            case .text(let enqueuedAt) = row["enqueued_at"]
        else { return nil }

        return FedOutboxEntry(
            id: id,
            tableName: tableName,
            rowKey: rowKey,
            packedHLC: packedHLC,
            payload: payload,
            enqueuedAt: enqueuedAt
        )
    }
}
