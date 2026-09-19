---
title: Supersession Benchmark Detail
release: "1.1"
date: 2026-08-28
description: Public-facing purpose, construction, metrics, reproduction, and evidence contract for the Supersession benchmark.
---

# Supersession

## What it measures

Supersession measures whether the current version of a changed fact outranks
the versions it replaced in an estate that retains the full change history. It
also measures whether planted conflicting claims are surfaced without firing
on non-conflicting decoy pairs.

The deterministic corpus contains version chains, contradiction pairs,
divergence pairs, and decoys. The benchmark reports:

- current-version rank per entity;
- positions of superseded versions;
- current-over-superseded wins;
- contradiction and divergence detection by tier; and
- decoy firing.

The complete construction and scoring contract is in
`../benchmarks/supersession.md`. No metric requires a MOOTx01-specific feature;
another system can implement the same corpus and scoring rules.

## Run procedure

Run from `benchmarks/`:

```sh
make seeds
make smoke-measure-supersession PORT=<swift|rust>
make measure-supersession PORT=<swift|rust> [LIMIT=<n>]
```

`make seeds` fixes the generated corpus. The wide target requires the selected
port's smoke stamp. `LIMIT` produces a bounded diagnostic result and must be
recorded as limited coverage.

## Evidence and publication

The report carries the seed, corpus shape, per-entity and per-pair outcomes,
binary identity, protocol version, estate schema, port, and coverage.
Deterministic replay is an artifact-build gate. Copy only human-accepted
figures from `../RESULTS_RECORD.md` into a public result register.
