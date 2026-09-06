//! AdornmentLib — dream-time adornment generation and certification.
//!
//! Dark by default. All production modules compile only when the `miners`
//! Cargo feature is enabled: `cargo build --features miners`.
//!
//! Ruling (Encoder Rerank Program, 2026-09-05): adornments did not earn their
//! cost at ingest. The library is retained in the tree because its minter
//! recipes hold NuExtract for v1.2 KGFact creation. Not deleted — dark.
//!
//! When `miners` is off this crate compiles as an empty library with no
//! public symbols and zero warnings. Dependents that gate their usage behind
//! `#[cfg(feature = "miners")]` build cleanly without the feature.

#[cfg(feature = "miners")]
pub mod adornment_validators;
#[cfg(feature = "miners")]
pub mod adornment_generator;
#[cfg(feature = "miners")]
pub mod adornment_identity;
#[cfg(feature = "miners")]
pub mod gold_miner;
#[cfg(feature = "miners")]
pub mod minter_recipe;
#[cfg(feature = "miners")]
mod quantized_qwen2_lean;

#[cfg(feature = "miners")]
pub use adornment_validators::{contains_word_boundary, validate_count, validate_date};
#[cfg(feature = "miners")]
pub use adornment_generator::{ADORNMENT_CHUNK_THRESHOLD, ADORNMENT_MAX_LENGTH, build_adornment_prompt, invoke_adornment_command, mint_adornment_map_reduce};
#[cfg(feature = "miners")]
pub use adornment_identity::{AdornmentMinterDescriptor, StoredAdornment};
#[cfg(feature = "miners")]
pub use minter_recipe::{CHATML_TEMPLATE, MintOutputKind, MinterRecipe, NUEXTRACT_TINY_RECIPE, OSMOSIS_STRUCTURE_RECIPE, QUANTIZED_RECIPE, QWEN25_05B_RECIPE, QWEN25_15B_RECIPE, QWEN3_06B_RECIPE, extract_claim_line, fnv1a64_hex, normalize_mint_output, recipe_for_model, selected_recipe};
#[cfg(feature = "miners")]
pub use gold_miner::{GoldMinerEngine, QuantizedLlmEngine};
