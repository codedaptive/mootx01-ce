# Blast Radius Report — RG-SUBSPAN

**Baseline:** swift test pass count at mission start: 435  
**Mission:** MISSION_11X_RECALL_GAP_01 Stream E — transient sub-span max-cosine scoring (Item 1)  
**Branch:** stream/rg-subspan (branched from stream/rg-discrim)

## Symbols being changed:

All production changes are ADDITIVE. One existing private method gains a new
scoring step inside its body; no external symbol is renamed, removed, or has
its signature changed.

---

## Symbol 1: `RecallDirector.recallUnionBest` (private)

**Change class:** semantic — adding step 5.8 (sub-span dense refinement) inside
the body of the existing private extension method.

**Scope:** private (extension on `GeniusLocusKit`, file-scoped)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| RecallDirector.swift | ~97 | grep | MUST_UPDATE | This IS the method being modified — step 5.8 added within |
| RecallDirector.swift | ~97 | codegraph | INTENTIONALLY_LEFT | The call site at `recall(_:_:)` switch case does not change; only the body grows |

### Summary
- MUST_UPDATE: 1 site (the method body itself)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## New symbols (additive — no blast radius)

### `CorpusContentEngine.scoreSubSpans(query:candidateIDs:)` — new public method
Additive. No existing callers before this commit.

### `Corpus.scoreSubSpans(query:sourceIDs:)` — new public method
Additive. No existing callers before this commit.

### `SubSpanScoring` enum — new type in CorpusKit
Additive. Exposes `subSpanRanges(text:windowTokens:overlapTokens:)` and
`cosineSimilarity(_:_:)` as `internal` (visible within module and to tests),
and `score(query:candidateIDs:source:provider:)` as `public` for SDK consumers.

### Rust twins — new functions/methods in content_engine.rs and corpus.rs
Additive. `sub_span_scoring.rs` module added and re-exported from lib.rs.

---

## Scope confirmation

Files this stream will modify or create:

**CorpusKit Swift sources (additive):**
- `Sources/CorpusKit/SubSpanScoring.swift` — NEW
- `Sources/CorpusKit/CorpusContentEngine.swift` — add method
- `Sources/CorpusKit/CorpusKit.swift` — add method to Corpus

**CorpusKit Swift tests (additive):**
- `Tests/CorpusKitTests/SubSpanScoringTests.swift` — NEW

**CorpusKit Rust sources (additive):**
- `rust/src/sub_span_scoring.rs` — NEW
- `rust/src/content_engine.rs` — add method
- `rust/src/corpus.rs` — add method  
- `rust/src/lib.rs` — add module export
- `rust/tests/sub_span_scoring_tests.rs` — NEW

**GeniusLocusKit Swift sources (modified):**
- `Sources/GeniusLocusKit/RecallDirector/RecallDirector.swift` — step 5.8

No LocusKit, VectorKit, AriaMcpKit, or other kit files are touched.
No passages trait is enabled. No existing query APIs are changed.
