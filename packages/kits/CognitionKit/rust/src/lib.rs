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
//!    EstateDivergence, Anticipate, MindOverlap, Bias, FreeAssociation).
//!    Keystones, Constellation, FreeAssociation, TunnelSuccessor,
//!    TrustLens, ThemeWeather, LatentThemes, Bias, and Anticipate are
//!    paired with Swift versions in `Sources/CognitionKit/`; Drift,
//!    Contradiction, FeelsLike, MindOverlap, and EstateDivergence are
//!    Rust-only today, with the Swift versions contracted (SPEC C-7).
//!    None are registered in the `catalog` yet — a lens registers in
//!    BOTH versions' catalogs or in neither, per the graduation gate in
//!    `docs/engineering/LENS_DISCOVERABILITY_DECISION_v1.0_2026-05-31.md`.
//!
//! Determinism: every function here is a pure function of its inputs.
//! No clock, no randomness, no unordered iteration that reaches output.
//!
//! Conformance: each module's `#[cfg(test)]` block fits the same
//! fixtures as the Swift `*Tests` and asserts identical results.

pub mod capability;
pub mod error;
pub mod catalog;
pub mod migration_ranking;
pub mod migration_orchestration;
pub mod migration_live;
pub mod grounded_synthesis;
pub mod keystones_recipe;
pub mod latent_themes_recipe;
pub mod trust_lens_recipe;
pub mod drift_recipe;
pub mod contradiction_recipe;
pub mod constellation_recipe;
pub mod free_association_recipe;
pub mod theme_weather_recipe;
pub mod feels_like_recipe;
pub mod tunnel_successor_recipe;
pub mod estate_divergence_recipe;
pub mod anticipate_recipe;
pub mod mind_overlap_recipe;
pub mod bias_recipe;

pub use capability::{verify_capabilities, NeuronKitCapability, shipped_capabilities};
pub use error::{RecipeError, RecipeRunError, SubstrateError};
pub use catalog::{recipe_catalog, recipe_descriptor, recipe_names, RecipeDescriptor};
pub use migration_ranking::{
    first_duplicate, lost_concepts, partition_origin, rank,
    DisqualifiedCore, PlanOutcome, RankedPlan, RankingResult,
};
pub use migration_orchestration::{
    run_migration_benchmark, BenchmarkOutcome, CorpusEntry, CoreReport, OriginEntry, PlanInput,
    PlanResultCore, RecipeSubstrate,
};
pub use migration_live::{confirm_migration_promotion, LiveRecipeSubstrate};
pub use grounded_synthesis::{run_grounded_synthesis, GroundedOutput};
pub use keystones_recipe::run_keystones;
pub use latent_themes_recipe::run_latent_themes;
pub use trust_lens_recipe::{run_trust_grounded_synthesis, TrustGroundedOutput};
pub use drift_recipe::{run_drift, DriftOutput};
pub use contradiction_recipe::{run_contradiction, ContradictionOutput};
pub use constellation_recipe::run_constellation;
pub use free_association_recipe::{run_free_association, Association};
pub use theme_weather_recipe::run_theme_weather;
pub use feels_like_recipe::{run_partial_cue_recall, CueMatch, CueMode};
pub use tunnel_successor_recipe::{run_tunnel_successor, Successor};
pub use estate_divergence_recipe::{run_estate_divergence, EstateDivergence};
pub use anticipate_recipe::run_anticipate;
pub use mind_overlap_recipe::{run_mind_overlap, MindOverlap};
pub use bias_recipe::{run_bias, BiasReport};
