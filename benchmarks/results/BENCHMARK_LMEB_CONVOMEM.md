---
title: LMEB and ConvoMem Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing task, metric, coverage, reproduction, and evidence contract for the two protocols over ConvoMem.
---

# LMEB and ConvoMem

## What they measure

The `convomem` corpus supports two published protocols across 5,867 questions
in six evidence categories:

| Category | Questions |
|---|---:|
| abstention | 982 |
| assistant facts | 765 |
| changing facts | 1,434 |
| implicit connection | 990 |
| preference | 356 |
| user evidence | 1,340 |

LMEB is a deterministic retrieval protocol over each question's candidate
pool. The `lmeb-spec` lane reports the official metric grid at k = 1, 5, 10,
25, and 50, including Recall, capped Recall, MRR, nDCG, and MAP under both
instruction settings.

ConvoMem judged QA generates an answer from retrieved memory and grades it
RIGHT or WRONG with the evidence-type judge template. The `convomem-spec` lane
implements this model-based protocol.

The exact candidate restriction, metric equations, answer prompt, judge
templates, and verdict rules are in
`../specs/LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md`.

## Origin and corpus

Chen et al. published LMEB with *KaLM-Embedding: Superior Training Data Brings
A Stronger Embedding Model* (arXiv:2603.12572). Its ConvoMem task and retrieval
code are in `github.com/KaLM-Embedding/LMEB` under the MIT license. Yoon et al.
published the judged-QA protocol with *ConvoMem: Benchmarking Conversational
Memory Agents* (arXiv:2511.10523); code is in
`github.com/SalesforceAIResearch/ConvoMem`.

- Dataset key: `convomem`
- Protocol keys: `lmeb`, `convomem`
- Fetch command: `make fetch`
- External fixture: `$BENCH_WORK_ROOT/fixtures/lmeb/data/ConvoMem/`
- Coverage: all six categories, 5,867 questions

## Run procedure

Run from `benchmarks/`:

```sh
make fetch
make seeds
make smoke-bench-convomem PORT=<swift|rust>
make measure-convomem PORT=<swift|rust> SCALE=unit
make measure-lmeb-spec PORT=<swift|rust> SCALE=unit
```

Run ConvoMem judged QA in deferred mode:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
make measure-convomem-spec PORT=<swift|rust> SCALE=unit DUMP=1
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

## Evidence and publication

Reports name the protocol, category coverage, instruction setting, scale,
binary identity, protocol version, and estate schema. ConvoMem judged figures
also name the answer and judge models. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
