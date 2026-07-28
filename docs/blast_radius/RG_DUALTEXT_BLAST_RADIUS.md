# Blast Radius Report — RG-DUALTEXT

**Baseline:** swift test pass count at mission start: 396
**Branch:** stream/rg-dualtext
**Mission:** MISSION_11X_RECALL_GAP_01 Stream A — CorpusKit dual-text indexing capability

## Symbols being changed

---

## Symbol 1: `CorpusContentRecord` — additive new field `denseCompositionText: String?`

**Change class:** additive field (new optional init parameter with default nil)
**Scope:** public

### Call sites — Swift

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusContent.swift | 52–69 | definition | MUST_UPDATE | Definition site — add the field + accessor |
| Sources/CorpusKit/CorpusDocumentStore.swift | 102, 116, 148, 166 | grep | MUST_UPDATE | All construction sites must populate `denseCompositionText` from `dense_text` column |
| Tests/CorpusKitTests/CorpusContentBoundaryTests.swift | 33, 40 | grep | INTENTIONALLY_LEFT | Test mock with 4-arg init; `denseCompositionText` defaults to nil — no behavior change needed |
| Tests/CorpusKitTests/CorpusContentEngineTests.swift | 763, 781, 809, 829, 872, 1035, 1039 | grep | INTENTIONALLY_LEFT | Test fixtures use 4-arg init; nil dense text means effectiveDenseText == text — existing behavior preserved |

### Call sites — Rust

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| rust/src/content.rs | 41–51 | definition | MUST_UPDATE | Definition site — add `dense_composition_text: Option<String>` + `effective_dense_text()` |
| rust/src/document_store.rs | 164–170, 215–226, 332–336, 357–364 | grep | MUST_UPDATE | All struct literal constructions must add `dense_composition_text: None` |
| rust/tests/content_engine_tests.rs | 575–580, 612–619, 659–665, 698–703, 772–778, 1138–1148, 1187–1197 | grep | MUST_UPDATE | Struct literal constructions need `dense_composition_text: None`; Rust doesn't allow missing fields |
| rust/tests/content_boundary_tests.rs | 103–110, 122–128 | grep | MUST_UPDATE | Struct literal constructions need `dense_composition_text: None` |

---

## Symbol 2: `CorpusDocumentStore.schemaDeclaration` — version 1→2 + `dense_text TEXT NULL` column migration

**Change class:** schema version bump (additive migration, nullable column)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusDocumentStore.swift | 41–78 | definition | MUST_UPDATE | Add migration, bump version, add nullable column |
| Sources/CorpusKit/CorpusSchemaProfile.swift | 111–113 | grep | INTENTIONALLY_LEFT | Passes `CorpusDocumentStore.schemaDeclaration` to the profile builder — no code change needed, version sum auto-updates |
| rust/src/document_store.rs | 36–74 | definition | MUST_UPDATE | Bump Rust schema version, add `dense_text` column + migration |

---

## Symbol 3: `CorpusDocumentStore.record(for:)` and `records(for:)` — semantic addition (read `dense_text` column)

**Change class:** semantic (richer return value; callers ignoring `denseCompositionText` are unaffected)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusDocumentStore.swift | 139–170 | definition | MUST_UPDATE | Update reads to populate `denseCompositionText` from `dense_text` column |
| All callers via `CorpusContentSource.record(for:)` | n/a | protocol | INTENTIONALLY_LEFT | Callers that ignore the new field are unaffected by the richer record; the field defaults nil (identical behavior) |
| rust/src/document_store.rs | 141–225 | definition | MUST_UPDATE | Update Rust record construction to populate `dense_composition_text` from DB |

---

## Symbol 4: `CorpusContentEngine.embedQueueRecords` — use `effectiveDenseText` for `embedPair`

**Change class:** semantic (embedding input changes from lexical to dense text when set; BM25 unchanged)
**Scope:** internal

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusContentEngine.swift | 810 | definition | MUST_UPDATE | Change `embedPair(record.text)` → `embedPair(record.effectiveDenseText)` |
| CorpusContentEngineQueue.swift (callers of embedQueueRecords) | n/a | codegraph | INTENTIONALLY_LEFT | Callers pass records with nil dense text (unchanged behavior) — no source edit needed |

---

## Symbol 5: `CorpusContentEngine.backfillProviderCoverage` — use `effectiveDenseText` for `embedPair`

**Change class:** semantic
**Scope:** private

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusContentEngine.swift | 1160 | definition | MUST_UPDATE | Change `embedPair(record.text)` → `embedPair(record.effectiveDenseText)` |

---

## Symbol 6: `CorpusContentEngine.replaceUnits` / `IndexUnit` — separate dense text from lexical text in whole-content unit

**Change class:** additive (new `denseText` field on private `IndexUnit` struct; passage mode unaffected)
**Scope:** private

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusContentEngine.swift | 1656–1713 | definition | MUST_UPDATE | Add `denseText: String?` to `IndexUnit`; set from `record.denseCompositionText` in whole-content case; use `unit.effectiveDenseText` in the `embedPair` call at line 1618 |

---

## Symbol 7: `prepareProviderTraining` — use `effectiveDenseText` for training accumulation

**Change class:** semantic (basis trained on dense text when available; nil → unchanged)
**Scope:** private

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| Sources/CorpusKit/CorpusContentEngine.swift | 2034 | definition | MUST_UPDATE | Change `texts.append(record.text)` → `texts.append(record.effectiveDenseText)` |
| rust/src/content_engine.rs | 2376 | definition | MUST_UPDATE | Change `texts.push(record.text)` → `texts.push(record.effective_dense_text().to_string())` |

---

## Symbol 8: Rust `replace_units` and structural batch embed

**Change class:** semantic — identical rationale as Symbol 6
**Scope:** internal

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| rust/src/content_engine.rs | 1930 | definition | MUST_UPDATE | Change `record.text.clone()` → `record.effective_dense_text().to_string()` for whole-content unit |
| rust/src/content_engine.rs | 1296 | definition | MUST_UPDATE | Change `embed_pair(&record.text)` → `embed_pair(record.effective_dense_text())` in structural batch embed |
| rust/src/content_engine.rs | 2714 | definition | MUST_UPDATE | Change `embed_pair(&record.text)` → `embed_pair(record.effective_dense_text())` in coverage backfill |

---

## Summary

- MUST_UPDATE: 21 sites across Swift sources, Rust sources, and Rust tests
- INTENTIONALLY_LEFT: 5 sites (callers that ignore nil dense text / protocol consumers)
- RESCOPE_REQUIRED: 0

### New files (additive)
- `Tests/CorpusKitTests/DualTextIndexingTests.swift` — new test file
- `rust/tests/dual_text_indexing_tests.rs` — new Rust test file (or appended to existing)

### Recomposability invariant (mission requirement)
All recomposed vectors use the dense-composition text, which is persisted in `corpus_documents.dense_text` (standalone) or supplied by the source adapter at record-resolution time (attached). The recomposability rule is satisfied: a basis retrain or reindex can always reconstruct vectors from durable canonical text.
