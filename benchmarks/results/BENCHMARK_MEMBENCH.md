---
title: MemBench Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing task, metric, coverage, reproduction, and evidence contract for MemBench.
---

# MemBench

## What it measures

MemBench evaluates memory-system question answering across two distinct task
shapes:

| Perspective | Items | Shape |
|---|---:|---|
| FirstAgent | 7,000 | multi-session user and assistant dialogue |
| ThirdAgent | 13,137 | observed statements about third parties |

The `membench-spec` lane implements the published interaction protocol. It
stores each message with its step prefix, asks an answering model to choose one
of four options, and scores the returned letter by exact equality. It also
reports the paper's step-ID recall, efficiency timers, and capacity walk. The
exact storage format, prompts, metrics, and capacity semantics are in
`../specs/MEMBENCH_OFFICIAL_PROTOCOL.md`.

The deterministic `membench` lane measures whether labeled evidence turns
appear in the ranked results. It reports recall@k and MRR per category and per
perspective. This is a retrieval guard, not the published multiple-choice
score. FirstAgent and ThirdAgent figures are never averaged into one task
score.

## Origin and corpus

Li et al. published MemBench with *MemBench: Evaluating LLM Memory Systems*
(arXiv:2506.21605, ACL Findings 2025). The upstream corpus and evaluation code
are in `github.com/import-myself/Membench`.

- Dataset key: `membench`
- Protocol key: `membench`
- Fetch command: `make fetch`
- External fixture: `$BENCH_WORK_ROOT/fixtures/membench/MemData/`
- Coverage: both perspectives, 20,137 items total

## Run procedure

Run from `benchmarks/`:

```sh
make fetch
make seeds
make smoke-bench-membench PORT=<swift|rust>
make measure-membench PORT=<swift|rust> SCALE=unit
```

Run the published protocol with deferred judging inputs:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
make measure-membench-spec PORT=<swift|rust> SCALE=unit DUMP=1
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

## Evidence and publication

Reports identify the perspective, coverage, scale, binary, protocol, estate
schema, answering model, and per-item outcomes. Capacity results also record
the token-budget step. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
