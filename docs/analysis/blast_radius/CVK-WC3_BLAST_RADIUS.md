# Blast Radius Report — CVK-WC3

**Baseline:** cargo test pass count at mission start: 101 (exit 0)
**Mission:** Rust skew-queue parity — _fed_pending_skew + hold/replay (WC3)
**Worker:** Bilby (claude-sonnet-4-6)

## Symbols being changed

### Symbol 1: `ensure_fed_sync_meta_table`
**Change class:** semantic (schema version bump 2 → 3; additive migration only)
**Scope:** private fn in federation.rs

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | 1200 | grep | MUST_UPDATE | Adding v3 _fed_pending_skew table + migration v2→v3 |

### Symbol 2: `pull()` in `SyncEngine for FederationSyncEngine`
**Change class:** semantic (schema-version check replaced with three-branch split)
**Scope:** impl block in federation.rs

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | 628 | grep | MUST_UPDATE | Replace `schema_version !=` with future/downgrade/equal split |

### Symbol 3: `enable()` in `SyncEngine for FederationSyncEngine`
**Change class:** additive (replay block inserted before start_observers)
**Scope:** impl block in federation.rs

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | 529 | grep | MUST_UPDATE | Add skew-queue drain-and-replay on enable |

### Symbol 4: `apply_record()` tombstone arms
**Change class:** additive (P5-M1b purge calls in RemoteWins, LastWriterWinsByHLC, FieldLevelLWW tombstone arms)
**Scope:** free fn in federation.rs

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `packages/kits/ConvergenceKit/rust/src/federation.rs` | 832 | grep | MUST_UPDATE | Add fed_skew_delete_older_than after tombstone apply in three arms |

### New symbols (additive, no blast radius)
- `FED_PENDING_SKEW_TABLE` const
- `FED_SKEW_QUEUE_CAP` const
- `fed_skew_enqueue` free fn
- `fed_skew_evict_if_needed` free fn
- `fed_skew_drain_ready` free fn
- `fed_skew_delete_applied` free fn
- `fed_skew_count_held` free fn
- `fed_skew_delete_older_than` free fn (P5-M1b)
- `iso8601_utc_now` free fn (helper)
- `tests/federation_skew_tests.rs` (new test file)

## Summary
- MUST_UPDATE: 1 file (`federation.rs`, four change sites within it)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

## Non-code references
| File | Classification | Justification |
|---|---|---|
| `docs/analysis/CVK_WAVEC_FEDERATION_CHARTER.md` | INTENTIONALLY_LEFT | Source-of-truth for this mission; read-only |
