---
mission: MX-TAB-Q1
title: TypedValueComparator TEXT ordering — byte-exact parity fix
date: 2026-07-12
status: complete
---

# Blast Radius Report — MX-TAB-Q1

Fixing `TypedValueComparator.compare` TEXT arm to use `utf8.lexicographicallyPrecedes` /
`utf8.elementsEqual` (byte-exact order) instead of Swift String `<` / `==` (Unicode-canonical).
Also fixes `PredicateEvaluator` `.eq`, `.neq`, `.in` arms to route equality through the
comparator rather than `TypedValue ==`. Discovered during MX-TAB-1 test-suite authoring.

Commit: `98b9dd07`

---

## Step 0 — Baseline

Test suite at mission start: `swift test` on PersistenceKit exited 0, with the
`DatasetStore`-related tests green. MX-TAB-1 had just landed its initial round-trip
suite; the BINARY collation ordering tests (`binaryCollation_textOrdering_*`) were
added in this mission as part of the fix verification.

Rust leg (`cargo test` on PersistenceKit): `TypedValueComparator` does not exist in
Rust — the Rust InMemory leg uses `String::cmp` (byte-lexicographic by default);
no Rust code change was required.

---

## Symbol — `TypedValueComparator.compare` text arm

**Change class:** behaviour fix — no type, signature, or visibility change; callers are
unchanged. The comparator is internal to `PersistenceKitInMemory`.

**Scope:** `enum TypedValueComparator` in
`packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift`

### Call sites chased

| File | Site | Classification | Verdict |
|---|---|---|---|
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift` | `.lt`, `.lte`, `.gt`, `.gte` arms — already routed through `compare()` | VERIFIED | Correct; no change |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift` | `.eq` arm — used `TypedValue ==` (Unicode-canonical) | MUST_UPDATE | Fixed: `compare() == 0` |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift` | `.neq` arm — used `TypedValue !=` | MUST_UPDATE | Fixed: `compare() != 0` |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift` | `.in` arm — used `Array.contains(_:)` (TypedValue Equatable) | MUST_UPDATE | Fixed: `contains { compare(v, $0) == 0 }` |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryDatasetStore.swift` | PK pre-sort call to `TypedValueComparator.compare` | VERIFIED | Ordering semantics updated in same commit |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryDatasetStore.swift` | `columnStats` min/max tracking (iterates values, uses `compare`) | VERIFIED | Byte-order semantics propagated automatically via comparator fix |

### Out-of-scope (SQLite / Postgres backends)

SQLite uses BINARY collation at the engine level (no Swift comparator involved).
`PostgreSQLDatasetStore` uses COLLATE "C" DDL (byte-order locked at the column level).
Neither path calls `TypedValueComparator.compare` — no change needed.

---

## Files Modified

| File | Change | Role |
|---|---|---|
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/PredicateEvaluator.swift` | `.eq`/`.neq`/`.in` arms; `TypedValueComparator.compare` text arm body | Primary fix |
| `packages/kits/PersistenceKit/Sources/PersistenceKitInMemory/InMemoryDatasetStore.swift` | PK pre-sort comparator update | Ordering parity |
| `packages/kits/PersistenceKit/Tests/PersistenceKitDatasetTests/DatasetStoreTests.swift` | New `binaryCollation_*` tests (ordering + parity) | Parity gate |
| `docs/findings/MX_TAB_0_BRANCH_AND_EE_CHECK.md` | Finding updated to reflect resolution | Doc |

---

## MUST_UPDATE Resolution

All three broken arms (`.eq`, `.neq`, `.in`) are fixed in commit `98b9dd07`.
No deferrals.

Rust leg: `TypedValue` equality in `InMemoryDatasetStore` (Rust) uses Rust's derived
`PartialEq` on enum variants, which compares `String` fields via byte equality (`==` on
Rust `String` is byte-identical, not Unicode-normalizing). No Rust change was needed
and none was made.
