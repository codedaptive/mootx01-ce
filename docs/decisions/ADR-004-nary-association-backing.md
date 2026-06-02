# ADR-004 — N-ary Association Backing: Analytical Projection, Not a Persisted Noun

- Status: Proposed
- Date: 2026-06-01
- Deciders: Bob (Commander)
- Scope: the backing model for `AssociationArity.nAry` — LocusKit's `Association`
  noun (semantics only, no change), the substrate's fixed row model (no change),
  and the projection layer the discovery engines (`ar` pairwise rule mining,
  `fa` formal concepts — both pending parallel streams) will feed
- Evidence: `packages/kits/LocusKit/Sources/LocusKit/AssociationOperational.swift`
  (the existing arity flag — `AssociationArity { binary = 0, nAry = 1 }`, decoded
  from `operationalBitmap` at shift 18, width 2; its doc comment records that
  I-23 limits v1 associations to binary, with `.nAry` reserved for v2+),
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/RowBitmaps.swift`
  (the fixed row model — `fieldCount 36`, `bitsPerField 6`, `totalBits 216`,
  three flat Int64 bitmap columns),
  `packages/kits/LocusKit/Sources/LocusKit/Association.swift`
  (the persisted noun today: exactly two endpoints — source and target wing /
  room / optional drawer columns — plus a required lattice anchor defined per
  cookbook §2.7 / I-16 as the midpoint of its endpoints),
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixO.swift`
  (pairwise co-occurrence — a projection source; conceptually symmetric but
  stores both ordered pairs). Companion to ADR-003 (Datalog rule evaluation),
  which reads the same fact sources and records `ar`/`fa` as pending parallel
  streams.

## Context

**Decision in one line: an n-ary association is an analytical projection —
materialized on demand from pairwise and row-level evidence — not a persisted
noun; the `nAry` arity flag classifies a derived association, and the fixed
36-field × 6-bit row model is left untouched.**

The substrate already *declares* association arity. `AssociationOperational.swift`
defines `AssociationArity { binary = 0, nAry = 1 }`, decoded from the
operational bitmap at bits 18–19 (shift 18, width 2, raws 2–3 reserved, safe
fallback `.binary`). So "n-ary association" is an existing concept with a
reserved encoding — what has never been decided is how an n-ary association's
**variable-length member set** is represented. That is this ADR.

A binary association fits the model exactly: `Association` carries two fixed
endpoints (source and target wing / room / optional drawer id), three Int64
bitmap columns, and a lattice anchor defined as the midpoint of its (two)
endpoints. The substrate's row model is fixed-width by construction: the
abstract 36-field × 6-bit grid (216 bits across three flat Int64 columns —
`RowBitmaps`: `fieldCount 36`, `bitsPerField 6`; the named fields are ranges
at specific bit positions within that envelope) plus a fixed column set per
noun. An n-ary association `{A, B, C, …}` has a variable-length member set —
precisely the one shape that fits neither the fixed endpoint columns nor any
bitmap field. Something has to give, and there are exactly two candidate
backings:

1. **Persisted noun** — store the member set durably: a new n-ary association
   row plus variable-length membership storage (a membership/junction table,
   or an encoded member-list column), with its own wire representation, decay
   behaviour, and lifecycle.
2. **Analytical projection** — never store the member set. Materialize n-ary
   associations on demand from evidence the estate already accumulates, and
   let `.nAry` classify the derived value. Persisted associations stay binary
   (I-23 unchanged for the store).

### The projection sources (what a derived n-ary association is made of)

- **MatrixO** (`SubstrateTypes/MatrixO.swift`) — sparse pairwise co-occurrence
  counts keyed `(field_i, value_i, field_j, value_j)`. Conceptually symmetric;
  the reference stores both ordered pairs. Pairwise counts generate candidate
  member sets and bound their support from above (a set's true support cannot
  exceed the minimum of its pairwise counts) — but cannot confirm it.
- **Row replay** — re-scanning the estate's rows (and, where needed, the audit
  trail) to count how often *all* k members actually co-occur. This is the
  exact, authoritative source of true n-ary support, paid for at query time.
- **`fa` formal concepts** (pending parallel stream) — bounded formal concept
  analysis. A formal concept's extent is a maximal set closed under shared
  attributes — formal concepts *are* n-ary closures, which makes the `fa`
  engine the natural home for precomputed-but-still-derived n-ary structure.
- **`ar` association rules** (pending parallel stream) — pairwise/itemset rule
  mining over the same evidence; a generator of candidate n-ary groupings.

## Decision

**Analytical projection.** The five open decisions, resolved:

1. **Member-set representation.** A variable-length member set is never a
   stored row. An n-ary association is a transient, derived value materialized
   on demand by the projection layer (the discovery engines and any future
   query surface) from MatrixO candidates, `fa` concepts, and row replay. It
   lives in memory for the duration of its use and is recomputed, not synced.

2. **Relationship to the existing arity flag.** `AssociationArity.nAry`
   classifies a **derived** association: projection-produced association
   values carry `.nAry` in their operational bitmap to declare what they are.
   It does not point into new storage. Persisted association rows remain
   binary — I-23 ("v1 associations are binary") stays true of the store, and
   the v2+ reservation recorded in `AssociationOperational.swift` is honoured
   by the projection layer rather than by a schema change. The decode path
   (shift 18, width 2, fallback `.binary`) is untouched.

3. **Support semantics.** True n-ary support is **not** derivable from
   pairwise MatrixO alone — pairwise counts upper-bound a set's support but
   three-way (and higher) co-occurrence is strictly more information than its
   pairwise shadow. Support is therefore obtained in two tiers: MatrixO (and
   `ar` rules) generate candidates cheaply with an upper bound; **row replay
   confirms** with an exact count when exactness matters; and `fa`'s bounded
   formal concepts provide precomputed n-ary closures where the concept
   lattice already covers the question. Cheap-bound-then-exact-confirm, never
   a stored count that can silently go stale.

4. **Model integrity.** Preserved outright. No new table, no new column, no
   new bitmap field, no wire-format change, no change to the 36-field × 6-bit
   row envelope. The substrate's integrity argument — every noun is a
   fixed-width row over three Int64 bitmap columns — survives the arrival of
   n-ary associations because n-ary associations never become rows.

5. **Decay & lifecycle.** A projection has **no independent lifecycle**:
   nothing to decay, tombstone, or round-trip on the wire. Freshness is
   inherited from the sources — MatrixO decays under MatrixDecay (365-day
   half-life per cookbook §6.8), binary associations carry their own decay
   classes, and a projection recomputed today reflects today's estate. Member
   expunge is handled by construction: an expunged row simply stops appearing
   in replay and decayed counts, with no dangling membership row to reconcile.

### The persisted noun, weighed and rejected

Persisting the member set was seriously considered — it makes n-ary
associations directly addressable, recallable by id, and queryable without
recompute. It is rejected because every one of those conveniences is bought
with a structural cost:

- **It breaks the fixed row model.** A variable-length member set needs either
  a membership/junction table (a new one-to-many shape no noun currently has)
  or an encoded list column (an opaque blob the bitmap model cannot index).
  Either way the "every noun is a fixed-width row" invariant is gone.
- **It forces a parallel wire and persistence path.** Today's nouns serialize
  as fixed column sets; a member list needs its own encoding, versioning, and
  migration story for a structure that is derivable from data already on the
  wire.
- **It forces a parallel decay path.** Binary associations decay as single
  rows. A persisted n-ary noun must answer: does it decay as a unit, or
  per-member? What happens when one of five members is expunged — partial
  membership, tombstone the noun, or renormalize? All of that machinery exists
  to maintain a cache of something recomputable.
- **The lattice anchor does not generalize for free.** `Association` requires
  an anchor at the midpoint of its endpoints (§2.7 / I-16); a k-member noun
  needs a defined k-way anchor before it can even be inserted.
- **It stores what can be derived.** The projection sources exist or are
  landing (MatrixO shipped; `ar`/`fa` in flight). Persisting their closure
  trades a recompute cost for a permanent consistency burden — the classic
  derived-data mistake.

**Revisit trigger:** if on-demand projection proves too slow on a *real* query
path — measured, not anticipated — a future evidence-driven ADR may introduce
a bounded materialization (cache or persisted projection). That ADR would
start from benchmarks, not from this one's reversal.

## Consequences

- The `nAry` enum case gains defined semantics with zero code change now:
  follow-on missions implementing `ar`/`fa` and any projection surface know
  that `.nAry` marks derived values and that stored rows stay binary.
- LocusKit's schema, the wire format, and the decay machinery are untouched —
  no migration ever ships for this decision.
- N-ary queries pay recompute: candidate generation from MatrixO/`ar`, exact
  support by row replay. That cost is accepted and bounded by the revisit
  trigger above.
- The `fa` stream inherits a recorded role: its bounded formal concepts are
  the precomputed (but still derived, still source-decayed) n-ary structure.
  ADR-003's fact-source map is unaffected; derived n-ary values are integer-
  relational, consistent with ADR-001.
- A constraint lands on future work: any proposal to *store* an n-ary
  association must arrive as a new ADR with measurements, not as an
  implementation detail.

## Deferred / non-goals

None of the following is decided or built by this ADR; each is follow-on work:

- Implementing n-ary projection (the `ar` and `fa` streams already begin it).
- A hypergraph query API (and the magic-sets question it would reopen per
  ADR-003).
- Any persisted n-ary noun, membership table, or member-list encoding
  (prohibited absent the revisit trigger).
- Changing the arity bitmap layout, the `AssociationArity` enum, or I-23's
  v1-binary rule for stored rows.
- Projection performance benchmarks (they gate the revisit trigger, not this
  decision).
- A k-way lattice-anchor definition (only needed if a persisted noun ever
  returns).
