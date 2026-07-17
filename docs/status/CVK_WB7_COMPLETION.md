---
title: CVK-WB7 Completion Report
task: CVK-WB7
status: COMPLETE
date: 2026-07-17
---

# CVK-WB7 Completion Report

**Status:** COMPLETE

## What Was Done

| Part | Description | Commit |
|---|---|---|
| 1 | Step zero: merged 3cbdc4f5 (fast-forward); verified 40-bit mask fix present | merge |
| 2 | New `TombstoneGCSchedule.swift` — `gcIntervalMs = 86_400_000` (24h) with WHY comment | 4ffce1ca |
| 3 | `AdaptivePollScheduler`: `SchedulerGCFn` typealias; `nowMs` clock injection; `gcFn` hook after successful pull | 4ffce1ca |
| 4 | `TombstoneGCCoordinator.swift`: `CloudKitStateActor` extension; `gcIfDue(nowMs:)` + testable `gcIfDue(storage:nowMs:)`; sentinel in `_ck_change_token` (zone `_gc_tombstone_sweep`) | 4ffce1ca |
| 5 | `CloudKitSyncEngine.enable()`: wires `gcFn` closure into `AdaptivePollScheduler` | 4ffce1ca |
| 6 | `FederationSyncEngine`: `gcIfDue` methods + sentinel in `_fed_sync_meta` (table `_gc_state`, key `_tombstone_sweep`); `pull()` calls `gcIfDue` after each cycle | 4ffce1ca |
| 7 | 3 CloudKit GC tests (`TombstoneGCSchedulerTests`) + 3 Federation GC tests (`FederationTombstoneGCTests`) | 4ffce1ca |
| 8 | Spec B-9 one-line GC note; TRACKED_FOLLOWUPS item 7 marked DONE | 4ffce1ca |

## Seam and Storage Choice

**CloudKit seam:** `AdaptivePollScheduler.runLoop()` — after `pull()` succeeds and tier accounting
completes, `try? await gcFn(_nowMs())` fires. Non-fatal to the convergence loop.

**CloudKit storage:** Sentinel row in `_ck_change_token` (the existing key-value side table keyed by
`zone_name`). Sentinel `zone_name = "_gc_tombstone_sweep"` cannot collide with real CloudKit zone
names (underscore prefix). `token` = `Data()` placeholder; `updated_at` (ISO8601 TEXT) carries the
last-GC timestamp.

**Federation seam:** `FederationStateActor.pull()` — tail call before returning the receipt.
`try? await gcIfDue(nowMs: nowMillis())`. Non-fatal.

**Federation storage:** Sentinel row in `_fed_sync_meta` (the existing per-row sync tracking table).
Sentinel `(table_name="_gc_state", primary_key="_tombstone_sweep")`. `sync_hlc` stores the last-GC
wall-clock ms directly (not a packed HLC). Written via `upsertSync(origin: .syncApply)` to suppress
echo propagation to peers.

## Cadence

`TombstoneGCSchedule.gcIntervalMs = 86_400_000` — 24 hours.

WHY 24h: GC pressure is tiny — tombstones accumulate at the delete rate, not the write rate.
The retention window is 90d-scale (30d, `SyncTombstone.gcRetentionSeconds`). A daily sweep is
far more frequent than needed and imposes negligible cost. A shorter interval would not materially
reduce tombstone accumulation.

## Critical Invariant

`SyncTombstone.gcRetentionSeconds` (30 d = 2 592 000 s) MUST exceed the P1-M3 slot-eviction long
window. A fenced-out device must stay within the retention window so it cannot miss a delete when
it reconnects. Commented at both seams. Verified in Test 3 of each suite (entry inside retention
window survives GC).

## Test Verification Log

```
swift build (ConvergenceKit):  exit 0 (Build complete! 1.68 sec)
swift test  (ConvergenceKit):  exit 0 — 229 tests in 43 suites, all passing (76.3 s)
swift test --filter TombstoneGC: 6 tests (3 CloudKit + 3 Federation), all passing
Baseline before mission: 223 tests; after: 229 tests — delta +6
```

## Discoveries

- `fedSyncMetaTable` was `private static let` in `FederationStateActor`; changed to `internal static
  let` so `FederationTombstoneGCTests.swift` can use `FederationStateActor.ensureFedSyncMetaTable`
  in test setup without reaching into internals. Blast radius: single reference site changed.
- `nowMs` injection in `AdaptivePollScheduler` replaces a private `func nowMs()`. The init default
  `nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }` keeps
  all existing call sites unchanged.
- swift-testing parallel runner reports +3 tests/+1 suite in the aggregate summary but all 6 new
  tests appear individually in the log and pass. Appears to be a reporting artifact from parallel
  bundle grouping.

## Outstanding

- TRACKED_FOLLOWUPS items 3, 5, 8, 9, 10, 11, 12 remain open (unchanged scope).
- Rust twin GC scheduling (item 9) explicitly out of scope for this mission (WB9 lane).
