---
id: LENS_DISCOVERABILITY_DECISION_v1.0_2026-05-31
date: 2026-05-31
status: decision
scope: packages/kits/CognitionKit, packages/kits/NeuronKit, apps/ARIA_MCP
---

# Lens Discoverability

## Doctrine

- Swift is the design surface and leads. Every behaviour is authored in Swift first.
- Rust is secondary. It follows Swift. It never leads.
- Both ports are gated against shared fixtures and may not diverge.

## Facts (verified 2026-05-31)

| Fact | Source |
|---|---|
| 14 CognitionKit lens recipes exist in Rust only; no Swift sibling. | `packages/kits/CognitionKit/rust/src/*_recipe.rs`; `Sources/CognitionKit/` has only GroundedSynthesis, MigrationBenchmark, MigrationOrchestration, MigrationRanking, Recipe, RecipeCatalog, NeuronKitCapability, RecipeError |
| 11 lens reasoning surfaces exist in Rust NeuronKit only; no Swift sibling. | Rust `NeuronKit/src/{keystones,latent_themes,drift,anomaly_scan,constellation,theme_weather,partial_recall,anticipation,mind_overlap,bias,spreading_activation}.rs`; no matching Swift `func` |
| The lenses were authored Rust-first with no Swift. This violates the Swift-leads doctrine. | above |
| `recipe_catalog()` (Rust) registers only `grounded_synthesis`, `migration_benchmark`. A test asserts exactly that set. | `catalog.rs` L33-59, L78-83 |
| The Rust catalog must match Swift `RecipeCatalog.all` byte-for-byte (conformance anchor). | `catalog.rs` L1-11; `RecipeCatalog.swift` L62-65 |
| `moot_list_recipes` reads `RecipeCatalog.all`. | `RecipeTools.swift` L192-193 |
| Each MCP recipe tool hard-binds to a specific Swift recipe type. No generic run-by-name dispatcher. | `RecipeTools.swift` L160-185 |
| ARIA_MCP links Swift kits only — no Rust, FFI, or uniffi. | `apps/ARIA_MCP/Package.swift` |
| Rust kit crates are `[lib]` only — no `[[bin]]`, no MCP server, no FFI. The lenses run only under `cargo test`. | `Cargo.toml`, both crates |

## Consequences

1. The 14 lenses are not discoverable or invokable by any agent. MCP reaches only Swift; Rust has no runtime caller.
2. The lenses have no Swift design surface, so they are not legitimately shipped under the doctrine. Rust led; that is the defect.
3. Making a lens shipped requires its Swift design surface authored first, Rust re-derived to follow, landing in the same change as the catalog entry. Listing alone does not invoke — a graduated recipe also needs its MCP tool.

## Decision

- The catalog stays `grounded_synthesis` + `migration_benchmark` until a lens graduates.
- Do not add lenses to `recipe_catalog()` without the Swift port in the same change.
- Do not build a second Rust-only registry (`lens_catalog()`); no runtime consumer exists for one.
- A lens graduates only via the gate below.

## Graduation gate (all required)

1. A product or agent workflow names the lens as a required behaviour.
2. Any v1 caveat is retired, not relabeled.
3. The lens fits the capability-gated descriptor model, or the descriptor model is extended by explicit decision.
4. The Swift design surface (recipe + NeuronKit surface) is authored first; Rust follows; both land with the catalog entry and the MCP tool in one change.

## Open items requiring Bob

- Disposition of the 14 Rust-first lenses (redo Swift-first, or retain as scratch pending graduation).
- Whether `RecipeDescriptor` gains capabilities for structural recipes or is extended for uncapability-gated lenses.
- First lens graduation (first Swift design surface for a lens; spends fixture budget).

## Notes

- The Swift/Rust catalog parity is guarded by a single assert (`catalog.rs` L78-83). If relaxed, parity is lost silently. The catalog is the shipped surface, not a feature inventory.
- Prior incident: Anticipate and MindOverlap shipped proxies under final names and were rebuilt — basis for graduation criterion 2.
