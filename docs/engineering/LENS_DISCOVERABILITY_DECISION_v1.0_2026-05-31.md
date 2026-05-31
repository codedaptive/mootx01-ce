# Lens Discoverability — Architecture Decision Memo

**ID:** LENS_DISCOVERABILITY_DECISION_v1.0_2026-05-31
**Author:** Kong (architecture review, read-only)
**Date:** 2026-05-31
**Status:** RECOMMENDATION — Bob decides
**Scope:** `packages/kits/CognitionKit`, `packages/kits/NeuronKit`, `apps/ARIA_MCP`

---

## Assessment

Fourteen net-new reasoning lenses have been built in the Rust substrate,
each as a NeuronKit reasoning surface over gated SubstrateML/GLK math plus
a CognitionKit recipe that sequences GLK verbs. They are Rust-only and
green under inline `#[cfg(test)]` fixtures. They are also **invisible and
uninvokable** outside their own test modules: the only discovery surface
(`RecipeCatalog`) is the Swift port's, the only invocation path (ARIA_MCP)
links the Swift packages only, and the Rust crates ship as `[lib]` with no
binary, no FFI, and no MCP server. The decision is not "how do we list the
lenses" — it is "do these lenses graduate to the shipped, conformance-
anchored surface, or do they remain an exploratory Rust layer with no
runtime caller yet." The catalog conformance anchor is the constraint that
makes this a real decision rather than a one-line edit.

---

## Verified facts (read from source 2026-05-31)

| Claim | Verified |
|---|---|
| 14 Rust CognitionKit lens recipes (`*_recipe.rs`) | YES — exactly 14 |
| Lenses absent in Swift CognitionKit | YES — Swift has only GroundedSynthesis, MigrationBenchmark, MigrationOrchestration, MigrationRanking, NeuronKitCapability, Recipe, RecipeCatalog, RecipeError |
| Lens reasoning surfaces present in Rust NeuronKit, absent in Swift NeuronKit | YES — 9 `pub fn` surfaces (keystones, latent_themes, drift, anomaly_scan, constellation, theme_weather, partial_recall, anticipation, mind_overlap, spreading_activation, bias); zero matching Swift `func`s |
| `recipe_catalog()` (Rust) registers ONLY `grounded_synthesis` + `migration_benchmark` | YES — `catalog.rs` L33-59; test L78-83 asserts exactly that sorted set |
| Catalog header declares byte-for-byte Swift parity is "the strongest conformance anchor in this crate" | YES — `catalog.rs` L1-11 |
| Swift `RecipeCatalog.all` = `[GroundedSynthesis(), MigrationBenchmark()]` | YES — `RecipeCatalog.swift` L62-65 |
| `moot_list_recipes` reads `RecipeCatalog.all` | YES — `RecipeTools.swift` L192-193 |
| Each MCP recipe tool hard-binds to a specific Swift recipe type (no generic run-by-name) | YES — `RecipeTools.swift` dispatch L160-185 calls `GroundedSynthesis().run`, `MigrationBenchmark().run/.confirmPromotion` directly |
| ARIA_MCP depends on Swift kits only; no Rust/FFI/uniffi linkage | YES — `Package.swift` imports `NeuronKit`/`CognitionKit` Swift packages; no FFI line |
| Rust kit crates are `[lib]` only — no `[[bin]]`, no MCP, no FFI | YES — `Cargo.toml` for both crates |
| `confirm` verb (the cited precedent) exists in BOTH Swift and Rust GLK | YES — present in `VerbSurface.swift` and Rust `verbs/surface.rs`, `branches.rs`, `coordinator.rs` |
| Lens recipes carry no capability gate, return lens-specific types | YES — e.g. `run_keystones` (`keystones_recipe.rs` L14-16, L30-35): "No capability gate… composes a structural graph read," returns `Vec<Keystone>` |

Two facts worth stating plainly because they reshape the options:

1. **There is no Rust runtime caller of these lenses, anywhere.** Not a
   binary, not an FFI export, not an MCP server. They run only inside
   `cargo test`. "Discoverable in Rust now" (the pitch for Option 2)
   means discoverable to *another Rust crate at compile time* — not to
   any agent or MCP client. That is a narrower benefit than it sounds.

2. **Listing a recipe does not make it invokable.** Even on the Swift
   side, `moot_list_recipes` enumerates the catalog, but each recipe is
   *invoked* through its own purpose-built MCP tool that hard-binds to a
   Swift recipe type. There is no generic "run the recipe named X"
   dispatcher. So promoting a lens to discoverability is two commitments,
   not one: a catalog descriptor **and** a Swift recipe body **and** (for
   invocation) a dedicated MCP tool.

---

## The doctrine, as written vs. as observed

The parity rule cited in the spawn does not live in a top-level CLAUDE.md
in this repo (there is none); it lives as crate-header framing
(`cognition-kit` Cargo.toml, `lib.rs` L4-5: "Per CLAUDE.md neither port
leads") and is corroborated by the observed pattern:

- **Shipped-surface stubs present in BOTH ports → implemented
  symmetrically.** Evidence: `confirm` is live in Swift and Rust GLK.
- **NET-NEW reasoning behaviours → Rust-first only.** Evidence: every
  lens recipe header (`keystones_recipe.rs` L6-10) explicitly says
  "NET-NEW, Rust-first… A Swift parity port follows the spec this
  establishes."

The doctrine is sound and the lenses are correctly on the Rust-first side
of it. Nothing here is drift. The open question is *graduation*, which the
doctrine names ("a Swift parity port follows") but does not gate.

> **Stale-comment flag (not this memo's to fix):** `CognitionKit/rust/src/lib.rs`
> L20-25 still claims the estate-driven recipe bodies are "NOT ported
> here" and that closing the gap "is Pass 2" — yet the module list
> immediately below registers all 14 lens recipes plus live migration.
> That header contradicts the file's current contents and will mislead
> the next agent (comment-fidelity rule). Worth a one-line follow-up
> mission; out of scope for a doc-only review.

---

## Option assessment

### Option 1 — Port each lens to Swift, promote to shipped catalog recipes

| Dimension | Assessment |
|---|---|
| Conformance anchor | Preserved and extended — Swift leads, Rust follows, catalog grows in lockstep |
| MCP / agent discoverability | Full — appears in `moot_list_recipes`, *if* also given an MCP tool |
| Maintenance + fixture cost | Highest — 14 lenses × (Swift recipe + Swift NeuronKit surface + shared fixtures + per-lens MCP tool). Roughly doubles the kit-layer surface and the fixture corpus in one stroke |
| Parity doctrine | **Contradicts it.** Doctrine says NET-NEW reasoning is Rust-first *until it earns* parity. Porting all 14 pre-emptively treats exploratory work as shipped before any has proven its worth |
| Invocation | Still requires 14 new MCP tools or one generic dispatcher; listing alone does not invoke |
| Graduation criteria | None applied — promotes the whole batch indiscriminately |

The cost is not negligible, and it is incurred for lenses that have never
been invoked outside a test. This is the expensive option done at the
wrong time.

### Option 2 — Separate Rust-only `lens_catalog()` distinct from `recipe_catalog()`

| Dimension | Assessment |
|---|---|
| Conformance anchor | Preserved — the parity-gated `recipe_catalog()` is untouched |
| MCP / agent discoverability | **None today.** A Rust `lens_catalog()` is visible only to Rust callers at compile time. ARIA_MCP does not link Rust. So this delivers discoverability to no agent and no MCP client until an FFI/Rust-MCP story exists — which does not |
| Maintenance + fixture cost | Moderate — one new registry + descriptors + a fixture asserting the set. But it must be kept in sync with 14 recipes by hand |
| Parity doctrine | Neutral-to-risky — introduces a NEW discovery pattern (a second registry) that future lens authors will follow. Two parallel registries with the same shape and different membership invariants is a known drift generator |
| Invocation | Unchanged — no generic dispatcher exists in Rust either |
| Graduation criteria | None — and worse, it creates a comfortable holding pen that *removes* the pressure to graduate |

The non-obvious problem with Option 2: it spends real design budget to
build a registry whose only consumer (compile-time Rust) does not need a
registry to call a `pub fn`, and whose intended consumer (an agent over
MCP) cannot reach it. It manufactures the *appearance* of discoverability
without the substance. That is the most dangerous kind of architecture
decision — it looks like progress and commits the codebase to a second
registry pattern that someone has to reconcile later.

### Option 3 — Leave the lenses as an exploratory Rust-first layer

| Dimension | Assessment |
|---|---|
| Conformance anchor | Preserved — no change |
| MCP / agent discoverability | None — honestly so. The lenses are what they are: a proven, tested, Rust-first exploratory layer |
| Maintenance + fixture cost | Zero new cost; existing fixtures stand |
| Parity doctrine | Matches it exactly — Rust-first, parity port follows when earned |
| Invocation | None today (consistent with their status) |
| Graduation criteria | Deferred — which is the gap |

The honest option. Its only weakness is that "revisit per-lens later"
without a written trigger tends to mean "never revisit," and 14 tested
behaviours quietly rot into dead code.

---

## The option nobody named: a graduation gate (Option 3 + a written trigger)

The three framed options conflate two questions that should be separate:

1. *Are the lenses shipped?* — No. Correctly Rust-first per doctrine.
2. *How does a lens stop being exploratory and become shipped?* — Unwritten.

Neither Option 1 (graduate all now) nor Option 2 (build a parallel home so
they never have to graduate) answers (2). The missing artifact is a
**graduation pipeline**: a short, written checklist that moves ONE lens
from exploratory to shipped when it earns it, and that — when it fires —
naturally does the Option-1 work for that single lens (Swift recipe +
NeuronKit surface + shared fixture + catalog entry + MCP tool), preserving
the conformance anchor by construction because Swift and Rust land
together for that lens.

A lens graduates when ALL hold:

1. **A product or agent workflow names it as a required behaviour** (pull,
   not push — the lens is wanted, not just built).
2. **Its v1 caveats are retired, not relabeled.** (This repo already has
   the scar tissue: Anticipate and MindOverlap shipped proxies under the
   real names and had to be rebuilt. A lens with an open "reads both
   estates directly instead of the privacy-preserving federation" caveat
   has not earned the shipped name.)
3. **It fits the capability-gated descriptor model** — or its departure
   from that model is a deliberate, documented decision. Today the lenses
   do NOT fit: `run_keystones` and its siblings carry no capability gate
   and compose graph reads rather than declared `NeuronKitCapability`
   reasoning functions. The shipped catalog descriptor requires
   `requiredCapabilities`. Graduating a lens means either giving it real
   capabilities or extending the descriptor model — a decision in itself.
4. **A Swift parity port lands in the same change as the catalog entry**,
   so the anchor never sees a Rust-only registered recipe.

This is Option 3 today (no premature cost, doctrine-aligned) with the one
thing Option 3 lacks: a written door out, so the lenses don't rot.

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| 14 tested behaviours become dead code (no caller, no graduation trigger) | Med | Graduation gate makes "exploratory" a state with an exit, not a grave |
| Option 2 builds a second registry that drifts from `recipe_catalog()` | High (if Option 2 taken) | Do not introduce a parallel registry until there is a consumer that needs one |
| Adding lenses to `recipe_catalog()` to "make them discoverable" silently breaks the conformance anchor and the asserting test | High | Anchor is test-guarded today; the danger is a future agent treating the catalog as a free-for-all list. Document that the catalog is the shipped/parity surface, not a feature inventory |
| Descriptor model mismatch discovered only at graduation time | Med | Named here: lenses are uncapability-gated and return heterogeneous types; resolve the model question before, not during, the first graduation |
| Listing ≠ invoking; a graduated lens appears in `moot_list_recipes` but errors when called | Med | Graduation checklist requires the MCP tool + Swift recipe body, not just the descriptor |

**Non-obvious risk (the one nobody named):** the pitch for Option 2 is
"makes lenses discoverable in Rust now." But there is no Rust runtime — no
binary, no FFI, no Rust MCP server. The only Rust consumer is another
crate at compile time, which calls a `pub fn` directly and needs no
registry. So Option 2's headline benefit is illusory: it delivers
discoverability to an audience that does not exist and cannot reach the
intended audience (agents over MCP, which speak only to the Swift port).
Whoever evaluates Option 2 should ask one question first — *who reads
`lens_catalog()`?* — and the honest answer today is "a test."

---

## Dependencies

- **Depends on:** the Swift `RecipeCatalog` ↔ Rust `recipe_catalog()`
  byte-for-byte conformance anchor (`catalog.rs`, `RecipeCatalog.swift`);
  the Swift-only ARIA_MCP linkage (`apps/ARIA_MCP/Package.swift`); the
  per-recipe MCP tool pattern (`RecipeTools.swift`); the NET-NEW-is-Rust-
  first parity doctrine (crate headers; observed `confirm`-in-both
  precedent).
- **Affects:** any future lens author (sets the precedent for whether
  lenses get a registry); ARIA_MCP's tool surface if/when a lens
  graduates; the fixture corpus.
- **Conflicts with:** Option 2 conflicts latently with `recipe_catalog()`
  by standing up a sibling registry; Option 1 conflicts directly with the
  Rust-first doctrine.

---

## Recommendation

**ACCEPT WITH CONDITIONS — adopt Option 3 (leave the lenses exploratory),
plus a written graduation gate. Reject Option 1 and Option 2 as currently
framed.**

Reason, one line: the lenses are correctly Rust-first per doctrine; the
only real gap is the absence of a written door out, and neither premature
batch-porting (Option 1) nor a consumer-less parallel registry (Option 2)
addresses that gap.

Conditions:

1. **Do not add lenses to `recipe_catalog()`.** The anchor stays exactly
   `grounded_synthesis` + `migration_benchmark` until a lens graduates
   with its Swift port in the same change.
2. **Do not build `lens_catalog()`** until a concrete consumer needs it.
   A `pub fn` is its own discovery surface for the only caller that exists
   (compile-time Rust).
3. **Write the graduation gate** (the four criteria above) as a short
   engineering note so "exploratory" has an exit. This is the actual
   deliverable that closes the gap.
4. **Resolve the descriptor-model question before the first graduation:**
   decide whether lenses get real `requiredCapabilities` or whether the
   descriptor model is extended for uncapability-gated structural recipes.
5. **Separately, fix the stale `lib.rs` header** (Pass 2 / "not ported
   here" no longer true). Comment-fidelity follow-up, not part of this
   decision.

If a single lens has a named consumer today, the right move is not Option
1 or 2 — it is to graduate *that one lens* through the gate (Swift recipe
+ NeuronKit surface + shared fixture + catalog entry + MCP tool, landed
together). That is bounded, anchor-safe, and earns the cost one behaviour
at a time.

### Sign-off routing

- **Safe to proceed without Bob:** keeping the lenses as-is (the default);
  fixing the stale `lib.rs` comment.
- **Needs Bob's sign-off:** writing the graduation gate as doctrine (it
  sets fleet precedent for how exploratory substrate work graduates);
  any decision to extend the `RecipeDescriptor` capability model; any
  first lens graduation (it is the first Swift port of a NET-NEW lens and
  spends the conformance-fixture budget).

---

## Notes for the audit trail

- The conformance anchor is currently the *only* thing forcing Swift/Rust
  catalog parity, and it is guarded by a single assert
  (`catalog.rs` L78-83). If that test is ever relaxed, the anchor is gone
  silently. Treat the catalog as the shipped/parity surface, never as a
  feature inventory.
- The repo has prior scar tissue on shipping-before-earning: Anticipate
  and MindOverlap shipped proxies under their real names and had to be
  rebuilt (memory: lens arc, 2026-05-31). The graduation gate's caveat-
  retirement criterion exists because of that incident.
- "Discoverable in Rust" and "discoverable to an agent" are different
  claims in this codebase because Rust has no runtime and MCP links only
  Swift. Any future memo proposing Rust-side discovery should state which
  one it means.
- If the Rust crates ever grow an FFI or a Rust MCP server, this decision
  should be revisited — that single change would make Option 2's premise
  real and is the only thing that would.
