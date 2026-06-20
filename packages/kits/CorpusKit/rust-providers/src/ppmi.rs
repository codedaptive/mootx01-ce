//! Positive Pointwise Mutual Information (PPMI) distributional-semantics
//! embedding provider.
//!
//! Rust port of Swift's `PpmiProvider` in `CorpusKitProviders`.
//!
//! Implements PPMI-weighted context accumulation producing a fixed-D dense
//! vector:
//!   1. Each context term gets a sparse ternary index vector in R^D
//!      (same seeded-index-vector machinery as RI — same FNV+SplitMix64
//!      pipeline, same D, K constants).
//!   2. Build term-context co-occurrence counts over a sliding window
//!      across the corpus.
//!   3. Compute PPMI weights:
//!        ppmi(t,c) = max(0, log( P(t,c) / (P(t) * P(c)) ))
//!      where:
//!        P(t,c) = co_count[t][c] / total_pairs
//!        P(t)   = term_count[t] / total_terms
//!        P(c)   = term_count[c] / total_terms
//!   4. A term's embedding = PPMI-weighted sum of context terms' index vectors.
//!      (RI adds the full index vector for every co-occurrence; PPMI scales
//!      each addition by the informative weight.  The distinction is real:
//!      this is NOT a plain RI accumulation.)
//!   5. A document/query embedding = the L2-normalised sum of its terms'
//!      PPMI context vectors.
//!
//! ## Constants (documented, cross-port identical)
//!
//!   D        = 2048   Dimensionality of index/context vectors.
//!   K        = 10     Nonzero positions per index vector (sparse ternary).
//!   WINDOW   = 4      Co-occurrence window radius (±4 terms).
//!
//! ## Index vector generation
//!
//! Identical to RI: seed = `fnv::hash64(term.to_lowercase())`,
//! rng = `SplitMix64::new(seed)`, 2*K draws in (pos, sign) pairs.
//! Cross-port: the same term produces the same index vector in RI and PPMI
//! because the seeding is identical.  What differs is the weight applied when
//! accumulating a context term's index vector into the target term's sum.
//!
//! ## Projection seed
//!
//!   PPMI_PROJECTION_SEED = 0x5050_4D49_5F56_314D  ("PPMI_V1M")
//!   Model ID = "ppmi-v1",  version = "1.0.0"
//!
//! The seed MUST differ from `RI_PROJECTION_SEED` so PPMI and RI engrams
//! key to different storage buckets when both providers coexist.
//!
//! Swift port: `packages/kits/CorpusKit/Sources/CorpusKitProviders/PpmiProvider.swift`
//!
//! ADR-010 reference: Decision B, signal #3 of the honest fusion.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// Index vectors:      ri_index_vector (same FNV+SplitMix64 pipeline as RI)
// L2 normalisation:   substrate_kernel::float_vec_ops::l2_normalize
// FloatSimHash:       substrate_ml::float_simhash::project
// FNV hash:           substrate_types::fnv::hash64   (via ri_index_vector)
// SplitMix64:         substrate_ml::random_walks::SplitMix64 (via ri_index_vector)
//
// All of these are conformance-gated substrate primitives.
// ─────────────────────────────────────────────────────────────────

use crate::basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
use corpus_kit::{CorpusKitError, TrainableEmbeddingBasis};
use crate::random_indexing::ri_index_vector;
use engram_lib::Engram;
use std::collections::HashMap;
use substrate_kernel::float_vec_ops;
use substrate_ml::float_simhash;
use vectorkit::{EmbeddingProvider, VectorKitError};

// MARK: - Constants
//
// Values are byte-identical to the Swift constants in `PpmiProvider.swift`.
// Any change must be mirrored to both ports simultaneously and the canonical
// test vectors must be regenerated.

/// Dimensionality of every PPMI index/context vector.
/// Shared with RI: same index space, different accumulation weights.
/// D=2^11 so `% PPMI_DIMENSION` is exact (equivalent to masking low 11 bits).
pub const PPMI_DIMENSION: usize = 2048;

/// Number of nonzero ternary (±1) entries in each term's index vector.
/// Shared with RI: 10/2048 ≈ 0.5 % density.
pub const PPMI_NONZEROS: usize = 10;

/// Co-occurrence window radius: ±4 terms on each side of the target.
/// Shared with RI for direct comparability of the two methods.
pub const PPMI_WINDOW: usize = 4;

/// FloatSimHash projection seed for PPMI. Encodes "PPMI_V1M" in ASCII bytes.
/// MUST differ from `RI_PROJECTION_SEED` so PPMI and RI engrams key to
/// different storage buckets when both providers coexist in one estate.
pub const PPMI_PROJECTION_SEED: u64 = 0x5050_4D49_5F56_314D;

/// 4-byte magic identifying a PPMI basis blob ("PPB1"). Mirrors the Swift
/// constant `PpmiProvider.basisMagic`.
pub const PPMI_BASIS_MAGIC: &[u8; 4] = b"PPB1";

// MARK: - PpmiProvider

/// PPMI distributional-semantics embedding provider.
///
/// Rust mirror of Swift's `PpmiProvider` in `CorpusKitProviders`.
///
/// An instance holds per-term PPMI context vectors built from the training
/// corpus.  Training is a two-phase process:
///
///   1. `train(&mut self, terms, window)` accumulates raw co-occurrence counts.
///   2. `finalize(&mut self)` converts counts to PPMI weights and fills the
///      context vector table.  Must be called before any `embed` / `embed_float`.
///
/// Once `finalize` has been called, additional `train` calls are allowed
/// (followed by another `finalize`) to extend the vocabulary.
///
/// ## Conformance
///
/// Conforms to `vectorkit::EmbeddingProvider`.
/// `model_id = "ppmi-v1"`, `model_version = "1.0.0"`.
/// Projection seed = `PPMI_PROJECTION_SEED`.
///
/// ADR-010 Decision B, signal #3 — PPMI co-occurrence provider in the
/// dense recall lane.
pub struct PpmiProvider {
    model_id: String,
    model_version: String,
    /// FloatSimHash projection seed.  Fixed to PPMI_PROJECTION_SEED.
    projection_seed: u64,

    // ── Count tables (accumulated during training, read during finalize) ──

    /// co_count[t][c] = number of times c appeared in t's sliding window
    /// across all training documents.
    co_count: HashMap<String, HashMap<String, usize>>,

    /// term_count[t] = total number of times t appeared as a *target* term.
    term_count: HashMap<String, usize>,

    /// Total number of (target, context) pairs observed.
    total_pairs: usize,

    /// Total number of target-term observations.
    total_terms: usize,

    // ── PPMI vectors (filled by finalize, read during embed) ──

    /// PPMI context vectors, keyed by lowercased term.
    /// Raw (unnormalised) PPMI-weighted sums of context-term index vectors.
    /// Normalisation happens at embed time.
    ppmi_vectors: HashMap<String, Vec<f32>>,
}

impl PpmiProvider {
    /// Build an untrained provider with the canonical defaults:
    /// `model_id = "ppmi-v1"`, `model_version = "1.0.0"`,
    /// projection seed = `PPMI_PROJECTION_SEED`.
    pub fn new() -> Self {
        Self::with_parameters("ppmi-v1", "1.0.0", PPMI_PROJECTION_SEED)
    }

    /// Build with explicit identity and projection seed.
    pub fn with_parameters(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
    ) -> Self {
        PpmiProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            projection_seed,
            co_count: HashMap::new(),
            term_count: HashMap::new(),
            total_pairs: 0,
            total_terms: 0,
            ppmi_vectors: HashMap::new(),
        }
    }

    // MARK: - Training — Phase 1 (count accumulation)

    /// Accumulate raw co-occurrence counts from a single document.
    ///
    /// For each target term t at position i, every term c in
    /// `[i-window, i+window]` (excluding i) is a context term.
    /// Increments `co_count[t][c]` and `term_count[t]` accordingly.
    ///
    /// Training is additive: multiple `train` calls extend the count tables
    /// without resetting them.  Call `finalize` after all documents are done.
    ///
    /// This is bit-identical to the Swift `train(terms:window:)` implementation:
    /// same window slice (`lo = i.saturating_sub(window)`, `hi = (i+window).min(n-1)`),
    /// same increment logic.
    pub fn train(&mut self, terms: &[&str], window: usize) {
        let n = terms.len();
        for (i, target) in terms.iter().enumerate() {
            let lo = i.saturating_sub(window);
            let hi = (i + window).min(n - 1);
            for j in lo..=hi {
                if j == i {
                    continue;
                }
                let context = terms[j];
                // Increment co-occurrence count for (target, context).
                *self
                    .co_count
                    .entry(target.to_lowercase())
                    .or_default()
                    .entry(context.to_lowercase())
                    .or_insert(0) += 1;
                // Increment total pairs.
                self.total_pairs += 1;
            }
            // Increment marginal target-term count.
            *self.term_count.entry(target.to_lowercase()).or_insert(0) += 1;
            self.total_terms += 1;
        }
    }

    // MARK: - Training — Phase 2 (PPMI computation)

    /// Convert the accumulated co-occurrence counts to PPMI context vectors.
    ///
    /// Must be called after all `train` calls and before any `embed` /
    /// `embed_float` calls.  Calling `finalize` is idempotent.
    ///
    /// ## PPMI weight formula (bit-identical to Swift)
    ///
    ///   P(t,c)    = co_count[t][c] as f32 / total_pairs as f32
    ///   P(t)      = term_count[t] as f32 / total_terms as f32
    ///   P(c)      = term_count[c] as f32 / total_terms as f32
    ///   ppmi(t,c) = max(0.0, log_e(P(t,c)) − log_e(P(t)) − log_e(P(c)))
    ///
    /// Zero-weight context terms (below-chance or zero-count pairs) are
    /// skipped; they contribute nothing to the target's context vector.
    ///
    /// ## Context vector construction
    ///
    ///   ppmi_vec(t) = sum over c in co_count[t] of
    ///                   ppmi(t,c) * ri_index_vector(c)
    ///
    /// Only terms with at least one nonzero-weight context pair get a
    /// ppmi_vector entry.
    pub fn finalize(&mut self) {
        if self.total_pairs == 0 || self.total_terms == 0 {
            return;
        }

        let f_total_pairs = self.total_pairs as f32;
        let f_total_terms = self.total_terms as f32;

        self.ppmi_vectors.clear();

        // Iterate over all (target, context_counts) pairs.
        // We need to read term_count for both target and context terms during
        // iteration, so we collect the co_count keys first to avoid borrow issues.
        let targets: Vec<String> = self.co_count.keys().cloned().collect();

        for target in &targets {
            let tc = match self.term_count.get(target) {
                Some(&c) if c > 0 => c,
                _ => continue,
            };
            let log_pt = (tc as f32 / f_total_terms).ln();

            let context_counts = match self.co_count.get(target) {
                Some(m) => m.clone(),
                None => continue,
            };

            let mut vec = vec![0.0f32; PPMI_DIMENSION];
            let mut has_nonzero = false;

            for (context, pair_count) in &context_counts {
                if *pair_count == 0 {
                    continue;
                }
                let cc = match self.term_count.get(context.as_str()) {
                    Some(&c) if c > 0 => c,
                    _ => continue,
                };
                let log_pc = (cc as f32 / f_total_terms).ln();
                let log_ptc = (*pair_count as f32 / f_total_pairs).ln();

                // PPMI weight: max(0, PMI).
                let pmi_val = log_ptc - log_pt - log_pc;
                let weight = pmi_val.max(0.0f32);

                // Skip zero-weight context terms.
                if weight == 0.0 {
                    continue;
                }

                // Accumulate: weight * ri_index_vector(context).
                // Reuse the RI index vector machinery (FNV + SplitMix64,
                // same constants D=2048, K=10). The shared index space is
                // intentional: PPMI and RI are comparable because they
                // project into the same coordinate system.
                let idx_vec = ri_index_vector(context);
                for d in 0..PPMI_DIMENSION {
                    vec[d] += weight * idx_vec[d];
                }
                has_nonzero = true;
            }

            if has_nonzero {
                self.ppmi_vectors.insert(target.clone(), vec);
            }
        }
    }

    // MARK: - Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) PPMI context vector for a term, or `None`
    /// if the term is OOV or has no nonzero PPMI-weighted context.
    /// Used by conformance tests to verify PPMI accumulation.
    pub fn ppmi_vector_for_term(&self, term: &str) -> Option<&Vec<f32>> {
        self.ppmi_vectors.get(&term.to_lowercase())
    }

    /// The current trained vocabulary size (terms with a PPMI vector).
    pub fn vocabulary_size(&self) -> usize {
        self.ppmi_vectors.len()
    }

    /// The number of unique target terms seen during training (before PPMI
    /// filtering).  `vocabulary_size() <= training_vocab_size()`.
    pub fn training_vocab_size(&self) -> usize {
        self.co_count.len()
    }

    // MARK: - Basis serialization (mission 6a-i)

    /// Serialize the finalized PPMI basis to a versioned, little-endian blob.
    ///
    /// PPMI's `embed`/`embed_float` output is fully determined by the
    /// finalized `ppmi_vectors` map plus the projection seed. The raw
    /// co-occurrence count tables are training-phase scratch and are NOT
    /// part of the embed-relevant basis, so they are intentionally excluded.
    /// Byte layout mirrors Swift's `serializeBasis()` exactly.
    pub fn serialize_basis(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(PPMI_BASIS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_string_f32_vector_map(&self.ppmi_vectors);
        w.into_bytes()
    }

    /// Reconstruct a provider from a serialized PPMI basis blob.
    ///
    /// The reconstructed provider's embed output is identical to the original
    /// finalized provider's. The count tables are left empty. Returns
    /// `Err(BasisCodecError)` on a truncated blob, an unknown format version,
    /// or a magic mismatch — never panics.
    pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(PPMI_BASIS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let model_id = r.read_string()?;
        let model_version = r.read_string()?;
        let projection_seed = r.read_u64()?;
        let ppmi_vectors = r.read_string_f32_vector_map()?;
        let mut provider = PpmiProvider::with_parameters(model_id, model_version, projection_seed);
        provider.ppmi_vectors = ppmi_vectors;
        Ok(provider)
    }

    // MARK: - Private helpers

    /// Compute the L2-normalised PPMI context vector for `text`.
    /// Returns `None` for empty text or when all terms are OOV.
    fn ppmi_context_vector(&self, text: &str) -> Option<Vec<f32>> {
        if text.is_empty() {
            return None;
        }
        // corpus_kit::default_keyword_tokens is the single canonical keyword
        // tokenizer shared by all distributional providers (RI, PPMI, and
        // future LSA/NMF). It is byte-identical to Swift's
        // distributionalKeywordTokenize in DistributionalBase.swift.
        let terms = corpus_kit::default_keyword_tokens(text);
        if terms.is_empty() {
            return None;
        }

        let mut sum = vec![0.0f32; PPMI_DIMENSION];
        let mut hit_count = 0usize;

        for term in &terms {
            if let Some(cv) = self.ppmi_vectors.get(term.as_str()) {
                for d in 0..PPMI_DIMENSION {
                    sum[d] += cv[d];
                }
                hit_count += 1;
            }
        }

        if hit_count == 0 {
            return None;
        }
        // Delegate to the substrate's canonical scalar implementation.
        // float_vec_ops::l2_normalize is conformance-gated against the Swift
        // port; using it here guarantees bit-identical output.
        Some(float_vec_ops::l2_normalize(sum))
    }
}

impl Default for PpmiProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl EmbeddingProvider for PpmiProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn model_version(&self) -> &str {
        &self.model_version
    }

    /// Produce the PPMI distributional embedding for `text`.
    ///
    /// Computes the L2-normalised PPMI context vector and projects it through
    /// `float_simhash::project` to produce the 256-bit Engram.
    /// Empty or all-OOV input returns `Engram::ZERO`.
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        match self.ppmi_context_vector(text) {
            None => Ok(Engram::ZERO),
            Some(v) => Ok(float_simhash::project(&v, self.projection_seed)),
        }
    }

    /// Return the D-dimensional L2-normalised PPMI context vector for `text`.
    ///
    /// - No trained basis (ppmi_vectors empty): returns `Ok(vec![])` — structural opt-out.
    /// - Empty or non-tokenisable input: returns `Ok(vec![])`.
    /// - Trained basis, all query tokens OOV: returns
    ///   `Err(VectorKitError::EmbedFloatVocabMiss(...))` so the corpus layer
    ///   maps to `FloatLaneOutcome::UnavailableNoVocabHit`.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        // No trained basis: structural opt-out, not vocabMiss.
        if self.ppmi_vectors.is_empty() {
            return Ok(vec![]);
        }
        if text.is_empty() {
            return Ok(vec![]);
        }
        let terms = corpus_kit::default_keyword_tokens(text);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        // OOV check: throw vocabMiss when basis is trained but no query term hits.
        let has_in_vocab = terms.iter().any(|t| self.ppmi_vectors.contains_key(t.as_str()));
        if !has_in_vocab {
            return Err(VectorKitError::EmbedFloatVocabMiss(format!(
                "ppmi: vocab size {}, but 0 of {} query token(s) matched",
                self.ppmi_vectors.len(),
                terms.len()
            )));
        }
        Ok(self.ppmi_context_vector(text).unwrap_or_default())
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

impl TrainableEmbeddingBasis for PpmiProvider {
    /// Train the PPMI basis on a corpus of raw document texts.
    ///
    /// PPMI's `train` consumes a term slice per document, so each text is
    /// tokenized with the canonical `corpus_kit::default_keyword_tokens` and fed
    /// to `train` at `PPMI_WINDOW`. PPMI requires the Phase-2 `finalize` pass to
    /// convert co-occurrence counts to PPMI-weighted context vectors; it runs
    /// once after all documents are counted. This reproduces the exact
    /// trained+finalized state of `train` + `finalize` driven from token slices,
    /// so a basis serialized after `train_on_corpus` is byte-identical to the
    /// 6a-i fixture whose corpus is the same texts tokenized.
    fn train_on_corpus(&mut self, texts: &[&str]) {
        for text in texts {
            let terms = corpus_kit::default_keyword_tokens(text);
            let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
            self.train(&term_refs, PPMI_WINDOW);
        }
        self.finalize();
    }

    /// Serialize the finalized PPMI basis (6a-i codec), surfaced through the seam.
    fn serialize_basis(&self) -> Vec<u8> {
        PpmiProvider::serialize_basis(self)
    }

    /// Reconstruct a fresh `PpmiProvider` from a basis blob, boxed. Delegates to
    /// `from_serialized_basis` (6a-i); a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        let provider = PpmiProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// Reconstruct a fresh PPMI provider from a basis blob, boxed as TRAINABLE so
    /// `Corpus` can rebuild a from-scratch trainable provider for `reindex` /
    /// first-ingest (train_on_corpus is additive — see the trait doc). Same
    /// `from_serialized_basis` constructor as `reconstruct_basis`.
    fn reconstruct_trainable_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError> {
        let provider = PpmiProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }
}

// MARK: - Unit tests

#[cfg(test)]
mod tests {
    use super::*;
    use vectorkit::EmbeddingProvider;

    /// Build and finalize a provider trained on the canonical mini-corpus.
    fn build_trained_provider() -> PpmiProvider {
        let corpus = vec![
            vec!["car", "engine", "drive", "road", "vehicle"],
            vec!["vehicle", "road", "transport", "car", "fuel"],
            vec!["engine", "fuel", "combustion", "power", "car"],
            vec!["dog", "bark", "run", "fetch", "animal"],
            vec!["animal", "run", "cat", "dog", "pet"],
        ];
        let mut provider = PpmiProvider::new();
        for doc in &corpus {
            provider.train(doc, PPMI_WINDOW);
        }
        provider.finalize();
        provider
    }

    #[test]
    fn projection_seed_differs_from_ri() {
        use crate::random_indexing::RI_PROJECTION_SEED;
        assert_ne!(
            PPMI_PROJECTION_SEED, RI_PROJECTION_SEED,
            "PPMI and RI must use distinct projection seeds for bucket isolation"
        );
    }

    #[test]
    fn ppmi_dimension_matches_ri_dimension() {
        use crate::random_indexing::RI_DIMENSION;
        assert_eq!(PPMI_DIMENSION, RI_DIMENSION,
            "PPMI and RI share the same index vector space (D=2048)");
    }

    #[test]
    fn ppmi_vector_is_nonzero_after_training() {
        let provider = build_trained_provider();
        let car_vec = provider.ppmi_vector_for_term("car");
        assert!(car_vec.is_some(), "car must have a PPMI vector after training");
        let has_nonzero = car_vec.unwrap().iter().any(|&x| x != 0.0);
        assert!(has_nonzero, "car's PPMI vector must have at least one non-zero component");
    }

    #[test]
    fn ppmi_vector_differs_from_ri_context_vector() {
        // The key distinction: PPMI weights each context term's index vector by
        // its informativeness. RI adds the full index vector for every
        // co-occurrence. The results must differ.
        use crate::random_indexing::RandomIndexingProvider;
        let ppmi = build_trained_provider();
        let corpus = vec![
            vec!["car", "engine", "drive", "road", "vehicle"],
            vec!["vehicle", "road", "transport", "car", "fuel"],
            vec!["engine", "fuel", "combustion", "power", "car"],
            vec!["dog", "bark", "run", "fetch", "animal"],
            vec!["animal", "run", "cat", "dog", "pet"],
        ];
        let mut ri = RandomIndexingProvider::new();
        for doc in &corpus {
            ri.train(doc, PPMI_WINDOW);
        }
        let ppmi_vec = ppmi.ppmi_vector_for_term("car").unwrap();
        let ri_vec   = ri.context_vector_for_term("car").unwrap();
        assert_ne!(*ppmi_vec, *ri_vec,
            "PPMI and RI context vectors for 'car' must differ (different accumulation weights)");
    }

    #[test]
    fn embed_empty_returns_zero_engram() {
        let provider = build_trained_provider();
        assert_eq!(provider.embed("").unwrap(), Engram::ZERO);
    }

    #[test]
    fn embed_float_empty_returns_empty_vec() {
        let provider = build_trained_provider();
        assert!(provider.embed_float("").unwrap().is_empty());
    }

    #[test]
    fn oov_text_returns_zero_engram() {
        let mut provider = PpmiProvider::new();
        provider.finalize();
        assert_eq!(provider.embed("unknown word").unwrap(), Engram::ZERO);
    }

    #[test]
    fn oov_text_returns_empty_float_vec() {
        let mut provider = PpmiProvider::new();
        provider.finalize();
        assert!(provider.embed_float("unknown word").unwrap().is_empty());
    }

    #[test]
    fn embed_is_deterministic() {
        let provider = build_trained_provider();
        let e1 = provider.embed("car engine").unwrap();
        let e2 = provider.embed("car engine").unwrap();
        assert_eq!(e1, e2, "same text must produce same embedding");
    }

    #[test]
    fn embed_float_returns_unit_length_vector() {
        let provider = build_trained_provider();
        let v = provider.embed_float("car engine").unwrap();
        assert!(!v.is_empty(), "embed_float must be non-empty after training");
        let norm: f32 = v.iter().map(|&x| x * x).sum::<f32>().sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-5,
            "embed_float must return a unit vector; got norm={norm}"
        );
    }

    #[test]
    fn ppmi_and_ri_engrams_differ_for_same_text() {
        use crate::random_indexing::RandomIndexingProvider;
        let ppmi = build_trained_provider();
        let corpus = vec![
            vec!["car", "engine", "drive", "road", "vehicle"],
            vec!["vehicle", "road", "transport", "car", "fuel"],
            vec!["engine", "fuel", "combustion", "power", "car"],
            vec!["dog", "bark", "run", "fetch", "animal"],
            vec!["animal", "run", "cat", "dog", "pet"],
        ];
        let mut ri = RandomIndexingProvider::new();
        for doc in &corpus {
            ri.train(doc, PPMI_WINDOW);
        }
        let ppmi_engram = ppmi.embed("car engine").unwrap();
        let ri_engram   = ri.embed("car engine").unwrap();
        assert_ne!(ppmi_engram, ri_engram,
            "PPMI and RI must produce distinct Engrams (different projection seeds + accumulation weights)");
    }

    #[test]
    fn semantic_relatedness_holds_after_training() {
        let provider = build_trained_provider();
        let car     = provider.embed_float("car").unwrap();
        let vehicle = provider.embed_float("vehicle").unwrap();
        let dog     = provider.embed_float("dog").unwrap();

        assert!(!car.is_empty() && !vehicle.is_empty() && !dog.is_empty());

        let car_vehicle_sim: f32 = car.iter().zip(vehicle.iter()).map(|(&a, &b)| a * b).sum();
        let car_dog_sim: f32     = car.iter().zip(dog.iter()).map(|(&a, &b)| a * b).sum();

        assert!(
            car_vehicle_sim > car_dog_sim,
            "car↔vehicle ({car_vehicle_sim}) must be closer than car↔dog ({car_dog_sim}) under PPMI"
        );
    }

    #[test]
    fn finalize_before_embed_returns_empty() {
        // Without finalize, ppmi_vectors is empty → all terms are OOV.
        let mut provider = PpmiProvider::new();
        let corpus = vec![
            vec!["car", "engine", "drive"],
        ];
        for doc in &corpus {
            provider.train(doc, PPMI_WINDOW);
        }
        // NOT finalized: embed_float must return empty (all OOV in ppmi_vectors).
        let v = provider.embed_float("car engine").unwrap();
        assert!(v.is_empty(), "embed_float must return empty before finalize() is called");

        // After finalize, non-empty.
        provider.finalize();
        let v2 = provider.embed_float("car engine").unwrap();
        assert!(!v2.is_empty(), "embed_float must be non-empty after finalize()");
    }
}
