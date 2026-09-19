---
title: Supersession Benchmark Definition
release: "1.1"
date: 2026-08-28
description: Whether the current version of a changed fact outranks its superseded versions, measured on one database holding accumulated history.
---

# Supersession Benchmark

## Purpose

This test measures which version of a changed fact is returned.

The public benchmarks score whether the right row was retrieved. They do not
score the question a store faces once it has been running: when three versions
of the same fact are present, does the current one win and do the superseded
ones lose.

That gap is structural. Those benchmarks provision a fresh database per
question, so no history exists for a recency signal to be computed from. A
measurement taken there cannot observe behaviour that only exists once history
accumulates.

## Terminology

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |
| event time | `event_time` |

## Data set

One database, not one per question. Facts are written in chronological order
with real event times, and queries are asked only after the whole timeline is
in place.

The generated data set contains:

**Versioned entities.** Each entity has several versions of the same attribute,
written at increasing event times. Exactly one is current.

**Contradiction pairs.** Two rows that state incompatible values for the same
attribute. These must be flagged.

**Divergence pairs.** The same pair shape carrying digit-valued differences.

**Decoy pairs.** Adversarial non-contradictions. Two rows that resemble a
contradiction and are not one. These must not be flagged at any tier.

Counts are set by `--entities`, `--versions`, `--contradictions`,
`--divergences` and `--decoys`. The data set is a pure function of `--seed`.

Every scored behaviour is achievable in principle by any competent keyword and
vector system that tracks recency. Nothing is scored that requires a feature
specific to the system under test.

## Metrics

**Current-version rank** is the position of the current version in the returned
order for its entity's query.

**Superseded suppression** is whether superseded versions appear below the
current one.

**Contradiction detection** counts planted contradiction and divergence pairs
that were flagged, by tier.

**Decoy firing** counts decoy pairs that were flagged. A decoy flagged at any
tier is a failure.

## What is recorded

Per entity: the current-version rank and the position of each superseded
version. Per pair: whether it fired and at which tier. Each report carries the
provenance fields required by `../BENCHMARK_METHOD.md` §6.

## Invocation

```sh
make smoke-measure-supersession [PORT=swift|rust]
make measure-supersession [PORT=swift|rust] [LIMIT=<n>]
```

`make seeds` generates the corpus. Run these commands from `benchmarks/`. The
wide target requires the selected port's smoke stamp.

Deterministic replay of this benchmark is a quality control step, defined in
`../BENCHMARK_PROTOCOL.md`.
