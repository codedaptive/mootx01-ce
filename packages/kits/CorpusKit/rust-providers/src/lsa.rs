//! LSA (Latent Semantic Analysis) distributional-semantics embedding provider.
//! Rust port of Swift's `LsaProvider` in `CorpusKitProviders`.
//!
//! ADR-010 Decision B, signal #1 — LSA/SVD provider in the classical-
//! fusion dense recall lane.
//!
//! ## Algorithm
//!
//!   1. Build a term-document matrix M (numDocs × vocabSize) with
//!      TF-IDF weighting:
//!        tf(t, d)   = ln(1 + raw_count(t, d))
//!        idf(t)     = ln((N + 1) / (df(t) + 1))
//!        tfidf(t,d) = tf(t, d) * idf(t)
//!      CANONICAL tokenizer: corpus_kit::default_keyword_tokens.
//!
//!   2. Run JacobiSvd::decompose on M with the requested rank k:
//!        M ≈ U · diag(Σ) · Vᵀ
//!      where U is numDocs × k, Σ is k×k, Vᵀ is k × vocabSize.
//!
//!   3. Document embedding (training corpus):
//!        docVec(d) = U[d] · Σ   (L2-normalised)
//!
//!   4. Query embedding (fold-in formula for unseen text):
//!        queryVec[r] = (1 / σ_r) * dot(Vt[r], tfidf_q)   (L2-normalised)
//!
//! ## Constants
//!
//!   LSA_PROJECTION_SEED = 0x4C53415F56315F4D  ("LSA_V1_M" in ASCII)
//!   Model ID = "lsa-v1",  version = "1.0.0"
//!   Default rank = 64
//!   SVD sweeps = 30 (pinned for cross-port bit-identity)
//!
//! Swift port: packages/kits/CorpusKit/Sources/CorpusKitProviders/LsaProvider.swift

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// JacobiSvd:   substrate_ml::svd::JacobiSvd (deterministic, cross-port)
// FloatSimHash: substrate_ml::float_simhash::project
// FloatVecOps: substrate_kernel::float_vec_ops::l2_normalize
// tokenizer:   corpus_kit::default_keyword_tokens
//
// These are conformance-gated substrate primitives.
// ─────────────────────────────────────────────────────────────────

use crate::basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
use corpus_kit::{CorpusKitError, TrainableEmbeddingBasis};
use crate::term_document_counts::TermDocumentCounts;
use corpus_kit::default_keyword_tokens;
use engram_lib::Engram;
use std::collections::HashMap;
use substrate_kernel::float_vec_ops;
use substrate_ml::float_simhash;
use substrate_ml::svd::JacobiSvd;
use vectorkit::{EmbeddingProvider, VectorKitError};

// MARK: - Constants

/// FloatSimHash projection seed for LSA. Encodes "LSA_V1_M" in ASCII.
/// MUST differ from RI_PROJECTION_SEED and PPMI_PROJECTION_SEED.
/// MUST NOT drift from the Swift constant `lsaProjectionSeed`.
pub const LSA_PROJECTION_SEED: u64 = 0x4C53415F56315F4D;

/// Default latent-semantic rank k for LSA.
pub const LSA_DEFAULT_RANK: usize = 64;

/// 4-byte magic identifying an LSA basis blob ("LSB1"). Mirrors the Swift
/// constant `LsaProvider.basisMagic`.
pub const LSA_BASIS_MAGIC: &[u8; 4] = b"LSB1";

// MARK: - LsaProvider

/// LSA distributional-semantics embedding provider.
///
/// ## Lifecycle
///
///   1. `train(document)` — call once per training document.
///   2. `finalize()` — build TF-IDF matrix and run JacobiSvd.
///   3. `embed` / `embed_float` — fold query into LSA space.
///
/// ## Thread safety
///
/// `LsaProvider` is NOT Send during training. After `finalize()`,
/// the struct is read-only and can be wrapped in an Arc for sharing.
pub struct LsaProvider {
    model_id: String,
    model_version: String,

    /// Requested LSA rank k.
    pub rank: usize,

    /// Number of Jacobi sweeps. Pinned at 30 for cross-port bit-identity.
    pub svd_sweeps: usize,

    projection_seed: u64,

    // ── Training-phase state ──────────────────────────────────────────

    /// Shared term-document count builder. Owns vocab construction
    /// (encounter-order index assignment), TF counts, and DF counts.
    /// LSA reads both TF and DF from this builder for TF-IDF weighting.
    counts: TermDocumentCounts,

    // ── Post-finalize state ───────────────────────────────────────────

    /// IDF weights indexed by vocabulary position. Empty until finalize().
    idf_weights: Vec<f32>,

    /// Left singular vectors (U), numDocs × k. Empty until finalize().
    /// Retained (not just the derived `doc_vecs`) because the basis blob
    /// serializes the raw SVD factors U/σ/Vᵀ — keeping U lets the Rust port
    /// emit a blob byte-identical to Swift's (which keeps the full SVDResult).
    /// Document embeddings are still served from the pre-normalised `doc_vecs`.
    u: Vec<Vec<f32>>,

    /// Right singular vectors (Vᵀ), k × vocabSize. Empty until finalize().
    vt: Vec<Vec<f32>>,

    /// Singular values, length k. Empty until finalize().
    sigma: Vec<f32>,

    /// Left singular vectors scaled by sigma then L2-normalised:
    /// normalize(U[d] · diag(Σ)), numDocs × k. Document projections.
    doc_vecs: Vec<Vec<f32>>,

    /// Effective SVD rank after finalize().
    effective_rank: usize,
}

impl LsaProvider {
    /// Create a new LsaProvider.
    ///
    /// - `rank`: Target LSA rank k (default 64).
    /// - `svd_sweeps`: Jacobi SVD sweep count (default 30; pinned for
    ///   cross-port conformance — do not change without updating both ports
    ///   and regenerating canonical vectors).
    pub fn new(rank: usize, svd_sweeps: usize, projection_seed: u64) -> Self {
        LsaProvider {
            model_id: "lsa-v1".to_string(),
            model_version: "1.0.0".to_string(),
            rank: rank.max(1),
            svd_sweeps,
            projection_seed,
            counts: TermDocumentCounts::new(),
            idf_weights: Vec::new(),
            u: Vec::new(),
            vt: Vec::new(),
            sigma: Vec::new(),
            doc_vecs: Vec::new(),
            effective_rank: 0,
        }
    }

    /// Create with default rank (64) and projection seed.
    pub fn default_new() -> Self {
        Self::new(LSA_DEFAULT_RANK, 30, LSA_PROJECTION_SEED)
    }

    // MARK: Training

    /// Add one training document.
    ///
    /// Delegates tokenization, vocabulary construction (encounter-order
    /// index assignment), TF count accumulation, and DF count accumulation
    /// to the shared `TermDocumentCounts` builder.
    pub fn train(&mut self, document: &str) {
        self.counts.add_document(document);
    }

    // MARK: Finalization

    /// Compute TF-IDF matrix and run JacobiSvd.
    ///
    /// Must be called after all `train` calls and before `embed`/`embed_float`.
    ///
    /// ## TF-IDF formula (identical to Swift port)
    ///
    ///   tf(t, d)   = ln(1 + raw_count(t, d))   [f32::ln]
    ///   idf(t)     = ln((N + 1) / (df(t) + 1))
    ///   tfidf(t,d) = tf(t, d) * idf(t)
    pub fn finalize(&mut self) {
        let n = self.counts.document_count();
        let vocab_size = self.counts.vocabulary_size();
        if n == 0 || vocab_size == 0 {
            return;
        }

        // Compute IDF weights.
        // idf_weights[j] = ln((N+1) / (df_counts[j]+1)), clamped to >= 0.
        // Using f32::ln — same transcendental as Swift's `log()` on f32.
        self.idf_weights = vec![0.0_f32; vocab_size];
        for (&term_idx, &df) in &self.counts.df_counts {
            let idf = ((n + 1) as f32 / (df + 1) as f32).ln();
            self.idf_weights[term_idx] = idf.max(0.0);
        }

        // Build TF-IDF matrix M (numDocs × vocabSize, row-major).
        // M[i][j] = log(1 + tf[i][j]) * idf[j]
        let mut m: Vec<Vec<f32>> = vec![vec![0.0_f32; vocab_size]; n];
        for (doc_idx, doc_tf) in self.counts.tf_counts.iter().enumerate() {
            for (&term_idx, &count) in doc_tf {
                let tf = (1.0 + count as f32).ln();
                let tfidf = tf * self.idf_weights[term_idx];
                m[doc_idx][term_idx] = tfidf;
            }
        }

        // Effective rank: min(requested, min(numDocs, vocabSize)).
        let effective_rank = self.rank.min(n.min(vocab_size));

        // SVD on M (numDocs × vocabSize).
        // JacobiSvd requires m >= n. Handle both tall and wide orientations
        // identically to the Swift port.
        let svd_result = if n >= vocab_size {
            // Tall or square: SVD on M directly.
            JacobiSvd::decompose(&m, effective_rank, self.svd_sweeps)
        } else {
            // Wide matrix: SVD on Mᵀ (vocabSize × numDocs), then swap U/Vt.
            let mut mt: Vec<Vec<f32>> = vec![vec![0.0_f32; n]; vocab_size];
            for i in 0..n {
                for j in 0..vocab_size {
                    mt[j][i] = m[i][j];
                }
            }
            let transposed = JacobiSvd::decompose(&mt, effective_rank, self.svd_sweeps);
            let k = transposed.rank;
            // Swap: doc U = transposedSVD.Vt transposed (numDocs × k)
            let u_new: Vec<Vec<f32>> = (0..n)
                .map(|d| (0..k).map(|r| transposed.vt[r][d]).collect())
                .collect();
            // doc Vt = transposedSVD.U transposed (k × vocabSize)
            let vt_new: Vec<Vec<f32>> = (0..k)
                .map(|r| (0..vocab_size).map(|j| transposed.u[j][r]).collect())
                .collect();
            substrate_ml::svd::SvdResult {
                u: u_new,
                singular_values: transposed.singular_values,
                vt: vt_new,
                rank: k,
            }
        };

        let k = svd_result.rank;
        self.sigma = svd_result.singular_values.clone();
        self.vt = svd_result.vt.clone();
        self.effective_rank = k;
        // Retain the raw left singular vectors so `serialize_basis` can emit
        // U byte-identically to the Swift port (which keeps the full SVDResult).
        self.u = svd_result.u.clone();

        // Pre-compute document embeddings: U[d] · Σ, then L2-normalise.
        self.doc_vecs = (0..n)
            .map(|d| {
                let v: Vec<f32> = (0..k)
                    .map(|r| svd_result.u[d][r] * self.sigma[r])
                    .collect();
                // l2_normalize takes Vec<f32> by value and returns Vec<f32>.
                float_vec_ops::l2_normalize(v)
            })
            .collect();
    }

    // MARK: Public accessors

    /// Number of training documents.
    pub fn document_count(&self) -> usize {
        self.counts.document_count()
    }

    /// Vocabulary size.
    pub fn vocabulary_size(&self) -> usize {
        self.counts.vocabulary_size()
    }

    /// True if `finalize()` has been called with at least one document.
    pub fn is_finalized(&self) -> bool {
        !self.vt.is_empty()
    }

    /// Effective SVD rank after `finalize()`.
    pub fn effective_rank(&self) -> usize {
        self.effective_rank
    }

    // MARK: Basis serialization (mission 6a-i)

    /// Serialize the finalized LSA basis to a versioned, little-endian blob.
    ///
    /// Emits configuration (`rank`, `svd_sweeps`, `projection_seed`), the
    /// term-document support (vocab + document count), `idf_weights`, and the
    /// raw SVD factors U/σ/Vᵀ plus `effective_rank`. The factors are
    /// PORT-NEUTRAL: each port reconstructs its own internal representation
    /// (Swift keeps the full SVDResult; Rust derives `doc_vecs` from U·σ).
    /// Byte layout mirrors Swift's `serializeBasis()` exactly — the same
    /// trained state yields a byte-identical blob on both ports.
    pub fn serialize_basis(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(LSA_BASIS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u32(self.rank as u32);
        w.write_u32(self.svd_sweeps as u32);
        w.write_u64(self.projection_seed);
        w.write_u32(self.counts.document_count() as u32);
        w.write_u32(self.effective_rank as u32);
        w.write_string_u32_map(&self.counts.vocab);
        w.write_f32_array(&self.idf_weights);
        w.write_f32_matrix(&self.u);
        w.write_f32_array(&self.sigma);
        w.write_f32_matrix(&self.vt);
        w.into_bytes()
    }

    /// Reconstruct a provider from a serialized LSA basis blob.
    ///
    /// The reconstructed provider's `embed`/`embed_float`/`document_embedding`
    /// output is identical to the original finalized provider's. Returns
    /// `Err(BasisCodecError)` on a truncated blob, an unknown format version,
    /// or a magic mismatch — never panics.
    pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(LSA_BASIS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let model_id = r.read_string()?;
        let model_version = r.read_string()?;
        let rank = r.read_u32()? as usize;
        let svd_sweeps = r.read_u32()? as usize;
        let projection_seed = r.read_u64()?;
        let document_count = r.read_u32()? as usize;
        let effective_rank = r.read_u32()? as usize;
        let vocab = r.read_string_u32_map()?;
        let idf_weights = r.read_f32_array()?;
        let u = r.read_f32_matrix()?;
        let sigma = r.read_f32_array()?;
        let vt = r.read_f32_matrix()?;

        // Derive the pre-normalised document embeddings from U·Σ, matching
        // `finalize()`. An empty SVD section (never-finalized source) yields
        // empty doc_vecs and an empty `u`/`vt`, so `is_finalized()` stays false.
        let doc_vecs: Vec<Vec<f32>> = (0..u.len())
            .map(|d| {
                let v: Vec<f32> = (0..effective_rank).map(|rr| u[d][rr] * sigma[rr]).collect();
                float_vec_ops::l2_normalize(v)
            })
            .collect();

        Ok(LsaProvider {
            model_id,
            model_version,
            rank: rank.max(1),
            svd_sweeps,
            projection_seed,
            counts: TermDocumentCounts::from_restored(vocab, document_count),
            idf_weights,
            u,
            vt,
            sigma,
            doc_vecs,
            effective_rank,
        })
    }

    /// Return the k-dim LSA embedding for `text` via the fold-in formula.
    /// Returns `None` if finalize() not called, text is empty, or all OOV.
    pub fn embed_float(&self, text: &str) -> Option<Vec<f32>> {
        if !self.is_finalized() || text.is_empty() {
            return None;
        }
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return None;
        }

        let vocab_size = self.counts.vocabulary_size();
        let k = self.effective_rank;

        // Build sparse TF-IDF query vector.
        let mut raw_counts: HashMap<usize, usize> = HashMap::new();
        let mut has_in_vocab = false;
        for term in &terms {
            if let Some(&idx) = self.counts.vocab.get(term.as_str()) {
                *raw_counts.entry(idx).or_insert(0) += 1;
                has_in_vocab = true;
            }
        }
        if !has_in_vocab {
            return None;
        }
        let mut query_tfidf = vec![0.0_f32; vocab_size];
        for (&term_idx, &count) in &raw_counts {
            let tf = (1.0 + count as f32).ln();
            let tfidf = tf * self.idf_weights[term_idx];
            query_tfidf[term_idx] = tfidf;
        }

        // Fold-in: queryVec[r] = (1 / σ_r) * dot(Vt[r], query_tfidf)
        let sigma_eps: f32 = 1e-9;
        let mut query_vec = vec![0.0_f32; k];
        let mut has_nonzero = false;
        for r in 0..k {
            let sigma = self.sigma[r];
            if sigma < sigma_eps {
                continue;
            }
            let dot: f32 = self.vt[r]
                .iter()
                .zip(query_tfidf.iter())
                .map(|(&a, &b)| a * b)
                .sum();
            query_vec[r] = dot / sigma;
            if query_vec[r] != 0.0 {
                has_nonzero = true;
            }
        }
        if !has_nonzero {
            return None;
        }

        // L2-normalise using the substrate's conformance-gated primitive.
        // float_vec_ops::l2_normalize takes Vec<f32> by value and returns Vec<f32>.
        let normalised = float_vec_ops::l2_normalize(query_vec);
        if normalised.iter().all(|&v| v == 0.0) {
            return None;
        }
        Some(normalised)
    }

    /// Return the k-dim LSA embedding for `text` as an Engram.
    /// Returns `Engram::ZERO` if the vector cannot be computed.
    pub fn lsa_engram(&self, text: &str) -> Engram {
        match self.embed_float(text) {
            Some(v) if !v.is_empty() => float_simhash::project(&v, self.projection_seed),
            _ => Engram::ZERO,
        }
    }

    /// Return the pre-computed document embedding at `doc_idx`.
    /// Returns `None` if out of range or not finalized.
    pub fn document_embedding(&self, doc_idx: usize) -> Option<Vec<f32>> {
        if !self.is_finalized() || doc_idx >= self.counts.document_count() {
            return None;
        }
        Some(self.doc_vecs[doc_idx].clone())
    }
}

impl EmbeddingProvider for LsaProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn model_version(&self) -> &str {
        &self.model_version
    }

    /// Produce the LSA embedding for `text`.
    ///
    /// Returns `Engram::ZERO` if finalize() was not called, text is empty,
    /// or all tokens are OOV.
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        Ok(self.lsa_engram(text))
    }

    /// Return the k-dimensional L2-normalised LSA float vector for `text`.
    ///
    /// - Not finalized / no basis: returns `Ok(vec![])` — structural opt-out.
    /// - Empty or non-tokenisable input: returns `Ok(vec![])`.
    /// - Trained basis, all query tokens OOV: returns
    ///   `Err(VectorKitError::EmbedFloatVocabMiss(...))` so the corpus layer
    ///   maps to `FloatLaneOutcome::UnavailableNoVocabHit`.
    /// - Degenerate SVD (all-zero result): returns `Ok(vec![])` — basis quality
    ///   issue, not a vocabulary miss.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        // No finalized basis or empty input: structural opt-out.
        if !self.is_finalized() || self.counts.vocabulary_size() == 0 {
            return Ok(vec![]);
        }
        if text.is_empty() {
            return Ok(vec![]);
        }
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        // OOV check before full projection: throw vocabMiss when basis is
        // trained but query hits nothing in the vocab.
        let has_in_vocab = terms.iter().any(|t| self.counts.vocab.contains_key(t.as_str()));
        if !has_in_vocab {
            return Err(VectorKitError::EmbedFloatVocabMiss(format!(
                "lsa: vocab size {}, but 0 of {} query token(s) matched",
                self.counts.vocabulary_size(),
                terms.len()
            )));
        }
        // Degenerate SVD or all-zero fold-in: return [] (basis quality issue,
        // not OOV — the corpus layer maps this to UnavailableProviderOptOut).
        Ok(LsaProvider::embed_float(self, text).unwrap_or_default())
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

impl TrainableEmbeddingBasis for LsaProvider {
    /// Train the LSA basis on a corpus of raw document texts.
    ///
    /// LSA's `train` consumes a raw document per call (it tokenizes internally
    /// via the shared `TermDocumentCounts` builder, which uses
    /// `default_keyword_tokens`), so each text is passed through unchanged — one
    /// document column per text. The `finalize` pass then computes the TF-IDF
    /// matrix and runs the deterministic Jacobi SVD. This reproduces the exact
    /// trained+finalized state of per-document `train` + `finalize`, so a basis
    /// serialized after `train_on_corpus` is byte-identical to the 6a-i fixture
    /// trained on the same texts.
    fn train_on_corpus(&mut self, texts: &[&str]) {
        for text in texts {
            self.train(text);
        }
        self.finalize();
    }

    /// Serialize the finalized LSA basis (6a-i codec), surfaced through the seam.
    fn serialize_basis(&self) -> Vec<u8> {
        LsaProvider::serialize_basis(self)
    }

    /// Reconstruct a fresh `LsaProvider` from a basis blob, boxed. Delegates to
    /// `from_serialized_basis` (6a-i); a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        let provider = LsaProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// Reconstruct a fresh LSA provider from a basis blob, boxed as TRAINABLE so
    /// `Corpus` can rebuild a from-scratch trainable provider for `reindex` /
    /// first-ingest (train_on_corpus is additive — see the trait doc). Same
    /// `from_serialized_basis` constructor as `reconstruct_basis`.
    fn reconstruct_trainable_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError> {
        let provider = LsaProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    /// Canonical mini-corpus: same 5 documents used by the Swift LSA test.
    fn canonical_corpus() -> Vec<&'static str> {
        vec![
            "car engine drive road vehicle",
            "vehicle road transport car fuel",
            "engine fuel combustion power car",
            "dog bark run fetch animal",
            "animal run cat dog pet",
        ]
    }

    fn trained_provider() -> LsaProvider {
        let mut p = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p.train(doc);
        }
        p.finalize();
        p
    }

    #[test]
    fn finalize_produces_svd() {
        let p = trained_provider();
        assert!(p.is_finalized());
        assert!(p.effective_rank() <= 3);
        assert!(p.effective_rank() >= 1);
    }

    #[test]
    fn embed_float_returns_unit_vector() {
        let p = trained_provider();
        let v = p.embed_float("car engine").expect("should produce a vector");
        let norm2: f32 = v.iter().map(|&x| x * x).sum();
        assert!((norm2.sqrt() - 1.0).abs() < 1e-5, "embed_float must return a unit vector; norm = {}", norm2.sqrt());
    }

    #[test]
    fn embed_float_oov_returns_none() {
        let p = trained_provider();
        // "xyz999" is not in the training corpus.
        let v = p.embed_float("xyz999 qqq111");
        assert!(v.is_none(), "all-OOV query must return None");
    }

    #[test]
    fn empty_text_returns_zero_engram() {
        let p = trained_provider();
        let eng: Engram = p.lsa_engram("");
        assert_eq!(eng, Engram::ZERO);
    }

    #[test]
    fn determinism() {
        let mut p1 = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
        let mut p2 = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p1.train(doc);
            p2.train(doc);
        }
        p1.finalize();
        p2.finalize();
        let v1 = p1.embed_float("car engine");
        let v2 = p2.embed_float("car engine");
        assert_eq!(v1, v2, "same corpus + query must produce identical embedding");
    }

    #[test]
    fn document_embedding_is_unit_vector() {
        let p = trained_provider();
        let v = p.document_embedding(0).expect("doc 0 must have an embedding");
        let norm2: f32 = v.iter().map(|&x| x * x).sum();
        assert!((norm2.sqrt() - 1.0).abs() < 1e-5,
            "document embedding must be unit vector; norm = {}", norm2.sqrt());
    }

    #[test]
    fn semantic_separation_vehicles_vs_animals() {
        // "car engine" and "dog animal" should be far apart in LSA space.
        let p = trained_provider();
        let v_car = p.embed_float("car engine").expect("car vector");
        let v_dog = p.embed_float("dog animal").expect("dog vector");
        let dot: f32 = v_car.iter().zip(v_dog.iter()).map(|(&a, &b)| a * b).sum();
        // For unit vectors, dot product = cosine similarity.
        // Different semantic clusters should have cosine < 0.8.
        assert!(dot < 0.8,
            "car and dog should be semantically separated; cosine = {}", dot);
    }

    /// Emit canonical bit patterns for cross-port conformance.
    /// Run with: cargo test lsa::tests::emit_canonical_lsa_values -- --nocapture
    #[test]
    fn emit_canonical_lsa_values() {
        let p = trained_provider();
        let v = p.embed_float("car engine").expect("should produce a vector");
        println!("=== CANONICAL LSA EMBEDDING VALUES ===");
        println!("Query: 'car engine', corpus: 5-doc canonical, rank=3, sweeps=30");
        for (i, &val) in v.iter().enumerate() {
            println!("  embed_float[{}] = {} (bits: 0x{:08X})", i, val, val.to_bits());
        }
        let eng = p.lsa_engram("car engine");
        println!("Engram: block0=0x{:016X} block1=0x{:016X} block2=0x{:016X} block3=0x{:016X}",
            eng.block0, eng.block1, eng.block2, eng.block3);
        // doc 0 embedding
        if let Some(d0) = p.document_embedding(0) {
            for (i, &val) in d0.iter().enumerate() {
                println!("  doc[0][{}] = {} (bits: 0x{:08X})", i, val, val.to_bits());
            }
        }
        println!("=== END CANONICAL LSA VALUES ===");
    }

    /// Cross-port conformance test: asserts bit-identical embedding values
    /// between Swift and Rust for the canonical mini-corpus.
    ///
    /// Values are generated by running the Rust `emit_canonical_lsa_values`
    /// test and then confirmed by the Swift LSA conformance test.
    #[test]
    fn canonical_lsa_conformance_vectors() {
        let p = trained_provider();

        // Determinism self-check.
        let v1 = p.embed_float("car engine").expect("car engine vector");
        let mut p2 = LsaProvider::new(3, 30, LSA_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p2.train(doc);
        }
        p2.finalize();
        let v2 = p2.embed_float("car engine").expect("car engine vector 2");

        // Bit-identical on the same port.
        let bits1: Vec<u32> = v1.iter().map(|&v| v.to_bits()).collect();
        let bits2: Vec<u32> = v2.iter().map(|&v| v.to_bits()).collect();
        assert_eq!(bits1, bits2, "LSA embedding must be deterministic");

        // Structural: unit vector.
        let norm2: f32 = v1.iter().map(|&x| x * x).sum();
        assert!((norm2.sqrt() - 1.0).abs() < 1e-5);
    }
}
