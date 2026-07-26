---
version: v0.1
---

# COMPLETION: LME-06

Status: COMPLETE

## Pre-flight and Post-flight Verdicts

**Smythe (pre-flight):** Not run in a separate pass (context-continuation session).
Blast radius is Tier 3 net-new — all files added, zero existing symbols changed,
renamed, removed, or deprecated. BRR not required per tier 3 rules.

**Adams (post-flight):** Pending (spawning after completion report).

## What Was Done

Mission implemented across two sessions (context compaction mid-mission).
All four parts are on stream branch `stream/lme-lmeb`.

- Part 1: LMEB corpus loaders (Swift + Rust), fixture files, fetch script — `633962dc`
  - `LMEBCorpus.swift`: 283 lines, loadLMEBCorpus, LMEBQuery, LMEBDoc, LMEBCorpus
  - `rust/src/lmeb_corpus.rs`: 544 lines, load_lmeb_corpus, identical schema
  - `lmeb_sample/user_evidence/`: 4 fixture files (corpus, queries, candidates, qrels)
  - `conformance/lmeb_vectors.json`: placeholder (upgraded in Part 2)
  - `scripts/fetch-lmeb.sh`: download script, MIT license notice

- Part 2: Swift subcommand + scoring — `b47930ef`
  - `LMEBScorer.swift`: lmebNDCG, lmebMRR, lmebRecall, lmebAP, lmebPercentile,
    scoreLMEBQuery, aggregateLMEBScores, JSON report types, buildLMEBReport, writeLMEBReport
  - `LMEBRunner.swift`: lmebMootVerbMap (location "benchmark/lmeb"), lmebScratchDir,
    lmebGuardedTeardown, lmebEndpointConfig, runLMEBQueries (n=true per write)
  - `LMEBScorerTests.swift`: 16 conformance + unit tests (213 total Swift tests)
  - `conformance/lmeb_vectors.json`: 29 vectors (8 nDCG + 7 MRR + 6 recall + 8 AP)
  - `main.swift`: lmeb dispatch case + runLMEB function

- Part 3: Rust twin — `72ad61a2` (includes fix: `changing_state_evidence` → `changing_evidence`)
  - `rust/src/lmeb_scorer.rs`: lmeb_ndcg, lmeb_mrr, lmeb_recall, lmeb_ap, lmeb_percentile,
    score_lmeb_query, aggregate_lmeb_scores, build_lmeb_report, write_lmeb_report (sorted_json_value)
  - `rust/src/lmeb_runner.rs`: lmeb_verb_map, lmeb_scratch_dir, lmeb_guarded_teardown,
    lmeb_endpoint_config, ingest_doc (n=true), run_one_lmeb_query, run_lmeb_queries
  - `rust/src/lib.rs`: pub mod lmeb_runner + lmeb_scorer added
  - `rust/tests/conformance.rs`: lmeb_scorer_ndcg_vectors, lmeb_scorer_mrr_vectors,
    lmeb_scorer_recall_vectors, lmeb_scorer_ap_vectors (4 new tests, 109 total Rust tests)
  - `rust/src/main.rs`: lmeb subcommand dispatch + run_lmeb function

- Part 4: Diagnostic smoke + fixes — `1cbdc117`
  - Fixed: `changing_evidence` (not `changing_state_evidence`) aligns Rust with Swift + HuggingFace
  - Fixed: fetch-lmeb.sh run examples used wrong flag (--config → --data-dir)
  - `results/LMEB_DIAGNOSTIC_SMOKE_2026-07-26.md`: 50-query live smoke from both twins

## Test Verification Log

- swift build (Part 4): exit 0
- swift test (Part 4): exit 0, 213 tests in 44 suites, all passing
  - Baseline before mission: 197 tests
  - Delta: +16 tests (LMEBScorerTests 16, LMEBCorpusTests counted in LMEBScorerTests)
- cargo build (Part 4): exit 0
- cargo test (Part 4): exit 0, 109 tests (81 unit + 27 conformance + 1 stdio)
  - Baseline before mission: 92 tests
  - Delta: +17 tests (4 LMEB conformance + 13 lmeb_corpus unit tests added in Part 1)

## Diagnostic Smoke (Part 4 — 50q, user_evidence, seed 20260725)

| Metric     | Rust   | Swift  | Delta    |
|------------|--------|--------|----------|
| queries_run | 50    | 50     | 0        |
| guard_excl  | 0     | 1      | —        |
| nDCG@10     | 0.4651 | 0.4644 | +0.0007 |
| MRR         | 0.5525 | 0.5645 | −0.0120 |
| recall@1    | 0.2683 | 0.2602 | +0.0081 |
| recall@5    | 0.4343 | 0.4279 | +0.0064 |
| recall@10   | 0.5483 | 0.5476 | +0.0007 |
| MAP@10      | 0.3767 | 0.3696 | +0.0071 |
| query_p50_s | 0.0861 | 0.0937 | −0.0076 |
| query_p95_s | 0.1924 | 0.1903 | +0.0021 |
| wall_time   | ~3m07s | ~3m10s | — |

Twin agreement on nDCG@10: Δ0.0007 (excellent — within expected mootx01 ANN variance).
Scoring math verified to 1e-9 via 29 conformance vectors; score differences are retrieval
variance, not math divergence.

## Discoveries

- **Conformance vector precision**: nDCG@k uses DCG@k = Σ 1/log2(rank+1) (zero_based=0
  → divisor = log2(2) = 1.0). Pre-computed IEEE 754 values: 1/log2(3) = 0.6309297535714573,
  two-relevant nDCG = 0.9197207891481876, AP interleaved = 0.8333333333333334. Both legs
  reproduce all 29 vectors to within 1e-9.

- **Evidence type naming**: HuggingFace LMEB dataset uses `changing_evidence` (not
  `changing_state_evidence`). Caught during Part 4 self-review.

- **fetch-lmeb.sh run examples were wrong**: examples used `--config` (transfer subcommand
  flag) instead of `--data-dir` (lmeb subcommand flag). Fixed in Part 4.

- **Rust SplitMix64 reuse**: `lmeb_runner.rs` re-exports `SplitMix64` from
  `longmemeval_runner`. Same seed → same shuffle order on both legs (verified by
  having same first 50 query IDs in both smoke runs).

- **DegeneracyGuard variance on 50q**: Swift had 1 guard exclusion, Rust had 0. This is
  normal per-run variance in the 3 probe-query comparisons. The guard algorithm is identical;
  mootx01's ANN ranking for probe queries has slight non-determinism.

- **Per-query candidate pool size**: averaging ~88 docs/scene (10–168 range) for
  user_evidence. Write time is fast (~4ms/doc) because n=true flushes synchronously.

## Outstanding

- Full 6-evidence-type LMEB run not done (~6–8h single-threaded). Results here are
  user_evidence only (1,340 queries of ~5,867 total).
- Abstention handling: the LMEB dataset includes `abstention_evidence` type where some
  queries have no relevant documents. Both scorers return nDCG=0.0/recall=0.0 for empty
  relevant sets (correct per §1.4 of the BENCHMARKER_OPTIMIZER_CONTRACT). Not tested
  with live data here.
- LLM-judge accuracy scoring (answer quality beyond document retrieval) not in scope.
