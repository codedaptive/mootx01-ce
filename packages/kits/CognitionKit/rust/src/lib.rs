//! CognitionKit — the behaviour-recipe layer of the MOOTx01 substrate
//! (Rust port).
//!
//! This crate is the Rust side of the Swift `CognitionKit` package. Per
//! CLAUDE.md neither port leads: both implement the same spec and are
//! gated against shared fixtures. CognitionKit implements no algorithms
//! itself — recipes SEQUENCE NeuronKit reasoning and GeniusLocusKit
//! verbs. The only thing in a recipe worth porting is therefore its
//! DETERMINISTIC DECISION CORE — the pure logic with no estate, no
//! actor, no I/O:
//!
//!   - the NeuronKit capability set + the pre-execution capability gate
//!     (`capability`)
//!   - the recipe error model (`error`)
//!   - the recipe catalog / descriptor self-discovery surface (`catalog`)
//!   - the migration-benchmark decision core: duplicate-plan guard,
//!     origin partition, lost-concept union, C-13 gate + survivor
//!     ranking (`migration_ranking`)
//!
//! The estate-driven recipe bodies (`GroundedSynthesis.run`,
//! `MigrationBenchmark.run`, `confirmPromotion`) are NOT ported here:
//! they require the GeniusLocusKit estate handle and the NeuronKit
//! branch/benchmark/tournament surfaces, which are Swift-only at v0.8.
//! Closing that gap is Pass 2 — it expands the Rust NeuronKit and GLK
//! crates first, then ports the recipe bodies on top.
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
pub mod theme_weather_recipe;
pub mod feels_like_recipe;
pub mod tunnel_successor_recipe;
pub mod estate_divergence_recipe;
pub mod anticipate_recipe;

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
pub use theme_weather_recipe::run_theme_weather;
pub use feels_like_recipe::{run_partial_cue_recall, CueMatch, CueMode};
pub use tunnel_successor_recipe::{run_tunnel_successor, Successor};
pub use estate_divergence_recipe::{run_estate_divergence, EstateDivergence};
pub use anticipate_recipe::run_anticipate;
