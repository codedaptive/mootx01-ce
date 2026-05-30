# Blast Radius Report — NOUN-ASC-01 (Association noun substrate)

Mission: `docs/missions/inflight/MISSION_NOUN_ASC_01.md`
Stream: nas · Branch: stream/nas-association-noun-substrate
Baseline commit: `93363c7` · Head: `e3eac3b`
Tier: **net-new (no-cap)** — net-new types + additive registration only.
No existing symbol's semantics changed; no deletions of behaviour
(`git diff --stat`: 12 files, 1898 insertions, **0 deletions**).

## Status: COMPLETE — no RESCOPE required

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table listed 6 files. The real, in-scope blast radius is 12
files — the same additive 12-shape the NOUN-PRO-01 sibling established.
The extra 6 are **additive registrations** Parts 2 and 3 explicitly
require ("Mirror in the Rust schema", "Add store read/write", "Rust suite
mirrors Swift") but the table omitted. Smythe pre-flight (YELLOW) confirmed
these within scope; documented here so the diff is fully accounted for.

| File | In mission table? | Change | Why in scope |
|---|---|---|---|
| `Sources/LocusKit/Association.swift` | yes (CREATE) | new type | Part 1 |
| `Sources/LocusKit/AssociationOperational.swift` | yes (CREATE) | new accessors | Part 1 |
| `rust/src/association.rs` | yes (CREATE) | new type | Part 1 |
| `rust/src/association_operational.rs` | **no** | new accessors | Part 1 rust leg of AssociationOperational; mirrors tunnel_operational.rs split |
| `Sources/LocusKit/LocusKitSchema.swift` | yes (edit) | register `associations` table + 3 indices | Part 2 |
| `rust/src/schema.rs` | **no** | register `associations` table + 3 indices; update `table_count_and_order` + `index_names_match_swift_order` tests | Part 2 "Mirror in the Rust schema" |
| `Sources/LocusKit/DrawerStore.swift` | **no** | add addAssociation / getAssociation / associationsFrom / associationsTo + 2 helpers | Part 3 "Add store read/write methods" |
| `rust/src/drawer_store.rs` | **no** | add 4 trait default methods + 1 import | Part 3 store methods, rust leg |
| `rust/src/drawer_store_inmemory.rs` | **no** | implement 4 methods + 2 helpers + 1 const + 1 import | Part 3 store methods, rust impl |
| `rust/src/lib.rs` | **no** | register association, association_operational, association_tests modules | required for the new rust files to compile |
| `Tests/LocusKitTests/AssociationTests.swift` | yes (CREATE) | conformance + store suite | Part 3 |
| `rust/src/association_tests.rs` | yes (CREATE) | store conformance suite | Part 3 |

## Symbols changed

- **No existing symbol's semantics changed.** Every edit to an existing
  file is additive: a new table appended to a `tables` list, new indices
  appended to the index list, new methods appended to a store / trait, new
  module declarations, and two rust schema tests updated to include the new
  `associations` entries.
- New public surface: `Association`, `AssociationSignalSources`,
  `AssociationDecayClass`, `AssociationArity` (both legs); store methods
  `addAssociation` / `getAssociation` / `associationsFrom(wing:room:)` /
  `associationsTo(wing:room:)` (Swift) and `add_association` /
  `get_association` / `associations_from` / `associations_to` (Rust trait +
  impl).

## Files NOT modified (per mission's MUST NOT list)

- `docs/validation/**` — untouched.
- `Tunnel.swift`, `KGFact.swift`, `Proposal.swift`, other existing noun
  types — read as templates only; not edited.
- The `tunnels` table declaration — read as template; not altered.
- `SubstrateLib` bitmap primitives — used (`BitField.extractField` /
  `bit_field::extract_field`), not changed.

## Deliberate deviations from the Tunnel template (documented inline)

1. **No `kind`.** `Tunnel` carries a typed `TunnelKind` vocabulary in a
   `kind_id` column; an association has no equivalent typed-relationship
   vocabulary. All association-specific semantics live in the operational
   bitmap (cookbook §2.4). The `associations` table has no `kind_id`
   column and no `TunnelKind`-equivalent enum.
2. **A required `latticeAnchor`.** `Tunnel` predates cookbook §2.7 (I-16);
   `Association` honours it, anchored to the lattice-midpoint of its
   endpoints (§2.7). Stored as the four anchor columns drawers/proposals
   use (`udcCode TEXT NOT NULL DEFAULT '' + udcFacets + wikidataQID +
   wikidataQidsSecondary`); `addAssociation` rejects an empty `udcCode`
   with `LocusKitError.invalidContent`, mirroring `addProposal`.
3. **`Association` is not `Hashable`** (Tunnel is). The embedded
   `LatticeAnchor` is `Equatable, Codable, Sendable` but not `Hashable`,
   so synthesised `Hashable` is unavailable — the same constraint
   `Proposal` carries. Rust mirrors: derives `PartialEq, Eq`, not `Hash`.
   Nothing keys a Set/dict on `Association`.
4. **Operational layout is the §2.4 "Association operational" 6-bit-floor
   layout**: `signal_sources_seen` is a **bitset** (bits 0–11) surfaced as
   an `OptionSet` / newtype, not a contiguous named-enum field; `decay_class`
   (bits 12–17, scale-gapped 0/16/32/48) and `arity` (bits 18–19,
   contiguous, v1 always binary per I-23) are ordinary field extracts.

## Schema placement decision

The `associations` table and its three indices are registered **after the
`proposals` block** (not adjacent to `tunnels`), in both the Swift `tables`
list and the Rust `tables` vec, plus the Rust `table_count_and_order` /
`index_names_match_swift_order` tests. This follows the serialized-append
model the mission's parallel-safety note prescribes (npr → nas → nlr edit
the shared schema files in sequence) and keeps the noun tables grouped, the
way `proposals` was appended after `kg_facts` in NOUN-PRO-01. "Mirror
tunnels" is honoured structurally (column shape, edge indices), not by
list-adjacency.

## Pre-existing issue surfaced (out of scope)

`rust/src/drawer_store_inmemory.rs` — `let mut e1` in the
`diary_round_trip_and_lastn_ordering` test triggers an `unused_mut`
warning (line ~2784; shifted from ~2643 at the npr baseline as code was
added above it). Byte-identical-in-cause at baseline `93363c7`; unrelated
to the association symbol (diary test). Left as-is per blast-radius
discipline. My diff adds **zero** new warnings.

## Test verification

- `swift test`: exit 0, **441** passed (422 baseline + 19). 0 warnings.
- `cargo test --lib`: exit 0, **390** passed (367 baseline + 23: association.rs 4,
  association_operational.rs 10, association_tests.rs 9). 1 pre-existing
  unrelated warning (above); zero new.
