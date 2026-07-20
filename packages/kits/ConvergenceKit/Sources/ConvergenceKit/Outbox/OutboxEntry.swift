// OutboxEntry.swift
//
// Entry model for the _ck_outbox durable side table.
//
// An OutboxEntry represents one pending outbound change that has not yet been
// confirmed by the transport. Entries accumulate in the outbox as local writes
// are observed; PushCycle reads a batch, sends records to CloudKit, and
// confirms (removes) only the entries whose per-record push succeeded.
//
// Transport-agnostic: OutboxEntry holds a serialised SyncValueMap blob so the
// push path can re-encode to any transport format (CKRecord today, other
// formats in the future) without coupling the outbox schema to CloudKit.
//
// GAP 6 (2026-07, D38.1): `hlcWireBytes: Data` (16-byte `HLC.wireBytes`)
// replaces the legacy `packedHLC: Int64` (`HLC.packed`, 40-bit-truncated).
// `_ck_outbox` is develop/1.1.x-only (confirmed absent from the shipped
// v1.0.33 tag) — clean regenerate, no backfill needed. See
// ColumnHLCStore.swift's file header for the full defect writeup this fixes.

import Foundation

// MARK: - OutboxEntry

/// A single pending outbound row mutation in the durable outbox.
///
/// Stored in the `_ck_outbox` side table managed by `CKSideSchema`. Fields
/// map one-to-one to the table columns declared there. The `retry_count` and
/// `is_parked` columns were added in CKSideSchema v3 (CVK-ICLOUD P1-M6) to
/// support per-record error handling and permanent-failure parking.
public struct OutboxEntry: Sendable {
    /// Stable row identity used for per-record confirmation. Generated at
    /// append time; never reused even if the same (table, rowKey) is
    /// coalesced into a newer entry.
    public let id: UUID

    /// Name of the application table this change belongs to.
    public let tableName: String

    /// UUID of the changed application row, stored as a String because
    /// PersistenceKit's TEXT column type is the canonical storage form.
    public let rowKey: String

    /// Change kind, stored as its raw string value ("insert", "update",
    /// "delete") to satisfy the schema invariant: no Bool stored
    /// properties on side tables.
    public let event: SyncEventKind

    /// JSON-encoded SyncValueMap for insert and update events; nil for
    /// delete events (there are no values to send for a deletion).
    public let valuesData: Data?

    /// JSON-encoded ColumnHLCMap for `fieldLevelLWW` outbox entries; nil for
    /// non-fieldLevelLWW tables or delete events.
    ///
    /// Populated by `CloudKitStateActor.recordOutbound` when the synced table
    /// uses `conflictPolicy == .fieldLevelLWW`. The push path (PushCycle)
    /// decodes this and passes it to `CKRecordMapping.record(...)` so the
    /// `_syncColumnHLCs` field is present in the CKRecord on the wire.
    ///
    /// WHY pre-encoded (not a live ColumnHLCMap):
    /// Mirrors `valuesData` — the outbox stores opaque JSON blobs so the push
    /// path can re-encode to any transport format without schema coupling.
    /// Decoding only happens in PushCycle when building the CKRecord.
    public let columnHLCsData: Data?

    /// Full-width wire-format HLC for this change (`HLC.wireBytes` — 16
    /// bytes: 8 bytes physicalTime LE + 4 bytes logicalCount LE + 4 bytes
    /// nodeID LE; gap 6, D38.1). Used by the coalescing logic: when two
    /// entries for the same (tableName, rowKey) exist, the one decoding to
    /// the lower HLC is discarded.
    public let hlcWireBytes: Data

    /// ISO8601 wall-clock timestamp recorded at append time. Used for
    /// observability (staleness monitoring, queue age signals). Not used
    /// for ordering; HLC is the ordering primitive.
    public let enqueuedAt: String

    /// Number of push attempts that have failed with a retryable or conflict
    /// error. Incremented by OutboxStore.incrementRetryCount after each failed
    /// push cycle. The column is Int (not Bool) in the DB per schema invariants.
    public let retryCount: Int

    /// When true, this entry has permanently failed (quotaExceeded or
    /// limitExceeded) and is excluded from future push batches. The entry
    /// remains in the outbox for diagnostics visibility via
    /// OutboxStore.parkedEntries(from:). The column is `is_parked` (Int 0/1)
    /// in the DB per schema invariants; this Swift Bool is derived from it.
    public let isParked: Bool

    public init(
        id: UUID,
        tableName: String,
        rowKey: String,
        event: SyncEventKind,
        valuesData: Data?,
        hlcWireBytes: Data,
        enqueuedAt: String,
        retryCount: Int = 0,
        isParked: Bool = false,
        columnHLCsData: Data? = nil
    ) {
        self.id = id
        self.tableName = tableName
        self.rowKey = rowKey
        self.event = event
        self.valuesData = valuesData
        self.hlcWireBytes = hlcWireBytes
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.isParked = isParked
        self.columnHLCsData = columnHLCsData
    }
}
