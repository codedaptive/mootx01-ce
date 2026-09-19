---
title: Synthesis Payload Definition
release: "1.1"
date: 2026-08-28
description: A store-generated digest scored as a fourth payload shape, on the same figures as payload economics.
---

# Synthesis Payload

## Purpose

This test measures a payload the store produces rather than returns.

The three shapes in payload economics are all views of retrieved rows. This
shape is a digest the store generates itself. It is scored on the same
figures, so the generated payload and the retrieved payloads are directly
comparable.

## Terminology

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |
| synthesis verb | `moot_synthesize` |

## Source corpus and artifact

Synthesis Payload is a MOOTx01-authored instrument over the frozen `lme-s`
questions and gold answers. It uses the same selected port's ready Form-2
`lme-s` artifact as Payload Economics. The lane does not generate a separate
source corpus or build a separate estate. The release corpus carries
`has_answer` turn annotations where evidence is identified.

Its MOOTx01-authored classification describes ownership of the method, not
ownership of the source data.

## Method

The digest is requested from the store per question and scored in place of a
retrieved payload. It is scored by the same mechanical procedure as the other
three shapes: the question's gold answer is matched against the digest by
normalized substring. Explicit evidence text is matched only when the input
provides it.

The arm is additive. It runs alongside whichever retrieval arm is configured
and does not alter retrieval scoring. The retrieval figures from a run with
this arm enabled are the same figures that run would produce without it.

The synthesis verb is called directly and does not pass through the retrieval
path. What the store selects to summarise, and how much of the database it
considers, is the store's own behaviour and is bounded by `--synthesize-limit`.
That bound is recorded in the report.

Scoring is deterministic; no model grades the digest in this lane.

## Metrics

The figures from payload economics, computed identically:

**Tokens read** is the mean digest size, estimated as
`(utf8_byte_count + 3) / 4`.

**Answer presence rate** is the fraction of questions whose digest contains
the dataset's gold answer under normalized substring matching. It is always
reported for the release corpus.

**Answer presence per 1000 tokens** is answer presence rate divided by mean
tokens and multiplied by 1000. It is reported whenever mean tokens are
nonzero.

**Evidence hit rate** uses the text of `has_answer`-annotated turns and only
annotated questions in its denominator. **Evidence hits per 1000 tokens**
scales that rate by mean tokens. A full-coverage release report contains both
fields. A bounded slice with no annotated question may omit them; omission
means unavailable, never zero.

Results are reported beside the three retrieved-payload shapes. Hit@k and MRR
do not apply to the synthesis arm because the digest carries no ranked IDs.

## What is recorded

The report carries `mean_tokens`, `answer_presence_rate`,
`answer_presence_per_1k_tokens` when mean tokens are nonzero, and the value of
`--synthesize-limit`. A full-coverage release report also carries
`evidence_hit_rate` and `evidence_hits_per_1k_tokens`; a bounded slice may omit
them only when it contains no annotated question. Every report carries the
provenance fields required by `../BENCHMARK_METHOD.md` §6.

## Invocation

```sh
make smoke-measure-synthesis-payload [PORT=swift|rust]
make measure-synthesis-payload [PORT=swift|rust] [LIMIT=<n>]
```

Run these commands from `benchmarks/`. The wide target requires the selected
port's smoke stamp. Both targets also require the LongMemEval fetch and seed
projection and the selected port's ready Form-2 `lme-s` artifact, prepared as
specified in `../BENCHMARK_RUN_BOOK.md` §9. The artifact dependency is fixed;
the targets do not accept `SCALE`.

Payload economics is defined in
[payload-economics.md](payload-economics.md).
