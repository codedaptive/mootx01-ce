---
title: Benchmark Method
release: "1.1"
version: v0.2
date: 2026-09-09
description: Metric definitions, the settled-database requirement, required report fields, and how each metric relates to its source paper.
changelog:
  - version: v0.2
    date: 2026-09-09
    description: "Remove stale adornment-rows/miner reference from payload arms section (schema 19 dropped adornment_minters)."
  - version: v0.1
    date: 2026-09-04
    description: "Initial method document."
---

# Benchmark Method

This document defines what is measured and what every report must carry. It is
the referent for the `protocol_version` field.

Procedure for running the tests is in `BENCHMARK_RUN_BOOK.md`. Individual test
definitions are under `benchmarks/`.

---

## 1. Terminology

The system under test uses its own nouns. This document uses standard database
terms. The mapping is given once here.

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |
| prebuilt database | estate artifact |

---

## 2. Isolation

External benchmarks support the three storage scales defined in
`BENCHMARK_RUN_BOOK.md` §1.2. At `unit` scale, each test unit is measured
against its own estate and rows from one unit are never visible to another.
This is the published-protocol storage shape.

At `bench-aggregate` and `complete-aggregate` scales, units share an estate as
defined in `BENCHMARK_ESTATES.md`. The report records the scale, and aggregate
figures are never combined with `unit` figures. Internal benchmarks use the
single estate shape defined by their benchmark specification.

---

## 3. Storage backends

Each benchmark runs against one of two backends.

**On-disk** is SQLite on the filesystem. Latency figures are taken from this
backend.

**In-memory** is the InMemory backend behind the same storage interface. It
performs no filesystem I/O in the measured path. Retrieval quality figures may
be taken from this backend.

---

## 4. Latency metrics

Four latencies are defined. A report of latency carries all four.

**Read latency** is the client-side duration of one search query, reported as
p50 and p95.

**Write latency** is the client-side duration until the write is acknowledged.
It ends at the acknowledgement and excludes the indexing work that follows.

**Ingest latency** is the interval from write acknowledgement to the background
indexing queue reaching idle for that row, taken from the indexing completion
marker in the audit log.

**Cycle latency** is the interval until the written row is retrievable,
reported in four tiers:

| Tier | Retrievable when |
|---|---|
| Keyword and structured | The row commits. |
| Vector, known vocabulary | That row's own indexing completes. |
| Vector, new vocabulary | A full rebuild of the vector index has run. |
| Associative | The association pass covering that row completes. |

---

## 5. Settled-database requirement

No measurement runs against an unsettled database. The sequence is:

1. Import the data set.
2. Wait for the background indexing queue to reach idle.
3. Run the association pass with full coverage.
4. Rebuild the vector index over the whole table.
5. Snapshot.

Measurement begins from the snapshot. A run that omits any step is unsettled.
A figure from an unsettled database is labelled as such in the report.

A prebuilt database is settled by definition: the sequence above runs before
the snapshot is taken, and a restored database is not re-settled.

---

## 6. Required report fields

Every report carries an identity block:

| Field | Content |
|---|---|
| `mootx01_binary_sha256` | SHA-256 digest of the binary under test. This is the citable binary identity. |
| `mootx01_version` | Version string reported by that binary. |
| `protocol_version` | Version of this document governing the run. |

Timing files additionally carry the full run environment, including the
machine profile and load state, because latency figures are properties of a
machine. Accuracy files carry the identity block only.

Row count at measurement time is carried per row as `docs_ingested` or
`turns_ingested`.

---

## 7. Metrics against their source papers

Each benchmark family carries two lanes. The spec lane implements the source
paper's documented evaluation protocol verbatim; its definitions are the
protocol extractions under `specs/`. The legacy lane reports a deterministic
transformation of the same run.

The legacy metrics are the stated alternative for an operator to whom an LLM
judge or an answering model is cost prohibitive. They call no external model.
A fixed run produces the same number every time, and the number is comparable
across releases. The legacy lane is therefore the regression guard at scale;
the spec lane is the published-protocol measurement.

The relation differs per family. Where the official metric requires a judge
or an answering model, the legacy metric is the judge-free substitute. Where
the official metric is already deterministic, the legacy metric is an
additional and stricter guard rather than a substitute.

### 7.1 MemBench

The documented MemBench protocol requires an answering model: it reads
recalled memory context through the paper's four-choice prompt and outputs a
letter, scored by exact equality. The `membench-spec` lane implements that
protocol. The legacy metrics below are the judge-free alternative.

Legacy retrieval accuracy scores key-evidence labels: the harness identifies
which turns contain evidence for the answer and scores whether those turns
appear in the top k results, reported as recall@k and MRR. It scores the
retrieval path directly and does not depend on answer generation, so it is
stable enough to compare across releases.

Legacy `multiple_choice_accuracy` scans the four options in letter order
against the returned payload text, selects the first that appears, and
compares that letter to the ground truth, with `multiple_choice_correct` per
item. This figure is a payload-text heuristic, and it is not a substitute
for the spec lane's answered accuracy.

### 7.2 LongMemEval

The documented protocol grades generated answers with an external judge
model; the `lme-spec` lane implements it, including abstention questions.
The legacy metric is session-level retrieval accuracy against the evidence
labels, reported as recall@k and MRR. It is the judge-free substitute: zero
model calls over 500 questions per run, repeatable to the digit.

### 7.3 LoCoMo

The documented protocol is already deterministic (stemmed token F1 over
generated answers, no judge); the `locomo-spec` lane implements it, though
its answer-generation step still requires an answer path. The legacy metric
is turn-level evidence retrieval, reported as recall@k and MRR. It is not a
substitute here; it is a stricter additional guard, since retrieving the
labelled turn is a harder target than any answer-level score.

### 7.4 LMEB

Deterministic in both lanes. The legacy lane reports recall@k, MRR, nDCG@10
and MAP@10; the `lmeb-spec` lane reports the paper's full metric grid at
k = 1, 5, 10, 25, 50 with capped recall and instruction settings. The
`convomem-spec` lane carries the data set's judged-QA protocol, which
requires a judge and has no deterministic substitute beyond the retrieval
metrics above.

## How a judged lane runs

Three parties are involved: a memory system, an answering model, and a grader. The published protocols grade the answering model's text. The memory system holds the history and serves the evidence. It never answers.

**Worked example.** The question is from LongMemEval: "What was the page count of the two novels I finished in January and March?" The gold answer is 856.

**Step 1: the recording.** The harness starts the memory system on that question's estate. It calls `moot_memory_search` with the question as the query. It then calls `moot_memory_get` on each hit at the chosen hydration tier. For each question it writes one line. The line carries the question, the hit IDs, and the returned texts. It also carries the gold answer for the grader. The memory system does exactly what it does for any caller. The harness saves the reply instead of using it live.

**Step 2: the reader.** Later, with the memory system stopped, the harness runs one command per recorded line. The command receives the question and the returned texts. It prints an answer, for example "856 pages in total". That command is the answering model of the protocol. It can be a local model or a frontier model. The harness saves the printed answer and names the model in the record.

**Step 3: the grader.** The judge receives the question, the gold answer, and the printed answer. It returns yes or no. MemBench uses exact letter match. LoCoMo uses token F1.

**Why it is recorded.** Readers can be swapped without re-running the memory system. Two runs over one recording give the same answer. The reader never sees anything the memory system did not return.

**The guard.** Before the reader runs, the harness checks whether the gold answer text appears in the returned texts. It reports that count beside the score. A yes the texts could not support is a reader guess, and the count shows it.

**Payload arms.** The same recording can be scored against different activation arms. A with-activation arm and a without arm read identical retrieval hits; only the context supplied to the reader differs.

---

## 8. Run shapes and file shapes

The suite has three run shapes. The file a run produces is determined by
its shape.

### 8.1 Accuracy

An accuracy run executes a lane's full data set against prebuilt databases
restored from the artifact store. Parallel and serial execution produce the
same accuracy figures. An accuracy report contains the lane's accuracy
figures, its per-unit records, and an identity block:
`mootx01_binary_sha256`, `mootx01_version`, `protocol_version`. It contains
no timing columns. Accuracy runs use the plaintext posture; the harness
accepts the encrypted posture only in the timing lane.

### 8.2 Posture equivalence

The serial timing lane runs a posture-equivalence loop: a fixed seeded
sample of 200 rows and 50 probe queries is ingested, converted to an
encrypted twin of the same database, and probed in both postures. The
ranked results are compared exactly. The comparison is written as its own
artifact, `posture-equivalence-<arm>-<serial>.json`, containing the probes
compared, the identical count, the divergent count, and the ranked lists of
any divergent probe. Encrypted and unencrypted execution produce the same
accuracy results.

### 8.3 Timing

Timing figures come from the serial timing lane. The lane runs both
postures and emits one timing file per posture carrying the four latency
metrics of §4 and the full run environment. The timing lane accepts no
parallel option.

---

## 9. Dataset coverage

A figure carries the scope it was measured over. A run that covers part of a
data set and reports the data set's name overstates itself, and nothing in the
numbers shows it — this is the one omission that cannot be detected downstream,
so it is stated per benchmark here and recorded in every report.

Every set below is run WHOLE. Where a set is divided into parts, all parts are
built and measured; where the harness accepts a selector that would narrow the
run, the selector's full value is pinned in the Makefile rather than left to a
default.

| Data set | Division | Covered | Units built |
|---|---|---|---|
| LoCoMo | 10 conversations | all 10 | 10 |
| LongMemEval | 500 questions, variant `s` | all 500 | 500 |
| LMEB / ConvoMem | 6 evidence categories | all 6 | 5,867 |
| MemBench | 2 agent perspectives | both | 20,137 |

LMEB's 5,867 is the sum of its six categories: abstention 982, assistant_facts
765, changing 1,434, implicit_connection 990, preference 356, user 1,340.
MemBench's 20,137 is FirstAgent 7,000 plus ThirdAgent 13,137.

LongMemEval ships the same 500 questions in two haystack configurations,
`s` and `m`. Release 1.1 measures the `s` configuration, named `lme-s` in the
operator interface. It contains all 500 questions. A report names the variant
and never presents an `lme-s` figure as an `m` result.

MemBench's two perspectives are different task shapes rather than two views of
one shape, and are reported separately. FirstAgent items are user/assistant
conversations across multiple sessions. ThirdAgent items are flat streams of
single observed statements about third parties, each carrying an explicit
relation/attribute/value triple. A combined figure would average two different
tasks; the triples are also deliberately not ingested alongside the statement
text, since supplying the answer structure would measure parsing rather than
recall.

---

## 10. Instrument integrity

### Tool-level error results

A tool-level error result (`isError: true` in the MCP `tools/call` response)
is a hard run error. It is never converted into an empty result or an all-zero
measurement row.

The shared retrieval seam applies this rule to every lane. A failure stops the
run and records the unit, tool, and error text. JSON-RPC transport failures are
handled by the same fail-closed rule.

---

## 11. Expand-verify scoreboard metrics

The expand-verify scoreboard adds three families of metrics to the lmeb-spec
lane. They appear in the report alongside the existing §A1 metric grid.

### Pool guarantee

Pool guarantee is the fraction of questions where the returned list contains at
least one gold document. A question counts as a guarantee hit when
`pool_gold_hit == 1`. Pool guarantee measures whether the recall stage surfaces
any relevant material at all, before the precision metrics at each k cutoff.

### Short-query metrics

A question is classified as short when its content-term count falls below the
`--short-query-terms` threshold (default 4). Content terms are lowercase
alphanumeric tokens after removing the shared EN stopword list. Short-query
metrics report nDCG@10, Recall@10, and pool guarantee separately for this
subset. The subset reveals whether short queries are harder to satisfy than
longer queries, which is a known retrieval signal.

### Pool gold recall

Pool gold recall is the fraction of gold documents that appear anywhere in the
returned list, computed across all healthy questions in the leg. It differs
from pool guarantee in that guarantee counts questions while pool gold recall
counts individual gold documents. A high guarantee with a lower pool gold
recall indicates that some questions have multiple gold documents where only
one is returned.
