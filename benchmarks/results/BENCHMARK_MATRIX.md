---
title: Storage Matrix Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing purpose, posture controls, metrics, reproduction, and evidence contract for the Storage Matrix benchmark.
---

# Storage Matrix

## What it measures

The Storage Matrix measures retrieval across storage postures while holding the
logical data constant. Release 1.1 compares plaintext and encrypted on-disk
cells. The conversion uses the product's estate-encryption migration path and
preserves primary keys, fingerprints, vectors, tables, indexes, and triggers.

Before a converted cell is probed, row counts must match and the integrity
check must pass. The same deterministic probe set runs against both cells.
Ranked identifier lists are compared exactly. The report records conversion
failures, probe failures, and every divergent ranked list.

One source database is resident at a time. The scratch estate and queue
database share a posture and are retired before the next cell. The complete
design, release gates, and record fields are in
`../benchmarks/posture-matrix.md`.

## Run procedure

Run from `benchmarks/`:

```sh
make seeds
make smoke-measure-matrix PORT=<swift|rust>
make measure-matrix PORT=<swift|rust> [LIMIT=<n>]
```

The wide target builds or restores its fixed matrix corpus and requires the
selected port's smoke stamp. `LIMIT` is a bounded diagnostic control; a limited
report is never labeled as complete matrix coverage.

## Evidence and publication

The report records the posture, conversion and integrity outcomes, probe set,
ranked identifiers, divergence details, binary identity, protocol version,
estate schema, port, and coverage. Copy only human-accepted figures from
`../RESULTS_RECORD.md` into a public result register.
