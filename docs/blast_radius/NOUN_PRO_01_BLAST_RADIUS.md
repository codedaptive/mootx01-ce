# Blast Radius Report — NOUN-PRO-01 (Proposal noun substrate)

Mission: `docs/missions/inflight/MISSION_NOUN_PRO_01.md`
Stream: npr · Branch: stream/npr-proposal-noun-substrate
Baseline commit: `9037608` · Head: `3d6a43d`
Tier: **net-new (no-cap)** — net-new types + additive registration only.
No existing symbol's semantics changed; no deletions of behaviour.

## Status: COMPLETE — no RESCOPE required

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table listed 6 files. The real, in-scope blast radius is 12
files. The extra 6 are **additive registrations** that Parts 2 and 3 of
the mission explicitly require ("Mirror in the Rust schema", "Add store
read/write methods", "Rust suite mirrors Swift") but the table omitted.
Smythe pre-flight (YELLOW) confirmed these are within scope — purely
additive, mirroring how `kg_facts` is already registered — and do not
warrant a rescope. Documented here so the diff is fully accounted for.

| File | In mission table? | Change | Why in scope |
|---|---|---|---|
| `Sources/LocusKit/Proposal.swift` | yes (CREATE) | new type | Part 1 |
| `Sources/LocusKit/ProposalOperational.swift` | yes (CREATE) | new accessors | Part 1 |
| `rust/src/proposal.rs` | yes (CREATE) | new type | Part 1 |
| `rust/src/proposal_operational.rs` | **no** | new accessors | Part 1 rust leg of ProposalOperational; mirrors kg_fact_operational.rs split |
| `Sources/LocusKit/LocusKitSchema.swift` | yes (edit) | register `proposals` table + 3 indices | Part 2 |
| `rust/src/schema.rs` | **no** | register `proposals` table + 3 indices; update `table_count_and_order` + `index_names_match_swift_order` tests | Part 2 "Mirror in the Rust schema" |
| `Sources/LocusKit/DrawerStore.swift` | **no** | add addProposal / getProposal / proposals(forTargetRowID:) + 2 helpers | Part 3 "Add store read/write methods" |
| `rust/src/drawer_store.rs` | **no** | add 3 trait default methods | Part 3 store methods, rust leg |
| `rust/src/drawer_store_inmemory.rs` | **no** | implement 3 methods + 2 helpers + 1 const + 1 import | Part 3 store methods, rust impl |
| `rust/src/lib.rs` | **no** | register proposal, proposal_operational, proposal_tests modules | required for the new rust files to compile |
| `Tests/LocusKitTests/ProposalTests.swift` | yes (CREATE) | conformance + store suite | Part 3 |
| `rust/src/proposal_tests.rs` | yes (CREATE) | store conformance suite | Part 3 |

## Symbols changed

- **No existing symbol's semantics changed.** Every edit to an existing
  file is additive: a new table appended to a `tables` list, new methods
  appended to a store / trait, new module declarations, and two rust
  schema tests updated to include the new `proposals` entries.
- New public surface: `Proposal`, `ProposalKind`,
  `ProposalTargetObjectType`, `ProposalConfirmationSource`,
  `ProposalGeneratedByClass`, `ProposalConfidenceBucket` (both legs);
  store methods `addProposal` / `getProposal` /
  `proposals(forTargetRowID:)` (Swift) and `add_proposal` /
  `get_proposal` / `proposals_for_target` (Rust trait + impl).

## Files NOT modified (per mission's MUST NOT list)

- `docs/validation/**` — untouched.
- `KGFact.swift`, `Tunnel.swift`, other existing noun types — read as
  templates only; not edited.
- The `kg_facts` table declaration — read as template; not altered.
- `SubstrateLib` bitmap primitives — used, not changed.

## Deliberate deviations from the KGFact template (documented inline)

1. **`Proposal` is not `Hashable`** (KGFact is). The embedded
   `LatticeAnchor` is `Equatable, Codable, Sendable` but not `Hashable`,
   so synthesised `Hashable` is unavailable. Rust mirrors: derives
   `PartialEq, Eq`, not `Hash`. Nothing keys a Set/dict on `Proposal`.
2. **`Proposal` carries a required `latticeAnchor`** that KGFact lacks —
   KGFact predates cookbook I-16; Proposal honours it (mission Part 3
   requires the absent-anchor → error test).
3. **Operational layout is the v0.36 6-bit cookbook §2.4 "Proposal
   operational"**, not KGFact's older 4-bit/3-bit internal layout. The
   mission designates §2.4 as the authority. EE's Brain-layer
   `ProposalKind` (by_reference_drift, tournament_update, …) is a
   different vocabulary at a different altitude and was intentionally
   NOT mirrored (Smythe confirmed).

## Pre-existing issue surfaced (out of scope)

`rust/src/drawer_store_inmemory.rs:2643` — `let mut e1` in the
`diary_round_trip_and_lastn_ordering` test triggers an `unused_mut`
warning. Byte-identical at baseline `9037608`; unrelated to the proposal
symbol (diary test). Left as-is per blast-radius discipline (genuinely
unrelated pre-existing issue). My diff adds zero new warnings.

## Test verification

- `swift test`: exit 0, **422** passed (402 baseline + 20). 0 warnings.
- `cargo test --lib`: exit 0, **367** passed (345 baseline + 22). 1
  pre-existing unrelated warning (above).
