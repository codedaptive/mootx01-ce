---
title: VaultKit JSON Seed-File Format
version: 1.1.0
status: active
date: 2026-08-09
description: Canonical definition of seed-file schema v1.1 — the rigid, versioned JSON format consumed by the moot_json_import lane, both ports.
---

# VaultKit JSON Seed-File Format (schema v1.1)

This document is the authority definition of the seed-file format the
`moot_json_import` lane consumes. The format belongs to VaultKit, where the
importer lives (`Sources/VaultKit/JsonImportBridge.swift`,
`rust/src/json_import_bridge.rs`). Any other document describing this format
is a pointer to this one, not a second definition.

The lane is the fourth import lane beside the Obsidian/Markdown, MemPalace,
and GKF lanes. It is built for machine-generated interchange (benchmark
seeds, estate reconstruction, third-party reproduction), which drives its
three defining properties:

1. **Total pre-write validation.** The whole file is validated before any
   estate work. Any violation means ZERO writes and one error naming the
   first offending element. There is no count-and-skip; a partial estate is
   never produced.
2. **File order is ingestion order.** The `records` array order is
   semantic (supersession chains, timelines). The importer never sorts.
3. **Strict append.** Any lineage overlap between file records and the
   existing estate is a hard error. Silent dedup is banned as a
   determinism hazard.

## Top-level object

```json
{
  "format_version": 1,
  "name": "supersession-20260725",
  "records": [ ... ],
  "facts": [ ... ],
  "tunnels": [ ... ]
}
```

| Key | Required | Rule |
|---|---|---|
| `format_version` | yes | MUST equal `1`. Any other value is a hard error naming the version found. |
| `name` | yes | Non-empty seed name; carried into the audit receipt. |
| `records` | yes | Array (may be empty). Order IS ingestion order. |
| `facts` | no | Array; defaults to empty. |
| `tunnels` | no | Array; defaults to empty. |

The schema is rigid: an unknown key — at top level or inside any element —
is a hard error. A misspelled optional key silently changing an estate is
exactly the failure class this lane eliminates.

## `records[]`

```json
{
  "id": "r0001",
  "content": "…",
  "event_time": "2026-01-03T09:00:00Z",
  "wing": "Benchmark",
  "room": "supersession/chains",
  "kind": "prose",
  "sensitivity": "normal",
  "exportability": "private",
  "subject": "First sentence of the content."
}
```

| Key | Required | Rule |
|---|---|---|
| `id` | yes | Non-empty; unique within the file. The lineage anchor: the drawer's lineage is `DrawerMapping.lineageID(forStableSourceKey: id)` — the exact FNV-1a-128 derivation the shipping importers use, for cross-port parity. |
| `content` | yes | Non-empty (substrate invariant I-5). |
| `event_time` | yes | UTC ISO8601 with a REQUIRED trailing `Z`. Exactly two shapes: `YYYY-MM-DDTHH:MM:SSZ` and `YYYY-MM-DDTHH:MM:SS.fffZ` (milliseconds, exactly 3 fraction digits). Offset forms (`+02:00`) are rejected. Components are calendar-validated (no Feb 30). |
| `wing` | no | Non-empty when present. Absent → the import's default wing. An empty string is an error, not a default. |
| `room` | yes | Non-empty room path. |
| `kind` | no | One of `prose` (default), `code`, `transcript`, `list`, `structuredJSON`, `imageCaption`. The system-managed kinds (`fingerprintOnly`, `dataset`) are not seedable. |
| `sensitivity` | no | One of `normal` (default), `elevated`, `restricted`, `secret`. |
| `exportability` | no | One of `private` (default), `public`. `public` is NOT allowed together with `sensitivity: secret` (substrate invariant I-22) — the combination is rejected in total validation, never clamped. |
| `subject` | no | **Schema v1.1.** Optional caller-supplied subject line. Non-empty, ≤120 characters. An empty string is a hard error (omit the key to mark as subject-debt instead). When present, written via `setSubjectRepresentation`/`set_subject_representation` with pipeline version `import-v1` (bottom trust tier — regenerable by the backfill daemon). When absent, the record is subject-debt: the backfill daemon will regenerate a subject. The import receipt carries `subjectsProvided` and `subjectsDebt` counters for the file. |

## `facts[]`

```json
{ "subject": "s", "predicate": "p", "object": "o", "record_id": "r0001" }
```

All four keys are required and non-empty. `record_id` MUST resolve to a
record `id` in the same file; the imported KG fact is anchored to that
record's drawer (inheriting its sensitivity/provenance bitmaps through the
standard `captureKGFact` seam).

## `tunnels[]`

```json
{ "from": "r0001", "to": "r0002", "kind": "references", "label": "…" }
```

| Key | Required | Rule |
|---|---|---|
| `from`, `to` | yes | MUST resolve to record `id`s in the same file. |
| `kind` | yes | One of the closed `TunnelKind` vocabulary, spelled as the Swift case names: `supersedes`, `references`, `blocks`, `validates`, `contradicts`, `derivesFrom`, `covers`, `elaborates`, `respondsTo`, `parent`. |
| `label` | no | Non-empty when present. Absent → the generated default `"<sourceWing>/<sourceRoom> -> <targetWing>/<targetRoom>"` (the same fill-in the palace lane applies, invariant I-5). |

## Ceilings

One budget covers the whole import (the `MemPalaceImportLimits` pattern):

- **Byte ceiling** — default 512 MiB, charged from the on-disk size before
  the file is read.
- **Row ceiling** — default 2,000,000 total elements
  (records + facts + tunnels).

## Failure contract

Any violation: the import performs ZERO writes and returns ONE error naming
the first offending element (`record[3] (id "r0004"): …`, `fact[0]: …`,
`tunnel[1]: …`). Validator error messages are pinned byte-identical across
the Swift and Rust ports; the determinism verification script compares
failure output as well as estate inventories.

## Import pipeline (context, not part of the format)

After validation the lane runs: one estate snapshot → strict-append
collision assertion (any lineage overlap with the existing estate is a hard
error naming the colliding record id) → pure frame build in file order →
windowed bulk write (`captureBatch`, 125k-row transaction windows) →
subject attribution phase (records carrying `subject` have it written via
`setSubjectRepresentation` with pipeline `import-v1`; records without a
subject accrue debt for the backfill daemon) → intra-file relationship pass
(facts, tunnels) → one deferred encode enqueue → audit receipt carrying
`seedSha256`, `subjectsProvided`, and `subjectsDebt`, so any estate is
traceable to the exact seed file that built it. The importer returns after
the encode enqueue; the drain barrier and dream are caller protocol steps.

## Changelog

- **1.1.0 (2026-08-09)** — Schema v1.1: added optional `subject` field on
  records (mission MXE-JI-4). Non-empty, ≤120 chars when present; empty
  string is a hard error; absent = subject debt. Written via
  `setSubjectRepresentation` with pipeline `import-v1` (bottom trust tier).
  Import receipt now carries `subjectsProvided` and `subjectsDebt` counters.
  Pipeline description updated to include the subject attribution phase
  (Phase 5.5). Error message updated from "schema v1" to "schema v1.1".
- **1.0.1 (2026-08-08)** — Documented the I-22 validation rule:
  `sensitivity: secret` + `exportability: public` is rejected in total
  validation (the storage gate refuses the combination on every write;
  rejecting pre-write preserves the zero-partial-write contract).
- **1.0.0 (2026-08-08)** — Initial canonical definition of seed-file
  schema v1, authored with the `moot_json_import` lane (mission MXE-JI-1).
