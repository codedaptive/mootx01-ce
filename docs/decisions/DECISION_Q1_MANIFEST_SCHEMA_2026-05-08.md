---
status: decided
question: Q1 (parent — manifest schema specifics)
authors: MOOTx01 maintainers
date: 2026-05-08
relates_to:
  - DECISION_Q1_PROVENANCE_BITMAP_2026-05-08.md (sibling — provenance representation)
  - DECISION_LATTICE_CITATION_UDC_WIKIDATA_2026-05-07.md (manifest carries lattice_citation)
supersedes: none
context:
  - Q1 (parent) covers manifest column shape, storage location, version
    field format, and v1 field set. The provenance representation slice
    was decided 2026-05-08 in a sibling decision record; this record
    decides everything else about the manifest.
  - Driving question surfaced mid-discussion — does the manifest deliver
    on the VPF self-describing-bootstrap promise, or only the
    spec-as-bootstrap promise? Resolved by adding two fields that make
    the manifest a true bootstrap for everything that varies per estate.
---

# Q1 Decision — Manifest Schema (Parent)

## The question

Q1 has four sub-decisions:

1. **Column shape** — JSON blob, key/value table, or typed columns?
2. **Storage location** — same SQLite file as drawers, or sidecar?
3. **Version field format** — how does the manifest declare which
   schema version it conforms to?
4. **v1 field set** — what fields ship in the initial manifest?

This record decides all four. The provenance representation
question (sub-decision of Q1) is resolved separately in
`DECISION_Q1_PROVENANCE_BITMAP_2026-05-08.md`.

## The decision

### 1. Column shape: dedicated `manifest` table, key/value rows

```sql
CREATE TABLE manifest (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL              -- TEXT for strings, stringified
                                     -- integer for bitmaps, JSON for
                                     -- the rare structured value
);
```

One row per field. Adding a field is an INSERT, not a schema
migration. Matches the existing `meta` table pattern that LocusKit
already ships, so no new mental model.

Rejected alternatives:

- **JSON blob in `meta` row.** Cheap to extend but every read parses
  JSON, fields are not indexable, SQL queries against manifest
  values become awkward (`json_extract(value, '$.zoom_window_low')`).
  Loses the SQLite-as-queryable-store benefit.
- **Typed columns on a dedicated `manifest` table.** Most
  query-friendly per individual field but every new manifest field
  is a schema migration. The architecture is supposed to evolve;
  locking column types is anti-pattern for this surface
  specifically.

### 2. Storage location: same SQLite file as drawers

The manifest lives in the same SQLite file as drawers, enrichments,
provenance_audit, profiling_runs, devices, corrections, and the
CorpusKit virtual tables. One file, atomic backups, atomic
transactions across all GLK state.

Sidecar files were considered and rejected. The single benefit
(readable without opening the database) is weak — opening a SQLite
file is cheap and the manifest is small. The downsides are real:
two-file atomicity, sync drift, backup complexity. No forcing
function justifies the split.

### 3. Version field format: `manifest_version` row, semantic version

A single row keyed `manifest_version`, value is a string like
`"1.0"`. Engine reads on open, asserts compatibility with its
expected major version, refuses to open if incompatible.

Same pattern as VPF library headers: declare the version
explicitly, fail loud when it doesn't match. The engine never
silently operates on a manifest version it doesn't understand.

A separate `schema_version` row declares the version of the
*storage schema* (drawers, enrichments, etc.) — these can drift
independently from the manifest schema, though in practice they
will usually move together.

### 4. v1 field set

| Key | Type | Purpose |
|---|---|---|
| `manifest_version` | string | semantic version of the manifest schema itself |
| `schema_version` | string | semantic version of the storage schema (drawers, enrichments, etc.) |
| `estate_uuid` | string | unique identifier for this estate (UUIDv4) |
| `estate_name` | string | human-readable name |
| `owner_identifier` | string | iCloud-account-keyed owner ID |
| `lattice_citation` | string | e.g., `"UDC:2024+Wikidata:2024-Q3"` |
| `framework_profile` | string | profile name and version, e.g., `"personal_life_v1"` |
| `framework_profile_definition` | JSON blob | full profile content (see §5 below) |
| `zoom_window_low` | integer | UDC depth low end |
| `zoom_window_high` | integer | UDC depth high end |
| `federation_group_id` | string (nullable) | federation membership; NULL if standalone |
| `access_posture` | integer (bitmap) | estate-level access defaults |
| `provenance_defaults` | integer (bitmap) | default provenance bits applied to new drawers |
| `active_storage_mode` | integer (bitmap, 6 bits) | current L/Q/P configuration |
| `tables_present` | string | comma-separated list of optional tables present in this database (see §5 below) |
| `created_at` | string (ISO8601) | when the estate was created |
| `last_modified` | string (ISO8601) | when the manifest was last written |

## §5 — The two justified JSON / structured values

Most manifest fields are integers, strings, or bitmaps. Two are
not, and the reason matters because it's the only place the
JSON-blob escape hatch is used in the v1 schema.

### `framework_profile_definition` (JSON blob)

Full profile content lives in the manifest. The `framework_profile`
string is the profile's *name and version*; the
`framework_profile_definition` is the actual content — wing
vocabulary, room types, depth-anchoring rules, lane vocabulary,
channel extensions if any.

Why JSON blob and not its own table:

- Profile content is a **structured authored document**, like a
  config file. The application or the user authors it once at
  estate creation; the engine reads it but does not query
  individual fields with SQL.
- The profile schema is itself versioned and evolves; flattening
  to typed columns would force schema migrations every time a
  profile field is added or restructured.
- A profile is logically a single thing. Splitting it across
  multiple tables fragments authoring and reading.

Why this satisfies the VPF self-describing-bootstrap principle:

A reader (third-party tool, federation partner, future agent)
that knows the GLK spec but has never seen this estate's profile
can read `framework_profile_definition` and learn everything it
needs to interpret depth coordinates, lane tags, and any
profile-contributed channel extensions. The profile travels with
the estate. No out-of-band fetch from a profile registry.

This is the VPF library-attribute-table pattern correctly applied:
**variable content lives in the file; fixed content lives in the
spec.**

### `tables_present` (string)

A comma-separated list of optional tables that exist in this
database. Examples:

- `"profiling_runs,provenance_audit,devices"` — all optional
  tables present
- `"provenance_audit,devices"` — never ran profiling
- `""` — minimal estate (early version or no enrichment activity)

A reader runs `SELECT value FROM manifest WHERE key =
'tables_present'` and learns immediately what's available. No
need to query `sqlite_master` and reason about table names.

Why a string and not a small dedicated table:

- v1 has fewer than ten optional tables. Comma-separated string
  is adequate.
- If the list grows beyond ten or needs metadata per entry
  (added_at_version, populated_count), promote to a table in v2.

The `tables_present` field is the smaller half of the VPF
file-as-bootstrap argument: federation and third-party readers
benefit from knowing what's there before they query.

## §6 — What this enables

### For the spec

The spec describes the fixed parts: the `manifest` table's column
shape, the meaning of each well-known key, the bit layouts of
`access_posture` / `provenance_defaults` / `active_storage_mode`,
the schema of every table named in `tables_present`.

The estate-specific parts (which lattice, which profile, which
tables are present) are read from the manifest itself. A reader
with the spec and the file has everything it needs.

### For federation

Two estates federate. Estate A's reader doesn't know Estate B's
framework profile. Estate B's
`framework_profile_definition` is in Estate B's manifest. Estate
A's reader fetches it, applies it locally for the federated
context, and can interpret Estate B's lane tags and depth
coordinates. No out-of-band profile registry.

### For third-party tools

A tool written against the GLK spec — published openly, no GLK
codebase access required — can read any GLK estate written by any
application. The estate carries its own profile. The estate
declares which optional tables exist. Schema is published. The
reader bootstraps from the manifest in three queries:

```sql
SELECT * FROM manifest;                                       -- bootstrap
SELECT * FROM drawers WHERE provenance >> 4 & 0x7 = 2;        -- user-confirmed drawers
SELECT * FROM enrichments WHERE rung_type = 'precis'          -- précis rungs
                          AND model_id = 'apple-fm-2026-q1';
```

This is the durability claim the publication makes, fulfilled at
the schema level.

## §7 — What this decision does NOT cover

- **Provenance representation** — decided in
  `DECISION_Q1_PROVENANCE_BITMAP_2026-05-08.md` (Int64 bitmap on drawers).
  This record decides where provenance *defaults* live (manifest,
  as `provenance_defaults` integer bitmap).
- **Provenance schema specifics (Q2.5)** — defaults block content,
  mutability rules per axis, audit retention, retrieval-layer
  filter semantics. Open.
- **Multi-rung schema (Q2)** — does the embedding vector live in
  `enrichments` or in CorpusKit's `vec_drawers` virtual table? Open.
- **Framework profile format (Q4)** — Swift literal vs JSON vs YAML
  for *authoring* profiles. The manifest stores the *content* as a
  JSON blob regardless of which authoring format the developer or
  user used. Q4 decides the developer-facing authoring shape.
- **Federation conflict resolution (Q5)** — what happens when two
  estates federate and Estate A and Estate B disagree on a shared
  room. Open.
- **Profiling run schema, devices schema, corrections schema** —
  these are sibling tables in the same SQLite file but their
  internal columns are decided in their own decision records.

## §8 — Open follow-ups (not blocking)

- Should `tables_present` be enforced (engine refuses to open if
  declared tables don't exist) or advisory (engine opens, missing
  tables are treated as if present-but-empty)? Leaning
  enforced — drift between manifest and reality is the failure
  mode the manifest exists to prevent.
- Should `framework_profile_definition` be deduplicated across
  estates that share a profile? At v1 scale (one human, a handful
  of estates) the duplication is negligible. At federation scale
  this could be revisited; for v1, ship the duplication.
- The `access_posture` bitmap layout is named but not specified.
  Belongs in its own decision record once the access posture
  taxonomy is settled (probably during Q5 federation work).

## §9 — Schema (full)

```sql
CREATE TABLE manifest (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Required keys at v1 (engine refuses to open if any are missing):
--   manifest_version, schema_version, estate_uuid, estate_name,
--   owner_identifier, lattice_citation, framework_profile,
--   framework_profile_definition, zoom_window_low, zoom_window_high,
--   access_posture, provenance_defaults, active_storage_mode,
--   tables_present, created_at, last_modified
--
-- Optional keys at v1:
--   federation_group_id (NULL when standalone)
```

---

*End of Q1 (parent) decision record. Q1 is now fully resolved
across this record and the sibling provenance bitmap record. Q2
(multi-rung schema) is the next decision in the queue.*
