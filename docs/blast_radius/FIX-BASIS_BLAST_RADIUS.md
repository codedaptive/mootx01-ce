# Blast Radius Report — FIX-BASIS

**Baseline:** swift test pass count at mission start: 339
**Mission:** Fix degenerate LSA/NMF vector basis on fresh estates (per-doc ingest path)
**codegraph:** unavailable — grep-only blast radius

## Symbol 1: `Corpus.ingest(_:sourceID:now:)` (Swift)
**Change class:** semantic (same signature; adds growth-retrain behavior for young-corpus ingests)
**Scope:** public

### Problem
The per-document `ingest()` Phase 1 loop triggers first-ingest auto-train on the FIRST
document only. Subsequent documents fold-in onto this 1-doc (degenerate rank-1 SVD)
basis. The batch path (Phase 1b in `ingestBatch`) already has the correct guard —
training on the full accumulated corpus — but the per-doc path had no equivalent.
Kinsta-verified: recall dropped from 0.853 to 0.56 any@5 on LongMemEval 50q.

### Change
Add a growth-retrain gate: when the persisted basis was trained on fewer than
`perDocAutoRetrainStableChunkThreshold` (50) chunks AND the live corpus has grown
to at least 2× that count, retrain on the full corpus before fold-in. Retrains thin
out exponentially (1→2→4→8→16→32 chunks) then stop at the stability threshold.
This mirrors Phase 1b's intent.

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| packages/kits/CorpusKit/Tests/CorpusKitTests/BasisPersistenceTests.swift | 185–188 | grep | MUST_UPDATE | Test explicitly asserts second ingest does NOT retrain — encodes the buggy behavior |
| packages/kits/CorpusKit/Sources/CorpusKit/CorpusIngestQueue.swift | 543 | grep | INTENTIONALLY_LEFT | Drain worker calls ingest() per queued item; semantic change is correct (young-corpus items now retrain). No behavioral assertion broken. |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/Intake/EncodeIntake.swift | 615 | grep | INTENTIONALLY_LEFT | .impatient path calls ingest() per drawer; the growth-retrain is exactly the desired fix for this path. No assertion broken. |
| packages/kits/CorpusKit/Tests/CorpusKitTests/CorpusTests.swift | multiple | grep | INTENTIONALLY_LEFT | Tests use .deterministic provider (non-trainable) or small fixture corpora that only assert recall behavior, not basis chunk count. None asserts that second ingest does not retrain. |
| packages/kits/CorpusKit/Tests/CorpusKitTests/FloatLaneOutcomeTests.swift | multiple | grep | INTENTIONALLY_LEFT | Asserts float lane outcome categories, not basis training count. |
| packages/kits/CorpusKit/Tests/CorpusKitTests/BasisPersistenceTests.swift | 150–161 | grep | INTENTIONALLY_LEFT | reindexPersistsBasis uses ingest() then calls reindex() — reindex always retrains to full corpus regardless; assertion on final trainedChunkCount remains correct. |
| packages/kits/CorpusKit/Tests/CorpusKitTests/BasisPersistenceTests.swift | 193–220 | grep | INTENTIONALLY_LEFT | reopenLoadsBasis calls ingest() then reindex() then checks loaded embeddings — reindex is the retrain source; ingest's growth-retrain has no effect on the reindex basis or loaded embeddings. |
| packages/kits/CorpusKit/Tests/CorpusKitTests/BasisPersistenceTests.swift | 225–241 | grep | INTENTIONALLY_LEFT | destroyWipesBasis uses ingest() + reindex() — final assertion is destroy wiped the basis; unaffected. |

### Summary (Swift)
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 7 sites (all justified above)
- RESCOPE_REQUIRED: 0 sites

---

## Symbol 2: `Corpus::ingest` (Rust)
**Change class:** semantic (same signature; adds growth-retrain behavior — mirrors Swift)
**Scope:** public

### Call sites (Rust)

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| packages/kits/CorpusKit/rust/tests/corpus_basis_persistence_tests.rs | 123–129 | grep | MUST_UPDATE | Test asserts second ingest does NOT retrain — same buggy assertion as Swift mirror |
| packages/kits/CorpusKit/rust/src/corpus_ingest_queue.rs | (drain worker) | grep | INTENTIONALLY_LEFT | Same as Swift drain worker — correct behavior, no assertion broken |
| packages/kits/CorpusKit/rust/tests/corpus_tests.rs | multiple | grep | INTENTIONALLY_LEFT | Corpus integration tests use deterministic or non-trainable providers, or assert recall results not basis count |
| packages/kits/CorpusKit/rust/tests/corpus_basis_persistence_tests.rs | 83–100, 135–168, 225–274, 283–431 | grep | INTENTIONALLY_LEFT | All other basis-persistence tests use ingest() but assert reindex or destroy or counts behavior — none broken by growth-retrain |

### Summary (Rust)
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 4 sites (all justified above)
- RESCOPE_REQUIRED: 0 sites

---

## Comments being updated (not symbols — listed for completeness)

1. `CorpusKit.swift` ~line 1086: "This is the ONLY implicit train trigger" — updated to describe growth-retrain
2. `CorpusKit.swift` ~line 1744: "DOCUMENTED FOLLOW-UP KNOB, deliberately NOT wired here" — updated now that it IS wired
3. `corpus.rs` ~line 1056: mirrors same comment updates

These are comment edits only. No API changes. No schema changes.
