---
version: v0.1
---

# CVK-ICLOUD P5-M1b — Tombstone Apply Purges Stale Skew-Queue and Parked-Outbox Payloads

**Status:** COMPLETE
**Advisory:** Perkins P4-M4 (payload retention)
**Stream:** worktree-agent-a65053730e84bc664
**Baseline tests:** 216 (40 suites) | **Final tests:** 221 (41 suites, +5) | **Exit:** 0

## What Was Done

When a tombstone wins its LWW gate for `(table, rowKey)`, two categories of stale
payloads are now purged immediately on both backends:

### 1. Pending-skew queue (`_ck_pending_skew` / `_fed_pending_skew`)

`PendingSkewQueue.deleteMatchingOlderThan(tableName:rowKey:tombstoneHLC:from:sideTable:)` —
new API. Queries all held entries for the row, decodes each payload's HLC, and
deletes entries whose HLC is **strictly older** than the tombstone HLC. Entries with
a **newer** HLC survive: they represent future-schema writes that postdate the delete
and would win the LWW gate on replay, correctly overriding the tombstone.

### 2. Parked outbox (`_ck_outbox`, `is_parked = 1`)

`OutboxStore.deleteMatchingParked(tableName:rowKey:from:)` — new API. Deletes all
parked outbox entries for the row. Parked entries (permanent push failures) will
never be delivered. A newer **active** outbox entry would have prevented the tombstone
from winning in the first place; purging parked entries at tombstone-apply time is
therefore always safe.

### Call sites

**CloudKit** (`ConvergenceKitCloudKit/Engine/ApplyInbound.swift`):
- `remoteWins` tombstone arm
- `lastWriterWinsByHLC` tombstone arm (after A6 tombstone HLC write)
- `fieldLevelLWW` tombstone arm (after A6 tombstone HLC write)

**Federation** (`ConvergenceKitFederation/FederationSyncEngine.swift`):
- `remoteWins` tombstone arm
- `lastWriterWinsByHLC` tombstone arm (after A6 tombstone HLC write)
- `fieldLevelLWW` tombstone arm (after A6 tombstone HLC write)

Both purge calls use `_ = try? await` — failures are silent (best-effort cleanup;
does not break tombstone apply correctness).

## Helper APIs Added

- `PendingSkewQueue.deleteMatchingOlderThan(tableName:rowKey:tombstoneHLC:from:sideTable:) -> Int`
- `OutboxStore.deleteMatchingParked(tableName:rowKey:from:) -> Int`

Both are `@discardableResult` and public.

## Test Names (10 new tests across 2 suites)

**`TombstonePayloadRetentionTests` (CloudKit, ConvergenceKitCloudKitTests):**
- `tombstonePurgesOlderSkewEntry` — lastWriterWinsByHLC purges older skew entry
- `tombstonePurgesParkedOutboxEntry` — lastWriterWinsByHLC purges parked outbox
- `newerSkewEntrySurvivesTombstone` — HLC > tombstone survives
- `nonMatchingRowsUntouched` — different rowKey untouched
- `fieldLevelLWWTombstonePurgesPayloads` — fieldLevelLWW both purges

**`FederationTombstoneRetentionTests` (Federation, ConvergenceKitFederationTests):**
- `fedTombstonePurgesOlderSkewEntry` — Federation lastWriterWinsByHLC skew purge
- `fedTombstonePurgesParkedOutbox` — Federation lastWriterWinsByHLC outbox purge
- `fedNewerSkewEntrySurvives` — Federation: newer skew entry survives
- `fedNonMatchingRowsUntouched` — Federation: different rowKey untouched
- `fedFieldLevelLWWTombstonePurges` — Federation fieldLevelLWW both purges

## Docs Updated

- `docs/reference/CONVERGENCEKIT_SPEC.md` — B-9 +2 lines (outbox purge); B-10 +3 lines (skew purge). Draft markers retained.

## Both-Leg Status

| Leg | Tombstone skew purge | Tombstone outbox purge |
|---|---|---|
| Swift CloudKit | ✓ lastWriterWinsByHLC, fieldLevelLWW, remoteWins | ✓ all winning arms |
| Swift Federation | ✓ lastWriterWinsByHLC, fieldLevelLWW, remoteWins | ✓ all winning arms |
| Rust | No Federation sync leg in Rust (no `federation.rs` skew/outbox handling found) | N/A |
