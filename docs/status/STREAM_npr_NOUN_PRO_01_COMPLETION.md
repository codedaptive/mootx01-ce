# COMPLETION: NOUN-PRO-01 — Proposal noun substrate (type + table + store, both legs)

**Status: COMPLETE**
Stream: npr · Branch: `stream/npr-proposal-noun-substrate`
Baseline: `9037608` · Head: `3d6a43d`
Mission: `docs/missions/inflight/MISSION_NOUN_PRO_01.md`
Date: 2026-05-30

---

## Summary

The `proposal` noun now has substrate behind it in both legs (Swift +
Rust), mirroring the `KGFact` row-shaped noun: a `Proposal` type model,
a `proposals` schema table, and store persistence. A `Proposal` row
round-trips byte-identically through both stores. No verb behaviour is
implemented — the recall/mutate/withdraw/expunge verb missions can now
target `proposal`.

The Proposal operational bitmap follows cookbook §2.4 ("Proposal
operational", v0.36 6-bit layout); the required lattice anchor follows
cookbook §2.7 (I-16). EE's Brain-layer `ProposalKind` is a different
vocabulary at a different altitude and was intentionally not mirrored.

## What Was Done

- **Part 1 — type model, both legs** — `e3abf56`
  - `Proposal.swift` / `proposal.rs`: id, targetRowID, justification,
    candidateState, required `latticeAnchor`, three Int64 bitmaps,
    filedAt; `state` accessor (adjective bits 0–5, cookbook §2.3).
  - `ProposalOperational.swift` / `proposal_operational.rs`: five §2.4
    axes — ProposalKind (0–5), ProposalTargetObjectType (6–11),
    ProposalConfirmationSource (12–17), ProposalGeneratedByClass
    (18–23), ProposalConfidenceBucket (24–29, scale-gapped). Accessors
    mirror the KGFactOperational pattern, safe-fallback to the zero case.
  - `lib.rs` registers the two new rust modules.
- **Part 2 — proposals schema table, both legs** — `78960c1`
  - `proposals` table registered in `LocusKitSchema.swift` + `schema.rs`,
    mirroring `kg_facts`: bitmap columns, candidateState bitmap, the
    lattice-anchor quartet (udcCode NOT NULL DEFAULT '' + udcFacets +
    wikidataQID + wikidataQidsSecondary), filedAt, ext json. Generated
    column `g_state_cluster` + three indices (target, udcCode,
    state_cluster). Rust `table_count_and_order` +
    `index_names_match_swift_order` tests updated.
- **Part 3 — store + conformance, both legs** — `3d6a43d`
  - Swift `DrawerStore`: `addProposal` / `getProposal` /
    `proposals(forTargetRowID:)` + value/row helpers. Lattice anchor
    required (empty `udcCode` → `invalidContent`); `targetRowID` not
    required (brand-new-object proposals).
  - Rust `DrawerStore` trait + `InMemoryDrawerStore` impl: `add_proposal`
    / `get_proposal` / `proposals_for_target` + helpers.
  - `ProposalTests.swift` (+20) and `proposal_tests.rs` (+8) store/
    conformance; operational + type conformance mirrored inline in
    `proposal_operational.rs` (+9) and `proposal.rs` (+5).

## Test Verification Log

### Baseline (mission start, commit 9037608)
- `swift test`: exit 0, **402** passed.
- `cargo test --lib`: exit 0, **345** passed.

### Final (commit 3d6a43d)
- Command: `cd packages/kits/LocusKit && swift test`
  - Exit code: **0**
  - Pass count: **422** (402 baseline + 20 ProposalTests)
  - Tail: `Test run with 422 tests in 39 suites passed`
  - `swift build` warnings: **0**
- Command: `cd packages/kits/LocusKit/rust && cargo test --lib`
  - Exit code: **0**
  - Pass count: **367** (345 baseline + 22: proposal.rs 5, proposal_operational.rs 9, proposal_tests.rs 8)
  - Tail: `test result: ok. 367 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`
  - Warnings: **1**, pre-existing + unrelated (see Discoveries).

Coverage achieved: round-trip persist/fetch (both legs); four-bitmap
byte-identity; lattice-anchor-required (absent → error, both legs);
index resolution via `proposals(forTargetRowID:)` /
`proposals_for_target`; full §2.4 operational conformance (raw values,
field positions, scale-gap fallbacks, composite round-trip); empty-target
allowed; miss returns nil/None; table isolation.

## Smythe Pre-flight

Verdict: **YELLOW — clear to proceed**, no RESCOPE.
- Confirmed net-new (`find … -iname '*Proposal*'` empty), KGFact
  templates match mission claims, cookbook §2.4 + §2.7 present.
- Flagged the mission's "Files You Will Modify" table as incomplete: it
  listed 6 files; the real additive blast radius is 12 (the extra 6 are
  the rust schema mirror, both store legs, lib.rs, proposal_operational.rs
  — all required by Parts 2/3, purely additive). Confirmed within scope.
- Confirmed Proposal carries `latticeAnchor` as a first-class field
  (mission Part 3 test requires it) and that EE's Brain-layer ProposalKind
  is a distinct concept not to be mirrored.

## Adams Post-flight

Verdict: **PASS — CLEAN.** No findings (CRITICAL / WARNING / INFO all empty).
- §9 Blast Radius Verification: **PASS** — BRR accounts for all 12 files;
  no existing symbol's semantics changed; no prohibited patterns.
- §10 Test Execution Verification: **PASS** — independently re-ran both
  legs (Method B): swift exit 0/422, cargo exit 0/367, both MATCH. The
  single rust warning confirmed pre-existing (byte-identical at baseline)
  and unrelated.
- Verified §2.4 bitmap layout case-for-case (all five axes, both legs);
  Swift↔Rust parity; lattice-anchor enforcement both legs; schema tests
  correctly updated.

## Self-review

- Diff (12 files, 1931 insertions, 2 deletions) matches the BRR
  MUST_UPDATE list exactly. All changes additive; no existing symbol
  semantics altered.
- No bridges, shims, TODOs, deprecations, or silenced warnings in the diff.
- Blast Radius Report: `docs/blast_radius/NOUN_PRO_01_BLAST_RADIUS.md`.

## Discoveries

- **Mission file-table drift.** The mission's "Files You Will Modify"
  table (6 files) under-specifies the real additive blast radius (12).
  Parts 2 and 3 require the rust schema mirror, both store legs, lib.rs
  registration, and the rust ProposalOperational file, none of which the
  table listed. Future noun-substrate missions should list all 12-shaped
  files (Swift type + operational, rust type + operational, both schema
  legs, both store legs, lib.rs, both test files) so the table matches
  reality. Surfaced for the mission-authoring lane (Skippy).
- **Two `LatticeAnchor` types coexist.** `SubstrateTypes.LatticeAnchor`
  (numeric udcCode/qidPointer, used by the audit write path) and the
  LocusKit `EstateTypes.LatticeAnchor` (string udcCode + enrichment, the
  Frame/Drawer anchor). Proposal uses the latter (the noun-row anchor),
  matching how drawers store their anchor.
- **`Proposal` cannot be `Hashable`** where `KGFact` is, because the
  embedded `LatticeAnchor` is not `Hashable`. Documented inline; rust
  mirrors by deriving `PartialEq, Eq` not `Hash`.

## Outstanding (out of scope — not addressed)

- **Pre-existing rust warning.** `rust/src/drawer_store_inmemory.rs`
  `let mut e1` in the `diary_round_trip_and_lastn_ordering` test
  (`unused_mut`). Byte-identical at baseline `9037608`; unrelated to the
  proposal symbol. Left as-is per blast-radius discipline (genuinely
  unrelated pre-existing issue); my diff adds zero new warnings. A
  one-character cleanup mission could remove the `mut`.
- **`keys` table Swift/Rust divergence (pre-existing).** The Swift schema
  declares a `keys` table (ENC-01) the rust schema does not yet mirror.
  Unrelated to this mission; noted because the rust `table_count_and_order`
  comment now references it.
