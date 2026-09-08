//! Candle-backed pair-logit inference for the cross encoder.
//!
//! Loads a BERT sequence classifier (`BertForSequenceClassification`) from
//! the fixed HF file triple `config.json` + `tokenizer.json` +
//! `model.safetensors`, tokenizes every (query, span) pair with the
//! `tokenizers` crate's pair encode (longest-first truncation) and returns
//! one relevance logit per pair: `classifier(tanh(pooler(hidden[CLS])))`.
//!
//! The classifier head is not part of `candle_transformers`' `BertModel`,
//! so the pooler dense and the classifier linear are read from the same
//! safetensors under their HF names (`bert.pooler.dense`, `classifier`).
//!
//! Gated behind the `candle` feature exactly like `CandleNLProvider`.
//! Mirror of Swift `CorpusKitProviders/Encoder/CoreMLPairInference.swift`.

#[cfg(feature = "candle")]
mod inner {
    use std::path::Path;

    use candle_core::{Device, IndexOp, Module, Tensor};
    use candle_nn::{Linear, VarBuilder};
    use candle_transformers::models::bert::{BertModel, Config, DTYPE};
    use corpus_kit::encoder::{EncoderError, PairInference};
    use tokenizers::{PaddingParams, PaddingStrategy, Tokenizer, TruncationParams, TruncationStrategy};

    /// The three files the runtime loads; `vocab.txt` is hashed by the
    /// factory but not read here.
    pub const REQUIRED_FILES: [&str; 3] = ["config.json", "tokenizer.json", "model.safetensors"];

    /// The safetensors prefixes of the classifier head.
    const POOLER_PREFIX: &str = "bert.pooler.dense";
    const CLASSIFIER_PREFIX: &str = "classifier";

    /// BERT sequence classifier producing one logit per (query, span) pair.
    ///
    /// # Thread safety
    ///
    /// `Send + Sync` because candle CPU tensors are Arc-based and read-only
    /// after load; the tokenizer is likewise read-only after load.
    pub struct CandlePairScorer {
        model: BertModel,
        pooler: Linear,
        classifier: Linear,
        tokenizer: Tokenizer,
        device: Device,
    }

    impl CandlePairScorer {
        /// Load the classifier from `model_dir`, truncating every pair at
        /// `max_sequence` tokens (the profile's `max_sequence`). Values
        /// above the model's positional ceiling are clamped to it.
        pub fn load(model_dir: &Path, max_sequence: usize) -> Result<Self, String> {
            let device = Device::Cpu;
            let config_path = model_dir.join("config.json");
            let config: Config = serde_json::from_str(
                &std::fs::read_to_string(&config_path)
                    .map_err(|e| format!("reading {}: {e}", config_path.display()))?,
            )
            .map_err(|e| format!("parsing config.json: {e}"))?;
            let ceiling = config.max_position_embeddings.max(1);
            let tokenizer = pair_tokenizer(model_dir, max_sequence.clamp(1, ceiling))?;

            let weights_path = model_dir.join("model.safetensors");
            if !weights_path.exists() {
                return Err(format!("model weights absent at {}", weights_path.display()));
            }
            // SAFETY: mmap of a local file that was just confirmed to exist.
            // Standard candle loading path for safetensors weights.
            let vb = unsafe {
                VarBuilder::from_mmaped_safetensors(&[&weights_path], DTYPE, &device)
                    .map_err(|e| format!("mmap safetensors at {}: {e}", weights_path.display()))?
            };
            // `BertModel::load` tries the bare prefix first and then
            // `<model_type>.`; the classifier checkpoint stores the encoder
            // under `bert.`, which the fallback resolves.
            let model = BertModel::load(vb.clone(), &config)
                .map_err(|e| format!("building BertModel: {e}"))?;
            let hidden = config.hidden_size;
            let pooler = candle_nn::linear(hidden, hidden, vb.pp(POOLER_PREFIX))
                .map_err(|e| format!("loading {POOLER_PREFIX}: {e}"))?;
            let classifier = candle_nn::linear(hidden, 1, vb.pp(CLASSIFIER_PREFIX))
                .map_err(|e| format!("loading {CLASSIFIER_PREFIX}: {e}"))?;
            Ok(Self { model, pooler, classifier, tokenizer, device })
        }

        /// True when the three files the runtime loads are present.
        pub fn assets_present(model_dir: &Path) -> bool {
            REQUIRED_FILES.iter().all(|f| model_dir.join(f).exists())
        }

        /// Token ids and segment ids of one pair, exactly as the forward
        /// pass sees them. Exposed so the pair tokenization can be pinned
        /// against the Swift `tokenizePair` without running the model.
        pub fn encode_pair(&self, query: &str, span: &str) -> Result<(Vec<u32>, Vec<u32>), String> {
            encode_pair(&self.tokenizer, query, span)
        }

        /// One batched forward over every (query, span) pair.
        fn forward_pairs(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, String> {
            let pairs: Vec<(String, String)> =
                spans.iter().map(|s| (query.to_string(), s.to_string())).collect();
            let encodings = self
                .tokenizer
                .encode_batch(pairs, true)
                .map_err(|e| format!("tokenizing pairs: {e}"))?;
            let batch = encodings.len();
            let seq_len = encodings[0].get_ids().len(); // uniform after BatchLongest
            let mut ids = Vec::with_capacity(batch * seq_len);
            let mut type_ids = Vec::with_capacity(batch * seq_len);
            let mut mask: Vec<u32> = Vec::with_capacity(batch * seq_len);
            for enc in &encodings {
                ids.extend_from_slice(enc.get_ids());
                type_ids.extend_from_slice(enc.get_type_ids());
                mask.extend_from_slice(enc.get_attention_mask());
            }
            let shape = (batch, seq_len);
            let input_ids = Tensor::from_vec(ids, shape, &self.device).map_err(|e| e.to_string())?;
            let token_type_ids =
                Tensor::from_vec(type_ids, shape, &self.device).map_err(|e| e.to_string())?;
            let attention_mask =
                Tensor::from_vec(mask, shape, &self.device).map_err(|e| e.to_string())?;
            let hidden = self
                .model
                .forward(&input_ids, &token_type_ids, Some(&attention_mask))
                .map_err(|e| e.to_string())?; // (b, s, hidden)
            // HF BertPooler: dense over the [CLS] position, then tanh; the
            // classifier is a plain linear to one label.
            let cls = hidden.i((.., 0, ..)).map_err(|e| e.to_string())?;
            let pooled = self.pooler.forward(&cls).and_then(|t| t.tanh()).map_err(|e| e.to_string())?;
            let logits = self.classifier.forward(&pooled).map_err(|e| e.to_string())?; // (b, 1)
            let rows = logits.to_vec2::<f32>().map_err(|e| e.to_string())?;
            rows.into_iter()
                .map(|row| {
                    if row.len() == 1 {
                        Ok(row[0])
                    } else {
                        Err(format!("classifier output carries {} values, expected 1", row.len()))
                    }
                })
                .collect()
        }
    }

    // SAFETY: BertModel and the two Linear layers hold only CPU tensors
    // (Arc-based) and are read-only after load. Tokenizer is likewise
    // read-only. Both are safe to share across threads.
    unsafe impl Send for CandlePairScorer {}
    unsafe impl Sync for CandlePairScorer {}

    impl PairInference for CandlePairScorer {
        fn backend(&self) -> &str {
            "candle"
        }

        fn logits(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> {
            if spans.is_empty() {
                return Ok(Vec::new());
            }
            self.forward_pairs(query, spans).map_err(EncoderError::InferenceFailed)
        }
    }

    /// `tokenizer.json` configured for pairs: longest-first truncation at
    /// `max_sequence` (the reference `truncation="longest_first"`) and
    /// pad-to-longest within a batch. The shipped file carries a fixed
    /// padding block that would pad every pair to its own length; the
    /// override replaces it, as the sentence-encoder runtime does.
    pub fn pair_tokenizer(model_dir: &Path, max_sequence: usize) -> Result<Tokenizer, String> {
        let tokenizer_path = model_dir.join("tokenizer.json");
        let mut tokenizer = Tokenizer::from_file(&tokenizer_path)
            .map_err(|e| format!("loading {}: {e}", tokenizer_path.display()))?;
        tokenizer
            .with_truncation(Some(TruncationParams {
                max_length: max_sequence,
                strategy: TruncationStrategy::LongestFirst,
                ..Default::default()
            }))
            .map_err(|e| format!("configuring truncation: {e}"))?;
        tokenizer.with_padding(Some(PaddingParams {
            strategy: PaddingStrategy::BatchLongest,
            ..Default::default()
        }));
        Ok(tokenizer)
    }

    /// Token ids and segment ids of one (query, span) pair.
    pub fn encode_pair(tokenizer: &Tokenizer, query: &str, span: &str) -> Result<(Vec<u32>, Vec<u32>), String> {
        let encoding = tokenizer
            .encode((query, span), true)
            .map_err(|e| format!("tokenizing pair: {e}"))?;
        Ok((encoding.get_ids().to_vec(), encoding.get_type_ids().to_vec()))
    }
}

#[cfg(feature = "candle")]
pub use inner::{encode_pair, pair_tokenizer, CandlePairScorer, REQUIRED_FILES};
