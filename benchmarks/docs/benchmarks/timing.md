---
title: Timing Benchmark Definition
release: "1.1"
date: 2026-08-28
description: Read, write, ingest and cycle latency measured on a single database at fixed row count, with and without encryption at rest.
---

# Timing Benchmark

## Purpose

This test measures four latencies against a database holding a fixed number of
rows. It reports them twice: once for a plaintext database and once for the
same database encrypted at rest.

The accuracy benchmarks do not produce these figures. They restore a prebuilt
database and query it, so they measure the read path only.

## Terminology

The system under test uses its own nouns. This document uses standard database
terms throughout. The mapping is given once here.

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |
| search query | `moot_memory_search` |
| vector index rebuild | `moot_reindex` |
| association pass | `moot_dream` |
| background indexing queue | encode queue |

## What is measured

**Read latency** is the client-side duration of one search query, reported as
p50 and p95 over the query set.

**Write latency** is the client-side duration until the write is acknowledged.
It ends at the acknowledgement. It does not include the indexing work that
follows.

**Ingest latency** is the interval from write acknowledgement to the background
indexing queue reaching idle for that row. It is taken from the indexing
completion marker in the audit log rather than from client-side polling.

**Cycle latency** is the interval until the written row is retrievable. It is
reported in four tiers, because retrievability arrives in stages.

The first tier is keyword and structured lookup, available as soon as the row
commits. The second is vector search for terms already present in the index
vocabulary, available when that row's own indexing completes. The third is
vector search for terms new to the vocabulary, which requires a full rebuild of
the vector index over the whole table. The fourth is associative lookup,
available once the background association pass covering that row completes.

All four are required.

## Database under test

One database holds a fixed row count, written as S and recorded in the report.
It is built once per encryption setting and copied before any measurement.

### The landscape

The S rows are the landscape. They come from one of two sources, and the report
records which.

**Corpus.** Rows are taken from a published data set in that data set's own
order: questions in file order, each question's sessions in order, each
session's turns in order. No shuffle. A row is filed as `role: content`, which
is how the conversational benchmarks file a turn. Taking a deterministic prefix
means the landscape at 2,000 rows is the first 2,000 rows of the one at 10,000,
so a curve across sizes is a curve over one data set rather than three
unrelated samples. Where a requested row count exceeds the data set, the data
set cycles and the repeat number is folded into each row's identity, so every
row keeps a distinct id.

Row identity is derived from the source turn rather than drawn from a random
sequence. The same turn always lands under the same id, on both ports and
across runs, so a row can be found again in a rebuilt landscape.

Event times are the lane's own monotonic sequence rather than the data set's.
The landscape's recency distribution is then a function of the row count under
test rather than of which data set supplied the text.

**Synthetic.** One templated sentence per row with an index and seed
substituted in. It needs no data set, so the lane runs anywhere. Every row has
the same length and vocabulary, which is invisible in read and write latency
and decisive in the third cycle tier: a template introduces almost no terms new
to the index after the first row.

A synthetic landscape exists only inside this harness. A corpus landscape can
be rebuilt by anyone holding the data set.

### The recipe

Every report carries the recipe under `landscape`:

| Field | Content |
|---|---|
| `source` | `corpus` or `synthetic` |
| `corpus` | Data set name. Absent when synthetic. |
| `corpus_variant` | Data set variant. Absent when synthetic. |
| `corpus_licence` | Licence a reproducing team is bound by. Absent when synthetic. |
| `rows` | Landscape row count, excluding measured writes. |
| `seed` | Seed governing selection order. |

To rebuild a landscape from a published report: fetch the named data set at the
named variant, ingest the first `rows` rows in the order above, and the
resulting database is the one the figures were taken against.

The default data set is LongMemEval, under CC BY 4.0. Of the data sets this
harness fetches, LongMemEval and LMEB carry licences that permit an outside
team to reproduce a published landscape; LoCoMo is CC BY-NC.

Both ports produce identical landscapes for a given recipe. Three row
identities are pinned as literals in each port's tests, so a change to either
port's derivation fails the other's suite.

Every measured write runs against a fresh copy of that database. Writing
repeatedly into one database would place the second measurement at S+1 rows,
the third at S+2, and the reported row count would describe only the first
measurement. Restoring a copy per measurement holds every figure at exactly S.

The S rows already present are unmeasured background. They are built ahead of
the measured run by `landscape-build`, which may run on a machine under load.
Only the measured window requires an idle machine.

`landscape-build` writes one stored landscape per row count in a single pass,
so the 10,000-row landscape is the 2,000-row landscape with 8,000 more rows
added. Each stored landscape carries the recipe that produced it. A measured
run restores the stored landscape for each row count rather than ingesting one,
which is what holds every figure at exactly S: a run that grew one database
through the row counts would reach the second at S plus the writes measured at
the first.

A stored landscape is selected by its recipe, not by its row count alone. A run
naming a recipe with no stored landscape at some requested row count stops
before measuring anything rather than after spending part of the idle window.

## Encryption at rest

The test runs twice. The first pass uses a plaintext database. The second uses
the same database encrypted with SQLCipher under a key held in process memory
for the life of the run. Neither pass reads or writes the system keychain.

The two passes run one after the other and never overlap.

The difference between the two passes is a reported figure in its own right.

## What is recorded

Each report carries the row count S, the query count, the four latencies with
their tiers, and the encryption setting. It carries the provenance fields
required by `../BENCHMARK_METHOD.md` §6: the SHA-256 digest of the binary
under test, the declared machine state, the measured one-minute load average
with the logical CPU count, and the protocol version.

## Invocation

Build the landscapes first. This step is not measured and may run on a loaded
machine.

```
mcp-benchmarker landscape-build --cache-dir <dir> --sizes 2000,10000,100000 \
                       --landscape corpus --landscape-data-dir <data> \
                       [--landscape-corpus longmemeval] [--landscape-variant s]
```

Then measure on an idle machine:

```sh
make smoke-measure-timing [PORT=swift|rust]
make measure-timing [PORT=swift|rust] [LIMIT=<n>]
```

The lane measures both encryption settings and records each posture
separately. Run these commands from `benchmarks/`. The wide target requires the
selected port's smoke stamp.

Row counts are selected with `--sizes`. Running at more than one row count
produces a scaling curve: read latency across sizes gives the point where a
linear scan is overtaken by the graph index, write latency gives insert cost
growth, and cycle latency gives the cost growth of the association pass.
