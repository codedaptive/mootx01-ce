//! Candle-based in-process NL embedding provider — all-MiniLM-L6-v2.
//!
//! `CandleNLProvider` implements `synapsekit::EmbeddingProvider` using
//! Hugging Face's `candle` ML crate for BERT forward passes. It is the
//! Rust-port analogue of Swift's `AppleNLProvider` (which uses Apple's
//! `NaturalLanguage` framework): both produce dense float embeddings
//! that feed the float lane and project to binary Engrams, but they use
//! different backends and produce different float values for the same
//! text (sanctioned cross-backend divergence, §4 of
//! `PART_E_RUST_SEAM_DESIGN.md`).
//!
//! # Model
//!
//! `sentence-transformers/all-MiniLM-L6-v2` — Apache-2.0, 384-dim
//! pooled output. Weights must be fetched ONCE via
//! `tools/neural-embed/fetch-model.sh` before use; the crate never
//! calls a network API. The pinned revision is declared in
//! [`MODEL_VERSION`].
//!
//! # CRITICAL: tokenizer padding override
//!
//! The model's shipped `tokenizer.json` contains a FIXED-LENGTH-128
//! padding configuration. If left in place, every single-text encode
//! pads to 128 tokens and the unmasked mean pooling would average
//! ~100+ `[PAD]` embedding vectors into the result, shifting each
//! component by ~0.04 — wrong vectors that would pass every smoke test.
//!
//! `Embedder::load` overrides this with `BatchLongest` padding plus
//! attention-masked mean pooling. Any future change to tokenizer
//! configuration MUST retain this override. The golden-pin test
//! `golden_pin_first_four_components` in the spike test suite guards it:
//! a regression to the file's padding shifts those values by ~0.04.
//!
//! # Gate-8 disposition (§7.3 throughput)
//!
//! The spike's §7.3 criterion was ≥100 texts/s on a single CPU core.
//!
//! - Apple Silicon + Accelerate feature: 104/s — MARGINAL PASS.
//! - Pure CPU (no BLAS): 32/s — FAIL on Linux aarch64 production target.
//!
//! Disposition: ACCEPTED for this integration with the following
//! reasoning:
//!
//! 1. Benchmark indexing is offline (hours available); 32/s ×
//!    3600 s = 115 200 texts/hour is adequate for lme-75 arms and
//!    realistic estate sizes.
//! 2. The `candle-accelerate` feature flag (passed at build time:
//!    `--features candle,candle-accelerate`) enables Apple Accelerate /
//!    Linux BLAS and recovers the ≥100/s criterion on BLAS-capable
//!    hardware.
//! 3. A Linux aarch64 re-measurement with OpenBLAS is the blocking gate
//!    for declaring §7.3 fully PASS; that measurement is a follow-up
//!    action. Until it completes, the Candle path should not be used
//!    in latency-sensitive indexing paths on non-BLAS Linux hosts.
//!
//! # Compile guard
//!
//! This module is compiled ONLY when the `candle` Cargo feature is
//! enabled. The `EmbeddingModelConfig::CandleNL` variant in `corpus-kit`
//! is always present (it takes a `Box<dyn EmbeddingProvider>`); the
//! concrete provider here is optional.

#[cfg(feature = "candle")]
mod inner {
    use candle_core::{DType, Device, Tensor};
    use candle_nn::VarBuilder;
    use candle_transformers::models::bert::{BertModel, Config, DTYPE};
    use engram_lib::Engram;
    use std::path::Path;
    use substrate_ml::float_simhash;
    use tokenizers::{PaddingParams, PaddingStrategy, Tokenizer, TruncationParams};
    use synapsekit::{EmbeddingProvider, SynapseKitError};
    // SynapseKitError is used in forward_batch, embed, embed_float, embed_pair,
    // embed_batch return types. EmbeddingProvider is implemented for CandleNLProvider.

    // ─────────────────────────────────────────────────────────────────────────
    // DO NOT REIMPLEMENT SUBSTRATE MATH.
    //
    // The SimHash projection below uses `substrate_ml::float_simhash::project`
    // (the conformance-gated, bit-identical Swift+Rust primitive). Do not
    // hand-roll a projection. See packages/libs/SubstrateML/AGENTS.md.
    // ─────────────────────────────────────────────────────────────────────────

    /// Stable model ID reported by the provider and used to tag stored
    /// vectors. Distinct from the seam-based `MiniLMTextProvider`'s
    /// `"minilm-v6"` because these providers use different backends (Candle
    /// vs host-supplied seam) and will produce different float vectors.
    pub const MODEL_ID: &str = "candle-minilm-l6-v2";

    /// Pinned HF revision of sentence-transformers/all-MiniLM-L6-v2.
    /// Changing this constant invalidates all stored vectors and requires a
    /// re-index; bump the golden-pin test when upgrading.
    pub const MODEL_VERSION: &str = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41";

    /// Output dimension all-MiniLM-L6-v2 always produces.
    pub const DIMENSION: usize = 384;

    /// BERT positional-embedding ceiling. Inputs longer than this are
    /// truncated (MiniLM config `max_position_embeddings = 512`).
    const MAX_TOKENS: usize = 512;

    /// Projection seed for the binary Engram lane.
    ///
    /// Encodes "CANDLNL1" in ASCII big-endian:
    /// C(0x43) A(0x41) N(0x4E) D(0x44) L(0x4C) N(0x4E) L(0x4C) 1(0x31).
    ///
    /// Distinct from the seam-based MiniLM seed (`MINILM_PROJECTION_SEED
    /// = 0x4D49_4E4C_4D5F_7631`). Binary engrams produced by this provider
    /// and the seam-based one are NOT comparable under Hamming distance — the
    /// different seeds guarantee different projections even if the same float
    /// vector were fed in. The schema's `model_id` field distinguishes them.
    pub const CANDLE_NL_PROJECTION_SEED: u64 = 0x4341_4E44_4C4E_4C31;

    /// All-MiniLM-L6-v2 provider backed by Candle in-process BERT inference.
    ///
    /// Load with [`CandleNLProvider::load`]; then pass as
    /// `EmbeddingModelConfig::CandleNL { provider: Box::new(provider) }`.
    ///
    /// # Thread safety
    ///
    /// `Send + Sync` because candle CPU tensors are Arc-based and
    /// read-only after model load. The tokenizer crate's `Tokenizer` is
    /// likewise read-only after load. No shared mutable state.
    pub struct CandleNLProvider {
        model: BertModel,
        tokenizer: Tokenizer,
        device: Device,
        projection_seed: u64,
    }

    impl CandleNLProvider {
        /// Load the provider from a local directory containing
        /// `config.json`, `tokenizer.json`, and `model.safetensors`.
        ///
        /// The load path is purely local: no network I/O. Fetch weights
        /// once with `tools/neural-embed/fetch-model.sh` (pinned revision
        /// `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, Apache-2.0).
        ///
        /// Returns `Err` when any asset is absent or malformed. The caller
        /// should fall back to the default ensemble when weights are absent
        /// (e.g. on first-install or CI runners without the model volume).
        ///
        /// See the module-level doc for the CRITICAL tokenizer-padding
        /// override and the gate-8 throughput caveat.
        pub fn load(model_dir: &Path) -> Result<Self, String> {
            Self::load_with_seed(model_dir, CANDLE_NL_PROJECTION_SEED)
        }

        /// Load with an explicit projection seed. Intended for tests only;
        /// production callers use [`CandleNLProvider::load`] to keep the
        /// seed byte-identical to the constant.
        pub fn load_with_seed(model_dir: &Path, projection_seed: u64) -> Result<Self, String> {
            let device = Device::Cpu;

            let config_path = model_dir.join("config.json");
            let config: Config = serde_json::from_str(
                &std::fs::read_to_string(&config_path)
                    .map_err(|e| format!("reading {}: {e}", config_path.display()))?,
            )
            .map_err(|e| format!("parsing config.json: {e}"))?;

            let tokenizer_path = model_dir.join("tokenizer.json");
            let mut tokenizer = Tokenizer::from_file(&tokenizer_path)
                .map_err(|e| format!("loading {}: {e}", tokenizer_path.display()))?;

            // CRITICAL: override the shipped tokenizer.json's FIXED-LENGTH-128
            // padding configuration. See the module-level doc — without this
            // override, every encode pads to 128 and the unmasked mean pooling
            // contaminates the result with ~100 PAD embeddings (~0.04 shift per
            // component). BatchLongest + attention-masked mean pooling is the
            // correct approach, and the golden-pin test guards this override.
            tokenizer
                .with_truncation(Some(TruncationParams {
                    max_length: MAX_TOKENS,
                    ..Default::default()
                }))
                .map_err(|e| format!("configuring truncation: {e}"))?;
            tokenizer.with_padding(Some(PaddingParams {
                strategy: PaddingStrategy::BatchLongest,
                ..Default::default()
            }));

            let weights_path = model_dir.join("model.safetensors");
            if !weights_path.exists() {
                return Err(format!(
                    "model weights absent at {} — run tools/neural-embed/fetch-model.sh first",
                    weights_path.display()
                ));
            }
            // SAFETY: mmap of a local file that was just confirmed to exist.
            // Standard candle loading path for safetensors weights.
            let vb = unsafe {
                VarBuilder::from_mmaped_safetensors(&[&weights_path], DTYPE, &device)
                    .map_err(|e| format!("mmap safetensors at {}: {e}", weights_path.display()))?
            };
            let model =
                BertModel::load(vb, &config).map_err(|e| format!("building BertModel: {e}"))?;

            Ok(Self {
                model,
                tokenizer,
                device,
                projection_seed,
            })
        }

        /// True when the three required asset files are present in `model_dir`.
        ///
        /// Check before calling `load` when you want a user-friendly absent-asset
        /// message rather than the load error. `load` is still authoritative: an
        /// asset being present does not guarantee it is valid.
        pub fn assets_present(model_dir: &Path) -> bool {
            ["config.json", "tokenizer.json", "model.safetensors"]
                .iter()
                .all(|f| model_dir.join(f).exists())
        }

        /// Run the BERT forward on a batch of (already-tokenized) encodings
        /// and return one 384-dim pooled float vector per input.
        ///
        /// Batched forward is the efficient path: candle's per-op overhead
        /// dominates at batch-size-1, so grouping non-empty texts into a
        /// single forward pass is the throughput strategy. See the gate-8
        /// disposition in the module doc.
        fn forward_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, SynapseKitError> {
            debug_assert!(!texts.is_empty(), "forward_batch: empty slice is a caller bug");
            let encodings = self
                .tokenizer
                .encode_batch(texts.iter().map(|t| t.to_string()).collect(), true)
                .map_err(|e| SynapseKitError::EmbeddingFailed(format!("tokenizing: {e}")))?;

            let batch = encodings.len();
            let seq_len = encodings[0].get_ids().len(); // pad-to-longest: uniform after BatchLongest
            let mut ids = Vec::with_capacity(batch * seq_len);
            let mut type_ids = Vec::with_capacity(batch * seq_len);
            let mut mask: Vec<u32> = Vec::with_capacity(batch * seq_len);
            for enc in &encodings {
                ids.extend_from_slice(enc.get_ids());
                type_ids.extend_from_slice(enc.get_type_ids());
                mask.extend_from_slice(enc.get_attention_mask());
            }

            let shape = (batch, seq_len);
            let input_ids = Tensor::from_vec(ids, shape, &self.device)
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?;
            let token_type_ids = Tensor::from_vec(type_ids, shape, &self.device)
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?;
            let attention_mask = Tensor::from_vec(mask, shape, &self.device)
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?;

            let hidden = self
                .model
                .forward(&input_ids, &token_type_ids, Some(&attention_mask))
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?; // (b, s, 384)

            // Attention-masked mean pooling: PAD positions contribute nothing
            // to the sum; the divisor is the real token count per sequence.
            // This ensures a padded batch pools identically to an unpadded
            // single encode (the result does NOT depend on padding length).
            let mask_f = attention_mask
                .to_dtype(DType::F32)
                .and_then(|t| t.unsqueeze(2))
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?; // (b, s, 1)
            let summed = hidden
                .broadcast_mul(&mask_f)
                .and_then(|t| t.sum(1))
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?; // (b, 384)
            let counts = mask_f
                .sum(1)
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?; // (b, 1)
            let pooled = summed
                .broadcast_div(&counts)
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?;

            let vecs = pooled
                .to_vec2::<f32>()
                .map_err(|e| SynapseKitError::EmbeddingFailed(e.to_string()))?;
            for v in &vecs {
                if v.len() != DIMENSION {
                    return Err(SynapseKitError::EmbeddingFailed(format!(
                        "dimension mismatch: expected {DIMENSION}, got {}",
                        v.len()
                    )));
                }
            }
            Ok(vecs)
        }

        /// Embed one non-empty text. Delegates to `forward_batch` with
        /// a batch of 1 — there is exactly ONE call path (soft-SDK
        /// equality: no separate single/batch paths that could drift).
        fn embed_single_nonempty(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
            let mut vecs = self.forward_batch(std::slice::from_ref(&text))?;
            Ok(vecs.pop().expect("batch of 1 always returns 1 vector"))
        }
    }

    // SAFETY: BertModel holds only CPU tensors (Arc-based) and is read-only
    // after load. Tokenizer is likewise read-only. Both are safe to share
    // across threads.
    unsafe impl Send for CandleNLProvider {}
    unsafe impl Sync for CandleNLProvider {}

    impl EmbeddingProvider for CandleNLProvider {
        fn model_id(&self) -> &str {
            MODEL_ID
        }

        fn model_version(&self) -> &str {
            MODEL_VERSION
        }

        /// Produce a 256-bit engram for `text`.
        ///
        /// Empty input returns `Engram::ZERO` per the `EmbeddingProvider`
        /// contract without touching the inference seam.
        fn embed(&self, text: &str) -> Result<Engram, SynapseKitError> {
            if text.is_empty() {
                return Ok(Engram::ZERO);
            }
            let pooled = self.embed_single_nonempty(text)?;
            // float_simhash::project is the conformance-gated, bit-identical
            // Swift/Rust SimHash primitive; do NOT replace with a local impl.
            Ok(float_simhash::project(&pooled, self.projection_seed))
        }

        /// Return the raw 384-dim unnormalized pooled vector.
        ///
        /// Unnormalized by design (mirroring `AppleNLProvider`):
        /// `float_simhash` is scale-invariant, and normalization is opt-in
        /// at the benchmark level via `--normalize`. Empty input returns
        /// `vec![]` (no dense direction for the empty string).
        fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
            if text.is_empty() {
                return Ok(Vec::new());
            }
            self.embed_single_nonempty(text)
        }

        /// Produce both the binary engram and the float vector from a SINGLE
        /// forward pass. Empty input returns `(Engram::ZERO, vec![])` without
        /// touching inference.
        fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), SynapseKitError> {
            if text.is_empty() {
                return Ok((Engram::ZERO, Vec::new()));
            }
            let pooled = self.embed_single_nonempty(text)?;
            let engram = float_simhash::project(&pooled, self.projection_seed);
            Ok((engram, pooled))
        }

        /// Batched embed — override the default sequential path with a single
        /// candle forward pass over all non-empty texts.
        ///
        /// Empty texts are short-circuited to `Engram::ZERO` without reaching
        /// the model. Non-empty texts are collected, forwarded in one batch,
        /// projected, and merged back at their original positions.
        fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Engram>, SynapseKitError> {
            if texts.is_empty() {
                return Ok(Vec::new());
            }
            // Partition: track positions of non-empty texts for merge-back.
            let mut positions: Vec<usize> = Vec::new();
            let mut nonempty: Vec<&str> = Vec::new();
            for (i, &t) in texts.iter().enumerate() {
                if !t.is_empty() {
                    positions.push(i);
                    nonempty.push(t);
                }
            }

            // All empty → short-circuit.
            if nonempty.is_empty() {
                return Ok(vec![Engram::ZERO; texts.len()]);
            }

            // Single forward pass over all non-empty texts.
            let pooled_vecs = self.forward_batch(&nonempty)?;

            // Build output: ZERO for empty slots, projected engram for rest.
            let mut out = vec![Engram::ZERO; texts.len()];
            for (pos, pooled) in positions.into_iter().zip(pooled_vecs) {
                out[pos] = float_simhash::project(&pooled, self.projection_seed);
            }
            Ok(out)
        }
    }
}

// Re-export the public surface unconditionally so callers can always
// name the type; the compiler gates the actual implementation on the feature.
#[cfg(feature = "candle")]
pub use inner::{
    CandleNLProvider, CANDLE_NL_PROJECTION_SEED, DIMENSION as CANDLE_NL_DIMENSION,
    MODEL_ID as CANDLE_NL_MODEL_ID, MODEL_VERSION as CANDLE_NL_MODEL_VERSION,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
//
// Tests that do NOT require model weights run unconditionally — they exercise
// the provider interface via a stub. Tests that DO require weights are marked
// `#[ignore]` and run manually with:
//
//   cargo test --features candle -- --include-ignored candle_provider
//
// after fetching weights with tools/neural-embed/fetch-model.sh.

#[cfg(all(test, feature = "candle"))]
mod tests {
    use super::inner::*;
    use synapsekit::EmbeddingProvider;
    use engram_lib::Engram;

    // The default model directory mirrors tools/neural-embed/models so that
    // a single fetch-model.sh invocation satisfies both the spike tests and
    // these provider tests.
    fn model_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent() // rust-providers → CorpusKit
            .unwrap()
            .parent() // CorpusKit → kits
            .unwrap()
            .parent() // kits → packages
            .unwrap()
            .parent() // packages → repo root
            .unwrap()
            .join("tools/neural-embed/models")
    }

    /// Guard: returns true when the model weights are present on disk.
    /// All weight-requiring tests call this and skip when false.
    fn weights_present() -> bool {
        CandleNLProvider::assets_present(&model_dir())
    }

    // ── Weight-free tests ─────────────────────────────────────────────────

    /// `assets_present` returns false when a non-existent path is given.
    /// This exercises the graceful absent-asset detection path without
    /// needing actual weights.
    #[test]
    fn assets_present_returns_false_for_nonexistent_dir() {
        let absent = std::path::Path::new("/tmp/candle-nl-provider-absent-dir-test");
        assert!(!CandleNLProvider::assets_present(absent));
    }

    /// `load` returns Err (not panic) when weights are absent.
    #[test]
    fn load_returns_err_when_assets_absent() {
        let absent = std::path::Path::new("/tmp/candle-nl-provider-absent-dir-test");
        let result = CandleNLProvider::load(absent);
        assert!(result.is_err(), "load must return Err when assets are absent");
    }

    /// Constants have expected values (projection seed is distinct from
    /// existing MiniLM seed 0x4D49_4E4C_4D5F_7631).
    #[test]
    fn constants_are_expected() {
        assert_eq!(DIMENSION, 384);
        assert_eq!(MODEL_ID, "candle-minilm-l6-v2");
        // Projection seed must differ from all existing seeds (any collision
        // would mean two providers project to the same engram for identical
        // float input, breaking cross-provider distance guarantees).
        const MINILM_SEAM_SEED: u64 = 0x4D49_4E4C_4D5F_7631;
        const MPNET_SEAM_SEED: u64 = 0x4D50_4E45_545F_7631;
        const GEMMA_SEAM_SEED: u64 = 0x454D_4247_4D5F_7631;
        assert_ne!(CANDLE_NL_PROJECTION_SEED, MINILM_SEAM_SEED);
        assert_ne!(CANDLE_NL_PROJECTION_SEED, MPNET_SEAM_SEED);
        assert_ne!(CANDLE_NL_PROJECTION_SEED, GEMMA_SEAM_SEED);
    }

    // ── Weight-requiring tests (run with --include-ignored) ───────────────

    /// §4.1 determinism: same input → byte-identical engrams on every call.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn determinism_same_input_identical_engrams() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let text = "The estate coordinator provisions embedding providers at open time.";
        let a = p.embed(text).unwrap();
        let b = p.embed(text).unwrap();
        assert_eq!(a, b, "same input must produce bit-identical engrams");
    }

    /// Distinct inputs produce distinct engrams (sanity: provider is not
    /// collapsing all inputs to a constant).
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn distinct_inputs_produce_distinct_engrams() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let a = p.embed("cats are small domestic mammals").unwrap();
        let b = p.embed("the stock market rose sharply today").unwrap();
        assert_ne!(a, b, "semantically unrelated inputs should rarely collide");
    }

    /// Empty input must return Engram::ZERO without touching inference.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn empty_input_returns_zero_engram() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        assert_eq!(p.embed("").unwrap(), Engram::ZERO);
        assert!(p.embed_float("").unwrap().is_empty());
        let (e, f) = p.embed_pair("").unwrap();
        assert_eq!(e, Engram::ZERO);
        assert!(f.is_empty());
    }

    /// embed_float dimension pin.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn embed_float_returns_384_dim_vector() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let v = p.embed_float("dimension pin").unwrap();
        assert_eq!(v.len(), 384);
    }

    /// embed_pair is consistent with embed + embed_float (same pass, same result).
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn embed_pair_matches_embed_and_embed_float() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let text = "embed pair consistency check";
        let (pair_e, pair_f) = p.embed_pair(text).unwrap();
        let solo_e = p.embed(text).unwrap();
        let solo_f = p.embed_float(text).unwrap();
        assert_eq!(pair_e, solo_e, "embed_pair engram must match embed");
        assert_eq!(pair_f, solo_f, "embed_pair float must match embed_float");
    }

    /// embed_batch: empty-text slots must return Engram::ZERO; non-empty
    /// slots must match individual embed calls.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn embed_batch_handles_mixed_empty_and_nonempty() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let texts = ["hello world", "", "batch test"];
        let batch = p.embed_batch(&texts).unwrap();
        assert_eq!(batch.len(), 3);
        assert_eq!(batch[1], Engram::ZERO, "empty text at index 1 must be ZERO");
        // Non-empty results must match individual embeds (determinism).
        assert_eq!(batch[0], p.embed("hello world").unwrap());
        assert_eq!(batch[2], p.embed("batch test").unwrap());
    }

    /// Golden pin — first four raw (unnormalized) float components of a
    /// known input. Generated on 2026-08-21 with model rev
    /// 1110a243fdf4706b3f48f1d95db1a4f5529b4d41 (Candle 0.9.2, CPU path).
    /// Catches silent weights/tokenizer/pooling drift. Asserted to 1e-5.
    ///
    /// These values are the same as the spike's golden pin because this
    /// provider uses the same model, tokenizer override, and pooling logic.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn golden_pin_first_four_float_components() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        let v = p.embed_float("the quick brown fox jumps over the lazy dog").unwrap();
        // GOLDEN — regenerate ONLY on a deliberate model-revision bump.
        // See tools/neural-embed/tests/backend_tests.rs for provenance.
        let expected: [f32; 4] = [0.19502874, 0.33672202, 0.2895038, 0.38847142];
        for (i, (got, &want)) in v.iter().zip(expected.iter()).enumerate() {
            assert!(
                (got - want).abs() < 1e-5,
                "float component {i}: got {got}, want {want}"
            );
        }
    }

    /// Provider identity getters return the canonical constants.
    #[test]
    #[ignore = "requires model weights — run tools/neural-embed/fetch-model.sh"]
    fn model_id_and_version_return_canonical_values() {
        if !weights_present() {
            eprintln!("SKIP: model weights absent");
            return;
        }
        let p = CandleNLProvider::load(&model_dir()).unwrap();
        assert_eq!(p.model_id(), MODEL_ID);
        assert_eq!(p.model_version(), MODEL_VERSION);
    }
}
