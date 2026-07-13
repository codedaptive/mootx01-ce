---
title: MX-TABULAR — Row/column data as a first-class kit shape
version: v0.1
status: draft-under-adversarial-review
date: 2026-07-11
description: "Design spec, parent of the MX-TAB mission set. Datasets enter the estate as a single drawer-level handle over a native backend table; rows are the interior, the handle is the citizen. Lenses gain dataset targets; ARIA gains four tools."
relates_to:
  - docs/concepts/MOOTX01_AND_ARIA_CANON.md
  - docs/concepts/KIT_INTERFACE_DESIGN.md
---

# Spec MX-TABULAR — Row/column data as a first-class kit shape

Priority: P2

Type: Design spec (parent of mission set, not itself a mission)

Product: mootx01-ce

Branch: develop/1.1.x (feature line — already cut from develop/1.0.x, worktree active)

Depends on: None

Parallel safe with: All missions not touching PersistenceKit, LocusKit, GLK intake, or AriaMcpKit tool schemas

## Problem

The kits have no user-facing tabular shape. A dataset today enters the estate as
one drawer with kind `structuredJSON` or `list`. The whole table gets one
fingerprint. Recall can find the table. It cannot find a row. The lenses cannot
see the columns.

Meanwhile the substrate already speaks tabular internally. PersistenceKit
defines `TypedValue`, `StorageRow`, `SchemaDeclaration`, `StoragePredicate`,
and `OrderClause`. The `RowStore` protocol
(packages/kits/PersistenceKit/Sources/PersistenceKit/RowStore.swift:32) already
supports column projection (the no-blob read path, declared at RowStore.swift:96).
SQLite and Postgres backends both handle row/column tables natively. The gap is
not storage. The gap is that user data cannot occupy that shape.

The lens layer proves the math is ready — with one honest exception. Complexity
computes entropy over label fields. Associations projects categorical facets
into a co-occurrence matrix. Both run over drawer metadata today; pointing them
at user columns is plumbing, not research. Cohesion is different: the shipped
lens (CognitionKit `Contradiction.swift`, surfaced as `moot_lens_cohesion`) is a
**lexical** odd-one-out detector over content. Column-value anomaly over
numeric/categorical rows is a related but **new** computation. It is in scope,
costed as new lens math, not reuse (see section 4).

## Locked decision: dataset entity, not row-as-drawer

One dataset equals one drawer-level handle. Rows live in native backend tables.
This is locked for three reasons.

1. **Scale.** A 1M-row table imported as 1M drawers swamps a 50K-drawer estate,
   destroys the co-occurrence matrix tier, and makes dreaming meaningless.
2. **Semantics.** Belief lifecycle, sensitivity, exportability, and provenance
   belong to the dataset as a unit. A user confirms or supersedes a table, not
   row 48,201.
3. **Cost.** Per-row capture pays classification, node resolution, and encoding
   per item. GLK-BATCH-1 exists because that cost is already unacceptable at
   40K items.

Rows are the interior of the dataset. The drawer handle is the citizen.

## Design

### 1. DatasetStore (PersistenceKit)

New protocol alongside `RowStore` and `BlobStore`, surfaced on the `Storage`
protocol (packages/kits/PersistenceKit/Sources/PersistenceKit/Storage.swift:16)
the same way `rowStore` and `blobStore` are surfaced on the concrete storages
(packages/kits/PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift:26).

- `createDataset(id, schema, indexes)` — creates a namespaced backend table per
  dataset (`ds_<uuid>` naming, UUID hyphen-stripped so the identifier needs no
  quoting on either backend) from a `SchemaDeclaration` built of existing
  `TypedValue` column types. `indexes` is a list of single-column secondary
  index declarations; composite indexes are out of scope for v1. **Primary key
  defaulting:** a schema may name a primary-key column; if it does not, the
  table uses the backend's synthetic key (SQLite rowid, Postgres
  `bigint generated always as identity`) and that key is what `appendRows`
  pre-sorting refers to.
- `appendRows(id, rows)` — bulk insert. One transaction, prepared statement,
  pre-sorted by primary key. Reuses the GLK-BATCH-1 transaction seam
  (`beginTransaction` / `commitTransaction` on `RowStore`, RowStore.swift:115).
- `queryRows(id, predicate, orderBy, limit, offset, columns)` — delegates to
  the existing predicate and projection machinery. No new query language.
- `columnStats(id, column)` — count, distinct count, min, max, null count.
  Computed in SQL by the backend, returned as a typed struct. This is the feed
  for lenses.
- `dropDataset(id)` — table drop plus handle tombstone.

**Identifier safety (hard requirement, both legs).** Dataset table names are
generated (`ds_<uuid>`), never user-supplied. Column names ARE user-supplied
(they arrive from `moot_file_dataset` and from CSV headers) and become SQL
identifiers in `CREATE TABLE` and index DDL. Every column identifier passes a
validator before any DDL or DML is built — the Postgres leg already has
`PostgreSQLIdentifierValidator.swift`; SQLite gets an equivalent, and the Rust
leg mirrors both. Rejected identifiers fail the whole import with a clear
error; there is no sanitize-and-continue path.

**`Storage.datasetStore` shape.** The protocol requirement is a throwing
accessor — `var datasetStore: any DatasetStore { get throws }` (Swift) /
`fn dataset_store(&self) -> Result<&dyn DatasetStore>` (Rust) — with a default
implementation that throws `unsupported`, so third-party `Storage` conformers
do not break. A plain computed property cannot throw; both legs use the
throwing-accessor shape so the seam is identical.

Backends: SQLite and Postgres implement natively. InMemory implements for
tests. No new engines. `CachingRowStore` does not wrap `DatasetStore` in v1;
dataset reads are scan-shaped and would churn the LRU.

### 2. Dataset handle (LocusKit + GLK)

- New content kind `dataset` beside `prose`, `code`, `transcript`, `list`,
  `structuredJSON`, `imageCaption`
  (packages/kits/LocusKit/Sources/LocusKit/DrawerOperational.swift:80).
- The handle drawer stores: dataset id, schema summary, row count, column list
  with types, source provenance, and the layered signatures (section 3). It
  carries the full adjective-axis metadata: state, trust, sensitivity,
  exportability, confirmation. Belief mutations (confirm, contest, supersede)
  apply to the handle and therefore to the dataset as a unit.
- **Classifier boundary (locked).** The FDC classifier never emits `dataset`.
  Handles are created only through the tool path (`moot_file_dataset`) — a
  dataset is a deliberate act, not a classification outcome. `moot_reclassify_fdc`
  passes dataset handles through untouched. The FDC label taxonomy does not
  gain a dataset label; the kind is orthogonal to FDC.
- Sensitivity floor: rows inherit the handle sensitivity. No per-row
  sensitivity in v1.
- **Withdraw (locked semantics):** withdrawing the handle hides the dataset
  from recall AND refuses `moot_dataset_query` / `moot_dataset_stats` by id
  with a withdrawn-handle error. Withdraw is user intent to hide the data, not
  just its discoverability. The backend table remains (withdraw is reversible).
- **Erase:** erasing the handle drops the backend table after the standard
  confirmed irreversible-erase gate. Both the handle erase and the table drop
  land in the audit log.

### 3. Layered signatures (semantics layer)

Three tiers, cheapest first.

1. **Table signature:** one fingerprint over schema plus sampled content. Feeds
   ordinary recall. The dataset is findable like any drawer.
2. **Column signatures:** one fingerprint per column from name, type, and value
   distribution sketch. Feeds lenses. It also *enables* cross-dataset column
   matching (same-column-different-name detection), but matching itself is v2 —
   v1 computes and stores the signatures, nothing consumes them across datasets.
3. **Row fingerprints:** computed lazily, never at import. Materialized only
   for rows surfaced by a query, capped per dataset. This keeps 1M-row imports
   at import speed and keeps the matrix tier clean.

Dreaming and distillation see the handle only in v1. Rows do not enter the
association matrix.

### 4. Lens targeting (CognitionKit)

The dataset-target lenses are the **CognitionKit** (deliberate/active) lenses,
not their NeuronKit siblings — targeting a named dataset column is a deliberate
query by construction. v1 scope is exactly three:

- **Complexity** (CognitionKit `Complexity.swift`): entropy over a named user
  column, mutual information between two columns. Direct reuse of the existing
  field-entropy path.
- **Associations** (CognitionKit `AssociationRules.swift`): co-occurrence rules
  across categorical columns of one dataset. Direct reuse of the facet-matrix
  path with columns as facets.
- **Cohesion**: outlier rows by column-value anomaly, capped scan. **New lens
  math** — the shipped cohesion lens is lexical; this is a numeric/categorical
  distance scorer. Costed as its own mission part with reference fixtures, not
  as reuse.

All other lenses explicitly reject dataset targets in v1 with a clear error,
not silent wrong answers.

### 5. ARIA tool surface (AriaMcpKit)

Four new tools, plus one optional parameter added to each of three existing
lens tools. No **breaking** changes to any existing tool schema — the lens-tool
additions are optional parameters with absent-means-current-behavior semantics.

- `moot_file_dataset(name, columns, rows | csv_path, location, wing,
  sensitivity, exportability)` — creates handle plus table, bulk loads.
  **Path-ingestion rules:** `csv_path` is canonicalized, must resolve to a
  regular file, is size-capped, and the resolved path is recorded in the
  handle's provenance and the audit log. Column identifiers pass the validator
  (section 1) before any DDL.
- `moot_dataset_query(id, where, order_by, limit, columns)` — predicate grammar
  mirrors `StoragePredicate`. Returns rows plus the handle metadata so the
  caller always sees belief state next to data. Refuses withdrawn handles
  (section 2).
- `moot_dataset_stats(id, column?)` — `columnStats` passthrough. Refuses
  withdrawn handles.
- `moot_lens_complexity`, `moot_lens_associations`, `moot_lens_cohesion` gain
  an optional `dataset_id` parameter.

**Security review gate:** the missions shipping this section and section 6
(MX-TAB-6 and MX-TAB-7) name Perkins in their post-flight suites — user column
names becoming SQL identifiers, filesystem path ingestion by an MCP tool, and
the export surface are squarely his lane.

### 6. Import, export, and vault round-trip

- **Import:** CSV and JSON-lines in v1 via the existing capture seam, one
  transaction per file using the shard-merge discipline already proven in
  SQLiteShard (packages/kits/PersistenceKit/Sources/PersistenceKitSQLite/SQLiteShard.swift).
  Parquet and Arrow are explicitly out of scope for v1 and noted as the natural
  v2 (no new engine required; reader-only dependency).
- **Export:** `moot_vault_export` writes a dataset as CSV beside the handle
  note. Export scope rules apply unchanged; a private handle never exports.
- **Vault round-trip (locked v1 behavior):** `moot_vault_import` recreates the
  backend table from the exported CSV through the same code path as
  `moot_file_dataset` (validator, transaction, signatures recomputed), and
  reattaches the handle metadata from the note. `moot_vault_reconcile` compares
  the **table signature** — dataset interiors are opaque to reconcile in v1; a
  signature mismatch surfaces as an ordinary content conflict on the handle.
  An estate that exports datasets can reimport them; reconcile never silently
  drops a dataset.

## Why this is the moat

Databases store tables. Nothing else gives a table a belief lifecycle. This
design makes "this dataset is unconfirmed," "this one is superseded," and
"these two contradict" native operations on tabular data. ClarityCalc is the
first consumer: MSP license reconciliation is a contested-tabular-data problem,
and contested is exactly what the estate models.

## Branching and flow

Standing state, restated so no mission worker re-derives it wrong:

- **CE is the source of truth for all SHARED substrate** — standing order since
  the 2026-06-29 mirror, not an amendment introduced by this spec. CognitionKit
  and NeuronKit are additionally CE-led outright. EE receives backports from
  mootx01-ce/develop/1.1.x. Everything in this spec ships in CE; nothing here
  is EE-only.
- The CE surgical-commits-only rule is scoped to develop/1.0.x. Feature work is
  permitted on develop/1.1.x.

Branch topology, next weeks:

- develop/1.0.x — fast-moving bug fixes only. Existing candidate and stable
  promotion flow unchanged.
- develop/1.1.x — **already cut** from develop/1.0.x; the feature worktree is
  active. All MX-TABULAR missions land here. develop/1.0.x merges forward
  **per fix** (the standing practice), and additionally before every mission
  branch cut, so feature work always sits on current fixes.
- Flow is one-way until release. Features never merge 1.1.x into 1.0.x.
  Fix-on-oldest discipline: a bug found during 1.1.x work is authored against
  1.0.x and merged forward, never fixed only on 1.1.x.
- At 1.1.0 release, 1.1.x is a superset of 1.0.x by construction. 1.0.x retires
  or continues as a patch line at Bob's discretion.
- EE backport: merge or cherry-pick from develop/1.1.x after the 1.1.x line
  stabilizes per-mission. Precondition: verify EE's unreleased WIP has not
  diverged the shared substrate files (PersistenceKit, LocusKit, GLK,
  AriaMcpKit) before the first backport merge. That check is a required step
  of MX-TAB-0, not an afterthought.

## Blast radius

Symbols added (no existing symbol changes semantics):

- `DatasetStore` protocol + SQLite, Postgres, InMemory conformances (Swift + Rust)
- `Storage.datasetStore` throwing accessor (additive protocol requirement with
  default `unsupported`-throwing implementation to avoid breaking third
  conformers; see section 1 for the exact shape in each leg)
- SQLite column-identifier validator (Postgres leg already has one)
- `dataset` content kind (LocusKit enum, GLK intake, exhaustive-switch sites)
- Column-signature functions (semantics layer)
- Four ARIA tools + three optional lens parameters

Symbols touched but not changed in behavior:

- `RowStore` transaction methods (reused, GLK-BATCH-1)
- `SchemaDeclaration`, `TypedValue`, `StoragePredicate` (reused as-is)

**Exhaustive-switch risk:** every switch over content kind in both legs must
gain a `dataset` arm. A preliminary sweep already shows a dozen-plus Swift
sites (EstateVerbs, DreamingDaemon ×2, AuditBridge, EstateLifecycle,
StandingSignalScheduler, ToolDispatch, AssociationRules, FormalConcepts,
SyncRecord, ObsidianAdapter, …) plus Rust (estate_verbs.rs, hydration.rs,
coordinator.rs). This is why the enum addition is its own mission (MX-TAB-3).
Codegraph sweep required before mission authoring; the sweep output becomes
that mission's Blast Radius Report seed.

## Parity law

Every part lands twice, Swift and Rust, byte-identical semantics. Rust twin
files: the `RowStore` trait (packages/kits/PersistenceKit/rust/src/row_store.rs:9)
gains a sibling `dataset_store.rs`; LocusKit `drawer_store_sqlite.rs` untouched
except the kind enum.

**Float discipline:** `columnStats` min/max/mean over REAL columns cross the
tool surface as JSON float text and MUST follow the f64 shortest-roundtrip wire
rule — f64 only, never f32, or the legs disagree three ways. This is a known
landmine, not a hypothetical.

**Collation discipline:** `orderBy` over TEXT columns and `distinct count`
must produce identical results across SQLite, Postgres, and both legs. v1 locks
TEXT ordering to byte order (SQLite BINARY collation; Postgres `COLLATE "C"` on
dataset TEXT columns) so parity is decidable. Locale-aware ordering is a v2
question, not a v1 wobble.

## Candidate mission decomposition

- **MX-TAB-0** — Wire the develop/1.0.x → develop/1.1.x forward-merge cadence
  (per-fix + pre-mission-cut), run the EE shared-file divergence check
  (PersistenceKit, LocusKit, GLK, AriaMcpKit), record findings. (The branch cut
  itself is already done.)
- **MX-TAB-1** — `DatasetStore` protocol + SQLite **and InMemory** conformances,
  identifier validator, index surface, both legs, tests. InMemory rides here
  because it is the test double for the protocol's default-behavior tests.
- **MX-TAB-2** — Postgres conformance, both legs, tests. (Decision pending —
  see open questions; recommendation is defer, SQLite covers CE and
  ClarityCalc.)
- **MX-TAB-3** — `dataset` kind: enum case + every exhaustive-switch arm, both
  legs. Mechanical, wide, atomic — this is the mission that claims the atomic
  exception, and it ships nothing but the case and its arms (each arm is the
  correct no-op/reject behavior for that site).
- **MX-TAB-4** — Handle drawer, belief-mutation wiring, withdraw/erase gates,
  classifier pass-through, both legs.
- **MX-TAB-5** — Layered signatures: table + column tiers, both legs.
- **MX-TAB-6** — Lens targeting: complexity + associations (reuse), cohesion
  (new column-anomaly scorer with reference fixtures). Perkins post-flight.
- **MX-TAB-7** — ARIA tools + CSV/JSONL import + vault export/import
  round-trip, integration tests. Perkins post-flight.

Everything serializes behind MX-TAB-0. Missions 1 and 2 are then parallel safe
with everything outside PersistenceKit. Missions 3 through 7 serialize behind 1.

## Non-goals (v1)

- No new database engines. SQLite and Postgres only.
- No per-row belief state, sensitivity, or exportability.
- No rows in the association matrix, dreaming, or distillation.
- No cross-dataset column **matching** (signatures are computed in v1; nothing
  consumes them across datasets until v2).
- No composite indexes; single-column secondary indexes only.
- No Parquet, Arrow, or SQL passthrough surface.
- No cross-dataset joins in the ARIA tool surface.
- No update-in-place row API (pending open question 3; the default model is
  append-plus-supersede-the-handle).

## Verification (spec level)

- Import 1M-row CSV in under 60 seconds on Apple Silicon reference machine.
- Estate drawer count increases by exactly 1 per dataset import.
- `moot_dataset_query` p50 under 10 ms for point queries against the primary
  key or a declared secondary index; non-indexed predicates are documented as
  scans and carry no latency gate in v1.
- Lens entropy over a user column matches offline computation on fixture data.
- Cohesion column-anomaly scorer matches reference fixtures on both legs.
- Confirm, contest, supersede on a handle round-trips through audit log.
- Withdrawn handle: recall excludes it AND `moot_dataset_query` refuses it.
- Erase: handle gone, backend table gone, both events in the audit log.
- Vault round-trip: export then import on a fresh estate reproduces the table
  (same table signature) and the handle metadata.
- Malicious column names (SQL metacharacters, quoting attempts) are rejected
  by the validator on both backends, both legs.
- Parity harness: identical results Swift vs Rust on the fixture dataset,
  including `columnStats` float text and TEXT ordering.

## Open questions for Bob

1. Should dataset rows be recallable by content at all in v1 (lazy row
   fingerprints), or is query-only access enough to ship first?
   *Recommendation: query-only; row fingerprints are severable and are the one
   place this design could leak back into the matrix tier.*
2. Postgres in MX-TAB-2 or deferred? *Recommendation: defer; SQLite alone
   covers CE and ClarityCalc, and MX-TAB-2 is the only mission with no
   consumer.*
3. Does ClarityCalc want an update-in-place row API in v1, or is
   append-plus-supersede-the-handle the reconciliation model?
   *Recommendation: append-plus-supersede IS the model; an update-in-place API
   gives rows a mutation lifecycle the belief model deliberately denies them.*
