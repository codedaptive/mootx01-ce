---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-06-01
version: v0.85
supersedes: NEURONKIT_SPEC_v0.8.md
package: NeuronKit
kind: Kit
relates_to:
  - NEURONKIT_INTERFACE_v0.85.md  (the API surface this spec contracts)
  - GENIUSLOCUSKIT_SPEC_v0.8.md  (the estate verb surface every substrate touch flows through)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (the Brain layer, recall fusion, branch COW, autonomic daemons)
  - SUBSTRATEML_SPEC_v0.8.md  (the gated math primitives the reasoning lenses surface — centrality, communities, random-walk, NMF, decay, action-outcome matrix, Bradley-Terry)
  - EIDETICLIB_SPEC_v0.8.md  (the deterministic text-to-anchor lookup NeuronKit composes)
  - ENGRAMLIB_SPEC_v0.8.md  (the Hamming distance primitive MMR ranking uses)
  - LOCUSKIT_SPEC_v0.8.md  (the read-only Drawer value type and adjective-state the reasoning surface shapes)
  - COGNITIONKIT_SPEC_v0.1.md  (the not-yet-built consumer that sequences NeuronKit lenses into named recipes)
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

> **Supersedes NEURONKIT_SPEC_v0.8.** v0.85 carries forward every v0.8
> contract unchanged (the autonomic daemons, the reasoning functions,
> B-1…B-7, I-1/I-2/I-3/I-15/I-16, the error model, C-1/C-8/C-9/C-13/C-15/
> C-Det) and **promotes the reasoning-lens surface from "documented
> Rust-narrower gap" to first-class settled design.** The v0.8 framing
> treated the lens cluster (keystones, constellation, spreading
> activation, theme weather, latent themes, bias, learned preference,
> anticipation) as a port asymmetry to be reconciled away. It is not an
> asymmetry — it is the design. The lenses are now specified as a
> deliberate taxonomy with a shared construction archetype
> (§ 8, "surface-then-sequence"), and both ports must realise the full
> lens surface (I-2 design law: every surface has both legs). The Swift
> leg, currently narrower, is brought up to this spec Swift-first.

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
recipes; it is not yet built (`COGNITIONKIT_SPEC_v0.1.md`). NeuronKit
itself ships no user-facing recipes.

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

- API signatures — those live in `NEURONKIT_INTERFACE_v0.85.md`.
- The estate verb surface, branch COW mechanics, or the Brain-layer
  adapter that binds the daemon seams to live verbs — those are
  GeniusLocusKit's (`GENIUSLOCUSKIT_SPEC_v0.8.md`).
- **The gated math primitives the lenses surface — eigenvalue
  centrality, Louvain community detection, random-walk-with-restart,
  NMF, exponential decay, the action-outcome matrix + Wilson bound, and
  the Bradley-Terry MLE — those are SubstrateML's / GeniusLocusKit's**
  (`SUBSTRATEML_SPEC_v0.8.md`, GLK matrix tier). NeuronKit shapes their
  inputs and outputs; it does not own the math.
- The linguistic pipeline (tokenize, normalize, stem, gazetteer-match,
  classify, resolve) — that is EideticLib's (`EIDETICLIB_SPEC_v0.8.md`).
- The Hamming distance primitive — that is EngramLib's
  (`ENGRAMLIB_SPEC_v0.8.md`).
- Storage, SQL, and the `Drawer` schema — those are LocusKit's
  (`LOCUSKIT_SPEC_v0.8.md`).
- User-facing recipes and the estate-side sequencing that derives each
  lens's input from a live estate — those are CognitionKit's
  (`COGNITIONKIT_SPEC_v0.1.md`).

## § 3 — Position in the kit family

```
EideticLib   EngramLib   SubstrateML (gated math)   LocusKit (read-only value types)
     ▲            ▲              ▲                          ▲
     │            │              │                          │
   GeniusLocusKit (estate verb surface; branch COW; Brain layer; matrix tier)
     ▲
   NeuronKit   ← composes all of the above; daemons + reasoning functions + lenses
     ▲
   CognitionKit   (named recipes — NOT BUILT)
```

**Depends on:** EideticLib (text-to-anchor `lookup`), EngramLib
(Hamming `distance` for MMR), SubstrateML (the gated reasoning-lens math
primitives — centrality, communities, random-walk, NMF, decay,
action-outcome matrix, Bradley-Terry), GeniusLocusKit (the
`EstateHandle`, the nine estate verbs, branch COW verbs,
`ExternalCorpus`, `AuditChainVerifier`, and the matrix-tier `MatrixNMF`),
and LocusKit (the read-only `Drawer` value type and its read-only
adjective-state accessors — the B-1 exception, I-2).

**Consumed by:** CognitionKit (not yet built). At v0.85 there are **zero
external in-tree consumers** of NeuronKit; the recipe layer that would
sequence the lenses has not shipped. The lenses are nonetheless
first-class design: they exist to be sequenced, and the surface is
contracted now so the Swift and Rust ports converge before the consumer
arrives.

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

## § 6 — Error model (conceptual)

NeuronKit's reasoning surface is mostly total — edge inputs (empty
candidate lists, `k <= 0`, empty corpora, empty lens inputs) return
empty / neutral results rather than throwing. The one family that raises
typed errors is the Bradley-Terry fitter and its preference-lens caller,
which own NeuronKit's `MOOTx01Error` enum per the fleet convention (one
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

**Constellation — emergent communities.** Surfaces SubstrateML's Louvain
`CommunityDetection` (phase 1) over the same undirected drawer-id graph
(weight 1; absent-endpoint edges ignored). Where Keystones finds the
load-bearing nodes, Constellation finds the *clusters* — emergent themes
the user never named. Result: `Constellation { communities: [[id]] }`.

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

### § 7.5 — Surprise lenses (what doesn't fit)

**Drift — distributional shift between two windows.** Surfaces
SubstrateML's `InformationTheory`. Given two distributions over the same
aligned support (same length — the caller normalizes and aligns them),
reports the Jensen-Shannon divergence (symmetric, bounded; 0 = identical,
growing with separation — the primary drift signal) and the KL divergence
D(p‖q) (asymmetric — how surprising the second window is under the
first). "Your interests shifted in April." Result:
`DriftScore { jensenShannon, klDivergence }`.

**Anomaly scan — z-score outliers.** Surfaces SubstrateML's
`AnomalyDetection`. Given a value series, flags every entry whose
z-score magnitude meets the threshold; the sign carries direction
(negative = below the mean — the "doesn't fit" signal the contradiction
lens uses). Mean and standard deviation are computed over the whole
series; a series with (near) zero spread has no outliers (guarded — no
divide-by-zero z-score), and an empty series is total. Result:
`[Anomaly { index, zScore }]`.

### § 7.6 — Associative lens (partial-cue recall)

**Partial-cue recall — per-block fingerprint matching.** Surfaces
SubstrateML's `PartialStateRecall`. The 256-bit drawer fingerprint is
four independent 64-bit similarity blocks — structure (0),
concept/lattice (1), lineage-temporal (2), channel/source (3). Querying
a block subset instead of the whole fingerprint gives "memories that
FEEL structurally like this" vs "memories ABOUT this concept" vs
"memories FROM this period" — different recalls from one cue. The
match/differ split scores "similar in X, different in Y": top `k` rows
by high similarity to the anchor over the match blocks AND high
difference over the differ blocks. The caller excludes the anchor row
if present. Result: ranked `(row, score)` matches.

### § 7.7 — Federated lens (privacy-preserving overlap)

**Mind overlap — DP summaries across estates.** Surfaces SubstrateML's
DP-OR-reduce. Each estate reduces its fingerprint set to ONE
differentially-private aggregate (deterministic for a fixed seed, so
two estates seeded alike produce comparable noise); the two aggregates
are compared as 1 − normalized Hamming over the
structure/concept/channel blocks (192 bits; 1.0 = convergent minds,
→ 0 as they diverge). Neither side's individual memories are ever
touched by the comparison — only the DP summaries, which is exactly
what would cross a federation boundary. Block 2 (lineage-temporal) is
DELIBERATELY excluded: it encodes per-row identity, so it differs even
between two estates holding the very same memory — comparing it across
estates is both meaningless and nondeterministic.

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

**C-1 (dreaming cadence):** the dreaming daemon fires a cycle once its
configured `tickIntervalMs` has elapsed since the last tick (the spec's
±10% jitter tolerance is satisfied exactly: the scheduler fires as soon
as the full interval elapses). The first `pump` always fires.

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

**C-13 (zero silent migration loss):** the migration benchmark's
`notFoundInBranch` is empty for a conforming migration; a non-empty set
disqualifies the branch from tournament ranking (the gate is applied
BEFORE scoring, and disqualified branches are retained with a typed
reason rather than dropped). The benchmark's only substrate call is the
read-only `BranchHandle.recall(_:)`.

**C-15 (reward source):** the dreaming daemon derives reward from
`RecallTraceItem.used` via the default `RecallTraceRewardSource`
(used → 1.0, unused → 0.0). Ignoring this source is non-conformant. The
two-source taxonomy (implicit recall-trace + explicit `DiaryEntry.reward`)
is preserved at the type level; the explicit source is a documented seam
the substrate does not yet populate.

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
learned preference, anticipation — with matching type and member names
(the § 6 fitter-error name being the lone sanctioned exception) and
bit-for-bit-equal numeric results on shared vectors. A surface present on
one leg and absent on the other is non-conformant; this is the v0.85
design law applied to NeuronKit (I-2 / "everything has both legs").

**C-Det (cross-port determinism):** for every shared test vector, the
Swift and Rust ports agree bit-for-bit on the reasoning engines AND the
lenses they both implement — lattice-anchor inference, hybrid-recall
rerank / shingle similarity / paging, context synthesis, the
Bradley-Terry fit (strengths AND confidence-interval bounds), and every
§ 7 lens (centrality scores, community partitions, activation
frequencies, momentum, NMF loadings + reconstruction error, bias
differences, preference strengths + intervals, Wilson-ranked
predictions). Tie-breaks resolve on stable keys so the agreement is
exact. Randomised primitives (spreading activation, latent themes) agree
because both ports take the same explicit seed into the same gated
generator (SplitMix64).

---

*End of NeuronKit Specification v0.85.*
