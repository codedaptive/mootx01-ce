//! CognitionKit — the behaviour-recipe layer of the MOOTx01 substrate
//! (Rust version).
//!
//! This crate is the Rust side of the Swift `CognitionKit` package.
//! CognitionKit implements no algorithms itself — recipes SEQUENCE
//! NeuronKit reasoning and GeniusLocusKit verbs. Three layers live here:
//!
//! 1. **Swift-paired decision cores + estate-driven recipes** (`neither version
//!    leads`, gated against shared fixtures): the capability set + gate
//!    (`capability`), the error model (`error`), the catalog/descriptor
//!    self-discovery surface (`catalog`), the migration ranking decision core
//!    (`migration_ranking`), and the estate-driven bodies themselves
//!    (`grounded_synthesis`, `migration_orchestration`, `migration_live`).
//!    `migration_live` now provides `run_migration_benchmark_sqlite`, a
//!    production entry point over a durable WAL-mode `SqliteDrawerStore`-backed
//!    `EstateCoordinator` — parity with Swift's `MigrationBenchmark.run`
//!    opening an `InMemoryStorage` estate. Tests CK-SQLITE-1..3 cover the
//!    end-to-end path and the primitive-decode reopen round-trip.
//!
//! 2. **Reasoning lenses** (`*_recipe` below): named behaviours that
//!    sequence gated SubstrateML math into estate-level reasoning
//!    (Keystones, LatentThemes, TrustLens, Drift, Contradiction,
//!    Constellation, ThemeWeather, FeelsLike, TunnelSuccessor,
//!    EstateDivergence, Anticipate, MindOverlap, Bias, FreeAssociation,
//!    AssociationRules, AprioriRules, FormalConcepts, Moment, Rhythm,
//!    Precedence, Complexity, ExploratoryRecall). Every lens recipe is
//!    paired with a Swift version in `Sources/CognitionKit/` (SPEC C-7
//!    satisfied) and registered in both versions' catalogs with byte-identical
//!    descriptors.
//!    All 30 catalog entries are present in both versions; the 3 distillation-
//!    family entries carry descriptor metadata in Rust but no full Rust recipe
//!    body in this directory.
//!
//! Determinism: the sequencing logic in `migration_orchestration` is a pure
//! function of its inputs when tested via the `RecipeSubstrate` trait; the
//! live path (`migration_live::run_migration_benchmark_sqlite`) reads mutable
//! estate state via `EstateCoordinator` and captures `SystemTime` for telemetry.
//! Lens recipes are read-only; no unordered iteration reaches output.
//!
//! Conformance: each module's `#[cfg(test)]` block fits the same
//! fixtures as the Swift `*Tests` and asserts identical results.

pub mod anticipate_recipe;
// distill.rs — DistillInput/Output data types AND run_distill recipe body
// for the per-item distillation sweep (SPEC_DISTILLATION_STORAGE §3/§7).
// Rust parity with CognitionKit/Distill.swift. run_distill delegates to
// EstateCoordinator::distill_items_sweep (parity with Swift's kit.distillItemsSweep).
pub mod distill;
// distilled_recall.rs — DistilledRecallInput/Output/DistilledMatch types AND
// run_distilled_recall recipe body. Rust parity with CognitionKit/DistilledRecall.swift.
// Exact-search geometry over originals + distilled hydration (§10.3).
pub mod distilled_recall;
pub mod association_rules_recipe;
pub mod exploratory_recall_recipe;
pub mod bias_recipe;
pub mod capability;
pub mod catalog;
pub mod constellation_recipe;
pub mod contradiction_recipe;
pub mod drift_recipe;
pub mod error;
pub mod estate_divergence_recipe;
pub mod feels_like_recipe;
pub mod formal_concepts_recipe;
pub mod free_association_recipe;
pub mod grounded_synthesis;
pub mod keystones_recipe;
pub mod latent_themes_recipe;
pub mod complexity_recipe;
// Dataset-targeted lens entry points (MX-TAB-6): take plain column-value
// arrays from the tool layer rather than estate handles. No PersistenceKit
// dependency is added to the library; callers feed values from DatasetStore.
pub mod dataset_complexity;
pub mod dataset_associations;
pub mod dataset_cohesion;
pub mod migration_live;
pub mod migration_orchestration;
pub mod migration_ranking;
pub mod mind_overlap_recipe;
pub mod moment_recipe;
pub mod precedence_recipe;
pub mod connected_recall;
pub mod precise_recall;
pub mod rhythm_recipe;
pub mod shaped_recall;
pub mod theme_weather_recipe;
pub mod trust_lens_recipe;
pub mod tunnel_successor_recipe;

pub use anticipate_recipe::run_anticipate;
pub use distill::{run_distill, DistillInput, DistillOutput};
pub use distilled_recall::{
    classify_distilled_discrimination, run_distilled_recall, DistilledDiscriminationLevel,
    DistilledMatch, DistilledRecallInput, DistilledRecallOutput,
};
pub use association_rules_recipe::{
    run_apriori_rules, run_association_rules, AprioriRulesOutput, AssociationRuleResult,
    AssociationRulesOutput,
};
pub use bias_recipe::{run_bias, BiasReport};
pub use capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
pub use catalog::{recipe_catalog, recipe_descriptor, recipe_names, RecipeDescriptor};
pub use constellation_recipe::run_constellation;
pub use contradiction_recipe::{run_contradiction, ContradictionOutput};
pub use drift_recipe::{run_drift, DriftOutput};
pub use error::{AnchorNotInRecalledSetError, RecipeError, RecipeRunError, SubstrateError};
pub use estate_divergence_recipe::{run_estate_divergence, EstateDivergence};
pub use feels_like_recipe::{run_partial_cue_recall, CueMatch, CueMode};
pub use formal_concepts_recipe::{run_formal_concepts, FormalConceptResult, FormalConceptsOutput};
pub use exploratory_recall_recipe::{run_exploratory_recall, ExploratoryRecallOutput, ExploratoryResult};
pub use free_association_recipe::{run_free_association, Association};
pub use grounded_synthesis::{run_grounded_synthesis, GroundedOutput};
pub use keystones_recipe::run_keystones;
pub use latent_themes_recipe::run_latent_themes;
pub use migration_live::{
    confirm_migration_promotion, confirm_migration_promotion_by_id, LiveRecipeSubstrate,
    run_migration_benchmark_sqlite,
};
pub use migration_orchestration::{
    run_migration_benchmark, BenchmarkOutcome, CoreReport, CorpusEntry, OriginEntry, PlanInput,
    PlanResultCore, RecipeSubstrate,
};
pub use migration_ranking::{
    first_duplicate, lost_concepts, partition_origin, rank, DisqualifiedCore, PlanOutcome,
    RankedPlan, RankingResult,
};
pub use complexity_recipe::{run_complexity, ComplexityOutput, ComplexityResult};
pub use dataset_complexity::{run_dataset_column_entropy, ColumnEntropyOutput};
pub use dataset_associations::{run_dataset_associations, DatasetAssociationsOutput};
pub use dataset_cohesion::{
    run_dataset_cohesion, DatasetCohesionOutput, DatasetColumnValue, RowAnomalyScore, SCAN_CAP,
};
pub use mind_overlap_recipe::{run_mind_overlap, MindOverlap};
pub use precise_recall::{run as run_precise_recall, PreciseMatch, DEFAULT_POOL as PRECISE_DEFAULT_POOL};
pub use moment_recipe::{run_moment, MomentOutput};
pub use precedence_recipe::{run_precedence, PrecedenceOutput};
pub use rhythm_recipe::{run_rhythm, RhythmOutput};
pub use shaped_recall::{run as run_shaped_recall, ShapedRecallOutput};
pub use theme_weather_recipe::run_theme_weather;
pub use trust_lens_recipe::{run_trust_grounded_synthesis, TrustGroundedOutput};
pub use tunnel_successor_recipe::{run_tunnel_successor, Successor};
