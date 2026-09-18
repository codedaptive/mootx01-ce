---
title: MOOTx01-Authored Benchmark Rationale
release: "1.1"
date: 2026-08-28
description: Benchmarks in this suite that have no public equivalent, what each measures, and the structural reason the public data sets cannot measure it.
---

# MOOTx01-Authored Benchmarks

The MOOTx01-authored benchmarks listed in `BENCHMARK_RUN_BOOK.md` §1.1 are
defined here. Each
measures a property of a long-term memory store that the public data sets in
this suite do not measure.

The reason is structural. The published protocols define independent
question-and-haystack evaluations and do not exercise a memory store through a
changing lifecycle. The suite's aggregate storage scales increase distractor
scope, but they do not add supersession events, multi-step agent journeys,
posture comparisons, or payload-cost experiments. A metric that ends at the
ranked list also cannot state what the ranked list costs an answering model to
read.

Each benchmark below states what it measures, what the public data sets do not
measure, and where its definition lives. The designs are open and are run the
same way as the public benchmarks.

---

## 1. Supersession

**Measures** whether the current version of a changed fact outranks the
versions it replaced, and whether pairs of claims that conflict are surfaced.

**Not measured publicly.** A fresh database per question holds one version of
every fact. Nothing has been superseded, so nothing can be tested for
supersession. Recency signals computed from history are all zero on a database
with no history.

**Definition:** [benchmarks/supersession.md](benchmarks/supersession.md).
**Subcommand:** `supersession`.

---

## 2. Encryption cost

**Measures** what encryption at rest costs in query latency, and whether it
changes retrieval quality.

**Not measured publicly.** The public data sets are run against plaintext
storage. Encryption is a deployment property of the store rather than a
property of the data set, so no data set carries it.

**Method.** Run the same benchmark twice on the same data at the same seed, one
pass plaintext and one encrypted, and compare retrieval scores and median query
latency across the pair.

**Definition:** [benchmarks/posture-matrix.md](benchmarks/posture-matrix.md),
which places the encryption setting alongside the storage backend as a second
axis.
**Subcommand:** `matrix`.

---

## 3. Payload economics

**Measures** how much text each payload shape renders and whether that payload
mechanically carries the question's gold answer.

**Not measured publicly.** Public retrieval metrics end at the ranked list.
They score whether the correct row was returned and stop there. The cost of
reading what was returned, and whether the returned text carries the gold
answer, falls outside the metric.

**Method.** Hold the questions and retrieval results fixed. Vary only the
payload shape: short previews of each hit, the full retrieved content, and a
compressed form. Record mean tokens, normalized-substring gold-answer
presence, and answer presence per 1000 tokens for each shape. Retrieval arms
also report hit@k and MRR. No answering model or judge participates.

**Definition:** [benchmarks/payload-economics.md](benchmarks/payload-economics.md).
**Subcommand:** arms of `longmemeval`. The report carries `exact mean tokens`,
`dense mean tokens` and their ratio.

This MOOTx01-authored instrument uses the frozen `lme-s` questions and gold
answers, its `has_answer` turn annotations, and the selected port's Form-2
`lme-s` artifact. Evidence metrics use annotated questions only; a question
without an annotation is recorded separately and is not treated as a miss.

---

## 4. Synthesis payload

**Measures** the same token and gold-answer-presence figures as payload
economics for a fourth payload shape: a digest with citations that the store
generates from its own retrieval.

**Not measured publicly.** It depends on the store producing the payload rather
than returning rows, which no public data set is shaped to score.

**Method.** Add the generated digest as a fourth shape and apply the same
deterministic token estimate and normalized-substring gold-answer check as the
other three. The digest has no ranked IDs, so hit@k and MRR do not apply.

**Definition:** [benchmarks/synthesis-payload.md](benchmarks/synthesis-payload.md).
**Subcommand:** `longmemeval --synthesize-arm`.

This MOOTx01-authored instrument uses the same frozen `lme-s` questions, gold
answers, `has_answer` annotations, and Form-2 artifact as Payload Economics.

---

## 5. Journey cost

**Measures** the work an agent performs to reach a correct answer across a
sequence of steps.

**Not measured publicly.** One question against one fresh database is a single
step. Multi-step cost has no place to appear.

**Definition:** [benchmarks/journey.md](benchmarks/journey.md).
**Subcommand:** `journey`.

---

## 6. Cycle latency

**Measures** the interval between writing a row and that row becoming
retrievable, in four tiers.

**Not measured publicly.** Public benchmarks measure a settled store. Write
latency alone ends at the acknowledgement and says nothing about when the
written row can be found, which for a store with asynchronous indexing is a
different time for each retrieval path.

**Definition:** [benchmarks/timing.md](benchmarks/timing.md) §What is measured.
**Subcommand:** `timing`.

---

## 7. Adversarial distractor classes

**Measures** retrieval against distractors planted in five named classes, one
class at a time.

**Not measured publicly.** Public data sets contain whatever distractors their
source material happened to contain. A failure cannot be attributed to a class
because the classes are not labelled.

**Definition:** [benchmarks/gauntlet.md](benchmarks/gauntlet.md).
**Subcommand:** `gauntlet`, `gauntlet-corpus`.

---

## 8. Deterministic alternatives

**Measures** repeatable retrieval outcomes for each external benchmark without
an answering model or judge in the scoring path.

**Not measured by every published protocol.** LongMemEval and ConvoMem require
model-based answer grading, and MemBench requires an answering model. The
deterministic lanes measure retrieval against labeled evidence so release
movement can be tested without model cost or judge variance. For LoCoMo and
LMEB, whose official scoring includes deterministic components, the authored
lane is an additional retrieval guard rather than a replacement.

**Definition:**
[benchmarks/deterministic-alternatives.md](benchmarks/deterministic-alternatives.md).
**Subcommand:** `deterministic-alternatives`.

---

## Fairness constraint

Supersession, journey and gauntlet generate their own data sets. Each is
constrained so that every scored behaviour is achievable in principle by any
competent keyword and vector system that tracks recency. Nothing is scored that
requires a feature specific to the system under test.
