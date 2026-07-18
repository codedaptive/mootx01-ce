---
task: CVK-WC3
title: Rust skew-queue parity (_fed_pending_skew + hold/replay)
worker: Bilby (claude-sonnet-4-6)
date: 2026-07-17
---

# COMPLETION: CVK-WC3

Status: COMPLETE

## What Was Done

- Step 0: Merged 8370cc90, verified CVK_WAVEC_FEDERATION_CHARTER.md present.
  BRR committed as 14c11340.

- Part 1 — Schema v3: Added FED_PENDING_SKEW_TABLE constant and
  _fed_pending_skew TableDeclaration; bumped ConvergenceKitFederation
  from v2 to v3; added v2→v3 CreateTable migration.

- Part 2 — pull() three-branch split: Replaced flat schema_version check
  with future/downgrade/equal branches. Future-schema → fed_skew_enqueue +
  skew_held_count. Downgrade → conflicts. Equal → normal apply. Emits
  RecordsHeldForMigration when skew_held_count > 0.

- Part 3 — enable() replay: Drain-ready → apply_record → delete-applied →
  emit RecordsHeldForMigration if still_held > 0. Echo-suppressed by
  construction (observers not started yet).

- Part 4 — Tombstone purge (P5-M1b): fed_skew_delete_older_than called in
  RemoteWins, LastWriterWinsByHLC, and FieldLevelLWW tombstone arms.

- Part 5 — Helper functions: fed_skew_enqueue, fed_skew_evict_if_needed
  (cap 512), fed_skew_drain_ready, fed_skew_delete_applied,
  fed_skew_count_held, fed_skew_delete_older_than, iso8601_utc_now,
  epoch_days_to_date, is_leap_year.

- Part 6 — Tests: federation_skew_tests.rs with 6 test cases.

- Commit: feat(convergencekit-rust): schema-skew pending queue parity (CVK-WC3)
  SHA: 5a2fcdf4

## Test Verification Log

- cargo build: exit 0 (2026-07-17)
- cargo test: exit 0, 107 tests, all passing (2026-07-17)
- Baseline: 101 before mission; 107 after — delta +6
- New tests:
  - hold_then_replay_after_version_bump
  - downgrade_rejected
  - cap_eviction
  - event_emission_during_pull
  - event_emission_on_reenable_with_still_held
  - purge_interplay

## Schema Version Taken

ConvergenceKitFederation v3 (was v2; Swift was already v3 — now in parity).

## Discoveries

- iso8601_utc_now implemented without chrono (no new dep). Gregorian
  calendar math correct for 1970–2099; subsecond precision not needed
  for eviction ordering.

- HLC.physical_time is i64 in Rust (not u64 as assumed from the field name).
  Test helpers needed i64 literal for loop variable.

- OrderClause::ascending takes a Column struct, not &str. Requires
  Column::new(table, column_name) — consistent with rest of predicate API.

- Echo suppression in enable() replay is structural (observers not started
  when drain block runs), not flag-based. Matches the design intent in the
  charter.

- subscriber() can be called after disable() but before enable() — the
  subscribers Vec persists across enable/disable cycles. Used in
  event_emission_on_reenable_with_still_held test.

- Existing pull_rejects_schema_mismatch test (engine_b at schema_version=99
  receiving schema_version=1 records) exercises the downgrade path after
  WC3 changes and passes unchanged — the three-branch split is backward-
  compatible with the prior test setup.

## Outstanding

- Swift fast-lane kit test (sanity) deferred to mission exit per mission
  scope (Rust-only). The Swift leg owns schema-adjacent Swift per WC1.
- Pre-existing unused-import warnings in json_conformance_tests.rs (not
  introduced by WC3).
