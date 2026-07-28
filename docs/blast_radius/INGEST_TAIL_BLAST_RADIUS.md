# Blast Radius Report — fix-ingest-tail

**Baseline:** CorpusKit swift test pass count at mission start: 396
**Rust CorpusKit baseline:** 5 tests passing
**mcp-benchmarker Swift baseline:** 251 tests passing
**mcp-benchmarker Rust baseline:** 159 tests passing
**Mission:** Batch O(N×slots) referenceFor queries (Cause 3) + batch source.record(for:) fetches (Cause 4) + fix report writer gap (Part C) + unignore docs/blast_radius/ (Part D)
**Symbols being changed:**

## Symbol 1: CorpusProviderCountsStore (Swift)
**Change class:** additive (new method `referencesFor(modelID:modelVersion:contentIDs:)`)
**Scope:** public

### Call sites
| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusContentEngine.swift | ~1367 | grep | MUST_UPDATE | Uses per-ID `referenceFor`; batched in `commitQueueBatch` |

### Summary
- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 2: CorpusProviderCountsStore (Rust) — `reference_for`
**Change class:** additive (new method `references_for`)
**Scope:** pub(crate)

### Call sites
| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| content_engine.rs | ~1551 | grep | MUST_UPDATE | Per-ID loop; batched |
| content_engine.rs | ~2984 | grep | INTENTIONALLY_LEFT | `commit_direct_index` — same-symbol loop, separate code path; Part A scope is `commit_queue_batch` only |

### Summary
- MUST_UPDATE: 1 site (`commit_queue_batch` loop)
- INTENTIONALLY_LEFT: 1 site (`commit_direct_index` — separate path, out of scope)
- RESCOPE_REQUIRED: 0

---

## Symbol 3: CorpusContentSource protocol (Swift) — `record(for:)`
**Change class:** additive (new default method `records(for:)`)
**Scope:** public protocol

### Call sites
| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CorpusContentEngine.swift | ~977 | grep | MUST_UPDATE | Phase 1 per-job call; batched pre-Phase-1 |
| CorpusContentEngine.swift | ~604,619,671,1136,1227,1296,1990,2189 | grep | INTENTIONALLY_LEFT | All other `source.record(for:)` calls are in non-drain paths (indexSingleContent, reindex, train) — not in the drain batch loop |

### Summary
- MUST_UPDATE: 1 site (Phase 1 per-job drain call)
- INTENTIONALLY_LEFT: 8 sites (non-drain single-record paths)
- RESCOPE_REQUIRED: 0

---

## Symbol 4: CorpusDocumentStore (Swift) — `record(for:)` not changed; new `records(for:)` added
**Change class:** additive
**Scope:** public

### Summary
- Pure addition — no existing symbol changed

---

## Symbol 5: Rust CorpusContentSource trait — additive `records_for`
**Change class:** additive default method
**Scope:** pub(crate)

### Summary
- Pure addition with default fallback — no call site breaks

---

## Symbol 6: LoCoMoQuestionResult / LMEBQueryResult — add payloadText field
**Change class:** additive (new optional field)
**Scope:** internal

### Call sites
| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| LoCoMoRunner.swift | ~330 | grep | MUST_UPDATE | Result construction site — must add payloadText capture |
| LMEBRunner.swift | ~293 | grep | MUST_UPDATE | Result construction site — must add payloadText capture |
| LoCoMoScorer.swift | builder | grep | MUST_UPDATE | buildLoCoMoReport must use payload text for tokens_per_result + provenance_summary |
| LMEBScorer.swift | builder | grep | MUST_UPDATE | buildLMEBReport must use payload text for tokens_per_result + provenance_summary |

### Summary
- MUST_UPDATE: 4 sites
- RESCOPE_REQUIRED: 0

---

## Symbol 7: Rust locomo_runner / lmeb_runner — add payload text capture
**Change class:** additive
**Scope:** pub(crate)

### Summary
- MUST_UPDATE: locomo_runner.rs result construction, lmeb_runner.rs result construction
- Rust locomo_scorer.rs and lmeb_scorer.rs report builders

---

## Part D: .gitignore
**Change class:** line removal (unignore `docs/blast_radius/`)
**Scope:** repo-level

### Summary
- Single-line change; no code blast radius

---

## Equivalence gate (Parts A + B)
Both parts must produce byte-identical end-state vs. the unbatched path on a fixed
corpus. The existing equivalence-proof test pattern from fix-fanout (structural
equivalence via ProbeRecorder) applies.
