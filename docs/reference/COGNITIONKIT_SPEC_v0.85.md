---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-06-01
version: v0.85
supersedes: COGNITIONKIT_SPEC_v0.8.md
package: CognitionKit
kind: Kit
relates_to:
  - COGNITIONKIT_INTERFACE_v0.85.md  (the API surface this spec contracts)
  - NEURONKIT_SPEC_v0.85.md  (the reasoning surface every recipe sequences — daemons, reasoning functions, the lens taxonomy)
  - GENIUSLOCUSKIT_SPEC_v0.8.md  (the estate verb surface and branch COW verbs recipes dispatch through)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (the substrate contract; the active/subconscious control path)
  - LENS_DISCOVERABILITY_DECISION_v2.0_2026-06-02.md  (the catalog-graduation criteria for a lens recipe; supersedes v1.0)
purpose: |
  CognitionKit is the conscious mind of the MOOTx01 substrate: the
  behaviour-recipe layer that sequences NeuronKit reasoning and
  GeniusLocusKit estate verbs into named, reusable behaviours. It
  contains no algorithms and owns no substrate state. A recipe is a
  deliberate, intent-invoked behaviour with a declared capability set; it
  reads through the estate handle and reasons through NeuronKit, and
  returns a typed result. The recipe surface is two foundational
  behaviours (grounded synthesis, migration benchmark) and a taxonomy of
  fourteen reasoning-lens recipes — each a deliberate read that sequences
  one gated NeuronKit reasoning surface over the estate. The companion
  INTERFACE document carries the signatures.
---

# CognitionKit Specification

> **Supersedes COGNITIONKIT_SPEC_v0.8.** v0.85 promotes the recipe surface
> from a documented as-built inventory to first-class settled design. The
> fourteen reasoning-lens recipes (§ 4) are specified here as a deliberate
> taxonomy with a shared construction archetype (§ 5, "read-sequence-
> shape"), parallel to the NeuronKit lens taxonomy they consume
> (`NEURONKIT_SPEC_v0.85` § 7). Both the Swift and Rust versions realise the
> full recipe surface (C-7); the catalog parity anchor (§ 8) holds across
> versions byte-for-byte.

## § 1 — What this package is

CognitionKit is the conscious, deliberate layer of the MOOTx01 substrate.
It sits above NeuronKit and assembles NeuronKit reasoning and
GeniusLocusKit estate verbs into named, reusable **recipes** — behaviours
a caller invokes by intent.

It offers three families of recipe:

- **Foundational recipes (§ 3).** The two deliberate substrate
  behaviours that gate on capability and explicit confirmation:
  **grounded synthesis** (hybrid-recall a query, synthesize the recalled
  drawers into one grounded context document) and **migration benchmark**
  (derive one branch per migration plan, benchmark each against the origin
  corpus under a zero-silent-loss gate, rank survivors, gated-promote the
  winner).

- **Reasoning-lens recipes (§ 4).** A taxonomy of fourteen deliberate
  reads, each of which shapes the estate into the input of one gated
  NeuronKit reasoning surface, calls that surface, and returns the
  reasoning result. The structural lenses (keystones, constellation,
  free association), the topic lenses (latent themes, theme weather), the
  preference lens (bias), the surprise lenses (drift, contradiction), the
  grounding lens (trust), the associative lens (feels-like), the
  prediction lenses (anticipate, tunnel successor), and the federated
  lenses (mind overlap, estate divergence).

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

- API signatures — those live in `COGNITIONKIT_INTERFACE_v0.85.md`.
- The reasoning surfaces a recipe sequences — hybrid recall, synthesis,
  branch operations, the benchmark, the tournament, and every reasoning
  lens (keystones, constellation, spreading activation, latent themes,
  theme weather, representation bias, learned preference, drift,
  anomalies, partial recall, anticipation, the DP summary / overlap) —
  those are NeuronKit's (`NEURONKIT_SPEC_v0.85`). A recipe shapes their
  inputs and outputs; it does not own the reasoning.
- The estate verb surface, branch COW mechanics, and the recall/tunnel
  reads a recipe issues — those are GeniusLocusKit's
  (`GENIUSLOCUSKIT_SPEC_v0.8`).
- Any algorithm. A recipe that implements an algorithm has leaked across
  its boundary; the algorithm belongs in NeuronKit (B-1).
- Storage, SQL, the `Drawer` schema — those are the substrate kits'.
- Cross-estate transport and mediation — that is ARIA_MCP's; a federated
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
benchmark, tournament, and branch-promotion surfaces. A plan set with
duplicate plan names is rejected before any branch is derived
(`duplicatePlanName`); a plan whose branch silently lost an origin concept
is disqualified from ranking and can never be promoted
(`silentConceptLoss`, a non-recoverable gate, C-5); a tournament with no
rankable survivor surfaces `tournamentNoWinner`; promotion without
confirmation surfaces `userConfirmationRequired` (B-3).

## § 4.2 — The reasoning-lens recipe taxonomy (14)

Each lens recipe is a deliberate read that shapes the estate into the input
of one gated NeuronKit reasoning surface, calls that surface, and returns
its reasoning result. The lenses are grouped by the cognitive question they
answer; the category numbers match the NeuronKit lens headers
(`NEURONKIT_SPEC_v0.85` § 7). Category 3 is reserved. Every lens recipe
obeys I-1 (no algorithm), I-2 (no direct substrate), I-6 (read-only,
deterministic), and the read-sequence-shape archetype (§ 5).

#### The categorical projection of a drawer

The topic, preference, and prediction lenses do not reason over a
drawer's prose. They reason over the drawer's **categorical facets** —
the same facets the substrate already records as bitmap fields and as the
structural fingerprint. A lens recipe derives one of two projections from
a recalled drawer set, and which one is fixed by the shape the lens's math
requires, not by the recipe's discretion:

- **The partition projection** — for a lens whose math takes one value per
  axis (theme weather's per-category mass, bias's category share,
  anticipate's category-keyed events). Each categorical axis of a drawer
  (a state, a content kind, a capture channel, a source type, a trust
  level, a sensitivity, and the other bitmap fields) holds exactly one
  value, so the drawer contributes exactly one category token per axis.
  A category token is the pairing of an axis identifier with that axis's
  value identifier; both identifiers are the axis's and value's own
  canonical names as fixed by the substrate vocabulary, language-neutral
  and identical across versions. The token is a stable identity, never a
  rendered or debug-formatted string. A lens counts, masses, or shares
  these per-axis tokens; because each axis is single-valued, the tokens
  of one axis form a true partition of the drawer set.

- **The co-occurrence projection** — for a lens whose math takes a sparse
  symmetric co-occurrence over a shared label vocabulary (latent themes'
  NMF). A drawer projects to the **set bits of its structural
  fingerprint**: the fingerprint is a fixed-width bit vector each drawer
  carries, and a set bit is a categorical feature the drawer exhibits and
  may share with other drawers. A label is a fingerprint bit position — an
  integer index into the fixed bit space, language-neutral by
  construction. The co-occurrence weight of a label pair is the count of
  recalled drawers whose fingerprint has both bits set. This projection is
  what makes the factorisation meaningful: bits that co-vary across the
  recalled set are the latent themes the NMF recovers. The single-valued
  partition tokens are deliberately NOT used here — independent axes do not
  co-occur in any way the factorisation can read.

Both projections are derived from substrate quantities that are already
byte-identical across versions (the bitmap fields and the conformance-
gated fingerprint), so a lens that shapes its input from them inherits
cross-version determinism for free (C-Det). A lens recipe that invents a
label or category string of its own — a rendered field value, a
language-specific formatting of an enum — has left the substrate
vocabulary and is non-conformant: the projection must be the substrate's
own identities, not a restatement of them.

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

### Topics (category 2) — over categories / co-occurrence

- **Latent themes** — recall a frame, derive the **co-occurrence
  projection** over the recalled drawers (fingerprint-bit labels, weighted
  by how many drawers share each bit pair), and surface NeuronKit's
  latent-themes factorisation into soft topic loadings. "The themes
  underlying the co-occurrence."

- **Theme weather** — recall a frame, derive the **partition projection**
  over one categorical axis (per-category counts, plus recency-weighted
  masses over the same tokens), and surface NeuronKit's theme-weather
  momentum. "Which themes are rising vs fading."

### Preference (category 4) — what the estate leans toward / away from

- **Bias** — derive the **partition projection** of the estate's category
  shares, compare against a passed-in reference share, and surface
  NeuronKit's representation bias and learned preference. "What I lean
  toward, away from, and actually keep."

### Surprise (category 5) — distributional movement and outliers

- **Drift** — recall a frame, split it at a time boundary, and surface
  NeuronKit's drift between the two halves. "How far the distribution has
  moved."

- **Contradiction** — recall a frame and surface NeuronKit's anomaly
  detection (with a shingle-similarity tie-break) to find the odd one out.
  "Which memory is the outlier."

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

### Analytics (category 10) — over the recalled set's co-occurrence structure

- **Association rules** — recall a frame, project each drawer's categorical
  facets (kind, channel, sensitivity, room) into the co-occurrence matrix O
  using a per-call label vocabulary (canonical lowercase camelCase Swift
  case names, ≤64 labels), and surface NeuronKit's `mineAssociationRules`
  pairwise rule mining with the five standard metrics (support, confidence,
  lift, conviction, leverage). "What co-occurs with what across the
  recalled drawers." The label vocabulary is per-call and deterministic;
  rules are relabeled to string antecedents and consequents before return.

- **Formal concepts** — recall a frame, build a `FormalContext` where each
  drawer is one row and its categorical facets (kind, channel, sensitivity,
  room) are its `FormalAttribute` triples (namespace "locus", key = axis
  name, value = canonical lowercase camelCase Swift case name), and surface
  NeuronKit's `BoundedConceptMiner`. "What maximal attribute closures — the
  hidden cohorts — emerge from the recalled drawer set." Concept extents are
  relabeled to drawer IDs before return.

## § 5 — The read-sequence-shape archetype

Every lens recipe in § 4.2 is built to one archetype, and the archetype is
itself a design contract:

1. **Read the estate through the handle.** The recipe issues a read —
   a hybrid recall over a frame, a tunnel-graph read for a wing, a
   per-category distribution — through the passed estate handle and the
   GeniusLocusKit surface. It issues no write verb and touches no substrate
   state beyond what the read returns (I-2, I-6).

2. **Shape the read into the reasoning surface's input.** The recipe turns
   the substrate's natural form into the NeuronKit surface's input: a
   drawer-id edge list for the graph lenses, the **co-occurrence
   projection** (fingerprint-bit labels) for latent themes, the
   **partition projection** (single-valued categorical-axis tokens) for
   theme weather, bias, and anticipate, a set of action-outcome events, or
   two estate distributions. Both categorical projections (§ 4.2) are read
   off substrate quantities — the bitmap fields and the structural
   fingerprint — so the recipe restates the substrate's own identities and
   invents no label of its own. The recipe adds no math (I-1).

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
  (`insufficientBranches`); two plans share a name (`duplicatePlanName`); a
  branch silently lost an origin concept (`silentConceptLoss`, non-
  recoverable — a disqualified branch can never be promoted, C-5); a
  tournament produced no rankable survivor (`tournamentNoWinner`); or a
  destructive step requires confirmation that was not provided
  (`userConfirmationRequired` — a recipe never auto-confirms on the
  caller's behalf, B-3).

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

A recipe **registers** in the catalog when both its versions ship, per
`LENS_DISCOVERABILITY_DECISION_v2.0`: the catalog lists every recipe
that exists in both versions — the normal registry posture — and a
registered recipe ships its dedicated MCP tool in the same change, so
the listing never advertises a behaviour an agent cannot reach. Caveats
are retired rather than relabeled (a recipe registers under its honest
name for what it actually computes). A recipe registered in the catalog
is registered in both versions or in neither — the anchor never sees a
recipe present in one version and absent from the other. The catalog
currently lists **18 recipes**: the 2 foundational recipes (grounded_synthesis,
migration_benchmark), the 14 reasoning lenses, and the 2 analytics lenses
(association_rules, formal_concepts).

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
versions realise the complete recipe surface — the two foundational recipes
and the fourteen lens recipes — with matching recipe names, descriptors, and
result shapes, and bit-for-bit-equal numeric results on shared vectors where
a lens recipe surfaces a deterministic reasoning result. A recipe present in
one version and absent from the other is non-conformant.

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
deterministic (`NEURONKIT_SPEC_v0.85` C-Det).

---

*End of CognitionKit Specification v0.85.*
