---
title: Benchmark Seed-File Usage
version: 1.0.0
status: active
date: 2026-08-09
description: How the benchmark harness uses seed-file schema v1 — pointer to the canonical VaultKit format definition plus benchmark-specific usage.
relates_to:
  - packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md (canonical schema definition)
  - benchmarks/lanes/README.md (run protocol v3)
---

# Benchmark Seed-File Usage

## The schema lives in VaultKit

The seed-file format (schema v1) is defined once, in
[`packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md`](../../packages/kits/VaultKit/docs/JSON_IMPORT_FORMAT.md).
That document is the authority: top-level keys, record fields, fact and
tunnel rules, validation contract, ceilings, and the failure contract.
This document does not restate any of it. If anything here appears to
disagree with the VaultKit document, the VaultKit document wins.

This document covers only what the benchmark harness adds on top: how
lanes emit and load seed files, the `--dump-seed` symmetry contract, and
the third-party reproduction flow.

## How lanes use seed files (run protocol v3)

Every lane builds its test data as an in-memory list of seed records,
serializes it to a schema-v1 seed file, and loads the file with one
`moot_json_import` call. The encode barrier, the `moot_dream` pass, and
the queries follow. Seeding is setup, not measurement. Per-record live
capture survives only as the optional slow lane behind `--seed-path
live`, kept for periodic equivalence re-proving against the bulk path.

Both harness ports emit seed files through one shared emitter
(`Sources/mcp-benchmarker/SeedExport.swift`, `rust/src/seed_export.rs`).
The emitters are pinned byte-identical by the shared conformance vectors
in `benchmarks/conformance/seed_export_vectors.json`: same seed, same
bytes, on both ports.

## `--dump-seed` symmetry

Lanes that generate their own test data accept `--dump-seed <path>`. The
flag writes the lane's seed file and exits without touching any store.

The symmetry contract: **the dumped bytes are exactly the bytes the lane
imports**. Dump output and importer input go through the same emitter,
so there is no second serialization path that could drift. The dump is
sorted-key, LF-terminated JSON with a stable byte layout, which makes
seed files diffable across runs, ports, and machines.

```bash
mcp-benchmarker supersession --seed 20260725 --dump-seed seed.json
mcp-benchmarker journey --seed 20260725 --dump-seed seed.json
```

## Third-party reproduction

The seed file is the interchange artifact. To run a lane's test data
against another memory system, no harness code is needed:

1. Dump the seed file for the lane and seed of interest (`--dump-seed`).
2. Parse it with any JSON tooling. The schema is rigid and documented in
   the VaultKit format definition; `records` order is ingestion order.
3. Ingest the records into the system under test in file order,
   preserving each record's `event_time`.
4. Query and score per the lane's method doc (`benchmarks/lanes/`).

The audit receipt of a `moot_json_import` run carries `seedSha256`, the
SHA-256 of the imported bytes. A published run can therefore be traced
to the exact seed file that built its store, and an independent
reproduction can verify it imported the same bytes.
