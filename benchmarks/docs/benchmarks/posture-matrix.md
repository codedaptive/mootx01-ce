---
title: Storage Matrix Definition
release: "1.1"
date: 2026-08-28
description: Retrieval measured across encryption at rest and storage backend, holding the data byte-identical, one database at a time.
---

# Storage Matrix

## Purpose

This test measures retrieval quality across storage configurations. The data is
held constant. The encryption setting varies.

The matrix is two cells per database: plaintext on disk, and encrypted at rest
on disk. The conversion between them is the product's own, through the shared
EstateEncryption library, and both ports of that library are held to one
another by `conformance/cross-port.sh`.

Retrieval metrics are those of the benchmark whose data set is being used.

An in-memory cell is not measured. The in-memory backend provisions a fresh
database and has no path that loads an existing one, and adding that path is a
change to a shipped kit whose only gain here is removing filesystem I/O from a
measurement that is not a latency measurement.

## Terminology

The system under test uses its own nouns. This document uses standard database
terms throughout. The mapping is given once here.

| This document | System under test |
|---|---|
| database | estate |
| row | drawer |
| prebuilt database | estate artifact |
| index rebuild | `moot_reindex` |
| association pass | `moot_dream` |

## Method

The data is held constant. Only the encryption setting and the storage backend
vary, so any difference between cells is attributable to storage rather than to
content.

Each prebuilt database from an existing set is processed alone and deleted
before the next begins. One database is resident at a time. Peak disk use is
two working copies of the largest single database rather than two copies of the
set.

### Per database

The database is copied out of the set to a working copy. That copy is the
plaintext cell and the source for the encrypted one.

The encrypted cell is produced by `EstateEncryptionMigrator`, the same code
path the product uses when it offers to encrypt a plaintext database during an
upgrade. The conversion is a physical copy through SQLCipher's
`sqlcipher_export()` over an attached encrypted database. It copies every
table, index and trigger at the row level. Primary keys, audit rows,
fingerprints and the Merkle rollup are preserved, and no re-indexing is
performed. The encrypted database therefore holds the same vectors as its
source, and any measured difference is the storage layer alone.

Conversion is verified before measurement. Row counts per table in the
converted database must equal those in the source, and the converted database
must pass an integrity check. A conversion failing either check is recorded as
a failure for that database and no measurement is taken from it.

Conversion is the expensive step and is paid once per database.

The plaintext cell is served and queried. The probe is corpus-free: a
deterministic stride sample of the database's own stored row ids is taken from
its manifest, each row is hydrated by id to recover its stored text, and that
text is used as the query. The figure recorded is how often a row's own id
comes back, and at what rank. It is a fixed probe applied identically to every
set, so a MemBench database and a LoCoMo database are measured the same way and
neither needs a scorer, a question file, or evidence labels.

The encrypted cell is served and queried by the same probe, so both cells in a
row are measurements of the same kind and are directly comparable.

Serving it requires handing the server the key the conversion used. The key is
written to a file inside the scratch directory, beside the converted databases,
and the server reads it from there. This is the mechanism the Rust
implementation uses for every database it opens. On the Apple leg it is
compiled in only when both binaries are built with `MOOTX01_HARNESS_KEYFILE`,
which the harness build sets and no release build defines. A release binary
ignores the file and cannot open a database converted by the harness; the
matrix stops with an error in that configuration rather than recording a cell
it did not serve.

No key is written to the system keychain on either cell. The key file is
removed with the scratch directory when the database is retired, and the
retirement check reports any key material that outlives it.

Conversion is verified before the cell is served, by the same checks the
product runs before it swaps: an integrity check, a comparison of every index,
trigger and view by name, a schema-complete table comparison, and the four
gated row counts. A database failing any check is recorded as a failure and no
measurement is taken from it.

Every database in the scratch directory is converted, not only the estate
database. The server opens the estate and the queue beside it under one
setting, and a plaintext queue beside an encrypted estate is not openable. The
queue is verified by structure rather than by the four gated row counts, whose
tables it does not contain.

The two ports of the conversion are held to one another separately, by
`packages/libs/EstateEncryption/conformance/cross-port.sh`. It converts one
source with both ports and compares the content digest of every table in each
output against the source, then opens each port's output in the other. It does
not compare bytes: SQLCipher writes a random salt at the head of page 1 and a
random IV per page, so two correct conversions of one source are never
byte-equal.

## Release gates

Versions are `A.B.C`. A feature release increments B. A minor release
increments C.

The matrix runs as a precondition to a feature release, `A.X.C`, together with
the cross-port conformance run over a sample of the set.

A minor release, `A.B.x`, runs the matrix as a regression check against the
previous release's figures.

## What is not measured here

Latency. Read, write, ingest and cycle timings are measured by the timing
benchmark, which uses a single database at a fixed row count. This test copies
and converts databases while it runs.

## What is recorded

Each cell yields one row: database identifier, encryption setting, backend, and
port. Both cells carry the probe count, the two self-recall figures, and the
count of probes whose ranked result list differs from the plaintext cell's. An
encrypted cell also carries the row count verified during conversion. Every row
carries the provenance fields required by `../BENCHMARK_METHOD.md` §6.

The divergence count is reported per cell rather than folded into the recall
figures. Two cells can return the same rows in a different order, which a
recall figure alone does not show.

Differences between cells are computed when the report is assembled. The run
records absolute values only.

## Invocation

```sh
make smoke-measure-matrix [PORT=swift|rust]
make measure-matrix [PORT=swift|rust] [LIMIT=<n>]
```

Run these commands from `benchmarks/`. The target builds or restores its fixed
matrix corpus and requires the selected port's smoke stamp.

## Set scope

The release target runs the complete fixed matrix. `LIMIT` is permitted for
bounded diagnostic runs and is recorded in the report. A limited report is not
filed as complete matrix coverage.
