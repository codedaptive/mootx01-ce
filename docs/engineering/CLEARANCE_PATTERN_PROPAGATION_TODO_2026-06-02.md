# Clearance Pattern — Propagation TODO

**Status:** open checklist · **Date:** 2026-06-02 · **Pairs with:** `CLEARANCE_CLAMP_DECISION_v1.0_2026-06-02.md`

This is a forward TODO, not a findings report. MOOTx01 is **pre-product** — there
are no live estates, no federation peers, no real classified data, and none of
the surfaces below are exposed to a caller today. The list exists so that, as
each surface is built or wired, it **adopts the clearance pattern at build time**
rather than being retrofitted later.

The clearance pattern is defined by CLEARANCE_CLAMP_001: a noun-agnostic
`sensitivity_clamp(adjective_bitmap, ceiling)` applied at the read boundary, with
a `ClearanceCeiling` that defaults to `Normal` (so any un-threaded path returns
`≤ Normal` by construction). Mission A builds that primitive; everything below
inherits it.

Nothing here is a bug, a leak, or a blocker. Items are unchecked work to do when
the relevant surface gets built.

---

## Active now (CLEARANCE_CLAMP_001 Mission A)

- [ ] **The five noun-scoped reads adopt the clamp.** `kg_facts_for_drawer`
  (`drawer_store_inmemory.rs:1463`), `proposals_for_target` (:1524),
  `associations_from`/`associations_to` (:1587/:1615),
  `learned_references_from_source` (:1679). Each noun carries a full
  `adjective_bitmap`; route their collection reads through the clamp so a
  recall returns `≤ ceiling` rows. (These are reachable only once the recall
  stubs flip live in Mission B, which is why the clamp lands first.)
- [ ] **Elevated-row conformance vectors — the one stage-independent item.**
  This is a correctness test of the primitive, not a product gate: an
  all-`Normal` corpus passes whether the clamp is wired or inert (`Normal` is
  both the default ceiling and the `from_raw` fallback), so the vectors **must**
  include `Elevated`/`Restricted`/`Secret` rows. Assert: elevated row absent
  under default `Normal` ceiling, present under an elevated ceiling. Both legs,
  drawer path + at least one noun path (kg_facts).

## Adopt-when-built (each surface, when it gains a live/exposed path)

- [ ] **Federation push** — `ConvergenceKit/rust/src/federation.rs` (`enqueue`
  ~:213, `push` ~:250). The sync engine is an API today with no live trigger
  (the MCP `moot_cross_estate_recall` tool is a stub: "grant model not yet
  built"). When federation is built out, `enqueue` adopts the exportability +
  sensitivity gate: reject `AdjectiveExportability::Private`, and reject
  `> Normal` sensitivity until the grant model supplies a clearance claim. A
  scaffold default (reject-Private at enqueue) can be baked in early as a
  placeholder if convenient — optional, not required.
- [ ] **VectorKit `find_nearest`** — `VectorKit/rust/src/vector_store.rs:224`.
  No live similarity surface today (`NearVector` returns a not-implemented
  error). When it gains one, add `adjective_bitmap` to the `vectors` table and
  filter on sensitivity (or post-filter against a gated drawer lookup), so ANN
  results don't surface rows above the ceiling.
- [ ] **MatrixTier fold** — `GeniusLocusKit/rust/src/training/pipeline.rs:76`.
  Internal-only today (no external egress). When the matrix tier gains any
  external surface, enforce the MATRIX_ACCESSOR_DECISION fold-from-recall rule:
  `EnrichmentPipeline` derives from clearance-bounded recall, not the raw audit
  log.

## Schema / architecture decisions (their own items)

- [ ] **DiaryEntry sensitivity axis.** `DiaryEntry` has `operational_bitmap`
  only — no sensitivity axis (`diary_entry.rs`). So it can't ride the clamp; its
  recall stays scoped/refused. Decide and document: is the absence deliberate
  (diary is agent-scoped, never classified), or does it need an axis? Decision
  doc before the noun is exposed.
- [ ] **CorpusKit chunks.** `chunks` table carries no sensitivity axis
  (`CorpusKit/rust/src/bundle_store.rs`); a chunk's sensitivity is implicitly
  its source drawer's. Decide whether chunks carry/inherit an axis when corpus
  egress is built. (`NodeBundleStore`/`ContainerFingerprintStore` hold only
  aggregate counts/fingerprints — no row content, nothing to gate.)

## Future: PersistenceKit RAM row-cache (when/if built)

Not a current feature — a forward note so the option stays open. A cache is safe
only by layering: hold **raw rows below every gate** (PersistenceKit stays
clearance-blind), never cache post-clamp results, and evict on write via the
existing `StorageObserver`. It becomes viable once the noun-scoped reads route
through the clamp (the active item above); the gate runs above the cache on every
read, so a cache hit is still clamped on the way out.

---

*Pointers above are convenience for the implementer, captured 2026-06-02 at main
`da4b1ce`. The pattern, not the line numbers, is the durable part.*
