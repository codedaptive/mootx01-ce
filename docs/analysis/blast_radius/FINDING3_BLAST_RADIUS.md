# Blast Radius Report — FINDING-3 (duplicate-association-edges fix)

**Baseline:** LocusKit swift test pass count at mission start: 803
**GeniusLocusKit swift test pass count at mission start:** 597
**LocusKit rust test pass count at mission start:** 721 + 11 + 4 + 53 + 19 + 4 + 3 + 8 + 15 + 13 = 851 (across all test binaries)
**GeniusLocusKit rust test pass count at mission start:** 115 + 5 + 17 + 13 + 4 + 3 + 16 + 5 + 14 + 3 + 10 = 205 (across all test binaries)
**Mission:** Fix duplicate association edges — schema uniqueness constraint + INSERT-OR-IGNORE + signal persisted-edge check

## Symbol 1: LocusKitSchema.version (Int, public)
**Change class:** semantic (value 9 → 10)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| GeniusLocusKit/GeniusLocusKitSchema.swift | 65-70 | codegraph | INTENTIONALLY_LEFT | Live sum — auto-updates when LocusKit.version bumps; comment must be updated |
| GeniusLocusKit/Tests/HydrateRoundTripTests.swift | 74,78,93 | grep | MUST_UPDATE | Hardcoded `== 18` composite assertions must become `== 19` |
| GeniusLocusKit/rust/src/hydration.rs | 202 | grep | MUST_UPDATE | `assert_eq!(s.version, 18)` must become `assert_eq!(s.version, 19)` |
| LocusKit/rust/src/schema.rs | 64 | grep | MUST_UPDATE | `pub const SCHEMA_VERSION: i32 = 9` must become 10 |
| LocusKit/rust/src/schema.rs | 1050-1052 | grep | MUST_UPDATE | Test `schema_version_is_nine` asserts 9 and `migrations.is_empty()` — both must change |

### Summary
- MUST_UPDATE: 3 files (HydrateRoundTripTests.swift, hydration.rs, schema.rs)
- INTENTIONALLY_LEFT: 1 site (GeniusLocusKitSchema.swift — live sum, auto-corrects)
- RESCOPE_REQUIRED: 0

---

## Symbol 2: LocusKitSchema.associationsTable (TableDeclaration, static)
**Change class:** semantic (adding uniqueConstraints)
**Scope:** package-internal

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| LocusKitSchema.swift (schema property) | 114 | codegraph | INTENTIONALLY_LEFT | Part of schema property — the uniqueConstraint is declarative; the table reference stays |
| LocusKit/rust/src/schema.rs associations_table() | 457 | grep | MUST_UPDATE | Rust mirror must add matching unique_constraints |

### Summary
- MUST_UPDATE: 1 (schema.rs associations_table)
- INTENTIONALLY_LEFT: 1

---

## Symbol 3: DrawerStore.addAssociation (public async throws)
**Change class:** semantic (INSERT → INSERT-OR-IGNORE via catch-DuplicateKey)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| EstateVerbs.swift | 1798 | codegraph | INTENTIONALLY_LEFT | Callers tolerate no-throw on duplicate — the function still returns; no behavior change at call site |
| GeniusLocusKit/Verbs/VerbSurface.swift | (through associate verb) | codegraph | INTENTIONALLY_LEFT | Swallowed duplicateKey propagates as success; VerbSurface.associate already handles LocusKitErrors separately |
| AssociationTests.swift | various | grep | MUST_UPDATE | New test for idempotency must be added |
| LocusKit/rust/src/drawer_store_inmemory.rs | 3087 | grep | MUST_UPDATE | Rust add_association must mirror INSERT-OR-IGNORE |

### Summary
- MUST_UPDATE: 2 (AssociationTests.swift — new test, drawer_store_inmemory.rs)
- INTENTIONALLY_LEFT: 2

---

## Symbol 4: VectorSimilaritySignal.spec (Swift + Rust)
**Change class:** additive (new optional drawerStore / edge_checker parameter)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| DefaultStandingSignals.swift | 125 | codegraph | MUST_UPDATE | Call site must pass drawerStore:nil (or the new parameter) |
| GeniusLocusKit/Tests/StandingSignalsTests.swift | various | grep | INTENTIONALLY_LEFT | Tests construct VectorSimilaritySignal.spec without the new param; default nil keeps them working |
| Rust default_set.rs | various | grep | MUST_UPDATE | Rust call site for VectorSimilaritySignal::spec must pass None for edge_checker |
| Rust standing_signals_parity.rs | various | grep | INTENTIONALLY_LEFT | Parity tests check signal names, not spec parameters |

### Summary
- MUST_UPDATE: 2 (DefaultStandingSignals.swift, default_set.rs)
- INTENTIONALLY_LEFT: 2

---

## Schema migration (v9 → v10)
Both Swift LocusKitSchema and Rust schema.rs must declare a Migration(fromVersion: 9, toVersion: 10) that:
1. Deduplicates existing rows (custom SQL)
2. Adds unique index `idx_associations_natural_key` on (sourceWing, sourceRoom, sourceDrawerId, targetWing, targetRoom, targetDrawerId, label)

---

## RESCOPE_REQUIRED items
None. All call sites are within LocusKit and GeniusLocusKit which are in scope.

---

## Files You Will Modify
- `packages/kits/LocusKit/Sources/LocusKit/LocusKitSchema.swift`
- `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift`
- `packages/kits/LocusKit/Tests/LocusKitTests/AssociationTests.swift`
- `packages/kits/LocusKit/rust/src/schema.rs`
- `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs`
- `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/GeniusLocusKitSchema.swift` (comment only — live sum auto-corrects)
- `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Brain/Signals/VectorSimilaritySignal.swift`
- `packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Brain/Signals/DefaultStandingSignals.swift`
- `packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/HydrateRoundTripTests.swift`
- `packages/kits/GeniusLocusKit/rust/src/hydration.rs`
- `packages/kits/GeniusLocusKit/rust/src/brain/signals/vector_similarity.rs`
- `packages/kits/GeniusLocusKit/rust/src/brain/signals/default_set.rs`
