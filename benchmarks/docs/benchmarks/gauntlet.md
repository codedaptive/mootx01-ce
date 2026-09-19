---
title: Gauntlet Benchmark Definition
release: "1.1"
date: 2026-08-28
description: Retrieval of known rows buried under five named classes of adversarial distractor, scored per row.
---

# Gauntlet Benchmark

## Purpose

This test measures retrieval against distractors engineered to defeat it in
named, separable ways.

Public data sets contain whatever distractors their source material happened to
contain. This data set plants them deliberately, one class at a time, so a
failure is attributable to a class rather than to the data set as a whole.

## Terminology

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |

## Data set

The data set is generated from one 64-bit seed. The same seed produces
byte-identical output, enforced as a test gate.

It contains **needles** and **distractors**. A needle is the single correct
answer for its query and its content is known exactly. A distractor is planted
to outrank the needle.

Distractors fall into five classes, tagged with stable identifiers used in the
generated files and in per-class report tables.

| Tag | Class |
|---|---|
| T1 | Lexical |
| T2 | Semantic |
| T3 | Temporal |
| T4 | Split |
| T5 | Scatter |

A T4 split needle is stored as two records. Each half is correct but
insufficient on its own. The second half is recorded as a split partner rather
than as a distractor, because returning it is not an error.

Generation is bounded by `--per-tier` and `--distractors`. `--tiers` selects
which classes are generated.

## Metrics

Scored per needle, from the ordered result set the system returned for that
needle's query.

**Found@k** is a flag per k in the scored set, by default 1, 5 and 10.

**Rank** is the 1-based position of the needle in the returned order, absent
when the needle appears at no scored depth.

**Completeness** is 1.0 when the returned row identified as the needle byte
matches the needle's stored content, and 0.0 otherwise. For a split needle it
is 1.0 only when both halves byte match the rows identified as each half. A
needle that was not found scores 0.0.

**Contamination** is the count of that needle's planted distractors present in
the returned top k, where k is the deepest value scored.

**Reciprocal rank** is 1 divided by rank, and 0.0 when the needle was not
found.

**Latency** is the recall duration in seconds, supplied by the runner.

**Bytes returned** is the payload size for that query, supplied by the runner.

Scoring is a pure function of the needle's ground truth and the returned result
set. It makes no server contact and reads no clock.

## What is recorded

One row per needle carrying every metric above, the class tag, and the seed.
Per-class tables aggregate those rows. Each report carries the provenance
fields required by `../BENCHMARK_METHOD.md` §6.

## Invocation

```sh
make smoke-measure-gauntlet [PORT=swift|rust]
make measure-gauntlet [PORT=swift|rust] [LIMIT=<n>]
```

`make seeds` generates the corpus. Run these commands from `benchmarks/`. The
wide target requires the selected port's smoke stamp.
