---
title: LongMemEval Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing task, metric, coverage, reproduction, and evidence contract for LongMemEval-s.
---

# LongMemEval-s

## What it measures

LongMemEval evaluates question answering over long, multi-session assistant
histories. Release 1.1 uses the 500-question small-haystack variant,
`LongMemEval-s`. Question types cover single-session user and assistant facts,
preferences, multi-session facts, temporal reasoning, knowledge updates, and
abstention.

The published `lme-spec` protocol grades generated answers with the benchmark's
type-specific judge prompts. The exact prompts, judge parameters, aggregation,
and abstention rules are in `../specs/LONGMEMEVAL_OFFICIAL_PROTOCOL.md`.

The deterministic `lme-s` lane measures whether labeled evidence sessions
appear in the ranked results. It reports any@1/5/10, all@1/5/10, and MRR.
Abstention questions have no evidence location and do not enter retrieval
metrics.

## Origin and corpus

Wu et al. published LongMemEval with *LongMemEval: Benchmarking Chat Assistants
on Long-Term Interactive Memory* (arXiv:2410.10813, ICLR 2025). The upstream
code is in `github.com/xiaowu0162/LongMemEval`; the cleaned corpus used here is
`xiaowu0162/longmemeval-cleaned` on Hugging Face under CC BY 4.0.

- Dataset key: `lme-s`
- Protocol key: `lme`
- Fetch command: `make fetch`
- External fixture: `$BENCH_WORK_ROOT/fixtures/longmemeval/data/`
- Coverage: all 500 `s`-variant questions

The `m` variant is a different haystack configuration and is never represented
by an `lme-s` result.

## Run procedure

Run from `benchmarks/`:

```sh
make fetch
make seeds
make smoke-bench-lme-s PORT=<swift|rust>
make measure-lme-s PORT=<swift|rust> SCALE=unit
```

Run the published protocol with deferred judging:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
make measure-lme-spec PORT=<swift|rust> SCALE=unit DUMP=1
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

Set `MOOT_BENCH_JUDGE_CMD` on the spec invocation instead of `DUMP=1` for
inflight judging.

## Evidence and publication

The result names the storage scale, answering model, judge identity, binary
digest, protocol version, estate schema, coverage, and `judged_count`.
Retrieval and judged-answer figures remain separate. Copy only human-accepted
figures from `../RESULTS_RECORD.md` into a public result register.
