---
title: Journey Benchmark Definition
release: "1.1"
date: 2026-08-28
description: Cost of reaching a correct answer across a multi-step agent sequence, measured as four integer counts.
---

# Journey Benchmark

## Purpose

This test measures the cost of reaching a correct answer, not whether the
answer was reachable.

The public benchmarks provision one database per question and score a single
retrieval: was the right row in the top k. That design cannot measure how much
work an agent performs to arrive at the answer, and it cannot expose two
failure modes that appear only across a sequence of steps.

## Terminology

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |

## Data set

Two generated data sets, one per failure mode. Both are pure functions of a
seed: the same seed produces the same bytes, and the Swift and Rust
implementations produce identical output under a conformance gate.

**Precise miss.** The correct row is present in the database. A near-duplicate
decoy repeats the query's distinctive terms more densely and outranks it. The
query has one correct answer and the decoy is not it.

**Vague narrow.** The query is open-ended and resolves against a cluster of
on-topic siblings. One member carries the answer detail. Term overlap alone
does not separate the true member from its siblings.

Generation is bounded by `--precise-miss-count`, `--cluster-count` and
`--members-per-cluster`.

Every scored behaviour is achievable in principle by any competent retrieval
system. Nothing is scored that requires a feature specific to the system under
test.

## Metrics

Four integer counts over an ordered sequence of steps.

**Hops** is the number of tool calls the agent made.

**Token-turn residency integral** is the volume of payload reprocessed across
turns. For a sequence of N steps indexed 0 to N−1, the cumulative payload at
step i is the sum of payload tokens for steps 0 through i. The integral is the
sum of those cumulative payloads over all steps:

```
integral = Σ(i=0..N-1) Σ(j=0..i) payloadTokens[j]
```

**Pre-terminal full-content tokens** is the count of full-body tokens fetched
before the final answer step.

**Total payload tokens** is the token volume across all steps.

The metrics are computed from the recorded step sequence and contain no
floating-point arithmetic.

## What is recorded

Per journey: the four counts, the step sequence, and the data set seed. Each
report carries the provenance fields required by `../BENCHMARK_METHOD.md` §6.

## Invocation

```sh
make smoke-measure-journey [PORT=swift|rust]
make measure-journey [PORT=swift|rust] [LIMIT=<n>]
```

`make seeds` generates the corpus. Run these commands from `benchmarks/`. The
wide target requires the selected port's smoke stamp.
