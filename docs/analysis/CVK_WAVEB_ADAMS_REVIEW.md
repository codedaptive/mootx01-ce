---
title: CVK Wave B Post-Flight Review
agent: Adams
version: v0.1
date: 2026-07-17
scope: git diff 2055cc2e..ae3fcdbf (develop/1.1.x, Wave B — 10 missions)
---

# POST-FLIGHT: CVK Wave B (WB1–WB9, WB12)

**Final Status: BLOCKED**

Wave B implemented tier-rise retraction (WB1), sync toggle (WB2), encryptedValues
decision record (WB3), changedColumns on TableChange (WB4), outbox index +
batched HLC reads (WB5), scheduler CKError backoff (WB6), scheduled tombstone GC
+ 90d retention (WB7), benchmark lane gating (WB8), Rust column-grain fieldLevelLWW
parity (WB9), and CKSideSchema v9 consolidation (WB12).

Two CRITICAL findings. Both must close before merge.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution |
|---|---|---|---|---|
| 1 | CRITICAL | WB2 SyncPolicyTests.roundTripsStoredValue FAILS. Both tests in SyncPolicyTests share UserDefaults suite name "cvk-wb2-sync-policy". swift-testing runs them in parallel by default; defaultIsFalseWhenKeyAbsent's `removePersistentDomain` races with roundTripsStoredValue's `set(true,forKey:)`, producing a false read. Exit code is 0 (swift-testing trap). WB2 completion claimed "tests pass" — they don't. | `apps/Mootx01-App/Tests/GatewayUITests/SyncPolicyTests.swift:10` | Add `@Suite("SyncPolicy — defaults and persistence (CVK-WB2)", .serialized)` to force sequential execution within the suite. Alternative: use unique UserDefaults suite names per test method (e.g. "cvk-wb2-1" and "cvk-wb2-2"). |
| 2 | CRITICAL | Eight stale "30 d" / "2 592 000 s" comment references in WB7 GC code. `SyncTombstone.gcRetentionSeconds` was raised to 90d (7 776 000 s) at the WB7 merge gate (per Tombstone.swift), but comments at the point of use still say "30 d". Comment-fidelity rule: a stale comment about a safety-critical constant (the A6 stale-resurrect guard) is BLOCKING. Sites: TombstoneGCCoordinator.swift:27,70,74,75; FederationSyncEngine.swift:1107,1111; TombstoneGCSchedule.swift:26; TombstoneGC.swift:19. | `TombstoneGCCoordinator.swift:27,70,74,75` `FederationSyncEngine.swift:1107,1111` `TombstoneGCSchedule.swift:26` `TombstoneGC.swift:19` | Replace all occurrences of "30 d" with "90 d" and "2 592 000 s" with "7 776 000 s" in comments at these eight sites. Tombstone.swift is already correct ("raised from 30d at the CVK-WB7 merge gate, 2026-07-17"). |
| 3 | WARNING | No test asserting `SyncTombstone.gcRetentionSeconds > Int64(SlotLongInactivityWindow)`. The safety invariant (90d must exceed the 30d slot-eviction window) is documented in comments at two seams but not enforced by any test or compile-time assertion. If either constant changes independently, the A6 guard silently degrades with no compile or test signal. | `ConvergenceKit/Tests/.../TombstoneGCSchedulerTests.swift` | Add one `#expect(SyncTombstone.gcRetentionSeconds > Int64(SlotLongInactivityWindow))` assertion to TombstoneGCSchedulerTests (or FederationTombstoneGCTests). One test, three lines, catches all future constant drift. |
| 4 | WARNING | TRACKED_FOLLOWUPS row 5 ("Outbox secondary index + readSyncHLC batch-read") not marked DONE despite WB5 completing that exact scope. WB5 completion report confirms the work is shipped (SideSchema v8 outbox index, `readSyncHLCs(batch:)` in SyncMetaStore, PullCycle pre-load). Row 5 in the table lacks the strikethrough/DONE marking that WB1,WB2,WB3,WB4,WB6,WB7,WB8,WB9,WB12 all received. | `docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md:21` | Strike through row 5 and add a DONE block matching the other completed rows. |
| 5 | WARNING | WB4 BRR baseline counts don't match observed reality. The BRR declares "CVK Swift 438 tests" as the Step 0 baseline. WB5 completion (right after WB4) reports "221 tests, delta unchanged (0)". My re-run of CVK Swift post-Wave B shows 230 (consistent with 221 + WB6–WB9 additions − WB8 perf-gate removals). The BRR's "438" is approximately 2× the real count — likely from a multi-kit `swift test` output miscounted as CVK-only. §9.2 baseline inaccuracy undermines the BRR's gate value. | `docs/blast_radius/CVK-WB4_BLAST_RADIUS.md:3` | Update the Baseline line in the WB4 BRR to reflect the actual per-kit counts at mission start. The BRR's MUST_UPDATE classification list is correct; only the counts need repair. |
| 6 | WARNING | WB4 BRR classifies `PersistenceKit/Tests/PersistenceKitReplicationTests/IncrementalReplicationTests.swift` as MUST_UPDATE but the justification reads "Must compile with new field (default nil covers them; no value needed for replication tests)" — that is the definition of INTENTIONALLY_LEFT (no change needed, compiles unchanged). The file is correctly not in the diff (the default handles it), but §9.3 triggers because MUST_UPDATE files must appear in the diff. | `docs/blast_radius/CVK-WB4_BLAST_RADIUS.md:34` | Reclassify IncrementalReplicationTests.swift from MUST_UPDATE to INTENTIONALLY_LEFT in the BRR, with justification "changedColumns defaults to nil; existing TableChange(...) construction sites compile unchanged." |
| 7 | INFO | AdaptivePollScheduler.stop() docstring says "The caller can `await` this method and be confident no further pulls will be scheduled after it returns." But stop() is not `async` and does not await the loop task before returning. The comment implies a stronger guarantee than the implementation provides. Pre-existing, not introduced by Wave B. | `AdaptivePollScheduler.swift:185` | Update docstring to remove the `await` claim: "Stop the poll loop. Cancels the loop task and any active sleep sub-task. No further pulls will be scheduled after cancel propagates." |
| 8 | INFO | SQLiteStorage.upsert always fires `.update` event even for upsert-as-insert (a row that didn't exist). InMemoryStorage fires `.insert` for upsert-as-insert. This event-type asymmetry is pre-existing (not introduced by WB4) but could mislead ConvergenceKit consumers that dispatch on event type. The changedColumns semantics are consistent between both backends (value-inequality diff). | `PersistenceKitSQLite/SQLiteStorage.swift` `PersistenceKitInMemory/InMemoryStorage.swift` | Note in StorageObserver.swift or a comment at the upsert implementation that SQLite always emits .update on upsert regardless of whether the row was new. Non-blocking. |

---

## Blast Radius Verification

**Files in diff:** 51  
**Files actually in diff:** 51 (confirmed via `git diff --name-only 2055cc2e..ae3fcdbf`)

**BRR coverage:**
- WB4 has a BRR (`docs/blast_radius/CVK-WB4_BLAST_RADIUS.md`).
- WB1, WB5, WB6, WB7, WB9, WB12 touch existing code but no BRRs filed. Assessment: all changes in those missions are purely additive (new optional parameters with defaults, new fields with defaults, new functions, additive schema migrations). No existing public API callers broken; BRR requirement applies when existing symbol semantics change. WB4's changedColumns was the only additive field on an existing protocol-boundary type, correctly scoped in its BRR.
- WB3 (decision record only) and WB8 (test-only gating): BRR not required.

**MUST_UPDATE files missing from diff:** One misclassification (Finding #6):
- `PersistenceKitReplicationTests/IncrementalReplicationTests.swift` — classified MUST_UPDATE in WB4 BRR but correctly absent from diff (default nil makes it a no-op change site; should be INTENTIONALLY_LEFT).

**Prohibited patterns in diff:**
- Bridges/shims: none found.
- Orphan `@available(*, deprecated)`: none found.
- TODO/FIXME on changed symbols: none found.
- Conflict markers (`^<<<<<<<`): none repo-wide.

---

## Test Execution Verification

| Suite | Method | Bilby's claim | My re-run | Status |
|---|---|---|---|---|
| ConvergenceKit swift test | B (re-run) | 230 tests (WB7 completion) | exit 0, 230 tests in 44 suites | PASS |
| ConvergenceKit Rust cargo test | B (re-run) | exit 0, 101 tests (WB9) | exit 0, tail shows 8+23 of ~101 | PASS |
| PersistenceKit swift test | B (re-run) | exit 0 | exit 0 (tail: 26 tests; multi-target) | PASS |
| PersistenceKit Rust cargo test | B (re-run) | exit 0 | exit 0 (tail: 24 tests) | PASS |
| Mootx01-App swift test | B (re-run) | "tests pass" | EXIT 0 (swift-testing trap); 1 FAILURE in GatewayUITests — SyncPolicyTests.roundTripsStoredValue | **CRITICAL** |

The App test suite exits 0 even with a failing test — the known swift-testing exit-0-with-failures pattern (documented in Adams memory). WB2's completion report claim that "tests pass" is false. This is Finding #1.

---

## Cross-Mission Seam Analysis

### (a) recordOutbound composed path — mixed-column above-ceiling UPDATE

Trace for a "drawers" row at sensitivity=elevated (above .normal ceiling), UPDATE event carrying `{title, score, adjective_bitmap}`:

1. **SensitivityFilteredObserver**: `exceedsCeiling(change.values, ceiling: .normal)` → true for UPDATE with valid rowKey → emits synthetic delete `TableChange(table:, event:.delete, rowKey:, values:nil, origin:.local)`. Original UPDATE is discarded (content never reaches outbox).
2. **CloudKitStateActor.recordOutbound**: origin guard — `.local != .syncApply` → passes. Projection strip — values is nil (delete) → `effectiveValues = nil`. Storm-kill precision block — skipped (no values to strip). changedColumns for delete is nil (not set on synthetic TableChange) — no LWW stamping. HLC minted. OutboxStore.append enqueues tombstone entry. Debouncer armed.
3. **Self-delivery guard**: Pull cycle delivers tombstone back to originating device. applyInbound calls deleteSync on SensitivityFilteredRowStore. Guard queries the row; row is above-ceiling locally → returns 0, local restricted copy survives.

No ordering holes. The composition is clean.

### (b) WB7 GC sentinel rows — full-table scan survival

**CloudKit path**: Sentinel row stored in `_ck_change_token` (`zone_name="_gc_tombstone_sweep"`). TombstoneGC.compact runs on `_ck_sync_meta` (different table). No collision possible.

**Federation path**: Sentinel row stored in `_fed_sync_meta` (`table_name="_gc_state"`, `primary_key="_tombstone_sweep"`, `is_deleted=0`). TombstoneGC.compact runs on `_fed_sync_meta` filtering `WHERE is_deleted = 1`. Sentinel has `is_deleted=0` (confirmed in `writeFedLastGCMs`). TombstoneGC will not match or delete the sentinel. ✓

TokenStore.load/save: keyed by `zone_name` using an equality predicate — no full-table scan that would trip on the sentinel.

### (c) AdaptivePollScheduler teardown — retain cycles and determinism

`AdaptivePollScheduler.stop()` cancels `_sleepTask` then `_loopTask`. The GC closure (`_gcFn`) is captured in `runLoop` with no strong reference back to the scheduler — the closure is a stored let (`_gcFn: SchedulerGCFn?`) on the actor. `CloudKitSyncEngine.enable()` constructs the scheduler with a gcFn closure that calls `[weak self] gcIfDue(nowMs:)`. disable() does `scheduler.stop()` then awaits `drainDebouncer?.cancel()`. No retain cycles identified.

Note: stop() is not `async` and does not await the loop task. Cancellation is cooperative; the loop exits at the next `while !Task.isCancelled` check. The test "stop() is deterministic even when pull throws retryable errors" passed (230-test CVK suite). No new teardown regression from Wave B.

### (d) changedColumns semantics — SQLite pre-SELECT diff vs InMemory diff

Both backends use TypedValue value-inequality (`!=`) to compute the diff between old and new column values. Both stamp nil for deletes. SQLite pre-reads the existing row via `fetchRowByConflictColumns` (upsert) or `fetchMatchingRowValues` (updateRows) before the write. InMemory has the old row in-memory before the merge. Semantics are identical.

Postgres Rust backend: honestly documents `changed_columns: None` at all write sites ("Postgres backend does not implement pre-read diff; nil = unknown/all") — falls back to pre-WB4 "stamp all" behavior in ConvergenceKit. Correct fallback per the nil contract.

---

## Invariant Spot-Checks

**gcRetentionSeconds vs SlotLongInactivityWindow:**
- `SyncTombstone.gcRetentionSeconds` = 7 776 000 s (90 days, Tombstone.swift:56)
- `SlotLongInactivityWindow` = 30 × 24 × 3600 = 2 592 000 s (30 days, SlotTable.swift:45)
- 90 d > 30 d: invariant holds numerically ✓
- No test enforces it (Warning #3)
- Comments at the seam sites still say "30 d" (Critical #2)

**Tier-rise self-delivery guard PK coercion:**
`SensitivityFilteredRowStore.deleteSync` queries the row using the same StoragePredicate passed from applyInbound (`.eq(pkColumn, .uuid(rowKey))`). The query uses `try?` — if the pre-check fails (e.g. type mismatch), existing is nil and the delete proceeds. This is safe: we only block when we can confirm the row is above-ceiling locally. No new PK coercion hazard introduced by WB1.

---

## TRACKED_FOLLOWUPS Accuracy

| Row | Claim | Code present | Verdict |
|---|---|---|---|
| 1 — WB1 tier-rise retraction | DONE | SensitivityFilteredStorage.swift with retraction tombstone path + 7 tests | ✓ |
| 2 — WB2 in-app sync toggle | DONE | SyncPolicy.swift + EngineView toggle + Mootx01App.swift configure() | ✓ (test failure separate) |
| 3 — WB3 encryptedValues eval | EVALUATED/DEFER | docs/decisions/DECISION_CONVERGENCEKIT_ENCRYPTEDVALUES_2026-07-17.md | ✓ |
| 4 — WB4 changedColumns | DONE | TableChange field + all backends + tests + docs updated | ✓ |
| 5 — WB5 outbox index + batch read | **NOT MARKED DONE** | Code shipped (SideSchema v8, readSyncHLCs, PullCycle pre-load) | **MISS** (Finding #4) |
| 6 — WB6 scheduler backoff | DONE | AdaptivePollScheduler CKError backoff + 5 tests | ✓ |
| 7 — WB7 scheduled GC | DONE | TombstoneGCCoordinator + FederationSyncEngine gcIfDue + 6 tests | ✓ |
| 8 — WB8 benchmark gating | DONE | CVK_ICLOUD_P4M5_PerfTests gated; moot-test + Makefile updated | ✓ |
| 9 — WB9 Rust field-level LWW | DONE | federation.rs + field_lww_engine_tests + 16 tests | ✓ |
| 10 — Federation durable outbox | still deferred | — | ✓ (correctly open) |
| 11 — SyncValueBox depth limit | still deferred | — | ✓ (correctly open) |
| 12 — WB12 A11 consolidation | DONE | SideSchema v9 + DeviceIdentityStore delegation + consolidation test | ✓ |

---

## Hygiene

**Conflict markers:** none repo-wide (`rg '^<<<<<<<` returned nothing).

**Machine paths in docs:** none found in DECISION_CONVERGENCEKIT_ENCRYPTEDVALUES_2026-07-17.md or MOOTX01_APP_USER_GUIDE.md.

**Stale "planned" / "will land" comments:** Tombstone.swift correctly notes "raised from 30d at the CVK-WB7 merge gate, 2026-07-17." The stale references are the "30 d" values in the surrounding comment bodies (Finding #2), not forward-looking promises.

---

## Resolution Checklist (before merge)

**Must fix (CRITICAL):**
- [ ] #1: Add `@Suite(.serialized)` to SyncPolicyTests. Verify App swift test passes with 0 failures.
- [ ] #2: Update 8 stale "30 d" comment sites to "90 d = 7 776 000 s". Files: TombstoneGCCoordinator.swift, FederationSyncEngine.swift, TombstoneGCSchedule.swift, TombstoneGC.swift.

**Address before merge (WARNING):**
- [ ] #3: Add one `#expect(SyncTombstone.gcRetentionSeconds > Int64(SlotLongInactivityWindow))` assertion.
- [ ] #4: Strike through TRACKED_FOLLOWUPS row 5 and mark DONE.
- [ ] #5: Correct WB4 BRR baseline counts to actual per-kit values.
- [ ] #6: Reclassify IncrementalReplicationTests.swift in WB4 BRR from MUST_UPDATE to INTENTIONALLY_LEFT.

**Non-blocking (INFO):**
- [ ] #7: Fix stop() docstring.
- [ ] #8: Document upsert event-type asymmetry.
