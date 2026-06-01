# Blast Radius Report — NOUN-LRF-01 (LearnedReference noun substrate)

- **Stream:** nlr
- **Branch:** stream/nlr-learnedref-noun-substrate
- **Base:** 816dbe2 (merge: NOUN-ASC-01)
- **Mission:** docs/missions/inflight/MISSION_NOUN_LRF_01.md
- **Date:** 2026-05-30

## Summary

Net-new LearnedReference noun substrate — type model, `learned_references`
table, and store persistence — in both legs (Swift + Rust), mirroring the
Association content+anchor noun. No verb behaviour. The mission predicted
**6 files**; the real blast radius is **11 files** (5 new, 6 edited). The
extra 5 edited files are the store-surface mirror + Rust module/trait wiring
that Part 3 ("store read/write") forces but the mission's "Files You Will
Modify" table under-listed. Smythe pre-flight (YELLOW) flagged this gap; all
extra edits are additive. No existing noun type, the `kg_facts`/`associations`
declarations, `docs/validation/**`, or `SubstrateLib` primitives were touched.

## Files — NEW (5)

| File | Purpose |
|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/LearnedReference.swift` | Value type (id, sourceCatalogID, handle, latticeAnchor, 3 bitmaps, addedBy/filedAt, tombstone reservation) |
| `packages/kits/LocusKit/Sources/LocusKit/LearnedReferenceOperational.swift` | §2.4 operational accessors: RefreshPolicy, DriftSeverity, LearnMode, LearnedReferenceSource |
| `packages/kits/LocusKit/rust/src/learned_reference.rs` | Rust type + operational accessors + inline conformance tests |
| `packages/kits/LocusKit/Tests/LocusKitTests/LearnedReferenceTests.swift` | Swift conformance (operational + store) |
| `packages/kits/LocusKit/rust/src/learned_reference_tests.rs` | Rust store conformance (mirror of Swift store suite, gate I-19) |

## Files — EDITED (6, all additive)

| File | Change |
|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/LocusKitSchema.swift` | + `learnedReferencesTable` decl, registered in `tables`, + 3 indices |
| `packages/kits/LocusKit/rust/src/schema.rs` | + `learned_references_table()`, registered in `schema()`, + 3 indices, + 2 conformance-test list entries (`table_count_and_order`, `index_names_match_swift_order`) |
| `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift` | + `addLearnedReference` / `getLearnedReference` / `learnedReferences(forSourceCatalogID:)` + `learnedReferenceValues` / `learnedReferenceFromRow` |
| `packages/kits/LocusKit/rust/src/drawer_store.rs` | + `use learned_reference::LearnedReference`, + 3 trait method default impls |
| `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` | + import, + `T_LEARNED_REFERENCES` const, + 3 trait method impls, + `learned_reference_values` / `learned_reference_from_row` |
| `packages/kits/LocusKit/rust/src/lib.rs` | + `pub mod learned_reference;`, + `#[cfg(test)] mod learned_reference_tests;` |

Diff: 0 deletions; all changes are additions. Existing behaviour preserved.

## Symbols changed in existing code

- `LocusKitSchema.schema` (Swift) / `schema()` (Rust): additive — register the
  `learned_references` table alongside the others, position 8 (after
  `associations`, before `node_bundles`) on both legs so the
  `table_count_and_order` conformance stays symmetric.
- `DrawerStore` (Swift) / `DrawerStore` trait + `InMemoryDrawerStore` (Rust):
  additive — three new methods + private mappers. No existing method touched.
- `lib.rs` module registry: additive — two new `mod` declarations.

## NOT touched (confirmed)

- `docs/validation/**` — out of scope.
- Existing noun types: `KGFact.swift`, `Tunnel.swift`, `Association.swift`,
  `Proposal.swift` (read as templates only).
- `kg_facts` / `associations` table declarations — read as templates.
- `SubstrateLib` / `substrate_kernel` bitmap primitives — used, not changed.
- Schema version — **not bumped** (declarative schema, no migration ladder;
  matches NOUN-PRO-01 / NOUN-ASC-01). Stays version 1 both legs.

## Risk notes

- Field shape departs from the mission Context's KGFact-triple/`grounding_ref`
  sketch and follows the architecture spec §7.8.2 LearnedReference
  (`{source→sourceCatalogID, handle, mode}`) + cookbook §2.4 operational
  bitmap. "Source is ground truth" per the mission Read First. No
  `grounding_ref` column (no `GroundingSpec`/`groundingColumn` exists in the
  codebase). See completion report Decisions.
- `mode` (cookbook §2.4 bit 12) lives in `operationalBitmap`, not as a struct
  field — consistent with every other LocusKit noun.
