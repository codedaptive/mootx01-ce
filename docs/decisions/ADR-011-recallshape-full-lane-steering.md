---
status: decided
question: Should RecallShape's lane-key surface steer ONLY the retrieval lanes, or ALL recall scoring columns (retrieval + matrix/graph/preference)?
authors: MOOTx01 maintainers
date: 2026-06-17
version: 1.3.0
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

Both ports populate `graph` and `preference` from a registered `GraphCache` /
`PreferenceStore` (the dreaming/training caches). The Swift port has done so
since the original mission; the Rust port now wires the same consumption surface
(mission glk-recall-graphpref-rust, 2026-06-17): Rust GLK defines the
`GraphCache` / `PreferenceStore` traits, `EstateCoordinator.register_graph_cache`
/ `register_preference_store`, per-candidate `col_graph` / `col_preference`
lookups in the `matrixAware` score loop, and carries the live columns onto the
`RecallScoreVector`. When no cache is registered the column reads `0.0` on both
ports (the correct fresh-estate behaviour). With a registered cache the
`graph` / `preference` keys steer the live columns identically cross-port — the
keys, their semantics, the composition with `RecallWeights` (both columns share
the `weights.graph` slice), and the resulting fused `final` all agree Swift↔Rust.

The conformance tests assert the LIVE surface in both ports over a shared
fixture: a constant `GraphCache`(0.8) / `PreferenceStore`(0.9) makes the columns
measured-uniform, normalizing to exactly `0.5` on both ports; excluding a column
(weight 0) changes a fused final and a negative weight subtracts strictly below
weight 0 (`RecallShapeMatrixSteerTests.swift` /
`recall_shape_matrix_steer_parity.rs`). This closes the parity violation D-4
previously documented (Rust columns hardcoded `0.0`).

PRODUCER boundary — the GRAPH producer now EXISTS on both ports
(mission BRAIN-GRAPH-PRODUCER, 2026-06-17). The graph-centrality producer is a
cadence-driven AutonomicGovernor duty (Swift `AutonomicGovernor.graphCentralityScan`
/ Rust `graph_centrality_duty`) that reads the estate structure graph (drawers +
tunnels + kg_facts), computes per-drawer eigenvalue centrality via the existing
conformance-gated NeuronKit `keystones` oracle (no math reinvented — I-17), wraps
the scores in a `GraphCache`, and registers it on the kit/coordinator. After it
runs, the `unionBest` / `matrixAware` recall `graph` column is LIVE on both ports
(non-zero for structurally-central drawers, identical Swift↔Rust for the same
graph). The producer lives in the AutonomicGovernor (not the standing-signal
scheduler) because that is the ONLY cadence-driver that can register a cache at
parity: the Swift scheduler `emit` closure CAN capture the kit, but the Rust
scheduler emission model (`Propose | Associate | MutateCandidate | Diagnostic`)
cannot register a cache and the synchronous `Fn(&SignalContext)` closure has no
`&mut EstateCoordinator`. The governor already holds the kit/coordinator and runs
estate-reading duties on a cadence, making it the faithful cross-port home.

The PREFERENCE producer now EXISTS on both ports (mission BRAIN-PREF-PRODUCER,
2026-06-17), built as the SIBLING of the graph producer. It is a cadence-driven
AutonomicGovernor duty (Swift `AutonomicGovernor.preferenceScan` / Rust
`preference_duty`) that reads the estate's recall-trace reward history
(`RecallTraceItem`: per-drawer `target` + `used` flag), shapes it into per-drawer
`(label, endorsements, dismissals)` curation records (surfaced-and-used →
endorsement, surfaced-and-passed → dismissal — the implicit relevance signal,
C-15), fits per-drawer Bradley-Terry preference strengths via the existing
conformance-gated NeuronKit `learnedPreference` / `learned_preference` anchor-
reduction fitter (the `Bias` lens — no fitting math reinvented, I-17), wraps the
strengths in a `PreferenceStore`, and registers it on the kit/coordinator. After
it runs, the `unionBest` / `matrixAware` recall `preference` column is LIVE on
both ports (non-zero for endorsed drawers, identical Swift↔Rust for the same
record set). It lives in the AutonomicGovernor for the same parity reason as the
graph producer: only the governor holds the kit/coordinator on a cadence and can
register a store at parity. The OUTCOME SOURCE is the recall reward cycle, which
already records traces; no new substrate data was required.

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
The Rust `GraphCache` / `PreferenceStore` consumption surface (D-4) was wired in
mission glk-recall-graphpref-rust (2026-06-17), bringing Rust to parity with the
Swift recall-side surface. The GRAPH-centrality PRODUCER (D-4 producer boundary)
was built on both ports in mission BRAIN-GRAPH-PRODUCER (2026-06-17) as an
AutonomicGovernor duty over the NeuronKit `keystones` oracle; the `graph` column
is now live in production on both ports. The PREFERENCE producer was built on both
ports in mission BRAIN-PREF-PRODUCER (2026-06-17) as the sibling AutonomicGovernor
duty over the NeuronKit `learnedPreference` Bradley-Terry fitter, reading the
recall-trace reward cycle; the `preference` column is now live in production on
both ports. Both D-4 producer boundaries are now closed.

## Changelog

- 1.3.0 (2026-06-17) — D-4 producer boundary closed: the PREFERENCE producer now
  exists on BOTH ports (mission BRAIN-PREF-PRODUCER), built as the sibling of the
  graph producer. A cadence-driven AutonomicGovernor duty (Swift `preferenceScan`
  / Rust `preference_duty`) reads the estate's recall-trace reward history
  (`RecallTraceItem` target+used), shapes it into per-drawer
  `(endorsements, dismissals)` records (surfaced-and-used → endorsement,
  surfaced-and-passed → dismissal), fits per-drawer Bradley-Terry strengths via
  the NeuronKit `learnedPreference` / `learned_preference` anchor-reduction fitter
  (I-17, no math reinvented), and registers a `PreferenceStore`, taking the recall
  `preference` column from dark to live in production on both ports. The outcome
  source is the existing recall reward cycle — no new substrate data was needed.
  Conformance: `PreferenceProducerTests.swift` / `preference_producer_parity.rs`
  (faithful-wrapper, endorsed-outranks-dismissed, outcome shaping, C-16 totality,
  cadence, end-to-end dark→live). Both D-4 producer boundaries are now closed.
- 1.2.0 (2026-06-17) — D-4 producer boundary updated: the GRAPH-centrality
  PRODUCER now exists on BOTH ports (mission BRAIN-GRAPH-PRODUCER). A
  cadence-driven AutonomicGovernor duty (Swift `graphCentralityScan` / Rust
  `graph_centrality_duty`) computes per-drawer eigenvalue centrality via the
  NeuronKit `keystones` oracle and registers a `GraphCache`, taking the recall
  `graph` column from dark to live in production on both ports. Conformance:
  `GraphCentralityProducerTests.swift` / `graph_centrality_parity.rs`
  (faithful-wrapper, hub-outranks-spokes, kg_facts bond, C-16 totality, cadence,
  end-to-end dark→live). The PREFERENCE producer remains a separate open mission.
- 1.1.0 (2026-06-17) — D-4 updated: the Rust port now wires the `GraphCache` /
  `PreferenceStore` recall-consumption surface (traits, registration, per-
  candidate `col_graph`/`col_preference` lookups, live `RecallScoreVector`
  columns). The columns are no longer hardcoded `0.0`; the conformance tests now
  assert the LIVE path on both ports (constant cache → 0.5 cross-port). Records
  the still-open producer boundary (cache producers absent on both ports).
- 1.0.0 (2026-06-17) — Initial decision: RecallShape steers all recall scoring
  columns (retrieval + matrix/graph/preference) in unionBest `.matrixAware`.
