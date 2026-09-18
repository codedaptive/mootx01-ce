---
title: Benchmark Results Register
release: "1.1"
date: 2026-09-17
description: Catalog of benchmark result surfaces, required coverage, evidence, and authoritative detail pages.
---

# Benchmark Results Register

This register defines the result surfaces for release 1.1. Each detail page is
the authoritative location for figures in that class and identifies the source
report and parameter sidecar from which every published value is copied.

## Status at this release

The suite is built and runs end to end from the Makefile: setup, corpus
seeding, artifact build, measurement, judging, and release qualification. The
runs are under way.

Figures land here when the runs finish. Until then every cell reads `pending`.

| Surface | Required coverage | Primary figures | Detail |
|---|---|---|---|
| LoCoMo retrieval | 10 conversations; 1,536 evidence-scored questions | any@1/5/10, all@5, MRR | [`BENCHMARK_LOCOMO.md`](BENCHMARK_LOCOMO.md) |
| LoCoMo published QA | all 1,986 questions | per-category stemmed token F1 | [`BENCHMARK_LOCOMO.md`](BENCHMARK_LOCOMO.md) |
| LongMemEval-s retrieval | all 500 `s` questions, excluding abstention from location metrics | any@1/5/10, all@1/5/10, MRR | [`BENCHMARK_LONGMEMEVAL.md`](BENCHMARK_LONGMEMEVAL.md) |
| LongMemEval-s judged QA | all 500 questions | judged accuracy and panel agreement | [`BENCHMARK_JUDGED_ANSWERS.md`](BENCHMARK_JUDGED_ANSWERS.md) |
| LMEB | all six categories; 5,867 questions | official recall grid, capped recall, MRR, nDCG, MAP | [`BENCHMARK_LMEB_CONVOMEM.md`](BENCHMARK_LMEB_CONVOMEM.md) |
| ConvoMem judged QA | all six categories; 5,867 questions | judged answer accuracy by category | [`BENCHMARK_LMEB_CONVOMEM.md`](BENCHMARK_LMEB_CONVOMEM.md) |
| MemBench retrieval | FirstAgent and ThirdAgent reported separately; 20,137 total | recall@k and MRR | [`BENCHMARK_MEMBENCH.md`](BENCHMARK_MEMBENCH.md) |
| MemBench published protocol | both perspectives reported separately | exact-letter accuracy, step recall, efficiency, capacity | [`BENCHMARK_MEMBENCH.md`](BENCHMARK_MEMBENCH.md) |
| Supersession | complete generated corpus | current-version rank, wins, contradiction tiers, decoy firing | [`BENCHMARK_SUPERSESSION.md`](BENCHMARK_SUPERSESSION.md) |
| Journey | complete generated scenario set | hops, token-turn integral, pre-terminal full-content tokens, total payload tokens | [`BENCHMARK_JOURNEY.md`](BENCHMARK_JOURNEY.md) |
| Gauntlet | all five distractor classes | found@k, reciprocal rank, completeness, contamination, bytes | [`BENCHMARK_GAUNTLET.md`](BENCHMARK_GAUNTLET.md) |
| Storage matrix | complete fixed matrix corpus | conversion failures and ranked-list divergences | [`BENCHMARK_MATRIX.md`](BENCHMARK_MATRIX.md) |
| Timing and throughput | fixed landscape and recorded machine profile | four latency families and separately scoped throughput | [`BENCHMARK_TIMING_THROUGHPUT.md`](BENCHMARK_TIMING_THROUGHPUT.md) |
| Substrate math | complete vector gate plus named workload | conformance, drift, and separately scoped kernel timing | [`BENCHMARK_SUBSTRATE_MATH.md`](BENCHMARK_SUBSTRATE_MATH.md) |

## Published figures

| Surface | Swift | Rust | Run identifier |
|---|---|---|---|
| LoCoMo retrieval | pending | pending | pending |
| LoCoMo published QA | pending | pending | pending |
| LongMemEval-s retrieval | pending | pending | pending |
| LongMemEval-s judged QA | pending | pending | pending |
| LMEB | pending | pending | pending |
| ConvoMem judged QA | pending | pending | pending |
| MemBench retrieval | pending | pending | pending |
| MemBench published protocol | pending | pending | pending |
| Supersession | pending | pending | pending |
| Journey | pending | pending | pending |
| Gauntlet | pending | pending | pending |
| Storage matrix | pending | pending | pending |
| Timing and throughput | pending | pending | pending |
| Substrate math | pending | pending | pending |

## Identity required beside every figure

- run identifier and UTC date;
- binary SHA-256 and product version;
- protocol version and estate schema version;
- port and storage scale or internal run shape;
- complete coverage declaration;
- machine profile and load state for timing;
- answering and judging model identities for model-based figures; and
- source report and parameter sidecar.

Retrieval, answer quality, latency, throughput, payload efficiency, storage
behavior, and kernel timing are separate result classes and are never collapsed
into one score. A value lacking any required identity field is not a release
figure.
