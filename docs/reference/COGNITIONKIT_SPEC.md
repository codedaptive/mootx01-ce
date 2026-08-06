---
title: CognitionKit Specification
version: 1.8.0
status: active
date: 2026-08-06
description: "Behavioral specification for CognitionKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - COGNITIONKIT_INTERFACE.md  (the API surface this spec contracts)
  - NEURONKIT_SPEC.md  (the reasoning surface every recipe sequences — daemons, reasoning functions, the lens taxonomy)
  - GENIUSLOCUSKIT_SPEC.md  (the estate verb surface and branch COW verbs recipes dispatch through)
  - GENIUSLOCUS_ARCHITECTURE_SPEC.md  (the substrate contract; the active/subconscious control path)
purpose: |
  CognitionKit is the conscious mind of the MOOTx01 substrate: the
  behaviour-recipe layer that sequences NeuronKit reasoning and
  GeniusLocusKit estate verbs into named, reusable behaviours. It
  contains no algorithms and owns no substrate state. A recipe is a
  deliberate, intent-invoked behaviour with a declared capability set; it
  reads through the estate handle, reasons through NeuronKit (for lens
  recipes) or delegates to SubstrateML (for analytics recipes), and
  returns a typed result. The recipe surface is two foundational
  behaviours (grounded synthesis, migration benchmark), a taxonomy of
  twenty reasoning-lens recipes — each a deliberate read that sequences
  one gated NeuronKit reasoning surface over the estate — and three
  analytics recipes (association_rules, apriori_rules, formal_concepts)
  that mine structural patterns by delegating to SubstrateML engines, the
  exploratory-recall recipe (recall_exploratory) that walks a wing's
  tunnel graph with restart from a seed drawer, and three
  distillation-family recipes (consolidate, distilled_recall, recollect)
  that compact working memory, search the distilled tier, and expand
  factoids back to their source memories. The companion INTERFACE
  document carries the signatures.
---

# CognitionKit Specification

> This specification settles the recipe surface as first-class design. The
> twenty reasoning-lens recipes (§ 4) are specified here as a deliberate
> taxonomy with a shared construction archetype (§ 5, "read-sequence-
> shape"), parallel to the NeuronKit lens taxonomy they consume
> (`NEURONKIT_SPEC.md` § 7). Both the Swift and Rust versions realise the
> full recipe surface (C-7); the catalog parity anchor (§ 8) holds across
> versions byte-for-byte.

## § 1 — What this package is

CognitionKit is the conscious, deliberate layer of the MOOTx01 substrate.
It sits above NeuronKit and assembles NeuronKit reasoning and
GeniusLocusKit estate verbs into named, reusable **recipes** — behaviours
a caller invokes by intent.

It offers five recipe families:

- **Foundational recipes (§ 3).** The two deliberate substrate
  behaviours that gate on capability and explicit confirmation:
  **grounded synthesis** (hybrid-recall a query, synthesize the recalled
  drawers into one grounded context document) and **migration benchmark**
  (derive one branch per migration plan, benchmark each against the origin
  corpus under a zero-silent-loss gate, rank survivors, gated-promote the
  winner).

- **Reasoning-lens recipes (§ 4).** A taxonomy of twenty deliberate
  reads, each of which shapes the estate into the input of one gated
  NeuronKit reasoning surface, calls that surface, and returns the
  reasoning result. The structural lenses (keystones, constellation,
  free association), the topic lenses (latent themes, theme weather,
  complexity), the preference lens (bias), the surprise lenses (drift,
  cohesion, lens_contradiction, node_motion), the grounding lens (trust),
  the associative lens (feels-like), the prediction lenses (anticipate,
  tunnel successor), the federated lenses (mind overlap, estate
  divergence), and the temporal lenses (moment, rhythm, precedence).

- **Analytics recipes (§ 4.3).** Three knowledge-discovery recipes —
  `association_rules`, `apriori_rules`, and `formal_concepts` — that mine
  structural patterns across a recalled drawer set or the estate's audit
  log by delegating to SubstrateML engines. Each declares a capability
  (`associationRuleMining` or `formalConceptAnalysis`) that gates
  execution before any estate touch.

- **Exploratory-recall recipe (§ 4.4).** One walk-based recall recipe —
  `recall_exploratory` — that runs a random walk with restart from a seed
  drawer over a wing's tunnel graph, returning the most-visited drawers
  ranked by visit frequency. Delegates entirely to
  `SubstrateML.RandomWalks.walkWithRestart`; declares the
  `exploratoryRecall` capability.

- **Distillation-family recipes (§ 4.5).** Three recipes that operate on
  the distilled memory tier: `consolidate` (sweep active items and produce
  factoid drawers), `distilled_recall` (Hamming NN search over the
  distilled tier, returning factoid prose without embedding inference), and
  `recollect` (fan out from a factoid to its source memories via
  `_distilled_from` tunnels). All three have empty `requiredCapabilities`
  and are read-only except Consolidate, which writes factoid drawers.

- **The catalog (§ 8).** An enumerable registry of the recipes that have
  graduated to a product surface, with each recipe's descriptor (name,
  version, description, required capabilities). The catalog is the
  conscious mind's self-knowledge.

CognitionKit is consumed by product surfaces and the agent tool layer
(`moot_list_recipes` enumerates the catalog; an intent router invokes a
recipe by name). It is the first in-tree consumer of NeuronKit's reasoning
surface.

This package is a **Kit**: it composes upstream kits and manages the
lifecycle of a recipe invocation. Its recipes are pure sequencers — they
hold no state between calls (B-4); all state between a recipe's steps
lives in local values or in the NeuronKit/GeniusLocusKit nouns it is
handed (a `BranchHandle`, a `TournamentReport`).

## § 2 — Scope

This specification defines:

- The active/subconscious **placement gate** (§ 1.1 below) that decides
  whether a behaviour lives in CognitionKit or NeuronKit.
- The **Recipe contract**: the declared metadata, the capability set, the
  run boundary, and the verification that precedes execution.
- The **foundational recipes** and their gates (capability, confirmation,
  zero-silent-loss).
- The **reasoning-lens recipe taxonomy** (§ 4) and the read-sequence-shape
  archetype (§ 5) that governs every lens recipe.
- The **error model** (§ 6): the closed recipe-guard set and the
  propagated substrate failure.
- Determinism obligations for the lens recipes.
- Cross-version conformance obligations, including the obligation that
  both versions realise the full recipe surface and that the catalog is a
  byte-for-byte parity anchor.

This specification does NOT define:

- API signatures — those live in `COGNITIONKIT_INTERFACE.md`.
- The reasoning surfaces a recipe sequences — hybrid recall, synthesis,
  branch operations, the benchmark, the tournament, and every reasoning
  lens (keystones, constellation, spreading activation, latent themes,
  theme weather, representation bias, learned preference, drift,
  anomalies, partial recall, anticipation, the DP summary / overlap) —
  those are NeuronKit's (`NEURONKIT_SPEC.md`). A recipe shapes their
  inputs and outputs; it does not own the reasoning.
- The estate verb surface, branch COW mechanics, and the recall/tunnel
  reads a recipe issues — those are GeniusLocusKit's
  (`GENIUSLOCUSKIT_SPEC.md`).
- Any algorithm. A recipe that implements an algorithm has leaked across
  its boundary; the algorithm belongs in NeuronKit (B-1).
- Storage, SQL, the `Drawer` schema — those are the substrate kits'.
- Cross-estate transport and mediation — that is aria-mcp's; a federated
  lens recipe (§ 4) shapes two estate handles it is handed and does not
  own the transport between them.
- Any specific product behaviour (obligation framing, daily planning, a
  product's domain scoring) — that belongs to the product layer atop the
  substrate (architecture spec § 33).

### § 1.1 — The placement gate (active vs subconscious)

The rule that decides whether a behaviour lives in CognitionKit or
NeuronKit:

- **NeuronKit is the subconscious** — the autonomic layer. Automated,
  self-running algorithm trees live here, alongside the raw algorithm
  nodes. The subconscious runs itself two ways: off its own deterministic
  scheduler, or off an internal feedback loop that computes an intent to
  act.

- **CognitionKit is active thinking** — the deliberate layer. It acts on
  intent from outside, and it can reach down into the subconscious and
  alter its behaviour by routing a directive to NeuronKit.

A subconscious tree is therefore triggered or modified from exactly three
places: a directive sent down from CognitionKit; NeuronKit's own
scheduler; or NeuronKit's own feedback loop.

The sort is **active vs automated**, not one-step-vs-many-steps: an
automated tree of many steps is still subconscious. A single analysis may
have both faces — an automated form the subconscious runs continuously
(NeuronKit) and a deliberate on-demand form a caller invokes
(CognitionKit) — in which case it is split across the two kits, never
duplicated.

## § 3 — Position in the kit family

```
            NeuronKit (subconscious: daemons + reasoning functions + lens surfaces)
                ▲
            CognitionKit  ← sequences NeuronKit reasoning + GLK verbs into recipes
                ▲
        product surfaces / agent tool layer (moot_list_recipes, intent router)
```

**Depends on:** NeuronKit (every reasoning surface a recipe sequences) and
GeniusLocusKit (the `EstateHandle`, the estate verbs, the recall and
tunnel reads, branch COW verbs). A recipe reaches the estate only through
the handle it is passed and reasons only through NeuronKit; it never calls
a substrate kit (LocusKit, VectorKit, CorpusKit, PersistenceKit, QueueKit)
directly (B-2).

**Consumed by:** product surfaces and the agent tool layer. The catalog
(§ 8) is the discovery surface.

## § 4 — The Recipe contract

A recipe is a named, deliberate behaviour with a declared capability set,
run against a passed-in estate. It owns no estate and instantiates no
NeuronKit; both are handed in.

A recipe declares:

- `name` — a stable identifier surfaced to callers and tool surfaces
  (e.g. `grounded_synthesis`).
- `version` — bumped when the recipe's observable behaviour changes.
- `description` — one human-readable line.
- `requiredCapabilities` — the set of NeuronKit reasoning capabilities the
  recipe will sequence, declared completely (no undeclared capability call,
  C-2).

A recipe runs against a typed `Input` and returns a typed `Output` — plain
value types carrying parameters in and results out, never a live substrate
handle the recipe would own. The run boundary takes the input, an
`EstateHandle` addressing the estate to operate against, and the
GeniusLocusKit surface through which verbs and branch operations dispatch.

**The capability gate.** A recipe's required capabilities are verified
against the host's available set before any execution begins. A recipe
that cannot be fully executed fails immediately at the gate
(`missingCapability`, § 6) and never partially runs (B-5). The check walks
a stable capability order, so the first-missing report is deterministic.

A capability names a NeuronKit reasoning surface a recipe may sequence.
The capability set is closed to surfaces that actually exist; a recipe
cannot declare a dependency on a surface that does not exist, so the gate
is a real check and not a rubber stamp.

## § 4.1 — Foundational recipes

These are deliberate, intent-driven behaviours that gate on capability and,
where a step is destructive, on explicit human confirmation.

**Grounded synthesis.** Hybrid-recall a query against the estate, then
synthesize the recalled drawers into a single grounded context document.
Sequences the hybrid-recall and synthesis reasoning surfaces. Read-only:
it issues no write verb and consults no substrate state beyond the recalled
page.

**Migration benchmark.** Derive one branch per migration plan, benchmark
each branch's recall fidelity against the origin corpus under the
zero-silent-loss gate, and rank the survivors; promotion of the winner is
a separate, explicitly confirmed step. Sequences the branch-derivation,
benchmark, tournament, and branch-promotion surfaces.

Input size is bounded before any branch derivation begins: a plan list
exceeding MAX_MIGRATION_PLANS (20) is rejected with `tooManyPlans`; an
origin corpus exceeding MAX_MIGRATION_ORIGIN_ENTRIES (5000) is rejected
with `tooManyOriginEntries`. These DoS bounds protect against unbounded
resource usage — each plan derives a COW branch (O(plans) work) and each
origin entry is captured into every branch (O(plans × entries) work).

A plan set with duplicate plan names is rejected before any branch is derived
(`duplicatePlanName`); a plan whose branch silently lost an origin concept
is disqualified from ranking and can never be promoted
(`silentConceptLoss`, a non-recoverable gate, C-5); a tournament with no
rankable survivor surfaces `tournamentNoWinner`; promotion without
confirmation surfaces `userConfirmationRequired` (B-3).

Guard evaluation order: `insufficientBranches` → `tooManyPlans` →
`tooManyOriginEntries` → `duplicatePlanName` → recipe start emit →
branch derivation loop.

## § 4.2 — The reasoning-lens recipe taxonomy (20)

Each lens recipe is a deliberate read that shapes the estate into the input
of one gated NeuronKit reasoning surface, calls that surface, and returns
its reasoning result. The lenses are grouped by the cognitive question they
answer; the category numbers match the NeuronKit lens headers
(`NEURONKIT_SPEC.md` § 7). Every lens recipe obeys I-1 (no algorithm),
I-2 (no direct substrate), I-6 (read-only, deterministic), and the
read-sequence-shape archetype (§ 5). The catalog-registered name for each
lens is given in parentheses where it differs from the prose name.

### Structure (category 1) — over the drawer/tunnel graph

- **Keystones** — read a wing's drawer-to-drawer tunnel graph and rank the
  load-bearing memories by surfacing NeuronKit's keystones. "The spine of
  your thinking." A wing with no tunnels yields an empty result.

- **Constellation** — read the same drawer-to-drawer graph and recover its
  emergent communities by surfacing NeuronKit's constellations. "The
  clusters I never named."

- **Free association** — from a seed drawer in a wing, surface NeuronKit's
  spreading activation over the weighted drawer graph and return the most-
  activated other drawers. "What this memory reminds me of."

### Time (category 3) — temporal fingerprint and periodicity

- **Moment** — read the estate's captured fingerprints for a primary time
  window, OR-reduce them into a temporal signature, and rank comparison
  windows by Hamming proximity to that signature. "How similar was this
  period to those others."

- **Rhythm** — read the estate's bit-activity series for a fingerprint bit
  and surface NeuronKit's FFT to find the dominant periodic patterns.
  "What repeats."

- **Precedence** — read the estate's audit lag pairs, fold them into
  T-matrix deltas via TemporalCausalityFold, and surface NeuronKit's
  precedence to rank the antecedents most predictive of a target
  field-value coordinate. "What tends to happen just before X."

### Topics (category 2) — over categories / co-occurrence

- **Latent themes** — recall a frame, derive a label co-occurrence, and
  surface NeuronKit's latent-themes factorisation into soft topic loadings.
  "The themes underlying the co-occurrence."

- **Theme weather** — recall a frame, derive per-category recency-weighted
  and raw masses, and surface NeuronKit's theme-weather momentum. "Which
  themes are rising vs fading."

- **Complexity** — recall a frame, derive the frequency distribution of a
  label field (and an optional second field for mutual information), and
  surface NeuronKit's complexity (Shannon entropy and optional mutual
  information). "How varied the filing is, and whether two fields co-vary."

### Preference (category 4) — what the estate leans toward / away from

- **Bias** — recall the estate's category distribution against a passed-in
  reference and surface NeuronKit's representation bias and learned
  preference. "What I lean toward, away from, and actually keep."

### Surprise (category 5) — distributional movement and outliers

- **Drift** — recall a frame, split it at a time boundary, and surface
  NeuronKit's drift between the two halves. "How far the distribution has
  moved."

- **Cohesion** (`cohesion`) — recall a frame and surface NeuronKit's
  anomaly detection (with a shingle-similarity tie-break) to find the
  memories whose content cohesion with the recalled set is anomalously low.
  "Which memory is the odd one out." (Previously named `contradiction` in
  the catalog; renamed to distinguish statistical cohesion anomaly detection
  from the semantic contradiction lens below.)

- **Lens contradiction** (`lens_contradiction`) — surface genuine
  contradictions in the estate: drawer pairs linked by an explicit
  `contradicts` tunnel and KG facts with conflicting objects for the same
  subject+predicate key. "What explicitly contradicts what."
  Catalog-only registration; the implementing recipe is forthcoming.

### Diffusion node layer — per-memory motion

- **Node motion** (`node_motion`) — read a single memory's recent audit
  history and surface its mutation volatility (decay-weighted recent-churn
  mass), its topic trajectory (the UDC anchors it has occupied over time),
  whether it has reanchored, and a write-time anomaly verdict
  (churning / reanchored / stable). "How this memory has moved."
  Catalog-only registration; the implementing recipe is forthcoming.

### Grounding / trust (category 6)

- **Trust** — grounded synthesis with a provenance overlay: synthesize a
  recalled frame and surface how well-grounded the set is by source. "How
  trustworthy this grounding is."

### Associative (category 7)

- **Feels-like** — from an anchor drawer and a cue mode, surface NeuronKit's
  partial-state recall to find drawers that match on some facets and differ
  on others. "What matches on these facets but differs on those."

### Prediction (category 8) — action → outcome and successor

- **Anticipate** — recall a frame of action→outcome observations and
  surface NeuronKit's anticipation, ranked by the conservative success
  bound, for a target outcome. "To reach Y, what action tends to work."

- **Tunnel successor** — from an anchor drawer in a wing, read the explicit
  tunnel graph and return the drawers that tend to follow it by explicit
  link. "What tends to follow this, by explicit links." (A pure graph read;
  it sequences no reasoning surface.)

### Federated (category 9) — over two estates

- **Mind overlap** — shape two estate handles into two frames and surface
  NeuronKit's differentially-private summary overlap. "Where two minds
  converge, privately."

- **Estate divergence** — shape two estate handles into two frames and
  surface NeuronKit's drift between their distributions. "How two estates'
  distributions differ."

## § 4.3 — Analytics recipes (3)

Three analytics recipes mine structural patterns across a recalled drawer set or
the estate's audit log. Each delegates to a SubstrateML engine after reading the
estate through the passed handle and GeniusLocusKit surface. The analytics recipes
obey B-5 (capability gate before any estate touch), I-2 (no direct substrate kit
access), and I-3 (complete capability declaration), parallel to the lens recipes.

## § 4.4 — Exploratory-recall recipe (1)

The exploratory-recall recipe walks a wing's tunnel graph with restart from a seed
drawer, accumulating visit counts per RowId and returning the most-visited drawers
(excluding the seed) ranked descending. It obeys B-1 (no math in the recipe — all
walk math lives in `SubstrateML.RandomWalks.walkWithRestart`), B-5 (capability gate
before any estate touch), B-6 (PRNG seed derived deterministically from the seed
drawer id via FNV hash64 — no wall clock), I-1, I-2, I-3, and I-6.

**Exploratory recall** (`recall_exploratory`). Reads the tunnel graph for a named
wing via `GeniusLocusKit.recallTunnels`, builds a RowId-keyed adjacency from
drawer-to-drawer tunnel edges (only edges whose source and target drawer ids are
valid UUID strings), derives an FNV RNG seed from the seed drawer id string, and
delegates to `RandomWalks.walkWithRestart`. Returns `ExploratoryResult` records
(drawer UUID string, visit count) ranked by visit count descending with drawer id
as a stable tie-break. A seed absent from the adjacency returns an empty result. A
`k > 0` input truncates to the top-k results. Declares the `exploratoryRecall`
capability.

**RNG seed derivation.** The PRNG seed is `FNV.hash64(seedDrawerID)` in Swift and
`substrate_types::fnv::hash64(seed_drawer_id)` in Rust — both produce the same
64-bit value for the same UUID string, so the walk is reproducible and cross-version
deterministic on the same input.

## § 4.5 — Distillation-family recipes (3)

Three recipes that operate on or with the distilled memory tier — the dense
factoid drawers produced by the per-item distillation pipeline. All three
have empty `requiredCapabilities`, obey B-1/B-2 (pure sequencing, no
direct substrate kit access), and obey I-6 (read-only, deterministic,
except `consolidate` which produces factoid drawers as its intended side
effect).

**Consolidate** (`consolidate`). Triggers an on-demand distillation sweep
over the estate. Delegates entirely to `GeniusLocusKit.distillItemsSweep` /
`EstateCoordinator::distill_items_sweep`, which iterates active
not-yet-distilled items, applies the NeuronKit HMM feature extractor via
the distillation pipeline, and persists produced factoid drawers in room
`_distilled`. The `clusterID` and `includeHeld` input parameters are
accepted for API stability but are currently no-ops at this layer; the
sweep operates estate-wide. Returns the count of factoid drawers produced.

**DistilledRecall** (`distilled_recall`). Dense-tier recall: searches the
distilled memory tier using structural fingerprint Hamming nearest-neighbor
over the `distillation-features-v1` VectorKit lane. No embedding model
inference required; no full corpus scan. Returns `DistilledMatch` records
(drawer UUID, factoid prose, confidence, source count, SNR, delta type,
uncertainty flag, injection depth) and a `DistilledDiscriminationLevel`
signal (how well the top result separates from the rest). The
discrimination signal is derived from the confidence-score gap between
rank-1 and rank-2 matches. Hydration is frame-aware and enforces the
sensitivity ceiling; tombstoned or restricted drawers are excluded before
DIST content is parsed.

**Recollect** (`recollect`). Fan-out from a distilled factoid to its
source memories. Follows the outgoing `_distilled_from` tunnel graph from
a `_distilled` drawer and returns the full episodic content of the M
source memories that produced it. Three error gates enforce structural
invariants: `factoidNotFound` (the drawer ID is not in this estate);
`notADistilledDrawer` (the drawer exists but carries no DIST header);
`noSourceTunnels` (the factoid has no outgoing `_distilled_from` tunnels,
indicating it predates tunnel wiring). Source memories are ordered
oldest→newest by tunnel `filedAt`; withdrawn sources are silently skipped,
so `sourceCount` (from the DIST header) may exceed `sources.count`.

**Association rules** (`association_rules`). Recalls a frame via the estate handle,
projects each drawer's categorical facets (kind, channel, sensitivity, room) into a
per-call sorted label vocabulary, builds a co-occurrence matrix using `MatrixO`, and
surfaces SubstrateML's `mineAssociationRules` over the matrix. Returns relabeled
pairwise rules with the five standard metrics (support, confidence, lift, conviction,
leverage). Declares the `associationRuleMining` capability.

**Apriori rules** (`apriori_rules`). Reads the estate's audit log `RowAttributeView`
via `GeniusLocusKit.mineAprioriRules` and surfaces SubstrateML's multi-antecedent
Apriori mining. No label projection; the engine works directly on the audit log's
`(field, value)` items. Declares the `associationRuleMining` capability.

**Formal concepts** (`formal_concepts`). Recalls a frame, builds a `FormalContext`
where each drawer is one row and its categorical facets (trust, lattice anchors
udc/qid, sensitivity, kind, channel, room) are its attributes, and surfaces
SubstrateML's `BoundedConceptMiner`. Returns formal concepts with drawer-ID extents,
cover deltas (a structural lens over the mined concept order), and the bounded
Duquenne–Guigues canonical basis of sound logical implications. Declares the
`formalConceptAnalysis` capability.

**Engine location.** The analytics engines (`mineAssociationRules`, `AprioriMining`,
`BoundedConceptMiner`) live in SubstrateML and are reached without a NeuronKit lens.
This is sanctioned: B-2's prohibition names the substrate kits (LocusKit, VectorKit,
CorpusKit, PersistenceKit, QueueKit); it does not prohibit calling the gated math
libraries in SubstrateML. The analytics recipes remain conformant with B-1 (no
algorithm in the recipe body — the recipe shapes inputs; the engine owns the
computation) and I-1 (no re-implementation of the mining algorithms). Do not alter
B-1 or B-2 on account of the analytics recipes.

## § 5 — The read-sequence-shape archetype

Every lens recipe in § 4.2 is built to one archetype, and the archetype is
itself a design contract:

1. **Read the estate through the handle.** The recipe issues a read —
   a hybrid recall over a frame, a tunnel-graph read for a wing, a
   per-category distribution — through the passed estate handle and the
   GeniusLocusKit surface. It issues no write verb and touches no substrate
   state beyond what the read returns (I-2, I-6).

2. **Shape the read into the reasoning surface's input.** The recipe turns
   the substrate's natural form (a drawer-id edge list, a sparse
   co-occurrence, per-category masses, a set of action-outcome events) into
   the NeuronKit surface's input. The recipe adds no math (I-1).

3. **Surface the gated reasoning.** The recipe calls the one NeuronKit
   reasoning surface for its lens and returns that surface's reasoning
   result, named for the cognitive question. The numeric content is the
   reasoning surface's; the recipe shapes it into the recipe's typed output.

This archetype is why the lens-recipe surface is thin, pure, deterministic,
and parallel across versions: the port-sensitive reasoning lives once in
NeuronKit (which itself surfaces the gated SubstrateML / matrix-tier math),
and the recipe is a deliberate read on the conscious side of it. A new lens
recipe is added by reading the estate for an existing NeuronKit reasoning
surface — never by importing reasoning into CognitionKit.

## § 6 — Error model

A recipe surfaces two kinds of failure, and the distinction is a contract,
not an accident:

- **A recipe-guard failure** — a fault the recipe itself detects before or
  during sequencing. This is a closed set: a required capability is
  unavailable (`missingCapability`, raised at the gate before any
  execution); a branch-deriving recipe got fewer inputs than its minimum
  (`insufficientBranches`); the plan list exceeds the DoS bound of 20
  (`tooManyPlans`); the origin corpus exceeds the DoS bound of 5000 entries
  (`tooManyOriginEntries`); two plans share a name (`duplicatePlanName`); a
  branch silently lost an origin concept (`silentConceptLoss`, non-
  recoverable — a disqualified branch can never be promoted, C-5); a
  tournament produced no rankable survivor (`tournamentNoWinner`); or a
  destructive step requires confirmation that was not provided
  (`userConfirmationRequired` — a recipe never auto-confirms on the
  caller's behalf, B-3).

  The DoS-guard cases (`tooManyPlans`, `tooManyOriginEntries`) are checked
  after `insufficientBranches` and before `duplicatePlanName`, so they fire
  before any branch is derived. Their maximum values are constants in both
  ports (`MAX_MIGRATION_PLANS = 20`, `MAX_MIGRATION_ORIGIN_ENTRIES = 5000`)
  and their human-readable messages match across versions byte-for-byte.

- **A propagated substrate failure** — a read or verb behind the estate
  boundary failed (a recall, a tunnel read, a branch derivation). The
  failure names the operation and its cause and surfaces unchanged; a
  failed read is surfaced as a substrate failure, never as a silent empty
  result.

The recipe-guard set is closed and parity-gated: its members and their
human-readable messages match across versions. A lens recipe, being
read-only, can only ever surface a propagated substrate failure or its
empty/neutral result; it raises no recipe-guard failure.

## § 7 — Behavioral contracts

**B-1 (recipes implement no algorithms):** a recipe sequences reasoning;
all computation delegates to a NeuronKit surface. A recipe that implements
an algorithm has leaked across its boundary.

**B-2 (no direct substrate access):** a recipe reads and writes only
through NeuronKit or the passed estate handle. It never calls a substrate
kit (LocusKit, VectorKit, CorpusKit, PersistenceKit, QueueKit) directly and
executes no SQL.

**B-3 (no autonomic destructive action):** a recipe never auto-promotes a
branch or auto-discards substrate state. Every destructive step is gated
behind explicit human confirmation (`userConfirmationRequired`).

**B-4 (recipes are stateless between calls):** a recipe holds no state
across invocations. State between a recipe's own steps lives in local
values or in the NeuronKit / GeniusLocusKit nouns it is handed.

**B-5 (capability declarations are verified before execution):** a recipe's
required capabilities are checked against the host's available set at the
top of the run, before any substrate touch. A recipe that cannot be fully
executed fails at the gate and never partially runs.

**B-6 (lens recipes are read-only and deterministic):** a lens recipe issues
no write verb and is a deterministic function of its inputs. It reads no
wall clock — a `now` value is passed in — and any walk or DP seed is derived
from its inputs, so the recipe is reproducible and the two versions agree on
shared vectors.

## § 8 — The catalog and graduation

The catalog is an enumerable registry of recipe descriptors — name,
version, description, required capabilities — in stable declaration order.
It is the single place a recipe is registered for discovery, and the
`moot_list_recipes` tool reads exactly these values.

The catalog is a **parity anchor**: a descriptor's strings and field shape
match across the Swift and Rust versions byte-for-byte, so a descriptor
round-trips identically across the versions' wire shapes. The catalog
therefore lists exactly the recipes that exist in both versions.

A recipe **graduates** into the catalog only when: it has a named consumer; its caveats
are retired rather than relabeled; it fits the descriptor model; and both
versions of the recipe land together, so the anchor never sees a recipe
present in one version and absent from the other. A recipe registered in
the catalog is registered in both versions or in neither. This applies to
all recipe families: the two foundational recipes, the twenty lens
recipes, the three analytics recipes, the exploratory-recall recipe, and
the three distillation-family recipes. The thirty catalog entries are
listed in the concordance in `COGNITIONKIT_INTERFACE.md` § 7.

## § 9 — Invariants

**I-1 (recipes own no reasoning):** every recipe is a sequencer over gated
NeuronKit reasoning surfaces. A recipe never re-implements recall, synthesis,
centrality, community detection, the random walk, NMF, decay, drift, anomaly
detection, partial recall, the action-outcome model, the DP summary, the
benchmark, or the tournament — it shapes the estate into the surface's input
and the surface's output into a reasoning result. A recipe that reaches into
math a lower layer owns is non-conformant. (See § 5.)

**I-2 (recipes hold no substrate):** a recipe reads and writes only through
the passed estate handle and NeuronKit. It owns no estate, opens no estate,
instantiates no kit, and reaches no substrate kit's API directly.
(Consistent with B-2.)

**I-3 (the capability declaration is complete):** a recipe's
`requiredCapabilities` names every NeuronKit capability it will sequence.
A recipe that calls an undeclared capability is non-conformant; the gate
(B-5) is only sound if the declaration is complete.

**I-4 (no destructive step without confirmation):** every branch promotion
or multi-branch discard is gated behind explicit confirmation. A recipe that
performs a destructive substrate change without a confirmation token is
non-conformant. (Consistent with B-3.)

**I-5 (the catalog is a parity anchor):** the catalog lists exactly the
recipes present in both versions, and each descriptor matches across versions
byte-for-byte. A recipe registered in one version's catalog and absent from
the other's is non-conformant. (See § 8, C-7.)

**I-6 (lens recipes are pure and read-only):** every lens recipe is a
deterministic function of its explicit inputs. It issues no write verb,
reads no substrate state beyond the estate read it is handed, and reads no
wall clock (a `now` value is passed in; any seed is input-derived). A lens
recipe that writes or that depends on the clock is non-conformant.

## § 10 — Conformance requirements

**C-1 (recipe-protocol conformance):** every recipe declares its metadata
and capability set and runs against a passed estate handle and kit; no
recipe opens an estate or instantiates a kit. (I-2.)

**C-2 (capability-declaration completeness):** every NeuronKit capability a
recipe sequences appears in its `requiredCapabilities`; the capability gate
is verified before execution. (B-5, I-3.)

**C-3 (no algorithm in a recipe):** a recipe's body is read, shape, and
sequence — no algorithm. A recipe whose result diverges from a direct call
to the underlying NeuronKit surface on the same shaped input is non-
conformant. (B-1, I-1.)

**C-4 (no direct substrate touch):** no recipe calls a substrate kit
directly or executes SQL; every substrate touch is a NeuronKit call or an
estate-handle read. (B-2, I-2.)

**C-5 (zero silent migration loss):** the migration-benchmark recipe
disqualifies any branch whose recall silently lost an origin concept; a
disqualified branch is retained with a typed reason and can never be
promoted. The disqualification gate is applied before ranking.

**C-6 (lens determinism):** every lens recipe is a deterministic function of
its inputs — no wall-clock read, no unseeded randomness; ties resolve on
stable keys so a lens recipe's result is reproducible. (B-6, I-6.)

**C-7 (full recipe surface on both versions):** both the Swift and Rust
versions realise the complete recipe surface — the two foundational recipes,
the twenty lens recipes, the three analytics recipes, the exploratory-recall
recipe, and the three distillation-family recipes — with matching recipe
names, descriptors, and result shapes, and bit-for-bit-equal numeric results
on shared vectors where a recipe surfaces a deterministic reasoning result.
A recipe present in one version and absent from the other is non-conformant.
The two catalog-only lens entries (`node_motion` and `lens_contradiction`)
are registered as descriptors in both versions; their implementing recipes
are forthcoming and will be added to both versions together when they land.

**C-8 (catalog parity anchor):** the catalog descriptors match across
versions byte-for-byte; the catalog lists exactly the recipes present in
both versions; a recipe graduates into the catalog in both versions together
or in neither. (§ 8, I-5.)

**C-Det (cross-version determinism):** for every shared test vector, the
Swift and Rust versions of a lens recipe agree bit-for-bit on the reasoning
result they return — the keystone centralities, community partitions,
activation frequencies, theme loadings and reconstruction error, momentum,
bias differences and preference strengths with intervals, drift divergences,
anomaly scores, partial-recall matches, the Wilson-ranked predictions, and
the federated summary overlaps. Agreement holds because the recipe shapes
identically and the reasoning surface it sequences is itself cross-version
deterministic (`NEURONKIT_SPEC.md` C-Det).

## § 11 — Self-report telemetry

CognitionKit emits self-report metrics through IntellectusLib at recipe-run
boundaries. Monitoring is **off by default**; off-path cost is a single
atomic load plus branch (~1 ns, zero allocation).

### § 11.1 — Emit contract

Every foundational recipe emits a **start** and a **complete** metric using
the stable name `"cognitionkit.recipe.run"`:

| tag | start value | complete value |
|---|---|---|
| `recipe` | recipe name (e.g. `"grounded_synthesis"`) | same |
| `status` | `"start"` | `"complete"` |
| `step_count` | absent | number of items processed |

The `step_count` for **GroundedSynthesis** is the number of recalled drawers
(`drawer_count`). For **MigrationBenchmark** it is the number of plans
benchmarked (`plans.count`).

The `ts` field is epoch seconds captured once at the validated recipe-entry
point (after capability and guard checks pass). The value is caller-supplied
to the emit helper — no clock is read inside the emit function itself.

### § 11.2 — Emit placement

- **Start** is emitted AFTER all precondition guards (capability gate, empty
  plans check, duplicate-name check). A metric is only emitted if the recipe
  body will actually run.
- **Complete** is emitted AFTER the return value is fully assembled and
  BEFORE the `return` statement. The return value is identical whether
  monitoring is on or off (C-Det invariant).

### § 11.3 — Test isolation

Tests that call recipe `run()` functions must hold the process-wide
`CognitionTestMutex` for their entire duration. The mutex prevents a
concurrent telemetry test that holds the Intellectus singleton enabled from
receiving emissions from non-telemetry tests in its capturing sink.

The Rust telemetry integration tests use a `static GLOBAL_LOCK:
OnceLock<Mutex<()>>` acquired at the top of every test that touches the
singleton.

### § 11.4 — Conformance (C-Tel)

**C-Tel (telemetry conformance):** when monitoring is disabled, both Swift
and Rust recipe implementations emit zero metrics. When monitoring is
enabled, each recipe emits exactly one start metric and one complete metric
per invocation. The recipe's return value is bit-identical whether monitoring
is on or off (C-Det extension: the telemetry path does not affect output).

---

*End of CognitionKit Specification.*

## Changelog

### 1.8.0 -- 2026-08-06

- New recipe ConnectedRecall (`recall_connected`): scored anchor grab →
  multi-seed walk-with-restart (FNV-seeded, deterministic) over
  tunnels ∪ associations (both directions, drawer-endpoint edges) →
  RRF fusion → late hydration. Degrades to plain scored recall on a
  structureless estate, never below it. Rust twin
  `connected_recall::run_connected_recall`.

### 1.7.0 -- 2026-08-06

- GroundedSynthesis grounding pool: the recipe OWNS both lanes. Lane A =
  base frame + OR of contentMatches cue predicates; lane B = scored
  search over the raw query (`Input.query`), both bounded by
  `groundingPoolBound` (200). Lane weighting moved into hybridRecall
  (the recency-shall-not-dominate invariant); the recipe passes caller
  tuning through. Degraded contract: on an estate whose scored lane
  yields no scoring-evidence hits, hybrid grounding behaves exactly like
  lexical-only grounding.

### 1.6.0 -- 2026-08-06

- GroundedSynthesis keyInsights bound: cue-grounded runs excerpt EVERY
  capped survivor (maxKeyInsights = post-cap drawer count); digest runs
  keep the historical 3-row bound. Trial 3 measured 30/35 misses with
  the answer ranked into the capped set but invisible behind the 3-row
  excerpt.

### 1.5.0 -- 2026-08-06
`GroundedSynthesis.Input` gains `cueTerms: [String] = []` and `cap: Int? = nil`.
When `cueTerms` is non-empty, recall is passed through `HybridRecallEngine.rerank`
with the cue terms so the lexical lane is genuinely independent of the recency lane,
and the recipe OWNS the lane weights: it overrides the tuning's lane split to
lexical-dominant (1.0/0.0 — recency strictly a tie-break, which the lexical
sort's input-order tie-break provides), because any blended weighting lets the
recency lane's pool-size-scaled rank spread override a one-step relevance
difference on large estates. The caller's `rrfK`, `mmrLambda`, and `pageSize`
still apply. `cap` is applied after rerank so only the top-N ranked drawers feed
synthesis — preventing a wide frame from overwhelming the synthesizer while still
surfacing the most relevant drawer regardless of filing date. Rust port mirrors
Swift.

### 1.4.0 -- 2026-07-16
Closed missing DoS-bound invariants (verifier gap):

- § 4.1 migration benchmark: added DoS-bound description (`tooManyPlans` at
  MAX_MIGRATION_PLANS = 20, `tooManyOriginEntries` at MAX_MIGRATION_ORIGIN_ENTRIES
  = 5000) with rationale (O(plans × entries) work) and the guard evaluation order.
  Both constants are enforced in `migration_orchestration.rs` before any branch
  derivation begins.
- § 6 error model: added `tooManyPlans` and `tooManyOriginEntries` to the closed
  recipe-guard set with their triggering conditions, guard-order placement, and
  the note that their Display/description messages match byte-for-byte across ports.

### 1.3.0 -- 2026-07-16
Additive audit (MX-TAB dataset series + distillation-family): updated § 1
purpose to cite twenty reasoning-lens recipes and add the distillation-family
recipe family. Updated § 4.2 header (18→20) and Surprise sub-section:
renamed `Contradiction` lens entry to `Cohesion` (`cohesion` in the catalog,
reflecting the catalog rename from `contradiction`); added `lens_contradiction`
(catalog-only, explicit KG contradiction detection) and a new "Diffusion node
layer" sub-section for `node_motion` (catalog-only). Added § 4.5
Distillation-family recipes (Consolidate, DistilledRecall, Recollect).
Updated § 8 catalog count (25→30) and C-7 recipe surface count. Updated
catalog-only lens entry clause in C-7.

### 1.2.0 -- 2026-06-17
Additive (A-2 exploratory-recall): added § 4.4 (exploratory-recall recipe family,
`recall_exploratory`) and the `exploratoryRecall` capability. The recipe delegates
entirely to `SubstrateML.RandomWalks.walkWithRestart` (B-1); gates on the new
capability (B-5); derives its RNG seed from the seed drawer id via FNV hash64
(B-6/I-6). Registered in the catalog (count → 25). Updated § 1 purpose summary,
§ 8 graduation roster, C-7, and C-8.

### 1.1.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): added the `shaped_recall` recipe — a single
parameterized recall recipe over the GLK named `RecallShape` preset roster. It
SEQUENCES one estate recall verb (`.unionBest`/`.matrixAware`) with a preset-
resolved signed-weight shape applied; it owns no math and no substrate state
(B-1/B-2), and `"balanced"` (or an unknown preset) runs unsteered. Registered in
the catalog as a parity anchor (catalog count → 24). The four ARIA filtering
adjectives compose ORTHOGONALLY with the preset (the preset ranks; the filter
filters). Conformance: `ShapedRecallTests.swift` / `shaped_recall.rs`.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
