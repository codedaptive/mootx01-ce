---
title: Accepted Results Page Schema
release: "1.1"
date: 2026-08-28
description: Required structure and evidence fields for a benchmark result page.
---

# Accepted Results Page Schema

A result page is created only after its run has passed the run book's coverage,
receipt, provenance, drift, and result-class gates. Values are copied from the
identified report or parameter sidecar; they are never estimated, averaged
across undeclared runs, or reconstructed from console output.

## Required run identity

Include one identity table containing:

| Field | Required source |
|---|---|
| Run identifier and UTC date | report and parameter sidecar |
| Binary SHA-256 and product version | parameter sidecar |
| Protocol and estate schema versions | report |
| Port and storage scale or run shape | report |
| Coverage and exclusions | report |
| Source report and sidecar paths or digests | release evidence |
| Machine profile and load state | timing sidecar, when applicable |
| Answer and judge model identities | model sidecars, when applicable |

## Required measurement content

State the benchmark surface, population, exclusions, metric definitions, and
the exact Make target and parameters used. Present only metrics named by the
surface's detail page in `RESULTS.md`. Keep retrieval, answer quality, latency,
throughput, payload efficiency, storage behavior, and substrate timing in
separate tables.

For payload measurements, report evaluated questions, questions carrying
evidence annotations, and `no_evidence` separately. For judged measurements,
report answer model, judge model, grading mode, panel agreement, and transcript
identity. For timing, report the fixed landscape and machine/load profile.

## Required acceptance statement

Close with the completed gate evidence: deterministic replay receipt, store
integrity, required smoke receipts, coverage check, and source-report digest.
If any required evidence is absent, do not create a result page.
