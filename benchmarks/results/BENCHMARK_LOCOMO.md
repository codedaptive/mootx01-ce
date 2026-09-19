---
title: LoCoMo Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing task, metric, coverage, reproduction, and evidence contract for the LoCoMo benchmark.
---

# LoCoMo

## What it measures

LoCoMo, Long Conversational Memory, tests question answering over 10
multi-session conversations containing 1,986 questions. The question set
includes multi-answer, short factual, temporal, single-answer, and adversarial
abstention categories.

The published `locomo-spec` protocol uses an answering model. It normalizes the
answer, removes articles, applies Porter stemming, and reports token F1 by
category. Adversarial questions require an abstention phrase. The exact rules
are in `../specs/LOCOMO_OFFICIAL_PROTOCOL.md`.

The deterministic `locomo` lane measures evidence retrieval on the 1,536
questions with labeled evidence turns. It reports any@1, any@5, any@10, all@5,
and MRR. It is an additional retrieval guard, not the published QA score.

## Origin and corpus

Jang et al. published LoCoMo with *CONVERSATION CHRONICLES: Towards Rich and
Consistent Conversational Agents* (arXiv:2402.17753, ACL 2024). The corpus and
evaluation code are in `github.com/snap-research/locomo` under CC BY-NC 4.0.

- Dataset key: `locomo`
- Protocol key: `locomo`
- Fetch command: `make fetch`
- External fixture: `$BENCH_WORK_ROOT/fixtures/locomo/data/locomo10.json`
- Coverage: all 10 conversations; 1,536 retrieval-scored questions; 1,986
  published-protocol questions

## Run procedure

Run from `benchmarks/`:

```sh
make fetch
make seeds
make smoke-bench-locomo PORT=<swift|rust>
make measure-locomo PORT=<swift|rust> SCALE=unit
```

`SCALE=unit` is the published per-instance storage shape. Use
`bench-aggregate` or `complete-aggregate` only for separately labeled
aggregate comparisons.

Run the published protocol with inflight judging:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
MOOT_BENCH_JUDGE_CMD="…" \
make measure-locomo-spec PORT=<swift|rust> SCALE=unit
```

Run deferred judging:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
make measure-locomo-spec PORT=<swift|rust> SCALE=unit DUMP=1
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

## Evidence and publication

The report records binary identity, product version, protocol version, estate
schema, scale, coverage, and per-question outcomes. Answer-quality figures name
the answering model. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
