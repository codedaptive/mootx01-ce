---
title: Benchmark Protocol
release: "1.1"
date: 2026-08-28
description: Operating rules for the benchmark program, including measurement conditions, prebuilt database identity, and release handling.
---

# Benchmark Protocol

This document states how the benchmark program is operated.

What is measured, and what a report must carry, is in `BENCHMARK_METHOD.md`.
That document is not repeated here.

---

## 1. Operating rules

Three rules govern when the tools are run.

### 1.1 Measurement

Used when producing numbers for a report or comparison.

- Run on a machine with no competing load during the timed window.
- Run the suite once. Do not repeat any part of a measurement run.
- Do not publish run counts.
- Retrieval quality passes are insensitive to machine load and may run on a
  loaded machine. Latency passes may not.

### 1.2 Creation

Used when writing or changing a benchmark or its configuration.

- At most 10 measurement loops.
- At most 5 minutes of total run time.
- At most 3 repeats of any single measurement.
- Run only the benchmark that changed. Do not trigger a suite run.

### 1.3 Repair

Used when debugging a benchmark producing wrong results.

- Run only that benchmark.
- Use the smallest part of it that isolates the problem.
- Do not trigger a suite run.

---

## 2. Prebuilt database keying

A prebuilt database is keyed by the run configuration that produced it:
benchmark, variant, seed, indexing barrier, encryption setting, granularity,
preference extraction, and seed path. The unit identifier is the leaf.

The binary fingerprint is not part of the key. It invalidated every database on
every product build, including builds that could not change stored bytes.
Staleness is detected instead: each database carries a provenance manifest,
validated on open, and a mismatch is a hard error.

The schema version is NOT in the key. It is recorded in each artifact's
provenance manifest and checked when the artifact is opened, where a mismatch
is a hard error.

The estate schema for release 1.1 is **1.1**. Three values must agree:

- new estates write schema 1.1;
- the harness expects schema 1.1; and
- every restored artifact records schema 1.1 in its provenance manifest.

An artifact with a different schema is unusable for the run. The pre-run scan
compares every artifact manifest with the harness expectation and refuses the
run before measurement if any value differs.

Every lane report carries `estate_schema_version`. The results record copies
that field from the report; operators do not infer or enter it from memory.

---

## 3. Release loop

1. Fix the defect, release.
2. Re-benchmark.
3. If a regression appears, fix it and release again.

A release that does not change schema reuses its prebuilt databases, so both
runs measure the same data and the difference is attributable to the code.

A release that changes schema invalidates them. The new run has no
same-substrate predecessor and is compared against saved historical figures.

Release gates for the storage matrix are in `benchmarks/posture-matrix.md`.

---

## 4. Quality control: deterministic replay

Before a run's figures are used, determinism must have been proved: the
benchmark is replayed and its outcome fields are compared across runs.

This is done at ARTIFACT BUILD TIME, not during a measured pass. It needs no
quiet machine, and a benchmark window is the scarcest resource in this program
— spending one to discover the pipeline is nondeterministic wastes exactly what
the check exists to protect. The build records a receipt; the measured run
reads it.

`mcp-benchmarker replay` runs the supersession benchmark two or more times,
each on a freshly provisioned database, and compares the fields whose values
are required to be deterministic. It prints a per-field table of MATCH or
DRIFT and exits non-zero on any drift.

A field that drifts between two runs of the same seed and the same binary is
not measuring the system. Figures from a benchmark whose replay shows drift are
not used until the drift is resolved.

Replay compares runs of the same encryption setting. It does not compare one
setting against another.

```
mcp-benchmarker replay --mootx01-binary <path> --runs <n> \
                       --estate-mode unencrypted|encrypted \
                       [--seed N] [--entities N] [--versions N] \
                       [--contradictions N] [--k N]
```

All seed and shape flags carry the same meaning as the supersession benchmark.

---

## 5. Records

Each run writes reports beneath `$BENCH_WORK_ROOT/results`. Accepted headline
figures are published in the applicable page under `results/` with the run
date, product version, estate schema version, benchmark coverage, headline
metric, run identifier, and source-report identity. The report is the source
for every published cell. A run does not publish or alter a result page.
