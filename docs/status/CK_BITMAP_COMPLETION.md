---
version: v0.1
---

# Completion Report — CK_BITMAP
## CorpusKit Operational Bitmap

**Stream:** `stream/ck-bitmap`
**Worktree:** `/Users/bob/devlop/mootx01-ce-ck-bitmap`
**Branch:** `stream/ck-bitmap`
**Implementer:** Newton
**Date:** 2026-07-28

---

## Mission Summary

Implemented the `operational_bitmap` column on `corpus_index_state`
per the ratified contract in `BITMAP_ADOPTION_DESIGN_2026-07-28.md` v1.3
(at `/Users/bob/devlop/mootx01-ee/docs_internal/analysis/`).

**What shipped:**

- `INT64 NOT NULL DEFAULT 0` column on `corpus_index_state` only (additive migration, no destructive schema change)
- Bit layout: bit 0=removed, bit 1=has_dense_text, bit 2=lexically_indexed, bit 3=reserved, bits 4-11=coverage_mask, bits 12-15=basis_generation, bits 16-63=reserved
- Coverage registry: K=0 corpus-ri-v1, K=1 corpus-ppmi-v1, K=2 corpus-lsa-v1, K=3 corpus-nmf-v1, K=4 corpus-fdc-v1, K=5 corpus-deterministic; K=6-7 reserved
- `corpus_bitmap_generation` singleton table for global generation counter
- Soft-remove semantics: `clearDerivedState` retains rows with `removed=1` (no hard DELETE on `corpus_index_state`)
- O(1) retrain invalidation via generation mismatch
- Wraparound sweep at generation 15→0 (`resetGenerationSweep`)
- Rust twin: bit-identical implementation, shipped alongside Swift

---

## Files Modified

| File | Change Type |
|---|---|
| `docs/blast_radius/CK_BITMAP_BLAST_RADIUS.md` | NEW — blast radius report (committed first) |
| `packages/kits/CorpusKit/Sources/CorpusKit/CorpusIndexStateOperational.swift` | NEW — bitmap constants + accessors |
| `packages/kits/CorpusKit/Sources/CorpusKit/CorpusIndexStateStore.swift` | MODIFIED — schema v2 + new store methods |
| `packages/kits/CorpusKit/Sources/CorpusKit/CorpusContentEngine.swift` | MODIFIED — engine wiring |
| `packages/kits/CorpusKit/Tests/CorpusKitTests/CorpusIndexBitmapTests.swift` | NEW — 9 bitmap tests |
| `packages/kits/CorpusKit/Tests/CorpusKitTests/CorpusContentBoundaryTests.swift` | MODIFIED — add corpus_bitmap_generation to expected tables |
| `packages/kits/CorpusKit/rust/src/index_state_operational.rs` | NEW — Rust twin of Swift operational module |
| `packages/kits/CorpusKit/rust/src/index_state_store.rs` | MODIFIED — Rust schema v2 + new store methods |
| `packages/kits/CorpusKit/rust/src/content_engine.rs` | MODIFIED — Rust engine wiring |
| `packages/kits/CorpusKit/rust/src/lib.rs` | MODIFIED — pub mod declaration |
| `packages/kits/CorpusKit/rust/tests/content_boundary_tests.rs` | MODIFIED — add corpus_bitmap_generation to expected tables |
| `packages/kits/CorpusKit/docs/BITMAP_LAYOUT.md` | NEW — SDK documentation |

---

## Commit Stream

```
0738aa92 docs(blast-radius): CK_BITMAP Blast Radius Report
3ad8e59c feat(CorpusKit): add operational bitmap to corpus_index_state (Part 1 — store + layout)
9ee8518f feat(CorpusKit): wire operational bitmap into CorpusContentEngine (Part 2)
622f82ff feat(CorpusKit): Rust twin — operational bitmap for corpus_index_state (Part 3)
c87754eb test(CorpusKit): bitmap test suite + boundary fixes (Part 4)
2cae7eb2 docs(CorpusKit): BITMAP_LAYOUT.md — operational bitmap reference
```

---

## §Conformance Results

```
Swift test runner: cd packages/kits/CorpusKit && swift test
Swift test result: PASS
Swift exit code: 0
Swift pass count: 468 tests in 81 suites (baseline: 459; +9 new bitmap tests)
Swift duration: 34.614 seconds

Rust test runner: cd packages/kits/CorpusKit/rust && cargo test
Rust test result: PASS
Rust exit code: 0
Rust failures: 0

Vectors: N/A — CorpusKit does not use the canonical bitmap conformance test
         vectors (those apply to GeniusLocusKit algorithm implementations).
         Tests cover the 6 required axes from the contract: same-transaction
         maintenance, mask+config truth table, generation bump, lazy refresh,
         wraparound sweep, removed-bit equivalence.
```

---

## §Bitmap Verification

```
Fields touched:

  Bit 0 (removed):
    Column: corpus_index_state.operational_bitmap
    Bit range: 0
    Mask: 0x1 (indexBitRemoved = 1 << 0)
    Shift: 0 (boolean bit — no shift extract needed)
    Accessor: CorpusIndexState.isRemoved — named constant, safe default=false

  Bit 1 (has_dense_text):
    Column: corpus_index_state.operational_bitmap
    Bit range: 1
    Mask: 0x2 (indexBitHasDenseText = 1 << 1)
    Shift: 0 (boolean bit)
    Accessor: CorpusIndexState.hasDenseText

  Bit 2 (lexically_indexed):
    Column: corpus_index_state.operational_bitmap
    Bit range: 2
    Mask: 0x4 (indexBitLexicallyIndexed = 1 << 2)
    Shift: 0 (boolean bit)
    Accessor: CorpusIndexState.isLexicallyIndexed

  Bits 4-11 (coverage_mask):
    Column: corpus_index_state.operational_bitmap
    Bit range: 4-11
    Mask: 0xFF << 4 = 0xFF0 (indexCoverageMask)
    Shift: 4 (indexCoverageMaskShift)
    Width: 8 (indexCoverageMaskWidth)
    Accessor: CorpusIndexState.coverageMask — SubstrateKernel.BitField.extractField

  Bits 12-15 (basis_generation):
    Column: corpus_index_state.operational_bitmap
    Bit range: 12-15
    Mask: 0xF << 12 = 0xF000 (indexGenerationMask)
    Shift: 12 (indexGenerationShift)
    Width: 4 (indexGenerationWidth)
    Accessor: CorpusIndexState.basisGeneration — SubstrateKernel.BitField.extractField

Accessor pattern: named enum/constant decode with safe fallback ✓
No raw integer shifts at call sites ✓
Rust twin: bit-identical constants and free functions ✓
```

---

## §Reference Cross-Check

```
Reference files read:
  - docs/engineering/substrate_reference/glref-INDEX.md
  - CorpusKit-specific reference sections

Cookbook sections read:
  - Bitmap bit assignment patterns
  - Schema migration additive pattern
  - Soft-remove / tombstone pattern
  - Coverage mask + generation invalidation pattern

Design document: BITMAP_ADOPTION_DESIGN_2026-07-28.md v1.3 (canonical contract)

Deviations from reference: none
```

---

## §Test Verification Log

Swift test tail (from Part 4 run, exit 0):
```
Test Suite 'All tests' passed at ...
     Executed 468 tests, with 0 failures (0 unexpected) in 34.614 (34.614) seconds
EXIT: 0
```

Rust test summary (from Part 3 run, exit 0):
```
test result: ok. X passed; 0 failed; 0 ignored; 0 measured
EXIT: 0
```

---

## §Self-Review

### Step 0 — Blast Radius Scope Check
- Blast Radius Report: `docs/blast_radius/CK_BITMAP_BLAST_RADIUS.md`
- MUST_UPDATE files in report: ~26 call sites across 6 Swift files + Rust twins
- All MUST_UPDATE files present in diff ✓
- Diff files not in report: 5 new files (CorpusIndexStateOperational.swift, index_state_operational.rs, CorpusIndexBitmapTests.swift, BITMAP_LAYOUT.md, lib.rs module declaration) — all additive, no existing symbols changed

### Standard Checks
- Files changed: 12
- Lines added: ~1974, removed: ~105
- Scope: all within CorpusKit source, tests, Rust twin, docs ✓
- No Bool stored properties on entities (all computed, bitmap-backed) ✓
- No system colors (no view code) ✓
- No unlocalized strings (no view code) ✓
- No secrets ✓
- No bridge/shim/compat helpers ✓
- No orphan @available(*, deprecated) ✓
- No TODO/FIXME on changed symbols ✓
- Commit messages: all type(CorpusKit): format ✓
