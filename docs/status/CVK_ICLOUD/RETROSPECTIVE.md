---
title: CVK-ICLOUD Program Retrospective
version: v0.1
status: active
date: 2026-07-17
description: "End-of-program retrospective for the CVK-ICLOUD ConvergenceKit iCloud integration program."
---

# CVK-ICLOUD Program Retrospective

## Program Summary

CVK-ICLOUD shipped ConvergenceKit's iCloud multi-device sync arm across
30 missions in 5 phases, running from the concurrent multi-device decision
(P0) through iCloud wire integration (P1), ConvergenceKit v1.2 feature
work (P2), engine hardening (P3), conformance and performance (P4), and
production wiring with program closeout (P5).

## Phases and What Shipped

### Phase 0 — Architecture and Decisions
Two missions established the concurrent multi-device decision record
(DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md) and the
Kong architecture review (CVK_ICLOUD_KONG_REVIEW.md). These locked the
15-slot HLC registry design (N2), the sensitivity ceiling posture, and the
five questions (Q1–Q5) whose adjudications drove later work.

### Phase 1 — Core iCloud Engine
Nine missions (P1-M0 through P1-M8) built the CloudKit engine from the
ground up:
- Engine decomposition from monolith to focused files (P1-M0).
- Echo suppression via `TableChange.origin` / `ChangeOrigin` across
  PersistenceKit and ConvergenceKit (P1-M1).
- Device slot registry core with fenced eviction types (P1-M2).
- CloudKit tombstoned deletes: `Tombstone.swift`, `SyncRecord.syncDeleted`,
  Rust `sync_deleted` wire parity, Federation A6 migration (P1-M7,
  split across three parts).
- Durable coalescing outbox with consolidated side-table schema (P1-M4).
- CloudKit server change token persistence per zone (P1-M5).
- Per-record push error taxonomy and `retryAfterSeconds` floor (P1-M6).
- Drop of spurious `pushCompleted` start signal (P1-M8).

### Phase 2 — ConvergenceKit v1.2 Feature Surface
Four missions added the three v1.2 feature surfaces:
- `fieldLevelLWW` per-column HLC policy, column HLC maps, FieldLWWMerge,
  ColumnHLCStore, side-schema v3→v6 (P2-M1).
- Column projection (`excludedColumns`), storm-kill outbound suppression,
  inbound column drop, Rust parity (P2-M2).
- `postApplyIntegrityHook` on `SyncManifest`; `AppliedBatch` type;
  hook invocation in both CloudKit and Federation pull paths (P2-M3).
- Consumer contract document (`CONVERGENCEKIT_PLAYGROUND_RULES.md`) (P2-M4).

### Phase 3 — Engine Hardening and Live Loop
Four missions added the live push/pull loop and schema robustness:
- Debounced automatic outbox drain with `OutboxDrainDebouncer`; single-step
  backoff on transport failure (P3-M1).
- Adaptive tiered poll scheduler (`PollTierPolicy`, `AdaptivePollScheduler`)
  with `nudge()` seam (P3-M2).
- Zone subscription and remote-wake accelerator (`ZoneSubscription.swift`,
  `RemoteWake.swift`, `handleRemoteNotification`) (P3-M3).
- Schema-skew pending queue (`PendingSkewQueue.swift`, `SkewReplay.swift`)
  with enable-time replay and `recordsHeldForMigration` event (P3-M4).

### Phase 4 — Conformance, Simulation, and Performance
Six missions validated correctness and performance:
- Two-estate concurrent simulation harness (`TwoEstateFixture`,
  `ConvergenceScenarios`, `FaultInjector`); PersistenceKit UUID/TEXT
  coercion fix found during integration (P4-M1).
- Crash-recovery scenarios; CKRecord type-tag fidelity fix (`NSNumber`
  integer/float tags disambiguated, critical bug #4) (P4-M2).
- Slot exhaustion/eviction/fencing scenarios (`SlotFencingScenarios`,
  `SlotRegistryTests`) (P4-M3).
- Perkins security review; TombstoneGC 40-bit mask fix (critical bug #3)
  (P4-M4).
- Scorandum performance pass; perf benchmarks; read-path optimization
  (P4-M5).
- Executable conformance rows C-9..C-15; B-6 dual-layout reconciliation
  for `CKRecordMapping.packed()` vs `SubstrateTypes.HLC.packed` (P4-M6).

### Phase 5 — Production Wiring and Closeout
Five missions wired the engine into the app and closed the program:
- `SensitivityFilteredStorage` wrapper; ConvergenceKit iCloud arm wired
  into `GatewayRuntime` with `SyncController`; disabled by default pending
  user toggle (P5-M1).
- Tombstone purge of stale skew-queue and parked-outbox payloads on
  tombstone apply (P5-M1b).
- APNs push accelerator in `moot-mgr`; app-hosted `CloudKitSyncEngine`
  with full engine lifecycle in `MinerEngine` (P5-M2).
- Multi-device iCloud sync user guide (P5-M3).
- Program closeout: SPEC v1.2 final, INTERFACE v1.6 final, PLAYGROUND_RULES
  v0.2, comment-fidelity sweep, TRACKED_FOLLOWUPS ledger, RETROSPECTIVE (P5-M4).

## The Four Root-Fixed Critical Bugs

These were implementation bugs found during conformance testing that required
root fixes (not workarounds):

**1. Echo loop (P1-M1).** The CloudKit and Federation engines fired the
storage observer on inbound `applyInbound` writes, which re-entered the
outbox, which pushed the change back to the sender, which applied it again.
Two live machines ping-ponged forever. Root fix: `PersistenceKit` stamped a
`ChangeOrigin.syncApply` tag on all sync-path write methods
(`insertSync`/`upsertSync`/`deleteSync`). `recordOutbound` guards on
`change.origin != .syncApply` in both backends.

**2. SlotTable 40-bit truncation (P4-M3).** The fenced eviction long-inactivity
path compared `lastActiveHLC.physicalTime` (a 40-bit truncated value, because
HLC.packed uses a 40-bit physical field) against a full-width millisecond
timestamp. In 2026, Unix-ms (~1.75e12) exceeds 2^40 (~1.10e12), so every
non-ghost slot's physicalTime was truncated to negative or near-zero, making
every slot appear 35 years stale and permanently eviction-eligible. Silent
divergence: any slot could be evicted instantly, fencing active devices.
Root fix: mask both sides of the comparison into the same 40-bit space.
`SlotFencingScenarios.swift` provides named extractor helpers as ground truth
for both HLC packing layouts.

**3. TombstoneGC 40-bit mask (P4-M4).** The same 40-bit vs 64-bit comparison
class appeared in `TombstoneGC`: the GC retention window compared a full-width
`Date` against a 40-bit-truncated HLC physicalTime, causing all tombstones to
appear older than the retention window and GC them immediately. Root fix: apply
the same 40-bit mask to the wall-clock threshold before comparison.

**4. CKRecord type-tag fidelity (P4-M2).** `CKRecordMapping.toTypedValue` used
`NSNumber.intValue` and `NSNumber.doubleValue` to coerce CloudKit number
values, but NSNumber does not distinguish integers from floats by value — an
integer `3` stored as `NSNumber` and decoded as `doubleValue` returns `3.0`,
colliding with a genuine float. The `SyncValueBox.bitmap` and `.float` cases
became indistinguishable on the receive side. Root fix: inspect the Objective-C
type encoding (`NSNumber.objCType`) to select the correct `SyncValueBox` case
before any numeric coercion.

## Deviations from the Original Plan

**P1-M7 was split into three parts.** Tombstoned deletes required
simultaneous changes to `SyncRecord.swift` (Rust + Swift wire type), the
CloudKit apply path (`_ck_sync_meta` v2 + tombstone HLC persistence), and
the Federation apply path (`_fed_sync_meta`). These had a shared blast
radius but were implemented in three sequential commits to keep each
verifiable independently.

**P4-M4 (Perkins) was run twice.** The first run generated a findings doc.
A fable-model redo produced the root-cause analysis and the TombstoneGC
fix. Both contributions are recorded in `docs/status/CVK_ICLOUD/P4-M4.md`.

**B-6 dual-layout reconciliation was deferred to P4-M6.** The original spec
described a single `48/12/4` HLC packing layout. During P4-M3 conformance
work, `SlotTable.swift` revealed that `SubstrateTypes.HLC.packed` uses a
distinct `node 8b | logical 16b | physical 40b` layout. The spec was not
updated until P4-M6, leaving comments citing "48/12/4" that referred
ambiguously to the CloudKit wire layout but not to the SubstrateTypes layout.
P4-M6 formally named both layouts and P5-M4 swept all remaining comments.

**TombstoneGC was not scheduled in production.** Implementation and tests
landed in P4-M4, but the app-tier scheduling call was deferred to a
follow-up (TRACKED_FOLLOWUPS item 7). The GC runs in tests; in the
production app it is never invoked.

## Lessons Learned

### Stale-worktree lesson

Several mid-program missions merged into a worktree that was one or two base
commits behind `develop/1.1.x`. The pattern: a base merge was dispatched,
completed, and merged to develop, but a parallel worktree was not rebased.
The next mission in that stream then built on a base that did not include
the recently-merged fixes, and the conformance test suite showed failures
from the missing prerequisite. Mitigation: the standard `STEP ZERO` protocol
now mandates an explicit `git merge <SHA>` with verification before any
implementation work begins.

### Watchdog lesson

Swift test runs for the full ConvergenceKit suite (including perf benchmarks)
exceed 300 seconds on CI-equivalent hardware. Without a watchdog timeout,
a hung test runner would silently stall the mission indefinitely. The mission
template now mandates `pgrep stale swiftpm` as a pre-test step and imposes
explicit watchdog limits (300 s for kit, 900 s cold for app target) on every
`swift test` invocation.

### Echo loop found late

The echo loop bug (critical bug #1) was in the first batch of code
(P1-M1), but it was not caught until P4-M1 integration testing with
two live estates. Unit tests for individual components do not exercise
the full push→apply→observe→push cycle. The two-estate harness (P4-M1)
was the instrument that made the loop visible. Lesson: integration tests
with two live `FederationSyncEngine` instances should be in scope from
the first outbox+observer integration, not deferred to Phase 4.
