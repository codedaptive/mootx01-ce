---
id: LENS_DISCOVERABILITY_DECISION_v2.0_2026-06-02
date: 2026-06-02
status: decision
supersedes: LENS_DISCOVERABILITY_DECISION_v1.0_2026-05-31
scope: packages/kits/CognitionKit, packages/kits/NeuronKit, apps/ARIA_MCP
---

# Lens Discoverability v2.0 — the catalog lists what ships

## What changed since v1.0

v1.0 was written when the 14 lens recipes existed in Rust only — a
Swift-leads violation — and it froze the catalog at two entries to keep
the unshipped layer out of the discovery surface. Both of v1.0's open
items are now resolved:

1. **Disposition of the Rust-first lenses (Bob, 2026-06-02):** redone
   Swift-first. The STANDARD_CODE_AUTHORING_PRACTICE remediation
   authored every Swift leg test-first; all 14 recipes have both
   versions, per-file peer tests, and the lens math is gated by the
   shared-vector artifact (NEURONKIT_SPEC § 9 C-0).
2. **Descriptor-model fit:** resolved by inspection — `RecipeDescriptor`
   carries `requiredCapabilities` as an array; a lens that sequences no
   declared capability registers with an empty array
   (`trust_grounded_synthesis` declares `[synthesize]`). No model
   extension needed.

## Decision

- **The catalog lists every recipe that ships in both versions.** This
  is the normal registry posture (a plugin/tool registry enumerates
  what exists); v1.0's graduate-one-at-a-time gate was protecting
  against unshipped Rust-only code reaching the discovery surface, and
  that hazard no longer exists.
- **All 14 lens recipes register in both catalogs in one change**, with
  byte-identical descriptors (name, version, description,
  requiredCapabilities) — the conformance anchor in `catalog.rs`
  remains the guard.
- **Every cataloged recipe gets its dedicated MCP tool** in ARIA_MCP
  (hard-bound, per the `RecipeTools` pattern; no generic run-by-name
  dispatcher). Listing and invokability ship together — `moot_list_recipes`
  must never advertise a behaviour an agent cannot reach.

## What v1.0 got right and v2.0 keeps

- **Swift leads; Rust follows; never Rust-first.** Unchanged doctrine —
  now also enforced mechanically by the authoring standard and the
  shared-vector gate.
- **The catalog parity assert** (`catalog.rs` ↔ `RecipeCatalog.all`,
  byte-for-byte) stays the conformance anchor — and `recipe_catalog()`
  is not a mirror for the assert's sake alone: it is the discovery
  surface the Rust MCP server reads, exactly as the Swift catalog
  serves ARIA_MCP.
- **No FFI, ever (immutable law).** Rust never calls Swift binaries;
  Swift never calls Rust. The corollary: each language stack must be a
  COMPLETE vertical — kits, catalog, and MCP server. The Swift vertical
  is whole (ARIA_MCP). The Rust vertical's server is the contracted
  missing piece; until it ships, the Rust legs execute only under
  `cargo test`, and that is a tracked shortfall, not doctrine.
- **Caveats retired, not relabeled.** A recipe registers under its
  honest name for what it actually computes (the
  Anticipate/MindOverlap proxy scar still applies).

## What replaces the graduation gate

The per-lens gate (named consumer + caveat retirement + descriptor fit
+ Swift-first, all before a catalog entry) is retired. Its surviving
requirements are now structural:

| v1.0 gate criterion | v2.0 enforcement |
|---|---|
| Swift authored first, Rust follows | STANDARD_CODE_AUTHORING_PRACTICE + shared-vector gate (CI) |
| Both legs land with the catalog entry | catalog parity assert (both catalogs or the test fails) |
| MCP tool ships with the listing | this decision: tool + catalog entry in the same change |
| Named consumer | dropped — a registry entry is not a roadmap commitment; consumers discover via `moot_list_recipes` |

## Consequences

1. `RecipeCatalog.all` / `recipe_catalog()` grow from 2 to 16 entries
   (2 foundational + 14 lenses), byte-identical.
2. ARIA_MCP ships 14 new hard-bound lens tools alongside the existing
   recipe tools.
3. Any FUTURE recipe follows the same rule: it registers (both
   catalogs + MCP tool, one change) when both legs ship — not before,
   and not later.
4. The Rust MCP server (the Rust vertical's counterpart to ARIA_MCP,
   linking the Rust kits and reading `recipe_catalog()`) is contracted
   work. When it ships, the per-recipe tool rule applies to it
   identically.
