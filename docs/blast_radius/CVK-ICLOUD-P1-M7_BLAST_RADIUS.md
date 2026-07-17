# Blast Radius Report — CVK-ICLOUD P1-M7

**Mission:** Tombstoned deletes + record-type routing (R7) + adjudication A6
**Date:** 2026-07-16
**Tier:** Primitive-touching (ConvergenceKit sync wire format + both backend engines)
**Baseline:** Swift 26 tests (exit 0), Rust 14 tests (exit 0)
**Worktree base:** `worktree-agent-ae0fc38efe0c0733c`, commit `cec028eb`

---

## D1 + D2 Defects — Confirmed in Worktree

**D1 (table fan-out):** Confirmed at `CloudKitSyncEngine.swift` lines 320-330:
```swift
for recordID in deletedIDs {
    let parts = recordID.recordName.split(separator: ":")
    guard let rowKey = UUID(uuidString: String(parts[0])) else { continue }
    for syncedTable in manifest.tables where syncedTable.direction != .pushOnly {
        // ← fans out to EVERY non-pushOnly table — D1
        _ = try? await storage.rowStore.delete(table: syncedTable.name, where: predicate)
    }
}
```
`CKRecord.ID` carries no record type; UUID match spreads deletion to all tables.

**D2 (no HLC gate on deletions):** Confirmed — the `deletedIDs` path at lines 320-330 does
no HLC comparison before deleting. A stale delete beats a newer local edit.

---

## A6 Finding — Confirmed

**Federation:** `FederationSyncEngine.swift` stores `_syncHLC` IN the application row:
```swift
var rowValues = values
rowValues["_syncHLC"] = .hlc(record.hlc.asHLC)
_ = try await storage.rowStore.upsert(table: record.table, values: rowValues, ...)
```
After a hard-delete the row is gone → `_syncHLC` is lost → resurrection vulnerability.

**Rust `federation.rs`:** Same: `read_sync_hlc()` reads `_syncHLC` from the row via query.
After delete, `row_store.delete()` removes the row and the stored HLC with it.

---

## Scope Breakdown

### Modified files (existing code)

| File | Change | Reason |
|------|--------|--------|
| `Sources/ConvergenceKit/SyncRecord.swift` | Add `syncDeleted: Bool?` with omit-nil encoding | Federation wire tombstone flag (C-8 parity) |
| `Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift` | schema v1→v2 (`is_deleted` column), `writeTombstoneHLC`, tombstone push (no CKRecord.ID deletion), tombstone apply in `applyInbound`, `deletedIDs` comment update | Fix D1+D2, A6 on CloudKit side |
| `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` | Add `isTombstone: Bool = false` to `DecodedRecord`, add `tombstoneRecord(...)`, update `decode()` to detect `_syncDeleted` | CloudKit tombstone decode path |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | A6: add `_fed_sync_meta` side table, `enable()` ensures table, `applyInbound` reads/writes side table (not row), tombstone HLC persists after delete; push sets `syncDeleted: true` on delete | Fix A6, Federation tombstone |
| `rust/src/record.rs` | Add `#[serde(skip_serializing_if = "Option::is_none", default)] pub sync_deleted: Option<bool>` | C-8 wire parity with Swift |
| `rust/src/federation.rs` | A6: `_fed_sync_meta` side table, tombstone HLC persistence after delete | Rust parity |
| `Tests/ConvergenceKitFederationTests/FederationLWWTests.swift` | `makeStorage()` adds `ensureFedSyncMetaTable`; `syncHLCPersistedAfterApply` checks side table not row | A6 test update |

### New files

| File | Purpose |
|------|---------|
| `Sources/ConvergenceKit/Tombstone.swift` | Shared constants: `SyncTombstone.deletedFieldKey`, `SyncTombstone.gcRetentionSeconds` |
| `Sources/ConvergenceKitCloudKit/TombstoneGC.swift` | GC compaction for stale tombstone HLCs in `_ck_sync_meta` |
| `Tests/ConvergenceKitCloudKitTests/TombstoneLWWTests.swift` | Tombstone LWW matrix: stale-delete-loses, newer-delete-wins, recreate-after-delete, stale-resurrect-rejected, cross-table-isolation |
| `Tests/ConvergenceKitFederationTests/FederationTombstoneTests.swift` | Federation tombstone LWW + A6 side table verification + wire round-trip |

---

## MUST_UPDATE List

1. `Sources/ConvergenceKit/SyncRecord.swift` — `syncDeleted: Bool?` + CodingKey
2. `Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift` — schema v2, tombstone push, tombstone apply, `writeTombstoneHLC`
3. `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` — `DecodedRecord.isTombstone`, `tombstoneRecord()`, `decode()` detection
4. `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` — A6 full migration
5. `rust/src/record.rs` — `sync_deleted` field
6. `rust/src/federation.rs` — A6 side table + tombstone HLC
7. `Tests/ConvergenceKitFederationTests/FederationLWWTests.swift` — A6 test update

---

## RESCOPE_REQUIRED Items

None. Blast radius is within mission scope.

---

## Risk Notes

- `FederationLWWTests.syncHLCPersistedAfterApply` checks `stored[0]["_syncHLC"]` in the
  row — this WILL be nil after A6. Test MUST be updated in the same commit as Part 3.
- Schema version bump from 1→2 on `_ck_sync_meta` — PersistenceKit `migrate(to:)` is
  additive, handles the new `is_deleted` column for InMemory and SQLite backends.
- Rust `sync_deleted: Option<bool>` uses `#[serde(default)]` so existing wire JSON
  without the field decodes without error (null default).
- `_fed_sync_meta` is a new table; `enable()` creates it. Tests calling `applyInbound`
  directly need `ensureFedSyncMetaTable` in their setup.
