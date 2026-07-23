---
title: FAB5-FO Completion Report
mission: FAB5-FO
stream: fo
status: COMPLETE
date: 2026-07-23
worker: bilby
---

# FAB5-FO — Federation Durable Outbox — Completion Report

## Status: COMPLETE

---

## Smythe Pre-flight

**Verdict: YELLOW**  
Terrain navigable. Two findings:

1. **Blast radius scope expansion (YELLOW)**: The DUR-5 race fix (`e784e8c8`) modified two
   PersistenceKit files not in the declared blast radius —
   `PersistenceKit/rust/src/inmemory.rs` and `PersistenceKit/rust/src/row_store.rs`.
   These changes were necessary to fix a TOCTOU race in the Rust echo suppression mechanism
   (see Implementation section). The commit message documents the full rationale. Classified
   as EXPLAINED — correct, intentional, documented.

2. **SPEC delta note required (INFO)**: `CONVERGENCEKIT_SPEC.md` is reserved by stream `ev`
   (complete but unmerged). SPEC delta recorded as follow-up below.

---

## Self-Review

Checked against BRR MUST_UPDATE list:

| Item | Status |
|------|--------|
| `FederationSyncEngine.pendingOutbound` removed | ✅ gone from live code; 8 residual refs are comments only |
| `FedOutboxStore.swift` new file | ✅ present |
| Federation side-schema v7 with `_fed_outbox` | ✅ Swift v4→v5 chain (WC2 step); current v7 |
| `federation.rs` Rust twin — schema, drain, echo | ✅ parity confirmed |
| `FederationDurableOutboxTests.swift` (DUR-1..5) | ✅ present, all pass |
| `federation_durable_outbox_tests.rs` (DUR-1..5) | ✅ present, all pass after DUR-5 fix |
| `CONVERGENCEKIT_SPEC.md` NOT modified (ev reservation) | ✅ untouched by FO stream |
| `OutboxStore.swift` NOT modified | ✅ untouched |
| `ConvergenceKitCloudKit` NOT modified | ✅ untouched |
| Stale `pulling` flag removed from non-comment code | ✅ zero live refs remain |

---

## Implementation

### Mission context
The core implementation (FedOutboxStore, FederationSyncEngine, Rust twin, schema v5 migration,
DUR-1..5 tests) was committed to the develop/1.1.x branch in a prior session (CVK-WC2).
This stream's unique contribution is the DUR-5 race fix.

### Stream-unique commit: `e784e8c8`
`fix(cvk-fed-rs): fix DUR-5 race — switch echo suppression to SyncApply origin`

**Root cause of DUR-5 failure:**  
The Rust echo suppression used `pulling: Arc<AtomicBool>`. `pull()` cleared the flag before
the observer worker processed events buffered during the apply loop. With a 100ms worker tick,
any pull completing in under 100ms caused the worker to see `pulling=false` on events queued
while `pulling=true` — a TOCTOU race.

**Fix:**  
Align the Rust leg with Swift's event-level `change.origin != .syncApply` approach.

- **`PersistenceKit/rust/src/inmemory.rs`**: Added `insert_impl`, `upsert_impl`, `delete_impl`
  helpers accepting a `ChangeOrigin` parameter. Overrode `insert_sync`, `upsert_sync`,
  `delete_sync` on `InMemoryRowStore` to emit `ChangeOrigin::SyncApply`. The public `insert`,
  `upsert`, `delete` delegate to the helpers with `ChangeOrigin::Local` (unchanged behaviour).

- **`packages/kits/PersistenceKit/rust/src/row_store.rs`**: Updated doc comments on the
  `*_sync` trait methods to document the fix and current override state.

- **`packages/kits/ConvergenceKit/rust/src/federation.rs`**:
  - Removed `pulling: Arc<AtomicBool>` field and all 6 usage sites.
  - Observer worker: check `change.origin == ChangeOrigin::SyncApply` (race-free — origin
    stamped at emit time, not consume time).
  - `apply_record`: all 8 application-table write sites switched to `upsert_sync`,
    `insert_sync`, `delete_sync`. Federation metadata writes (`_fed_sync_meta`,
    `_fed_pending_skew`, etc.) stay on plain paths — those tables are not observed by the
    outbox worker.

- **`packages/kits/ConvergenceKit/rust/src/types.rs`**: Updated `AppliedBatch` doc comment
  (removed stale `pulling` flag reference).

**PersistenceKit scope expansion justification:**  
The `InMemoryRowStore` is the only backend used in ConvergenceKit's Rust test suite. Fixing
the race required stamping `ChangeOrigin::SyncApply` at emit time, which requires overriding
the `*_sync` trait methods in `InMemoryRowStore`. The `row_store.rs` change is doc-only.
Neither file modifies the storage behaviour for the production SQLite backend (which doesn't
override `*_sync` — those remain no-ops on SQLite, consistent with the existing transaction
model). This is a minimal, safe extension to a test-support type.

---

## SPEC Delta (follow-up, not in-file — ev reservation active)

**CONVERGENCEKIT_SPEC.md** is reserved by stream `ev` (completion report `9b9f0f8a` exists;
`ev` not yet merged to develop/1.0.x).

**Delta to record when ev merges:**

Section: `B — Outbound pipeline invariants`  
- B-11: `_fed_outbox` durable outbound queue: entries survive process death; loaded into outbox
  on `enable()` (drain-on-enable); pushed in ascending HLC order. Coalescing per
  `(table_name, row_key)` bounds hot-row growth. Gap 6: `hlc_wire` column (full-width 16-byte
  HLC); legacy `packed_hlc` retained for additive migration safety.

Section: `I — Echo suppression`  
- I-10 (Rust leg update): Observer workers check `change.origin == ChangeOrigin::SyncApply`;
  `apply_record` writes via `upsert_sync`/`insert_sync`/`delete_sync` which stamp `SyncApply`
  in `InMemoryRowStore`. Race-free: origin stamped at emit time.

**Follow-up queue entry:**  
`CONVERGENCEKIT_SPEC.md` Federation section (B-11, I-10) — update when ev merges.

---

## Test Verification Log

### Final (2026-07-23)

**Swift:**
```
Command: cd packages/kits/ConvergenceKit && swift test
Exit code: 0
Pass count: 254 in 52 suites
```
Tail output (verbatim):
```
Test run with 254 tests in 52 suites passed after 2.022 seconds.
```

**Rust:**
```
Command: cargo test --manifest-path rust/Cargo.toml
Exit code: 0
Pass count: 138 (all suites)
```
DUR tests specifically:
```
running 5 tests
test dur1_outbox_entries_survive_disable_enable_cycle ... ok
test dur4_leftover_entries_survive_disable_and_visible_after_enable ... ok
test dur2_push_failure_retains_outbox_entries ... ok
test dur5_echo_suppressed_after_engine_reload ... ok
test dur3_two_writes_same_row_coalesce_to_one_outbox_entry ... ok
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.67s
```

**PersistenceKit Rust:**
```
Command: cargo test --manifest-path packages/kits/PersistenceKit/rust/Cargo.toml
Exit code: 0
Pass count: 168+ (all suites green)
```

---

## Discoveries

1. **`pulling: AtomicBool` echo suppression is fundamentally racy.** Any pull completing in
   less than the observer worker's tick (100ms) produces a window where buffered apply-phase
   events are processed after the flag is cleared. The correct fix is always event-level
   origin stamping (as in Swift). This was diagnosed and fixed in this session.

2. **`_fed_outbox` gap 6 (`hlc_wire` column):** The full-width HLC column was added at schema
   v7 alongside `packed_hlc` retention. The coalescing query in `FedOutboxStore.append` uses
   `hlc_wire` for newest-wins ordering. This is present in both legs and tests correctly.

---

## Adams Post-flight

*To be filled after Adams runs (see below).*

---

## Commits on This Stream

| SHA | Message |
|-----|---------|
| `e784e8c8` | `fix(cvk-fed-rs): fix DUR-5 race — switch echo suppression to SyncApply origin` |
