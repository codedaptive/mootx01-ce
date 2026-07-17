---
title: CVK-ICLOUD Program — Adams Final Post-Flight Review
version: v0.1
status: final
date: 2026-07-17
reviewer: Adams
diff_range: aa4b140f..5d4cd61e
commits: 78
files_changed: 152
---

# POST-FLIGHT: CVK-ICLOUD FINAL GATE

**Final Status: CLEAN-WITH-FOLLOWUPS**

Zero CRITICAL findings. Two WARNING findings. Four INFO observations.
Tests verified passing across all three suites. No bridges, shims, or
partial migrations. All four cross-phase seams coherent.

---

## Test Execution Verification

**Method: B (re-run) — program changes engine code, data-model, persistence, and sync layers.**

| Suite | Claimed | Verified | Exit |
|---|---|---|---|
| ConvergenceKit Swift (4 bundles) | pass | pass | 0 |
| Mootx01-App Swift (incl. SensitivityFilteredStorage 12-test suite) | pass | pass | 0 |
| ConvergenceKit Rust cargo test | 220 tests | 220 passed | 0 |

ConvergenceKit Swift total ~438 tests across ConvergenceKitTests,
ConvergenceKitCloudKitTests, ConvergenceKitFederationTests,
ConvergenceKitConformanceTests. Exit 0 all three invocations.

**Status: PASS**

---

## Blast Radius Verification

- Files claimed in program diff: 152 (78 commits, P0 through P5)
- Files verified in diff: 152
- MUST_UPDATE files missing from diff: none detected
- Prohibited patterns: none (no bridges, shims, orphan `@available(*, deprecated)`)
- Scope violations: none

**Status: PASS**

---

## Cross-Phase Seam Analysis

### Seam (a) — enable() ordering in CloudKitStateActor

18-step sequence verified. CKSideSchema.ensure before any side-table
reads. SkewReplay.drainReady before observers start (echo suppression by
construction). DeviceIdentityStore.ensureSchema/load before HLC generator
uses confirmed nodeID. remintAll before drainDebouncer can fire. isEnabled
set true only at the final step. No step reads state initialized by a later
step.

**Verdict: coherent**

### Seam (b) — disable() teardown completeness vs. P3 additions

P3 additions: drainDebouncer, scheduler, subscription.

- `drainDebouncer`: `await drainDebouncer?.cancel()` — properly awaited in `CloudKitStateActor.disable()`. Deterministic.
- `scheduler`: `await scheduler?.stop()` in `CloudKitSyncEngine.disable()` BEFORE `stateActor.disable()` is called. Properly awaited.
- `ZoneSubscription`: server-side `CKRecordZoneSubscription` — not in-process state; no disable teardown needed or appropriate.
- `observerTasks`: see WARNING #1 below.

**Verdict: structurally complete with one spec/code mismatch (WARNING #1)**

### Seam (c) — SensitivityFilteredStorage protocol coverage

`Storage` protocol (12 required members): all forwarded by `SensitivityFilteredStorage`. Confirmed against `PersistenceKit/Sources/PersistenceKit/Storage.swift`.

`RowStore` protocol (14 required members): all implemented by `SensitivityFilteredRowStore`. insertSync/upsertSync gate on ceiling; deleteSync forwarded unchanged; all transaction members forwarded; temporal query variants covered by protocol defaults.

`StorageObserver`: `SensitivityFilteredObserver` filters observe(); passes observeBlobs() and observeDirtyChain() through unchanged.

Perkins Amendment 1 invariant honored: SensitivityFilteredStorage is the exact handle passed to engine.enable() via SyncController.enable(). The wrapper is constructed before enable() in SyncController.swift:71-72.

**Verdict: complete**

### Seam (d) — PushCycle final composition

Verified step sequence: EpochFence.heartbeat (BEFORE outbox read, satisfying A2/A5) → reenroll if reenrollRequired → OutboxStore.readBatch (non-consuming, R4 durability) → CKRecordMapping.record with columnHLCs from entry.columnHLCsData (B-8) or CKRecordMapping.tombstoneRecord for deletes (D1 fix) → modifyRecords(saving: saved, deleting: [], atomically: false) → PushResults.process per-record classification → confirm/park/incrementRetryCount → SyncReceipt(pushed: outcome.pushedCount, pulled: 0, conflicts: 0).

No dead paths. No double-counting. Empty-outbox path emits zero-receipt correctly.

**Verdict: correct**

---

## Spec Honesty at v1.2 FINAL

Checked I-10, I-11, I-12, B-9 (both backends), B-13, C-14.

- **I-10 (no-echo)**: active. Implementation note "Flipped to active in P5-M4" present. Guard `change.origin != .syncApply` in recordOutbound confirmed. `*Sync` write paths stamp `.syncApply` origin confirmed.
- **I-11 (device slot identity)**: active. 15-slot registry, node 0 reserved, epoch fencing — all implemented.
- **I-12 (durable pipeline)**: active. OutboxStore is SQLite-backed; server change token persisted in `_ck_change_token`. Both survive process death.
- **B-9 (tombstoned deletes)**: active, both backends. `_ck_sync_meta` is_deleted=1 on CloudKit backend; `_fed_sync_meta` on Federation. Tombstone purge clears parked outbox and skew entries (P5-M1b).
- **B-12 note**: `_ck_device_identity still carries its own declaration (planned v4 consolidation)` — honestly documented. No overclaim in spec.
- **B-13 (slot registry contract)**: active. 6-point behavioral contract implemented.
- **C-14 (slot fencing)**: active. reenrollRequired check fires BEFORE outbox entries are read; remintAll runs before any stale-nodeID records reach the wire.

No flipped markers with unsatisfied contracts found.

**Verdict: honest**

---

## Schema Invariants Final Check

**CKSideSchema (SideSchema.swift)**

Tables: `_ck_sync_meta`, `_ck_outbox`, `_ck_change_token`, `_ck_sync_meta_cols`, `_ck_pending_skew`. Version 7.

- `is_deleted`: `.int` (comment: "Int, not Bool (schema invariants)") — PASS
- `is_parked`: `.int` (comment: "Int, default 0 (not Bool per schema invariants)") — PASS
- `retry_count`: `.int` — PASS
- All date columns (`enqueued_at`, `received_at`, `updated_at`, `claimed_at`): `.text` ISO8601 — PASS

**DeviceIdentityStore (`_ck_device_identity`)**

- `id`: TEXT (sentinel "self"), `device_uuid`: TEXT, `slot`: INT, `epoch`: INT, `claimed_at`: TEXT — all PASS.
- No Bool stored columns. Date storage is TEXT.

**Verdict: PASS — zero schema violations**

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution |
|---|---|---|---|---|
| 1 | WARNING | I-2 spec overclaims "awaited" teardown. `observerTasks` are cancelled with cooperative `task.cancel()` — no `await task.value`. Spec says "Teardown of the observation tasks is awaited (Swift)." `drainDebouncer` IS properly awaited; scheduler IS properly awaited in CloudKitSyncEngine. Functionally safe due to actor isolation + debouncer guard, but spec contract is wrong. A future agent reading I-2 may add correctness-critical ordering assumptions that rely on the false "awaited" claim. | `CloudKitStateActor.swift:365`; `docs/reference/CONVERGENCEKIT_SPEC.md` §I-2 | Either (a) update spec I-2 to accurately describe cooperative cancellation — "observerTasks are cooperatively cancelled; completion is not awaited (actor isolation provides the ordering guarantee)" — or (b) add `await task.value` after each `task.cancel()` call if deterministic drain is required. Option (a) is lower blast radius. |
| 2 | WARNING | Stale comment in DeviceIdentityStore.swift. Lines 23-31 say "will land in P1-M4" and "Do not add Bool columns or REAL dates before P1-M4 closes this gap." P1-M4 has shipped (P1-M4.md exists in status dir). The consolidation did not happen. CKSideSchema earmarked v4 for `_ck_device_identity` but P2-M1 jumped to v6 superseding the earmark. The comment now names a completed mission as future work, and issues a conditional instruction that is permanently unactionable. Rule violation per `rules/comment-fidelity.md` ("Stale mission IDs"). A future agent reading this file will be misled about who owns the consolidation and when it should happen. | `DeviceIdentityStore.swift:23-31` | Rewrite the consolidation note to reflect current actual state. Suggested replacement: "Consolidation note (A11 — deferred): `_ck_device_identity` retains its own SchemaDeclaration (kitID 'ConvergenceKit', version 1). Consolidation into CKSideSchema was planned for the P1-M4 v4 earmark but the earmark was superseded when P2-M1 jumped directly to v6. A11 consolidation is tracked in TRACKED_FOLLOWUPS as a future mission. Schema invariants (no Bool columns, TEXT dates) apply in perpetuity." |
| 3 | INFO | Machine path in historical note. P1-M4.md line 121: `/Users/bob/devlop/mootx01-ce/.claire/worktrees/...`. The sentence is documenting a historical artifact (a placeholder file that landed in the wrong place due to a worktree typo). Not an active path reference. No doc says to omit machine paths from completion reports in the CVK_ICLOUD/status dir; however the `no-machine-paths` rule applies fleet-wide. | `docs/status/CVK_ICLOUD/P1-M4.md:121` | Replace the bare machine path with `<worktree>/...` or drop the specific path and keep the description of what happened. |
| 4 | INFO | P5-M4 status file absent. P5-M4 was the docs-only spec finalization mission (removing draft markers from I-10, I-11, I-12 et al, promoting B-9 tombstone note). CVK_ICLOUD status dir contains P5-M1, P5-M1b, P5-M2, P5-M3, RETROSPECTIVE, TRACKED_FOLLOWUPS — no P5-M4.md. The mission content is traceable via git (spec changelog and RETROSPECTIVE account for it). Low risk; does not block. | `docs/status/CVK_ICLOUD/` | Create a minimal P5-M4.md status entry describing the docs-only scope (spec marker promotions, draft removals, changelog 1.2 finalization) so the program record is complete. One paragraph is sufficient. |
| 5 | INFO | A11 (_ck_device_identity consolidation) not in TRACKED_FOLLOWUPS. It is acknowledged in spec B-12 ("planned v4 consolidation") but there is no TRACKED_FOLLOWUPS row with file location, suggested scope, or blast radius. If someone runs the TRACKED_FOLLOWUPS as a follow-up program, A11 will be invisible to it. | `docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md` | Add item #12: A11 consolidation — merge `_ck_device_identity` into CKSideSchema at the next version bump. Name `DeviceIdentityStore.swift`, `SideSchema.swift`, the schema migration version, and the additive-compatibility constraint. |
| 6 | INFO | Pre-existing Rust dead_code warnings (not CVK-ICLOUD). `VectorKit ensure_float_index_built_locked` and `mootx01-cli Fresh` variant + `curl_stdout` appear in `cargo test` output. These predate CVK-ICLOUD and are not introduced by this program. Noted for completeness; not in scope. | `packages/kits/VectorKit/rust/`; `apps/mootx01/rust/src/` | Addressed in a separate Rust sweep; not a CVK-ICLOUD action. |

---

## Doc / Status Hygiene

- Conflict markers (`^<<<<<<<` repo-wide): none found
- Machine paths in docs/ (`/Users/` in `*.md`): one instance, P1-M4.md:121 (INFO #3 above)
- Status dir completeness: P0-M1, P0-M3, P1-M0..P1-M8, P2-M1..P2-M4, P3-M1..P3-M4, P4-M1..P4-M6, P5-M1, P5-M1b, P5-M2, P5-M3, RETROSPECTIVE, TRACKED_FOLLOWUPS — present. P5-M4 absent (INFO #4 above).

---

## Final Verdict

Zero CRITICAL. Two WARNINGs, both resolvable with targeted edits to one
spec section and one code comment block. No test failures. No schema
violations. No bridges or shims. All four program seams coherent.

WARNINGs do not block Wave B by themselves — both are documentation/spec
alignment issues, not correctness defects. Bilby should address both
before the next mission that touches the affected files, per standard
practice. If Wave B launches immediately, the WARNING resolutions can
ride the first Wave B commit that touches either file.

**CLEAN-WITH-FOLLOWUPS. Ship it.**

---

*Adams — post-flight review. CVK-ICLOUD program, develop/1.1.x,
aa4b140f..5d4cd61e. 2026-07-17.*
