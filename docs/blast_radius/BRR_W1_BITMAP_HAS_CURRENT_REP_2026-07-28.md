---
version: v0.1
mission: stream/w1-bitmap — has_current_representation operational-bitmap bit
date: 2026-07-28
author: newton
---

# Blast Radius Report — has_current_representation (bit 19)

## Mission scope

Assign and implement `has_current_representation` as bit 19 of the
`DrawerFeatureFlags` region (bits 12–23) in the drawer operational bitmap.
The bit is SET when the four distillation columns are populated; CLEAR when
they are NULL. Set and clear travel in the SAME statement as the column
writes, making skew structurally impossible.

---

## Symbols changed

### DrawerOperational.swift / drawer_operational.rs

| Change | Type |
|--------|------|
| `DrawerFeatureFlags.hasCurrentRepresentation` (bit 19) — NEW constant | Additive |
| `Drawer.hasCurrentRepresentation` computed Bool accessor — NEW | Additive |
| Module-level comments updated (bit range `bits 19–23 reserved` → bit 19 named) | Additive |

**Blast radius: zero.** Purely additive. No call sites need to change as a
result of adding a constant.

---

### DrawerStore.swift / drawer_store_inmemory.rs (DrawerStoreImpl)

#### `setDistilledRepresentation` / `set_distilled_representation`

**Change:** Converted from single UPDATE to read-modify-write (read
`operationalBitmap`, OR in bit 19, write with five columns). The function's
public signature is unchanged; the return contract is unchanged (0 = not
found, 1 = success).

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| `GeniusLocusKit.distillItem` | `DistillationCycle.swift` line 138 | None — signature unchanged |
| `GLKCoordinator::distill_items_sweep` | `coordinator.rs` line 2629 | None — signature unchanged |
| `DistillationCycleTests` (test scaffolds) | `DistillationCycleTests.swift` | Update to assert bit set after distillation |
| Rust `distilled_representation_tests` | `drawer_store_inmemory.rs` test mod | Update to assert bit set |

---

#### `countUndistilled` / `count_undistilled`

**Change:** Inner OR predicate's first branch changes from
`.isNull(Column("distilled"))` to
`.bitmaskNone(Column("operationalBitmap"), mask: 1<<19)`.
Return type, parameter, and outer predicate (tombstoned + non-empty) unchanged.

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| `Estate.countUndistilled` | `EstateVerbs.swift` / `estate_verbs.rs` | None — passes through unchanged |
| `GeniusLocusKit.drainStatuses` | `DrainStatus.swift` line 143 | None — no change to call site |

---

#### `updateDatasetContent` (Swift only)

**Change:** Wrapped in a serializable transaction; pre-reads `operationalBitmap`
to clear bit 19. Returns `Int` (row count) rather than calling through the raw
update directly. Internal function; no public API change.

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| `Estate.patchDatasetHandleSignatures` | `DatasetHandle.swift` line ~439 | None — signature unchanged |

---

#### `withClearedRepresentation` call sites — Swift (five sites)

The `withClearedRepresentation` helper uses caller-wins merge semantics.
Each call site that already has `operationalBitmap` in scope will include the
bit-cleared value in the input dict; the helper then folds the four
distillation-column NULLs alongside it.

| Site | Location | Bitmap available as |
|------|----------|---------------------|
| Head drawer expunge | line 1322 | `priorOperational` (line 1270) |
| Sibling already-tombstoned scrub | line 1358 | Read from `sibRow["operationalBitmap"]` |
| Sibling gate-accepted scrub | line 1400 | `sibOperational` (line 1365) |
| Sibling gate-rejected scrub | line 1421 | `sibOperational` (line 1365) |
| `updateDatasetContent` | line 4230 | Pre-read inside new transaction |

---

#### `insert_cleared_representation` call sites — Rust (four sites + bulk wipe)

Same pattern as Swift. Callers insert bit-cleared `operationalBitmap` into
the values map before (or independently of) the function call.

| Site | Location | Bitmap available as |
|------|----------|---------------------|
| Head drawer expunge | line 2030 | `prior_operational` (line 1962) |
| Sibling already-tombstoned scrub | line 2081 | Read via `read_drawer_bitmap` call |
| Sibling gate-accepted scrub | line 2148 | `sib_operational` (line 2104) |
| `patch_dataset_handle_content` | `dataset_handle.rs` line 182 | Pre-read via `row_store.query` |
| `wipe_all_content` bulk wipe | line 2429 | **OUT OF SCOPE** — see note below |

**`wipe_all_content` note:** This function is the estate-destruction bulk wipe
called immediately before the estate is closed and its SQLite file is deleted.
The storage layer does not support expression-based updates, so clearing bit 19
on all rows in one statement is not feasible without either (a) a separate
per-row pass or (b) zeroing the entire operational bitmap (which would corrupt
other feature flags). Since the estate is destroyed immediately after the wipe
and no read path ever accesses these rows again, leaving bit 19 set on destroyed
rows is safe. The function comment already documents the estate-destruction
rationale for not refreshing fingerprints; the same logic applies here.

---

### DistillationCycle.swift — `distillItemsSweep`

**Change:** Eligibility guard changes from `drawer.distilled == nil` to
`!drawer.hasCurrentRepresentation`. Pipeline-version check is unchanged.

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| `GeniusLocusKit.mootDistill` handler | `Distill.swift` line 115 | None |
| `RecipeTools` distill recipes | `RecipeTools.swift` | None |
| `DistillationCycleTests` | test file | Update to assert hasCurrentRepresentation |

---

### EncodeIntake.swift — `wireCorpusRoomRollup`

**Change:** Drain-stage eligibility check changes from `drawer.distilled == nil`
to `!drawer.hasCurrentRepresentation`. Pipeline-version check unchanged.

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| `EstateLifecycle.wireSubstores` | `EstateLifecycle.swift` lines 416, 437 | None — no behavioral change at call site |

---

### coordinator.rs — `distill_items_sweep`

**Change:** Eligibility skip condition changes from `drawer.distilled.is_some()`
to `drawer.has_current_representation()`. Pipeline-version check unchanged.

**Direct callers:**

| Caller | File | Action needed |
|--------|------|---------------|
| Rust `moot_distill` verb handler | `verbs/` | None |

---

### Cookbook and spec

| File | Change |
|------|--------|
| `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md` §2.4 | Assign bit 19 = `has_current_representation`; add semantics and design-tenet rationale |
| `SPEC_DISTILLATION_STORAGE.md` Appendix A (mootx01-ee docs) | One paragraph: migrated rows carry bit clear |

---

## MUST_UPDATE (files that change in this stream)

```
packages/kits/LocusKit/Sources/LocusKit/DrawerOperational.swift
packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift
packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Brain/DistillationCycle.swift
packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Intake/EncodeIntake.swift
packages/kits/LocusKit/rust/src/drawer_operational.rs
packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs
packages/kits/LocusKit/rust/src/dataset_handle.rs
packages/kits/GeniusLocusKit/rust/src/coordinator.rs
packages/kits/LocusKit/Tests/LocusKitTests/DistilledRepresentationTests.swift
packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/DistillationCycleTests.swift
docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK.md
```

---

## Files NOT changed

```
packages/kits/LocusKit/Sources/LocusKit/EstateVerbs.swift   — countUndistilled wrapper; no caller change
packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/DrainStatus.swift — calls countUndistilled; no caller change
packages/kits/LocusKit/Sources/LocusKit/DatasetHandle.swift — patchDatasetHandleSignatures; no caller change
packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/EstateLifecycle.swift — wireSubstores caller; no change
packages/kits/LocusKit/rust/src/estate_verbs.rs             — wrapper; no change
packages/kits/LocusKit/rust/src/drawer_store_sqlite.rs      — delegates to DrawerStoreImpl; no change
packages/kits/LocusKit/rust/src/drawer_store_postgres.rs    — delegates to DrawerStoreImpl; no change
```

---

## T5 system-drawer question (design decision 8)

**Finding:** No existing bitmap bit or `ContentKind` value distinguishes
system-provisioned drawers (wing seeds, `AI_Charter_Hint`) from user-captured
drawers. The `addedBy = "estate-provision"` annotation exists solely as an audit
value; the explicit comment on `DefaultWings.swift` prohibits branching on it.

**Conclusion:** `countUndistilled` continues to include system-provisioned
drawers in its count. No discriminator will be invented in this stream.

**Recommendation (cookbook question):** A future cookbook amendment should
assign bit 20 as `is_system_provisioned` for wing-seed and AI-hint drawers,
with `countUndistilled` excluding them via a `bitmaskNone(bit20)` additional
AND predicate. This work is separate and out of scope for this stream.
`RESCOPE_REQUIRED` is not triggered — the mission explicitly says "If no clean
discriminator exists, do NOT invent one — report the gap."

---

## Baseline test counts (to verify after implementation)

| Suite | Leg | Count | Exit |
|-------|-----|-------|------|
| LocusKit | Swift | 845 | 0 |
| GeniusLocusKit | Swift | 641 | 0 |
| LocusKit | Rust | 6 | 0 |
| GeniusLocusKit | Rust | 10 | 0 |
