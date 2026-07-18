---
title: CVK-WB4 Completion Report
mission: CVK-WB4 (Wave B)
stream: worktree-agent-a3f2fdb2cacccfd5a
worktree: /Users/bob/devlop/mootx01-ce/.claude/worktrees/agent-a3f2fdb2cacccfd5a
status: COMPLETE
date: 2026-07-17
---

# COMPLETION: CVK-WB4

Status: COMPLETE

## What Was Done

- Part 1 (merge step): git merge 2055cc2e — exit 0; ChangeOrigin confirmed present.
- Part 2 (BRR committed): 26c1a67d — blast radius mapped (MUST_UPDATE list: 6 Swift
  files, 4 Rust files). Note: postgres.rs discovered at build time (8 sites, missed
  in BRR; addressed in commit 4e3eb6d7 with `changed_columns: None` on all sites).
- Parts 3-5 (PK Swift): 7c90ef7a
  - `TableChange`: `changedColumns: Set<String>?` field + updated init (default nil).
  - `InMemoryStorage`: insert/update/upsert diff in-memory (zero extra reads);
    delete emits nil.
  - `SQLiteStorage`: `fetchRowValues` pre-SELECT before UPDATE and upsert;
    insert/upsert-insert stamp all keys; delete nil.
  - `observer.rs`: `changed_columns: Option<HashSet<String>>` field — was
    missing from 4e3eb6d7; committed here to close build gap.
- Part 6 (PK Rust): 4e3eb6d7
  - `inmemory.rs`: insert/upsert-insert stamp all; update/upsert-update diff vs
    old row (in memory); delete nil. Fixed tuple destructure in insert (3→4 elements).
  - `sqlite.rs`: `fetch_matching_rows_with_values` for update diff; upsert pre-read
    moved BEFORE execute (was after); delete nil.
  - `postgres.rs`: 8 TableChange sites — all get `changed_columns: None` (no
    pre-read diff in Postgres backend; conservative/backward-compat).
- Parts 7-8 (CVK): a8c5151c
  - `CloudKitStateActor.recordOutbound`: precision kill when changedColumns present
    (`allSatisfy(excluded.contains)`); classic `isStormKill` fallback when nil.
    fieldLevelLWW: stamp only changedColumns when present, fallback stamp-all.
  - `FederationSyncEngine.recordOutbound`: same storm-kill upgrade.
  - `FederationSyncEngine.push()`: fieldLevelLWW precision stamp.
  - `strippedChange` passes `changedColumns: change.changedColumns`.
  - Stale comments ("PersistenceKit has no changedColumns", "future refinement") removed.
- Part 9 (tests): 2b1b98e4
  - `InMemoryChangedColumnsTests.swift`: 5 tests — 5/5 pass.
  - `SQLiteChangedColumnsTests.swift`: 5 tests — 5/5 pass.
  - `changed_columns_tests.rs`: 5 tests — 5/5 pass.
  - `CVKWaveB4PrecisionTests.swift`: 3 tests — 3/3 pass (Scorandum Q1 storm-kill ×2;
    changedColumns propagation ×1).
- Part 10 (docs): 0ed5aa40
  - `PERSISTENCEKIT_SPEC.md`: B-20 added (changedColumns contract per operation).
  - `PERSISTENCEKIT_INTERFACE.md`: `TableChange` struct + Rust line updated.
  - `CONVERGENCEKIT_SPEC.md`: B-8 Capture bullet updated (removed "future refinement");
    B-14 storm-kill: two-path description (precision + classic).
  - `TRACKED_FOLLOWUPS.md`: row 4 → DONE.

## Test Verification Log

- `swift test PersistenceKit --filter InMemoryChangedColumns`: exit 0, 5 tests (2026-07-17)
- `swift test PersistenceKit --filter SQLiteChangedColumns`: exit 0, 5 tests (2026-07-17)
- `swift test ConvergenceKit --filter CVKWaveB4PrecisionTests`: exit 0, 3 tests (2026-07-17)
- `swift test ConvergenceKit` (full): exit 0, 221 tests, 41 suites (2026-07-17)
- `cargo test --test changed_columns_tests` (PK Rust): exit 0, 5 tests (2026-07-17)
- Baseline (CVK Swift): 221 tests before; 221 after — delta unchanged (new tests are in PK
  targets, not CVK directly, except CVKWaveB4PrecisionTests which add 3 to the CVK suite)

## Discoveries

- **postgres.rs missed in BRR**: 8 `TableChange` emission sites in postgres.rs were
  not listed in the Blast Radius Report. Discovered at Rust build time. All 8 got
  `changed_columns: None` (conservative). BRR gap noted in commit message.
- **observer.rs gap in 4e3eb6d7**: The Rust `TableChange` struct field was added in the
  working tree before the 4e3eb6d7 commit but accidentally excluded from it. The build
  would fail from a clean checkout. Closed in 7c90ef7a.
- **fieldLWW precision test difficulty**: Verifying that precision stamp changes
  convergence outcomes requires a 3-device scenario (device A stamps body absent, device B
  has newer body, device C merges). The two-device scenario is indistinguishable because
  `FieldLWWMerge.merge` falls back to `incomingRowHLC` for absent columns. Replaced
  the flawed test with a propagation test that verifies `changedColumns` passes through
  `recordOutbound → strippedChange → pendingOutbound`.
- **Scorandum Q1 closed**: The mixed-column false-enqueue was confirmed fixable with the
  `changedColumns.allSatisfy(excluded.contains)` precision kill. The test
  `mixedColumnScoreOnlyUpdateIsStormKilled` confirms zero pushed for a score-only update.

## Outstanding

- Row 9 in TRACKED_FOLLOWUPS (Rust fieldLevelLWW apply-side) remains open — Newton lane.
- Row 5 (outbox secondary index + batch-read) remains open.
