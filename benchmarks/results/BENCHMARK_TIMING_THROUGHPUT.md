---
title: Timing and Throughput Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing latency, throughput, environment, reproduction, and evidence contract for the Timing benchmark.
---

# Timing and Throughput

## What it measures

The timing lane measures four latency families on a fixed estate:

- read latency, reported as p50 and p95;
- write acknowledgement latency;
- ingest latency from acknowledgement to indexing idle; and
- cycle latency for keyword/structured, vector-known-vocabulary,
  vector-new-vocabulary, and associative retrieval.

The lane measures plaintext and encrypted postures separately. Timing runs are
serial and require a quiet machine. Throughput is a separate concurrent-load
shape reported with its request concurrency, row count, and operation mix; it
is never inferred from single-request latency.

The exact landscape recipe, snapshot procedure, posture rules, and record
fields are in `../benchmarks/timing.md` and `../BENCHMARK_METHOD.md` §4 and §8.

## Run procedure

Run from `benchmarks/`:

```sh
make seeds
make smoke-measure-timing PORT=<swift|rust>
make measure-timing PORT=<swift|rust> [LIMIT=<n>]
```

Run the wide measurement only after the machine-load gate is satisfied. The
selected port's smoke stamp is required. `LIMIT` is recorded as limited
coverage.

## Evidence and publication

Each timing file records the full machine profile, load state, row count,
posture, sample count, latency definitions, binary identity, protocol version,
estate schema, and port. A throughput file additionally records concurrency
and operation mix. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
