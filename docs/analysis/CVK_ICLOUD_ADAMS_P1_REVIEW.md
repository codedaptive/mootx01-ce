---
version: v0.1
reviewer: Adams
mission_phase: CVK-ICLOUD P1
diff_range: aa4b140f..76894ba6
date: 2026-07-16
---

# CVK-ICLOUD P1 — Post-Flight Review

**Reviewer:** Adams
**Scope:** 9 missions (P1-M0 through P1-M8) engine decomposition, echo suppression, slot registry, durable outbox, token persistence, per-record push results, tombstone deletes, R10 hygiene.
**Diff range:** `aa4b140f..76894ba6`

---

## Final Status: BLOCKED

One CRITICAL finding must be resolved before P2 is dispatched.

---

## First-Pass Findings

| # | Severity | Finding | File:Line | Resolution |
|---|---|---|---|---|
| 1 | CRITICAL | HLC 40-bit overflow in `evictionCandidate`: `nowMillis` is full 64-bit Unix ms (~1.75T in 2026); `slot.lastActiveHLC.physicalTime` from `HLC(packed:)` is 40-bit-truncated (~649B ms ≈ year 1990); difference ≈34.8 years >> 30-day inactivity window → every non-ghost slot is always eviction-eligible. Tests pass because fixtures use timestamps below 2^40. | `SlotTable.swift:204` | Mask nowMillis to 40 bits to match the packed physicalTime domain: `let nowMillis = Int64(now.timeIntervalSince1970 * 1000) & 0xFF_FFFF_FFFF` |
| 2 | WARNING | B-4 spec stale: describes `lastWriterWinsByHLC` as reading "`_syncHLC` (reserved column written by every winning apply)" from the application row; P1-M7 A6 adjudication moved HLC storage to `_ck_sync_meta` / `_fed_sync_meta` side tables; B-4 was not updated. B-9 (line 271) partially supersedes B-4 but does not retract or correct it. | `docs/reference/CONVERGENCEKIT_SPEC.md:220-228` | Update B-4 to "reads the `_ck_sync_meta` / `_fed_sync_meta` side-table entry for (table\_name, primary\_key)"; cross-reference B-9. |
| 3 | WARNING | B-12 overclaims consolidation: lists `_ck_device_identity` as governed under the single CKSideSchema `SchemaDeclaration`; `DeviceIdentityStore` uses its own separate `SchemaDeclaration(kitID: "ConvergenceKit", version: 1)`; CKSideSchema v4 consolidation is planned but not done. | `docs/reference/CONVERGENCEKIT_SPEC.md:294-300` | Add "(consolidation planned for SideSchema v4 — currently governed by DeviceIdentityStore.ensureSchema)" to B-12 to match shipped state. |
| 4 | WARNING | SyncMetaStore uses plain `upsert` (origin: `.local`) for `writeSyncHLC` and `writeTombstoneHLC`; Federation's `writeFedSyncHLC` / `writeFedTombstoneHLC` use `upsertSync` (origin: `.syncApply`). Safe because `_ck_sync_meta` is not in the manifest and is not observed; but the asymmetry silently violates the architectural pattern and will mislead a future implementor merging the two. | `SyncMetaStore.swift:53,82` | Change both plain `storage.rowStore.upsert(...)` calls to `storage.rowStore.upsertSync(...)` for consistency with Federation and defensive correctness. |
| 5 | WARNING | SideSchema comment gives wrong HLC packed bit layout: "48-bit physical \| 12-bit logical \| 4-bit node"; `HLC.packed` (HLC.swift:92–103) is actually 40-bit physical \| 16-bit logical \| 8-bit node. This is a new file written in P1. A future implementor reading only this comment will have the wrong layout for any custom decode. | `SideSchema.swift:103-104` | Correct to "40-bit physical \| 16-bit logical \| 8-bit node"; cross-reference `SubstrateTypes/HLC.swift`. |
| 6 | INFO | `modifyResult.deleteResults` tuple field declared but never read at the `modifyRecords` call site; `deleting: []` is always passed so this field is structurally dead. | `PushCycle.swift:156-157` | Can bind to `let (saveResults, _) = ...` to make the dead field explicit and silence any future analyzer warning; no functional impact. |
| 7 | INFO | Legacy `CKRecord.ID` deletion fan-out in `PullCycle.pull()` (post-D1). Intentional, explicitly documented: external-only deletions, no HLC gate, all manifest tables. `deleteSync` is correctly used to prevent echo. | `PullCycle.swift:111-123` | No action needed; document inline that this path is unreachable via the engine's own pushes. |
| 8 | INFO | SideSchema comment "Planned additions: v4 — `_ck_device_identity` Device-slot registry (N2)" implies the table does not yet exist. It does: `DeviceIdentityStore.ensureSchema` deploys it. The planned v4 is a governance consolidation, not initial deployment. | `SideSchema.swift:27-29` | Amend to "v4 — consolidate `_ck_device_identity` (currently deployed by `DeviceIdentityStore.ensureSchema`)" to accurately describe what the consolidation will do. |
| 9 | INFO | `SlotTable.verify()` docstring says "The CloudKit CAS in P1-M3 will confirm or reject it; until then no fencing is possible" (lines 224–225) and repeats the pattern in the inline comment at line 237. P1-M3 is complete; `EpochFence.heartbeat` IS the fencing mechanism. | `SlotTable.swift:224-225,237` | Update docstring and inline comment to describe the current shipped behavior: "EpochFence.heartbeat CAS arbitrates concurrent claims." |

---

## Blast Radius Verification

- **Files claimed in BRR (P1-M1 MUST\_UPDATE):** 18 (Swift + Rust + docs)
- **Files actually in diff:** All 18 confirmed present — StorageObserver.swift, RowStore.swift, InMemoryStorage.swift, InMemoryRowStore.swift, SQLiteStorage.swift, SQLiteStores.swift, CachingRowStore.swift (PK); CloudKitStateActor.swift, ApplyInbound.swift, PullCycle.swift, FederationSyncEngine.swift (CK); observer.rs, inmemory.rs, sqlite.rs, postgres.rs, row\_store.rs (Rust PK); PERSISTENCEKIT\_SPEC, PERSISTENCEKIT\_INTERFACE, CONVERGENCEKIT\_SPEC (docs).
- **MUST\_UPDATE files missing from diff:** None.
- **Prohibited patterns:**
  - Bridges/shims: None found.
  - Orphan `@available(*, deprecated)`: None found.
  - TODO/FIXME on changed symbols: None found.
  - Legacy pendingOutbound as live state: Not present in CloudKit path; Federation pendingOutbound is intentionally retained and documented (Note N4).
- **Stale comment patterns in new code:** Found (Findings #5, #8, #9 above) — wrong HLC bit layout, misleading v4 comment, stale P1-M3-as-future-work text.

---

## Test Execution Verification

| Suite | Method | Bilby's claim | Measured | Exit |
|---|---|---|---|---|
| PersistenceKit (Swift) | B (re-run) | pass | 458 tests, 7 bundles | 0 |
| ConvergenceKit (Swift) | B (re-run) | pass | 126 tests, 22 suites | 0 |
| ConvergenceKit (Rust) | B (re-run) | pass | 14 tests | 0 |
| PersistenceKit (Rust) | B (re-run) | pass | exit 0 | 0 |

Tests pass. Verified exit 0 on all four suites. 126 ConvergenceKit Swift tests include slot registry claim-race, eviction+epoch-bump, exhaustion, epoch-fence push-path, OutboxStore round-trips, and tombstone LWW force-tests.

Note: the eviction+epoch-bump test exercises ghost-path eviction (`lastActiveHLC == HLC.zero` + stale `claimedAt`), which does NOT exercise the 40-bit physicalTime comparison path in `evictionCandidate`. The exhaustion test uses fabricated synthetic timestamps that avoid overflow. Finding #1 is production-only; the test suite does not catch it.

---

## Composition Seam Checks

**PushCycle.swift** — Confirmed clean: fence → readBatch (non-consuming) → encode → `modifyRecords` → `PushResults.process` → confirm/park/incrementRetryCount → receipt using `outcome.pushedCount` (B-2). No double-confirm. Dead `deleteResults` field noted (Finding #6, INFO only).

**CloudKitStateActor.enable() ordering** — Confirmed correct: `CKSideSchema.ensure` → `OutboxStore.drainLeftovers` → `TokenStore.load` → `DeviceIdentityStore.ensureSchema` → `iStore.load()` → `SlotClaimOperation.claim` → conditional `OutboxStore.remintAll` → `HLCGenerator` → observers → `isEnabled = true`. CKSideSchema tables exist before any store accesses them.

**ApplyInbound** — Confirmed: tombstone-first dispatch (`if decoded.isTombstone`), all application table writes via `upsertSync`/`insertSync`/`deleteSync` (origin: `.syncApply`), LWW gate reads from `_ck_sync_meta` via `readSyncHLC`, post-delete `writeTombstoneHLC` persists tombstone HLC for A6 protection.

**SyncMetaStore `is_deleted` consistency** — Confirmed: `writeSyncHLC` writes `is_deleted: .int(0)`, `writeTombstoneHLC` writes `is_deleted: .int(1)`, matching the CKSideSchema `_ck_sync_meta` column declaration `defaultValue: .int(0)`.

---

## Schema Invariant Check

- **No Bool stored columns** in any new side table: `_ck_sync_meta.is_deleted` (INT), `_ck_outbox.retry_count` (INT), `_ck_outbox.is_parked` (INT), `_ck_device_identity` (no Bool columns). Pass.
- **TEXT ISO8601 dates**: `_ck_device_identity.claimed_at` (TEXT ISO8601 via `ISO8601DateFormatter`), `_ck_outbox.enqueued_at` (TEXT), `_ck_change_token.updated_at` (TEXT). Pass.

---

## Scope Check

Diff confined to declared missions. No out-of-scope file modifications observed. Federation pendingOutbound retained (not converted to durable outbox) per Note N4 (CloudKit exclusivity); this is intentional asymmetry, not a missed blast radius site.

---

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| WARNING | 4 |
| INFO | 4 |

CRITICAL #1 is production-breaking: the HLC 40-bit overflow makes the slot eviction candidate picker always return a non-ghost slot for eviction, regardless of actual inactivity. On a 15-slot estate where all slots are active, the first eviction call will evict the "oldest" active device rather than correctly reporting `exhausted`. This is silent data-model corruption — the evicted device will reenroll with a new node ID, breaking HLC continuity for its uncommitted outbox entries until remintAll runs.

Warnings #2–#5 are spec and comment debt that will mislead the P2 implementor. Fix them with this commit, not in a follow-up.

**Fix #1 and the four warnings before dispatching P2.**
