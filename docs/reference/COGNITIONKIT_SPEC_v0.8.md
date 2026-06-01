---
status: specification, v0.8
authors: Bob Pankratz (via/ claude)
date: 2026-05-31
version: 0.8
package: CognitionKit
kind: Kit
supersedes: COGNITIONKIT_SPEC_v0.1.md
relates_to:
  - COGNITIONKIT_INTERFACE_v0.1.md (the API surface this spec contracts)
  - NEURONKIT_SPEC_v0.8.md (NeuronKit provides the algorithms CognitionKit calls)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md (substrate contract; §33 scopes products out, §1305–1308 the write-verb provenance)
  - GENIUSLOCUS_ENGINEERING_COOKBOOK_v1.0_2026-05-28.md (§2.5 provenance bits; §3124 calibration update)
  - LENS_DISCOVERABILITY_DECISION_v1.0_2026-05-31.md (lens catalog + graduation)
---

# CognitionKit Specification — v0.8

CognitionKit is the **behaviour-recipe layer** of the GeniusLocus / MOOTx01
substrate. It assembles NeuronKit reasoning and GeniusLocusKit verbs into named,
reusable behaviours. **It contains no algorithms of its own** — a recipe that
implements an algorithm has leaked across its boundary; that algorithm belongs in
NeuronKit.

This version consolidates what was discovered after v0.1: the three placeholder
recipes proved out, and on top of them we built fourteen **reasoning lenses**.
v0.8 records the full set in one place and — for the first time — **classifies
every element by the active/subconscious gate** below.

---

## § 1 — The placement gate (active vs subconscious)

This is the rule that decides whether a thing lives in NeuronKit or CognitionKit.

- **NeuronKit is the subconscious** — the *autonomic* layer. Automated,
  set-it-and-forget-it algorithm trees live here, alongside the raw algorithm
  nodes. The subconscious runs *itself*, two ways: off its own **deterministic
  scheduler**, or off an **internal feedback loop** that computes an "intent" to
  act.

- **CognitionKit is active thinking** — the *deliberate* layer. It acts on intent
  from outside, and it can reach *down* into the subconscious and change how it
  behaves by routing an **alter-behavior directive** down to NeuronKit.

A subconscious (NeuronKit) tree is therefore triggered or modified from exactly
**three places**:

1. a directive sent **down from CognitionKit** (active thinking altering the
   subconscious),
2. NeuronKit's own **deterministic scheduler**,
3. NeuronKit's own **internal feedback loop** (a computed "intent").

**Rule of thumb.** Does it run on its own — scheduled or feedback-driven? →
NeuronKit (subconscious). Is it a deliberate act driven by intent from outside? →
CognitionKit (active thinking). The sort is **active vs automated**, *not*
one-step-vs-many-steps: an automated tree of many steps is still subconscious.

A single analysis can have **both** faces: an automated form that the subconscious
runs continuously (NeuronKit) and a deliberate on-demand form a caller invokes
(CognitionKit). When it does, it is split across the two kits, not duplicated.

---

## § 2 — The Recipe protocol

Every CognitionKit recipe is a deliberate behaviour with a declared capability
set, run against a passed-in estate. It owns no estate and instantiates no
NeuronKit; both are handed in.

```
Recipe:
  name, version, description
  requiredCapabilities: [NeuronKitCapability]   // verified before any execution
  run(input, estate, kit) -> Output             // estate = EstateHandle; kit = GeniusLocusKit
```

The capability set is checked at the start; a recipe that cannot be fully executed
fails immediately (`RecipeError.missingCapability`) and never partially runs.

> **Note (corrects v0.1):** there is no `NeuronKitHandle` type. Recipes take an
> `EstateHandle` plus the `GeniusLocusKit` kit and call NeuronKit statically. The
> Rust port realizes recipes as `run_*` functions returning typed `Result`s; the
> Swift port as `Recipe`-conforming types.

---

## § 3 — The behaviour catalog

### § 3.1 — Foundational recipes

These are deliberate, intent-driven behaviours → **CognitionKit (active thinking)**.

| Recipe | Purpose | Status |
|---|---|---|
| **MigrationBenchmark** | Derive one branch per migration plan, benchmark each against the origin corpus (zero-silent-loss gate), rank survivors, gated-promote the winner. | Shipped (Rust + Swift) |
| **GroundedSynthesis** | Hybrid-recall a query and synthesize the recalled drawers into one grounded context document. | Shipped (Rust + Swift) |
| **ScenarioSkill** | From 5 structured answers, derive two scenarios, run them, surface findings, save a preference profile. | Designed; blocked on absent NeuronKit surfaces (`elicitFraming`, `saveScenarioProfile`) |

**Removed in v0.8: `FulcrumDailyFraming`.** It was product bleed-through —
`GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md` §33 scopes Fulcrum (and every application
atop the substrate) **out**. It is also unscorable by the substrate: the
tournament scores fidelity against a **reference corpus**, and competing framings
of an unfinished day have none; its real success signal (obligation
state-progression, reward) is a *product-domain* signal, not a substrate one. The
generic capability it implied (run competing branches → tournament → gated
promote) already exists as MigrationBenchmark; the obligation-domain specialization
belongs in the Fulcrum product layer, not here.

### § 3.2 — Reasoning lenses (14)

Named reasoning behaviours that sequence gated SubstrateML math (via a NeuronKit
surface) over the estate. **Built Rust-only — Rust led, which violates the
Swift-leads doctrine (§ 8).** They have no Swift design surface, are therefore not
shipped, and are absent from the parity-anchored recipe catalog (§ 9). Each
requires a Swift design surface authored first before it can graduate (§ 9–10).
As structured, each lens recipe is invoked by intent → CognitionKit; each rests on
a NeuronKit algorithm surface (subconscious node).

The category numbers are those used in the lens headers. **Lens 3 is reserved**
(the numbering has always skipped it; left open for a future category).

| Lens | Category | NeuronKit surface | SubstrateML primitive | Question it answers |
|---|---|---|---|---|
| Keystones | 1 Structure | `keystones` | eigenvalue_centrality | Which memories are the load-bearing hubs? |
| Constellation | 1 Structure | `constellations` | community_detection (Louvain) | What clusters formed that I never named? |
| FreeAssociation | 1 Structure | `spreading_activation` | random_walks | What does this memory remind me of? |
| LatentThemes | 2 Topics | `latent_themes` | NMF | What themes underlie the co-occurrence? |
| ThemeWeather | 2 Topics | `theme_weather` | decay | Which themes are rising vs fading? |
| Bias | 4 Preference | `representation_bias` / `learned_preference` | (share diff) / bradley_terry | What do I lean toward, away from, actually keep? |
| Drift | 5 Surprise | `drift` | info_theory (KL / JS) | How far has the distribution moved? |
| Contradiction | 5 Surprise | `anomalies` | anomaly (z-score) | Which memory is the odd one out? |
| TrustLens | 6 Grounding/Trust | (synthesize + provenance) | — | How well-grounded is this set, by source? |
| FeelsLike | 7 Associative | `partial_recall` | partial_state_recall | What matches on these facets but differs on those? |
| Anticipate | 8 Prediction | `anticipate` | action_outcome | To reach Y, what action tends to work? |
| TunnelSuccessor | 8 Prediction | (synthesize) | (tunnel-graph read) | What tends to follow this, by explicit links? |
| MindOverlap | 9 Federated | `dp_summary` / `summary_overlap` | dp_or_reduce | Where do two minds converge, privately? |
| EstateDivergence | 9 Federated | (room-dist read) | — | How do two estates' distributions differ? |

### § 3.3 — Classification (active vs subconscious)

The gate (§ 1) applied to every element. "As-built" = where it lives today;
"Target" = where the gate puts it. Most are already filed correctly.

| Element | As-built | Target | Note |
|---|---|---|---|
| 14 lens **surfaces** (`keystones`, `drift`, …) | NeuronKit | NeuronKit | Algorithm nodes. ✔ |
| 14 lens **recipes** (`run_keystones`, …) | CognitionKit | CognitionKit | Deliberate, intent-invoked reads. ✔ |
| Foundational recipes (Migration, GroundedSynthesis) | CognitionKit | CognitionKit | Deliberate behaviours. ✔ |
| **Dreaming daemon** | NeuronKit | NeuronKit | Automated tree (scheduler + feedback). Subconscious. ✔ |
| **Maintenance daemon** | NeuronKit | NeuronKit | Automated aging/drift tree. Subconscious. ✔ |
| `benchmark`, `rank_tournament`, `bradley_terry` | NeuronKit | NeuronKit | Algorithm nodes. ✔ |
| `run_tournament` (benchmark-all-then-rank) | NeuronKit | NeuronKit | Automated, self-runnable tree → subconscious. ✔ |
| `migration_ranking::rank` (score/sort math) | CognitionKit | **NeuronKit** | **Delta** — duplicates `rank_tournament`; the math is a node. Move; keep only recipe glue. |
| `migration_ranking::{first_duplicate, partition_origin, lost_concepts}` | CognitionKit | CognitionKit | Recipe glue (input guard, surfacing). ✔ |

**One delta** (deferred, § 10): the pure score/sort in `migration_ranking` belongs
in NeuronKit (it duplicates `rank_tournament`); the recipe keeps only its glue.

**Split candidates** (future, not now): lenses whose nature is continuous
monitoring — **Drift, Contradiction, ThemeWeather, Anticipate, Calibration** —
could grow an *automated* subconscious form in NeuronKit (the dreaming daemon
recomputing them) alongside the deliberate CognitionKit read. Recorded as
candidates; not split today.

---

## § 4 — The confidence lifecycle

Confidence (provenance bits 24–29, cookbook §2.5) is not set at capture by
accident — it is set by the **writing verb**, then maintained by the subconscious.

**Injected by the verb** (`GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md` §1305–1308):

| Verb | Confidence at inject |
|---|---|
| `capture` | `unknown` — verbatim user content makes no confidence claim (null *by design*) |
| `propose` | the proposing daemon's reported value |
| `learn` / import | `medium-high`; **missing-on-import → default behavior → treat as simple/new** |
| `associate` | per the association's signal-source weights |

**Maintained over time by the subconscious:** the **dreaming daemon** recomputes
the calibration curve on a slow cadence and consolidates (EWC++ — a consolidated
confidence decays unless reinforced); the **maintenance daemon** applies decay and
drift. The loop is *closed* by **confirm-verb outcomes** feeding
`update_calibration(model_id, claimed_confidence, outcome.success)` (cookbook
§3124).

**Consequence for the Calibration lens (§ 10):** it is the *read surface* over the
dreaming daemon's calibration curve. It needs `propose` (to inject varied
confidence) and the dreaming loop live — it is **not** blocked by a missing
capture parameter.

---

## § 5 — Control flow (the down-directive)

The gate (§ 1) implies a one-way control path the substrate already honors:

- The subconscious (NeuronKit) **runs itself** — its scheduler and feedback loops
  fire its automated trees with no caller.
- Active thinking (CognitionKit) **reaches down**: it issues an *alter-behavior
  directive* to NeuronKit to change what the subconscious does (e.g., adjust a
  daemon policy), and it invokes NeuronKit nodes/trees on demand.
- CognitionKit never reads or writes the substrate directly (§ 7, B-2); it goes
  through NeuronKit or the passed estate handle.

---

## § 6 — Error model

- Swift recipes raise `RecipeError` (`missingCapability`, `insufficientBranches`,
  `silentConceptLoss`, `tournamentNoWinner`, `userConfirmationRequired`).
- Rust recipes return typed results: `RecipeError` for the foundational recipes;
  the lenses return `RecipeRunError { Recipe, Substrate }`, with `SubstrateError`
  wrapping a failed recall/verb. A recall failure surfaces as
  `RecipeRunError::Substrate`, never a silent empty result.
- `silentConceptLoss` is non-recoverable in MigrationBenchmark; the recipe never
  proceeds past a detected concept loss.

---

## § 7 — Behavioral contracts

- **B-1** Recipes implement no algorithms; computation delegates to NeuronKit.
- **B-2** Recipes have no direct substrate access; every read/write goes through
  NeuronKit or a passed estate handle.
- **B-3** Recipes never auto-promote/auto-discard; every destructive step is gated
  behind explicit confirmation.
- **B-4** Recipes are stateless between calls.
- **B-5** Capability declarations are verified before execution.
- **B-6** Lenses are **read-only** and **deterministic** — no `Date()`/random; a
  clock value (`now`) is passed in and any walk/DP seed is derived (e.g. FNV), so
  a lens is a pure function of its inputs.

---

## § 8 — Conformance + parity

- **C-1..C-5** (from v0.1): every recipe implements the protocol and declares its
  capabilities; no recipe calls a substrate kit directly or implements an
  algorithm; MigrationBenchmark disqualifies silent concept loss.
- **C-6 Placement gate (§ 1) is doctrine.** Every new element is classified
  active-vs-automated before it ships; automated trees land in NeuronKit, deliberate
  acts in CognitionKit.
- **C-7 Swift leads.** Swift is the design surface; every behaviour is authored in
  Swift first. Rust is secondary — it follows Swift and never leads. Both ports are
  gated against shared fixtures and may not diverge. (The 14 lenses in § 3.2 were
  authored Rust-only and are in violation of this rule — see § 10.)
- Conformance is gated by inline fixtures shared with the Swift reference where a
  Swift port exists.

---

## § 9 — Catalog and graduation

The Rust `recipe_catalog()` is a **Swift-parity conformance anchor** — its
descriptors must match the Swift `RecipeCatalog` byte-for-byte (the
`moot_list_recipes` MCP tool reads exactly these). It therefore lists only the
recipes that exist in *both* ports: today, **GroundedSynthesis** and
**MigrationBenchmark**.

The 14 lenses are **absent** from that catalog — they are Rust-only with no Swift
design surface (a Swift-leads violation, § 8); adding them would break the anchor.
§ 3.2 is the canonical lens list. A lens **graduates** into the catalog (and a
product surface) only when, per
`LENS_DISCOVERABILITY_DECISION_v1.0`: it has a named consumer; its caveats are
retired (not relabeled); it fits the descriptor model; and its Swift port lands
*with* the catalog entry so the anchor never sees a Rust-only registered recipe.

---

## § 10 — Status, backlog, and what's next

**Swift (shipped):** GroundedSynthesis, MigrationBenchmark, the Recipe protocol,
the catalog. **Rust (follows Swift):** GroundedSynthesis, MigrationBenchmark.
**Rust-only, in violation of Swift-leads (§ 8):** the 14 lenses + 11 NeuronKit
surfaces — green under inline fixtures, but with no Swift design surface;
disposition (redo Swift-first vs retain pending graduation) is Bob's call.
**Designed/blocked:** ScenarioSkill.

**Deferred reallocation backlog** (move only once the footprint is fixed — i.e.
after the unstarted lenses below land, so the move happens once):

- Consolidate `migration_ranking`'s score/sort into NeuronKit `rank_tournament`;
  leave only the recipe glue in CognitionKit (§ 3.3 delta).
- Realize any § 3.3 "split candidate" that earns an automated subconscious form.

**Unstarted lenses** (Swift design surface authored first; Rust follows):

| Lens | Primitive | Placement | Status |
|---|---|---|---|
| Cadence | fft | NeuronKit surface + CognitionKit recipe | clean — buildable now |
| Eras / temporal profile | temporal_compression / moment_summary | same | clean — buildable now |
| Calibration | calibration curve | NeuronKit surface; recipe **blocked on `propose`** + dreaming loop | blocked |
| Federated recall | tier_query | NeuronKit math + CognitionKit recipe | heavy (federation transport) |

**Reserved:** Lens 3 (category numbering hole — left open).

**Out of CognitionKit scope entirely:** any algorithm → NeuronKit; any storage →
substrate kits; cross-estate mediation → ARIA_MCP; any specific product (Fulcrum,
AI Brain, …) → that product's own layer (arch-spec §33).

---

*End of CognitionKit Specification v0.8.*
