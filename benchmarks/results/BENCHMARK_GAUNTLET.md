---
title: Gauntlet Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing purpose, distractor classes, metrics, reproduction, and evidence contract for the Gauntlet benchmark.
---

# Gauntlet

## What it measures

Gauntlet measures retrieval of known records buried under five labeled classes
of adversarial distractor:

| Class | Pressure |
|---|---|
| T1 lexical | shared words without the target fact |
| T2 semantic | similar meaning without the target fact |
| T3 temporal | competing versions or time-adjacent facts |
| T4 split | required content divided across records |
| T5 scatter | required evidence distributed among unrelated records |

Each needle is scored independently. Metrics include found@1/5/10, reciprocal
rank, completeness, contamination, and returned bytes. Corpus generation and
scoring are deterministic functions of the recorded seed. The complete
definition is in `../benchmarks/gauntlet.md`.

The degeneracy guard runs before scoring. A refused query is a run failure, not
a zero-score row.

## Run procedure

Run from `benchmarks/`:

```sh
make seeds
make smoke-measure-gauntlet PORT=<swift|rust>
make measure-gauntlet PORT=<swift|rust> [LIMIT=<n>]
```

The wide target requires the selected port's smoke stamp. `LIMIT` is for a
bounded diagnostic run and is recorded in the report.

## Evidence and publication

The report records the seed, distractor counts, class, needle ground truth,
ranked identifiers, every metric, binary identity, protocol version, estate
schema, port, and coverage. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
