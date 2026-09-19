---
title: Retired Techniques Ledger
version: 1.3.0
status: active
date: 2026-09-14
description: Engineering decisions for retired retrieval and stored-representation techniques.
---

# Retired Techniques Ledger

Read the evidence for a technique before testing it again. Add a new row when
another technique is retired. Preserve earlier rows as decision history.

The evaluations concern our own corpora and aggregate estates. Retrieval
comparisons use nDCG@10 and any@k. Storage and lifecycle decisions have
separate criteria. An architectural retirement does not establish a measured
retrieval loss.

Dates below bound the retained evaluation or decision records. They do not
imply daily tests. A proposed policy with no experiment is identified as such.
Aggregate corpus A held 13,817 session records. The cited retrieval runs
used a 120-question sample. Corpus B held 19,195 sessions; the span comparison
used a stratified 120-question sample from its 500 questions.

Whole-record family results below are a combined-arm measurement. They are
not individual-family ablations. The recorded lexical candidate pools had
any@1000 of 0.983 on corpus A and 0.954 on corpus B. Those pool-coverage
figures are separate from ranked nDCG@10.
Evidence is named so the record remains readable outside the engineering tree.

Figures are sourced from the engineering evidence records named in each row. RECALL_LEVER_EXPLORATION and the Encoder Rerank Program plan of record are the primary sources unless a row names another document.

| Technique | What it did | Evaluation or decision window | Measurement and scope | Outcome | Replacement | Evidence by name |
|---|---|---|---|---|---|---|
| Stored adornments | Attached generated short text to source records. | 2026-09-04 to 2026-09-05 | On our aggregate corpora the silo precision@1 was 0.200; peer-list nDCG@10 was 0.073 and 0.033. | The retrieval variants did not improve the recorded lexical baselines. | Source content spans and inline hydration. | Encoder Rerank Program plan of record; RECALL_LEVER_EXPLORATION. |
| Product minter pass | Scheduled generation and stored output for active minters. | 2026-08-23 to 2026-09-05 | Generation coverage supported the adornment experiments; the larger final judging run was cancelled. | Removing adornment storage removed the purpose of the product minter pass. | A span-encode duty over source content. | ADORNMENTLIB_SPEC; ADORNMENTLIB_INTERFACE; PLAN_RECONCILIATION_2026-09-06. |
| Separate minting and surfacing policy | Proposed independent controls for generation and presentation. | 2026-09-04 to 2026-09-05 | Proposed policy only; no completed retrieval experiment is recorded. | The proposal was superseded when the underlying store was removed. | Source-record hydration without a minter selector. | DECISION_ADORNMENT_ACTIVATION_SPLIT_2026-09-04. |
| Stored text distillation | Persisted compact text with converter identity and source currency. | 2026-09-04 to 2026-09-05 | A second lexical index over compact text changed nDCG@10 by +0.002 to +0.008 on aggregate corpus A and −0.001 to −0.017 on corpus B; inline conversion took 17 ms for a 4.9k-character record. | Small mixed retrieval effects did not justify retaining the stored representation machinery. | Deterministic inline compression at read time. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program rulings; ENCODER_RERANK_CONTRACT. |
| Distillation sweeps and rebuild commands | Refreshed stored representations before retrieval. | 2026-09-02 to 2026-09-05 | Lifecycle dependency on the stored rendering; no independent retrieval experiment. | Inline rendering removed the need for a stored-text sweep. | Compact hydration computed for each requested record. | DECISION_CONTEXTDISTILLLIB_2026-09-02; PLAN_RECONCILIATION_2026-09-06. |
| LSA record vectors | Used a fitted low-rank term representation as a retrieval signal. | 2026-09-05 to 2026-09-07 | The combined whole-record arm scored 0.311 nDCG@10 versus 0.432 with its vector column excluded on aggregate corpus A; this family used 7 MB of vector storage. Since 2026-09-07 the implementation is dark and unproven on a switch of its own (`LSA` / `lsa`) that the dense-families switch does not enable and no build gate exercises; its test `reindex recovers a deliberately-degenerate LSA basis` fails on the development line. | The combined arm reduced retrieval quality and the retired families together cost more storage than the replacement span index; the implementation is retained unverified. | Lexical candidates with span reranking. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program storage inventory; CorpusKit specification 2.4.0. |
| NMF record vectors | Used nonnegative term factors as a retrieval signal. | 2026-09-05 | The combined whole-record arm scored 0.311 nDCG@10 versus 0.432 with its vector column excluded on aggregate corpus A; this family used 3 MB of vector storage. | The combined arm reduced retrieval quality and the retired families together cost more storage than the replacement span index. | Lexical candidates with span reranking. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program storage inventory. |
| PPMI record vectors | Used term co-occurrence vectors as a retrieval signal. | 2026-09-05 | The combined whole-record arm scored 0.311 nDCG@10 versus 0.432 with its vector column excluded on aggregate corpus A; this family used 216 MB of vector storage. | The combined arm reduced retrieval quality and the retired families together cost more storage than the replacement span index. | Lexical candidates with span reranking. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program storage inventory. |
| FDC record vectors | Used classification-derived vectors as a retrieval signal. | 2026-09-05 | The combined whole-record arm scored 0.311 nDCG@10 versus 0.432 with its vector column excluded on aggregate corpus A; this family used 14 MB of vector storage. | The combined arm reduced retrieval quality and the retired families together cost more storage than the replacement span index. | Lexical candidates with span reranking. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program storage inventory. |
| Retired family steering presets | Emphasized or inverted the deferred record-vector families. | Decision recorded 2026-09-05. | Preset availability follows the family decision; no independent result is claimed. | Presets tied to the deferred families left the default roster. | Steering over the live recall signals. | ENCODER_RERANK_CONTRACT; RecallShape source. |
| Platform-specific record encoders | Used platform embedding models for candidate spans. | 2026-09-05 | Fused nDCG@10 was 0.442 and 0.448 on aggregate corpus A against 0.470 lexical; no corresponding corpus B result was recorded. | The tested platform span encoders did not improve the lexical baseline on corpus A. | A registered retrieval-trained span encoder in both ports. | RECALL_LEVER_EXPLORATION; Encoder Rerank Program rulings. |
| Index composition policy | Selected source or derived text for each indexing lane. | 2026-09-02 to 2026-09-05 | Storage and lifecycle review after removal of derived representation columns. | The remaining source text made the composition selector redundant. | One source-content indexing contract. | PLAN_RECONCILIATION_2026-09-06; CorpusKit specification composition-retirement entry. |
| Whole-record float lane in the default fusion | Fused one pooled float vector per record into every recall as a rank voter. | 2026-09-06 to 2026-09-07 | On aggregate corpus B with the span stage off, the lane cut the lexical gold at fusion on 13 of the 20 worst questions and cost about 0.04 nDCG@10 on the aggregate; no preset or call parameter could express its weight. | The lane lowered retrieval quality below the lexical order it fused with. | The span stage over source content; the engine stays as an opt-in build target for audition runs. | STAGE1C_TRACE; STAGE1C_DENSE_SWEEP; GeniusLocusKit specification 3.6.0. |

## Retained capabilities

The inline text compressor remains a deterministic library in both ports.
It reduces requested text at read time without storing another representation.
It does not alter recall ranking.

Random indexing remains available for fingerprints used by dreaming and
consolidation. Matrix NMF and classification anchors remain separate live
capabilities. Their names do not make them retired record-vector families.

## Deferred implementations

Four implementation switches preserve work for 1.2 review:

- `MOOTX01_MINERS` and Rust `miners`: the generation library for future fact creation.
- ~~`MOOTX01_DENSE_FAMILIES` and Rust `dense-families`~~: **retired 2026-09-14** — the NMF, PPMI and FDC providers and their presets (`ppmi_forward`, `nmf_forward`, `anti_redundant_nmf`) are removed. The switches no longer exist.
- ~~`MOOTX01_LSA` and Rust `lsa`~~: **retired 2026-09-14** — LSA joined the default ensemble and is unconditionally active. The switch no longer exists; `lsa_forward` and `anti_redundant_lsa` are in the always-on roster.
- `APPLE_ENCODERS`: the platform embedding adapters.

These switches do not restore the adornment tables removed at schema 19 or removed product
commands. The retired family presets include `ppmi_forward`, `lsa_forward`
and `nmf_forward`. They also include `anti_redundant_lsa` and
`anti_redundant_nmf`. The separate `ri_forward` preset remains in the source
roster because random indexing remains available.

A revisit requires the original evidence and a stated change in assumptions.
Individual-family comparisons require their original run evidence before a
new comparison claims continuity with the combined-arm experiment.

## Changelog

### 1.0.0 -- 2026-09-06

Recorded the retired techniques and retained inline compression contract.
Separated measured family results from superseded policy proposals.
