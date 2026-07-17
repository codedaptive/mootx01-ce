// Tombstone.swift
//
// Shared tombstone constants for both CloudKit and Federation backends.
//
// WHY tombstones: naive CKRecord.ID deletion carries no record type,
// causing fan-out across every non-pushOnly manifest table (D1 defect).
// A typed tombstone CKRecord (`kitID_tableName`, `_syncDeleted=1`)
// restores the routing guarantee. The delete HLC is carried in `_syncHLC`
// so the receiver can apply the same last-writer-wins-by-HLC gate that
// guards regular upserts (D2 fix).
//
// WHY the HLC persists after hard-delete: after a delete, the application
// row is gone. Without the tombstone HLC in the side table, a stale insert
// for the same (table, rowKey) would find `localHLC = nil` and be accepted,
// resurrecting a row that a newer delete had removed. The tombstone HLC
// in the side table (`_ck_sync_meta` / `_fed_sync_meta`) provides the
// comparison point that blocks stale resurrections (A6 adjudication).
//
// WHY the GC retention window matters: a tombstone HLC can only be compacted
// once every peer that could hold a stale insert for that row has had a
// chance to sync. The retention window must exceed the longest offline
// window the product supports. This constant is set longer than the P1-M3
// slot-eviction long window (that mission defines how long a device slot
// stays alive without a sync); compacting tombstones before a slot
// eviction expires would open the resurrection window for still-alive
// offline devices. If P1-M3 ships its own constant, GC retention MUST
// be verified >= that value.

/// Shared tombstone keys and GC parameters. Used by both the CloudKit
/// and Federation sync backends.
public enum SyncTombstone {

    /// The CKRecord field key (and side-table column) that marks a
    /// record as a delete tombstone. Value is 1 (NSNumber) when set.
    /// Prefixed `_sync` so `CKRecordMapping.decode` filters it from
    /// application values, same as `_syncHLC`, `_syncSchemaVersion`.
    public static let deletedFieldKey = "_syncDeleted"

    /// Minimum seconds a tombstone HLC entry persists in the side table
    /// before GC may compact it. 30 days (2 592 000 seconds).
    ///
    /// This value MUST exceed the slot-eviction long window defined by
    /// P1-M3 (DeviceSlotRegistry). Until P1-M3 ships, 30 days provides
    /// a conservative offline buffer. If P1-M3 sets a longer window,
    /// update this constant to match.
    ///
    /// WHY seconds (not Date): the side table stores HLC physical-time
    /// in milliseconds since epoch. GC converts this to a wall-clock
    /// age and compares against the threshold in seconds.
    public static let gcRetentionSeconds: Int64 = 2_592_000
}
