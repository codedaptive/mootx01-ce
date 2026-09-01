//! AdornmentLib — dream-time adornment generation and certification.
//!
//! Provides:
//!   - `adornment_validators`: deterministic post-mint validators (AV-1..AV-8
//!     golden pins, both ports). The minting model proposes; the validators
//!     certify.
//!   - `adornment_generator`: the MOOT_MINT_CMD command seam (stdin prompt →
//!     stdout claim text) with silent mechanical truncation at ADORNMENT_MAX_LENGTH
//!     and map-reduce chunking for records exceeding ADORNMENT_CHUNK_THRESHOLD.
//!   - `adornment_identity`: pure value types for one registered minter
//!     (`AdornmentMinterDescriptor`) and one stored adornment (`StoredAdornment`)
//!     per ADORNMENTLIB_INTERFACE 0.3.0 §4.
//!   - `minter_recipe`: compile-time minter recipes (composed
//!     `<model>-pN-sN` identities, cross-port FNV-1a-64 digests) and the
//!     generic text|json mint-output normalizer.
//!
//! No kit dependencies. External crates carry C-1 per-crate approval
//! (candle stack + tokenizers + libc for the resident engine, Bob
//! 2026-08-26; serde_json for the JSON normalizer branch — a transitive
//! dep of candle, declared explicitly). AdornmentLib is BELOW LocusKit
//! and GeniusLocusKit in the dependency graph.
//!
//! Ports AdornmentLib/Sources/AdornmentLib/ (Swift primary).

pub mod adornment_validators;
pub mod adornment_generator;
pub mod adornment_identity;
pub mod gold_miner;
pub mod minter_recipe;
mod quantized_qwen2_lean;

pub use adornment_validators::{contains_word_boundary, validate_count, validate_date};
pub use adornment_generator::{ADORNMENT_CHUNK_THRESHOLD, ADORNMENT_MAX_LENGTH, build_adornment_prompt, invoke_adornment_command, mint_adornment_map_reduce};
pub use adornment_identity::{AdornmentMinterDescriptor, StoredAdornment};
pub use minter_recipe::{CHATML_TEMPLATE, MintOutputKind, MinterRecipe, NUEXTRACT_TINY_RECIPE, OSMOSIS_STRUCTURE_RECIPE, QUANTIZED_RECIPE, QWEN25_05B_RECIPE, QWEN25_15B_RECIPE, QWEN3_06B_RECIPE, extract_claim_line, fnv1a64_hex, normalize_mint_output, recipe_for_model, selected_recipe};
pub use gold_miner::{GoldMinerEngine, QuantizedLlmEngine};
