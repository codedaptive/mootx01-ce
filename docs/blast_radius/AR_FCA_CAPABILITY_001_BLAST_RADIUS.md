# Blast Radius Report — AR_FCA_CAPABILITY_001

**Baseline:** CognitionKit swift test: 41 tests in 9 suites (exit 0). CognitionKit cargo test: 62 tests (exit 0). NeuronKit swift test: 152 tests in 18 suites (exit 0). NeuronKit cargo test: 157 tests (exit 0). ARIA_MCP swift test: 41 tests in 7 suites (exit 0).

**Mission:** AR_FCA_CAPABILITY_001 — finish AssociationRuleMining and FormalConceptAnalysis as full capabilities.

**Change class:** Purely additive — new enum cases, new recipe files, new catalog entries, new MCP tools. No existing symbols are renamed, removed, or semantically altered.

**Symbols being changed (additive):**

## Symbol 1: NeuronKitCapability (Swift enum)
**Change class:** additive — two new cases `.associationRuleMining` and `.formalConceptAnalysis`
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CognitionKit/Sources/CognitionKit/NeuronKitCapability.swift | 32–68 | codegraph | MUST_UPDATE | Add two new cases and update commentary |
| CognitionKit/Tests/CognitionKitTests/CapabilityGateTests.swift | 20–21 | codegraph | MUST_UPDATE | `allCases` walk auto-expands; the `shippedNeuronKitCapabilities == Set(allCases)` assertion still passes. The `first_missing_reported_in_declaration_order` test names specific cases — verify it still holds |
| CognitionKit/Sources/CognitionKit/NeuronKitCapability.swift (shippedNeuronKitCapabilities) | 67 | codegraph | INTENTIONALLY_LEFT | `Set(NeuronKitCapability.allCases)` auto-includes new cases — no change needed |
| docs/reference/COGNITIONKIT_SPEC_v0.85.md | §8 | grep | MUST_UPDATE | § 8 references v1.0 graduation gate; update to v2.0 and add the two new capability names |

### Summary
- MUST_UPDATE: 2 files
- INTENTIONALLY_LEFT: 1 (shippedNeuronKitCapabilities auto-expands)
- RESCOPE_REQUIRED: 0

---

## Symbol 2: NeuronKitCapability (Rust enum) + ALL array
**Change class:** additive — two new variants, ALL array size 6→8
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CognitionKit/rust/src/capability.rs | 19–162 | codegraph | MUST_UPDATE | Add 2 variants, update ALL (size 6→8), update raw_value() match, update raw_values_match_swift test |
| CognitionKit/rust/src/capability.rs (all_shipped_capabilities_available_by_default test) | 95–101 | codegraph | MUST_UPDATE | Test asserts `shipped_capabilities() == ALL.to_vec()` — passes automatically once ALL is updated, but verify |
| CognitionKit/rust/src/capability.rs (first_missing_reported_in_declaration_order test) | 127–145 | codegraph | INTENTIONALLY_LEFT | Test uses HybridRecall/Synthesize/Benchmark/DeriveBranch — new cases don't affect it |
| CognitionKit/rust/src/lib.rs | 55 | codegraph | INTENTIONALLY_LEFT | Re-exports NeuronKitCapability — no change needed, enum expansion is transparent |

### Summary
- MUST_UPDATE: 1 file (capability.rs)
- INTENTIONALLY_LEFT: 2
- RESCOPE_REQUIRED: 0

---

## Symbol 3: RecipeCatalog.all (Swift) — new entries
**Change class:** additive — two new RecipeDescriptor entries
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CognitionKit/Sources/CognitionKit/RecipeCatalog.swift | 62–65 | codegraph | MUST_UPDATE | Add AssociationRules() and FormalConcepts() to the .all array |
| CognitionKit/Tests/CognitionKitTests/RecipeCatalogTests.swift | various | codegraph | MUST_UPDATE | `catalog_lists_all_shipped_recipes` test has hard-coded name list — must expand to include new names |
| apps/ARIA_MCP/Tests/AriaMCPTests/RecipeToolsTests.swift | 55–60 | codegraph | MUST_UPDATE | `testRecipeToolsAppearInProjectionWithRecipeProvenance` sorted list must include the two new tool names |
| docs/reference/COGNITIONKIT_INTERFACE_v0.85.md | §6, §7 | grep | MUST_UPDATE | Recipe signatures and MCP tool roster |

### Summary
- MUST_UPDATE: 4 files
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 4: recipe_catalog() (Rust) — new entries
**Change class:** additive — two new RecipeDescriptor entries
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| CognitionKit/rust/src/catalog.rs | 33–58 | codegraph | MUST_UPDATE | Add two RecipeDescriptor entries with byte-identical strings vs Swift |
| CognitionKit/rust/src/catalog.rs (catalog_lists_all_shipped_recipes test) | 79–82 | codegraph | MUST_UPDATE | Hard-coded name list must expand |
| CognitionKit/rust/src/lib.rs | 57–68 | codegraph | INTENTIONALLY_LEFT | Re-exports run_grounded_synthesis etc — no change; we add new `pub use` for new recipe functions |

### Summary
- MUST_UPDATE: 1 file (catalog.rs; lib.rs gets additive pub use)
- INTENTIONALLY_LEFT: 1
- RESCOPE_REQUIRED: 0

---

## Symbol 5: RecipeTools (Swift MCP tool surface)
**Change class:** additive — two new tools moot_association_rules, moot_formal_concepts
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| apps/ARIA_MCP/Sources/AriaMCP/RecipeTools.swift | all | codegraph | MUST_UPDATE | Add tool names, tools() projection, isRecipeTool(), dispatch() |
| apps/ARIA_MCP/Tests/AriaMCPTests/RecipeToolsTests.swift | 55–60 | codegraph | MUST_UPDATE | Sorted list of recipe tool names |

### Summary
- MUST_UPDATE: 2 files
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 6: GeniusLocusKit matrix accessor (GLK verb surface)
**Change class:** DEFERRED — no change to GLK in this mission
**Scope:** n/a

The AR recipe builds MatrixO recipe-side from recalled drawers' field-value labels, mirroring the `latent_themes` recipe pattern. No new GLK read accessor is added to this mission. Adding a `glkCoOccurrenceMatrix()` accessor on the GLK verb surface is a follow-up mission (noted in completion report).

### Summary
- RESCOPE_REQUIRED: 0 (not attempted)
- Follow-up: RESCOPE for a future GLK matrix accessor mission

---

## Overall Summary

**Purely additive blast radius.** No existing symbols are removed, renamed, or semantically altered. The expansion of the `NeuronKitCapability` enum is the highest-impact change; all call sites tolerate the expansion without modification because they use `allCases` or open-coded for the old cases only.

| File | Change class | Classification |
|---|---|---|
| CognitionKit/Sources/CognitionKit/NeuronKitCapability.swift | additive | MUST_UPDATE |
| CognitionKit/Sources/CognitionKit/AssociationRules.swift | new file | MUST_UPDATE |
| CognitionKit/Sources/CognitionKit/FormalConcepts.swift | new file | MUST_UPDATE |
| CognitionKit/Sources/CognitionKit/RecipeCatalog.swift | additive | MUST_UPDATE |
| CognitionKit/Tests/CognitionKitTests/CapabilityGateTests.swift | verify passes | MUST_UPDATE |
| CognitionKit/Tests/CognitionKitTests/RecipeCatalogTests.swift | hard count | MUST_UPDATE |
| CognitionKit/Tests/CognitionKitTests/AssociationRulesTests.swift | new file | MUST_UPDATE |
| CognitionKit/Tests/CognitionKitTests/FormalConceptsTests.swift | new file | MUST_UPDATE |
| CognitionKit/rust/src/capability.rs | additive | MUST_UPDATE |
| CognitionKit/rust/src/catalog.rs | additive | MUST_UPDATE |
| CognitionKit/rust/src/association_rules_recipe.rs | new file | MUST_UPDATE |
| CognitionKit/rust/src/formal_concepts_recipe.rs | new file | MUST_UPDATE |
| CognitionKit/rust/src/lib.rs | additive pub use | MUST_UPDATE |
| apps/ARIA_MCP/Sources/AriaMCP/RecipeTools.swift | additive | MUST_UPDATE |
| apps/ARIA_MCP/Tests/AriaMCPTests/RecipeToolsTests.swift | hard count | MUST_UPDATE |
| docs/reference/COGNITIONKIT_SPEC_v0.85.md | §4.2, §8 | MUST_UPDATE |
| docs/reference/COGNITIONKIT_INTERFACE_v0.85.md | §6, §7 | MUST_UPDATE |
