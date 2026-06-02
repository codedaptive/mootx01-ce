---
id: MATRIX_ACCESSOR_DECISION_v1.0_2026-06-02
date: 2026-06-02
status: decision
scope: packages/kits/GeniusLocusKit, packages/kits/CognitionKit
relates_to:
  - docs/status/AR_FCA_CAPABILITY_001_COMPLETION.md  (the worker-proposal ruling this re-adjudicates)
  - LENS_DISCOVERABILITY_DECISION_v2.0_2026-06-02.md  (honest naming; catalog parity)
---

# Matrix-Tier Accessor — Blocked; the Fold Stands

Independent Kong review (root-level) of GLK_MATRIX_ACCESSOR_001:
should AssociationRules (and future matrix-consuming lenses) read a new
GLK accessor over the live `MatrixTier`, or keep the recipe-side fold
from recalled drawers?

## Decision

**The fold stands. The accessor is BLOCKED — a correctness gate, not a
backlog item.**

The decisive finding: `MatrixTier` and the `EnrichmentPipeline` that
feeds it have **zero sensitivity awareness** — the fold over the audit
log consults only fieldPath/bitmap/value, never `adjectiveSensitivity`
(EnrichmentPipeline.swift:188–250; both legs mirror). Recall IS the
access gate (`Filter.sensitivityAtMost`, the documented
clearance-bounding filter). The recipe-side fold builds co-occurrence
from RECALLED drawers, so a clearance-bounded recall correctly excludes
restricted/secret rows from the matrix. An accessor returning
`MatrixTier.coOccurrence` would surface co-occurrence contributed by
rows the same caller's recall is forbidden to see — leaking, through
aggregate statistics, exactly what the sensitivity gate exists to hide
(and `sensitivity:` is itself one of the mined label axes). Even a free
accessor would be wrong.

## Conditions (binding on any future live-tier work)

1. No matrix-tier accessor reaches the recipe surface until
   `MatrixTier` carries clearance-partitioned counts, or the accessor
   is provably scoped to a trusted non-recipe caller.
2. A live-tier capability, when wanted, ships as a **new-named recipe**
   (e.g. `accumulated_association_rules`) with its own descriptor in
   both catalogs — never a source-switch parameter on, or silent
   replacement of, `association_rules` (its shipped descriptor
   describes the recall-fold; honest naming: meaning changes ⇒ name
   changes).
3. Sequencing if pursued: Mission 1 clearance-partitions the tier
   (both legs, atomic, the hard part); Mission 2 ships the new recipe +
   accessor + catalog entries. Never bundled.
4. Swift-only exposure is rejected: the Rust tier exists
   (`GeniusLocusKit/rust/src/matrix/matrix.rs`, full parity), so the
   complete-vertical / no-FFI law applies with no exception.

## Facts that reshaped the brief

- The Rust GLK **has** the matrix tier (full parity incl. decay) — the
  accessor cost was exposure plumbing, not tier construction. Cost was
  never the blocker; the leak is.
- Two non-interchangeable co-occurrence types: SubstrateTypes `MatrixO`
  (packed 6-bit, what `mineAssociationRules` consumes) vs
  `MatrixTier.coOccurrence` (string-keyed, decayed Int64). Any accessor
  consumer owns a projection layer that B-1 constrains.
- The fold's N-semantics, stated plainly (also added to the
  INTERFACE): **N = recalled drawer count — a snapshot over the
  recalled frame, not estate-lifetime decayed history.**
- Next customer of the same seam: `LatentThemesLens` (its header
  already notes it builds co-occurrence from the recalled set with no
  tier plumbing). This decision is its pattern too.

## Prior ruling re-adjudicated

Bilby-as-Kong's AR_FCA_CAPABILITY_001 fold ruling is **AFFIRMED on
re-derived merits** — right destination for that mission's scope — but
reclassified from precedent to worker-proposal: it was the implementer
ruling on its own scope, and it missed the sensitivity leak (the
strongest argument FOR its own conclusion). Its queued follow-up
("expose coOccurrence + liveRowCount via a new GLK read verb") is
**amended to a BLOCKED finding** per condition 1 — as written, that
follow-up builds the leak.
