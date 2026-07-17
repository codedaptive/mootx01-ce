# Blast Radius Report — CVK-ICLOUD-P2-M2

**Baseline:** swift test pass count at mission start: 198
**Rust baseline:** 72 tests passing
**Mission:** Column projection on the sync boundary (R2)
**Stream:** CVK-ICLOUD-P2-M2

## Symbol 1: `SyncedTable` (Swift) — additive field `excludedColumns: Set<String>`

**Change class:** additive (new stored property + custom Codable + init default)
**Scope:** public struct in `ConvergenceKit` module

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Sources/ConvergenceKit/SyncTypes.swift` | 43 | direct | MUST_UPDATE | Add `excludedColumns` field, custom Codable init/encode, updated init signature |
| `Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` | 268 | codegraph | MUST_UPDATE | `recordOutbound` must access `excludedColumns` via `manifest?.table(named:)` |
| `Sources/ConvergenceKitCloudKit/Engine/ApplyInbound.swift` | 71 | codegraph | MUST_UPDATE | Inbound projection: strip excluded columns before conflict-policy switch |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 304 | codegraph | MUST_UPDATE | `recordOutbound` must apply projection before `pendingOutbound.append` |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 548 | codegraph | MUST_UPDATE | `applyInbound` must strip excluded columns before conflict-policy switch |

### Summary
- MUST_UPDATE: 5 files (SyncTypes.swift + 4 enforcement points)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

## Symbol 2: New `Sources/ConvergenceKit/Projection.swift` (additive)

**Change class:** net-new pure helpers
**Scope:** public enum, no existing callers

## Symbol 3: Rust `SyncedTable` — additive field `excluded_columns: HashSet<String>`

**Change class:** additive field + builder method
**Scope:** `pub struct SyncedTable` in `src/types.rs`

### Call sites

| File | Source | Classification | Justification |
|---|---|---|---|
| `rust/src/types.rs` | direct | MUST_UPDATE | Add `excluded_columns` field, serde default, `with_excluded_columns` builder |
| `rust/src/federation.rs` | codegraph | MUST_UPDATE | `change_to_record` observer closure must capture and apply exclusion; `apply_record` must strip inbound |

### Summary
- MUST_UPDATE: 2 Rust files
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

## Additive files

- `Tests/ConvergenceKitFederationTests/ProjectionTests.swift` — new test file
- `docs/status/CVK_ICLOUD/P2-M2.md` — new status file

## Siblings note

P2-M1 (fieldLevelLWW) and P2-M3 (postApplyIntegrityHook) also touch
`SyncTypes.swift`. This stream touches ONLY `excludedColumns` and its
enforcement points. Root reconciles the three parallel diffs.
