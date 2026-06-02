# Completion Report — AR_FCA_CAPABILITY_001

**Mission:** AR_FCA_CAPABILITY_001 — finish AssociationRuleMining and FormalConceptAnalysis as full capabilities
**Status:** COMPLETE
**Branch:** stream/ar-fca-capability-001 (worktree agent-af45c347e2d48a0ec)

---

## What Was Done

**BRR commit:** `04ef54c` docs(blast-radius): AR_FCA_CAPABILITY_001 Blast Radius Report

**Part 3+4 (Swift):** `f8100c6`
- NeuronKitCapability.swift: +.associationRuleMining, +.formalConceptAnalysis
- capability.rs: +AssociationRuleMining, +FormalConceptAnalysis; ALL size 6→8;
  raw_value() match; +new_capabilities_appear_in_all_and_shipped test
- AssociationRules.swift: full recipe (recall → per-call label table → MatrixO →
  mineAssociationRules → relabeled output)
- FormalConcepts.swift: full recipe (recall → FormalContext → BoundedConceptMiner →
  drawer-ID relabeled output)
- RecipeCatalog.swift: +AssociationRules(), +FormalConcepts() (4 entries)
- AssociationRulesTests.swift: 5 tests (empty, co-occurring, threshold, capability, determinism)
- FormalConceptsTests.swift: 5 tests (empty, two cohorts, fields populated, capability, determinism)
- CapabilityGateTests.swift: +capability_metadata_is_declared test
- RecipeCatalogTests.swift: updated sorted name list to 4 entries

**Part 3+4 (Rust):** `d825ead`
- association_rules_recipe.rs: run_association_rules — same design as Swift; canonical
  lowercase camelCase Swift case names for all enum labels
- formal_concepts_recipe.rs: run_formal_concepts — same design as Swift; FormalAttribute
  namespace:"locus" + lowercase camelCase values
- catalog.rs: +association_rules +formal_concepts (4 entries); byte-identical descriptor
  strings; +association_rules_descriptor_matches_swift, +formal_concepts_descriptor_matches_swift
- lib.rs: stale "Rust-first" comment updated; +pub mod + pub use for both recipes
- NeuronKit lib.rs: pub use re-exports for mine_association_rules, AssociationRule, Item,
  MiningThresholds, BoundedConceptMiner, FormalAttribute, FormalConcept, FormalContext, fca alias

**Part 5 (MCP tools):** `4a8b097`
- RecipeTools.swift: +moot_association_rules, +moot_formal_concepts; isRecipeTool covers 6;
  tools() returns 6; dispatch routes both; doubleArg() helper added
- RecipeToolsTests.swift: sorted list updated to 6 names; +3 dispatch tests

**Doc update:** `2077aaa`
- COGNITIONKIT_SPEC_v0.85: +Analytics (category 10) in § 4.2; § 8 updated to v2.0; relates_to updated
- COGNITIONKIT_INTERFACE_v0.85: § 3 capability enum updated; § 6 Analytics category + full signatures +
  label vocabulary contract; § 7 catalog listing updated to 4 entries

---

## Kong Design Rulings (AR_FCA_CAPABILITY_001)

**Part 1 — Estate-read seam for mineAssociationRules:**

RULING: Option (c) — recipe-side fold now, GLK accessor as follow-up.

Rationale (Bilby analysis, no conflict found requiring Kong spawn):
- GLK's MatrixTier.coOccurrence is private to EnrichmentPipeline with no public accessor.
  Adding a GLK verb accessor is a separate mission with blast radius on the GLK package.
- The latent_themes_recipe.rs pattern establishes the precedent: build co-occurrence from
  recalled drawers' field-value labels within the recipe, using the GLK recall verb.
- The recipe-side fold is coherent as a "conscious read" per COGNITIONKIT_SPEC § 1.1:
  the recipe mines rules from the recalled frame, not from the full estate-lifetime history.
  The N semantics are: N = recalled drawer count (honest, documented).
- No design conflict warranting Kong spawn was found; the established pattern was unambiguous.

Follow-up queued: GLK matrix accessor mission (expose coOccurrence + liveRowCount via
a new GLK read verb surface, enabling the live-matrix semantics with decay history).

**Part 2 — Packed-item mapping:**

RULING: Per-call sorted label→index table, value=1 (presence items), 64-label cap.

Mapping:
- Each drawer contributes 4 labels: "kind:{caseName}", "channel:{caseName}",
  "sensitivity:{caseName}", "room:{roomString}"
- CaseName = canonical lowercase camelCase Swift case name (substrate vocabulary § 4.2)
  NOT Rust PascalCase Debug names (the Swift names are canonical in BOTH legs)
- Sort distinct labels alphabetically → assign field index 0..63 (max 64 per MatrixO constraint)
- value=1 for all presence items (field index IS the label identity; value distinguishes nothing)
- Overflow rule: if >64 unique labels, first 64 alphabetically are indexed; overflow labels
  silently dropped for affected rows; labelOverflow=true in output; total and deterministic

Rationale: The MatrixO precondition (field < 64) is a hard constraint. The per-call sorted
table is deterministic within a call, requires no global enum enumeration, and handles open-ended
room strings without a global registry. The canonical label strings match the SPEC § 4.2
requirement to use "the axis's own canonical names as fixed by the substrate vocabulary."

---

## Test Verification Log

### Baseline (captured before mission start)
- CognitionKit swift test: 41 tests in 9 suites (exit 0)
- CognitionKit cargo test: 62 tests (exit 0)
- NeuronKit swift test: 152 tests in 18 suites (exit 0)
- NeuronKit cargo test: 157 tests (exit 0)
- ARIA_MCP swift test: 41 tests in 7 suites (exit 0)

### Final (post-commit 2077aaa, pre-signal)

**CognitionKit swift test:** exit 0, 52 tests in 11 suites (+11), all passing
```
Test run with 52 tests in 11 suites passed after 0.037 seconds.
```

**CognitionKit cargo test:** exit 0, 75 tests (+13), all passing
```
test result: ok. 75 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.02s
```

**NeuronKit swift test:** exit 0, 152 tests in 18 suites (unchanged), all passing
```
Test run with 152 tests in 18 suites passed after 0.036 seconds.
```

**NeuronKit cargo test:** exit 0, 157 tests (unchanged), all passing
```
test result: ok. 157 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```

**ARIA_MCP swift test:** exit 0, 44 tests in 7 suites (+3), all passing
```
Test run with 44 tests in 7 suites passed after 0.037 seconds.
```

**check-mirrored-vectors.py:** exit 0

---

## Self-Review

### Step 0 — Blast Radius Scope Check
- Blast Radius Report: docs/blast_radius/AR_FCA_CAPABILITY_001_BLAST_RADIUS.md
- Purely additive mission — N/A for MUST_UPDATE file tracking
- All 18 diff files match the BRR declared scope exactly

### Standard Checks
- Files changed: 18 (all within BRR declared scope)
- Scope: all within mission scope
- Secrets: none found
- Orphan code: none
- Prohibited Blast Radius patterns: none (no bridges, no shims, no orphan deprecations,
  no TODO/FIXME on changed symbols)
- Stale "Rust-first" comment in CognitionKit lib.rs: updated to v2.0 posture

---

## Discoveries

1. **MatrixO 6-bit constraint (field < 64):** The CooccurrenceKey precondition in both
   Swift and Rust asserts `field < 64` and `value < 64`. This bounds the label vocabulary
   at 64 entries per call. The 255-overflow rule originally planned was wrong; 64 is correct.

2. **latent_themes Rust uses Debug-format strings:** `format!("kind:{:?}", d.content_kind())`
   produces PascalCase (e.g. "kind:Prose"). This violates COGNITIONKIT_SPEC § 4.2's requirement
   for canonical substrate vocabulary names. The AR and FCA recipes use lowercase camelCase Swift
   names instead. The latent_themes recipe's label strings are technically non-conformant per the
   spec — worth a cleanup mission for that recipe.

3. **CognitionKit lib.rs stale comment:** The "Rust-first reasoning lenses" comment referenced
   the v1.0 graduation gate. Updated to v2.0 posture as part of this mission.

4. **NeuronKit Rust lib.rs had no re-exports for AR/FA:** The `pub mod` declarations existed but
   no `pub use` re-exports. Added re-exports so CognitionKit can reference them cleanly.

---

## Follow-up List

1. **GLK matrix accessor mission** — add a public read accessor on GeniusLocusKit/EstateCoordinator
   that exposes the MatrixTier's coOccurrence and liveRowCount. Enables live-matrix semantics with
   decay history for the AssociationRules recipe. Blast radius: GLK package (both legs).

2. **Rust MCP server tools for moot_association_rules and moot_formal_concepts** — sequenced
   AFTER ARIA_MCP_RUST_001 merges. That mission is building the Rust MCP server right now.
   Both recipe tools must be added to the Rust server once it ships.

3. **latent_themes label cleanup** — the existing `run_latent_themes` in Rust uses Debug-format
   strings ("kind:Prose") instead of canonical lowercase Swift names ("kind:prose"). Minor spec
   violation per § 4.2. Consider a cleanup mission.

4. **14 lens recipes Swift legs** — the 14 existing Rust lens recipes still need Swift legs per
   LENS_DISCOVERABILITY_DECISION_v2.0. This mission adds AR+FCA; the 14 lenses are a separate
   effort (likely a series of missions).
