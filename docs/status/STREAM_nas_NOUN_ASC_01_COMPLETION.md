# COMPLETION: NOUN-ASC-01 — Association noun substrate (type + table + store, both legs)

**Status: COMPLETE**
Stream: nas · Branch: `stream/nas-association-noun-substrate`
Baseline: `93363c7` · Head: `e3eac3b`
Mission: `docs/missions/inflight/MISSION_NOUN_ASC_01.md`
Date: 2026-05-30

---

## Summary

The `association` noun now has substrate behind it in both legs (Swift +
Rust), mirroring the `Tunnel` edge-shaped noun: an `Association` type
model, an `associations` schema table, and store persistence. An
`Association` row round-trips byte-identically through both stores. No
verb behaviour is implemented — the recall/mutate/expunge verb missions
(association accepts no capture, no withdraw per `Acceptance.swift`) can
now target `association`.

The Association operational bitmap follows cookbook §2.4 ("Association
operational", empirical-dominant 6-bit floor): `signal_sources_seen`
bitset (bits 0–11), `decay_class` (bits 12–17, scale-gapped 0/16/32/48),
`arity` (bits 18–19, contiguous — v1 always binary per I-23). The required
lattice anchor follows §2.7 (I-16): an association is anchored to the
lattice-midpoint of its endpoints.

## What Was Done

- **Part 1 — type model, both legs** — `d83db8a`
  - `Association.swift` / `association.rs`: id, source/target endpoints
    (wing + room + optional drawer id), free-form `label`, required
    `latticeAnchor`, three Int64 bitmaps, addedBy, filedAt, the Rev 1.0
    soft-delete reservation (`tombstonedAt` / `removedByBatch`). **No
    `kind`** (the one Tunnel field with no association analogue).
  - `AssociationOperational.swift` / `association_operational.rs`:
    `AssociationSignalSources` (OptionSet / newtype bitset, 10 named bits
    0–9, mask 0xFFF), `AssociationDecayClass` (scale-gapped, Comparable),
    `AssociationArity`. Accessors mirror the `TunnelOperational` pattern;
    the bitset is read off the masked low 12 bits, the two field axes via
    `BitField.extractField` with safe zero-case fallback.
  - `lib.rs` registers the two new rust modules.
- **Part 2 — associations schema table, both legs** — `c3e2d9d`
  - `associations` table registered in `LocusKitSchema.swift` + `schema.rs`,
    mirroring `tunnels`: edge columns, the lattice-anchor quartet (udcCode
    NOT NULL DEFAULT '' + udcFacets + wikidataQID + wikidataQidsSecondary),
    three Int64 bitmaps, ext json. **No `kind_id` column, no generated
    columns** (like tunnels, the edge endpoints are the indexed paths).
    Three indices: `idx_associations_source` (sourceWing, sourceRoom),
    `idx_associations_target` (targetWing, targetRoom),
    `idx_associations_udcCode`. Rust `table_count_and_order` +
    `index_names_match_swift_order` tests updated.
- **Part 3 — store + conformance, both legs** — `e3eac3b`
  - Swift `DrawerStore`: `addAssociation` / `getAssociation` /
    `associationsFrom(wing:room:)` / `associationsTo(wing:room:)` +
    value/row helpers. Edge endpoints + addedBy + lattice anchor required
    (empty `udcCode` → `invalidContent`); edge lookups filter
    `tombstonedAt IS NULL`.
  - Rust `DrawerStore` trait + `InMemoryDrawerStore` impl: `add_association`
    / `get_association` / `associations_from` / `associations_to` +
    helpers.
  - `AssociationTests.swift` (+19) and `association_tests.rs` (+9) store/
    conformance; §2.4 operational + type conformance mirrored inline in
    `association_operational.rs` (+10) and `association.rs` (+4).

## Test Verification Log

### Baseline (mission start, commit 93363c7)
- `swift test`: exit 0, **422** passed.
- `cargo test --lib`: exit 0, **367** passed.

### Final (commit e3eac3b)
- Command: `cd packages/kits/LocusKit && swift test`
  - Exit code: **0**
  - Pass count: **441** (422 baseline + 19 AssociationTests)
  - Tail: `Test run with 441 tests in 40 suites passed`
  - `swift build` warnings: **0**
- Command: `cd packages/kits/LocusKit/rust && cargo test --lib`
  - Exit code: **0**
  - Pass count: **390** (367 baseline + 23: association.rs 4,
    association_operational.rs 10, association_tests.rs 9)
  - Tail: `test result: ok. 390 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`
  - Warnings: **1**, pre-existing + unrelated (see Discoveries).

Coverage achieved: round-trip persist/fetch (both legs, every field
including both optional drawer ids); three-bitmap byte-identity;
lattice-anchor round-trip + lattice-anchor-required (absent → error, both
legs); source/target endpoint resolution via `associationsFrom` /
`associationsTo` (both edge indices); tombstoned rows excluded from edge
lookups but fetchable by id; full §2.4 operational conformance (signal
bitset individual bits + multi-bit + masking, decay-class scale-gap +
sentinels + ordering, arity field + reserved fallback, composite
round-trip); miss returns nil/None; table isolation vs tunnels.

## Smythe Pre-flight

Verdict: **YELLOW — clear to proceed**, no RESCOPE.
(`docs/blast_radius/NOUN_ASC_01_PREFLIGHT.md`)
- Confirmed net-new (`find … -iname '*Association*'` empty); `association`
  already a vocabulary case in `Noun.swift` / `Acceptance.swift` (accepts
  mutate/expunge/recall, no capture, no withdraw — `Acceptance.swift:29`).
- Confirmed the real additive blast radius is 12 files (not the mission
  table's 6) — same shape as NOUN-PRO-01.
- Supplied the §2.4 Association operational layout and confirmed the
  Tunnel template. Flagged the **"mirror Tunnel" vs I-16 tension**: Tunnel
  carries no lattice anchor, so the anchor must follow the Proposal
  pattern (four columns + store gate), not be copied from Tunnel.

## Adams Post-flight

Verdict: **PASS — CLEAN.** No findings (CRITICAL / WARNING / INFO all empty).
(`docs/blast_radius/NOUN_ASC_01_POSTFLIGHT.md`)
- §9 Blast Radius Verification: **PASS** — diff matches the BRR's 12 files
  exactly; 1898 insertions, 0 deletions; every existing-file edit additive.
  Verified all four deliberate Tunnel-template deviations (no kind, required
  anchor, not-Hashable, §2.4 layout) against the cookbook case-for-case;
  Swift↔Rust parity exact; no prohibited files touched; no stale call sites.
- §10 Test Execution Verification: **PASS** — independently re-ran both
  legs (Method B): swift exit 0/441, cargo exit 0/390, both MATCH. The
  single cargo warning confirmed pre-existing (diary test, line shifted
  2784→3007 by exactly the 223 lines this mission added above it) and
  unrelated; zero new warnings either leg.

## Self-review

- Diff (12 files, 1898 insertions, **0 deletions**) matches the BRR
  MUST_UPDATE list exactly. All changes additive; no existing symbol
  semantics altered.
- No bridges, shims, TODOs, deprecations, or silenced warnings in the diff.
- Blast Radius Report: `docs/blast_radius/NOUN_ASC_01_BLAST_RADIUS.md`.

## Discoveries

- **`Association` cannot be `Hashable`** where `Tunnel` is, because the
  embedded `LatticeAnchor` is not `Hashable` (`EstateTypes.swift:55` —
  Equatable/Codable/Sendable only). Same constraint `Proposal` hit in
  NOUN-PRO-01. Documented inline; Rust mirrors by deriving `PartialEq, Eq`
  not `Hash`. This is the load-bearing reason the mission's literal "mirror
  Tunnel" cannot be followed field-for-field on conformances.
- **`signal_sources_seen` is a bitset, not a contiguous field.** Unlike
  every other LocusKit operational axis (Tunnel/Proposal/KGFact all use
  contiguous named-enum fields), §2.4's association signal axis is a true
  bitset — multiple sources coexist on one row. Modelled as a Swift
  `OptionSet` / Rust newtype with `contains`, not an enum field extract.
  Future noun-operational work should expect bitset axes, not assume
  contiguous-field-only.
- **Schema placement: serialized-append, not list-adjacency.** "Mirror
  tunnels" was honoured structurally (column shape + edge indices); the
  `associations` table/indices were appended after the `proposals` block in
  both legs, per the mission's npr→nas→nlr serialization note, keeping the
  noun tables grouped (as `proposals` was appended after `kg_facts`).

## Outstanding (out of scope — not addressed)

- **Pre-existing rust warning.** `rust/src/drawer_store_inmemory.rs`
  `let mut e1` in the `diary_round_trip_and_lastn_ordering` test
  (`unused_mut`). Present at baseline `93363c7` (NOUN-PRO-01 already noted
  it); unrelated to the association symbol. Left as-is per blast-radius
  discipline; my diff adds zero new warnings. A one-character cleanup
  mission could remove the `mut`.
- **`keys` table Swift/Rust divergence (pre-existing).** The Swift schema
  declares a `keys` table (ENC-01) the rust schema does not yet mirror;
  the rust `table_count_and_order` comment documents it. Unrelated to this
  mission; the association table was added to both legs symmetrically.
