# Smythe Pre-flight — NOUN-LRF-01

- **Mission:** LearnedReference noun substrate (type + table + store, both legs)
- **Branch:** stream/nlr-learnedref-noun-substrate
- **Verdict:** YELLOW (two independent instances, converged) — navigable; proceed with corrections.
- **Date:** 2026-05-30

## Verified

- **Baseline clean.** Swift 441 tests / 40 suites green; Rust 390 green at
  mission start. (The draft worry about a `countAssociations` compile breakage
  was false — no such reference exists.)
- **No prior art conflict.** No existing `*Learned*` files; worktree clean
  except the untracked mission file.

## Corrections required before Part 1 (all adopted)

1. **Field design.** The mission Context's KGFact-triple + `grounding_ref`
   sketch is not grounded. Follow arch spec §7.8.2 `LearnedReference
   {source, handle, mode, 3 bitmaps}`. No `GroundingSpec`/`groundingColumn`/
   `grounding_ref` exists in the codebase — do not add one. Operational bitmap
   per cookbook §2.4 (refresh_policy / drift_severity / mode / source), with
   `mode` in the bitmap, not a struct field.
2. **Schema version.** Actually 1 (not 4). Do **not** bump — declarative
   schema, no migration ladder (matches NOUN-PRO/ASC).
3. **Blast radius.** 6 listed → 8+ real. `DrawerStore.swift` (Swift store) and
   Rust `lib.rs` + `drawer_store_inmemory.rs` are unavoidable additive edits.
   `LocusKitStore.swift`/`locuskit_store.rs` do not exist — the store is
   `DrawerStore.swift` / `drawer_store_inmemory.rs`.

## Bilby's stated approach (adopted)

Follow spec §7.8.2 shape with `source → sourceCatalogID` (TEXT identifier; the
catalog type is unimplemented) and `handle` (TEXT); required `latticeAnchor`
(§2.7); three bitmaps with the §2.4 operational layout; mirror `Association`
structurally (the freshest anchor-correct noun). Files in order: type model
(Part 1), schema table (Part 2), store + conformance (Part 3). No verb
behaviour. No schema version bump.
