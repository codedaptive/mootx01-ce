---
status: decided
question: How should persistent entity tables reserve space for unforeseeable future typed attributes (federation, encryption, custody metadata) without forcing a schema migration after 1.0 ships?
authors: MOOTx01 maintainers
date: 2026-06-17
version: 1.0.0
relates_to:
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/reference/LOCUSKIT_INTERFACE.md
  - docs/reference/VECTORKIT_SPEC.md
  - docs/reference/VECTORKIT_INTERFACE.md
  - docs/reference/CORPUSKIT_SPEC.md
  - docs/reference/CORPUSKIT_INTERFACE.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_INTERFACE.md
supersedes:
  - "DECISION_BUNDLE_ALGEBRA_AND_ERASURE §10 (dangling reference — formalized here)"
description: One nullable `.json` `ext` forward-compatibility column per persistent entity table; null and inert in 1.0; the migration-free home for future per-row typed metadata.
---

# ADR-012 — The `ext` forward-compatibility slot

## Context

The substrate schema is **not frozen** and **no estate data exists to
migrate** before the first public release. The 1.0.0 ship is the single
free schema-migration window: while no production database exists, adding a
column is just a fresh `CREATE TABLE` — no backfill, no ALTER ladder, no
data risk. After 1.0.0 ships to real users, every new column on a
persistent entity table becomes a migration that must be authored, tested,
and rolled out against live data.

Several roadmap tracks are known to need *some* per-row typed metadata that
is not yet designed: the federation/sharing model, at-rest encryption, and
the grant custody payload. Designing those shapes now would be premature;
shipping 1.0 without any reserved space would force a post-ship migration the
moment any of them lands.

The codebase already carried an informal convention for exactly this — a
nullable `.json` column named `ext` on most LocusKit entity tables — but its
governing rationale was cited to `DECISION_BUNDLE_ALGEBRA_AND_ERASURE
section 10`, a document that does not exist in `docs/decisions/` (a dangling
reference). This ADR formalizes the convention as the governing public
record and resolves that missing cite.

## Decision

**Every persistent entity table carries exactly one nullable `.json`
column named `ext`, present from the schema version that introduces it.**

- **Reserve the slot, not the shape.** `ext` has no predefined structure.
  It is the single width-independent container for the unknown-future case.
  No speculative typed columns, no second reserved `BLOB` — one `.json`
  column absorbs any future per-row typed attribute.
- **Null and inert in 1.0.** 1.0 code writes NULL / omits `ext` on every
  insert and upsert, and never reads it. Adding it is therefore a pure
  schema-shape reservation with no behavior change. A nullable column with
  no read path is inert even on append-only tables.
- **Migration-free future use.** When the federation/encryption/custody
  tracks land, they serialize their per-row metadata into `ext` (JSON),
  with no schema migration — the column already exists in every shipped
  database.
- **The `.json` type is the PersistenceKit `.json` column API** (Swift
  `.json("ext", nullable: true)` / Rust `ColumnDeclaration::json("ext").nullable()`),
  which maps to `BLOB` in SQLite and `JSONB` in PostgreSQL. Dates stored in
  any future `ext` payload still follow the fleet TEXT/ISO8601 rule; `ext`
  never carries a Bool stored field — the no-Bool-on-entities invariant
  applies to its contents.

### Pre-ship-window rationale

The five tables that lacked `ext` were provisioned in the 1.0.0 window
precisely because it is free. Doing so later would be a live-data migration;
doing so now is a fresh `CREATE TABLE`. This is 1.1 pre-provisioning landed
during the one window where it costs nothing.

## Table inclusion / exclusion list

`ext` belongs on **persistent entity tables** — rows that represent durable,
caller-authored domain objects. It does NOT belong on regenerable, cache, or
bookkeeping tables, whose rows are derived state that is rebuilt rather than
carried forward, so reserving per-row metadata space on them is meaningless.

### Included — persistent entity tables (14 total)

The 9 that already carried `ext`:

| Table | Kit |
|---|---|
| `drawers` | LocusKit |
| `tunnels` | LocusKit |
| `diary` | LocusKit |
| `kg_facts` | LocusKit |
| `proposals` | LocusKit |
| `associations` | LocusKit |
| `learned_references` | LocusKit |
| `source_catalog` | LocusKit |
| `recall_trace` | LocusKit |

The 5 added under this ADR (the pre-ship pre-provisioning):

| Table | Kit | Component schema bump |
|---|---|---|
| `keys` | LocusKit | LocusKit v1 → v2 |
| `vectors` | VectorKit | VectorKit v2 → v3 |
| `chunks` | CorpusKit (BundleStore) | CorpusKit v1 → v2 |
| `corpus_provider_basis` | CorpusKit (BasisStore, kit-ID `CorpusKitBasis`) | v1 → v2 |
| `grants` | GeniusLocusKit (GrantStore) | tracks LocusKit base + 1 (auto → v3) |

`recall_trace` keeps its existing `ext` (it is a persistent reward-signal
entity, not a cache).

### Excluded — regenerable / cache / bookkeeping tables

| Table | Reason for exclusion |
|---|---|
| `manifest` | Key-value bookkeeping, not a domain entity |
| `container_fingerprints` | Regenerable OR-reduction cache (rebuilt from drawers) |
| `node_bundles` | Regenerable count-vector aggregate (rebuilt on recompute) |
| `iix_*` (inverted-index tables) | Regenerable index, rebuilt from chunks |
| `_storagekit_*` (audit, migrations, vector_meta) | PersistenceKit-internal bookkeeping, created unconditionally by the backend |
| `_storagekit_blobs` | OUT on layering grounds: the opaque blob bucket is a storage-tier primitive. Encryption/federation metadata rides on the **entity rows** (their `ext`), never on the opaque blob bucket — putting it here would invert the layering. |

## Schema-version coupling

Each component store bumps its own schema version when it gains `ext`:
LocusKit v1→v2, VectorKit v2→v3, CorpusKit BundleStore v1→v2, BasisStore
("CorpusKitBasis") v1→v2, and the `grants` schema (version = LocusKit base +
1) follows the LocusKit bump automatically.

The **GeniusLocusKit composite** schema version is the SUM of its three
GLK-composed component versions — LocusKit + VectorKit + CorpusKit
(BundleStore). After these bumps that sum is `2 + 3 + 2 = 7`. The composite
version is **derived** from the live component declarations in both ports
(Swift `LocusKitSchema.version + VectorStore.schemaDeclaration.version +
BundleStore.schemaDeclaration.version`; Rust `lk.version + vk.version +
ck.version`), so a future component bump self-corrects the composite and the
two can never drift. (BasisStore is a separate kit-ID schema, not part of the
composite, so it is not summed.)

The Rust replication gate checks the **global** `current_schema_version()`
against the declared composite version; because the composite is the sum it
is always ≥ every component version, so opening the composite always advances
the global counter to exactly the composite value and the gate passes on both
sides. The Swift gate checks the per-kit version keyed by the `GeniusLocusKit`
kit-ID. Both must declare the same composite value — guarded by a conformance
test on each port (`CompositeSchemaVersionTests` / `composite_version_tests`).

## Consequences

- **Positive.** No post-1.0 migration is required to add the
  federation/encryption/custody metadata that is already on the roadmap. The
  shape can be designed when the feature lands, not now.
- **Positive.** The convention is uniform and conformance-tested across every
  persistent entity table and both language ports.
- **Cost.** A nullable column that is always NULL in 1.0 has near-zero storage
  cost (SQLite stores a NULL in ~1 byte; PostgreSQL tracks it in the null
  bitmap).
- **Neutral.** This ADR records no commitment to any particular `ext` payload
  shape; that is deferred to the federation/encryption/custody design work.

## Supersession note

This ADR supersedes and formalizes the dangling
`DECISION_BUNDLE_ALGEBRA_AND_ERASURE §10` reference that the original `ext`
convention cited. That document does not exist in `docs/decisions/`; the
governing rationale for the `ext` forward-compat slot now lives here. (The
separate, dated `DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20` reference for
the count-vector bundle-algebra / `node_bundles` work is unrelated and
unaffected.)

## Changelog

- 1.0.0 (2026-06-17): Initial decision. Formalizes the `ext` `.json`
  forward-compat slot as the governing convention; provisions it on the 5
  remaining persistent entity tables (`keys`, `vectors`, `chunks`,
  `corpus_provider_basis`, `grants`) during the 1.0.0 free-migration window;
  records the component + composite schema-version coupling; resolves the
  dangling `DECISION_BUNDLE_ALGEBRA_AND_ERASURE §10` cite.
