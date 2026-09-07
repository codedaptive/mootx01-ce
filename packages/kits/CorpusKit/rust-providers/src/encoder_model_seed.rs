//! Hardcoded seed values for the bundled snowflake-arctic-embed-s encoder model.
//!
//! Two paths consume these constants to upsert an `encoder_models` row:
//!   - `EstateCoordinator::seed_default_encoder_model_in` (GeniusLocusKit):
//!     the GLK activation path, called at open from `activate_span_encoder` when
//!     the manifest names `embedding_provider = "encoder"` and no active row
//!     exists yet (ruling 2026-09-04: seeding belongs to provision and serve).
//!   - `mootx01 upgrade`: the upgrade backfill, which seeds the row over a
//!     closed estate's storage so that pre-1.1 estates gain an active row on
//!     their next open.
//!
//! The row is inserted with `is_active = true` only when no active row exists;
//! an estate that already carries an active row (for example, a later audition
//! winner) keeps it unchanged.
//!
//! Twin of Swift's `EncoderModelSeed` in
//! `Sources/CorpusKitProviders/EncoderModelSeed.swift`. Both ports must carry
//! identical values; the `seed_matches_checked_in_manifests` test enforces
//! agreement with the JSON manifests in `tools/encoder-models/`.
//!
//! To swap the winner (a different model ID from the audition):
//! 1. Update all constants below to match the new model's manifest.
//! 2. Re-run `tools/encoder-models/build-all.sh`.
//! 3. Replace the model directory in app resources and installer package.
//! Schema migration and re-encode are handled by `EncoderModelStore` and
//! the drain duty; this file is only the seed source.

/// Static seed values for the bundled snowflake-arctic-embed-s encoder model.
///
/// `mootx01 upgrade` and estate provisioning insert a row into
/// `encoder_models` from these constants when none exists.
pub struct EncoderModelSeed;

impl EncoderModelSeed {
    // ── Model identity ────────────────────────────────────────────────────────

    /// The model ID, format `<model>-w<window_words>` per contract §1.
    /// Changing the window size requires a new model ID and a full re-index.
    pub const MODEL_ID: &'static str = "arctic-embed-s-w60";

    /// Full pinned HF commit hash. A weights revision bump is a new
    /// `model_version` and triggers a re-index via the drain duty.
    pub const MODEL_VERSION: &'static str = "e596f507467533e48a2e17c007f0e1dacc837b33";

    /// Output dimension of snowflake-arctic-embed-s.
    pub const DIM: usize = 384;

    /// Arctic card query instruction; documents receive no prefix.
    pub const QUERY_PREFIX: &'static str = "Represent this sentence for searching relevant passages: ";

    /// No document prefix.
    pub const DOC_PREFIX: &'static str = "";

    /// Pooling strategy stored in the registry row.
    pub const POOLING: &'static str = "cls";

    /// sha256(vocab.txt) at pinned HF revision e596f507467533e48a2e17c007f0e1dacc837b33.
    /// Verified by `ModelDirectoryResolver` at load time; stored in
    /// `encoder_models.tokenizer_hash`. Identical across Apple and Linux/Windows
    /// manifests because both platforms ship the same vocab file.
    pub const TOKENIZER_HASH: &'static str =
        "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3";

    // ── Span parameters ───────────────────────────────────────────────────────

    /// Sliding-window width in words. Encoded in the model ID ("w60").
    pub const WINDOW_WORDS: usize = 60;

    /// step = WINDOW_WORDS / OVERLAP_DIVISOR = 30 words of stride.
    pub const OVERLAP_DIVISOR: usize = 2;

    /// Hard ceiling on spans per drawer: 32 spans × 384 bytes = 12 KB.
    pub const MAX_SPANS: usize = 32;

    /// Model max-sequence in tokens (snowflake-arctic-embed-s max_position_embeddings).
    pub const MAX_SEQUENCE: usize = 512;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies that every constant in `EncoderModelSeed` matches the checked-in
    /// JSON manifests for both Apple and Linux. If a constant drifts from the
    /// manifest — for example, DIM is updated here but not in the JSON, or vice
    /// versa — this test fails immediately, preventing a silent mis-seed of the
    /// `encoder_models` row at upgrade time.
    #[test]
    fn seed_matches_checked_in_manifests() {
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        let manifest_names = [
            "encoder-models-apple.json",
            "encoder-models-linux.json",
        ];

        for name in &manifest_names {
            let path = std::path::Path::new(manifest_dir)
                .join("../../../../tools/encoder-models")
                .join(name);
            let raw = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {}: {}", path.display(), e));
            let manifest: serde_json::Value = serde_json::from_str(&raw)
                .unwrap_or_else(|e| panic!("failed to parse {}: {}", name, e));

            assert_eq!(
                manifest["model_id"].as_str().unwrap(),
                EncoderModelSeed::MODEL_ID,
                "{name}: model_id mismatch"
            );
            assert_eq!(
                manifest["model_version"].as_str().unwrap(),
                EncoderModelSeed::MODEL_VERSION,
                "{name}: model_version mismatch"
            );
            assert_eq!(
                manifest["dim"].as_u64().unwrap(),
                EncoderModelSeed::DIM as u64,
                "{name}: dim mismatch"
            );
            assert_eq!(
                manifest["query_prefix"].as_str().unwrap(),
                EncoderModelSeed::QUERY_PREFIX,
                "{name}: query_prefix mismatch"
            );
            assert_eq!(
                manifest["doc_prefix"].as_str().unwrap(),
                EncoderModelSeed::DOC_PREFIX,
                "{name}: doc_prefix mismatch"
            );
            assert_eq!(
                manifest["pooling"].as_str().unwrap(),
                EncoderModelSeed::POOLING,
                "{name}: pooling mismatch"
            );
            assert_eq!(
                manifest["tokenizer_hash"].as_str().unwrap(),
                EncoderModelSeed::TOKENIZER_HASH,
                "{name}: tokenizer_hash mismatch"
            );
            assert_eq!(
                manifest["window_words"].as_u64().unwrap(),
                EncoderModelSeed::WINDOW_WORDS as u64,
                "{name}: window_words mismatch"
            );
            assert_eq!(
                manifest["overlap_divisor"].as_u64().unwrap(),
                EncoderModelSeed::OVERLAP_DIVISOR as u64,
                "{name}: overlap_divisor mismatch"
            );
            assert_eq!(
                manifest["max_spans"].as_u64().unwrap(),
                EncoderModelSeed::MAX_SPANS as u64,
                "{name}: max_spans mismatch"
            );
            assert_eq!(
                manifest["max_sequence"].as_u64().unwrap(),
                EncoderModelSeed::MAX_SEQUENCE as u64,
                "{name}: max_sequence mismatch"
            );
        }
    }
}
