---
mission: CVK-WB5
stream: worktree-agent-aa0e0f420c2b4d276
status: COMPLETE
date: 2026-07-17
---

# COMPLETION: CVK-WB5 — Scorandum Q3+Q5 Perf Items (ConvergenceKit)

Status: **COMPLETE**

## What Was Done

**Part 1 (Q3) — Outbox secondary index**
- SideSchema bumped v7 → v8 with composite index `idx_ck_outbox_table_row` on
  `_ck_outbox(table_name, row_key)` via `SchemaDeclaration.indices` + `v7→v8`
  migration using `.addIndex(...)`.
- `OutboxStore.append` coalescing lookup (WHERE table_name=? AND row_key=?) changes
  from O(N) full scan to O(log N) index seek on SQLite backend.
  InMemoryStorage unaffected (no SQL index semantics).

**Part 2 (Q5) — Batch sync-HLC pre-load**
- `SyncMetaStore.readSyncHLCs(batch:storage:)` added — one `primary_key IN [...]`
  query returning `["\(table)|\(rowKey.uuidString)": HLC]`.
- `ApplyInbound.applyInbound` gains `preloadedSyncHLCs: [String: HLC]? = nil`
  (default nil preserves all existing call sites unchanged).
- Private helper `cachedOrReadSyncHLC` consults preloaded map or falls back to
  per-row `readSyncHLC`.
- `PullCycle.pull()` pre-loads the map before the apply loop via `try?`-based
  decode + `readSyncHLCs(batch:)` — graceful degradation if batch query fails.
- Reduces pull-cycle storage I/O from O(N) queries to 1 query + O(N) dict lookups.

**Commit:** `893ee49a perf(convergencekit): outbox index + batched sync-HLC reads (CVK-WB5)`

## Test Verification Log

- `swift build` (ConvergenceKit package): exit 0
- `swift test` (ConvergenceKit package): exit 0, **221 tests, 0 failed**
- Baseline: 221 before mission — delta: **unchanged (0)**
- LWW/tombstone spec tests: all green, unmodified

## Benchmark Deltas (InMemory backend — reflects variance, not SQLite gain)

| Suite | Before | After | Note |
|---|---|---|---|
| Q3a 1k distinct-row appends | 962 ms | 824 ms | InMemory variance; SQLite = O(log N) seek |
| Q3b 1k same-row coalescing | 98.5 ms | 79.7 ms | Same |
| Q5-1K applyInbound direct | 1198 ms | 1034 ms | Direct call bypasses batch path |
| Q5-10K applyInbound direct | 81183 ms | 75386 ms | Same; batch benefit invisible in test |

Real Q5 benefit surfaces in production pull cycles (PullCycle.pull via real
CloudKit). Q5 perf tests call applyInbound directly without preloaded HLCs and
therefore measure the per-row fallback — InMemory variation only.

## Discoveries

- SideSchema was at v7 (CVK-ICLOUD P4M5 took it to v7). Next free version was v8,
  confirmed before bumping.
- `StoragePredicate.in(Column, [TypedValue])` is implemented in `PredicateEvaluator`
  for InMemoryStorage — the batch query runs in tests but without SQL index benefit.
- `ColumnHLCStore` per-column batch read NOT implemented (follow-up noted). The
  return type is a `ColumnHLCMap` (dict-of-dicts) requiring grouping by `(table, row)`,
  and the mission's explicit "else note as follow-up" escape applied.

## Outstanding / Follow-ups

- **TRACKED_FOLLOWUP**: `ColumnHLCStore.readColumnHLCs(batch:)` — batch pre-load
  for per-column HLC reads in `fieldLevelLWW` path. Requires `_ck_sync_meta_cols`
  3-column composite PK grouping and a `ColumnHLCMap`-per-row return shape.
  Lower priority than Q3/Q5 since fieldLevelLWW is not the default policy.
- Sibling missions CVK-WB4 (TableChange.changedColumns) and CVK-WB6
  (AdaptivePollScheduler) run in parallel streams — no overlap with this diff.
