---
title: GeniusLocus Engineering Specification Cookbook
version: 1.3.0
status: accepted-1.1-target
description: "The substrate math contract: every conformance-gated primitive, its algorithm, and its cross-language reference behavior. Math-first, annotation only where needed to implement; integrates the mathematical canon, the conformance harness (23 cross-language-pinned primitives), and the Clock Triangle, Capture Genesis Event, Row Identity UUID, and SubstrateLib four-package decisions. An implementer reads it once and ships code."
author: MOOTx01 maintainers
date: 2026-07-20
relates_to:
  - docs/engineering/HARNESS_REFERENCE.md (the 23 conformance-gated primitives, agentic discovery index)
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md (cross-cutting system, identity, persistence, and federation rules)
  - docs/engineering/SUBSTRATE_PERFORMANCE_GATE.md (measured backend and performance authority)
---

# GeniusLocus Engineering Specification Cookbook

## §0. Frame

This document specifies the v1.0 GeniusLocus substrate at
implementation grade. It is a contract plus the algorithms that
satisfy the contract. An implementer reads this and ships code.

**Relation to v0.36.** Where this document is silent, v0.36 applies.
Where this document amends v0.36, the amendment supersedes. v0.36
content carried forward unchanged retains its v0.36 section
numbering for stability of external references.

**What changed in v1.0 (since v0.36).**

The v1.0 release integrates four decisions and the conformance
harness work into the math spec. New material is concentrated in
§5 (audit log), §2.3 (the `sealed` adjective bit), and the new
§20 (library split). §18 (conformance) is rewritten around the
harness gate, and §19 (out of scope) is trimmed of items that
v1.0 brings in scope.

1. **Clock Triangle decision integrated (new §5.6 through §5.10).**
   The HLC generator is placed in SubstrateLib as a substrate
   atomic (§5.2); a single-maker guard prevents two clocks from
   advancing over one log (§5.6.1); the integrity triangle
   (plaintext HLC + content+HLC seal + companion HLC seal) is
   specified at §5.7; custody mode (strict vs lazy) is a per-moot
   setting at §5.8; the three time concepts (empirical, origin
   HLC, ingest HLC) are kept distinct at §5.9; federation events
   carry the origin triangle verbatim and the receiver wraps with
   its own (§5.10).

2. **Capture Genesis Event decision integrated (§5.3, §10.1).**
   The capture verb writes one sealed event into the audit log
   with `prior = none`, through the same `AuditGate` every
   mutator passes through. The audit log is now genuinely the
   source of truth — `project_state_at(row, T)` does not need a
   live-row seed for any T ≥ the genesis HLC. `bitmap_audit` and
   `provenance_audit` tables, triggers, and types are retired.

3. **Row Identity UUID decision integrated (§2 and §16).** Every
   synced or audited row's identity is a UUID. Deterministic ids
   from natural keys (e.g. sourceFile + chunkIndex) derive a
   UUIDv5-style hash rather than supplying a free string. The
   audit write path requires the row id to parse as a UUID and
   fails loudly otherwise.

4. **Substrate four-package split (new §20).** The substrate
   ships as four packages: SubstrateTypes (pure data, zero
   compute), SubstrateKernel (bandwidth-bound bit operations,
   the §17.6 measured hot-path kernels), SubstrateML (cold-
   path / dreaming algorithms), and SubstrateLib (the retained
   orchestration layer — nine-verb mechanics, row-state automaton,
   AuditGate — over the other three). Kits depend on whichever
   combination they need. This makes I-25 (one implementation
   per atomic) explicit in the build graph.

5. **Conformance harness at 23 primitives (rewritten §18).** The
   v1.0 conformance gate is 23 cross-language-pinned primitives,
   four-way byte-identical between Swift and Rust on each
   primitive's canonical test vector. (Grown to 24 post-v1.0: the
   F18.2b promotion adds `bit_field_masked_equals` at CRC
   0x54f6c65f; see §18.2.) `HARNESS_REFERENCE.md` is the agentic
   discovery index — every kit and every future port consults it
   first to avoid reinventing the wheel (I-25 enforcement).

6. **`sealed` adjective bit 27 (amends §2.3).** Adjective bit 27
   is the substrate's seal trust hint. The cumulative used count
   in the adjective bitmap rises from 26 to 27; reserved drops
   from 38 to 37. Verification table §2.8 has one new row.

7. **New invariants I-26 through I-30 (added to §1 and the
   relevant sections).** I-26 (capture emits a gated genesis
   event); I-27 (integrity triangle: three cross-checking legs);
   I-28 (single clock maker per log); I-29 (row identity is a
   UUID); I-30 (the substrate ships as four packages). These
   join I-15 through I-25 of v0.36 and I-1 through I-14 carried
   from v0.35.

8. **Pending work resolved (Appendix A).** Open questions
   resolved by the four decisions are marked closed in Appendix
   A. Resolutions: capture genesis path, audit-log-as-source-of-
   truth model, library boundary, row identity model.

**What was in v0.36 (carried forward unchanged unless this
document amends).**

1. Bitmap field-width floor raised from 4 to 6 bits (§2.2; Pivot 2).
2. 256-bit epistemic fingerprint added as a row column (§3; Pivot 3).
3. Bit-sliced canonical runtime view (§4; Pivot 1) replaces row-major
   working set.
4. Portable kernel layer (§4.4; Pivot 4).
5. Memory-mapped working set, SQLite as durability tail (§4.2-§4.3;
   Pivot 5).
6. New noun type: AmbientSample (§2.6).
7. Lattice anchor required on all noun types (§2.7), correcting v0.35
   §5.8 ambiguity for non-Drawer nouns.
8. Audit log explicitly framed as event-sourced CRDT (§5).
9. Tier-3 matrix tier specified: F, C, O, T, calibration curves,
   Bradley-Terry weights (§6).
10. Row-state finite-state automaton formalized with
    reachability/liveness/safety proofs (§9).
11. 14 new CognitionKit primitives (§11).
12. Federation primitives specified (§12), including pairing algebra,
    tier-ascending queries, and (ε, δ)-DP modifications.
13. Portable Cognition Bundle export/import format (§13).
14. ActuatorKit interface for closed-loop action (§14).
15. Dreaming daemon update rules (§15).
16. Bitmap-field constants verification table (§2.8) and two critical
    issues from v0.35 resolved (§2.9).

**Constitutional core (extended for v1.0).** I-1 through I-14 of
v0.35 §3 continue to hold. I-15 through I-25 of v0.36 are carried
forward. I-26 through I-30 are introduced in v1.0:

- **I-26.** Capture emits a gated genesis event (§5.3, §10.1).
- **I-27.** Integrity triangle: every event carries plaintext HLC,
  content+HLC seal, and companion HLC seal; tampering with any
  corner makes the other two disagree (§5.7).
- **I-28.** Single clock maker per log; second `open` is refused
  and a takeover is an explicit logged operation (§5.6.1).
- **I-29.** Every synced or audited row's identity is a UUID
  (§2.1, §16).
- **I-30.** The substrate ships as four packages: SubstrateTypes,
  SubstrateKernel, SubstrateML, and the retained SubstrateLib
  orchestration layer (§20).

---

## §1. The substrate as a mathematical object

### §1.1. Seven aspects

The substrate is simultaneously:

1. **An event-sourced system whose audit log is a CRDT.** G-Set of
   immutable mutation events; current state is a deterministic
   projection (§5).
2. **A 3D binary tensor at runtime.** Indexed `[bitmap_column, field,
   bit_position, row]` (§4.1).
3. **A weighted typed evolving graph.** Drawers, Tunnels, KGFacts,
   AmbientSamples as nodes; Tunnels, lineage, co-activation as
   typed weighted edges (§7).
4. **A two-coordinate distance space.** Lattice (UDC + Wikidata,
   global, seed-free) and fingerprint (SimHash, scoped, seed-
   dependent) (§8.3-§8.4).
5. **A sparse-matrix cognition tier.** F, C, O, T, calibration
   curves, learned weights; incremental online learning (§6).
6. **A locality-sensitive hashing space.** 256-bit fingerprints in
   four 64-bit blocks; Hamming distance under hyperplane-seed-
   compatibility (§3).
7. **A constitutional vocabulary.** Nine verbs (§10), four adjective
   categories (v0.35 I-8), three bitmap columns (§2).

### §1.2. Twelve primitive operations

The substrate's complete primitive set. Every CognitionKit primitive
composes from this set.

| # | Primitive | Operation | Cost (1M-row estate) |
|---|-----------|-----------|----------------------|
| P1 | Bitmap filter | Tensor mask-AND-reduce | 50-500 µs |
| P2 | Hamming-NN | Tensor XOR-popcount on fingerprints | 100 µs (top-K) |
| P3 | Lattice distance | UDC tree walk + Wikidata graph walk | 10-100 µs per pair |
| P4 | Co-activation update | Sparse matrix increment | <1 µs |
| P5 | Bradley-Terry update | Gradient step on weight vector | <1 µs |
| P6 | OR-reduction | Bitwise OR over fingerprint set | <1 µs per pair |
| P7 | SimHash | Random projection over feature vector | 200-500 ns batched |
| P8 | Matrix decay | Multiplicative lazy update | <1 µs per entry |
| P9 | NMF | Alternating least squares | 1-10 s (dreaming) |
| P10 | FFT | Discrete Fourier transform | 10-100 µs |
| P11 | Entropy/MI/KL | Distribution-summary scalar | 10-100 µs |
| P12 | Eigenvalue centrality | Power method on sparse graph | 100 ms - 1 s (dreaming) |

P1-P8 are hot-path primitives; P9-P12 are cold-path primitives that
the dreaming daemon runs and caches.

### §1.3. Five refusals

The substrate explicitly does not provide:

1. **Lossy mutation.** Audit log is append-only (CRDT G-Set, §5).
2. **Hidden cognition state.** Every matrix entry and learned weight
   is exposable via CognitionKit (§11).
3. **Implicit cross-perimeter operation.** Fingerprints under
   different seeds are incomparable; federation requires explicit
   seed exchange (§12.2).
4. **Server-side dependence.** Local-first; CRDT properties enable
   offline operation with eventual reconciliation (§5.4).
5. **Model-resident cognition.** Matrices live in the substrate, not
   the LLM's weights (§6).

### §1.4. One implementation per atomic (I-25)

**I-25. Every substrate atomic lives in SubstrateLib and is consumed
by name.** A substrate atomic is any operation on the bit shape of a
row or the content identity of an event: bitfield extract/write,
bitmask, shift, AND / OR / XOR, popcount, Hamming distance,
fold / reduce, the SHA-256 content hash, and the Hybrid Logical Clock.
No kit reimplements these — not one line. Kits call the named
SubstrateLib operation (`BitField.extractField`, `SHA256.hash`,
`HLC.wireBytes`, the §3 fingerprint family, the §8 reductions) and
supply only the cookbook-named shifts, widths, and field meanings.

This generalizes M1: SubstrateLib does not merely *specify* the math,
it *executes* it. Three consequences:

1. **One change propagates.** A bit-layout or hash change is one edit
   in one library; every kit follows without a per-kit sweep.
2. **One kernel layer.** Centralizing the single-row atomics is the
   precondition for lifting the bulk paths (OR-reduction, Hamming
   batch, popcount batch) into a portable SIMD / Metal / NEON kernel
   (§4.4, I-19).
3. **One hard port.** SubstrateLib is the only difficult port. Once
   its conformance corpus passes on a new platform, every kit works
   there with no per-kit re-verification — the conformance corpus *is*
   the portability contract.

Reference instances: `BitField` (the §2.3 / §2.4 / §2.5 packed-row
field operations and the §2.8 verification table), `SHA256` (the §5.1
audit content address), `HLC` (the §5.2 ingest clock and the §5.6
HLCGenerator primitive). SQL generated columns that express bit
predicates inside the storage engine are exempt — they are
storage-engine expressions, not kit code.

The conformance gate (the harness at
`docs/validation/substrate_math_performance/test-harness/`) IS the
enforcement mechanism for I-25. Each of the 23 atomics it pins
(see `HARNESS_REFERENCE.md`) has exactly one
canonical Swift implementation and one canonical Rust
implementation; the CRC seal proves they compute the same
function. A kit that reimplements one of these primitives has
written code that cannot be conformance-checked against the gate
— which is the operative definition of a non-conforming kit.

---

## §2. Data model

### §2.1. Row layout (v1.0)

Every substrate row carries:

```
Row layout (v1.0):
  id                   UUID         (I-29; row identity is a UUID)
  adjective_bitmap     Int64        (§2.3, bit 27 sealed added v1.0)
  operational_bitmap   Int64        (§2.4)
  provenance_bitmap    Int64        (§2.5)
  fingerprint          Int8[32]     (256 bits, §3)
  lattice_anchor       Reference    (UDC + optional Q-ID, §2.7)
  -- structured-tier columns (v0.35 §5.9 unchanged)
  -- blob-tier columns (v0.35 §5.10 unchanged)
```

**I-29. Row identity is a UUID.** Every row identifier — the
primary key column, the audit event identifier seal, the CloudKit
`recordName` for synced rows — is a UUID. Deterministic identity
for ingest-from-natural-key callers (e.g. `sourceFile +
chunkIndex`) derives a deterministic UUID via UUIDv5-style hash
rather than supplying a free string. The audit write path
requires the row id to parse as a UUID and fails loudly otherwise.

Background: CloudKit's `CKRecord.ID.recordName` replaces a
non-UUID-parseable string with a freshly-generated UUID on
receive, silently breaking identity round-trip — convergence
fails for that row with no exception thrown. The UUID-everywhere
contract closes that path.

Bitmap-tier size per row: 192 bits (3 × Int64) + 256 bits
(fingerprint) = 448 bits = 56 bytes. Plus 16 bytes lattice anchor
reference = 72 bytes hot-path-resident per row. A million rows fits
in 72 MB hot-path-resident.

### §2.2. 6-bit field-width floor (I-15)

**I-15. Bitmap field width floor is 6 bits.** Adjective fields,
operational fields, and provenance fields are at least 6 bits wide
at v0.36, admitting 64 values per field. Fields wider than 6 bits
remain wider; fields previously 4 bits in v0.35 widen to 6 bits
with the v0.35 raw values left-shifted (or remapped per the
encoding tables below).

This supersedes v0.35 I-9.

**Rationale (one paragraph, then math).** 4-bit fields exhausted
state-category headroom (v0.35 used 10 of 16 state values). 6-bit
fields restore 30%+ growth room across all categories per v0.35
I-10. Total bitmap-tier bits per row remain 192 (three Int64s);
the gain is bits packed within each Int64.

### §2.3. Adjective bitmap (v0.36)

```
adjective_bitmap (Int64), low-to-high:
  Bits 0–5   (6 bits): State          [temporal,  gradient]
                       Cluster A (active/becoming):
                         0=active 1=pending 2=contested 3=accepted
                       Cluster B (superseded/historical):
                         16=superseded 17=decayed 18=withdrawn 19=expired
                       Cluster C (terminal):
                         32=rejected 33=tombstoned
                       4–15, 20–31, 34–63 reserved (per-cluster
                       growth; clusters at threshold boundaries 0,
                       16, 32 for mask-stable cluster queries)

  Bits 6–11  (6 bits): Sensitivity    [spatial,   scale-gapped]
                       0=normal  16=elevated  32=restricted  48=secret
                       1–15, 17–31, 33–47, 49–63 reserved

  Bits 12–17 (6 bits): Exportability  [spatial,   scale-gapped]
                       0=private  32=public
                       1–31, 33–63 reserved

  Bits 18–23 (6 bits): Trust          [empirical, gradient]
                       0=verbatim 1=observed 2=imported
                       3=canonical 4=derived 5=proposed
                       6=ambient (NEW, see §2.5)
                       7–63 reserved

  Bit  24    (1 bit):  State-extension flag (see §2.9 issue C2)
  Bit  25    (1 bit):  Lineage-clustering flag (NEW)
  Bit  26    (1 bit):  dreaming_recalc_required flag (NEW in v0.36 F17)
                       Set synchronously by any operation that
                       invalidates the row's graph contribution
                       (redact/expunge, mass-mutation, lineage
                       rewrite). Cleared by the dreaming pass after
                       the affected neighborhood (keystones, tunnels,
                       associations, T-matrices, BT pairings,
                       fingerprint clusters) has been reconciled.
                       Worklist marker, not a state invariant — see
                       §9.5.1 for the content-vs-graph distinction.
  Bit  27    (1 bit):  sealed flag (NEW in v1.0; polarity 1 = sealed)
                       Cached assertion that a valid SHA-256 seal
                       exists for this row's most recent event.
                       Strict custody mints the seal at the write
                       and stamps 1; lazy custody stamps 0 at the
                       write and the dreaming pass flips it to 1
                       after computing the seal off the hot path.
                       Orthogonal to trust (bits 18-23) — a record
                       can be canonical-but-not-yet-sealed during
                       the unsealed window. The bit is a hint, not
                       the proof; the proof is the seal itself.
                       Set only by code that writes or verifies the
                       seal (never independently). See §5.7 for the
                       integrity triangle and §5.8 for custody mode.
  Bits 28–63 (36 bits): RESERVED for cross-noun adjective growth
```

Total used: 27 bits. Reserved: 37 bits. State cluster boundaries
sit at exact powers of two (0, 16, 32) so the cluster predicate
is a single bit-shift-and-compare:
`cluster_of(state) = state >> 4 & 0x3`.

### §2.4. Operational bitmap layouts (v0.36)

```
Drawer operational (empirical-dominant, 6-bit floor):
  Bits 0–5    capture_channel   [empirical, contiguous]
                                 0=typed 1=voiced 2=ocr 3=imported_file
                                 4=sensor 5=actuator (NEW, case 2)
                                 6–63 reserved
  Bits 6–11   content_kind      [empirical, contiguous]
                                 0=prose 1=code 2=transcript 3=list
                                 4=structured_json 5=image_caption
                                 6=fingerprint_only (NEW, AmbientSample)
                                 7=dataset (NEW, MX-TAB-3)
                                 8–63 reserved
  Bits 12–23  feature_flags     [empirical, bitset]
                                 bit 12 has_attachments
                                 bit 13 has_voice
                                 bit 14 has_image
                                 bit 15 has_links
                                 bit 16 is_pinned
                                 bit 17 is_keystone (NEW, §7.2)
                                 bit 18 is_locked_zone
                                 bit 19 has_current_representation (NEW)
                                 bit 20 is_vague (NEW §2.4.2)
                                 bit 21 represented_by_vague (NEW §2.4.2)
                                 bits 22–23 vague_level [2-bit field] (NEW §2.4.2)
  Bit  24     state_extension flag
  Bit  25     lineage_clustering flag
  Bits 26–63  reserved
```

#### §2.4.1. `has_current_representation` — bit 19 (NEW, 2026-07-28)

**Semantics.** Set iff the four distillation columns (`distilled`,
`distilled_pipeline_version`, `distilled_token_count`, `distilled_at`)
are all populated (i.e., the row carries a current distilled
representation). Clear when those columns are all NULL — either because
the row was never distilled, was reset by a content edit, or was cleared
by the expunge scrub.

The §4 invariant ("NULL together or populated together") means the bit
and the four columns can never skew: **set and clear travel in the same
SQL UPDATE statement** as the column writes. The bit is not a cache of
a query; it is a field on the row that moves with the data it reflects.

**Practical win.** Sweep eligibility (`distillItemsSweep`) and drain
accounting (`countUndistilled`) need not issue per-row `distilled IS NULL`
scans; a `(operationalBitmap & (1<<19)) == 0` bitmap predicate covers
all three concerns in a single index-friendly expression.

**Design tenet.** Using open bitmap space for new features eliminates
migration overhead. 1.0.x rows migrated to 1.1.x carry the bit clear
because their distillation columns are all-NULL: no schema change,
no backfill, no migration guard. The first successful distillation
cycle sets the bit as a natural part of writing the four columns.

**Wire value.** `1 << 19 = 524288 (0x80000)`.

**Invariants.**
- Set path: `setDistilledRepresentation` / `set_distilled_representation`
  — read-modify-write within one transaction. Never set outside this path.
- Clear paths (unconditional, same-statement): `withClearedRepresentation` /
  `insert_cleared_representation` call sites — content-edit (§7.3),
  expunge scrub (head + all lineage siblings), gate-reject scrub,
  `updateDatasetContent` / `patch_dataset_handle_content`.
- Migrated rows: clear at migration time. Bit enters clean on first
  distillation cycle. No migration SQL required.
- Estate-destruction bulk wipe (`wipe_all_content`) does not clear the
  bit; the estate is destroyed immediately after the wipe, so row state
  is never read again.

#### §2.4.2. Vague tier bits — bits 20–23 (Wave 2, 2026-07-29)

Three fields carved from the four reserved bits above bit 19. They
encode whether a drawer is a consolidated "vague" item, whether it
has been subsumed into one, and how deeply it is nested in the
vague hierarchy.

**Bit 20 — `is_vague`**

Set iff this drawer is a Wave-2 consolidated vague item: it was
synthesised from N ≥ 3 constituent episodic drawers by the
`consolidateTransactionally` path. Clear for every ordinary drawer.

Wire value: `1 << 20 = 0x100000`.

**Bit 21 — `represented_by_vague`**

Set iff this drawer is a constituent that has been absorbed into a
vague item. A drawer with this bit set is excluded from default
recall (`.recallTier(.currentAndVague)`) — callers must opt in with
`.recallTier(.all)` or `.recallTier(.currentOnly)` to retrieve it
directly.

Wire value: `1 << 21 = 0x200000`.

**Bits 22–23 — `vague_level` (2-bit field)**

Encodes nesting depth in the vague hierarchy:
- `0b00 = 0` — not vague (ordinary episodic drawer or unset).
- `0b01 = 1` — first-level vague item (constituents are ordinary
  drawers, `represented_by_vague = 1`).
- `0b10 = 2` — second-level vague item (at least one constituent is
  itself a vague item). The spec caps depth at 2 — vague items
  cannot consolidate into a level-3 item.
- `0b11` — reserved; never written; if read, treat as level 2.

Mask: `0xC00000`. Shift: 22. Decoded by
`BitField.extractField(operationalBitmap, shift: 22, width: 2)`.

**Invariants for all three fields.**

1. **Set path (is_vague + represented_by_vague):** Only
   `consolidateTransactionally` / `consolidate_transactionally` sets
   these bits. The write is atomic: vague capture + N `_consolidated_from`
   tunnels + N constituent `representedByVague` bit-OR updates occur in
   one `storage.transaction(.serializable)`. Never set outside this path.

2. **Clear path (represented_by_vague):** `expungeGated` / `expunge_gated`
   — when expunging a vague item (`is_vague = 1`), the same transaction
   that tombstones the vague row clears `represented_by_vague` on all
   constituent rows discovered via `_consolidated_from` tunnels. One
   level per death; does not recurse into nested vague hierarchies.

3. **Fold-in (§5.1):** `foldIn` / `fold_in` is the ONLY mechanism that
   adds a new constituent to an existing vague item. It sets
   `represented_by_vague` on the new constituent and optionally updates
   `vague_level` on the vague item, all in one transaction.

4. **vague_level sync:** `vague_level` is set once at consolidation time
   (from the maximum `vague_level` of any constituent, plus 1). It does
   not update dynamically as constituents are added via fold-in.

5. **Level cap:** `consolidateTransactionally` rejects a cluster if any
   constituent has `vague_level = 2`. The rejection is logged (D10
   rejection counter) but does not crash.

6. **Migration:** 1.0.x rows carry `0` for all three fields — the bitmap
   bits are clear, which decodes as not-vague / not-represented /
   level-0. No backfill, no migration guard.

**Practical win.** The Fast Recall tier default (§4.2 — fourth
`insertDefaults` axis) inserts `.recallTier(.currentAndVague)` when no
tier filter is present. This predicate evaluates to:

```
include row iff: (operationalBitmap & 0x200000) == 0
```

i.e. exclude any row with `represented_by_vague = 1`. Vague items
themselves (`is_vague = 1`) pass because bit 21 is clear on them.
Ordinary drawers pass because neither bit is set. Only absorbed
constituents (bit 21 = 1) are excluded by the default.

```
Proposal operational (spatial-dominant, 6-bit floor):
  Bits 0–5    proposal_kind          [spatial, contiguous]
                                      0=new_tunnel 1=mutate_drawer
                                      2=withdraw_drawer 3=new_kgfact
                                      4=association_promotion
                                      5=mining_pattern_adjustment
                                      6=action_proposal (NEW, case 2)
                                      7=record_observation (NEW)
                                      8=tier_advisory (NEW, case 3)
                                      9–63 reserved
  Bits 6–11   target_object_type     [spatial, contiguous]
                                      0=drawer 1=tunnel 2=kgfact
                                      3=association 4=none-brand-new
                                      5=ambient_sample (NEW)
                                      6=system_state (NEW, case 2)
                                      7–63 reserved
  Bits 12–17  confirmation_source    [empirical, contiguous]
                                      0=human 1=agent
                                      2=automated_threshold
                                      3=actuator (NEW, case 2)
                                      4–63 reserved
  Bits 18–23  generated_by_class     [empirical, contiguous]
                                      0=dreaming_daemon 1=mcp_agent
                                      2=federation_sync 3=manual
                                      4=tier_aggregator (NEW)
                                      5–63 reserved
  Bits 24–29  confidence_bucket      [empirical, scale-gapped]
                                      0=null 8=low 16=medium
                                      32=high 48=verified
                                      Other values reserved
  Bits 30–63  reserved

Association operational (empirical-dominant, 6-bit floor):
  Bits 0–11   signal_sources_seen    [empirical, bitset]
                                      bit 0 co_recall
                                      bit 1 co_confirmed
                                      bit 2 dream_pairing
                                      bit 3 vector_similarity
                                      bit 4 shared_entity
                                      bit 5 explicit_human
                                      bit 6 fingerprint_similarity (NEW)
                                      bit 7 cross_estate (NEW, case 1)
                                      bit 8 cross_tier (NEW, case 3)
                                      bit 9 action_outcome (NEW, case 2)
                                      bits 10–11 reserved
  Bits 12–17  decay_class            [temporal, scale-gapped]
                                      0=pinned 16=slow 32=normal 48=fast
                                      Other values reserved
  Bits 18–19  arity                  [spatial, contiguous]
                                      0=binary 1=n-ary
                                      v1 always 0; v2+ may use 1
  Bits 20–63  reserved

LearnedReference operational (temporal-dominant, 6-bit floor):
  Bits 0–5    refresh_policy         [temporal, scale-gapped]
                                      0=none 16=monthly 24=weekly
                                      32=daily 48=on_demand 56=realtime
  Bits 6–11   drift_severity         [temporal, scale-gapped]
                                      0=none 16=minor 32=major 48=critical
  Bit  12     mode                   [spatial, contiguous]
                                      0=byReference 1=byIngestion
  Bits 13–18  source                 [empirical, contiguous]
                                      0=user 1=federation
                                      2=household_pairing (NEW, case 1)
                                      3=fleet_pairing (NEW, case 2)
                                      4=tier_inheritance (NEW, case 3)
                                      5=paired_estate (NEW)
                                      6–63 reserved
  Bits 19–63  reserved

AmbientSample operational (NEW in v0.36, 6-bit floor):
  Bits 0–5    signal_dominance       [empirical, contiguous]
                                      0=hr 1=location 2=calendar
                                      3=screen_time 4=messages
                                      5=photos 6=music 7=weather
                                      8=system_load (case 2)
                                      9=system_io (case 2)
                                      10=system_network (case 2)
                                      11=auth_events (case 2)
                                      12–63 reserved
  Bits 6–11   temporal_bucket        [temporal, scale-gapped]
                                      0=night 8=early_morning 16=morning
                                      24=midday 32=afternoon 40=evening
                                      48=late_night 56=transition
  Bits 12–23  signal_sources_present [empirical, bitset]
                                      bit 12 hr_present
                                      bit 13 location_present
                                      bit 14 calendar_present
                                      bit 15 screen_time_present
                                      bit 16 messages_present
                                      bit 17 photos_present
                                      bit 18 music_present
                                      bit 19 weather_present
                                      bit 20 system_present (case 2)
                                      bits 21–23 reserved
  Bits 24–29  derived_state          [empirical, bitset]
                                      bit 24 anomalous
                                      bit 25 represents_transition
                                      bit 26 high_confidence
                                      bit 27 cross_device_synced
                                      bit 28 fleet_visible (case 2)
                                      bit 29 tier_contribution_pending
  Bit  30     locked_zone            (privacy-aware bucket)
  Bits 31–63  reserved
```

### §2.5. Provenance bitmap (v0.36 amendments)

```
provenance_bitmap (Int64), low-to-high (v0.35 §5.7 amended):
  Bits 0–5    source_type            [empirical, contiguous]
                                      0=user 1=observed 2=imported
                                      3=canonical 4=derived
                                      5=federation_aggregate (NEW)
                                      6=tier_aggregate (NEW, case 3)
                                      7=paired_estate (NEW, case 1)
                                      8=ambient (NEW, AmbientSample)
                                      9=actuator (NEW, case 2)
                                      10–63 reserved
  Bits 6–11   channel                [empirical, contiguous]
                                      0=ui_typed 1=ui_voiced 2=mcp_agent
                                      3=file_import 4=api_grounding
                                      5=federation_inbound
                                      6=dream_proposal
                                      7=dream_association
                                      8=dream_mining_result
                                      9–14 reserved
                                      15=device_sensor (NEW)
                                      16=actuator_outcome (NEW)
                                      17–63 reserved
  Bits 12–17  capture_channel        (mirrored to operational §2.4)
  Bits 18–23  confirmation           [empirical, contiguous]
                                      0=unconfirmed 1=user_confirmed
                                      2=automated_confirmed
                                      3=peer_confirmed (cross-estate)
                                      4=actuator_confirmed (NEW)
                                      5–63 reserved
  Bits 24–29  confidence             [empirical, scale-gapped]
                                      0=null 16=low 32=medium
                                      48=high 56=verified
  Bits 30–35  sensitivity_at_capture [spatial, scale-gapped]
                                      mirrors adjective sensitivity
  Bits 36–41  enrichment_status      [temporal, contiguous]
                                      0=none 1=qid_pending
                                      2=qid_completed 3=closure_cached
                                      4–63 reserved
  Bits 42–63  reserved
```

### §2.6. New noun: AmbientSample

```
AmbientSample {
  row_id              UUID
  bucket_start        Date (ISO8601, UTC)
  bucket_duration_ms  Int32   -- 30000 (system 30-sec) | 300000 (5-min)
  fingerprint         Int8[32]  -- 256 bits (§3)
  adjective_bitmap    Int64
  operational_bitmap  Int64    -- AmbientSample layout (§2.4)
  provenance_bitmap   Int64
  lattice_anchor      Reference  -- Q-ID of dominant context (§2.7)
  signal_sources      Int16     -- bitset; which streams contributed
  estate_uuid         UUID
}
```

Differences from Drawer (v0.35 §5.9):
- No `content` blob.
- No `lineage_id` (AmbientSamples are not versioned; superseded by
  retention compression, §3.9.4).
- `lattice_anchor` is required (correcting v0.35 §5.8 omission for
  non-Drawer nouns).

Constrained adjective values for AmbientSamples:
- `state` ∈ {active, superseded, decayed} only.
- `trust` = ambient (raw 6, new in §2.3).
- `sensitivity` = locked-zone-aware; default restricted (32).
- `exportability` = private (0) always.

### §2.7. Lattice anchor required on all nouns (I-16)

**I-16. Every row has a lattice anchor.** Drawers, Tunnels (anchored
to source drawer's anchor), KGFacts (anchored to subject's anchor or
own concept Q-ID), AmbientSamples (anchored to dominant-context
Q-ID), DiaryEntries (anchored to event Q-ID if applicable, else
estate's root), Proposals (anchored to target's anchor),
Associations (anchored to lattice-midpoint of endpoints),
LearnedReferences (anchored to the canonical concept).

Supersedes v0.35 I-5 (drawer-only) with universal scope.

Lattice anchor reference is 16 bytes: 8-byte UDC code (numeric) +
8-byte Q-ID-or-null pointer.

For AmbientSamples, the dominant-context Q-ID resolution rules:
1. If a calendar event dominates the bucket, the event's Q-ID
   (resolved via Wikidata SPARQL or local cache).
2. Else if a location-cluster dominates, the cluster's place Q-ID.
3. Else the Q-ID for "personal-time" (Q-IDs for everyday-life
   states from Wikidata's everyday-activity taxonomy).
4. Else the estate root anchor.

Resolution runs at fingerprint extraction time; cache hit rate is
high in practice.

### §2.8. Bitmap field constants — verification table

The v0.35 spec's bitmap encodings were verified against the
LocusKit Swift implementation during the 2026-05-16 session. Of 22
field-constant pairs (spec vs source), all matched. The table
below lists each verification (now updated for the v0.36 widths
and additions). The table is the conformance fixture; an
implementation passes only when every source constant matches the
table.

| # | Field | Spec value (v0.36) | Source location | Notes |
|---|-------|--------------------|------------------|-------|
| 1 | State.active | 0 | Adjectives.swift `StateField.active` | Cluster A |
| 2 | State.pending | 1 | Adjectives.swift `StateField.pending` | Cluster A |
| 3 | State.contested | 2 | Adjectives.swift `StateField.contested` | Cluster A |
| 4 | State.accepted | 3 | Adjectives.swift `StateField.accepted` | Cluster A |
| 5 | State.superseded | 16 | Adjectives.swift `StateField.superseded` | Cluster B (boundary) |
| 6 | State.decayed | 17 | Adjectives.swift `StateField.decayed` | Cluster B |
| 7 | State.withdrawn | 18 | Adjectives.swift `StateField.withdrawn` | Cluster B |
| 8 | State.expired | 19 | Adjectives.swift `StateField.expired` | Cluster B |
| 9 | State.rejected | 32 | Adjectives.swift `StateField.rejected` | Cluster C (boundary) |
| 10 | State.tombstoned | 33 | Adjectives.swift `StateField.tombstoned` | Cluster C |
| 11 | Sensitivity.normal | 0 | Adjectives.swift `Sensitivity.normal` | Scale-gapped |
| 12 | Sensitivity.elevated | 16 | Adjectives.swift `Sensitivity.elevated` | Was 4 in v0.35 |
| 13 | Sensitivity.restricted | 32 | Adjectives.swift `Sensitivity.restricted` | Was 8 in v0.35 |
| 14 | Sensitivity.secret | 48 | Adjectives.swift `Sensitivity.secret` | Was 12 in v0.35 |
| 15 | Exportability.private | 0 | Adjectives.swift `Exportability.private` | |
| 16 | Exportability.public | 32 | Adjectives.swift `Exportability.public` | Was 8 in v0.35 |
| 17 | Trust.verbatim | 0 | Adjectives.swift `Trust.verbatim` | |
| 18 | Trust.ambient | 6 | Adjectives.swift `Trust.ambient` | NEW |
| 19 | Provenance.sourceType.ambient | 8 | Provenance.swift `SourceType.ambient` | NEW |
| 20 | Provenance.channel.device_sensor | 15 | Provenance.swift `Channel.device_sensor` | NEW |
| 21 | Provenance.channel.actuator_outcome | 16 | Provenance.swift `Channel.actuator_outcome` | NEW |
| 22 | Drawer.feature_flags.is_keystone | bit 17 | DrawerOperational.swift | NEW |
| 23 | Adjective.dreaming_recalc_required | bit 26 | Adjectives.swift `Adjective.dreamingRecalcRequired` | NEW in v0.36 F17; cross-noun |
| 24 | Adjective.sealed | bit 27 | Adjectives.swift `Adjective.sealed` | NEW in v1.0; integrity-triangle hint |
| 25 | Drawer.feature_flags.has_current_representation | bit 19 (0x80000) | DrawerOperational.swift | NEW 2026-07-28; set iff distillation columns populated |
| 26 | Drawer.feature_flags.is_vague | bit 20 (0x100000) | DrawerOperational.swift | NEW 2026-07-29 §2.4.2; set iff this drawer is a Wave-2 consolidated vague item |
| 27 | Drawer.feature_flags.represented_by_vague | bit 21 (0x200000) | DrawerOperational.swift | NEW 2026-07-29 §2.4.2; set iff absorbed into a vague item |
| 28 | Drawer.feature_flags.vague_level | bits 22–23 (mask 0xC00000, shift 22, width 2) | DrawerOperational.swift | NEW 2026-07-29 §2.4.2; nesting depth 0–2 |

Implementations MUST surface this table as an automated conformance
test that fails when a source constant deviates from spec.

### §2.9. Resolved issues from v0.35

The 2026-05-16 bitmap-math review surfaced two critical issues
plus four advisory and four cosmetic. The two critical issues are
resolved as follows:

**C1 — `mutateAdjective` bypasses DrawerStateValidator.** v0.35's
LocusKit `mutateAdjective` write path did not invoke
`DrawerStateValidator`, so the row-state automaton (§9) could
reach forbidden states via mutation that were unreachable via
capture.

*Resolution.* In v0.36, every adjective-bitmap mutation MUST route
through `DrawerStateValidator.canTransition(from:to:via:)` before
the bitmap write commits. Failed transitions return
`SubstrateError.invalidStateTransition` and write no audit row.
LocusKit conformance: `mutateAdjective`, `mutateState`,
`mutateOperational`, and any future per-field mutate accessor
share the same validator entry point.

**C2 — `stateExtensionActive` spec contradiction.** v0.35 specified
the state-extension flag (adjective bit 16) as both "signals
state-field overflow available" and "triggers reinterpretation of
the state field as cluster index." These are not the same thing.

*Resolution.* In v0.36, bit 24 of the adjective bitmap is
`state_extension_flag` and signals only that the state field
should be looked up against an *extension table* held in the
structured tier (table `state_extensions`). The flag does NOT
reinterpret the state field; the state field's value continues to
encode the cluster boundary explicitly via the 0/16/32 thresholds
(§2.3). Extension is for adding new state values beyond the
reserved 30 (per cluster); the table maps overflow integers to
extension names. Implementations MUST treat bit 24 as a hint,
never as a state interpretation override.

Advisory items A1-A4 and cosmetic items K1-K4 from the review are
addressed inline at their relevant sections (see Appendix B for
the mapping).

---

## §3. The fingerprint

### §3.1. 256-bit four-block structure

Every row carries a 256-bit fingerprint, decomposed into four
64-bit blocks. Hamming distance over the full fingerprint is the
sum of per-block Hamming distances. Per-block distance is the
substrate's structural-coordinate-system primitive (§8.4).

```
fingerprint (256 bits):
  bits 0–63    Block 0 (Bitmap-LSH)    SimHash over the 192-bit
                                       row bitmap (adjective ∥
                                       operational ∥ provenance)
  bits 64–127  Block 1 (Lattice-LSH)   SimHash over UDC code prefix
                                       + Q-ID hash + Q-ID subclass
                                       closure (§3.3)
  bits 128–191 Block 2 (Lineage+Temp)  SimHash over lineage-UUID
                                       hash + capture-week bucket +
                                       defer-pattern + completion
                                       bucket (§3.4)
  bits 192–255 Block 3 (Channel+Src)   SimHash over provenance
                                       channel + source_type +
                                       capture_channel + sensitivity
                                       (§3.5)
```

### §3.2. Block 0 — Bitmap-LSH

Input vector v ∈ {0,1}^192: the concatenation of the three Int64
bitmap columns.

Construction:
```
for k in 0..63:
    h_k = manifest.H_0[k]    -- 192-bit ±1 hyperplane
    dot = popcount(v & h_k.positive_mask)
        - popcount(v & h_k.negative_mask)
    block0[k] = 1 if dot > 0 else 0
```

The hyperplane vectors `H_0[0..63]` live in the manifest, immutable
post-creation (see §16.1).

### §3.3. Block 1 — Lattice-LSH

Input vector w: concatenation of
- 16 bits: UDC code prefix bucket (4-digit prefix hashed via
  Fowler-Noll-Vo-1a; "to 16 bits" means the LOW 16 bits of the 64-bit
  FNV-1a hash, `hash64 & 0xFFFF` — never an XOR-fold)
- 16 bits: Q-ID direct hash (FNV-1a of the Q-ID integer; low 16 bits
  of the 64-bit hash, `hash64 & 0xFFFF`)
- 32 bits: Q-ID subclass closure hash (XOR of FNV-1a of each
  closure member's Q-ID, weighted by 1/depth, truncated to 32 bits)

Total: 64 bits of input. The closure traversal is bounded to depth
3 (configurable per estate). Cached per Q-ID in the
`qid_closure_cache` table; cache miss triggers Wikidata SPARQL or
local-dump query (cost ~50ms one-time).

Construction same as §3.2 but with 64-bit ±1 hyperplanes
`H_1[0..63]`.

This is the *taxonomic-neighborhood* block. Two rows with
related-but-not-identical Q-IDs have low Hamming distance on this
block.

### §3.4. Block 2 — Lineage + temporal

Input vector x: concatenation of
- 16 bits: lineage_id direct hash (FNV-1a; low 16 bits of the 64-bit
  hash, `hash64 & 0xFFFF`)
- 8 bits: capture-week bucket (weeks since 2020-01-01 modulo 256)
- 8 bits: defer-pattern hash (FNV-1a of defer-count sequence
  truncated to 8 bits; null/zero when no deferrals)
- 8 bits: completion bucket (4 hot/warm/cool/cold gradients in 8
  bits via scale-gapping)
- 24 bits: behavioral-recency vector (most-recent N user actions
  on this row hashed to 24 bits)

Total: 64 bits.

This block is what makes posture-aware retrieval work
(augmentation, leverage scoring) — it encodes "how the user has been
treating this row" not just "when it was captured."

### §3.5. Block 3 — Channel + source

Input vector y: concatenation of
- 6 bits: provenance channel (raw value, §2.5)
- 6 bits: source_type (raw value, §2.5)
- 6 bits: capture_channel (raw value, §2.5)
- 6 bits: sensitivity (raw value, §2.5)
- 8 bits: estate-uuid hash (low 8 bits of FNV-1a)
- 32 bits: stream-source bitset for AmbientSamples (zero for other
  nouns)

Total: 64 bits.

For non-AmbientSample nouns, the stream-source bitset is the null
hash (32 zero bits); the cross-noun Hamming distance over this
block remains well-defined.

### §3.6. SimHash construction algorithm

```
function simhash_block(v: BitVector, H: HyperplaneFamily) -> Int64:
    # H is a 64-element array of ±1 hyperplanes, each |v| bits wide,
    # stored as (positive_mask, negative_mask) pairs.
    result = 0
    for k in 0..63:
        dot = popcount(v AND H[k].positive_mask)
            - popcount(v AND H[k].negative_mask)
        if dot > 0:
            result = result OR (1 shifted_left_by k)
    return result

function compute_fingerprint(row: Row) -> Fingerprint256:
    v_bitmap   = concatenate(row.adjective, row.operational, row.provenance)
    v_lattice  = build_lattice_input(row.lattice_anchor)
    v_lineage  = build_lineage_input(row)
    v_channel  = build_channel_input(row)
    return Fingerprint256(
        block0 = simhash_block(v_bitmap,  manifest.H_0),
        block1 = simhash_block(v_lattice, manifest.H_1),
        block2 = simhash_block(v_lineage, manifest.H_2),
        block3 = simhash_block(v_channel, manifest.H_3))

# Batched implementation (preferred):
function compute_fingerprints_batch(rows: [Row]) -> [Fingerprint256]:
    # Vectorize across rows: process the same bit position k for
    # all rows in one SIMD lane group.
    # On Apple Silicon AMX or AVX-512 with VPOPCNTQ:
    # ~200ns per fingerprint amortized.
    ...
```

**Cost.** Unbatched: ~500ns per fingerprint on Apple Silicon.
Batched across 64+ rows: ~200ns per fingerprint amortized. At
ambient-capture volumes (1728 fingerprints/day per active user),
total compute: ~1ms/day. Bandwidth-dominated.

> **Phase 2 measurement note (added 2026-05-18).** The cookbook
> estimates above predate the Phase 2 kernel measurement work.
> Measured outcomes on apple-m5-max are 2-3x faster than the
> cookbook estimate: unbatched scalar Swift is ~166 ns per
> fingerprint, batched SimdKernel bulk is ~59 ns per input at
> bs=256. See §17.6 for the full reconciliation and per-kernel
> selection breakdown.

### §3.7. Hyperplane seed families (manifest)

Manifest keys (NEW in v0.36):

```
hyperplane_seeds {
  H_0: [Int8[24]; 64]    -- bitmap-LSH, 192-bit hyperplanes
  H_1: [Int8[8];  64]    -- lattice-LSH, 64-bit hyperplanes
  H_2: [Int8[8];  64]    -- lineage+temporal, 64-bit hyperplanes
  H_3: [Int8[8];  64]    -- channel+source, 64-bit hyperplanes
}
```

Storage: 24*64 + 8*64*3 = 1536 + 1536 = 3072 bytes per estate.
Generated at estate creation from a secure PRNG seeded by user
entropy plus estate_uuid; persisted; **never rotated** within an
estate version (rotation requires a new estate or a v2 migration).

Federation extends with additional families:

```
shared_hyperplane_seeds {
  H_shared_household:  HyperplaneFamily   -- case 1, when paired
  H_shared_fleet:      HyperplaneFamily   -- case 2, when paired
  H_shared_company:    HyperplaneFamily   -- case 3
  H_shared_industry:   HyperplaneFamily   -- case 3
  H_shared_msp:        HyperplaneFamily   -- case 3
}
```

Each is set via pairing handshake (§12.2) and is itself immutable
after handshake. Dissolution adds `dissolved_at` timestamp; the
seed is retained in the manifest for asOf-recall reconstruction
but no longer used for new fingerprints.

### §3.7.1. Hyperplane family generation

§3.6 specifies the per-block SimHash math (the ±1 hyperplane dot product
reduced to popcount form) and §3.7 names the manifest slot
`hyperplane_seeds.H_n`. This subsection specifies the missing link: how
a single u64 **hyperplane seed** deterministically generates the family
of 64 ±1-valued hyperplanes for one block. The procedure is integer-only
and platform-independent; two implementations producing the same seed
produce byte-identical families and therefore byte-identical
fingerprints.

The pipeline is three stages: **expand** the u64 seed to a 32-byte seed,
**initialize** a SplitMix64 generator from those 32 bytes, then **draw**
the 64 planes with a fixed two-draws-per-bit discipline.

#### Constants (hex)

| Constant | Value | Role |
|---|---|---|
| SplitMix64 increment ("golden gamma") | `0x9E3779B97F4A7C15` | added to state before each `next()` |
| SplitMix64 mix multiplier 1 | `0xBF58476D1CE4E5B9` | first avalanche multiply |
| SplitMix64 mix multiplier 2 | `0x94D049BB133111EB` | second avalanche multiply |
| 64-bit mask | `0xFFFFFFFFFFFFFFFF` (`2^64 - 1`) | wrap every arithmetic op to u64 |

All arithmetic is modulo `2^64`. Rust wraps natively
(`wrapping_add` / `wrapping_mul`); a port in Python/Go/JS **MUST** mask
each add and each multiply with `& 0xFFFFFFFFFFFFFFFF` or the family
diverges silently.

#### Stage 0 — the SplitMix64 `next()` step

One `next()` step advances the state and returns one u64 draw. It is the
sole randomness primitive used everywhere below.

```
function splitmix64_next(state: u64) -> (state: u64, output: u64):
    state = (state + 0x9E3779B97F4A7C15) mod 2^64        # advance by golden gamma
    z = state
    z = ((z XOR (z >> 30)) * 0xBF58476D1CE4E5B9) mod 2^64
    z = ((z XOR (z >> 27)) * 0x94D049BB133111EB) mod 2^64
    z = z XOR (z >> 31)                                   # final avalanche shift
    return (state, z mod 2^64)
```

Two disciplines a port MUST honor (these are the exact omissions that
produced byte-wrong-but-plausible ports):

1. **The draw is a hash *of* the state; it never *becomes* the state.**
   The running state advances only by `+0x9E3779B97F4A7C15` each call.
   Do not feed the returned `z` back as the next state.
2. **Do not drop the final avalanche shift `z ^= z >> 31`.** It is the
   last line of the mix and is load-bearing.

#### Stage 1 — expand the u64 seed to 32 bytes (`expand_seed_to_32`)

The manifest stores a u64 hyperplane seed; the generator needs 32 seed
bytes. The expansion is **four** SplitMix64 `next()` rounds carried over
a single running state initialized to the seed. Round *i* (i = 0..3)
contributes 8 little-endian bytes at offset `8*i`.

```
function expand_seed_to_32(seed: u64) -> bytes(32):
    out = bytes(32)
    state = seed                                  # mod 2^64
    for i in 0..4:                                # exactly four rounds
        (state, z) = splitmix64_next(state)       # state carries across rounds
        out[8*i .. 8*i+8] = z.to_le_bytes()       # 8 little-endian bytes
    return out
```

It is **four** rounds, not one. Each round's 8-byte little-endian output
`z.to_le_bytes()` is written contiguously, lowest-offset round first.

#### Stage 2 — initialize SplitMix64 from the 32-byte seed

The generator that draws the planes is seeded from those 32 bytes by
reading them as four little-endian u64 words `w0..w3` and folding `w1..w3`
into `w0`:

```
function splitmix64_init(seed32: bytes(32)) -> u64:    # returns initial state
    s = le_u64(seed32[0 .. 8])                          # word 0 is the base
    for chunk in 1..4:                                  # words 1, 2, 3
        w = le_u64(seed32[8*chunk .. 8*chunk+8])
        s = s XOR ((w + 0x9E3779B97F4A7C15) mod 2^64)
    return s mod 2^64
```

Word 0 is taken verbatim; words 1, 2, 3 are each offset by the golden
gamma and XOR-folded in. This is **not** symmetric with Stage 1 — word 0
gets no `+gamma`; the other three do.

#### Stage 3 — draw the 64 planes (the two-draws-per-bit discipline)

A block has `input_bit_length` bits (192 for block 0, 64 for blocks
1..3) and `word_count = ceil(input_bit_length / 64)` u64 words. Each
plane is two bitmasks of `word_count` words: `positive_mask` marks the
+1 positions, `negative_mask` marks the −1 positions; a 0 in both marks
an inactive (zero-weight) position.

The **iteration order is fixed and a port MUST reproduce the exact PRNG
call sequence**: plane index `k` is the **outer** loop (0..63 ascending),
bit index is the **inner** loop (0..input_bit_length−1 ascending). For
every (plane, bit) the generator is consulted in this order:

- **Draw 1 — density gate.** `r = next()`. If `r` clears the activity
  test the position is active; otherwise it is inactive and the bit is
  skipped.
- **Draw 2 — sign.** Drawn **only when the position is active**:
  `sign = next()`. If `sign & 1 == 1` the position is +1 (set the bit in
  `positive_mask`); else it is −1 (set the bit in `negative_mask`).

```
function generate_family(seed: u64, input_bit_length: int,
                         density: f64) -> planes[64]:
    word_count = ceil(input_bit_length / 64)
    seed32 = expand_seed_to_32(seed)
    state  = splitmix64_init(seed32)

    no_gate   = (density >= 1.0)                         # see density rule
    threshold = (u64::MAX as f64 * density) as u64       # = floor((2^64 - 1) * density)

    planes = []
    for k in 0..64:                                      # OUTER: plane index
        pos = [0u64; word_count]
        neg = [0u64; word_count]
        for bit in 0..input_bit_length:                 # INNER: bit index
            (state, r) = splitmix64_next(state)          # DRAW 1: density gate
            active = no_gate OR (r < threshold)
            if active:
                (state, sign) = splitmix64_next(state)   # DRAW 2: sign (active only)
                if sign & 1 == 1:
                    pos[bit / 64] |= 1 << (bit mod 64)   # +1 position
                else:
                    neg[bit / 64] |= 1 << (bit mod 64)   # -1 position
        planes.push((pos, neg))
    return planes
```

**Density gating rule.** `density` is an f64 in `(0, 1]` controlling the
fraction of non-zero (±1) positions per plane.

- **`density >= 1.0` is a hard no-gate case:** every position is active,
  and the density-gate draw (`r`) is **still consumed** to keep the PRNG
  call sequence identical to the gated path — its value is simply
  ignored. (At density exactly 1.0 the naive `r < threshold` test would
  miss the single bit pattern `r == u64::MAX`, since the f64 cast of
  `u64::MAX * 1.0` saturates back to `u64::MAX`; the explicit no-gate
  branch removes that one-in-2^64 asymmetry.) **All committed
  conformance vectors use density = 1.0**, so the no-gate path is the
  exercised path.
- **`density < 1.0`:** `threshold = (u64::MAX as f64 * density) as u64`,
  i.e. `floor((2^64 − 1) * density)` — note `2^64 − 1`, **not** `2^64`.
  A position is active iff its first draw `r < threshold`. (No committed
  vectors exercise this branch yet; the formula is fixed so a port is
  forward-compatible.)

**Mask word/bit ordering.** Bit `b` of the input lives in word
`b / 64` at bit position `b mod 64` (little-endian within the word: bit 0
is the least-significant bit of word 0). The plane masks use the
identical layout, so `positive_mask[b/64]` bit `b mod 64` lines up with
input word `b/64` bit `b mod 64`. Word 0 holds bits 0..63, word 1 holds
bits 64..127, word 2 holds bits 128..191 (block 0 only).

**`block_index` semantics.** `block_index` (0..3) is **informational
only** for these conformance vectors and does **not** enter the seed
math. The harness and the Tier-1 reference both call
`expand_seed_to_32(hyperplane_seed)` on the bare per-case seed; the seed
already differs per block in the committed cases. `block_index` selects
the canonical input width (192 for block 0, 64 for blocks 1..3) and
routes the family to the correct fingerprint block, but it is never
mixed into the seed used to draw the planes. (A separate manifest path,
`block_families` / `diversified_seed`, *does* diversify one base seed
across four blocks by FNV-mixing the block index before expansion; that
path is **not** what the simhash conformance vectors exercise and is out
of scope for §3.6/§3.7.1 — keep them distinct.)

#### Stage 4 — compute the block (§3.6 recap)

With the 64 planes built, the 64-bit output follows §3.6 exactly. Pad the
input vector `v` to `word_count` words with zeros. For each plane `k`
(0..63):

```
p = sum over words i of popcount(v[i] & pos_mask_k[i])
n = sum over words i of popcount(v[i] & neg_mask_k[i])
if p > n: set bit k of result        # strict greater-than; ties (p == n) leave bit clear
```

The result is the u64 block value. Ties (`p == n`, includes the
all-inactive plane) resolve to 0 — the comparison is strict `>`.

#### Serialization

Where committed or transmitted as bytes, the u64 block value and the u64
hyperplane seed are rendered **little-endian** (`to_le_bytes()`). The
conformance vectors store both `hyperplane_seed` and `block_value` as
little-endian hex; decode with `int.from_bytes(bytes, "little")`. The f64
`hyperplane_density` is stored as its little-endian IEEE-754 bit pattern
(`0x000000000000f03f` = 1.0).

### §3.8. Cross-noun fingerprint compatibility (I-17)

**I-17. Cross-noun fingerprint compatibility.** All noun types
(Drawer, Tunnel, KGFact, DiaryEntry, Proposal, Association,
LearnedReference, AmbientSample) compute fingerprints under the
same four-block structure using the same per-block hyperplane
families. Fields missing for a given noun type contribute a
deterministic null sub-hash (16 zero bits or a fixed constant
chosen so distances remain interpretable). Hamming distance is
well-defined across all pairs of noun types within an estate.

This invariant unlocks moment-summary fingerprints (§8.7) and
cross-noun similarity queries.

### §3.9. Per-stream fingerprint extractors

Each ambient signal stream has a feature-vector extractor that
runs at the bucket boundary. The extractor reads raw samples,
computes a feature vector, contributes to specific bits in
specific blocks.

```
heart_rate_extractor(samples) -> FeatureVector:
    return {
        mean:           mean(samples),
        variance:       var(samples),
        max:            max(samples),
        min:            min(samples),
        hf_lf_ratio:    spectral_hf_lf(samples),   -- HRV proxy
        dominant_freq:  argmax_frequency(samples)
    }
    # Contributes to Block 0 bits 0–15.

location_extractor(events) -> FeatureVector:
    return {
        cluster_id:        dominant_cluster(events),
        distance_traveled: total_distance(events),
        geofence_xings:    count_transitions(events),
        motion_histogram:  histogram(motion_types(events))
    }
    # Contributes to Block 1 bits 64–95.

calendar_extractor(events) -> FeatureVector:
    return {
        event_count:        len(events),
        category_histogram: histogram(categories(events)),
        dominant_category:  argmax(category_histogram),
        declared_intent:    intent_ratio(events)
    }
    # Contributes to Block 2 bits 128–143.

screen_time_extractor(usage) -> FeatureVector:
    return {
        app_count:           distinct_apps(usage),
        dominant_category:   argmax(category_histogram(usage)),
        mean_session_length: mean(session_lengths(usage)),
        focus_mode:          focus_active_seconds(usage)
    }
    # Contributes to Block 3 bits 192–207.

# System telemetry extractors (case 2):

cpu_load_extractor(samples) -> FeatureVector:
    return {
        mean:                  mean(load_samples),
        p95:                   percentile(load_samples, 95),
        max:                   max(load_samples),
        top_processes:         top_3_processes(by_cpu_time)
    }
    # Contributes to Block 0 bits 0–15 (overlaps biometric streams
    # on personal estates; the signal_dominance field in operational
    # bitmap disambiguates).

memory_pressure_extractor: ...   -- analogous
io_wait_extractor:          ...   -- analogous
process_lifecycle_extractor: ...  -- analogous
filesystem_events_extractor: ...  -- analogous
security_auth_extractor: ...      -- masks dominant-actor identity
log_streams_extractor: ...        -- per spec §11.2
thermal_power_extractor: ...      -- analogous
```

For locked-zone streams, the extractor outputs a deterministic
null vector for its block-contribution bits; the bucket retains
discriminative power on unmasked blocks (§3.5 sensitivity input).

---

## §4. Runtime layout

### §4.1. 3D binary tensor (canonical runtime view) — I-18

**I-18. Runtime view is bit-sliced 3D tensor.** The substrate's
working set is held as memory-mapped bit-slice arrays organized
as a 3D binary tensor indexed `[column, field, bit_position,
row]`. For each of three bitmap columns (adjective, operational,
provenance), an outer dimension; for each field within the
column, a middle dimension; for each bit position within the
field, an inner dimension; for each row, the innermost dimension
contains N bits (the bit-slice).

At 1M rows v0.36:
- Adjective tensor: 12 fields × 6 bits × 1M rows = 72 Mbits = 9 MB
- Operational tensor: 12 fields × 6 bits × 1M rows = 9 MB
- Provenance tensor: 12 fields × 6 bits × 1M rows = 9 MB
- Fingerprint tensor: 256 bits × 1M rows = 32 MB
- Lattice anchor flat array: 1M × 16 bytes = 16 MB
- Total hot-resident: 75 MB.

Per LPDDR5 bandwidth (~60 GB/s on Apple Silicon), a full-tensor
scan is ~1.25 ms; predicate filters touching one field's bit-slice
(1 Mbit = 125 KB) finish in <10 µs. This is the bandwidth budget
the runtime must hit.

### §4.2. Memory-mapped working set

Bit-slice arrays are stored as flat 64-bit-aligned files on disk;
the working set is `mmap`-ed read/write into the runtime process.
Page-cache management is OS-delegated. The substrate does not
implement its own page cache.

```
File layout:
  /estate_uuid/bitslice/
    adjective.field0.bit0.bin    -- one file per (field, bit_position)
    adjective.field0.bit1.bin
    ...
    adjective.field11.bit5.bin
    operational.field0.bit0.bin
    ...
    provenance.field11.bit5.bin
    fingerprint.bit0.bin
    fingerprint.bit1.bin
    ...
    fingerprint.bit255.bin
    lattice_anchor.bin            -- single file, 16-byte records
```

Total file count: 3 columns × 12 fields × 6 bits + 256 fingerprint
bits + 1 lattice + manifest files = ~480 files per estate. Each
bit-slice file grows by `N_rows_added / 8` bytes per million rows
added. mmap re-extension is the OS's job.

### §4.3. SQLite as durability tail

SQLite remains the canonical row store for content (verbatim
text, blobs, structured-tier columns) and the audit log. The
bit-slice runtime is a *materialized view* over the SQLite tables
+ audit log; on cold start, the runtime rebuilds the bit-slice
files from SQLite if they're missing or behind the latest audit
row. On warm operation, every audit-row commit appends to both
SQLite (durable) and the bit-slice files (working view) before
returning success.

Crash recovery: on startup, compare bit-slice files' high-water-
mark row count against SQLite's audit log latest row. If they
disagree, rebuild bit-slice files from SQLite. Rebuild rate:
~1M rows/sec (constrained by SQLite scan + popcount).

### §4.4. Portable kernel layer (I-19)

**I-19. Kernel layer is portable across SIMD families.** The
bit-tensor operations (mask-AND-reduce, popcount-along-axis,
XOR-then-popcount, bitwise-OR-reduce) are implemented in a
portable kernel layer that selects the optimal backend at runtime:

```
KernelBackend (priority order):
  1. Apple AMX        -- Apple Silicon, matrix coprocessor
  2. ARM SVE/SVE2     -- ARM v9 with vector length agnostic
  3. ARM NEON         -- ARM v8 standard SIMD (128-bit)
  4. Intel AVX-512    -- modern x86_64 with AVX-512
  5. Intel AVX2       -- broader x86_64 support (256-bit)
  6. Scalar reference -- portable fallback (CRC validation)
```

Each backend implements the same trait/interface. The runtime
detects CPU features at startup and routes operations to the
strongest available backend. The scalar reference is the
authoritative source for correctness; per-backend implementations
must produce bit-identical results to the scalar reference (CRC
test against the v0.36 reference vectors in
`conformance/kernel/`).

In Swift on Apple Silicon, the AMX path is implemented via Accelerate
or direct AMX intrinsics. In Rust, `std::simd` plus per-architecture
intrinsics where necessary.

> **Phase 2 measurement note (added 2026-05-18).** The priority
> order above is a checklist for FUTURE backends, not a measured
> ranking. On apple-m5-max the production-default kernel is
> `SimdKernel` via Swift's `import simd` and Rust's `std::simd`,
> which the compiler lowers to NEON. The BNNS path to AMX was
> measured and REJECTED for hot-path ops: 192x slower than
> SimdKernel for or_reduce_256, 68x slower for hammingDistanceBatch,
> 3.7x slower asymptotically for simhashBlockBatch (encode-cost
> dominated). Direct NEON intrinsics (NeonKernel) lost 193x
> because Swift does not expose a vector-popcount primitive.
>
> The dispatcher on aarch64 reduces to a single branch:
> `kernelForCurrentPlatform()` returns `SimdKernel`. No learned
> dispatch is needed for any of the documented ops. AMX-via-BNNS
> remains the right choice for substrate-level matmul workloads
> (NMF, large-matrix dreaming-daemon passes); the kernel layer
> rejection is specific to the bandwidth-bound bit-tensor ops
> documented here.
>
> See `§17.6` for the per-op selection table and empirical outcomes.

### §4.5. Bandwidth budgets

Hot-path query budgets per primitive:

| Primitive | 1M-row estate | 10M-row estate |
|-----------|---------------|----------------|
| Bitmap filter (one predicate) | < 100 µs | < 1 ms |
| Bitmap filter (compound, 3-5 predicates) | < 500 µs | < 5 ms |
| Hamming-NN top-K (K=10) over 1 fingerprint | < 100 µs | < 1 ms |
| Hamming-NN top-K (K=100) | < 500 µs | < 5 ms |
| Lattice-distance pair | < 50 µs | < 50 µs (cached) |
| Composite distance (α·lattice + β·fingerprint) | < 200 µs | < 2 ms |

Cold-path budgets (dreaming daemon):

| Pass | 1M-row estate | Schedule |
|------|---------------|----------|
| F/C/O matrix refresh | < 10 sec | Per capture (incremental) |
| Asymmetry profile recompute | < 30 sec | Weekly |
| NMF on O matrix | < 60 sec | Weekly |
| Eigenvalue centrality | < 10 sec | Daily |
| Temporal compression (hour rollup) | < 5 sec | Hourly |
| Pattern mining | < 5 min | Weekly |

---

## §5. The audit log as CRDT

**v1.0 update.** Sections §5.1 through §5.5 carry forward from
v0.36 with minor amendments noted inline. Sections §5.6 through
§5.10 are new in v1.0 and integrate the Clock Triangle and
Capture Genesis Event decisions. The TL;DR: the audit log is now
genuinely the source of truth (no live-row seed needed for
projection), every event carries the integrity-triangle proof
shape, and custody is a per-moot setting that picks when the
seal is computed without changing what the seal is.

### §5.1. G-Set semantics (I-20)

**I-20. The audit log is a Grow-Only Set CRDT.** Each audit row
is an immutable event. The set of all audit rows across all
replicas is a G-Set. Merging two replicas' audit logs is set
union; conflict resolution is unnecessary because each row is
uniquely identified by `(estate_uuid, hlc_timestamp, sequence)`.

This formalizes v0.35 I-2 with CRDT properties.

### §5.2. Hybrid Logical Clock (HLC) ordering

Each audit row carries an HLC timestamp:

```
HLC {
  physical_time:  Int64    -- wall-clock milliseconds since epoch
  logical_count:  Int32    -- monotonically increasing counter
  node_id:        Int32    -- replica identifier (per-device)
}
```

Comparison: lexicographic on (physical, logical, node). HLC
ensures partial ordering across replicas without requiring
synchronized clocks. On message receipt, a replica advances its
HLC to `max(local, received) + (0, 1, 0)`.

This supersedes v0.35's wall-clock `updatedAt` ordering. Existing
v0.35 audit rows are upgraded at migration by treating their
`updatedAt` as the physical-time component and assigning
`logical_count = 0`, `node_id = legacy_node_id`.

### §5.3. Projection rules

Current visible state is a deterministic projection over the G-Set.
For row R with audit history E_R = {e_1, e_2, ..., e_n} ordered by
HLC ascending:

```
project_current_state(R, E_R) -> RowState:
    state = capture_initial_state(e_1)
    for e_i in E_R[1..]:
        state = apply_mutation(state, e_i)
    return state

# asOf reconstruction (v0.35 §6.5):
project_state_at(R, E_R, T) -> RowState:
    E_R_truncated = [e for e in E_R if e.hlc <= T]
    return project_current_state(R, E_R_truncated)
    # Returns None for T strictly before e_1.hlc (row did not
    # exist then).
```

The projection is deterministic and order-independent given HLC
ordering. Replicas converge to identical visible state once they
share identical audit logs.

**I-26. Capture emits a gated genesis event (v1.0).** The first
event in every row's history `e_1` is a `capture` event written
through `AuditGate.admit` with `prior = none` and `after = the
captured state`. The materialized projection (the live `drawers`
row in production) is a cache of the fold starting from `e_1`,
not a seed for it. `project_state_at(R, E_R, T)` is well-defined
for every T ≥ `e_1.hlc` using only the log; for T < `e_1.hlc`
it returns None.

This closes a semantic gap in v0.36, where `addDrawer` was an
INSERT that wrote nothing to the audit log and projection was
implicitly seeded from the live row. Federation under v0.36 had
to synthesize an origin event at export time — exactly the case
the federation decision's verbatim-carry rule was designed to
prevent. v1.0 capture is the fifth gated write path (joining the
four mutators); the `AuditGate`'s `prior == nil` branch runs
`ForbiddenCombinations.check` over the captured basis, so I-22
is enforced at capture as it is at mutation.

The reference implementation `AuditLogFold::project_current_state`
(Rust) / `AuditLogFold.projectStateAt` (Swift) is conformance-
gated; see `HARNESS_REFERENCE.md` §2.3 for the
canonical CRC (`0xa747722e`).

### §5.4. Sync correctness (I-21)

**I-21. Sync convergence.** Given two replicas R_A and R_B of the
same estate, with audit logs E_A and E_B, after each replica
receives all audit rows in the union E_A ∪ E_B, both replicas'
projected current state is identical.

*Proof sketch.* G-Set union is commutative and associative.
Projection is a pure function of the sorted G-Set. Both replicas
compute the same projection of the same set, therefore the same
state. ∎

### §5.5. Reconstruction algorithm

```
function rebuild_from_audit(estate_uuid: UUID) -> Substrate:
    substrate = empty_substrate(estate_uuid)
    audit_rows = sqlite.audit_log
                       .filter(estate_uuid)
                       .sort_by(hlc_asc)
    for e in audit_rows:
        substrate.apply(e)
    # Rebuilds:
    #   - bitmap tier (replays each adjective/operational/provenance
    #     mutation)
    #   - matrix tier (replays every increment to F, C, O, T)
    #   - fingerprint tier (recomputes each row's fingerprint from
    #     its final state)
    #   - vector index (recomputes embeddings from content)
    return substrate

# Cost: O(N_audit) for tier-N rebuilds, dominated by SQLite scan.
# 10M audit rows takes ~10 sec on Apple Silicon.
```

This is the disaster-recovery path (v0.35 F-4) and the sync-
reconciliation path (v0.36 NEW). Under v1.0 the rebuild is
self-sufficient — every row's genesis state is in the log (I-26),
so cold rebuild from log alone works without consulting the
live-row store.

---

## §5.6. HLC generator placement (v1.0)

The Hybrid Logical Clock comparison (§5.2) is paired with a
generator primitive `HLCGenerator` that issues the stamps. The
generator is a SubstrateLib atomic per I-25 — identical type
whether a bare kit or an estate opens it.

```
HLCGenerator (SubstrateLib primitive):
  open(over: AuditLog, nodeID: Int32) -> HLCGenerator
    -- Seeds physical to max(existing-log-max, wall-clock) and
       claims the maker node id. A second open over a log that
       already has a maker is REFUSED (single-maker guard, I-28).
  tick() -> HLC
    -- Returns the next HLC stamp. Holders call this; never open.
  takeover(over: AuditLog, nodeID: Int32, reason: String) -> HLCGenerator
    -- Explicit, logged handoff. Records a takeover audit event
       and claims the maker field with the new node id.
```

**I-28. Single clock maker per log (v1.0).** A log has exactly
one active maker node id at any time. `open` refuses on an
already-owned log; `takeover` is the only way to change custody
authority and is itself a logged event. The guard prevents the
silent two-clocks-over-one-log failure mode.

**Placement.** `HLCGenerator` lives in SubstrateKernel (§20).
The decision of *who* calls `open` belongs to the top entity
present (GLK in a full estate, the kit itself in standalone
deployments). Holders receive the opened generator by initializer
injection at construction boundaries: GLK opens, then hands the
instance into `LocusKit(hlc:)` and `RagKit(hlc:)`.

The maker-node-id marker lives in the PersistenceKit header;
storage holds and guards the marker, while the substrate defines
what claiming it means. Estate sync falls out for free: GLK is
the single maker; LOCUS and RAG events carry stamps from the
same sequence and same node id; they order against each other
with no kit-to-kit coordination. Sync is structural, not an
operation.

---

## §5.7. The integrity triangle (v1.0)

**I-27. Integrity triangle.** Every audit event carries three
cross-checking legs:

1. **Plaintext HLC** — the ordering key, produced by `tick()`,
   stored by PersistenceKit as a column on the event row.
2. **Content+HLC seal** — SHA-256 over the wire fields *including
   the full HLC with maker node id*, folded into the event id.
   Computed at `AuditGate.admit`. This binds content and time
   together; moving the event in order or swapping content under
   a stamp breaks the seal.
3. **Companion HLC seal** — SHA-256 of the HLC alone, stored as
   a companion to the plaintext clock value. Timestamp tampering
   is detectable as its own fault class without re-deriving the
   whole event id.

Tamper with any corner and the other two disagree. The seal MUST
cover the maker node id — "who knew first" is provable only if
the origin stamp is bound to which maker produced it.

The triangle is **per-maker**. Because GLK is the single maker
in an estate (I-28), LOCUS and RAG events share one sequence and
one node id, so a single coherent triangle spans everything
beneath one maker. The triangle is per-maker, not per-kit.

The seal proves event integrity and binds it to a *claimed* node
id. Binding the claimed id to a *real* peer is identity attestation
at the pairing handshake (federation decision Appendix C), a
separate mechanism.

**The sealed bit (adjective bit 27) is a one-bit trust hint, not
the proof.** A record carries a content trust level (verbatim
through ambient, bits 18-23) and a seal state independently. The
bit is mode-stamped, never computed: strict writes 1, lazy writes
0 at the write; the dreaming pass flips lazy 0→1 after computing
the seal. The bit is a cached assertion that a valid seal exists;
if the bit ever disagrees with the seal, the seal wins. The bit
doubles as the consolidation work-queue, since unsealed records
are exactly those where `sealed = 0`.

The kind of seal (lazy-consolidated vs strict-contemporaneous,
plus any attestation identity) rides with the proof, not in the
bitmap; the bit says only sealed yes or no.

---

## §5.8. Custody mode — strict versus lazy (v1.0)

Seal state is a trust level, and the cost-and-timing of sealing
is a **custody choice set per moot at creation**, over one byte-
identical seal construction. The axis is not secure-vs-casual; it
is whether a record is a chain-of-custody record or a personal-
integrity record — whether it must prove something, later, to
someone who does not trust the author.

**Strict moot** (research notes, priority claims, "I had the idea
first"). Mints the seal and the HLC atomically at the write,
contemporaneously. That contemporaneity is the evidence, so
deferral is forbidden: a seal minted later nullifies the priority
claim because the proof's time no longer coincides with the
moment of origin. The write stamps `sealed = 1`.

**Lazy moot** (personal life, no adversary, "I am not using my
moot as my alibi"). Does the fast path only at the write and
defers the SHA-256 to dreaming. The seal's only job here is
honest-fault detection, which is time-insensitive. The write
stamps `sealed = 0`; the dreaming-pass consolidation flips it to
1 after computing the seal.

Both modes produce the same seal; strict vs lazy is purely *when*
it is computed, never *what* it is.

**Anti-backdating guarantee.** A lazy moot can upgrade to strict
going forward, but its past lazy-sealed events can never
retroactively become contemporaneous, because their seals were
minted at dream-time, not write-time. That is a feature — exactly
the backdating the system exists to prevent.

**Unsealed window as emergent tier.** An unsealed record is at
once low custody-trust and high recency — the same physical fact,
that the seal has not run, seen from two directions. It is the
freshly-captured, not-yet-consolidated thought. Sealing is
consolidation; trust rises as a record moves from emergent-
unsealed to consolidated-sealed. The boundary rule holds
throughout: an event may cross a trust boundary (federate,
export, be audited, be relied on by another authority) only if
already sealed, and only a strict seal carries a priority claim.

**Device-edge resolution.** On an iPhone-only deployment, lazy
mode writes are cryptographically free and instant — tick, gate,
fold, stamp the bit 0, append. The dream-and-seal pass is idle-
and-power-gated, matching the deferrable-batch window iOS grants
background compute on its own terms of charging, screen-off, and
thermals. The pass must be resumable and incremental (the OS
yanks the background window mid-pass): it runs in HLC order,
flips bits as it goes, resumes from the first still-unsealed
record next window. The seal bit IS the work-queue — the queue
survives interruption with no separate checkpoint state.

Strict mode is fully supported on the same device, simply slower
per write because it pays the SHA-256 contemporaneously. The
felt latency is the deliberate notarization of an intentional
act, not a drag on every interaction.

---

## §5.9. Three time concepts, kept distinct (v1.0)

The federation and backlog cases force three timestamps apart;
conflating any two loses information that cannot be reconstructed.

1. **Empirical date** — when the thing actually happened in the
   world. A photo taken in 2015. Content-derived. About the
   material. Belonging to no clock. Stored as content
   (`eventTime` per ING-01), sealed at origin, riding along on
   ingest, never re-stamped.

2. **Origin HLC** — when the system first recorded it. The origin
   maker's gate stamp. The "who knew it first" proof. Kept
   verbatim under federation (§5.10).

3. **Ingest HLC** — when *your* system recorded receipt. Your
   maker's stamp. Orders the event in your timeline.

The correction this encodes: a federated item's clock is its
origin HLC (proof of the other party's first-knowledge), not its
empirical date. The empirical date is a third thing inside the
content.

**Empirical date and origin HLC must not be merged into a single
"authored date" field.** State has exactly one legitimate fold
order — ingest HLC — which is the order the chain of custody is
in. The empirical date is a content attribute to filter and sort
on, never a fold axis for state. Dual-clock projection was
considered and rejected; see Appendix A entry OQ-V1-1.

---

## §5.10. Federation wrap — verbatim, nested triangles (v1.0)

Verbatim carry is mandatory because the origin stamp is the proof
of who-knew-first; re-sealing an incoming event under the
receiver's maker would erase the evidence that the origin knew
it first.

An incoming federated event is **not re-stamped but wrapped**.
The origin event is carried verbatim — its origin plaintext HLC,
its origin seal, its origin content — so its triangle stays
intact and verifies against the origin maker. The receiver
stamps its own ingest HLC around it and seals the fact that it
received this event id at this time, and that is the receiver's
outer triangle. **Two intact triangles, nested, neither rewritten.**

The origin HLC proves first-knowledge; the receive HLC orders
it locally; and a receiver's log legitimately holds multiple
makers' seals, which is the normal multi-maker situation across
time, not corruption.

**Backlog is the same structure as federation.** A permanently
ingested decade-spanning backlog has origin and empirical dates
far in the past and a recent ingest HLC: same wrap, same nesting.

---

## §5.11. PersistenceKit's role — declare and enforce, never author

A kit declares integrity policy on the table at build time, as a
schema property alongside `appendOnly`: HLC-required or not,
sealed or not, encrypted or not.

**PersistenceKit enforces that policy** — it refuses a write
missing a required HLC or seal, verifies seals on read, keys on
`(eventID, hlc)`, and arms append-only — but **it does not
author**: it never generates the HLC or computes the seal. The
HLC comes from the one maker upstream; the seal is computed at
the `AuditGate`. The operative word is *enforce*, not *handle*,
because the moment storage authors the clock the triangle stops
composing across kits.

This makes read-only verifiable rather than merely promised.
Append-only plus the seal upgrades immutable history from a
promise to a property that is detectable if violated — which
matters most for the in-memory backend, where no engine enforces
immutability for you.

A genuinely read-only instance is also expressible: open with
the `AuditGate` never armed for writes, the HLC loaded to its
last value but not advancing, append refused. The result is a
verifiable read-only replica that can project state and verify
every seal but structurally cannot mint an event — useful as a
federation or audit-verification sandbox.

## §5.12. Merkle attestation composition (1.1 shared-content target)

Snapshot attestations compose across kits. A snapshot is an atomic
point-in-time record with one or more `SnapshotAttestation` rows,
each binding a subject (wing, corpus source, estate root) to a
Merkle root hash.

**LocusKit** provides the base attestations:
- Per-wing attestation: Merkle root over the wing's node-tree
  containment hierarchy.
- Estate-root attestation: interior hash over all per-wing roots.

In a GLK composition, **CorpusKit does not provide a second content
attestation**. The LocusKit Drawer root already attests the canonical bytes.
CorpusKit may provide a clearly typed *derived-index attestation* over canonical
Drawer id + revision/digest + index version/checkpoint. That attestation proves
which content revision the rebuildable BM25/vector state represents; it must not
hash or persist another copy of Drawer text.

Standalone CorpusKit may attest its own canonical document store. Optional
passage state contributes only revision-bound range/index metadata. The legacy
`BundleStore.corpusMerkleRoot` / `globalCorpusMerkleRoot` surface remains a
standalone 1.0 compatibility mechanism and is not part of GLK 1.1.

**GeniusLocusKit** composes the canonical LocusKit content root and any
CorpusKit derived-index root via `createComposedSnapshot(for:label:now:)`. Both
typed roots land in
one atomic `snapshot_attestations` table write. When no Corpus is
registered, falls back to LocusKit-only attestations.

The composition is additive: `Estate.createSnapshot` accepts an
`additionalAttestations` parameter that appends caller-supplied
attestations alongside the LocusKit-generated ones. The
`snapshotId` on additional attestations is a placeholder; the
estate assigns the real snapshot ID atomically.

**Verification.** Replay the Merkle root computations from current
data and compare to the stored attestation roots. A mismatch indicates
tampering, silent corruption, or a stale derived index. The roots are
independently verifiable without duplicating content: LocusKit's content root is
recomputed from canonical Drawers; CorpusKit's optional derived root is
recomputed from Drawer revision/digest plus derived index state.

---

## §6. The matrix tier

### §6.1. Field-presence matrix F

```
F: dense 2D array indexed by (field_index, bit_position)
   shape: 36 fields × 6 bits = 216 cells   -- v0.36
   cell type: Int64 (count of rows where bit is set)

   Update rule (on capture, mutate, expunge):
     for (field, bit_position) where row's bit is set:
         F[field, bit_position] += delta_count

   delta_count = +1 on capture
               = -1 on expunge_of_active_row
               = old_count_zero - new_count_zero per bit on mutate
```

Storage: 216 × 8 bytes = 1.7 KB per estate. Trivial.

### §6.2. Correlation matrix C

```
C: dense 2D array, same shape as F
   cell type: Float32 (marginal probability)

   Derivation (weekly recompute):
     C[field, bit_position] = F[field, bit_position] / N_rows

   N_rows = COUNT(rows in estate, excluding tombstoned)
```

Storage: 216 × 4 bytes = 864 bytes per estate. Trivial.

### §6.3. Co-occurrence matrix O

```
O: sparse 4D array indexed by
   (field_i, value_i, field_j, value_j)
   cell type: Int64 (count of rows where both pairs hold)
   storage: CSR-encoded

   Update rule (on capture, mutate, expunge):
     for each pair (i, v_i, j, v_j) where v_i is the row's value
     for field i and v_j is the row's value for field j:
         O[(i, v_i), (j, v_j)] += delta_count

   Same delta logic as F.
```

Storage at v0.36 with 36 fields and average 6 values active per
field, on a typical estate: 36 × 6 × 36 × 6 = 46K potential cells,
sparsity ~5-10% → 2-5K cells × 8 bytes = 16-40 KB per estate.

### §6.4. Temporal causality matrix T (NEW in v0.36)

```
T: sparse 3D array indexed by
   (source_field_value, target_field_value, lag_bucket)
   cell type: Int64
   storage: CSR-encoded
   lag_bucket: integer in {1, 2, 4, 8, 16, 32, 64, 128} (log-spaced
               minutes)

   Update rule (on dreaming daemon pass, weekly):
     for each pair (row_a, row_b) where row_b.capture_time -
                                      row_a.capture_time < 256 min:
         lag_bucket = log2_bucket(time_difference_minutes)
         for each (field, value) in row_a:
             for each (field', value') in row_b:
                 T[(field, value), (field', value'), lag_bucket] += 1
```

Storage at v0.36: ~200-500 KB per estate.

T encodes "field-value A at time t correlates with field-value B
at time t + lag_bucket" — directional, unlike the symmetric O.
Distinguishes "co-activated" from "caused."

### §6.5. Action-outcome matrix (case 2)

```
ActionOutcomes: sparse 3D array indexed by
   (action_kind, posture_fingerprint_bucket, outcome_category)
   cell type: Int64
   posture_fingerprint_bucket: low 16 bits of the recent posture
                               fingerprint (§8.7)
   outcome_category: enum {resolved, partial, persisted, regressed,
                           timed_out}

   Update rule (on actuator outcome capture, §14.4):
     ActionOutcomes[(kind, bucket, outcome)] += 1
```

Storage: ~50 KB per fleet-member estate at year-1.

### §6.6. LLM calibration curves

Per registered model:

```
Calibration[model_id]: dense 1D array of 20 buckets
   bucket b ∈ [0, 19] represents claimed confidence in
                                 [b * 0.05, (b+1) * 0.05)
   cell type: (Int32 count, Float32 success_rate)

   Update rule (on action outcome with claimed_confidence c
                                      and outcome ∈ {success, failure}):
     bucket = floor(c * 20)
     entry = Calibration[model_id][bucket]
     entry.count += 1
     entry.success_rate = (entry.success_rate * (entry.count - 1)
                          + (1.0 if outcome == success else 0.0))
                          / entry.count
```

Storage: 20 × 8 bytes × N_models = 160 bytes per model.

The actuator (§14) consults this before validating proposed
actions: a proposal with claimed 0.8 from a model whose 0.8
empirically yields 0.6 gets deflated to 0.6 for downstream
decision-making.

### §6.7. Bradley-Terry weight vectors

Two vectors, per-user, in the manifest:

```
W_tournament: Float32[5]      -- branch-scoring weights (algebra §3)
W_ranking: Float32[12][5]     -- per-primitive composite-ranking
                                 weights (algebra §4)

Both normalized to sum-to-1 per row and projected onto the
non-negative simplex after each update.
```

Storage: 60 × 4 = 240 bytes per estate.

### §6.8. Matrix decay (NEW in v0.36)

```
function apply_decay(M: Matrix, half_life_days: Float, now: Time):
    elapsed = now - M.last_decay_time
    if elapsed.days < 1:
        return                  -- decay daily at coarsest
    decay_factor = pow(0.5, elapsed.days / half_life_days)
    for entry in M:
        entry.count *= decay_factor
    M.last_decay_time = now

# Lazy: invoked at next update time, not continuously.
# The dreaming daemon's update pass calls apply_decay before
# applying new increments.
```

Half-lives (default; manifest-configurable):

| Matrix | Half-life | Justification |
|--------|-----------|---------------|
| F | None (no decay) | Stable population stats |
| C | None | Derived from F |
| O | 365 days | Personal patterns stable |
| T | 90 days | Causal drift faster |
| ActionOutcomes | 90 days | Systems evolve |
| Industry-tier (case 3) | 180 days | Medium pace |
| LLM Calibration | 30 days | Models update |
| W_tournament | None | User preference |
| W_ranking | None | User preference |

### §6.9. NMF latent factors

```
function nmf_factorize(O: Matrix, K: Int = 10) -> (W, H):
    # Alternating least squares on sparse O
    # Returns: W shape (rows × K), H shape (K × rows)
    # such that O ≈ W·H, W ≥ 0, H ≥ 0
    W = random_nonneg(N_rows, K)
    H = random_nonneg(K, N_rows)
    for iteration in 0..MAX_ITERS:
        H = H * (W.T @ O) / (W.T @ W @ H + ε)        -- multiplicative update
        W = W * (O @ H.T) / (W @ H @ H.T + ε)
        if reconstruction_error(O, W @ H) < tol: break
    return (W, H)
```

Storage: K × 2 × N_rows × 4 bytes; for K=10, 1M rows: 80 MB worst
case. In practice O is sparse and we cache only the row-factor
loadings of "interesting" rows (top-scoring per latent factor):
~10 MB.

Recomputed weekly by the dreaming daemon.

---

## §7. The estate as a graph

### §7.1. Graph definition

```
EstateGraph = (V, E)
  V = all noun rows (Drawer, Tunnel, KGFact, AmbientSample, ...)
  E = directed labeled weighted edges:
      - (drawer_a, drawer_b, kind="tunnel", weight=1.0)
        from every Tunnel row
      - (drawer_old, drawer_new, kind="lineage", weight=1.0)
        for each lineage_id chain
      - (row_a, row_b, kind="co_activation", weight=O_count(a,b))
        for each O-matrix cell above threshold
      - (row_a, row_b, kind="temporal_causality",
                       weight=T_count(a,b,lag), lag=lag)
        for each T-matrix cell above threshold
      - (drawer, qid, kind="anchored_to", weight=1.0)
        for lattice-anchor edges
```

Storage: implicit; constructed on demand from existing matrices
and Tunnel/lineage tables. No graph file format.

### §7.2. Eigenvalue centrality (keystone scoring)

```
function eigenvalue_centrality(G: EstateGraph,
                                edge_kinds: Set<Kind> = {"co_activation"},
                                max_iter: Int = 100) -> Map<Row, Float>:
    A = sparse_adjacency_matrix(G, edge_kinds)
    x = uniform_vector(|V|)
    for _ in 0..max_iter:
        x_new = A @ x
        x_new /= norm(x_new)
        if ||x_new - x||_2 < tol: break
        x = x_new
    return {row: x[row.index] for row in V}

# Cost: O(|E|) per iteration. Sparse graphs converge in 20-50
# iterations. 1M-row estate: ~100 ms.
```

Top-K rows by centrality are "keystone drawers" — rows central to
the user's cognitive graph. Cached in the structured tier as
`row_keystone_score` (Float32), refreshed daily by the dreaming
daemon. Exposed via `recall_keystone` (§11.11).

### §7.3. Community detection (auto-rooming)

```
function detect_communities(G: EstateGraph,
                             edge_kinds: Set<Kind>) -> Map<Row, CommunityId>:
    # Louvain method on the weighted graph.
    # Returns row -> community label.
    return louvain(G, resolution=1.0)
```

Communities surfaced as `propose(kind=room_suggestion, members=[...])`
events for user confirmation. Confirmed rooms become first-class
Room rows in v0.35 §4.3.

### §7.4. Random walks (exploratory retrieval)

```
function random_walk(G: EstateGraph, start: Row, length: Int,
                     restart_prob: Float = 0.15) -> [Row]:
    visited = []
    current = start
    for _ in 0..length:
        visited.append(current)
        if random() < restart_prob:
            current = start
        else:
            neighbors = G.out_edges(current)
            current = sample_weighted(neighbors)
    return visited
```

Used in `recall_exploratory` (v0.37 primitive; not yet specified
here).

---

## §8. Algorithms (the cookbook center)

This section gives the concrete pseudocode for each primitive
operation. Implementations may diverge in idiomatic detail but
must produce bit-identical results to these reference algorithms
on the v0.36 test vectors.

### §8.1. SimHash construction

Specified in §3.6. See `simhash_block` and
`compute_fingerprint`.

### §8.2. Hamming distance and Hamming-NN

```
function hamming_distance(f_a: Fingerprint256,
                          f_b: Fingerprint256,
                          blocks: Set<Int> = {0,1,2,3}) -> Int:
    distance = 0
    for block in blocks:
        distance += popcount(f_a.block(block) XOR f_b.block(block))
    return distance
    # Range: 0 to 64 * |blocks|

function hamming_nn(anchor: Fingerprint256, K: Int,
                    candidate_filter: Predicate = AnyRow) -> [Row]:
    # Brute-force exact NN. For 1M rows: ~100 µs with AVX-512/AMX
    # popcount kernels. Bandwidth-bound, not compute-bound.
    candidates = filter_rows_bitslice(candidate_filter)
    heap = MinHeap<(distance, row)>(capacity=K)
    for row in candidates:
        d = hamming_distance(anchor, row.fingerprint)
        heap.push_or_replace(d, row)
    return heap.sorted_ascending()
```

Batched: process 256 rows at once via tensor XOR-popcount along
the row axis.

### §8.3. Lattice distance

```
function lattice_distance(a: LatticeAnchor, b: LatticeAnchor,
                          alpha_udc: Float = 0.5,
                          alpha_qid: Float = 0.5) -> Float:
    udc_dist = udc_tree_distance(a.udc, b.udc)
    qid_dist = wikidata_graph_distance(a.qid, b.qid)
    return alpha_udc * udc_dist + alpha_qid * qid_dist

function udc_tree_distance(a: UDCCode, b: UDCCode) -> Float:
    # Tree distance over UDC hierarchy. Shared-prefix length
    # determines closeness.
    common = longest_common_prefix(a, b)
    return (len(a) - len(common)) + (len(b) - len(common))
    # Normalize to [0, 1] by dividing by max(len(a), len(b)).

function wikidata_graph_distance(a: QID, b: QID) -> Float:
    # Shortest path over (subclass_of, instance_of, part_of)
    # edges in Wikidata. Cached per pair.
    if a == b: return 0.0
    if cached(a, b): return cache[(a, b)]
    path_length = bfs(a, b, max_depth=4,
                       edges={subclass_of, instance_of, part_of})
    distance = 1.0 - exp(-path_length / 3.0)   -- normalized [0, 1)
    cache[(a, b)] = distance
    return distance
```

UDC tree distance is exact and cheap. Wikidata graph distance is
cached; cache miss triggers SPARQL or local-dump query.

### §8.4. Composite distance

```
function composite_distance(a: Row, b: Row,
                            alpha_lattice: Float,
                            alpha_fingerprint: Float,
                            compatible_seed_scope: SeedScope = LOCAL) -> Float:
    lat_d = lattice_distance(a.lattice_anchor, b.lattice_anchor)
    if compatible_seed_scope_present(a, b, compatible_seed_scope):
        fp_d = hamming_distance(a.fingerprint, b.fingerprint) / 256.0
        return alpha_lattice * lat_d + alpha_fingerprint * fp_d
    else:
        # Cross-perimeter without shared seeds: lattice only
        return lat_d

# alpha_lattice and alpha_fingerprint are per-primitive-per-user,
# learned via Bradley-Terry (§8.12). Default values for v0.36
# cold start:
default_alpha_lattice = 0.5
default_alpha_fingerprint = 0.5
```

### §8.5. OR-reduction across scopes

```
function or_reduce(fingerprints: [Fingerprint256]) -> Fingerprint256:
    result = Fingerprint256.ZERO
    for f in fingerprints:
        result.block0 |= f.block0
        result.block1 |= f.block1
        result.block2 |= f.block2
        result.block3 |= f.block3
    return result

# Commutative, associative, idempotent. Cost: O(N) bitwise OR.
```

Used for:
- Temporal compression (detail → hour → day, §3.9.4)
- Paired-estate shared-context (§12.3)
- Tier contribution (§12.3)
- Moment-summary fingerprints (§8.7)

### §8.6. Fingerprint bitwise arithmetic combinators

```
function intersect_fingerprints(a: Fingerprint256,
                                 b: Fingerprint256) -> Fingerprint256:
    return Fingerprint256(
        block0 = a.block0 AND b.block0,
        block1 = a.block1 AND b.block1,
        block2 = a.block2 AND b.block2,
        block3 = a.block3 AND b.block3)

function difference_fingerprints(a: Fingerprint256,
                                  b: Fingerprint256) -> Fingerprint256:
    return Fingerprint256(
        block0 = a.block0 XOR b.block0,
        block1 = a.block1 XOR b.block1,
        block2 = a.block2 XOR b.block2,
        block3 = a.block3 XOR b.block3)

function prototype_of(cohort: [Fingerprint256]) -> Fingerprint256:
    # Bit i of prototype = 1 if > 50% of cohort have bit i set
    N = len(cohort)
    threshold = N / 2
    sums = [0; 256]
    for f in cohort:
        for i in 0..256:
            sums[i] += (f.bit(i) ? 1 : 0)
    return Fingerprint256.from_bits(
        [1 if sums[i] > threshold else 0 for i in 0..256])
```

All three are sub-microsecond per call. Used by `recall_by_fingerprint`
(§11.17).

### §8.7. Moment-summary fingerprints

```
function moment_summary(time_window: TimeRange) -> Fingerprint256:
    active_rows = filter_rows_bitslice(
        captured_during=time_window OR
        active_during=time_window OR
        bucket_within=time_window
    )
    if active_rows.empty: return Fingerprint256.ZERO
    return or_reduce([row.fingerprint for row in active_rows])

# Cost: O(N_active) bitwise OR. For typical 1-hour window with
# ~50 active rows: < 50 µs.
```

This is the substrate's "moment-level" query primitive — encodes
everything observed in a time window into a single 256-bit vector.
Used by `recall_moment_summary` (§11.15) and
`recall_similar_moments_by_summary` (§11.16).

### §8.8. Partial-state recall

```
function partial_match_score(row: Row, anchor: Fingerprint256,
                              match_blocks: Set<Int>,
                              differ_blocks: Set<Int>) -> Float:
    match_total_bits  = 64 * len(match_blocks)
    differ_total_bits = 64 * len(differ_blocks)
    match_distance  = hamming_distance(row.fingerprint, anchor,
                                       blocks=match_blocks)
    differ_distance = hamming_distance(row.fingerprint, anchor,
                                       blocks=differ_blocks)
    match_score  = 1.0 - (match_distance / match_total_bits)
    differ_score = differ_distance / differ_total_bits
    return match_score * differ_score
    # Range [0, 1]. High = matches on match_blocks AND differs on
    # differ_blocks.
```

Used by `recall_partial_match` (§11.10).

### §8.9. NMF alternating least squares

Specified in §6.9. See `nmf_factorize`.

### §8.10. FFT (rhythm analysis)

```
function rhythm_analysis(estate: Substrate,
                          block: Int,
                          bit_position: Int,
                          window_buckets: Int = 1024) -> RhythmResult:
    recent = estate.ambient_samples
                   .latest_n(window_buckets)
                   .sorted_by_time_asc()
    series = [s.fingerprint.bit(block * 64 + bit_position) ? 1.0 : 0.0
              for s in recent]
    spectrum = fft(series)
    magnitudes = [abs(c) for c in spectrum]
    dominant_period_bucket = argmax(magnitudes[1:len(magnitudes)/2])
    dominant_period_seconds = (window_buckets *
                                BUCKET_DURATION_SEC) / dominant_period_bucket
    return RhythmResult(
        dominant_period_seconds = dominant_period_seconds,
        spectral_energy = sum(magnitudes[1:])
    )

# Cost: O(N log N). N=1024: ~10 µs.
```

Aggregated across bits in a block: histogram of life-rhythms.
Used by `recall_rhythm_analysis` (§11.14).

### §8.11. Information-theoretic measures

```
function entropy(distribution: Map<FingerprintBucket, Int>) -> Float:
    N = sum(distribution.values())
    entropy = 0.0
    for count in distribution.values():
        if count > 0:
            p = count / N
            entropy -= p * log2(p)
    return entropy
    # Bits.

function mutual_information(joint: Map<(A, B), Int>,
                              marginal_a: Map<A, Int>,
                              marginal_b: Map<B, Int>) -> Float:
    N = sum(joint.values())
    mi = 0.0
    for ((a, b), count) in joint:
        if count > 0:
            p_ab = count / N
            p_a  = marginal_a[a] / N
            p_b  = marginal_b[b] / N
            mi += p_ab * log2(p_ab / (p_a * p_b))
    return mi
    # Bits.

function kl_divergence(p: Map<FingerprintBucket, Float>,
                        q: Map<FingerprintBucket, Float>) -> Float:
    kl = 0.0
    for bucket in p.keys():
        if p[bucket] > 0 and q.get(bucket, 0) > 0:
            kl += p[bucket] * log2(p[bucket] / q[bucket])
    return kl
    # Bits. Asymmetric: D(p||q) ≠ D(q||p).
```

Anomaly detection uses KL-divergence of current-window
fingerprint distribution from historical baseline. Used by
`recall_anomalous_moments` (§11.4) when the KL-mode is selected.

### §8.12. Bradley-Terry online update

```
function bradley_terry_update(w: WeightVector,
                               feature_a: FeatureVector,
                               feature_b: FeatureVector,
                               winner: 'A' | 'B',
                               eta: Float = 0.01) -> WeightVector:
    delta = feature_a - feature_b
    s = dot(w, delta)
    p_a_wins = sigmoid(s)
    if winner == 'A':
        gradient = (1.0 - p_a_wins) * delta
    else:  -- 'B'
        gradient = (-p_a_wins) * delta
    w_new = w + eta * gradient
    w_new = project_to_simplex(w_new)
    return w_new
    # Project: clip to non-negative, normalize to sum 1.

function project_to_simplex(w: Vector) -> Vector:
    w_clipped = max(w, 0)
    total = sum(w_clipped)
    if total < ε: return uniform_vector(len(w))
    return w_clipped / total
```

Used to learn W_tournament (§6.7, branch promotion feedback) and
W_ranking (§6.7, RecallTrace feedback).

### §8.13. Anomaly z-score (alternative to KL)

```
function anomaly_zscore(bucket: AmbientSample,
                        context_class: ContextClass) -> Float:
    historical = estate.ambient_samples
                       .for_context(context_class)
                       .exclude(bucket)
    mean_fp = or_reduce(historical.map(s -> s.fingerprint))
                                  # Approximate "centroid" via OR
    distances = [hamming_distance(s.fingerprint, mean_fp)
                 for s in historical]
    mu = mean(distances)
    sigma = stddev(distances) + ε
    actual_distance = hamming_distance(bucket.fingerprint, mean_fp)
    return (actual_distance - mu) / sigma
```

Z > 3.0 fires the anomaly standing signal (§15.1 rule 4). Used by
`recall_anomalous_moments` (§11.4) when in zscore-mode.

### §8.14. Temporal compression (cascading OR-reduction)

```
function compress_to_hourly(detail_buckets: [AmbientSample]) -> AmbientSample:
    hour_start = align_hour(detail_buckets[0].bucket_start)
    return AmbientSample(
        bucket_start = hour_start,
        bucket_duration_ms = 3600 * 1000,
        fingerprint = or_reduce([b.fingerprint for b in detail_buckets]),
        adjective_bitmap = aggregate_adjective(detail_buckets),
        operational_bitmap = aggregate_operational(detail_buckets),
        provenance_bitmap = aggregate_provenance(detail_buckets),
        signal_sources = bitwise_or([b.signal_sources for b in detail_buckets]),
        lattice_anchor = mode_anchor(detail_buckets),
    )

# Daily compression follows the same pattern with hour buckets.
```

Retention schedule (default, manifest-configurable):
- Detail (5-min): 90 days
- Hourly: 1 year
- Daily: indefinite

The dreaming daemon runs compression at the end of each retention
window.

### §8.15. Audit log fold (asOf reconstruction)

Specified in §5.3. See `project_state_at`.

### §8.16. Pairing-handshake protocol

Specified in §12.2.

---

## §9. The row-state finite-state automaton

### §9.1. State set Σ

```
Σ = {active, pending, contested, accepted,
     superseded, decayed, withdrawn, expired,
     rejected, tombstoned}

|Σ| = 10
```

Cluster mapping (per §2.3):
- Cluster A (active/becoming): active, pending, contested, accepted
- Cluster B (superseded/historical): superseded, decayed, withdrawn,
  expired
- Cluster C (terminal): rejected, tombstoned

### §9.2. Alphabet Σ_in (verb invocations)

```
Σ_in = {capture, reanchor, mutate.confirm, mutate.reject,
         mutate.contest, mutate.supersede, withdraw, expunge,
         dream.decay, dream.expire, dream.lineage_advance,
         actuator.confirm}
```

### §9.3. Transition function δ

```
δ(state, verb) -> state  | ⊥ (invalid transition)

# Capture creates rows in `active` (Drawer, AmbientSample, others)
# or `pending` (Proposal). Listed only for completeness:
δ(∅, capture(non_proposal)) = active
δ(∅, capture(proposal))     = pending

# From active:
δ(active, mutate.contest)   = contested
δ(active, mutate.supersede) = superseded
δ(active, withdraw)         = withdrawn
δ(active, expunge)          = tombstoned
δ(active, dream.decay)      = decayed
δ(active, dream.expire)     = expired

# From pending (Proposal lifecycle):
δ(pending, mutate.confirm)       = accepted
δ(pending, mutate.reject)        = rejected
δ(pending, mutate.contest)       = contested
δ(pending, actuator.confirm)     = accepted   -- case 2
δ(pending, withdraw)             = withdrawn
δ(pending, expunge)              = tombstoned

# From contested:
δ(contested, mutate.confirm)     = accepted
δ(contested, mutate.reject)      = rejected
δ(contested, mutate.supersede)   = superseded
δ(contested, withdraw)           = withdrawn

# From accepted (a confirmed proposal):
δ(accepted, mutate.contest)      = contested
δ(accepted, mutate.supersede)    = superseded
δ(accepted, withdraw)            = withdrawn
δ(accepted, expunge)             = tombstoned
δ(accepted, dream.decay)         = decayed

# From superseded:
δ(superseded, withdraw)          = withdrawn
δ(superseded, expunge)           = tombstoned
δ(superseded, dream.lineage_advance) = decayed
                                  -- when superseded by a lineage
                                  -- successor that also superseded
δ(superseded, mutate.confirm)    = active     -- "revive"
                                  -- ADMITTED by the automaton, which is
                                  -- stateless on (state, verb). The
                                  -- lineage-conflict rule (a superseded
                                  -- row may not revive while a living
                                  -- successor — a Cluster-A row sharing
                                  -- its lineage_id — holds the head) is a
                                  -- domain rule enforced one layer up at
                                  -- LocusKit's revive guard (§6.2), which
                                  -- has store access. Legal only when the
                                  -- head is vacant.

# From decayed:
δ(decayed, withdraw)             = withdrawn
δ(decayed, expunge)              = tombstoned
δ(decayed, mutate.confirm)       = active     -- "revived"

# From withdrawn:
δ(withdrawn, mutate.confirm)     = active     -- "unwithdraw"
δ(withdrawn, expunge)            = tombstoned

# From expired:
δ(expired, withdraw)             = withdrawn
δ(expired, expunge)              = tombstoned
δ(expired, mutate.confirm)       = active     -- "revive" (TTL revive;
                                  -- the revived row carries no fresh TTL
                                  -- until a later mutation sets one)

# From rejected:
δ(rejected, mutate.confirm)      = accepted   -- "second chance"
δ(rejected, expunge)             = tombstoned

# From tombstoned: TERMINAL, no transitions.
δ(tombstoned, _)                 = ⊥
```

All other (state, verb) pairs return ⊥.

**revive verb mapping.** The four `δ(cluster_B, mutate.confirm) = active`
edges above are the complete `revive` surface. The reference
implementation (`RowStateAutomaton`, both ports) keys these on the
canonical lifecycle verb `observe` ("re-observation revives"): the
§9-vocabulary transition table holds `(decayed|withdrawn|expired|
superseded, observe) → active`, while the §10 verb-string adapter
holds the equivalent `(…, "confirm") → active`. Both vocabularies share
the state set and agree on the revive surface. `tombstoned`, `rejected`,
and `accepted` have NO revive edge — they are not historical states.

### §9.4. Terminal states

`tombstoned` is the only absolute terminal state — no outgoing
transitions at all. Conformance: from `tombstoned` no further mutation
is accepted; the DrawerStateValidator returns
`SubstrateError.invalidStateTransition` for all attempted transitions.
The Cluster-C states `rejected` and `accepted` reach only `tombstoned`
(and `accepted` is barred even from that by S-3); they are terminal for
the purposes of `revive` (a rejection is a review verdict; an accepted
row is live audit-grade). The Cluster-B states are NOT terminal: each
carries a `revive` edge back to `active` (§9.3).

### §9.5. Forbidden combinations (I-22)

**I-22. Forbidden state-combination invariants.** The substrate
MUST reject any mutation that would produce:

- (state=secret) AND (exportability=public)   -- v0.35 I-3
- (state=accepted) AND (trust=verbatim)       -- accepted is for
                                                 proposals, verbatim
                                                 is for captures
- (state=tombstoned) AND (any audit row from the same actor with
                          state != tombstoned at a later HLC)
                       -- monotonic terminality

The DrawerStateValidator enforces all three. Implementations failing
to enforce are non-conforming.

**Removed in v0.36 (F17 amendment)** — the prior clause
`(state=tombstoned) AND (adjective_bitmap.expunge_completed_flag = 0)`
mis-classified a worklist marker as a state invariant. The named
`expunge_completed_flag` had no bit position in any §2.x layout
(phantom flag). The corrected design names the flag
`dreaming_recalc_required` and places it at §2.3 adjective bit 26;
its lifecycle is a liveness property (the dreaming pass MUST
eventually drain the worklist), not a safety invariant gated at
mutation time. See §9.5.1 for the content-vs-graph distinction and
§10.5 for the expunge verb's interaction with the flag.

### §9.5.1. Content versus graph — the two concerns expunge entangles

Two separable concerns are entangled in the word "expunge"; v0.36
F17 separates them:

1. **Content erasure is atomic and synchronous**, enforced at the
   storage layer. When `expunge` (§10.5) is called, the content blob
   is zeroed in the same transaction as the state transition to
   `tombstoned`, and the corresponding RAG vector is deleted via the
   cross-kit signal (§10.5 postconditions). This is a structural
   property of the verb — not a §9.5 invariant — and is verified by
   the storage layer's transactional guarantees, not by
   DrawerStateValidator.

2. **Graph reconciliation is deferred and asynchronous.** The
   expunged row's contribution to keystones (§7.2), tunnels (§7.1),
   associations (§7.3, §10.10), T-matrices (§6.4), Bradley-Terry
   pairings (§6.7), fingerprint clusters (§3), and per-row
   aggregates is now stale. The `dreaming_recalc_required` flag
   (§2.3 bit 26) is set synchronously on the tombstoned row by
   `expunge`; the dreaming pass clears the flag after reconciling
   the affected neighborhood. Rolled-up "little-big data" aggregates
   (matrix decay summaries, federation roll-ups, tier summaries)
   are NOT walked — they remain valid statistical summaries because
   their identifying attribution has already been erased.

The flag generalizes beyond expunge: any future operation that
invalidates a row's graph contribution (mass-mutation, lineage
rewrite, federation rejoin) sets the same flag and reuses the same
dreaming-pass machinery. The flag's polarity is *obligation*, not
*state*: 1 = recalc owed (just disturbed, or queued for dreaming);
0 = no recalc owed (either never disturbed, or dreaming has visited
since the last disturbance). No second "has been dreamed" evidence
bit is needed because dreaming is the only writer that clears the
flag, so flag=0 implicitly means "either fresh or reconciled."

**Liveness.** The dreaming pass MUST eventually drain the
worklist. Implementations MUST schedule a dreaming pass within a
configurable bound after the worklist becomes non-empty (default:
next dreaming-eligible window). The pass is idempotent —
crash-restart safely reprocesses any row still flagged.

### §9.6. Reachability proof

*Claim.* Every state in Σ is reachable from `∅` (no row) via some
verb sequence starting with `capture`.

*Proof.* By construction (forward enumeration over §9.3):
- active: capture(non_proposal)
- pending: capture(proposal)
- contested: capture(...); mutate.contest
- accepted: capture(proposal); mutate.confirm
- superseded: capture(...); mutate.supersede
- decayed: capture(...); dream.decay
- withdrawn: capture(...); withdraw
- expired: capture(...); dream.expire
- rejected: capture(proposal); mutate.reject
- tombstoned: capture(...); expunge

All ten reachable; reachability complete. ∎

### §9.7. Liveness proof

*Claim.* Every non-terminal state has at least one outgoing
transition.

*Proof.* By enumeration over §9.3, each of {active, pending,
contested, accepted, superseded, decayed, withdrawn, expired,
rejected} has at least one defined transition. Only `tombstoned`
has none, and it is the designated terminal. ∎

### §9.8. Safety proof

*Claim.* The forbidden combinations of §9.5 are unreachable through
any legal verb sequence.

*Proof.* The DrawerStateValidator (§2.9 C1 resolution) intercepts
every mutation path. A proposed mutation that would produce a
forbidden combination is rejected before bitmap write. Audit log
never contains a write to a forbidden state. By induction over the
audit log: at every prefix, the projected state satisfies the
invariants. ∎

### §9.9. DrawerStateValidator conformance

LocusKit's `DrawerStateValidator` MUST implement:

```
function canTransition(from: State, to: State, via: Verb) -> Bool:
    expected_to = transition_table[(from, via)]   -- per §9.3
    if expected_to is None: return false
    return expected_to == to

function isLegalRowState(adjective: Int64, operational: Int64,
                          provenance: Int64, noun_type: NounType) -> Result<(), SubstrateError>:
    # Checks all §9.5 forbidden combinations
    state = extract_state(adjective)
    sensitivity = extract_sensitivity(adjective)
    exportability = extract_exportability(adjective)
    trust = extract_trust(adjective)
    if state == TOMBSTONED && !has_expunge_completed_flag(operational):
        return Err(InvalidStateForOperationalFlags)
    if sensitivity == SECRET && exportability == PUBLIC:
        return Err(SecretCannotBePublic)
    if state == ACCEPTED && trust == VERBATIM:
        return Err(AcceptedCannotBeVerbatim)
    return Ok(())
```

Both `canTransition` and `isLegalRowState` MUST be invoked on every
write path: `capture`, `mutateAdjective`, `mutateState`, `mutateOperational`,
`reanchor`, `withdraw`, `expunge`, `propose`, `associate`, `learn`.
This addresses v0.35 issue C1 (§2.9).

---

## §10. The nine verbs

Each verb specification gives: signature, preconditions,
postconditions, audit emissions, error modes.

### §10.1. capture

```
capture(noun_type: NounType, content: Blob,
        adjectives: AdjectiveSet, operational_overrides: OperationalOverrides,
        lattice_anchor: LatticeAnchor,
        provenance_origin: SourceType) -> Result<RowId, SubstrateError>
```

**Preconditions.** `noun_type` is one of v0.36's eight noun types
(§2). `lattice_anchor` is present (I-16). The combination of
adjectives passes `isLegalRowState` (§9.9).

**Postconditions.**
- New row created with `state = active` (non-proposal) or `state =
  pending` (proposal). The state must be in cluster A
  (accepting); capture cannot start at `contested`, `withdrawn`,
  or any later-cluster value. Tests that need such states must
  capture-active then mutate.
- Row identity is a UUID (I-29). Deterministic-ingest callers
  derive a deterministic UUID from their natural key rather than
  supplying a free string.
- `trust` defaulted per `provenance_origin`.
- Fingerprint computed (§3.6).
- F-matrix incremented (§6.1).
- O-matrix updated for new (field, value) pairs (§6.3).
- **One sealed `AuditEvent` written through `AuditGate.admit`**
  with `prior = none` and `after = the captured state` (I-26).
  This is the genesis event. The capture verb is the fifth gated
  write path joining the four mutators; the gate's `prior == nil`
  branch runs `ForbiddenCombinations.check` over the captured
  basis (I-22 enforcement). HLC stamped from `HLCGenerator.tick`
  (I-28). Seal stamped per custody mode (§5.8): strict writes
  `sealed = 1` and the SHA-256 inline; lazy writes `sealed = 0`
  and defers the SHA-256 to the dreaming pass.
- If noun_type = AmbientSample, T-matrix-eligible: queued for
  dreaming-daemon pass.

**Errors.**
- `SubstrateError.invalidStateTransition` if `isLegalRowState` fails.
- `SubstrateError.missingLatticeAnchor` if `lattice_anchor` is null.
- `SubstrateError.invalidNounType` for unknown noun type.
- `SubstrateError.invalidRowID` if the supplied id does not parse
  as a UUID (I-29).

### §10.2. reanchor

```
reanchor(row_id: RowId, new_lattice_anchor: LatticeAnchor,
         new_room: Option<RoomId>, new_wing: Option<WingId>) -> Result<(), SubstrateError>
```

**Preconditions.** Row exists, state ≠ tombstoned. `new_lattice_anchor` resolvable.

**Postconditions.** Lattice anchor updated. Block 1 (lattice-LSH)
of fingerprint recomputed. Other blocks unchanged. F/O/T matrices
updated for lattice-derived fields only.

**Audit.** before/after both include `lattice_anchor` and Block 1
of fingerprint.

### §10.3. mutate

```
mutate(row_id: RowId, mutation_kind: MutationKind,
       new_adjectives: AdjectiveSet) -> Result<(), SubstrateError>

MutationKind = confirm | reject | contest | supersede |
               automated_confirm | decay | expire | lineage_advance
```

**Preconditions.**
- `DrawerStateValidator.canTransition(row.state, new_state, via=mutation_kind)`
  returns true (§9.9). [C1 resolution].
- `isLegalRowState(new_adjective_bitmap, ...)` returns Ok.

**Postconditions.**
- Adjective bitmap updated.
- Fingerprint Block 0 (bitmap-LSH) recomputed.
- F-matrix decremented for old values, incremented for new.
- O-matrix updates as needed.
- If mutation produced state transition to/from a co-activation
  partner, T-matrix is dreaming-queued.

**Audit.** Full before/after bitmaps, mutation_kind, HLC.

### §10.4. withdraw

```
withdraw(row_id: RowId, reason: Option<String>) -> Result<(), SubstrateError>
```

**Preconditions.** State ∈ {active, pending, contested, accepted,
superseded, decayed, expired, rejected}. State ≠ tombstoned.

**Postconditions.** state = withdrawn. Row remains visible to
asOf queries before the withdraw HLC.

### §10.5. expunge

```
expunge(row_id: RowId, reason: String) -> Result<(), SubstrateError>
```

**Preconditions.** None beyond row existing.

**Postconditions.**
- state = tombstoned.
- Content blob zeroized in the same transaction as the state
  transition (atomic; verbatim sacred only up to expunge; spec §6.6
  of v0.35 governs).
- Corresponding RAG vector deleted via cross-kit signal (GLK
  orchestrates the redact verb across kits; LocusKit performs the
  tombstone + content-zero, RAG/VectorKit performs the vector
  delete, both within the redact transaction).
- `dreaming_recalc_required` flag (§2.3 bit 26) set on the
  tombstoned row, synchronously, before the verb returns.
- All matrices decremented as if the row were never captured (lazy
  via dreaming pass, driven by `dreaming_recalc_required`).
- Rolled-up aggregates (matrix decay summaries, federation
  roll-ups, tier summaries — "little-big data") NOT touched — they
  remain valid statistical summaries; per §9.5.1.
- Audit row tombstoned (per v0.35 I-6); fact-of-expunge preserved.
- **Keyed-commitment provenance.** After content-zero
  and RAG-vector deletion, the snapshot attestation for the
  affected wing (or corpus source) is invalidated. A new snapshot
  with recomputed Merkle roots must be taken to re-establish
  integrity — the old root covered the now-zeroed content. This is
  a natural consequence of the Merkle composition (§5.12): the
  per-wing and per-corpus roots are content-dependent, so expunge
  necessarily invalidates them. The fact-of-expunge (audit trail)
  plus the old/new snapshot pair constitutes the keyed-commitment
  provenance chain: "content existed (old root covers it), was
  expunged (audit event), and the tree now reflects its absence
  (new root excludes it)."

### §10.6. recall

```
recall(query: RecallQuery) -> Result<RecallResult, SubstrateError>

RecallQuery = {
    filter: BitmapPredicate,
    rank_by: RankingMode,
    limit: Int,
    as_of: Option<HLC>,
    trace: Option<TraceShape>,
}

RankingMode = bitmap_only | composite_distance | latent_factor |
              keystone | rhythm_phase_locked | partial_match | ...
```

Read-only. Drives every CognitionKit primitive (§11).
RecallTrace (v0.35 §A.1) is emitted when `trace` is set;
feedback shapes Bradley-Terry updates (§8.12).

### §10.7. propose

```
propose(target: RowReference, proposal_kind: ProposalKind,
        candidate_state: AdjectiveSet,
        justification: Option<String>,
        generated_by_class: GeneratedByClass) -> Result<RowId, SubstrateError>
```

Creates a Proposal row with state = pending. Substrate standing
signals invoke this; agents invoke this; the propose path is the
only autonomous write surface (case 2 confirms).

### §10.8. associate

```
associate(a: RowReference, b: RowReference,
          signal_sources: Bitset, weight: Float) -> Result<RowId, SubstrateError>
```

Creates or strengthens an Association row. Used by the dreaming
daemon to record dream-pairings, co-recall, vector similarity,
etc.

### §10.9. learn

```
learn(reference_uri: String, mode: LearnMode,
      source: LearnedReferenceSource,
      refresh_policy: RefreshPolicy) -> Result<RowId, SubstrateError>
```

Ingests a LearnedReference. `source` includes the new v0.36
values: `household_pairing`, `fleet_pairing`, `tier_inheritance`,
`paired_estate`.

---

## §11. CognitionKit primitives

Each primitive: signature, math, cost, RecallTrace shape (for
W_ranking updates).

### §11.1. recall_about

```
recall_about(topic: TopicAnchor, limit: Int = 10) -> [Drawer]
```

Math: composite_distance with `alpha_lattice` dominant. Top-K rows
by ascending distance.

### §11.2. recall_similar_moments

```
recall_similar_moments(anchor: AmbientSample | Fingerprint256,
                        limit: Int = 10) -> [AmbientSample]
```

Math: hamming_nn over AmbientSamples. Top-K by ascending Hamming.

### §11.3. recall_during

```
recall_during(time_range: TimeRange,
              fingerprint_filter: Optional<Fingerprint256>) -> [Drawer | AmbientSample]
```

Math: bitmap filter (capture_time ∈ time_range) ∧ optional
fingerprint match within Hamming threshold.

### §11.4. recall_anomalous_moments

```
recall_anomalous_moments(threshold: Float = 3.0,
                          mode: AnomalyMode = zscore,
                          limit: Int = 10) -> [AmbientSample]
```

Math: per §8.13 (zscore) or §8.11 (KL-divergence).

### §11.5. recall_current_posture

```
recall_current_posture(window: TimeRange = LAST_HOUR) -> Fingerprint256
```

Math: or_reduce over AmbientSamples within window. §8.5 / §8.7.

### §11.6. recall_action_outcomes (case 2)

```
recall_action_outcomes(action_kind: ActionKind,
                        context_fingerprint: Fingerprint256,
                        limit: Int = 10) -> [(Proposal, OutcomeRecord)]
```

Math: query ActionOutcomes matrix (§6.5) indexed by
(action_kind, context_fingerprint_bucket). Returns top historical
actions of this kind in similar context with their outcomes.

### §11.7. recall_household_context (case 1)

```
recall_household_context(window: TimeRange) -> HouseholdContext
```

Math: queries `co_present` Tunnel rows within window, returns
shared-context fingerprint plus list of paired estates currently
matching.

### §11.8. recall_fleet_context (case 2)

```
recall_fleet_context(window: TimeRange) -> FleetContext
```

Math: or_reduce over fleet-shared contributions; cross-machine
posture aggregate.

### §11.9. recall_with_advisory (case 3)

```
recall_with_advisory(query: RecallQuery,
                      tier_ascent_levels: [TierLevel] = []) -> AdvisoryResult
```

Math: tier-ascending query protocol (§12.4). Each tier processes
query against its tier-shared cognition; response flows back
enriched.

### §11.10. recall_partial_match (NEW)

```
recall_partial_match(anchor: Fingerprint256,
                      match_blocks: Set<Int>,
                      differ_blocks: Set<Int>,
                      limit: Int = 10) -> [Row]
```

Math: §8.8 partial_match_score. Top-K by descending score.

### §11.11. recall_keystone (NEW)

```
recall_keystone(scope: LatticeSubtree | TimeWindow | EstateWide,
                 limit: Int = 10) -> [Row]
```

Math: lookup `row_keystone_score` (cached eigenvalue centrality,
§7.2) filtered by scope. Top-K descending.

### §11.12. recall_latent_factors (NEW)

```
recall_latent_factors(limit: Int = 10) -> [LatentFactor]

LatentFactor = {
    id: Int,
    factor_vector: Vector,    -- in W from NMF
    top_loading_rows: [RowId],
}
```

Math: NMF factorization cache (§6.9). Returns top-K factors by
singular value.

### §11.13. recall_loading_on_factor (NEW)

```
recall_loading_on_factor(factor_id: Int, limit: Int = 10) -> [Row]
```

Math: extract column `factor_id` from W; sort rows by loading
value; top-K descending.

### §11.14. recall_rhythm_analysis (NEW)

```
recall_rhythm_analysis(window_buckets: Int = 1024) -> RhythmReport

RhythmReport = {
    rhythms: [(bit_position, dominant_period_seconds, energy)]
    dominant_rhythm: (period_seconds, label)
}
```

Math: §8.10 FFT over each bit position in the temporal block.

### §11.15. recall_moment_summary (NEW)

```
recall_moment_summary(time_window: TimeRange) -> Fingerprint256
```

Math: §8.7 moment_summary.

### §11.16. recall_similar_moments_by_summary (NEW)

```
recall_similar_moments_by_summary(anchor_window: TimeRange,
                                    limit: Int = 10) -> [TimeRange]
```

Math: compute `moment_summary(anchor_window)` then hamming_nn
against historical hour-summary fingerprints.

### §11.17. recall_by_fingerprint (with arithmetic combinators) (NEW)

```
recall_by_fingerprint(build_anchor: FingerprintBuilder,
                       limit: Int = 10) -> [Row]

FingerprintBuilder =
    | LiteralFingerprint(Fingerprint256)
    | Intersect(Builder, Builder)
    | Difference(Builder, Builder)
    | PrototypeOf(CohortFilter)
```

Math: evaluate builder to concrete Fingerprint256 (§8.6), then
hamming_nn.

### §11.18. propose_action (case 2 write surface)

```
propose_action(action_kind: ActionKind, parameters: Json,
                justification: String, confidence: Float) -> ProposalId
```

Math: invokes propose verb (§10.7) with operational bitmap encoding
the action_kind and confidence_bucket. ActuatorKit (§14) polls
pending action proposals.

---

## §12. Federation primitives

### §12.1. Pairing algebra (I-23)

**I-23. Pairing algebra.** The pairing relation P over estates
satisfies:

- **Reflexive.** ∀ estate E: E P E (every estate is paired with
  itself for its own seeds).
- **Symmetric.** ∀ E_A, E_B: E_A P E_B ⇒ E_B P E_A (pairing is
  bidirectional).
- **Not transitive.** E_A P E_B and E_B P E_C does NOT imply
  E_A P E_C. Each pairing requires explicit seed exchange.

Hierarchy (case 3) is NOT implicit pairing. User-tier participation
in company-tier requires explicit user↔company pairing; user has no
direct fingerprint compatibility with the industry tier above.

Implementations MUST refuse fingerprint comparisons across estate
pairs that lack explicit shared seeds.

### §12.2. Shared hyperplane seed exchange

```
function pairing_handshake(initiator: Estate,
                            responder: Estate,
                            scope: PairingScope) -> Result<H_shared, Error>:
    # 1. Initiator generates fresh 64-byte hyperplane bundle.
    H_proposed = generate_hyperplane_family(scope)

    # 2. Both estates verify identity via signed handshake
    #    (TLS-style; transport-layer concern).

    # 3. Both estates write LearnedReference rows minted from the
    #    same source-bundle, with shared lattice-anchor identifier.

    # 4. Both estates record H_proposed in
    #    manifest.shared_hyperplane_seeds[scope].

    # 5. Audit rows on both sides:
    #    actor = pairing_handshake,
    #    after = { shared_seeds[scope] = hash(H_proposed) }
    return Ok(H_proposed)

PairingScope = household | fleet | company | industry | msp
```

Transport: AirDrop, QR code, CloudKit shared zone, or signed-cert
exchange. Pick one per deployment; v1 defaults to QR code for
simplicity.

### §12.2.1. Pairing seed derivation

The shared hyperplane family of a pairing (§12.2) is generated
deterministically from a single u64 **pairing seed**. Both estates
compute the identical seed from the same three inputs, so neither side
needs to transmit the family itself — only the 32-byte nonce crosses the
wire. The seed feeds `expand_seed_64` → `block_families` (§3.7) to
produce the four shared hyperplane blocks.

**Inputs.**

- `nonce` — 32 bytes, the freshly exchanged pairing nonce.
- `estate_a`, `estate_b` — the two 16-byte estate UUIDs. Order of the
  two arguments does **not** affect the result (see *Symmetry* below);
  this realizes the symmetry requirement of the pairing algebra (I-23,
  §12.1).

**Algorithm.** A single FNV-1a running hash is initialized once, fed the
32 nonce bytes in file order, then fed the 16 bytes of the
**lexicographically smaller** estate UUID, in file order. The final
64-bit accumulator **is** the pairing seed. There is no truncation,
fold, or post-mix.

```
function pairing_seed(nonce: bytes(32),
                      estate_a: bytes(16),
                      estate_b: bytes(16)) -> u64:
    # 1. Lexicographic unsigned-byte comparison picks the lower UUID.
    #    Both UUIDs are exactly 16 bytes, so this is a plain byte-array
    #    compare: compare byte 0, then byte 1, ... first differing byte
    #    (as unsigned 0..255) decides; equal arrays are equal.
    lower = estate_a if estate_a <= estate_b else estate_b

    # 2. FNV-1a, 64-bit. Offset basis and prime are the standard
    #    FNV-1a-64 constants.
    h = 0xCBF29CE484222325          # FNV-1a-64 offset basis
    for b in nonce:                 # all 32 nonce bytes, file order
        h = h XOR b                 # XOR the byte into the low 8 bits
        h = (h * 0x00000100000001B3) mod 2^64   # FNV-1a-64 prime, wrap to u64
    for b in lower:                 # all 16 bytes of the lower UUID, file order
        h = h XOR b
        h = (h * 0x00000100000001B3) mod 2^64

    # 3. The accumulator is the seed. No truncation.
    return h
```

**Exact constants (hex).**

| Constant | Value |
|---|---|
| FNV-1a-64 offset basis | `0xCBF29CE484222325` |
| FNV-1a-64 prime | `0x00000100000001B3` |
| Modulus (multiply wraps) | `2^64` (`& 0xFFFFFFFFFFFFFFFF`) |

**Byte order and operation order — the federation-critical details.**

1. **Hash order is nonce-then-lower-UUID, never the reverse.** The 32
   nonce bytes are consumed first, then the 16 UUID bytes. Swapping the
   two segments produces a different, wrong seed.
2. **Bytes are consumed in file order** (index 0 first) for both
   segments. The nonce and the UUID are byte arrays on the wire; they
   are fed in array order. No endianness reinterpretation of either
   segment occurs before hashing — they are byte streams, not integers.
3. **FNV-1a order is XOR-then-multiply** (the *-1a* variant), per byte,
   for every one of the 48 bytes (32 + 16).
4. **All arithmetic is modulo 2^64.** Rust wraps natively
   (`wrapping_mul`); a port in Python/Go/JS MUST mask each multiply to
   64 bits (`& 0xFFFFFFFFFFFFFFFF`) or the seed diverges silently.
5. **No truncation or fold.** Unlike the lattice/channel FNV uses
   (§3.3, §3.5) that truncate FNV-1a to 16/8 bits, the pairing seed is
   the *full* 64-bit accumulator. Do not apply `& 0xFFFF`.
6. **Serialization is little-endian u64.** Where the seed is committed
   or transmitted as bytes (e.g. conformance vectors), it is the
   little-endian rendering of the u64 (`seed.to_le_bytes()`).

**Symmetry.** Because the hash consumes `min(estate_a, estate_b)` rather
than a fixed argument position, `pairing_seed(n, A, B)` equals
`pairing_seed(n, B, A)` for all `n, A, B`. This is what makes the shared
family bit-comparable regardless of which estate initiated the
handshake.

**Edge cases.**

- **Equal identifiers** (`estate_a == estate_b`): the comparison
  `estate_a <= estate_b` is true, so `estate_a` is selected; since the
  two arrays are byte-identical the choice is immaterial and the seed is
  well-defined. This is the reflexive case of the pairing algebra (I-23,
  §12.1): an estate's seed with itself.
- **Length differences:** none possible. The nonce is always exactly 32
  bytes and each estate UUID is always exactly 16 bytes; both are
  fixed-width in the data model. A port should `assert len(nonce) == 32`
  and `assert len(uuid) == 16` rather than handle variable lengths. The
  lexicographic compare is therefore always between two equal-length
  16-byte arrays — Rust's `[u8; 16] <= [u8; 16]` and Python's
  `bytes <= bytes` agree exactly here.
- **All-zero nonce or UUID:** no special-casing; zero bytes XOR/multiply
  through the FNV-1a accumulator like any other byte value.

### §12.3. Tier contribution fingerprints

```
function generate_contribution(estate: Estate,
                                scope: PairingScope,
                                window: TimeRange) -> Fingerprint256:
    # 1. Collect contributing rows from window per scope-rule.
    contributing = estate.rows_in_window(window)
                          .filter(scope.contribution_rule)
                          # e.g., for household: exclude HR, attention,
                          # messages metadata. For tier: exclude
                          # rows with sensitivity > tier.allowed_max.

    # 2. Recompute fingerprints under shared seeds for those rows.
    H_shared = estate.manifest.shared_hyperplane_seeds[scope]
    shared_fps = [recompute_fingerprint(row, H_shared)
                  for row in contributing]

    # 3. OR-reduce.
    contribution = or_reduce(shared_fps)

    # 4. Audit emission.
    estate.audit.append(ContributionGenerated(scope, window, contribution))

    return contribution
```

Cadence (default; manifest-configurable):
- User → Company: hourly
- Company → Industry: daily
- Industry → MSP: weekly

### §12.4. Tier-ascending query protocol

```
function tier_ascending_query(query: RecallQuery,
                                 levels: [TierLevel]) -> AdvisoryResult:
    # 1. Process locally.
    local_result = local_estate.recall(query)

    # 2. For each level in ascending order:
    response_chain = [local_result]
    for level in levels:
        # Translate query upward.
        upward_query = translate_query(query, scope=level)
        # Receive: structured response from level's estate.
        upper_response = federation.send_to(level, upward_query)
        response_chain.append(upper_response)
        # Stop on opt-out or error.
        if upper_response.opted_out: break

    # 3. Descend, enriching at each tier.
    final = response_chain.last()
    for response in response_chain.reverse_remaining():
        final = enrich(final, response.tier_context)
    return final
```

Each tier processes its own tier-shared cognition (Tier-3 matrices,
Tier-4 patterns) against the upward-translated query. Returns
structured advisory data; the user's local CognitionKit composes
the final response.

### §12.5. OR-reduction at tier boundaries

Per §8.5. Tier-aggregation OR-reduces contribution fingerprints
from N participating sub-estates. Result is the next-tier
contribution.

### §12.6. Differential privacy modifications (I-24)

**I-24. Tier aggregation provides (ε, δ)-DP.** For
tier-boundary aggregation:

```
function dp_or_reduce(contributions: [Fingerprint256],
                       epsilon: Float = 1.0,
                       p_flip: Float) -> Fingerprint256:
    # Bit-flip each contribution's bit with probability p_flip.
    flipped = [randomize_bits(c, p_flip) for c in contributions]
    return or_reduce(flipped)

# Calibration of p_flip for desired epsilon:
# For randomized-response, ε = log((1-p_flip)/p_flip).
# epsilon = 1.0 → p_flip ≈ 0.27
# epsilon = 0.5 → p_flip ≈ 0.38
```

Default at v0.38 release: ε = 1.0 at all tier boundaries.
Manifest-configurable per tier.

Alternative: Mitigation B (contribution provenance audit, §3.D of
the cross-case analysis) — log which contributions arrived from
which sub-estates and re-aggregate excluding suspected adversarial
contributions. Cheap; the audit log already supports it. Required
as a minimum at all multi-tenant deployments per case 3.

### §12.7. Anonymization discipline

At each tier boundary, the contributing estate's sensitivity ceiling
constrains what may cross. If `sensitivity_at_capture` of any
contributing row exceeds the tier's `max_allowed_sensitivity`
(manifest setting), the row's fingerprint is excluded from
contribution.

Default ceilings:
- Household tier: `restricted` (32)
- Fleet tier: `restricted` (32)
- Company tier: `elevated` (16)
- Industry tier: `elevated` (16)
- MSP tier: `normal` (0)

Each tier's manifest declares its `max_allowed_sensitivity`; the
contributing estate enforces.

---

## §13. Portable Cognition Bundle

### §13.1. Format

```
PortableCognitionBundle (JSON + binary mixed):
{
  schema_version: "0.36",
  estate_uuid_origin: UUID,
  bundle_generated_at: HLC,

  hyperplane_seeds: {
    H_0, H_1, H_2, H_3
  },

  tier_3_matrices: {
    F: { encoding: "dense", data: ... },
    O: { encoding: "csr", indices: [...], values: [...] },
    T: { encoding: "csr", indices: [...], values: [...] },
    ActionOutcomes: ...        -- if case 2
  },

  calibration_curves: {
    [model_id]: [{ bucket, count, success_rate }, ...]
  },

  ranking_weights: {
    W_tournament: [5 floats],
    W_ranking: [12][5 floats]
  },

  latent_factors: {
    W: { encoding: "dense", data: ... },
    H: { encoding: "dense", data: ... }
  },

  lineage_taxonomy: [
    { cluster_name, member_lineage_ids: [...] }
  ],

  anchor_catalog: {
    high_frequency_qids: [Q-ID, count, closure_cached],
    high_frequency_udc_prefixes: [...]
  }
}
```

Total bundle size: typically 1-5 MB.

No row-level data. No content. No audit log. No fingerprints of
specific rows. The bundle is a *behavioral model*, not a copy of
the estate.

### §13.2. Export algorithm

```
function export_cognition_bundle(estate: Estate) -> Bundle:
    bundle = Bundle.new(schema_version="0.36",
                         estate_uuid_origin=estate.uuid)
    bundle.hyperplane_seeds = estate.manifest.hyperplane_seeds
    bundle.tier_3_matrices = estate.matrices.snapshot()
    bundle.calibration_curves = estate.calibration.snapshot()
    bundle.ranking_weights = {
        W_tournament: estate.manifest.tournament_weights,
        W_ranking: estate.manifest.ranking_weights,
    }
    bundle.latent_factors = estate.matrices.nmf_factors
    bundle.lineage_taxonomy = estate.lineage.taxonomy
    bundle.anchor_catalog = estate.lattice.high_frequency_anchors
    # Audit:
    estate.audit.append(CognitionBundleExported(
        bundle_hash=hash(bundle), to_recipient=?))
    return bundle
```

### §13.3. Import algorithm

```
function import_cognition_bundle(target: Estate, bundle: Bundle,
                                   mode: ImportMode) -> Result<(), Error>:
    if mode == ColdStartPriors:
        # Replace existing seeds and matrices with bundle's.
        target.manifest.hyperplane_seeds = bundle.hyperplane_seeds
        target.matrices = bundle.tier_3_matrices.clone()
        target.calibration = bundle.calibration_curves.clone()
        target.manifest.tournament_weights = bundle.ranking_weights.W_tournament
        target.manifest.ranking_weights = bundle.ranking_weights.W_ranking
        target.lineage.taxonomy = bundle.lineage_taxonomy
        target.lattice.preload_anchor_catalog(bundle.anchor_catalog)
    elif mode == MergeWithExisting:
        # Weighted average / union with existing.
        target.matrices.merge(bundle.tier_3_matrices, weight=0.5)
        target.calibration.merge(bundle.calibration_curves)
        # ...

    target.audit.append(CognitionImportedFrom(
        bundle.estate_uuid_origin, bundle.bundle_generated_at, mode))
    return Ok(())

ImportMode = ColdStartPriors | MergeWithExisting
```

---

## §14. ActuatorKit (case 2)

### §14.1. Architecture

```
┌──────────────────────────────────────────────┐
│  GeniusLocus substrate                       │
│  - Reads via CognitionKit primitives         │
│  - Writes only via propose_action(...)       │
└─────────────────┬────────────────────────────┘
                  │
                  │ pending_action proposals
                  ▼
┌──────────────────────────────────────────────┐
│  ActuatorKit (polling loop)                  │
│  - Polls substrate.pending_proposals()       │
│  - For each:                                 │
│    1. validate_policy(proposal)              │
│    2. if valid: execute(proposal)            │
│    3. capture outcome → mutate(automated_confirm) │
│  - Severity / blast-radius checks            │
└──────────────────────────────────────────────┘
```

### §14.2. Validation policy schema

```
ActionPolicy {
    action_kind: ActionKind,
    description: String,
    parameter_bounds: ParameterSchema,
    blast_radius: BlastRadius,  -- {minimal, contained, broad, irreversible}
    severity: Severity,         -- {advisory, low_risk, medium_risk,
                                    high_risk, critical}
    confidence_floor: Float,    -- minimum (calibrated) confidence required
    cooldown_seconds: Int,      -- minimum time between executions
    sandboxed: Bool,            -- run in sandbox or directly
}
```

Stored in `actuator_policies` manifest section.

### §14.3. Action allowlist

```
function validate(proposal: ActionProposal,
                  calibration: CalibrationCurves) -> Result<(), Error>:
    policy = actuator_policies.get(proposal.action_kind)
    if policy is None: return Err(NotAllowlisted)

    # Confidence calibration:
    bucket = floor(proposal.confidence * 20)
    empirical = calibration[proposal.model_id][bucket].success_rate
    if empirical < policy.confidence_floor:
        return Err(BelowCalibratedConfidenceFloor)

    if !policy.parameter_bounds.check(proposal.parameters):
        return Err(ParametersOutOfBounds)

    if !cooldown_satisfied(proposal.action_kind, policy.cooldown_seconds):
        return Err(CooldownNotMet)

    return Ok(())
```

### §14.4. Outcome capture

```
function execute_and_capture(proposal: ActionProposal,
                                policy: ActionPolicy) -> Outcome:
    # Execute (sandboxed if policy demands).
    result = execute_via_platform(proposal.action_kind,
                                   proposal.parameters,
                                   sandboxed=policy.sandboxed)

    outcome = Outcome.from(result, proposal)
    # Confirm proposal via mutate verb.
    substrate.mutate(proposal.id,
                      mutation_kind=automated_confirm,
                      new_adjectives={state: accepted})
    # Record outcome in substrate.
    substrate.capture(noun_type=DiaryEntry,
                       content=outcome.serialize(),
                       provenance_origin=actuator)
    # Update calibration for the originating model.
    update_calibration(proposal.model_id, proposal.confidence, outcome.success)
    return outcome
```

### §14.5. Follow-up assessment

```
function followup_signal(proposal: ActionProposal,
                          observation_window: Duration):
    # Scheduled by ActuatorKit to run at proposal.executed_at + window.
    anomaly_resolved = check_anomaly_resolved(
        proposal.related_anomaly_fingerprint,
        proposal.executed_at,
        proposal.executed_at + observation_window)
    if anomaly_resolved:
        outcome = resolved
    else:
        outcome = persisted
    update_action_outcomes_matrix(
        proposal.action_kind,
        proposal.context_fingerprint,
        outcome)
```

### §14.6. Severity classification

Default policies per severity (manifest-overridable):

| Severity | Confidence floor | Cooldown | Auto-execute? | Sandboxed? |
|----------|------------------|----------|---------------|------------|
| advisory | 0.0 (any) | 0 sec | yes | yes |
| low_risk | 0.5 | 60 sec | yes | yes |
| medium_risk | 0.7 | 300 sec | yes | yes |
| high_risk | 0.9 (after calibration) | 3600 sec | no (human-confirm required) | yes |
| critical | 0.95 + human confirm | 86400 sec | no | yes |

---

## §15. Dreaming daemon

### §15.1. Five update rules

```
Rule 1: On Drawer/AmbientSample insert (synchronous, capture time)
  - Compute fingerprint (§3.6)
  - Increment F (§6.1)
  - Increment O for (field, value) pairs in this row (§6.3)
  - Queue T-eligibility for next dreaming pass

Rule 2: On Proposal promotion (synchronous, mutate.confirm)
  - Bradley-Terry update W_tournament (§8.12)
  - For confirmed proposals tied to action outcomes,
    update ActionOutcomes matrix (§6.5)

Rule 3: On RecallTraceItem.used (synchronous, recall feedback)
  - Bradley-Terry update W_ranking for the originating primitive
    (§8.12)
  - Per-tier feedback signal: tier that ranked the used row high
    gets positive; tier that ranked the unused row high gets
    negative

Rule 4: Every 5-minute boundary (background, device-edge)
  - For each enabled signal stream: extract feature vector,
    SimHash into appropriate fingerprint block, write
    AmbientSample row via capture
  - Z-score / KL-divergence anomaly check against historical
    fingerprint distribution for this time-of-day context
  - If anomaly threshold exceeded: propose_action(record_anomaly)

Rule 5: On retention thresholds (dreaming pass, hourly/daily)
  - At end of 90-day window: OR-reduce 12 detail buckets per hour
    into hour-bucket, delete detail buckets (§8.14)
  - At end of 1-year window: OR-reduce 24 hour-buckets per day
    into day-bucket, delete hour-buckets

Additional dreaming-only rules (cold path):
Rule 6: Weekly C-matrix recompute from F
Rule 7: Weekly Σ(M·M.T) signature recompute
Rule 8: Weekly NMF factorization of O
Rule 9: Weekly T-matrix incremental update from co-active rows
Rule 10: Daily eigenvalue centrality (keystone scores)
Rule 11: Daily community detection (auto-rooming proposals)
Rule 12: Daily decay-pass (matrices with non-None half-life, §6.8)
Rule 13: Hourly per-context-tier contribution fingerprint generation
         (§12.3, when paired)
```

### §15.2. Schedule

| Trigger | Rule | Frequency | Compute |
|---------|------|-----------|---------|
| Capture | 1 | Per insert | < 1 ms |
| Bucket boundary | 4 | Every 5 min | ~5 ms |
| Recall feedback | 3 | Per used row | < 1 ms |
| Retention | 5 | Hourly + daily | < 5 sec |
| Co-activation update | 9 | Weekly | ~10 sec |
| NMF | 8 | Weekly | < 60 sec |
| Centrality | 10 | Daily | ~100 ms |
| Community detection | 11 | Daily | ~5 sec |
| Decay | 12 | Daily | ~10 ms |

### §15.3. Hot/cold path separation

Rules 1-3 are *hot path*: synchronous with user action, executed in
the capture/mutate/recall code path. Sub-millisecond per
invocation.

Rules 4-13 are *cold path*: executed by the dreaming daemon on
charger/idle/scheduled cadence. Bursts of seconds-to-minutes
permissible.

Hot and cold path SHARE the bit-slice runtime view (mmap'd) but
NEVER share mutable scratch state. The dreaming daemon writes
results back to the runtime view atomically (per-matrix-cell
compare-and-swap or whole-matrix swap).

### §15.4. Battery / resource budgets

On battery (iPhone, iPad): only Rules 1, 3, 4 run.
On charger or desktop: all rules run.
On low-power mode: only Rule 1 runs.

Total compute per active user per day:
- Hot path: ~1 sec (mostly Rule 1)
- Background (Rule 4): ~60 ms × 288 = ~17 sec
- Daily dreaming: ~5-30 sec depending on rule set

---

## §16. Manifest schema amendments

### §16.1. New manifest keys (v0.36)

```
manifest_v0.36 (adds to v0.35 manifest):

bitmap_layout_version: "0.36"
schema_version: "0.36"
operational_bitmap_layouts: { ... per §2.4 }

hyperplane_seeds: {
    H_0: Int8[24][64],
    H_1: Int8[8][64],
    H_2: Int8[8][64],
    H_3: Int8[8][64]
}

ambient_capture_config: {
    enabled_streams: Bitset,             -- which streams active
    bucket_duration_ms: Int32,           -- default 300000
    detail_retention_days: Int32,        -- default 90
    hourly_retention_days: Int32,        -- default 365
    daily_retention_indefinite: Bool,    -- default true
    anomaly_threshold: Float,            -- default 3.0
    anomaly_mode: AnomalyMode,           -- default zscore
    raw_sample_retention_days: Int32     -- default 30
}

tournament_weights: Float[5]
ranking_weights: Float[12][5]

shared_hyperplane_seeds: {
    [scope]: HyperplaneFamily,
    [scope]_paired_at: HLC,
    [scope]_dissolved_at: Option<HLC>
}

paired_estates: {
    [estate_uuid]: PairingInfo
}

# Case 3 — multi-tenant:
tier_participation: [TierLevel]
tier_contribution_to: [TierLevel]
tier_advisory_from: [TierLevel]
industry_anchor: [{ wikidata_qid: QID }]
tier_participation_dissolved_at: { [TierLevel]: HLC }

# Case 2 — actuator:
actuator_policies: [ActionPolicy]
calibration_curves: { [model_id]: CalibrationBuckets }

# Cognition tier:
lineage_taxonomy: [LineageCluster]
```

### §16.2. Migration from v0.35 to v0.36

Migration script:

```
function migrate_0_35_to_0_36(estate_path: Path) -> Result<(), Error>:
    # 1. Backup.
    snapshot(estate_path)

    # 2. Widen bitmap fields.
    for row in estate.all_rows():
        new_adjective  = widen_4_to_6(row.adjective)
        new_operational = widen_4_to_6(row.operational)
        new_provenance = widen_4_to_6(row.provenance)
        write_back(row, new_adjective, new_operational, new_provenance)

    # 3. Compute fingerprints for all existing rows.
    estate.manifest.hyperplane_seeds = generate_hyperplane_family()
    for row in estate.all_rows():
        row.fingerprint = compute_fingerprint(row)

    # 4. Ensure every row has a lattice anchor.
    for row in estate.all_rows().filter(lattice_anchor.is_null):
        row.lattice_anchor = infer_lattice_anchor(row)  -- enrichment daemon

    # 5. Build bit-slice runtime files.
    rebuild_bitslice_files(estate)

    # 6. Initialize tier-3 matrices via dreaming-pass replay of audit log.
    replay_audit_for_matrix_init(estate)

    # 7. Update manifest version.
    estate.manifest.schema_version = "0.36"
    estate.manifest.bitmap_layout_version = "0.36"

    # 8. Verification: re-read all rows; compare fingerprint
    #    determinism, bitmap encoding correctness, matrix sanity.
    verify_migration(estate)

    return Ok(())

# Widen function (4-bit field at position p → 6-bit field at p):
function widen_4_to_6(b: Int64) -> Int64:
    # Move each field to its new offset; preserve value remapping
    # per §2.8 table. Bits 4–7 (sensitivity 0/4/8/12) become bits
    # 6–11 with values 0/16/32/48. Etc.
    ...  -- implementation per §2.8 mapping
```

---

## §17. Performance budgets

### §17.1. Hot-path budgets

Per primitive, 1M-row estate, Apple Silicon M-series:

| Primitive | Budget | Source |
|-----------|--------|--------|
| capture | < 1 ms | bit-slice write + fingerprint + audit row |
| recall (bitmap-only filter, top-10) | < 100 µs | §4.5 |
| recall_similar_moments (top-10) | < 100 µs | Hamming-NN, §4.5 |
| recall_with_advisory (1 tier hop) | < 50 ms | network-bound |
| propose_action | < 1 ms | one capture |
| mutate | < 1 ms | validate + bitmap write + audit |
| reanchor | < 5 ms | recompute Block 1 of fingerprint |

> **Phase 2 measurement note (added 2026-05-18).** The 100 µs
> Hamming-NN top-K budget above is internally inconsistent with
> §17.5's bandwidth math (32 MB / 60 GB/s = 533 µs floor). Phase 2.δ-1
> measured SimdKernel branchless top-K at K=10, N=1M in 604 µs on
> apple-m5-max, within 13% of the §17.5 floor. The 100 µs claim is
> achievable only with substrate-level bit-slice layout reducing
> the working-set bytes read (cookbook §4.1 I-18) AND a top-K
> implementation that maintains the K-element sorted ladder during
> the scan rather than sorting all distances afterward.
>
> Without bit-slice (current state): 604 µs achievable.
> With bit-slice for partial Hamming over a subset of blocks:
> proportionally faster (block 0 only = 8 MB / 60 GB/s = ~133 µs).
>
> Until substrate-level bit-slice lands, the 100 µs budget should
> be read as bit-slice-dependent. See `§17.6` for the measured
> bandwidth floor and architectural derivation.

### §17.2. Cold-path budgets

Per pass, 1M-row estate:

| Pass | Budget | Trigger |
|------|--------|---------|
| Capture-log drain | < 1 sec | At every dreaming session start |
| F/O incremental update | Already incremental | Per capture |
| C recompute | < 5 sec | Weekly |
| O recompute (full) | < 60 sec | Monthly |
| Σ(M·M.T) | < 30 sec | Weekly |
| NMF | < 60 sec | Weekly |
| Eigenvalue centrality | < 1 sec | Daily |
| Community detection | < 30 sec | Daily |
| Pattern mining (Tier-4) | < 5 min | Weekly |

### §17.3. Ambient capture (device-edge)

Per 5-min bucket per active user:

| Stage | Budget |
|-------|--------|
| Read raw samples | < 1 ms |
| Feature extraction | < 1 ms |
| SimHash per block | ~200 ns batched |
| AmbientSample insert | < 1 ms |
| Total per bucket | < 5 ms |

Daily compute: 12 buckets/hour × 24 hours = 288 buckets × 5 ms =
~1.4 sec of compute per active user. Trivial; runs in BG task or
equivalent.

### §17.4. Storage steady-state per user-year

| Tier | Size |
|------|------|
| Drawers (verbatim content) | ~10 MB (small write-frequency assumption) |
| AmbientSamples (detail, 5-min) | ~1.1 MB |
| AmbientSamples (hourly rollups) | ~280 KB |
| AmbientSamples (daily rollups) | ~12 KB |
| Audit log | ~50 MB (10× row count) |
| Fingerprints | 32 MB (per 1M rows) |
| Bit-slice runtime files | 75 MB (per 1M rows) |
| Matrices (F, C, O, T, ActionOutcomes) | 1-5 MB |
| W_tournament + W_ranking | < 1 KB |
| Calibration curves | < 10 KB |
| Hyperplane seeds | 3 KB |
| Manifest | < 100 KB |
| **Total** | **~170 MB / year (small estate)** |

### §17.5. Memory bandwidth at scale

Apple Silicon M-series: ~60 GB/s LPDDR5 bandwidth.

| Operation | Bandwidth required | Latency |
|-----------|-------------------|---------|
| Full-tensor scan (1M rows) | ~75 MB | ~1.25 ms |
| One predicate filter | ~125 KB | < 10 µs |
| Hamming-NN over 1M fingerprints | ~32 MB | ~500 µs |
| Matrix-tier update | ~kilobytes | negligible |

The architecture is bandwidth-bound, not compute-bound. The
kernel layer (§4.4) exists to extract bandwidth, not to add
arithmetic complexity.

### §17.6. Measured Phase 2 outcomes (added 2026-05-18)

This section reconciles the cookbook's per-primitive budget
estimates with the empirical outcomes from Phase 2 kernel
measurement work (commits `d8602d4` through `d87d824`). Hardware
is apple-m5-max throughout; results may differ on other Apple
Silicon variants or on Rust version targets.

#### §17.6.1. Per-primitive measured costs

| Primitive | Cookbook estimate | Measured (Phase 2) | Reference |
|-----------|-------------------|--------------------|-----------|
| or_reduce_256 (one cohort=8) | < 1 µs | ~3.4 ns/pair (SimdKernel, batched bs=256) | α-1: `d8602d4` |
| hamming_distance_256 (pair) | not estimated | ~2.6 ns/pair (SimdKernel) | β-1: `fa93c23` |
| hamming_distance_batch (bs=256) | ~100 µs for top-K(1M) | 0.65 ns/cand (SimdKernel) | β-1: `fa93c23` |
| hamming_top_k (K=10, N=1M) | < 100 µs (§17.1) | 604 µs (SimdKernel branchless ladder); cookbook 533 µs floor | δ-1: `8e7916d` |
| hamming_top_k (K=100, N=1M) | < 500 µs (§17.1) | 650 µs (SimdKernel; K-overhead 7%) | δ-1: `8e7916d` |
| simhash_compute (unbatched) | ~500 ns | ~166 ns (scalar Swift, bs=1) | γ-1: `cea9446` |
| simhash_block_batch (bs=256) | ~200 ns/input | ~59 ns/input (SimdKernel PackedFamily) | γ-1: `cea9446` |
| Bitmap filter (1 predicate) | < 100 µs (§4.5) | not yet measured (substrate-level) | n/a |
| Composite distance | < 200 µs (§4.5) | not yet measured | n/a |

#### §17.6.2. Reconciliation with cookbook §17.1 and §17.5

The cookbook is internally inconsistent on the Hamming-NN top-K
budget. §17.1 sets the budget at 100 µs; §17.5 derives a 500 µs
bandwidth floor from the same hardware (60 GB/s LPDDR5, 32 MB
fingerprint scan at 1M rows). Phase 2.δ-1 measurement landed at
604 µs, within 13% of the §17.5 floor.

Resolution: §17.5's bandwidth math is correct. §17.1's 100-µs
claim is achievable only with bit-slice layout (§4.1 I-18)
reducing the working set per query, AND a top-K implementation
that avoids the O(N log N) sort.

The substrate's kernel layer hits 90% of the available speedup
against the bandwidth floor; the remaining 10% requires the
bit-slice substrate-level work tracked under Phase 2.ε backlog
item 2.

#### §17.6.3. Reconciliation with cookbook §3.6 SimHash cost

The cookbook estimate of 500 ns unbatched / 200 ns batched
is 2-3x pessimistic relative to apple-m5-max measurement. The
optimistic figures (166 ns unbatched scalar, 59 ns batched bulk)
should be used for capacity planning on apple-m5-max-class
hardware. The 2-3x margin is significant enough that workloads
designed against the cookbook estimate will have substantial
headroom in practice.

Dreaming-daemon batch index-build pass capacity at the measured
59 ns/input bulk rate:

  1M-row regen = 59 ns × 1M = 59 ms
  10M-row regen = 590 ms

Well within cookbook §15.4 dreaming-daemon resource budgets.

#### §17.6.4. Selected approach per documented production need

The selected production approaches are:

  or_reduce_256:           SimdKernel SIMD4<UInt64> accumulator
  or_reduce_batch:         SimdKernel overridden default loop
  hamming_distance_256:    SimdKernel SIMD4 XOR + nonzeroBitCount
  hamming_distance_batch:  SimdKernel
  hamming_top_k:           SimdKernel branchless ladder
  simhash_block_batch:     SimdKernel PackedFamily + vertical SIMD
  simhash_compute (bs=1):  Inherited scalar (below SIMD packing crossover)

Dispatcher reduces to:

```swift
PortableKernel.kernelForCurrentPlatform():
    #if arch(arm64)
    return SimdKernel()
    #else
    return ScalarKernel()
    #endif
```

#### §17.6.5. Methodology and reproducibility

Every measurement above is reproducible from a stress-test
invocation at the cited commit on apple-m5-max. The procedure:

  1. `git checkout <commit>` in the repository.
  2. `cd docs/validation/substrate_math_performance/test-harness/swift`
  3. `swift build -c release`
  4. `.build/release/stress-test --kernel simd --quick` (or
     `.build/release/topk-bench --quick` for top-K measurements).
  5. Compare reported `ns_per_call_min` and `ns_per_element_min`
     against the table above.

Results on different Apple Silicon hardware (M1-M4) may differ
in absolute terms; the SimdKernel selection should hold because
the candidate kernels were rejected by ratio, not absolute
threshold.

The methodology gate produced eight measured findings and two
architectural-math declines. The reproducible procedure and the
selection table above are the stable ledger.

#### §17.6.6. What this section does NOT cover

The Phase 2 work measured the kernel layer's bandwidth-bound
bit-tensor ops (or_reduce, hamming, simhash, top-K). It did NOT
measure:

  - Bitmap predicate filters (§4.5 P1; substrate-level)
  - Lattice distance (P3; UDC + Wikidata graph walks)
  - Composite distance (P3 + Hamming combined)
  - NMF (P9; matrix factorization on O)
  - FFT (P10; rhythm analysis)
  - Eigenvalue centrality (P12)

These cookbook primitives remain at the original estimates until
a future measurement phase exercises them against real workloads.

---

## §18. Conformance requirements

### §18.1. Required behaviors

A v1.0-conforming implementation MUST:

1. Implement all 14 invariants from v0.35, plus I-15 through I-25
   from v0.36, plus I-26 through I-30 from this document.
2. Pass all 22 cross-language-pinned conformance vectors at their
   canonical CRCs. The 22 primitives and their CRCs are listed in
   `HARNESS_REFERENCE.md` §2; the gate is run at
   `docs/validation/substrate_math_performance/test-harness/`.
   Both languages (Swift and Rust) of any port MUST validate every
   canonical vector at the matching CRC. New ports (WASM, x86_64,
   non-Apple targets) are conforming when they pass the same gate.
3. Enforce `DrawerStateValidator` AND `AuditGate.admit`
   `ForbiddenCombinations.check` on every write path including
   capture (§9.9, §10.1; I-26 closes the v0.36 gap where capture
   bypassed the gate).
4. Maintain F, C, O, T matrices per the update rules (§6, §15.1).
   `MatrixF.apply_row` is conformance-gated; see HARNESS_REFERENCE
   §2.2 (`field_presence_matrix_f`, CRC `0x2a051f09`).
5. Generate audit events on every mutation AND on every capture,
   each carrying the integrity triangle (I-27): plaintext HLC,
   content+HLC seal, companion HLC seal. HLC stamped from the
   single estate-wide `HLCGenerator` (I-28).
6. Pass the bitmap-field-constants table verification (§2.8),
   including v1.0 row 24 for the `sealed` adjective bit.
7. Reject all forbidden state combinations (§9.5, I-22).
8. Use UUIDs for every row identifier and audit event identifier
   (I-29). Reject non-UUID-parseable identifiers at the audit
   write boundary.
9. Run all CognitionKit primitives (§11) with their specified
   math, calling the SubstrateKernel and SubstrateML atomics by
   name (I-25, I-30) — no kit reimplements a gated primitive.
10. Generate Portable Cognition Bundles per §13.1 format.
11. For multi-tenant deployments: enforce DP guarantees per §12.6
    and contribution provenance audit.
12. For deployments declaring strict custody: mint the SHA-256
    seal contemporaneously at the write (§5.8). For deployments
    declaring lazy custody: the dreaming pass MUST eventually
    drain the unsealed-record queue; the seal bit IS the queue.

### §18.2. Required tests — the harness gate

The v1.0 conformance gate is the cross-language test harness at
`docs/validation/substrate_math_performance/test-harness/`. The
gate pins 24 primitives (the 24 listed in HARNESS_REFERENCE §2)
with four-way validation: Swift gen × Swift validate, Swift gen
× Rust validate, Rust gen × Swift validate, Rust gen × Rust
validate. A primitive is conforming when all four cells PASS at
the same CRC.

```
The 24 gated primitives (23 at v1.0 ratification + bit_field_masked_equals,
the F18.2b post-v1.0 promotion; see HARNESS_REFERENCE.md for
full API and file paths):

Tier 1 (atomics):
  simhash               CRC 0xddd18e12   §3.6
  hamming               CRC 0xce4deb85   §8.2
  or_reduce             CRC 0x4ee84d73   §8.5
  bitwise               CRC 0x05230c95   §8.6
  fingerprint           CRC 0x4449238e   §3.6
  hlc                   CRC 0x9303e020   §5.2
  fnv                   CRC 0x275fd2bf   §3.3     [F5b promotion]
  bit_field_masked_equals
                        CRC 0x54f6c65f   §2.8     [F18.2b promotion]

Tier 2 (algorithmic):
  lattice (aka udc_tree_distance)
                        CRC 0x6c4e453f   §8.3
  info_theory           CRC 0x0cc08713   §8.11
  bradley_terry         CRC 0x601126c7   §8.12
  partial_state_recall  CRC 0xe8d3b221   §8.8
  temporal_compression  CRC 0xdc3144c0   §8.14
  anomaly               CRC 0x6c6fda4d   §8.13
  matrix_decay          CRC 0x7b12f93d   §6.8     [v1.0 promotion]
  moment_summary        CRC 0x6762440b   §8.7     [v1.0 promotion]
  field_presence_matrix_f
                        CRC 0x2a051f09   §6.1     [v1.0 promotion]

Tier 3 (substrate-level):
  tier_contribution     CRC 0x4b67bcb5   §12.3
  pairing_handshake     CRC 0x67bc56f8   §12.2
  fft                   CRC 0xeae5c063   §8.10
  hamming_nn            CRC 0xeac615f1   §8.2
  nmf                   CRC 0x300bf633   §6.9
  eigenvalue_centrality CRC 0x1a9039ea   §7.2     [v1.0 promotion]
  audit_log_fold        CRC 0xa747722e   §5.3+§8.15
```

Additional non-harness tests carried from v0.36:

- `automaton/`: every legal transition + every forbidden combination.
- `cognitionkit/`: each primitive with input/output fixtures (where
  not yet harness-gated).
- `federation/`: pairing protocols beyond the gated handshake.
- `dp/`: statistical tests that (ε, δ)-DP guarantees hold over N
  synthetic contributions.

The harness gate is run on every commit via the CI workflow at
`.github/workflows/geniuslocus-conformance.yml`. A failed cell
is a release blocker.

### §18.3. Versioning protocol

Manifest declares `schema_version` and `bitmap_layout_version`.
Old data remains readable when versions match.

Forward incompatibility: a v0.37 estate's manifest declares
`schema_version >= 0.37`; v0.36 implementation refuses to open
(or opens read-only with a warning).

Backward compatibility: v0.36 implementation MUST open v0.35
estates after running the migration in §16.2. Refusal to migrate
is non-conformance.

---

## §19. Out of scope (deferred to v0.37, v0.38, v2)

**v1.0 update.** Items resolved by the v1.0 work are removed
from the lists below. v0.36 entries that v1.0 brings in scope:
HLC generator placement, audit-log-as-source-of-truth (§5.3),
capture genesis event, integrity triangle, custody mode, row
identity UUID, library split. Items that remain deferred are
listed below; the principal carry-forward is `community_detection`
phase 2 (Louvain phase 2 graph aggregation, §7.3), which the
v1.0 harness has explicitly left out per cookbook §7.3.

### §19.1. v0.37 (CognitionKit expansion)

- Latent-factor primitives beyond §11.12-§11.13
- Information-theoretic primitives beyond §11.4 (entropy-NN,
  MI matrix visualization)
- Random-walk exploratory primitives
- Wikidata subclass closure as fingerprint input (already
  specified at §3.3; v0.37 expands the caching infrastructure)
- Graph community-detection primitives beyond §11.11
- `community_detection` phase 2 (Louvain phase 2 graph
  aggregation; gate explicitly excludes this until v0.37)
- Wikidata graph distance gated primitive (requires a remote
  adjacency provider; `lattice` covers only the UDC-tree half
  in v1.0)
- Composite distance gated primitive (awaits Wikidata gating)
- Bitmap-filter gated primitive (awaits bit-slice substrate
  work, cookbook §4.1 I-18)

### §19.2. v0.38 (Federation / multi-tenancy)

- Full hierarchical tier infrastructure (case 3)
- Multi-party DP composition theorems for chained tiers
- Cross-MSP audit and revocation protocols
- Industry-tier routing optimization
- Cross-jurisdiction subdivision

### §19.3. v2 successor architecture

- Learned hyperplanes replacing random hyperplanes
- Multi-replica sharding for performance
- Category-theoretic formalization of kit decomposition
- 5th adjective category (currently forbidden by I-8)
- Higher-arity Associations (currently I-23 limits to binary)

---

## §20. SubstrateLib package layout (v1.0)

**I-30. The substrate ships as four packages.** The substrate splits
into four SPM packages (Swift) / Cargo crates (Rust):
`SubstrateTypes` (pure data, incl. HLC + HLCGenerator),
`SubstrateKernel` (hot-path kernels + SHA256, HammingNN, BitField),
`SubstrateML` (cold-path / ML algorithms), and `SubstrateLib` — the
retained orchestration layer that owns the nine-verb mechanics, the
row-state automaton, and the AuditGate write-gate, and depends on the
other three. Consumers depend on
whichever combination they need; the boundary is enforced by the build
graph, and SubstrateLib no longer re-exports the sub-packages (the
transitional shim was removed once the symbol tail relocated, 2026-05-29).

### §20.1. SubstrateTypes — pure data, zero compute

Contains the data types every kit speaks, with no algorithms,
no I/O, no transcendentals:

- `Fingerprint256` (struct + wire encoding only)
- `HLC` (struct + ordering + wire encoding) and its `HLCGenerator`
- `LatticeAnchor`, `Row`, `RowLite`, `NounType`, `RowStateValue`
- `AuditEvent` (the struct shape)
- `MatrixF`, `MatrixC`, `MatrixO`, `MatrixT` (storage and indexing,
  no learning)
- `BlockMask`, `RowBitmaps`, `BitVector216` (layout constants)
- `TimeRange`
- Enums: `MutationKind`, `PairingScope`, `GeneratedByClass`, etc.

**Rule.** A kit that just wants to talk substrate-shape (e.g.
ConvergenceKit serializing rows to CloudKit) depends only on
SubstrateTypes.

### §20.2. SubstrateKernel — bandwidth-bound bit operations

Contains the hot-path bit-tensor operations that the Phase 2
measurement work selected (§17.6) plus the write-gate and
clock-maker primitives. All of these are gated by
HARNESS_REFERENCE §2.1 (Tier 1):

- `SimHash` family
- `Fingerprint256` distance / OR / AND / XOR / prototype ops
- `HammingNN` top-K (branchless ladder, §17.6)
- The combinators layer: `zip4`/`reduce4`/`map4`/`popcount` over
  Fingerprint256
- `SimdKernel` (Swift NEON via `import simd`; Rust `std::simd`)
- `SHA256`, `BitField` (content-ID / seal hashing and bitmap
  field extraction; the hot-path leaves the AuditGate depends on)

(`AuditGate` itself is **not** here — as of 2026-05-29 it stays in
SubstrateLib's orchestration layer because it calls `RowStateAutomaton`;
see §20.4 and I-30.)
- `HLCGenerator` (`open` / `tick` / `takeover`, I-28)
- SHA-256 content-ID (`audit_gate::content_id` in Rust;
  `ContentID.compute` in Swift); the seal construction (I-27)

**Rule.** Depends on SubstrateTypes only. No matrix updates, no
learning, no graph algorithms.

### §20.3. SubstrateML — learning and graph algorithms

Contains the cold-path or dreaming-driven algorithms; gated by
HARNESS_REFERENCE §2.2 (Tier 2) and §2.3 (Tier 3):

- `MatrixDecay`
- `MomentSummary`
- `BradleyTerry`
- `Anomaly` (z-score)
- `InfoTheory` (entropy / MI / KL)
- `TemporalCompression`
- `PartialStateRecall`
- `FFT`
- `NMF`
- `EigenvalueCentrality`
- `AuditLogFold`
- `TierContribution`
- `PairingHandshake`

**Rule.** Depends on SubstrateTypes and SubstrateKernel. Most
kits do NOT need this package — only LocusKit, CognitionKit, and
GeniusLocusKit consume it.

### §20.4. Why four packages

SubstrateTypes, SubstrateKernel, and SubstrateML are the three
sub-packages described above; **SubstrateLib is the fourth** — the
retained orchestration layer (nine-verb mechanics, row-state automaton,
AuditGate write-gate) that depends on the other three. It is a real,
narrow dependency, not a re-export shim (the transitional `@_exported`
re-export was removed 2026-05-29). The split serves four purposes:

1. **Compile time.** A kit that only serializes rows compiles
   against SubstrateTypes alone and avoids SubstrateKernel's
   SIMD code generation.
2. **Dependency clarity.** A kit's Package.swift tells you
   whether it's a substrate consumer, a hot-path consumer, or a
   learning consumer. The boundary lives in the build graph,
   not just in prose.
3. **Future portability.** A WASM target or a non-Apple-Silicon
   port that wants to ship without `simd_*` intrinsics can take
   SubstrateTypes and a stub SubstrateKernel without touching
   SubstrateML.
4. **Test isolation.** Each package's test suite is independent.
   SubstrateKernel's CRC-pinned conformance vectors (the harness)
   don't need to recompile when SubstrateML changes.

`I-25` (one implementation per atomic) applies across all four:
atomics live in whichever package they belong to, and every
consumer imports them by name.

---

## Appendix A — Design Edges

Open questions tracked for future refinement. Questions resolved
by the v1.0 decision set are listed first with their resolution.

### A.1. Resolved in v1.0

- **OQ-V1-1 (Dual-clock projection).** Resolved REJECTED. State
  has exactly one legitimate fold order — ingest HLC, the chain
  of custody. Empirical date is a content attribute to filter
  and sort on, never a fold axis for state. The "as-of empirical
  date" projection is undefined: row state evolved in ingest
  time, not in the order the world produced events.

- **OQ-V1-2 (Open-core split by custody mode).** Resolved
  REJECTED. Strict and lazy are one scheduling flag over one
  seal; cleaving the codebase along that flag protects a moat
  that does not yet exist and creates an artificial seam. The
  substrate stays the clean open mechanism; future optional
  attestation business layers stack above it.

- **OQ-V1-3 (HLC promotion mechanism).** Resolved REFUSE-PLUS-
  EXPLICIT-TAKEOVER. `open` refuses on an already-owned log; a
  `takeover` operation records the handoff as an event.

- **OQ-V1-4 (Checkpoint cadence).** Resolved CONSTANT INTERVAL,
  defaulting to 1000 events, configurable per moot.

- **OQ-V1-5 (Companion seal storage).** Resolved SAME-ROW COLUMN
  on the event row, not a sibling table.

- **OQ-V1-6 (Capture genesis path).** Resolved CAPTURE EMITS A
  GATED GENESIS EVENT (§5.3 / I-26).

- **OQ-V1-7 (Row identity for sync).** Resolved UUID EVERYWHERE
  (I-29).

- **OQ-V1-8 (SubstrateLib boundary).** Resolved FOUR PACKAGES:
  SubstrateTypes / SubstrateKernel / SubstrateML / SubstrateLib
  (§20, I-30).

### A.2. Carried forward (v0.36 open questions)

Open questions from the v0.36 designer artifacts, NOT resolved
in this spec, tracked for future refinement:

- **OQ-2.1.** Hyperplane density (±1 vs {0, ±1}). Implementation
  choice; both valid.
- **OQ-2.3.** Missing lattice-anchor strategy resolved to
  "infer dominant context" in §2.7; but the inference rules are
  themselves heuristic.
- **OQ-2.5.** Locked-zone mask strategy: specified at §3.5 as
  null hash; alternative randomized-mask considered for v2.
- **OQ-5.5.** Feature-vector design per stream (§3.9): currently
  best-guess. Empirical validation needed in v0.37 user testing.
- **OQ-5.6.** Rollup richness/variance scalar: not added in v0.36;
  consider for v0.37.
- **CS1-Q1.** Pairing UX (AirDrop / QR / CloudKit): v1 picks QR.
- **CS1-Q2.** Co-referenced entity grant granularity: per-topic
  with per-drawer override (default).
- **CS1-Q3.** Dissolution mathematics: revert to local
  identifiers; audit log preserves history.
- **CS1-Q4.** Multi-person households: v1 pairwise; N-way deferred
  to v2.
- **CS2-Q1.** Actuator allowlist schema: see §14.2.
- **CS2-Q2.** Action severity defaults: see §14.6.
- **CS2-Q3.** Fleet vs tenant boundary: ownership identity is the
  marker; mathematics identical.
- **CS2-Q4.** LLM placement: substrate-agnostic; provenance records
  model_id.
- **CS2-Q5.** Retired-machine history: stays in audit log forever
  (I-6); fleet aggregator continues to learn.
- **CS3-Q1.** Pairing-tier reciprocity: yes by default.
- **CS3-Q2.** Contribution cadence: see §12.3 defaults.
- **CS3-Q3.** Departing-tenant expungement: per spec §6.6 of v0.35;
  contracts govern requirements.
- **CS3-Q4.** Cross-industry query routing: industry Q-IDs in
  query metadata.
- **CS3-Q5.** Jurisdictional sub-industries: Q-ID subdivision per
  Wikidata; v0.38 spec amendment.
- **CS3-Q6.** Adversarial users: contribution-provenance audit
  (§12.6) + tier-advisory revocation.

---

## Appendix B — Provenance of each section

Sections trace back to designer artifacts as follows:

| Section | Primary source | Secondary |
|---------|----------------|-----------|
| §1.1 (seven aspects) | Final math pass §4 | All artifacts |
| §1.2 (twelve primitives) | Final math pass §4 | Algebra notebook |
| §2.2 (6-bit floor) | Design session Pivot 2 | Foundations |
| §2.3 (state encoding) | Algebra notebook + bitmap math review | v0.35 spec |
| §2.4 (operational layouts) | v0.35 spec amended | Case studies 1-3 |
| §2.6 (AmbientSample) | Algebra notebook §5 | Foundations F-1 |
| §2.7 (universal lattice anchor) | Cross-case math §2 | First math pass |
| §2.8 (bitmap verification table) | Bitmap math review (workspace) | Source files |
| §2.9 (C1, C2 resolutions) | Bitmap math review | DrawerStateValidator |
| §3 (fingerprint) | Algebra notebook §2 | All case studies |
| §4 (runtime layout) | Design session Pivots 1, 4, 5 | Final math pass §1.B |
| §5 (CRDT framing) | Final math pass §1.A | Foundations F-4 |
| §6 (matrix tier) | Algebra notebook §1 | First math pass §3.A, §3.C |
| §7 (graph framing) | Final math pass §1.C | NMF/centrality |
| §8 (algorithms) | All artifacts | This spec consolidates |
| §9 (automaton) | Final math pass §3.A | v0.35 spec §6.2 |
| §10 (verbs) | v0.35 spec amended | Case 2 (mutate.automated_confirm) |
| §11 (CognitionKit) | Algebra notebook §4 + all case studies + final math pass §2 | First math pass §3.E |
| §12 (federation) | Case study 1, 2, 3 | First math pass §3.D, final math pass §3.B-C |
| §13 (cognition bundle) | First math pass §4.A | Final math pass §5 |
| §14 (ActuatorKit) | Case study 2 | First math pass §3.B (calibration) |
| §15 (dreaming daemon) | Algebra notebook synthesis | Final math pass §5 |
| §16 (manifest) | All artifacts | v0.35 manifest decision |
| §17 (performance budgets) | Final math pass §1.B | Pivot 1 / Pivot 5 |
| §18 (conformance) | This spec | New |
| §19 (out of scope) | First and final math passes §5 | Roadmap |

## Changelog

### 1.3.0 -- 2026-07-20

- Revised §5.12 for the 1.1 shared-content architecture: LocusKit attests
  canonical Drawer content once; CorpusKit may attest only rebuildable index
  state in GLK. Legacy chunk-store roots are standalone compatibility only.

### 1.1.0 -- 2026-06-21
- §5.12: Merkle attestation composition. Documents how LocusKit
  and CorpusKit Merkle roots compose into unified snapshot attestations
  via GeniusLocusKit.createComposedSnapshot.
- §10.5 expunge: keyed-commitment provenance. Documents that expunge
  invalidates Merkle attestation roots and the provenance chain
  (old-root → audit-event → new-root) that proves erasure.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
