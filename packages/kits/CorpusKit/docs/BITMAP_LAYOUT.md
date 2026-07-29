---
version: v0.1
---

# CorpusKit Operational Bitmap Layout

This document is the authoritative reference for the `operational_bitmap`
column on `corpus_index_state`. Read it before allocating any new bit,
extending the coverage registry, or modifying any bitmap accessor.

**Source files:**
- Swift: `Sources/CorpusKit/CorpusIndexStateOperational.swift`
- Rust: `rust/src/index_state_operational.rs`

Both files must be kept bit-identical. The Rust twin ships with the Swift
implementation. Do not merge one without the other.

---

## Column declaration

Table: `corpus_index_state`
Column: `operational_bitmap BITMAP NOT NULL DEFAULT 0`
Type: `Int64` (Swift) / `i64` (Rust)
SQLite storage: `INTEGER` (per PersistenceKit `BITMAP` type alias)

The default value of 0 means no lifecycle bits set, no coverage, no
generation stamp. All bits are defined as additive — existing rows that
have never been updated continue to behave correctly with a 0 bitmap.

---

## Bit layout

```
Bit(s)  Field              Description
───────────────────────────────────────────────────────────────────────
  0     removed            Content is soft-deleted. Derived state
                           (BM25, vectors, coverage) has been cleared.
                           Row is retained as a tombstone so the active-
                           content filter distinguishes removed from
                           never-indexed rows.

  1     has_dense_text     corpus_documents.dense_text IS NOT NULL for
                           this row. Cross-table cache maintained by the
                           engine in the same write path that sets or
                           clears dense_text.

  2     lexically_indexed  BM25 term frequencies and an index-state
                           checkpoint exist for this row. The
                           feedCursorRowID sentinel always carries 0 here.

  3     RESERVED           Passages participation (CORPUSKIT_STANDALONE_
                           PASSAGES feature flag). Do not allocate until
                           that feature compiles into this build.

 4–11   coverage_mask      8-bit slot mask. Bit (4+K) is set when slot K
                           has been covered under the CURRENT basis
                           generation. See the coverage registry below.

12–15   basis_generation   4-bit global-generation stamp (values 0–15).
                           A content row's coverage_mask is valid ONLY
                           when this field equals the current global
                           generation stored in corpus_bitmap_generation.
                           A mismatch reads as "uncovered" — no estate-
                           wide write is issued on retrain.

16–63   RESERVED           Growth reserve. Extend this document and the
                           Swift + Rust source files before allocating
                           any bit in this range.
```

---

## Coverage mask registry

The coverage_mask field (bits 4–11) maps registered embedding model IDs
to slot offsets K (0–7). Bit position = 4 + K.

```
K   Bit   Model ID                  Provider
─────────────────────────────────────────────────────────
0    4    corpus-ri-v1              RandomIndexing
1    5    corpus-ppmi-v1            PPMI
2    6    corpus-lsa-v1             LSA
3    7    corpus-nmf-v1             NMF
4    8    corpus-fdc-v1             FDC
5    9    corpus-deterministic      Deterministic / FloatSimHash
6   10    RESERVED                  miniLM (future)
7   11    RESERVED                  mpNet / embeddingGemma / nlEmbedding / nlContextual (future)
```

Slots beyond K=7 fall back to the `corpus_provider_coverage` side table.
The bitmap accelerates the common 8-slot case; the side table handles overflow.

**Registry rules:**
- Entries are NEVER reassigned. Once K=N maps to a model ID, it maps to
  that model ID permanently. Adding a new provider gains the next free K.
- Before a new provider ships, update this document AND the Swift/Rust
  source registry functions. Both must be updated atomically.
- The `coverageMaskBitOffset(for:)` function in Swift and
  `coverage_mask_bit_offset(model_id)` in Rust are the authoritative
  implementations. All coverage write paths call these functions — no
  raw K integers at call sites.

---

## Basis generation semantics

The global generation counter lives in the `corpus_bitmap_generation`
singleton table (singleton_id = 1). It is a 4-bit counter (values 0–15).

**On retrain:** `CorpusContentEngine.trainTrainableSlots` calls
`CorpusIndexStateStore.incrementBasisGeneration()` after all training
jobs complete. The counter increments modulo 16. The engine caches the
new value in its `currentBasisGeneration` property (Swift: actor-isolated;
Rust: `AtomicI64`).

**Invalidation:** After a generation bump, existing content rows still
carry the old generation stamp in bits 12–15. When the coverage check
compares `state.basisGeneration != currentGeneration`, it reads as
uncovered — no writes to `corpus_index_state` are required on retrain.
This is the O(1) invalidation property.

**Lazy refresh:** When the backfill path re-covers a content row under
the new basis, it calls `updateBitmap(contentID:bitmap:)` to stamp the
new coverage slot AND the new generation in the same operation.

**Accumulation behavior:** `settingCoverageSlot(_:generation:)` ORs the
new slot bit into the existing bitmap without clearing other providers'
bits. This means once provider A re-stamps a row with gen N, the bitmap
may show B and C's coverage bits (from gen N-1) at the new generation
stamp. Callers of `isFullyCovered` that need strict per-generation
per-provider coverage must clear first with `clearingCoverageAndGeneration()`
before calling `settingCoverageSlot`. The backfill path uses the
authoritative `corpus_provider_coverage` side table for all coverage
decisions and is unaffected by this bitmap accumulation.

---

## Wraparound sweep (CoverageSweep)

When `incrementBasisGeneration()` returns 0 (the counter wrapped from 15
to 0), the engine calls `resetGenerationSweep()`. This sweep:

1. Resets the singleton counter to 0.
2. Iterates every row in `corpus_index_state`.
3. For each row, clears bits 4–15 (coverage_mask + basis_generation).
4. Skips rows where bits 4–15 are already 0 (no write needed).

The sweep is O(n) in the row count. It is expected to occur at most
once every 16 basis retrains and is typically rare in production.

After the sweep, the first backfill pass under generation 0 re-stamps
coverage + generation for each row.

**What is NOT cleared by the sweep:**
- Bit 0 (removed) — tombstones survive.
- Bit 1 (has_dense_text) — cross-table cache survives.
- Bit 2 (lexically_indexed) — active-content status survives.
- Bit 3 (RESERVED) — preserved.
- Bits 16–63 (RESERVED) — preserved.

---

## Accessor API

### Swift (`CorpusIndexState` extension — see CorpusIndexStateOperational.swift)

```swift
state.isRemoved               // Bool — bit 0
state.hasDenseText            // Bool — bit 1
state.isLexicallyIndexed      // Bool — bit 2
state.coverageMask            // Int64 — 8-bit sub-field from bits 4–11
state.basisGeneration         // Int64 — 4-bit sub-field from bits 12–15

state.isFullyCovered(configMask:currentGeneration:) -> Bool
state.settingCoverageSlot(_:generation:) -> Int64
state.clearingCoverageAndGeneration() -> Int64
```

### Rust (free functions — see rust/src/index_state_operational.rs)

```rust
is_removed(bitmap)
has_dense_text(bitmap)
is_lexically_indexed(bitmap)
coverage_mask(bitmap)
basis_generation(bitmap)
is_fully_covered(bitmap, config_mask, current_generation)
setting_coverage_slot(bitmap, slot_offset, generation)
clearing_coverage_and_generation(bitmap)
```

---

## Construction helpers

These functions build well-known bitmap values for common paths.

| Helper                    | Swift                   | Rust                     | Value     |
|---------------------------|-------------------------|--------------------------|-----------|
| Fresh active checkpoint   | `freshCheckpointBitmap()` | `fresh_checkpoint_bitmap()` | `1<<2` (lexically_indexed=1) |
| Soft-removed tombstone    | `softRemovedBitmap()`   | `soft_removed_bitmap()`  | `1<<0` (removed=1) |
| Feed-cursor sentinel      | `feedCursorBitmap`      | `FEED_CURSOR_BITMAP`     | `0`       |

---

## Adding a new bit

1. Choose the next free bit in the layout table above.
2. Add the bit constant to `CorpusIndexStateOperational.swift` (Swift)
   AND `rust/src/index_state_operational.rs` (Rust). Both changes ship
   together — do not merge one without the other.
3. Add a computed `Bool` accessor to `CorpusIndexState` in Swift and a
   corresponding free function in Rust.
4. Update the layout table and this document.
5. Update the bit assignment comment block in the Swift source file.
6. Add four tests per the bitmap-patterns skill: default=false, set=true,
   clear preserves other bits, round-trip through SQLite.

**Never reassign an existing bit.** A bit that was once assigned carries
semantics in persisted rows even after the feature is removed. Mark
removed bits as RESERVED with a note.
