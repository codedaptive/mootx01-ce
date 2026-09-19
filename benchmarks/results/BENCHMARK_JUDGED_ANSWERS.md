---
title: Judged Answer Accuracy Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing judge-panel, consensus, batching, reproduction, and evidence contract for model-graded benchmark answers.
---

# Judged Answer Accuracy

## What it measures

Judged accuracy evaluates whether a produced answer satisfies a benchmark's
published rubric. Each judge receives the question, reference answer, produced
answer, and protocol-specific prompt, then returns one verdict. The score
measures the complete retrieval-and-answer pipeline and always names the
answering and judging models.

Retrieval metrics and judged-answer metrics remain separate. Correct evidence
retrieval does not itself assert that the final answer is correct.

## Multi-judge consensus

When a panel is commissioned, each judge grades the same frozen answer set.
The report records one row per question and judge. Consensus is a per-question
majority vote; an even panel must define a tie rule before the run. The report
also records unanimity, per-judge yes-rate, agreement with consensus, and
Fleiss kappa.

Panel verdicts are never averaged across different answer sets, prompts, or
protocol versions. A deterministic containment audit may be reported as a
separate cross-check; it is not substituted for the published judge rubric.

## Run procedure

Run the applicable spec lane from `benchmarks/` in deferred mode:

```sh
MOOT_BENCH_ANSWER_CMD="…" \
make measure-<protocol>-spec PORT=<swift|rust> SCALE=unit DUMP=1
```

Canary one JSONL section before the full judge pass:

```sh
python3 scripts/judge-sessions.py \
  --inputs results/judge-dumps/<run-id>/<section>.jsonl \
  --judge-id <judge-id> \
  --judge-cmd "<stdin-to-stdout-command>" \
  --out results/judge-dumps/<run-id> \
  --canary
```

Complete and consume the deferred run:

```sh
MOOT_BENCH_JUDGE_CMD="…" \
make judge-batch DUMPS=results/judge-dumps/<run-id>
```

Batching, retries, misses, resume behavior, and verdict schema are defined in
`../JUDGE_PHASE.md`.

## Evidence and publication

The durable evidence includes frozen answers, judge inputs, per-judge verdicts,
misses, batch logs, consensus rows, answer and judge identities, protocol
version, and run identity. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
