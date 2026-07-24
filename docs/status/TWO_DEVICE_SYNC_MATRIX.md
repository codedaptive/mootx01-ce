---
version: v0.1
stream: vh
date: 2026-07-23
status: TEMPLATE — Bob executes on real hardware
---

# Two-Device Sync Validation Matrix

iPhone + Mac scenarios for MOOTx01 1.1 TestFlight validation.
Each scenario has a precondition, steps, expected outcome, and pass/fail record.
Execute on real hardware before External TestFlight submission.

Device A = iPhone (primary)  
Device B = Mac (iCloud same account)

---

## Prerequisites

- Both devices signed into the same iCloud account
- `mootx01` installed and estate initialized on both
- iCloud Sync enabled on both devices (Settings → iCloud Sync toggle)
- Both devices online with stable network
- Both device estates are empty or at a known baseline snapshot

---

## Scenario 1 — Concurrent Writes

### 1a. Non-conflicting concurrent writes — both land

**Precondition:** Both estates at identical baseline (0 memories or known snapshot).

**Steps:**
1. On Device A: file memory "Device A concurrent write — scenario 1a"
2. Within 5 seconds, on Device B: file memory "Device B concurrent write — scenario 1a"
3. Wait 60 seconds for sync to settle
4. On Device A: search for "1a" — expect 2 results
5. On Device B: search for "1a" — expect 2 results

**Expected:** Both memories visible on both devices. No data loss.  
**Owning stream:** sm (sync gate), ev (wire format)

| Run | Date | A result | B result | Pass? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

### 1b. Conflicting writes to same memory — LWW wins

**Precondition:** Memory M1 exists on both estates (previously synced).

**Steps:**
1. On Device A: update M1 title to "Version from A"
2. Within 2 seconds (before sync settles), on Device B: update same M1 title to "Version from B"
3. Wait 60 seconds
4. On both devices: open M1 — confirm identical title on both

**Expected:** One version wins on both devices (LWW by HLC). No split-brain; both
devices show the same title.

**Owning stream:** sm, ev  
**What to record:** which version won and the approximate timestamp delta.

| Run | Date | Winner on A | Winner on B | Consistent? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

## Scenario 2 — Kill / Restore

### 2a. Kill Device A mid-push — data survives on Device B after restore

**Steps:**
1. On Device A: file 3 memories in rapid succession
2. Immediately force-quit the MOOTx01 app on Device A (before sync has settled)
3. On Device B: wait 60 seconds, then search for the 3 memories filed on A
4. Re-launch Device A
5. Wait 60 seconds for sync to settle
6. On Device A: verify all 3 memories are present
7. On Device B: verify all 3 memories are present

**Expected:** Outbox survives crash (durable side table). All 3 memories eventually
land on both estates. No duplicates.

**Owning stream:** sm (outbox durability), CrashRecoveryTests scenario (1) covers this  
**Automated coverage:** `CrashRecoveryTests` scenario 1 — `outboxSurvivesCrashBeforeDrain()`

| Run | Date | A result | B result | Pass? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

### 2b. Kill both devices simultaneously — converge after both restart

**Steps:**
1. On Device A: file 2 memories; on Device B: file 2 different memories (total 4)
2. Force-quit MOOTx01 on both devices at approximately the same time
3. Re-launch Device A; re-launch Device B (order does not matter)
4. Wait 90 seconds for sync
5. On both devices: search for all 4 memories

**Expected:** All 4 memories visible on both devices after sync settles.

**Owning stream:** sm  
**Automated coverage:** `TwoDeviceKillRestoreTests` — `concurrentKillAndRestoreBothEstates()`

| Run | Date | A sees 4? | B sees 4? | Pass? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

### 2c. Kill during active sync — no duplicate records

**Steps:**
1. On Device A: file 5 memories in rapid succession
2. Trigger a manual sync (or wait for auto-push to start)
3. Force-quit Device A immediately after the first push confirmation sound / notification
4. Wait 30 seconds (let any in-flight records arrive on Device B)
5. On Device B: record how many of the 5 memories are visible
6. Re-launch Device A; wait 60 seconds
7. On Device A and Device B: count the total memories — must be exactly 5 (no duplicates)

**Expected:** Idempotent re-push; no duplicate records on either estate.

**Owning stream:** sm  
**Automated coverage:** `CrashRecoveryTests` scenario 2 — `rePushAfterMidPushCrashIsIdempotent()`

| Run | Date | A count | B count | Duplicates? | Pass? | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

---

## Scenario 3 — Slot Eviction / Fencing

### 3a. Slot eviction after long absence — Device A rejoins cleanly

**Simulated test (hardware execution not possible for 30-day window):**  
This scenario is validated by the automated slot-fencing suite.

**Automated coverage:**
- `SlotFencingScenarios` scenario 2: 2026-scale eviction with HLC truncation regression
- `SlotFencingScenarios` scenario 3c: epoch bump → auto-reenroll → B converges

**Verification command:**
```
cd packages/kits/ConvergenceKit && swift test --filter SlotFencingScenarios
# Expected: 6 tests, exit 0
```

**Manual watchpoint for TestFlight beta testers:**
- If a beta tester reports "sync stopped working after I didn't use the app for a month,"
  that is a slot-eviction edge case. Triage: check if reenrollment error surfaces in logs.

| Verification | Result | Notes |
|---|---|---|
| `SlotFencingScenarios` 6/6 green | | |

---

### 3b. Slot exhaustion — 16th device gets loud error, not silent failure

**Simulated test only** (requires 15+ concurrent test accounts).  
**Automated coverage:** `SlotFencingScenarios` scenario 1 — `slotExhaustedOnSixteenthClaim()`

**Expected behavior if hit in production:** App shows a clear error message (not silent)
telling the user they cannot sync on this device because all 15 device slots are occupied.
The user can revoke an inactive device in Settings to free a slot.

| Verification | Result | Notes |
|---|---|---|
| `SlotFencingScenarios` scenario 1 green | | |

---

## Scenario 4 — Tier Enable / Revoke (post-FAB5-ST)

**⚠ PENDING: FAB5-ST not yet complete. Execute this scenario after ST ships.**

### 4a. Enable Restricted tier — memories already filed NOT retroactively synced

**Precondition:** Some existing memories filed before Restricted tier is enabled.

**Steps:**
1. On Device A: Settings → Sensitive Tiers → Enable Restricted
2. File a new memory tagged Restricted
3. Wait 60 seconds
4. On Device B: verify the new Restricted memory is NOT visible (tier blocked at sync layer)
5. On Device A: verify pre-enable memories are still present and unaffected

**Expected:** Only Restricted memories filed AFTER enabling the tier appear on Device A.
Sync layer never places Restricted/Secret memories in the outbox.  
**Owning stream:** st

| Run | Date | New Restricted on B? | Pre-enable memories intact? | Pass? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

### 4b. Revoke Restricted tier — Device B does not lose previously synced memories

**Steps:**
1. Enable Restricted on both devices; file 3 Restricted memories; verify both see them
2. On Device A: Settings → Sensitive Tiers → Disable Restricted
3. Wait 60 seconds
4. On Device A: verify 3 Restricted memories are still locally accessible (not deleted)
5. On Device B: no behavior change (B still has Restricted enabled)

**Expected:** Revoking sync does not delete local memories. Local estate is the
source of truth; sync is additive only.  
**Owning stream:** st

| Run | Date | A local intact? | B unchanged? | Pass? | Notes |
|---|---|---|---|---|---|
| 1 | | | | | |

---

## Scenario 5 — Offline / Rejoin

### 5a. Device A offline during B writes — A catches up on rejoin

**Steps:**
1. Put Device A in Airplane Mode
2. On Device B: file 10 memories over 2 minutes
3. Restore Device A's network (disable Airplane Mode)
4. Wait 90 seconds for sync
5. On Device A: search — expect all 10 memories visible

**Expected:** Full catch-up on rejoin. No missing records.

**Owning stream:** sm  
**Automated coverage:** `TwoDeviceKillRestoreTests` — `offlineRejoinCatchUp()`

| Run | Date | A sees 10? | Pass? | Notes |
|---|---|---|---|---|
| 1 | | | | |

---

### 5b. Both devices offline, then rejoin — concurrent divergence resolves

**Steps:**
1. Put both devices in Airplane Mode
2. On Device A: file 5 memories; on Device B: file 5 different memories
3. On Device A: also update one shared memory to "Version-A"
4. On Device B: update the same shared memory to "Version-B"
5. Restore both devices' network (within 30 seconds of each other)
6. Wait 90 seconds
7. On both devices: count memories (expect 10 unique + 1 contested)
8. On both devices: open the contested memory — same title on both devices

**Expected:** 10 unique memories visible on both. Contested memory shows same
value on both (LWW resolved consistently).

**Owning stream:** sm, ev  
**Automated coverage:** `TwoDeviceKillRestoreTests` — `offlineDivergenceResolves()`

| Run | Date | A total | B total | LWW consistent? | Pass? | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

---

### 5c. Device A offline for extended period — B writes many records — token catch-up

**Steps:**
1. Put Device A in Airplane Mode for 5+ minutes (let it age the change token)
2. On Device B: file 20+ memories
3. Restore Device A
4. Wait 120 seconds (allow full token-catch-up pull)
5. On Device A: verify all 20+ memories visible

**Expected:** No records lost. Token-based incremental pull handles the backlog.

**Owning stream:** sm

| Run | Date | A sees all 20+? | Pass? | Notes |
|---|---|---|---|---|
| 1 | | | | |

---

## Scenario 6 — Automated Conformance Verification

Run before each TestFlight upload to confirm all automated scenarios pass.

```bash
# ConvergenceKit full suite (includes crash recovery, slot fencing, two-device fixtures)
cd packages/kits/ConvergenceKit && swift test 2>&1 | tail -5

# Expected: exit 0, ≥271 tests (baseline 269 + net-new fixtures)
```

| Build | Date | Exit code | Test count | Pass? |
|---|---|---|---|---|
| Round 1 | | | | |
| Round 2 | | | | |

---

## Pass/Fail Summary

| Scenario | Manual Run 1 | Manual Run 2 | Notes |
|---|---|---|---|
| 1a Concurrent non-conflicting | | | |
| 1b Conflicting LWW | | | |
| 2a Kill A mid-push | | | |
| 2b Kill both simultaneously | | | |
| 2c Kill during active sync | | | |
| 3a Slot eviction (automated) | | | |
| 3b Slot exhaustion (automated) | | | |
| 4a Tier enable (post-ST) | | | |
| 4b Tier revoke (post-ST) | | | |
| 5a Offline rejoin | | | |
| 5b Both offline concurrent divergence | | | |
| 5c Extended offline token catch-up | | | |
| 6 Automated conformance | | | |

**Target:** All automated scenarios green; manual scenarios 1a, 1b, 2a, 2b, 2c, 5a, 5b, 5c
pass on real hardware before external TestFlight submission.  
Scenarios 4a/4b execute after FAB5-ST ships.
