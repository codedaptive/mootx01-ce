# Blast Radius Report — INMEM-COMPARATOR-FIX

**Baseline:** swift test pass count at mission start: 387 (66 + 130 + 35 + 22 + 133 + 1)
**Mission:** Fix correctness regression — InMemory PredicateEvaluator .eq/.neq/.in silently wrong for blob/json/fingerprint/array TypedValue cases
**Symbols being changed:**

## Symbol 1: TypedValueComparator.compare (Swift)

**Change class:** semantic — adding new match cases; previously `default: return nil` for blob/json/fingerprint/array now returns an actual Int? result
**Scope:** internal (PersistenceKitInMemory module)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/PersistenceKitInMemory/PredicateEvaluator.swift | 23, 25, 27, 29, 31, 33, 44 | grep | INTENTIONALLY_LEFT | Same file as the fix; callers already handle non-nil correctly — the bug was that nil was returned for these types, not that callers were wrong |
| Sources/PersistenceKitInMemory/InMemoryStorage.swift | 422 | grep | INTENTIONALLY_LEFT | Sort path — adding non-nil returns for blob/json/fingerprint/array IMPROVES sort ordering for these types; no caller code change needed |

### Summary
- MUST_UPDATE: 0 sites (the fix is purely additive; no callers require changes)
- INTENTIONALLY_LEFT: 2 sites (both benefit from the fix; neither needs code changes)
- RESCOPE_REQUIRED: 0

---

## Symbol 2: compare_typed_values (Rust)

**Change class:** semantic — adding new match arms for Blob/Json/Fingerprint/Array; previously `_ => None` for these cases now returns `Some(Ordering)`
**Scope:** private function in `inmemory.rs`

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| rust/src/inmemory.rs (evaluate_predicate, query sort) | multiple | grep | INTENTIONALLY_LEFT | Callers already handle `None` (return false) and non-None (use ordering); adding new arms benefits ordering predicates and sort — no caller code change needed. Note: Rust equality predicates (.Eq/.Neq/.In) use TypedValue PartialEq directly and are already correct for all types. |

### Summary
- MUST_UPDATE: 0 sites
- INTENTIONALLY_LEFT: 1 site
- RESCOPE_REQUIRED: 0

---

## Scope note

Both changes are strictly additive (new match arms before `default`/`_ => None`).
No existing match arms are modified. No callers require code changes.
New test file (InMemoryComparatorTests.swift) is a net-new addition.
Rust test additions are net-new.
