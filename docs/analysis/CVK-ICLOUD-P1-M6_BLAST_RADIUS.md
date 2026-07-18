# Blast Radius Report — CVK-ICLOUD P1-M6

**Baseline:** swift test pass count at mission start: 67
**Mission:** Per-record push results, CKError taxonomy, retry/backoff (R6) + A11 housekeeping
**Classification:** Primarily additive; three existing files modified at named seams.

## Symbols being changed

### 1. `OutboxEntry` — additive fields
**Change class:** additive (new stored properties `retryCount: Int`, `isParked: Bool` with defaults)
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| Sources/ConvergenceKit/Outbox/OutboxStore.swift (decodeRow, insertEntry) | codegraph | MUST_UPDATE | Reads/writes the new columns from DB |
| Tests/ConvergenceKitCloudKitTests/OutboxStoreTests.swift (makeEntry helper) | grep | INTENTIONALLY_LEFT | makeEntry does not set new fields; existing tests remain valid because fields have defaults |
| Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift | codegraph | INTENTIONALLY_LEFT | Does not construct OutboxEntry directly; calls OutboxStore APIs |

### 2. `OutboxStore.readBatch(from:limit:)` — semantic change
**Change class:** semantic (filters out parked entries)
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| Sources/ConvergenceKitCloudKit/Engine/PushCycle.swift | codegraph | MUST_UPDATE | Per-record results wire in; bulk confirm replaced by PushResults.process; P1-M6 seam comment removed |
| Tests/ConvergenceKitCloudKitTests/OutboxStoreTests.swift | grep | INTENTIONALLY_LEFT | All existing tests create non-parked entries; filter does not affect them |

### 3. `CKSideSchema` — version bump 2→3
**Change class:** additive (new table, new addColumn migrations)
**Scope:** public

| File | Source | Classification | Justification |
|---|---|---|---|
| Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift (enable) | codegraph | MUST_UPDATE | Remove redundant TokenStore.ensure call; CKSideSchema v3 now covers _ck_change_token |
| Sources/ConvergenceKitCloudKit/Engine/TokenStore.swift (ensure) | codegraph | MUST_UPDATE | Local _ck_change_token declaration moved into SideSchema; ensure delegates to CKSideSchema |

### 4. `PushCycle.push()` — per-record confirm
**Change class:** semantic (consume modifyRecords result dict instead of discarding; remove P1-M6 seam comment)
**Scope:** internal

| File | Source | Classification | Justification |
|---|---|---|---|
| Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift | codegraph | INTENTIONALLY_LEFT | Public SyncEngine.push() signature unchanged; forwards to actor |

## Overall Classification

N/A — primarily additive mission.

MUST_UPDATE files: 3 (OutboxStore.swift, CloudKitStateActor.swift, TokenStore.swift)
The fourth MUST_UPDATE (PushCycle.swift) is also the seam-comment removal site named in the mission.
RESCOPE_REQUIRED: 0
