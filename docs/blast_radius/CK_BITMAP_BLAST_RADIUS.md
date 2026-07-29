# Blast Radius Report — CK_BITMAP (CorpusKit Operational Bitmap)

**Baseline:** swift test pass count at mission start: 459
**Command:** `cd /Users/bob/devlop/mootx01-ce-ck-bitmap/packages/kits/CorpusKit && swift test`
**Mission:** Implement CorpusKit operational_bitmap per BITMAP_ADOPTION_DESIGN_2026-07-28.md v1.3

**Symbols being changed:**

---

## Symbol 1: `CorpusIndexState` (struct)

**Change class:** additive field (`operationalBitmap: Int64 = 0`, default-value parameter)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusIndexStateStore.swift | 147 | codegraph | MUST_UPDATE | decode() must read `operational_bitmap` column |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 716 | codegraph | MUST_UPDATE | checkpoint construction — needs bitmap bits |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 970 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1004 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1038 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1078 | codegraph | MUST_UPDATE | real checkpoint — needs lexically_indexed=1 |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1083 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1364 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1676 | codegraph | MUST_UPDATE | real checkpoint in prepareIndex — needs bits |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1845 | codegraph | MUST_UPDATE | feedCursorRowID checkpoint (bitmap=0 is correct) |
| CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 310 | codegraph | INTENTIONALLY_LEFT | Store-level unit test; operationalBitmap=0 default is correct for this test (testing round-trip, not engine semantics) |
| CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 318 | codegraph | INTENTIONALLY_LEFT | Same: feedCursorRowID-style row; bitmap=0 expected |
| CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 337 | codegraph | INTENTIONALLY_LEFT | SQLite reopen test; bitmap=0 expected |
| CorpusKit/Tests/CorpusKitTests/CorpusContentEngineTests.swift | 732 | codegraph | INTENTIONALLY_LEFT | Counts-concurrency test; passes checkpoint with bitmap=0 which is acceptable for counting tests |
| CorpusKit/rust/src/index_state_store.rs | 20,200 | codegraph | MUST_UPDATE | Rust twin: CorpusIndexState struct + decode |
| CorpusKit/rust/src/content_engine.rs | 1393,2154 | codegraph | MUST_UPDATE | Rust content engine checkpoint construction |

### Summary
- MUST_UPDATE: 10 sites
- INTENTIONALLY_LEFT: 4 sites (all justified — store-level tests that don't exercise engine bitmap semantics; default=0 is correct)
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 2: `CorpusIndexStateStore.schemaDeclaration`

**Change class:** version bump (1 → 2), new column (`operational_bitmap`), new table (`corpus_bitmap_generation`)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusSchemaProfile.swift | 113,169 | grep | INTENTIONALLY_LEFT | Profile version is the live-sum of components — auto-updates when CorpusIndexStateStore.schemaDeclaration.version bumps |
| CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 240 | grep | MUST_UPDATE | `attachedProfileContainsNoCanonicalContentTable` enumerates table names — must include `corpus_bitmap_generation` (added in v2) |
| CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 306,336 | grep | MUST_UPDATE | Migrate-to calls must work with v2 schema; existing tests must still pass |
| CorpusKit/rust/src/index_state_store.rs | 43 | grep | MUST_UPDATE | Rust schema_declaration() must match Swift v2 |
| CorpusKit/rust/src/schema_profile.rs | — | grep | INTENTIONALLY_LEFT | Rust profile version is a sum — auto-updates |

### Summary
- MUST_UPDATE: 3 sites
- INTENTIONALLY_LEFT: 2 sites
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 3: `CorpusContentEngine.clearDerivedState(id:)` (semantic change)

**Change class:** semantic — no longer DELETEs `corpus_index_state` row; instead marks `removed=1`
**Scope:** private

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 623 (indexContent) | codegraph | MUST_UPDATE | Internally calls clearDerivedState — semantic change flows through |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 636 (indexContentStructural) | codegraph | MUST_UPDATE | Same |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 969 (drainIndexBatch remove) | codegraph | MUST_UPDATE | Calls clearDerivedState — soft-remove semantics |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1283 (applyChange remove) | codegraph | MUST_UPDATE | Same |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1361 (prepareQueueJob remove) | codegraph | MUST_UPDATE | Same |
| CorpusKit/rust/src/content_engine.rs | 2149 | codegraph | MUST_UPDATE | Rust clear_derived_state uses index_state.clear() — must switch to soft-remove |

### Summary
- MUST_UPDATE: 6 sites
- INTENTIONALLY_LEFT: 0 sites
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 4: `CorpusContentEngine.indexedContentIDs()` (semantic change)

**Change class:** semantic — filters by `lexically_indexed=1 AND removed=0`
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1148 (backfillProviderCoverage) | codegraph | MUST_UPDATE | Caller expects active-content set; semantic change is correct |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1957 (batchTrainIfNeeded) | codegraph | MUST_UPDATE | Caller expects indexed count; semantic change is correct |
| CorpusKit/rust/src/content_engine.rs | 714 | codegraph | MUST_UPDATE | Rust indexed_content_ids must filter by bitmap |

### Summary
- MUST_UPDATE: 3 sites
- INTENTIONALLY_LEFT: 0 sites
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 5: `CorpusContentEngine.coverageStore.markCovered(...)` call sites

**Change class:** additive — bitmap coverage bits must also be updated in same transaction
**Scope:** private (engine internal)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 714 (indexWholeContentBatch) | codegraph | MUST_UPDATE | Must also stamp coverage bits + generation in bitmap |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1074 (drainIndexBatch phase 3) | codegraph | MUST_UPDATE | Same |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1210 (backfillProviderCoverage) | codegraph | MUST_UPDATE | Same |
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | 1673 (prepareIndex) | codegraph | MUST_UPDATE | Same |
| CorpusKit/rust/src/content_engine.rs | ~1175 (mark_covered sites) | codegraph | MUST_UPDATE | Rust engine must also stamp coverage bitmap |

### Summary
- MUST_UPDATE: 5 sites
- INTENTIONALLY_LEFT: 0 sites
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 6: `CorpusContentEngine.trainTrainableSlots(...)` (additive: bumps generation)

**Change class:** additive — after retrain, bump global basis generation counter
**Scope:** internal

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift | (all callers of trainTrainableSlots) | codegraph | MUST_UPDATE | After training, bump generation; update engine's in-memory counter |
| CorpusKit/rust/src/content_engine.rs | (train_trainable_slots) | codegraph | MUST_UPDATE | Rust must also bump generation counter |

### Summary
- MUST_UPDATE: 2 sites
- RESCOPE_REQUIRED: 0 sites

---

## Remainder — out of scope for this mission (noted, not RESCOPE_REQUIRED)

**Legacy Corpus actor removed_sources migration:** `CorpusKit.swift` (legacy `Corpus` actor) uses `removedSourceStore.removedIDs()` for `activeChunks()` and `count()`. These operate on `BundleStore` chunks (chunk-level, not content-level), which maps to a different key space than `corpus_index_state` (content-level). Converting the legacy path would require chunk→content ID mapping which exceeds the bounded step in this mission. The `removed` bit in `corpus_index_state` targets the new `CorpusContentEngine` path exclusively. The legacy path continues using `removed_sources` as before.

This is NOT a RESCOPE_REQUIRED — the bitmap serves the new engine which is the active path. The legacy path is a compatibility surface.

---

## Overall Summary

| Classification | Count |
|---|---|
| MUST_UPDATE | ~26 sites across Swift + Rust |
| INTENTIONALLY_LEFT | 6 sites (all justified) |
| RESCOPE_REQUIRED | 0 sites |

Mission proceeds.
