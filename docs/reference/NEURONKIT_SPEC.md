---
title: NeuronKit Specification
version: 1.7.0
status: active
date: 2026-07-16
description: "Behavioral specification for NeuronKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
package: NeuronKit
kind: Kit
relates_to:
  - docs/reference/NEURONKIT_INTERFACE.md
  - docs/reference/GENIUSLOCUSKIT_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/reference/SUBSTRATEML_SPEC.md
  - docs/reference/EIDETICLIB_SPEC.md
  - docs/reference/ENGRAMLIB_SPEC.md
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/reference/COGNITIONKIT_SPEC.md
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#55-brain-layer-ownership-and-dreaming
  - docs/reference/QUEUEKIT_SPEC.md
purpose: |
  NeuronKit is the subconscious mind of the MOOTx01 substrate: the
  algorithms layer that hosts the autonomic daemons (dreaming,
  maintenance, the audit-chain monitor), the reasoning functions
  (lattice-anchor inference, hybrid recall, MMR diversification,
  context synthesis, branch operations, the migration benchmark,
  tournament ranking, Bradley-Terry strength estimation), and the
  reasoning-lens surface — a taxonomy of substrate-shaped reasoning
  results built on the gated SubstrateML / GeniusLocusKit math
  primitives (structure, topics, preference, prediction). It owns no
  substrate state. Every substrate touch flows through the
  GeniusLocusKit estate verb surface; the one acknowledged exception is
  read-only LocusKit value-type access used to shape reasoning value
  types. The companion INTERFACE document carries the signatures.
---

# NeuronKit Specification

The reasoning-lens surface is a first-class settled design: the lens
cluster (keystones, constellation, spreading activation, theme weather,
latent themes, bias, learned preference, anticipation) is specified as a
deliberate taxonomy with a shared construction archetype
(§ 8, "surface-then-sequence"), and both ports realise the full lens
surface (I-2 design law: every surface has both legs).

## § 1 — What this package is

NeuronKit is the algorithms layer of the MOOTx01 substrate — the
"subconscious mind." It sits above GeniusLocusKit and offers three
families of function:

- **Autonomic functions.** Background daemons that mine substrate state
  and *propose* changes for human confirmation: the dreaming daemon
  (latent-association discovery, § 3.1), the maintenance daemon
  (five health scans + the audit-chain integrity monitor, § 3.2 / § 3.5).
  Each is a Swift `actor` that ticks on a schedule and on demand, and
  whose only writes are proposals plus one cycle diary entry. They
  never mutate the substrate directly.
- **Reasoning functions.** Pure, on-demand computations: lattice-anchor
  inference (§ 4.0), hybrid recall (RRF + MMR, § 4.1), standalone MMR
  diversification (§ 4.1 step 4), context synthesis (§ 4.2), copy-on-write
  branch operations (§ 4.3), the migration recall-fidelity benchmark
  (§ 4.7), tournament ranking (§ 4.4), and the Bradley-Terry batch MLE
  ranker (§ 4.4).
- **Reasoning lenses (§ 7).** Pure, on-demand reasoning *results* shaped
  over the gated SubstrateML / GeniusLocusKit math primitives — the
  structural lenses (keystones, constellation, spreading activation),
  the topic lenses (theme weather, latent themes), the preference lenses
  (representation bias, learned preference), and the prediction lens
  (anticipation). Each lens is a thin NeuronKit shape over a conformance-
  gated primitive that already lived in the lower layer and that nothing
  reasoned with until the lens surfaced it (the surface-then-sequence
  archetype, § 8).

NeuronKit is consumed by CognitionKit (the named-recipe layer), which
sequences daemons, reasoning functions, and lenses into user-facing
recipes; the catalog of shipped recipes is in `COGNITIONKIT_SPEC.md`.
NeuronKit itself ships no user-facing recipes.

This package is a **Kit**: it manages lifecycle (the daemon actors carry
actor-isolated mutable state across cycles) and composes upstream kits.
Its reasoning engines and lenses are pure and stateless; the autonomic
daemons are the stateful surface.

## § 2 — Scope

This specification defines:

- The substrate-access discipline (B-1) and the one acknowledged
  read-only LocusKit value-type exception.
- The dreaming daemon: its seam architecture, the seven-step tick, the
  contrastive-confidence and EWC++ consolidation math, and the
  never-create-Tunnels structural guarantee.
- The maintenance daemon: the five health scans, the audit-chain monitor,
  and the never-remediate structural guarantee.
- The reasoning functions: lattice-anchor inference, hybrid recall
  (RRF + MMR), standalone MMR, context synthesis, branch operations,
  the migration benchmark, tournament ranking, and Bradley-Terry.
- **The reasoning-lens taxonomy (§ 7) and the surface-then-sequence
  archetype (§ 8) that governs every lens.**
- Determinism obligations (`now` and `rng_seed` passed in, never
  `Date()` or unseeded randomness in engines).
- The conceptual error model.
- Cross-port (Swift / Rust) conformance obligations, including the
  obligation that **both ports realise the full lens surface**.

This specification does NOT define:

- API signatures — those live in `NEURONKIT_INTERFACE.md`.
- The estate verb surface, branch COW mechanics, or the Brain-layer
  adapter that binds the daemon seams to live verbs — those are
  GeniusLocusKit's (`GENIUSLOCUSKIT_SPEC.md`).
- **The gated math primitives the lenses surface — eigenvalue
  centrality, Louvain community detection, random-walk-with-restart,
  NMF, exponential decay, the action-outcome matrix + Wilson bound, and
  the Bradley-Terry MLE — those are SubstrateML's / GeniusLocusKit's**
  (`SUBSTRATEML_SPEC.md`, GLK matrix tier). NeuronKit shapes their
  inputs and outputs; it does not own the math.
- The linguistic pipeline (tokenize, normalize, stem, gazetteer-match,
  classify, resolve) — that is EideticLib's (`EIDETICLIB_SPEC.md`).
- The Hamming distance primitive — that is EngramLib's
  (`ENGRAMLIB_SPEC.md`).
- Storage, SQL, and the `Drawer` schema — those are LocusKit's
  (`LOCUSKIT_SPEC.md`).
- User-facing recipes and the estate-side sequencing that derives each
  lens's input from a live estate — those are CognitionKit's
  (`COGNITIONKIT_SPEC.md`).
- The analytics capabilities (`associationRuleMining`,
  `formalConceptAnalysis`) that CognitionKit declares as gated
  `NeuronKitCapability` cases: the computation engines
  (`AssociationRuleMining`, `BoundedConceptMiner`) are SubstrateML's,
  the capability names belong to CognitionKit's gate vocabulary, and
  NeuronKit neither owns nor wraps them.

## § 3 — Position in the kit family

```
EideticLib   EngramLib   SubstrateML (gated math)   LocusKit (read-only value types)
     ▲            ▲              ▲                          ▲
     │            │              │                          │
   GeniusLocusKit (estate verb surface; branch COW; Brain layer; matrix tier)
     ▲
   NeuronKit   ← composes all of the above; daemons + reasoning functions + lenses
     ▲
   CognitionKit   (named recipes — ships and sequences the lens surface)
```

**Depends on:** EideticLib (text-to-anchor `lookup`), EngramLib
(Hamming `distance` for MMR), SubstrateML (the gated reasoning-lens math
primitives — centrality, communities, random-walk, NMF, decay,
action-outcome matrix, Bradley-Terry), GeniusLocusKit (the
`EstateHandle`, the nine estate verbs, branch COW verbs,
`ExternalCorpus`, `AuditChainVerifier`, and the matrix-tier `MatrixNMF`),
and LocusKit (the read-only `Drawer` value type and its read-only
adjective-state accessors — the B-1 exception, I-2).

**Consumed by:** CognitionKit. CognitionKit ships and sequences the lens
surface into named recipes; the `RecipeCatalog` enumerates the shipped
recipes (`COGNITIONKIT_SPEC.md`). The lenses exist to be sequenced,
and the surface is contracted so the Swift and Rust ports converge.

## § 4 — Invariants

**I-1 (no autonomic substrate writes outside `propose` + diary):** an
autonomic daemon's only writes are proposals (via the estate `propose`
verb, in production) and exactly one cycle diary entry. It has no other
write path, structurally: the daemon's write seam exposes only
`propose(_:)` and `recordCycleDiary(_:)`.

**I-2 (read-only LocusKit value-type exception):** NeuronKit may import
LocusKit solely to reference the `Drawer` value type and its read-only
adjective-state accessors (`isCurrentlyBelieved`, `adjectiveSensitivity`,
`exportability`) when shaping reasoning value types and synthesis math.
This is the single acknowledged exception to B-1. No LocusKit verb call,
no SQL, no storage handle is reachable from NeuronKit. (See B-1.)

**I-3 (forbidden-combination discipline):** a drawer may not be both
`secret` AND publicly exportable. The maintenance daemon scans for this
and proposes a discipline-violation remediation; the substrate, not
NeuronKit, owns the constraint. (LocusKit § 6.1.)

**I-15 (parent never modified by branch derivation):** deriving a COW
branch never mutates the parent estate. The guarantee lives in the
GeniusLocusKit substrate; NeuronKit's branch wrappers are thin forwards
and add no second place the guarantee could drift. (GeniusLocusKit
C-10.)

**I-16 (tournaments never auto-promote):** `runTournament` performs zero
substrate writes and never calls a branch-promotion verb. Its `winner`
is advisory only. Promotion is a separate, human-initiated GeniusLocusKit
verb (`glkPromoteBranch`).

**I-17 (lenses own no math):** every reasoning lens (§ 7) is a *shape*
over a gated primitive owned by SubstrateML or the GeniusLocusKit matrix
tier. A lens never re-implements centrality, community detection, the
random walk, NMF, decay, the Wilson bound, or the Bradley-Terry MLE — it
shapes the substrate into the primitive's input and the primitive's
output into a reasoning result. A lens that reaches into bit arithmetic
or matrix math the lower layer already owns is non-conformant. (See § 8.)

**I-18 (lenses are pure and side-effect-free):** every lens is a
deterministic function of its explicit inputs. A lens issues no estate
verb, writes nothing, and reads no substrate state beyond the arguments
it is handed (the estate-side derivation that gathers those arguments is
CognitionKit's, not the lens's). A lens that touches an estate handle is
non-conformant. (Consistent with B-3.)

## § 5 — Behavioral contracts

**B-1 (substrate access discipline):** NeuronKit never executes SQL and
never calls LocusKit, VectorKit, CorpusKit, PersistenceKit, or QueueKit
write APIs directly. The GeniusLocusKit estate verb surface is the only
substrate boundary. EngramLib (`distance`), EideticLib (`lookup`), and
SubstrateML (the gated lens primitives) are typed-math / lookup
dependencies with no substrate, SQL, or estate access, consistent with
B-1. The one acknowledged exception is the read-only LocusKit value-type
access in I-2. Because the Brain-layer verb surface is not yet live (the
GeniusLocusKit `propose` verb raises `notSupportedByEstate`, and no verb
yet reads recall traces, existing tunnels, drawers, or the audit log, or
writes a diary entry), the daemons depend on NeuronKit-owned **seam
protocols** that the production Brain-layer adapter will bind to live
verbs. The daemons reference substrate *value* types but call no
substrate *method*, so B-1 holds structurally today.

**B-2 (proposals are not actions):** every autonomic function that
detects something needing human attention emits a `ProposeFrame`; it
never applies the change. The dreaming daemon proposes Tunnels but never
creates one (its sink has no Tunnel-creation method); the maintenance
daemon proposes remediations but never remediates (its sink has no
expunge / withdraw / mutate method).

**B-3 (reasoning functions and lenses have no autonomic side effects):**
the reasoning functions and the lenses read their inputs, compute, and
return. The sole documented substrate touch among the reasoning
functions is the migration benchmark (§ 4.7) and tournament ranking
(§ 4.4), which issue ONLY the read-only `BranchHandle.recall(_:)` and no
write verb. Context synthesis (§ 4.2) reserves its `estate` parameter
and touches it not at all (C-9). The lenses (§ 7) touch no estate at all
(I-18).

**B-4 (autonomic idempotency):** re-running a daemon over unchanged
state emits no duplicate proposals. Each daemon keeps an actor-isolated
set of already-proposed candidate keys; a key already proposed in a
prior cycle is suppressed and counted, never re-emitted.

**B-5 (deterministic engines):** every NeuronKit computation is a
deterministic function of its inputs. No engine reads the wall clock —
`now` is always a caller-supplied parameter (the daemon `pump`/`trigger`
methods, the benchmark, the tournament, the dreaming/maintenance cycles).
Any lens with a randomised primitive (spreading activation's restart
walk, latent themes' NMF seeding) takes an explicit `rng_seed`/`seed`
and is a pure function of it — never a clock-derived seed. There is no
unseeded randomness and no hash-order iteration that reaches the output:
ties break on stable keys (input index, ascending ID string, ascending
label, ascending node index, geometric-mean-normalised strength), so the
Swift and Rust ports agree bit-for-bit on shared vectors.

**B-6 (hybrid recall is bounded by the verb surface):** the `recall`
verb returns a single ordered `[Drawer]` (its internal RRF over the BM25
and vector lists is drained inside the GeniusLocusKit boundary). The
hybrid-recall wrapper therefore runs the RRF math over a degenerate
(L₁ == L₂) input and applies MMR using a deterministic, vector-free
shingle-Jaccard proxy — actual embedding similarity is not reachable
under B-1. The tuning knobs (`bm25Weight`, `vectorWeight`, `rrfK`,
`mmrLambda`) are preserved so the day the verb surface exposes separate
lexical and semantic lists, only the fan-in changes.

**B-7 (the migration benchmark is zero-tolerance for silent loss):**
`benchmark`'s `notFoundInBranch` set lists concepts present in the
origin corpus but absent from branch recall. A conforming migration
yields an empty set; any non-empty value disqualifies the branch from
tournament ranking downstream (the C-13 gate, applied before scoring).

**B-8 (lenses are total over edge inputs):** every lens returns an empty
or neutral result for a degenerate input rather than throwing — an empty
node/label/observation set, a `k`/`top_k` of zero, an out-of-range seed,
a zero-length walk. The single exception is `learnedPreference`, which
forwards the Bradley-Terry fitter's typed errors (§ 6) and otherwise
shrinks toward neutral via the anchor-baseline reduction (§ 7.3). Edge
totality is a conformance obligation, not a convenience (C-16).

### § 5.1 — Q-ID-completion terminal workflow (enrichment pipeline)

**The gate:** every Q-ID that enters the maintenance daemon's
enrichment retry must reach a terminal — either resolved into a concrete
Q-ID by an implemented path, or moved into a real completed workflow that
obtains the missing data and then resolves it. **No durable pending state
is allowed.** Passive `qid_pending` that survives a cycle is debt; only a
real runtime substrate-write failure (after the workflow exists) may leave
a row pending, and that is retried next cycle.

**Failure-mode census** (derived from `EideticLib.lookup` →
`FDC.encodeAnchor`, mirrored in `NeuronKit.inferLatticeAnchor`):

| Mode | Inference condition | Initial status | Terminal |
|------|---------------------|----------------|----------|
| A | code resolved, Q-ID resolved | `qidCompleted` (2) | resolved — no action |
| B | code resolved, no Q-ID | `qidPending` (1) | retry resolves it if a newer canon is in effect; otherwise re-inference is deterministic, so the daemon files an enrichment proposal and moves the drawer to `qidProposed` (4); acceptance → `qidCompleted` |
| C | unresolved (code empty) | `none` (0) | capture-path concern (initial classification) — never enters the daemon's `qidPending` scan; the daemon's proposal route applies if such a row is ever surfaced as pending |

**The terminal in-workflow state** is `EnrichmentStatus.qidProposed`
(raw 4, provenance bits 36-41). It is NOT re-picked by `qidPendingDrawers`
(that scan filters `== qidPending`), so a proposed row leaves the retry
backlog. The acceptance path
(`GeniusLocusKit.resolveEnrichmentProposal`) writes the human/agent-
supplied Q-ID into the drawer's anchor and flips the status to
`qidCompleted` (2) — two atomic, audited writes.

**Pipeline contract** for the whole workflow:

| Field | Value |
|-------|-------|
| Owner | maintenance daemon (`MaintenanceDaemon.runCycle` step 5.5) files the proposal; the GeniusLocusKit acceptance surface (`resolveEnrichmentProposal`) completes it |
| Code path | NeuronKit `MaintenanceDaemon` (Mode-B branch) → GeniusLocusKit `propose` (kind `.enrichment`) + `updateEnrichmentStatus(→qidProposed)`; acceptance: GeniusLocusKit `resolveEnrichmentProposal` → `Estate.reanchorAnchor` (Q-ID into anchor) + `Estate.mutateProvenance` (→qidCompleted) |
| Data | `EnrichmentStatus.qidProposed` (raw 4) on all four enum mirrors; vocabulary gate legal values permit raw 4; `ProposalKind.enrichment` |
| Trigger | autonomic — the maintenance daemon's per-cycle retry batch; acceptance triggered by a human/agent confirming the proposal |
| Conformance | Both ports: unresolved drawers reach `qidProposed`, and no cycle ends with a durable-pending row. The acceptance path writes the Q-ID, flips the status, preserves other provenance bits, and throws on an absent drawer |
| Terminal state | RESOLVED → `qidCompleted`; UNRESOLVED → `qidProposed` (in-workflow) → acceptance → `qidCompleted`. Never durable `qidPending` (except a real runtime write failure, retried next cycle) |

**Port-parity note:** the daemon completion branch, the enums, the
vocabulary gate, and `ProposalKind.enrichment` are mirrored Swift+Rust.
The GLK acceptance method `resolveEnrichmentProposal` and the enrichment
retry reads are Swift-side surfaces with no Rust GLK coordinator peer —
consistent with the pre-existing asymmetry documented in
`maintenance_cycle.rs` (the Rust maintenance adapter writes via
`store.add_proposal` directly; the Rust GLK coordinator exposes no
enrichment surface). Both terminal primitives — anchor write
(`reanchor_gated`) and provenance flip (`mutate_provenance`) — exist on
both ports of LocusKit, so the terminal is reachable in either port.

## § 6 — Error model (conceptual)

NeuronKit's reasoning surface is mostly total — edge inputs (empty
candidate lists, `k <= 0`, empty corpora, empty lens inputs) return
empty / neutral results rather than throwing. The one family that raises
typed errors is the Bradley-Terry fitter and its preference-lens caller,
which own NeuronKit's `MOOTx01Error` enum per the project convention (one
typed error enum per owning module, never optionals plus logging).
Daemon and branch operations surface upstream GeniusLocusKit verb errors
unchanged.

| Category | Trigger | Recovery posture |
|---|---|---|
| Self-pairing (`selfPairing`) | A `PairwiseOutcome` has `winner == loser` — a malformed tally, not a quantity-zero record. (`learnedPreference` raises this only if a room is literally named the baseline sentinel.) | Abort the fit; surface so the caller corrects tally construction. Never silently dropped. |
| Disconnected comparison graph (`disconnectedComparisonGraph`) | The directed win graph is not strongly connected, so the BT MLE is not finite (a competitor never wins, or never loses, or a group is uncompared). | Abort the fit; finite confidence intervals cannot be represented for a non-finite estimate. **Note:** `learnedPreference`'s anchor-baseline reduction (§ 7.3) makes the graph strongly connected by construction, so the preference lens cannot raise this case. |
| Verb error (forwarded) | A branch op, benchmark, or daemon proposal hits a stale handle or a not-yet-live verb (`estateNotOpen`, `notSupportedByEstate`). | Forwarded unchanged from GeniusLocusKit; the caller retries or aborts per the verb's contract. |

Rust version note: the Rust version models the two fitter errors as a
crate-local `TournamentError` enum (`SelfPairing`,
`DisconnectedComparisonGraph`) rather than a shared `MOOTx01Error` name.
The *cases* and their triggers match; the *type name* differs across
ports (documented drift — see § 9 C-6 and INTERFACE § 4). This is the
**only** sanctioned cross-port type-name divergence; everything else,
including the entire lens surface, must agree in both name and value.

## § 7 — The reasoning-lens taxonomy

A reasoning lens turns one gated lower-layer math primitive into one
substrate-shaped reasoning result. Lenses are grouped by the cognitive
question they answer. Every lens obeys I-17 (owns no math), I-18 (pure,
no estate touch), B-5 (deterministic, explicit seed where randomised),
and B-8 (total over edge inputs). The estate-side derivation that builds
each lens's input from a live estate is CognitionKit's, not NeuronKit's.

### § 7.1 — Structure lenses (over the drawer/tunnel graph)

**Keystones — load-bearing memory.** Surfaces SubstrateML's gated
`EigenvalueCentrality` over the undirected graph formed by drawer-id
edge pairs (weight 1 each; self-loops and edges with an absent endpoint
ignored). Ranks the top `top_k` nodes by centrality, descending, ties by
ascending id. "The spine of your thinking" — the memories the rest hangs
off. Result: `[Keystone { id, centrality }]`.

**Constellation — emergent communities.** Surfaces SubstrateML's full
Louvain `CommunityDetection.detectFull` (phase 1 + phase-2 aggregation,
`maxLevels = topologyMaxLevels = 10`, `resolution = topologyResolution
= 0.05`) over the same undirected drawer-id graph (weight 1;
absent-endpoint edges ignored). Where Keystones finds the load-bearing
nodes, Constellation finds the *clusters* — emergent themes the user
never named. Result: `Constellation { communities: [[id]] }`.

**Spreading activation — free association.** Surfaces SubstrateML's
random-walk-with-restart (`RandomWalks`) from one `seed` node over a
weighted adjacency (`adjacency[i]` = the weighted out-edges
`(neighbor, weight)` of node `i`). At each step the walk either follows a
weighted edge or teleports home with probability `restart_prob`
(SubstrateML default 0.15); visit frequency over `walk_length` steps IS
the activation. Returns the top `k` most-activated nodes, strongest
first, ties by ascending node index; the **seed is excluded** (association
is what the seed reaches, not the seed). Deterministic for a fixed
`rng_seed`; an out-of-range seed or zero-length walk yields no
activations. Result: `[Activation { node, activation }]`.

**StructureGraph — shared adjacency builder for § 7.1.** Both Keystones
and Constellation read "the undirected graph formed by drawer-id edge
pairs (weight 1; self-loops and absent-endpoint edges ignored)." That
shaping step lives in `StructureGraph` so both surfaces receive the same
graph construction from their gated primitive. `StructureGraph` owns no
math (I-17); it is pure shaping — a static helper that maps a
`(nodeIDs, edges)` pair into the adjacency form the SubstrateML
primitives consume. Both ports ship the helper:
`Lenses/StructureGraph.swift` (Swift) and `src/structure_graph.rs`
(Rust).

### § 7.2 — Topic lenses (over categories / co-occurrence)

**Theme weather — recency momentum.** Surfaces SubstrateML's exponential
`decay`. Given per-category `(category, raw_count, weighted_mass)` where
`weighted_mass` is the sum of `recencyWeight` over the category's
memories, momentum = (weighted_mass / Σweighted) − (raw_count / Σraw): a
category whose recent attention share exceeds its historical share is
heating. Returned sorted by momentum descending (hottest first), ties by
category name. The thin `recencyWeight(elapsedSeconds, halfLifeSeconds)`
helper (1.0 at "now", halving each half-life) is the only piece NeuronKit
exposes directly over `decay_factor`. Result:
`[CategoryMomentum { category, momentum }]`.

**Latent themes — soft topic factors.** Surfaces the GeniusLocusKit
matrix-tier `MatrixNMF` (deterministic SplitMix64 seeding). Given a
sparse symmetric co-occurrence `(label_a, label_b, weight)` over `labels`
(pairs with an absent endpoint ignored), NMF factors it into `k` latent
themes (`k` clamped to the label count); each label gets a soft loading
vector → mixed-membership reasoning ("60% theme A, 30% theme C"), not a
hard bucket. Deterministic for a fixed `seed`. Result:
`LatentThemes { k, loadings: [ThemeLoading { label, loadings, dominantTheme }], reconstructionError }`.

### § 7.3 — Preference lenses (what the estate leans toward / away from)

**Representation bias — distributional.** The signed difference between
the estate's share and a reference share, per category over the union of
both label sets (a category present only in the reference gets
estate_share 0 ⇒ strongly negative = avoided). Sorted by bias descending
— most over-represented first, most avoided last, ties by label. Honest
about being a share difference, not dressed-up math. Result:
`[CategoryBias { label, estateShare, referenceShare, bias }]`.

**Learned preference — Bradley-Terry from curation.** The deeper, learned
half of the preference lens. Fits a Bradley-Terry utility over rooms from
per-room curation records `(label, endorsements, dismissals)` — now that
the `confirm` verb makes those choices a real event source. Construction
is the **anchor reduction**: every room competes against one shared
neutral baseline competitor, beating it once per endorsement and losing
once per dismissal, with a uniform +1 pseudo-win added in each direction
between every room and the baseline. That minimal symmetric prior (a)
makes the directed win graph strongly connected — so the MLE is finite
even for an only-confirmed or only-withdrawn room and the lens cannot
raise `disconnectedComparisonGraph` (§ 6) — and (b) shrinks rooms with
little curation signal toward the baseline (strength ≈ 0 = "no learned
preference yet"). The fitter gauge-fixes strengths to sum to zero over
{rooms, baseline}; re-centering subtracts the baseline's fitted strength
so the baseline reads exactly 0 and each room's sign is its preference
relative to neutral. Labels must be unique; empty input ⇒ empty output;
`selfPairing` propagates only if a room is literally named the baseline
sentinel. Returned strongest first, ties by ascending label. Result:
`[PreferenceStrength { label, strength, confidenceLow, confidenceHigh, endorsements, dismissals }]`.

### § 7.4 — Prediction lens (action → outcome)

**Anticipation — the learned action→outcome model.** Surfaces
SubstrateML's `ActionOutcomeMatrix` + Wilson lower bound. Given observed
`ActionObservation { action, outcome, success }` events, learn which
actions reliably reach a desired `target_outcome` — ranked by the Wilson
lower bound so a few lucky successes don't outrank a well-evidenced
action. Returns the top `k` actions seen at least `min_observations`
times. "To reach Y, you tend to do X." This is the genuine
action-outcome lens (distinct from the explicit-tunnel successor signal).
Events are category-keyed, so HLC ordering is irrelevant — `HLC::zero()`
is used for every observation (recency/decay is a separate concern,
handled by theme weather). Result:
`[ActionPrediction { action, successRate, count }]`.

### § 7.5 — Substrate-signal lenses (MomentSignature, Rhythm, Precedence, Complexity, Calibration)

Each lens gates a SubstrateML or GeniusLocusKit primitive that
was already conformance-tested but surfaced to no reasoning result until this section.

**MomentSignature (Topics + Time).** Surfaces `MomentSummary.orReduce` and
`EngramLib.distance`. Given a time-windowed slice of fingerprinted rows (`[RowLite]`) and
a candidate set (`[Fingerprint256]`), OR-reduces the window into one signature fingerprint
and ranks candidates by ascending Hamming distance. Ranking ties (equal Hamming distance)
resolve by input order (stable sort). Empty `fingerprints` or empty `candidates` returns
a zero signature and empty ranking. Result: `MomentSignatureResult { signature, ranking }`.

**Rhythm (Prediction + Time).** Surfaces `FFT.forward`. Given a boolean activity
series and a bucket duration, converts to float, zero-pads to the next power of two (as
required by `FFT.forward`), extracts positive-frequency bins 1..N/2, normalises magnitudes
by total AC energy, and returns top-K dominant periods sorted by relative magnitude
descending. All-constant series, series shorter than 4 elements, non-positive duration,
and `topK == 0` return empty (B-8). Result: `[DominantPeriod { periodSeconds, relativeMagnitude }]`.

**Precedence (Prediction).** Surfaces the T-matrix via pre-folded pairs. Given pre-folded
`[(TemporalCausalityKey, Int64)]` pairs already produced by `TemporalCausalityFold.fold`
and handed to the lens by CognitionKit, filters by target coordinate, sorts by count
descending (ties resolved by input order), and caps to k. Takes pre-folded inputs
(I-18: no estate touch). Empty pairs, `k == 0`, or no matching target returns empty (B-8).
Result: `[AntecedentRank { source, lagBucket, count }]`.

**Complexity (Topics).** Surfaces `InformationTheory.entropy` and
`InformationTheory.mutualInformation`. Normalises raw count distributions into probability
distributions before calling (input shaping, I-17). All-zero or empty counts yield
entropy 0.0 (zero distribution carries no information). Returns `entropyB` and
`mutualInformation` only when their inputs are provided. Result:
`ComplexityResult { entropyA, entropyB?, mutualInformation? }`.

**Calibration (Grounding + Trust).** Surfaces `MatrixCalibrationCurve.calibrate` (GLK
matrix tier). Given a calibration curve and a batch of claimed confidence values, maps
each through the curve's empirical success rate. `isCalibrated` is derived by replicating
the curve's bucket-index formula to test observation count — necessary because `calibrate`
returns the claimed value unchanged for empty bins, making calibrated results coincidentally
equal to the claim undetectable from the return value alone. Empty claimed returns empty (B-8).
Result: `[CalibratedValue { claimed, calibrated, isCalibrated }]`.

### § 7.6 — Diffusion lenses (node-layer motion)

The diffusion family is the time-axis peer of distillation: where distillation
extracts structure FROM content at ingest, diffusion tracks how a node's content
and classification EVOLVE over time. The node-layer lens is the first shipped tier.

**NodeMotion — node-layer motion model.** Folds a node's HLC-ordered audit
entries (via `UnifiedAuditLog`) into a decay-weighted motion model. The decay
weight is `exp(-λ·Δt_days)` where `λ` is the per-layer noise schedule constant
(`defaultNodeLambda = 0.5` per day — the node layer is high-frequency, so λ is
large). Dedup key is the FULL HLC identity `(physical, logical, node)` so two
mutations in the same millisecond (bursty writes, bulk import) are counted as
distinct volatility events. Physical-time age math uses a 40-bit mask to align
with the packed-HLC layout, avoiding a millennia-aged read when wall clock
exceeds the truncated physical field (secfix/ce-node-motion-hlc-dedup). Result:
`NodeMotion { rowID, volatility, eventCount, lastEventPhysicalMs, anchorTrajectory }`.

**NodeAnomaly — write-time verdict.** Classifies a `NodeMotion` as churning
(`volatility ≥ churnThreshold`, default 3.0) and/or reanchored
(`Set(anchorTrajectory).count > 1` — the node's topic has crossed at least two
distinct UDC codes). Reads hot at write time; the pure `fold`+`classify` pipeline
is deterministic over `(entries, now, λ, threshold)` and conforms to I-17, I-18.
GLK-bound estate-reading entry points (`run`, `anomaly`) are Swift-only per I-2.
Result: `NodeAnomaly { rowID, volatility, isChurning, reanchored, currentAnchor }`.

The pure `fold` and `classify` functions are both-port (C-18); `NodeMotionLens.run`
and `.anomaly` are Swift-only (GLK estate access — I-2 exception applies). Both
conformance obligations hold: the pure math is port-symmetric, and the estate
accessor is appropriately asymmetric.

---

## § 8 — The surface-then-sequence archetype

Every lens in § 7 is built to one archetype, and the archetype is itself
a design contract:

1. **The math is gated and idle in the lower layer.** SubstrateML and the
   GeniusLocusKit matrix tier already own the conformance-gated primitive
   (centrality, communities, the random walk, NMF, decay, the Wilson
   bound, the BT MLE). It was built, conformance-tested across ports, and
   *nothing reasoned with it* until the lens surfaced it.
2. **NeuronKit surfaces it.** A lens shapes the substrate's natural form
   (a drawer-id edge list, a sparse co-occurrence, per-category masses, a
   set of action-outcome events) into the primitive's input, calls the
   gated primitive, and shapes the primitive's output into a reasoning
   result with substrate-meaningful names. The lens adds no math (I-17).
3. **CognitionKit sequences it.** The named-recipe layer derives the
   lens's input from a live estate (build the adjacency from tunnels,
   gather per-category counts, derive a deterministic walk seed) and
   composes lenses into recipes. That derivation is not NeuronKit's
   (I-18); the lens is handed finished inputs.

This archetype is why the lens surface is thin, pure, deterministic, and
identical across ports: the hard, port-sensitive math lives once in the
gated lower layer, and the lens is a shape on either side of it. A new
lens is added by surfacing an existing gated primitive — never by
importing new math into NeuronKit.

## § 9 — Conformance requirements

**C-1 (dreaming cadence — v2 model, the recall-driven dreaming contract):** dreaming runs on the
shared REM dispatch table at four cadences. REM-ALPHA (30 s) is gated on
`pending_count(stream:"dreaming") > 0` — the daemon fires only when the
dreaming queue has items, driven by the resident governor (`.timer`) or a
forked `mootx01 dream` process (`.event`). REM-THETA (24 h), REM-BETA
(7 days), and REM-OMEGA (14 days) are gated on persisted last-run
timestamps; they run whenever their cadence is due, regardless of queue
depth. § 12 is the normative v2 specification; § 9 C-1 is a summary.

**C-4 (audit-chain integrity monitor alerts on tampering, AUDIT-ALERT-
RESTORE 2026-07-09):** the maintenance daemon's audit-chain integrity
monitor (step 0 of `MaintenanceDaemon.runCycle` / `run_cycle`) proposes an
integrity remediation on EITHER of two independent conditions, checked on
every audit-check cadence: (a) the chain walk itself finds an HLC
reversal or a content-hash mismatch on an admitted entry — the
pre-existing broken-chain path, keyed `audit_integrity|<brokenTag>`; or
(b) `UnifiedAuditLog`'s ingress (`add`/`merge`/`Codable` decode) rejected
one or more content-hash-mismatched entries while building the snapshot
this cycle scanned — keyed `audit_integrity_rejected|<rejectedCount>`.
Condition (b) exists because ingress rejection (codex a477800, secfix
ce-audit-content-id 5101e112) makes a tampered entry structurally unable
to reach the chain walk, so a tampered/corrupted estate audit trail
verifies vacuously clean under condition (a) alone — this invariant is
what restores daemon-level alerting at the ingress boundary. B-4
idempotency dedup applies to each condition's key independently: a
steady, unchanged rejected count is suppressed after its first alert
(the human already knows); a NEW, larger count proposes again. This
invariant does NOT weaken the ingress defence — rejected entries are
never re-admitted, only observed.

**C-6 (fitter error-name drift, sanctioned):** the Bradley-Terry fitter's
two error cases are `MOOTx01Error.selfPairing` /
`.disconnectedComparisonGraph` in Swift and `TournamentError::SelfPairing`
/ `::DisconnectedComparisonGraph` in Rust. Cases and triggers match; the
type name differs. This is the only sanctioned cross-port name divergence
(§ 6).

**C-8 (MMR on every page):** hybrid recall applies MMR reranking to the
full result before paging, so every emitted `RecallStream.Page` is drawn
from the reranked sequence. Even an empty result emits one terminal page
(`rows.isEmpty`, `isLast == true`).

**C-9 (synthesis is read-only):** `ContextSynthesizer.synthesize`
performs no estate write, invokes no estate verb, and consults no
substrate state beyond the materialised `page.rows`. Its `estate`
parameter is reserved and untouched.

**C-12 (audit ingress rejects, never re-admits, and is observable):**
`UnifiedAuditLog.add` (and every path that routes through it — `merge`,
`add(contentsOf:)`, `init(entries:)`, `Codable` decode) recomputes an
entry's SHA-256 content id on every ingress call; an entry whose stored
id does not match is dropped, never inserted, and never overwrites an
honest entry with the same id. This is unconditional — no configuration
re-admits a rejected entry. The rejection is also COUNTED
(`rejectedEntryCount` / `rejected_count()`) at the same choke point, so
the count is exactly as trustworthy as the rejection itself: any future
non-local audit ingress that bypasses `add`/`merge` bypasses both the
defence and the observability in the same stroke, which is why the
doc comment on `add` warns against adding alternative ingress paths.
See C-4 for how the daemon consumes this count.

**C-13 (zero silent migration loss):** the migration benchmark's
`notFoundInBranch` is empty for a conforming migration; a non-empty set
disqualifies the branch from tournament ranking (the gate is applied
BEFORE scoring, and disqualified branches are retained with a typed
reason rather than dropped). The benchmark's only substrate call is the
read-only `BranchHandle.recall(_:)`.

**C-15 (reward source):** the dreaming daemon derives reward from
`RecallTraceItem.used` via the default `RecallTraceRewardSource`
(used → 1.0, unused → 0.0). Ignoring this source is non-conformant.
The two-source taxonomy is fully live: the explicit source
(`ExplicitDiaryRewardSource`, backed by `DiaryEntry.reward`) overrides the
implicit trace source when the diary entry carries a non-nil reward; absent
an explicit reward, the fallback is `RecallTraceRewardSource`. Both sources
are available since LocusKit schema v1 + NeuronKit B2-4.

**C-16 (lens edge-totality):** every lens returns empty/neutral for a
degenerate input (empty node/label/observation set, zero `k`/`top_k`,
out-of-range seed, zero-length walk) and never throws — except
`learnedPreference`, which may forward `selfPairing` per § 6. (B-8.)

**C-17 (lens primitive-fidelity):** each lens's numeric output equals the
gated lower-layer primitive's output for the shaped input — the lens adds
no math (I-17). A lens whose result diverges from a direct call to the
underlying SubstrateML / matrix-tier primitive on the same shaped input
is non-conformant.

**C-18 (full lens surface on both legs):** both the Swift and Rust ports
realise the complete lens taxonomy (§ 7) — keystones, constellation,
spreading activation, theme weather, latent themes, representation bias,
learned preference, anticipation, momentSignature, rhythm, precedence,
complexity, calibration, and the diffusion node-layer lenses nodeMotion
(`fold`) / nodeAnomaly (`classify`) — with matching type and member names
(the § 6 fitter-error name being the lone sanctioned exception) and
bit-for-bit-equal numeric results on shared vectors. A surface present on
one leg and absent on the other is non-conformant; this is the
design law applied to NeuronKit (I-2 / "everything has both legs").
The GLK-bound entry points `NodeMotionLens.run` / `.anomaly` are
Swift-only and are NOT part of the C-18 parity obligation — only the pure
`fold` and `classify` algorithms that the estate-reading entry points wrap.

**C-Det (cross-port determinism):** for every shared test vector, the
Swift and Rust ports agree bit-for-bit on the reasoning engines AND the
lenses they both implement — lattice-anchor inference, hybrid-recall
rerank / shingle similarity / paging, context synthesis, the
Bradley-Terry fit (strengths AND confidence-interval bounds), and every
§ 7 lens (centrality scores, community partitions, activation
frequencies, momentum, NMF loadings + reconstruction error, bias
differences, preference strengths + intervals, Wilson-ranked
predictions, OR-reduced window signatures + Hamming rankings,
dominant spectral periods, T-matrix antecedent rankings, Shannon
entropy + mutual information, empirical confidence calibration, and the
diffusion-lens pure folds: NodeMotion volatility + anchorTrajectory,
NodeAnomaly isChurning + reanchored). Tie-breaks resolve on stable keys
so the agreement is exact. Randomised primitives (spreading activation,
latent themes) agree because both ports take the same explicit seed into
the same gated generator (SplitMix64). The query-precision helpers
(`queryPrecision`, `hasDistinctiveTokens`, `containmentSatisfied`) and
the reduction-pipeline functions (`reductionScore`, `reduce`) also agree
bit-for-bit — they are pure ASCII-folded text math with no RNG or clock.

---

## § 10 Self-Report Telemetry

NeuronKit emits substrate self-report metrics via IntellectusLib at three
operation boundaries. Monitoring is off by default; the off-path cost is
a single atomic load plus branch (~1 ns), never evaluates the payload
autoclosure, and never allocates. Telemetry is strictly additive:
algorithm results are bit-identical regardless of monitoring state. This
is enforced by the §5 conformance gate in both the Swift and Rust test
suites.

### 10.1 Metric namespace and tag contract

All NeuronKit metrics use the prefix `neuronkit.*`. The `estate` tag
is emitted on recall surfaces where an `EstateHandle` is in scope.

| Metric name | Value | Tags | Emit site |
|---|---|---|---|
| `neuronkit.recall.latency_ms` | elapsed wall-clock milliseconds | `estate` (UUID string) | After rerank in `hybridRecall()` |
| `neuronkit.recall.candidate_count` | drawer count before rerank | `estate` (UUID string) | After rerank in `hybridRecall()` |
| `neuronkit.recall.result_count` | drawer count after rerank | `estate` (UUID string) | After rerank in `hybridRecall()` |
| `neuronkit.dream.cycle` | 1.0 (start) or proposal count (complete) | `status` ("start"/"complete"), `cycle` (N), `drawers_touched` (complete only), `proposals` (complete only) | Start and completion of `DreamingDaemon.runCycle()` |
| `neuronkit.tournament.bt_update` | 1.0 | `competitor_count` (string) | End of `bradleyTerry(outcomes:)`, after sort |
| `neuronkit.tournament.competitor_count` | competitor count | none | End of `bradleyTerry(outcomes:)`, after sort |

### 10.2 Conformance gate

Conformance requirement: for every test vector, algorithm outputs
(reranked drawer order, BradleyTerry strength scores, dreaming cycle
reports) are bit-identical with monitoring ON and monitoring OFF. The
Swift `@Suite("§5", .serialized)` and Rust `§5` tests enforce this.

### 10.3 Dependency

IntellectusLib is the zero-dependency telemetry leaf. NeuronKit declares
it as an in-repo dependency per the package-dependency rule,
for self-report coverage.
Layering is safe: IntellectusLib depends only on the Swift/Rust standard
library and does not depend on NeuronKit or any substrate kit.

---

## § 11 — Estate topology snapshot

### Overview

`NeuronKit.graphTopology(drawers:tunnels:facts:)` (Swift) /
`neuron_kit::topology_analysis::graph_topology(drawers, tunnels, facts)`
(Rust) computes the estate topology snapshot behind the aria-mcp
`GET /api/graph`: Louvain community assignment and normalised eigenvalue
centrality per live drawer, tunnel and KGFact-bond edges, dissolution
metadata, and per-community summaries for constellation labelling.

Topology V3 then projects that structural result through
`TopologyProjector.project` / `topology_projection::project`. It overlap-matches
current communities and folds against the previous persisted snapshot, keeps
matched coordinates unchanged, partitions large communities with deterministic
farthest-seed multi-source graph distances, places new structure near connected
existing structure, and emits aggregate bridges plus balanced representatives.
Lattice/FDC edges are excluded from every key, fold, bridge, and coordinate
decision. FDC is summarized afterward as dominant code and purity metadata.

The shared golden key rule is FNV-1a 64 over sorted member ids joined by byte
`0x01`, prefixed with `c-` or `f-`. Previous overlap wins over a new hash. This
keeps raw Louvain-label renumbering from rotating the user's mental map and is
implemented identically in Swift and Rust.

The function is pure over plain descriptors — no store access, no clocks
(I-17/I-18). Analysis is NeuronKit's lane; GeniusLocusKit is composition.
The orchestration is arranged so the caller (aria-mcp, which depends on
both kits) performs the estate reads and hands descriptors here, which
keeps the NeuronKit/GeniusLocusKit package dependency acyclic.

### Caller responsibilities

The caller resolves all estate I/O before calling:

- Raw reads: drawers, tunnels, KGFacts — tombstoned rows included where the
  store surfaces them.
- The dead signal per drawer: Swift checks the state axis
  (`state == .tombstoned`) OR a round-tripping `tombstonedAt` stamp; Rust
  checks `tombstoned_at` (the Rust store round-trips its stamp).
- The tombstone instant: Swift falls back to the sealed audit trail's
  `tombstone` event (HLC physical milliseconds) when the stamp does not
  round-trip — one audit read per dead row. A dead drawer whose instant
  cannot be resolved still carries `tombstoned: true` with a nil instant.

### The weighted graph

Unlike the Keystones/Constellation lenses (unit-weight per § 7.1), topology
assembles a WEIGHTED graph over SubstrateML's existing weighted adjacency:

| Edge class | Weight | Meaning |
|---|---|---|
| tunnel | 1.0 | explicit drawer-to-drawer structural link |
| kgFact | 0.3 | derived shared-subject bond — weaker evidence class |
| lattice | 0.2 | derived classification bond — drawers sharing a non-empty `udcCode` |

Evidence hierarchy: tunnel (explicit) > kgFact (derived semantic) > lattice
(derived classification). Lattice bonding groups live drawers sharing a
non-empty `udcCode` in a star topology: hub = earliest `filedAt`, ties broken
by `id` ascending (deterministic across permuted input orders). VectorKit kNN
semantic bonding over `udcCode` remains a follow-on.

KGFact bonding is a syntactic proxy: drawers that filed facts with identical
`subject` strings are weakly connected. Full semantic resolution
(subject → drawers via VectorKit kNN) remains a follow-on.

Nothing new descends to the substrate layer: SubstrateML's
`CommunityDetection.detect` and `EigenvalueCentrality.compute` already take
weighted adjacency in both legs; the lenses simply fill 1.0. No cookbook
impact.

### Adjacency split — centrality vs. community detection

`EigenvalueCentrality` is computed on the **tunnel + kgFact** adjacency only.
Lattice edges are appended to the adjacency **after** centrality and used only
by `CommunityDetection`. Rationale: centrality means explicit structural
prominence; a lattice star hub would otherwise become the estate's top keystone
by topology artifact alone. Lattice bonds are derived classification and must
not mint keystones.

### Live-only math, dissolution sentinels

The math universe is LIVE entities only — adjacency, Louvain, centrality,
and community aggregation all derive from live drawers. Dead entities ship
on the wire but cannot shift community structure:

- Dead drawer → node with `communityId: -1` (no-community sentinel),
  `centrality: 0.0`, real `createdTs`, `tombstonedTs` when resolved.
- Dead tunnel → edge with `tombstonedTs` set, excluded from adjacency.
- kgFact edges derive from live facts only; `createdTs`/`tombstonedTs`
  always nil (a derived bond has no single ingest instant).
- Lattice edges derive from live drawers only; `createdTs`/`tombstonedTs`
  always nil — a derived classification bond carries no single ingest instant
  and relies on the live/dead partition applied before grouping.

### Algorithms

- Louvain: `SubstrateML.CommunityDetection.detectFull(adjacency:maxLevels:maxPasses:resolution:)`
  — FULL Louvain (phase 1 + phase-2 aggregation), with:
  - `maxPasses = 20` (`topologyMaxPasses` / `TOPOLOGY_MAX_PASSES` — passes
    per level; higher than the lens default 10 because the dashboard graph
    is read less often and benefits from extra convergence),
  - `maxLevels = 10` (`topologyMaxLevels` / `TOPOLOGY_MAX_LEVELS` —
    aggregation levels; typical convergence 2–4),
  - `resolution = 0.05` (`topologyResolution` / `TOPOLOGY_RESOLUTION` —
    Reichardt–Bornholdt γ). Phase-1-only Louvain locked tunnel-bonded
    pairs out of their lattice stars (leaving a 1.0 pair bond for a 0.2
    lattice bond is strictly negative gain — a large lattice star
    fragments into pair-communities). γ scales only the
    degree-penalty term: a supernode with degree k and edge weight w into
    a target community merges whenever γ < w/k, scale-invariantly. A
    tunnel-bonded pair (k = 2.2) with one lattice bond (w = 0.2) absorbs
    below 0.0909; 0.05 sits at ~55 % of that bound, while large
    continents joined by weak bridges (threshold ≈ w_bridge/m) stay
    separate. Small dense fixtures merge aggressively at this γ —
    bridged triangles become ONE community; test fixtures that must stay
    split use disjoint components.
- Centrality: `SubstrateML.EigenvalueCentrality.compute` with lens-default
  iterations/tolerance, normalised to [0, 1] against the estate maximum.
- Telemetry tags are empty/zero (no-op emit), same convention as the lenses.

### Community summaries

Live drawers group by Louvain label; each community reports
`{id, size, dominantUdcCode}` where `dominantUdcCode` is the most frequent
non-empty member `udcCode`, frequency ties broken lexicographically
ascending (byte-stable snapshots), `""` when every member code is empty.
Sorted by size descending, then id ascending.

### Timestamps

All wire timestamps are ISO-8601 UTC TEXT. `createdTs` = `filedAt` (ingest
clock — the alive(t) playback boundary). `lastActiveTs` = `eventTime`
(recency signal). The Rust leg formats epoch seconds via
`topology_analysis::epoch_to_iso8601` (Hinnant civil-from-days, no chrono;
pre-1970 via Euclidean division; known-vector tested including 1900/2000
century behavior).

### Performance guard

Swift logs at INFO when the two SubstrateML calls exceed 500ms:
`graphTopology took N.NNs for K nodes — consider the scheduled-snapshot
path`. Compute-on-read at ~2.2k nodes measures ~0.5–0.9s end-to-end
(including estate reads); the scheduled-snapshot architecture (autonomic
governor pass → ObserverSink store → moot-mgr reads materialized values)
is the designated successor and is specified in its own mission.

---

## § 12 — Recall-driven dreaming (v2)

> **Status: ratified target (the recall-driven dreaming contract), Phase 0.** This section is the
> normative form of the recall-driven dreaming contract. It supersedes the v1 dreaming model (the blind
> `tickIntervalMs` cadence in § 9 C-1 and the co-location candidate model) on
> Phase-3 landing. Until then the shipped behavior is v1; this section is the
> contract the implementation builds to. The contrastive-confidence and EWC++
> *math* (§ 12.5) is unchanged from v1 — only the candidate **source**,
> **trigger**, and **schedule** change.

### § 12.1 — Two association channels

Tunnels enter the estate by two channels that meet only in the tunnel store,
distinguished by `tunnels.provenanceBitmap`:

- **Declared** — palace `tunnels.json` and vault wikilinks, imported directly
  via VaultKit PalaceBridge. Not inferred. Provenance = declared.
- **Emergent** — proposed by dreaming from recall evidence. Provenance =
  dreamed.

Dreaming reads declared tunnels only as `existingTunnelKeys` (suppression
input); it never re-proposes or (per § 12.8) retires them.

### § 12.2 — The dreaming queue

Dreaming is recall-sourced. The recall verbs, after writing `recall_trace`,
enqueue a **dreaming item** onto the **one per-estate queue** under
`stream_id="dreaming"` (one queue per estate, many streams by type; backend by
the estate's storage class — an encrypted SQLite queue DB for SQLite estates,
Postgres for Postgres, InMemory for ephemeral; never a plaintext maildir for a
private estate — see QUEUEKIT_SPEC § 3 and the recall-driven dreaming contract Decision 7). The item is the
HLC-stamped set of drawer ids **used** in that recall (the reward targets);
items with fewer than two used drawers are not enqueued (no pair possible).
Enqueue is batched (one commit per batch). "Dreaming fires" = a **stream-scoped
drain** of the `"dreaming"` stream; `pending_count(stream:"dreaming") == 0` is
the cheap trigger (empty ⇒ no work, no scan). `recall_trace` stays the durable
record consumed by the longer-window REM cycles (§ 12.6 THETA) and crash
recovery — it is not the live ALPHA feed (the queue item carries the per-event
co-recall grouping directly).

### § 12.3 — Co-recall pairing (candidate generation)

A candidate pair `(a, b)` is generated when `a` and `b` appear in the **same
drained recall item** (recalled together), `a < b` by id (canonical order).
There is **no co-location/room enumeration** — the v1 O(room²) all-pairs
builder is removed. Candidates may span rooms (cross-room association is
intended). A drain unions the items in its claim window and emits the distinct
co-recall pairs over that union.

### § 12.4 — `attempts` = co-recall count

`minAttempts` (3) gates on how many distinct recall events have paired
`(a, b)` — the **co-recall count**, maintained in a persistent per-pair store
updated per drained window. (v1 used room size; v2 uses co-recall frequency, a
strictly stronger "seen together ≥ N times" signal.)

### § 12.5 — Decide math (unchanged from v1)

Per candidate, in canonical order: contrastive confidence, then EWC++ blend,
then gate. Reward is per-target (`used → 1`, else `0`), meaned over the pair's
two endpoints.

- `contrastiveConfidence(mean) = exp(mean/τ) / (exp(mean/τ) + exp(baseline/τ))`
  with `τ = temperature = 0.2`, `baseline = minSuccessRate = 0.6`. Empty
  evidence ⇒ 0. Computed in f64, returned as f32.
- `effective = max(raw, consolidated[key] · ewcRetention)`, `ewcRetention = 0.9`.
- emit iff `effective ≥ minConfidence (0.7)` AND `coRecallCount ≥ minAttempts (3)`
  AND not an existing tunnel / prior proposal / this-cycle duplicate.

### § 12.6 — The REM schedule

Dreaming is one engine parameterized by `(window, decay, breadth, prune,
retire)` at four cadences:

| Cycle | Cadence (default) | Job | Scope | Tunnel writes |
|---|---|---|---|---|
| **REM-ALPHA** | 30 s | drain the queue → form fresh co-recall tunnels | just-recalled set | propose |
| **REM-THETA** | daily | consolidate cross-event links; EWC decay; bump `attempts` | last day of `recall_trace` | propose + adjust |
| **REM-BETA** | weekly | prune/GC the consolidated + co-recall-counts stores (memory-only) | internal stores | none |
| **REM-OMEGA** | biweekly | retire dreamed tunnels no longer reinforced by recall | shipped dreamed tunnels | retire |

All four are bounded by recall activity (recalled-set²), never by estate shape.

### § 12.7 — Trigger modes and the forked dreamer

The trigger mode selects **who drives** dreaming, decoupled from § 12.6:

- **`.timer`** — a resident scheduler (the governor) ticks and runs due cycles
  in-process; no fork. Default for `serve --http`.
- **`.event`** — no loop; dreaming runs in a short-lived detached
  `mootx01 dream` process spawned by stdio lifecycle hooks. Default for stdio.
- **`.hybrid`** — resident loop plus event pokes (low-latency ALPHA on a large
  recall). Optional.

`mootx01 dream` (sibling of `mootx01 drain`): detached, takes the dreaming
drain-lease (heartbeat-TTL; at most one dreamer per estate), computes due-ness
itself (ALPHA if queue non-empty; THETA/BETA/OMEGA if their persisted last-run
is overdue), runs the due cycles, exits. Stdio structural triggers — fork only
if the lease is free and work exists: **post-recall**, **on-exit**,
**on-startup/first-query**.

### § 12.8 — OMEGA provenance rule

OMEGA's retire predicate is `provenance = dreamed AND not reinforced by recall`.
It MUST NOT retire a declared tunnel (§ 12.1). Retirement is reversible: a
retired tunnel is flipped via an `operationalBitmap` bit (no Bool stored field)
and audited, so a later co-recall re-forms it. No hard delete.

### § 12.9 — Bulk-import intersection

A massive import (palace corpus, vault) has ≈ zero intersection with
recall-driven dreaming: import feeds the encode pipeline, writes no
`recall_trace`, enqueues no dreaming items, so all four REM cycles stay idle.
Imported content is dream-eligible only once it is later co-recalled. Declared
tunnels (§ 12.1) arrive at import time through the declared channel, not
dreaming.

### § 12.10 — Conformance vectors (v2)

Canonical input → output, asserted bit-identically in both ports. Float values
are the f32 narrowing of the f64 computation.

**CV-D1 — contrastive confidence** (`τ = 0.2`, `baseline = 0.6`):

| endpoints rewarded | mean | confidence (f32) |
|---|---|---|
| neither | 0.0 | `0.0474258736` |
| one | 0.5 | `0.3775406778` |
| both | 1.0 | `0.8807970881` |

**CV-D2 — EWC++ blend** (`effective = max(raw, consolidated · 0.9)`):

| raw | consolidated | retained | effective |
|---|---|---|---|
| 0.8807971 | 0.0 | 0.0 | 0.8807971 |
| 0.0474259 | 0.95 | 0.855 | 0.855 |
| 0.3775407 | 0.90 | 0.810 | 0.810 |

**CV-D3 — co-recall pairing.** A recall item with used set `{A, B, C}`
(`A < B < C`) generates exactly the pairs `(A,B), (A,C), (B,C)` in canonical
order; a used set of size < 2 generates none and is not enqueued.

**CV-D4 — gate + `attempts` (the v2 contract).** Pair `(A,B)`, both endpoints
rewarded (raw = 0.8807971 ≥ 0.7, confidence PASS), no prior consolidation:

| co-recall # | coRecallCount (attempts) | emits? | why |
|---|---|---|---|
| 1 | 1 | no | attempts < 3 |
| 2 | 2 | no | attempts < 3 |
| 3 | 3 | **yes** | confidence ≥ 0.7 AND attempts ≥ 3 |

**CV-D5 — never-emittable.** A pair whose endpoints are not both rewarded has
confidence ≤ 0.3775406778 < 0.7 and never emits regardless of `attempts`
(the basis for the recall-gated candidate reduction).

---

*End of NeuronKit Specification.*

## Changelog

### 1.4.1 -- 2026-06-25
Corrected § 12.2 to the recall-driven dreaming contract Decision 7: the dreaming work is a
`stream_id="dreaming"` stream in the **one per-estate queue** (backend by
estate storage class — encrypted SQLite queue DB / Postgres / InMemory, never a
plaintext maildir for a private estate), drained by a **stream-scoped drain** —
not a separate dreaming maildir. `recall_trace` stays the durable record (the
queue item carries the per-event co-recall grouping). Doc only.

### 1.4.0 -- 2026-06-25
Recall-driven dreaming v2 (the recall-driven dreaming contract, Phase 0 — spec + conformance vectors only;
no code yet). Added § 12 as the normative form of the recall-driven dreaming contract: dreaming is sourced
from a recall-driven QueueKit stream (co-recall pairing, § 12.2–12.3),
`attempts` becomes the co-recall count (§ 12.4), the decide math is unchanged
(§ 12.5), and the daemon runs the four-cycle REM schedule (REM-ALPHA/THETA/
BETA/OMEGA, § 12.6) under redefined trigger modes with a forked `mootx01 dream`
process for stdio (§ 12.7). OMEGA retires only dreamed, recall-unreinforced
tunnels and never declared ones (§ 12.8); bulk import has ≈ zero dreaming
intersection (§ 12.9). § 12.10 fixes the canonical conformance vectors
(CV-D1..D5). § 12 supersedes the v1 blind-timer / co-location model (§ 9 C-1)
on Phase-3 landing; until then v1 is the shipped behavior.

### 1.3.0 -- 2026-06-25
Rust Brain-algorithm parity. The Rust dreaming daemon now runs the
Thompson-Sampling bandit (observe reward + re-select trigger mode each cycle,
§ 3.4) and persists it via the policy store's `load_bandit`/`save_bandit` seam;
the Rust maintenance daemon now owns the audit-check cadence (independent of the
scan tick, § 3.5), matching the Swift `lastAuditCheckAt` model. Both ports now
run identical dreaming/maintenance algorithms with the same persisted state shape
(this makes the 1.2.0 "Both ports … bandit" clause fully true on the Rust side).

### 1.2.0 -- 2026-06-25
F6 / the daemon-state persistence contract — daemon state is substrate-resident in the manifest. The dreaming
and maintenance policy-store seams gain `loadDaemonState`/`saveDaemonState`
(default no-op), and production wires manifest-backed stores
(`EstateManifestDreamingPolicyStore` / `EstateManifestMaintenancePolicyStore`)
that persist policy, bandit (dreaming), and the daemons' idempotency/cycle memory
(proposed keys, consolidated EWC++ confidence, cycle count, timer baselines) to
the estate manifest THROUGH the public substrate KV surface (Estate.meta/setMeta
// DrawerStore::get_meta/set_meta). The governor loads state on start and saves
after each fired cycle, so a restart resumes prior state instead of re-proposing,
re-consolidating, or repeating suppressed maintenance proposals — resolving the
B-1 "no manifest accessor" blocker. Both ports; in-memory stores (tests) are
unaffected by the default no-op seams. See NEURONKIT_INTERFACE.md 1.3.0.

### 1.1.0 -- 2026-06-19
Added: `NeuronKit.hmmFeatureExtractor` is now the production
`DistillationPipeline.FeatureExtractor`, replacing the capitalization-heuristic
stub as the default in `distillCluster`. `CognitionKit.Consolidate` routes
through `hmmFeatureExtractor` via the one-door pattern. Both ports (Swift
`HMMFeatureExtractor.swift` / Rust `hmm_feature_extractor.rs`) conform to
byte-identical extraction rules: ENT/noun, REL/verb, NUM/all-digit, TMP/4-digit
year. See NEURONKIT_INTERFACE.md § Distillation lens.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

### 1.5.0 -- 2026-06-26
the recall-driven dreaming contract v2 reconciliation (T14). § 9 C-1 updated from the v1 blind-timer model
(`tickIntervalMs` fires a cycle once elapsed) to the v2 REM dispatch table model:
four cadences (ALPHA 30 s / THETA 24 h / BETA 7 d / OMEGA 14 d), ALPHA gated on
`pending_count(stream:"dreaming") > 0`, THETA/BETA/OMEGA gated on persisted
last-run timestamps; driven by resident governor (`.timer`) or forked `mootx01
dream` (`.event`). § 12 (ratified target, Phase 0) is the normative v2 contract
and is unchanged; § 9 C-1 previously contradicted it. The v2 build (T1–T14) is
shipped; the recall-driven dreaming contract status updated to decided.

### 1.7.0 -- 2026-07-16
Audit pass: added behavioral contracts for surfaces shipped since 1.6.0 that
were absent from the SPEC. Added § 7.6 (diffusion node-layer lenses — NodeMotion
fold and NodeAnomaly classify); updated C-18 to include
`nodeMotion`/`nodeAnomaly` in the both-legs lens taxonomy (with explicit note
that the GLK-bound `run`/`anomaly` entry points are Swift-only and outside C-18);
updated C-Det to cover the diffusion-lens pure folds and the new reduction-pipeline
functions (`queryPrecision`, `hasDistinctiveTokens`, `containmentSatisfied`,
`reductionScore`, `reduce`). Doc-only; no algorithm or conformance change.

### 1.6.0 -- 2026-07-09
AUDIT-ALERT-RESTORE (Bob's option-1 ruling). Added § 9 C-4 and C-12 — both
were referenced pervasively across GLK/NeuronKit code and test comments
("NEURONKIT_SPEC §3.5 / invariant C-4/C-12") but were never actually
defined in this document's conformance list; this entry closes that gap
while updating the invariant to the new behavior. secfix 5101e112 made
`UnifiedAuditLog` ingress rejection silent (log-only), which made the
audit-chain integrity monitor's alerting structurally unreachable — a
rejected entry never reaches the chain walk, so the walk always reported
vacuously valid and the daemon never proposed. C-4 now defines two
independent alert conditions (broken-chain walk, and ingress rejection
observed via the new `rejectedEntryCount`/`rejected_count()` counter);
C-12 documents the ingress defence's unconditional-rejection guarantee
and its counted observability. No change to the rejection defence itself
— rejected entries are still never re-admitted; this is observability
only.
