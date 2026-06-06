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
//!    (`migration_ranking`), and — now that Pass 2 has landed the live Rust
//!    GeniusLocusKit estate + NeuronKit branch/benchmark/tournament surfaces —
//!    the estate-driven bodies themselves (`grounded_synthesis`,
//!    `migration_orchestration`, `migration_live`).
//!
//! 2. **Reasoning lenses** (`*_recipe` below): named behaviours that
//!    sequence gated SubstrateML math into estate-level reasoning
//!    (Keystones, LatentThemes, TrustLens, Drift, Contradiction,
//!    Constellation, ThemeWeather, FeelsLike, TunnelSuccessor,
//!    EstateDivergence, Anticipate, MindOverlap, Bias, FreeAssociation,
//!    AssociationRules, AprioriRules, FormalConcepts). Every lens recipe is paired with
//!    a Swift version in `Sources/CognitionKit/` (SPEC C-7 satisfied) and
//!    registered in BOTH versions' catalogs with byte-identical descriptors,
//!    per `docs/engineering/LENS_DISCOVERABILITY_DECISION_v2.0_2026-06-02.md`
//!    (the catalog lists what ships in both versions).
//!
//! Determinism: every function here is a pure function of its inputs.
//! No clock, no randomness, no unordered iteration that reaches output.
//!
//! Conformance: each module's `#[cfg(test)]` block fits the same
//! fixtures as the Swift `*Tests` and asserts identical results.

pub mod anticipate_recipe;
pub mod association_rules_recipe;
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
pub mod migration_live;
pub mod migration_orchestration;
pub mod migration_ranking;
pub mod mind_overlap_recipe;
pub mod theme_weather_recipe;
pub mod trust_lens_recipe;
pub mod tunnel_successor_recipe;

pub use anticipate_recipe::run_anticipate;
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
pub use free_association_recipe::{run_free_association, Association};
pub use grounded_synthesis::{run_grounded_synthesis, GroundedOutput};
pub use keystones_recipe::run_keystones;
pub use latent_themes_recipe::run_latent_themes;
pub use migration_live::{
    confirm_migration_promotion, confirm_migration_promotion_by_id, LiveRecipeSubstrate,
};
pub use migration_orchestration::{
    run_migration_benchmark, BenchmarkOutcome, CoreReport, CorpusEntry, OriginEntry, PlanInput,
    PlanResultCore, RecipeSubstrate,
};
pub use migration_ranking::{
    first_duplicate, lost_concepts, partition_origin, rank, DisqualifiedCore, PlanOutcome,
    RankedPlan, RankingResult,
};
pub use mind_overlap_recipe::{run_mind_overlap, MindOverlap};
pub use theme_weather_recipe::run_theme_weather;
pub use trust_lens_recipe::{run_trust_grounded_synthesis, TrustGroundedOutput};
pub use tunnel_successor_recipe::{run_tunnel_successor, Successor};
