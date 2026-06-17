---
status: decided
question: Should RecallShape's lane-key surface steer ONLY the retrieval lanes, or ALL recall scoring columns (retrieval + matrix/graph/preference)?
authors: MOOTx01 maintainers
date: 2026-06-17
version: 1.0.0
relates_to:
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUSKIT_INTERFACE.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/decisions/ADR-010-honest-fusion-recall-and-steering.md
supersedes: none
context:
  - ADR-010 established RecallShape as the engine-level steering knob over the recall lanes, and 6b-modifiers-core/core-2 wired the retrieval lane keys (locus, bm25, hamming, dense, dense:<modelID>) into both the RRF fusion (hybrid/corpusOnly) and the unionBest weighted-column score.
  - The unionBest .matrixAware score ALSO sums five matrix/graph/preference columns (fieldFit, coOccurrence, temporal, graph, preference), scored from the adaptive RecallWeights budget. These columns were NOT shape-steerable — the engine multiplied them by RecallWeights only, with a code comment stating "Matrix/graph/preference lanes are NOT shape-steerable here."
  - That gap blocks honest temporal/connection/field/preference recipes (a recipe cannot ask recall to weight temporal relevance up, or exclude the preference prior) and blocks the 1.1 quality optimizer, which must be able to drive EVERY signal's weight to run the ablation/combination gauntlet over real data.
---

# ADR-011 — RecallShape's lane-key surface spans ALL recall scoring columns

## Context

`RecallShape` (ADR-010) is the signed, per-lane steering vector for recall. A
lane's contribution is multiplied by its signed weight before fusion: `w > 0`
forwards, `w == 0` excludes, `w < 0` suppresses (demotes). The weight is read by
a stable string lane key, defaulting to `1.0` for any absent key, so a `nil`
shape is byte-identical to the pre-steer behaviour.

Until this decision the steerable surface covered only the retrieval lanes:
`locus`, `bm25`, `hamming`, `dense`, and per-signal `dense:<modelID>`. The
unionBest `.matrixAware` weighted score additionally sums five matrix/graph/
preference columns — `fieldFit`, `coOccurrence`, `temporal`, `graph`,
`preference` — and those were scored from the adaptive `RecallWeights` budget
ALONE, with no shape factor.

That is a hole in the steering contract. The optimizer (1.1) selects a recall
configuration by weighting every signal and measuring the result on the real
39k corpus; it cannot do that if five of the ten scoring columns are unreachable.
Honest recipes have the same problem: a "recent-first" recipe needs to weight
`temporal` up; a "ignore my learned preferences" recipe needs to exclude
`preference`. Neither was expressible.

## Decision

### D-1 — The lane-key surface is the COMPLETE set of recall scoring columns

`RecallShape`'s stable lane keys now span every column the recall scorer sums.
This is the surface the optimizer and the named-preset roster target:

Retrieval lanes (steer the RRF fusion in hybrid/corpusOnly AND the weighted
columns in unionBest):
- `locus` — the LocusKit bitmap lane.
- `bm25` — the CorpusKit BM25 keyword lane.
- `hamming` — the 256-bit SimHash-Hamming vector lane.
- `dense` — the aggregate dense float column in the unionBest weighted score.
- `dense:<modelID>` — a per-signal dense float lane, one key per held embedding
  provider; these steer the consensus fold that BUILDS the aggregate `dense`
  column.

Matrix/graph/preference columns (steer ONLY the unionBest `.matrixAware`
weighted score):
- `fieldFit` — the FDC field-fit column.
- `coOccurrence` — the MatrixTier co-occurrence column.
- `temporal` — the MatrixTier temporal-relevance column.
- `graph` — the connection-graph column.
- `preference` — the learned-preference column.

### D-2 — Signed semantics are uniform across all keys

The matrix/graph/preference keys carry EXACTLY the signed semantics already in
force for the retrieval lanes:
- `w == 1.0` — neutral. The column keeps its `RecallWeights.adaptive`
  contribution unchanged.
- `w == 0` — EXCLUDE. The column's contribution is zeroed.
- `w < 0` — SUPPRESS. The column's contribution is SUBTRACTED (a candidate the
  column scores high is demoted).

A key absent from the shape defaults to `1.0`. The shape composes WITH the
adaptive `RecallWeights` budget — it does not replace it: the column's effective
factor is `shapeWeight × RecallWeights × column`. The optimizer therefore tunes
recall on top of the adaptive budget, not against it.

The combined matrix term `weights.matrix × (coOccurrence + temporal) × 0.5` is
split so `coOccurrence` and `temporal` steer independently, each carrying half
the matrix budget. On the neutral (1.0/1.0) path the exact pre-steer combined
expression is preserved, so float reassociation is avoided and a `nil`/all-ones
shape is byte-identical to the pre-steer score (proven by test, both ports).

### D-3 — The matrix columns are active ONLY under `.matrixAware`

The five matrix/graph/preference columns are populated and summed ONLY by the
unionBest `.matrixAware` scoring path. The `.raw` and `.rrf` paths read the
lane-normalised `buffer.final` rank score directly and never run the weighted
formula. Steering the matrix/graph/preference keys is therefore a NO-OP under
`.raw`/`.rrf` — the keys are accepted (a shape carrying them is valid) but have
no effect, because the columns they name are not in those scoring paths. This
boundary is documented honestly: a recipe steering `temporal` must request
`.matrixAware` scoring for the steer to take effect.

### D-4 — Cross-port boundary for graph/preference

The Swift port populates `graph` and `preference` from a registered
`GraphCache` / `PreferenceStore` (the dreaming/training caches). The Rust port
does not yet wire those caches, so its `graph`/`preference` columns are `0.0`;
steering them multiplies `0.0` and is a no-op THERE. The steering SURFACE — the
keys, their semantics, the composition with `RecallWeights` — is identical
cross-port, so the contract is stable for when the Rust caches land. The
conformance tests assert the surface in both ports (Swift moves the columns when
the caches are registered; Rust asserts the no-op when the columns are dark).

## Consequences

- The 1.1 quality optimizer can drive every recall scoring column's weight,
  unblocking the ablation/combination gauntlet over the real corpus.
- Honest temporal/connection/field/preference recipes are now expressible
  (next mission: the named-preset roster — no presets are added here).
- No type change to `RecallShape` — the new keys are read through the existing
  `weight(for:)` / `weight()` lookup (default `1.0`). No public API widening.
- `nil` shape remains byte-identical to today on every path; the back-compat
  contract is unchanged and proven.
- A stale code comment ("Matrix/graph/preference lanes are NOT shape-steerable")
  was false after this change and was removed in both ports (comment fidelity).

## Status

Decided. Implemented in mission 6b-modifiers-matrix-steer (Swift
`RecallDirector` + Rust `coordinator.rs`, conformance-gated by
`RecallShapeMatrixSteerTests.swift` / `recall_shape_matrix_steer_parity.rs`).
