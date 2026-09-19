---
title: Deterministic Alternative Methods Definition
release: "1.1"
date: 2026-08-28
description: The four deterministic judge-free methods over public data sets — what each measures, why each exists beside the published protocol, and its relation to the spec lane.
---

# Deterministic Alternative Methods

## Purpose

Four public data sets in this suite carry two measurement methods each. The
spec lane implements the data set's published evaluation protocol; that
protocol needs a judge model or an answering model for three of the four.
The methods defined here are the deterministic alternative: they call no
external model, a fixed run produces the same number every time, and the
number is comparable across releases.

They exist for the operator to whom a judge is cost prohibitive, and for
release regression testing at scale, where a metric that moves only when the
retrieval path moves is worth more than a metric that also moves when a
judge does. `BENCHMARK_METHOD.md` §7 states each method's standing; this
document defines the methods themselves.

These methods are run by the LEGACY subcommands (`locomo`, `longmemeval`,
`lmeb`, `membench`) via their unchanged `measure-*` targets. The published
protocols are run by the spec lanes (`*-spec` subcommands; see the
extractions under `specs/`).

## Terminology

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |

## The four methods

### LoCoMo — turn-level evidence retrieval

Every scoreable question names the conversation turns (`dia_id`) holding its
evidence. The method ingests the conversation, asks the question through the
recall path, and scores whether the labelled turns appear in the top k of
the ranked result, reported as recall@k and MRR. Category-5 questions
(adversarial, no ground-truth answer) are excluded, as are the four
questions with empty evidence lists: a retrieval metric needs a labelled
target.

Relation to the published protocol (§7.3): not a substitute — a stricter
additional guard. The published protocol scores generated answers with
stemmed token F1 and needs no judge; this method instead demands the exact
evidence turn out of hundreds, a harder target than any answer-level score.

### LongMemEval — session-level retrieval

Every question names its evidence sessions. The method scores whether those
sessions appear in the top k, as recall@k and MRR, skipping abstention
questions (they have no evidence location — the same exclusion the paper
applies to its retrieval metrics). Payload modes measure token economics of
the same asks.

Relation (§7.2): the judge-free substitute. The published metric is judged
answer accuracy at roughly 500 judge calls per run; this method is zero
model calls and repeatable to the digit.

### LMEB (ConvoMem) — retrieval over per-scene pools

Each query seeds its scene's candidate pool into an isolated database and
scores the ranked retrieval against the qrels, as nDCG@10, recall@k, MRR
and AP@10. Unmapped result rows keep their rank slot rather than being
dropped.

Relation (§7.4): deterministic in both lanes. The spec lane widens the same
measurement to the paper's full metric grid (k∈{1,5,10,25,50}, capped
recall, instruction settings); the data set's own judged-QA protocol lives
in `convomem-spec`.

### MemBench — evidence retrieval

Every item names the turns holding the answer's evidence. The method scores
their presence in the top k, as recall@k and MRR, per category and per agent
perspective.

Relation (§7.1): the judge-free alternative. The published protocol has an
answering model choose among four options over recalled context; this
method scores the retrieval path directly and does not depend on answer
generation.

## What the methods share

- One isolated database per unit; no cross-unit leakage.
- Deterministic ordering: seeded shuffle from a recorded seed.
- Evidence labels come from the data set, never from a model.
- Reports carry the ranked ids per unit, so any score is recomputable from
  the record without rerunning.

## What these methods do not measure

Answer quality. A run can retrieve the right evidence and still answer
wrongly; only the spec lanes measure that. The register files the two
methods' figures in separate sections and never substitutes one for the
other.

## Invocation

```sh
make smoke-measure-deterministic-alternatives [PORT=swift|rust]
make measure-deterministic-alternatives [PORT=swift|rust] [LIMIT=<n>]
```

Run these commands from `benchmarks/`. The wide target requires the selected
port's smoke stamp.
