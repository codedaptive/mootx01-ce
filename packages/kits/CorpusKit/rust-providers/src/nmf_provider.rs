//! NMF (Non-Negative Matrix Factorization) distributional-semantics
//! embedding provider. Rust port of Swift's `NmfProvider` in
//! `CorpusKitProviders`.
//!
//! ADR-010 Decision B — NMF latent-factor provider in the classical-
//! fusion dense recall lane.
//!
//! ## Algorithm
//!
//!   1. Build a TF-weighted term-document matrix V (vocabSize × numDocs):
//!        tf(t, d) = ln(1 + raw_count(t, d))   — log-smoothed, always >= 0
//!      NMF requires V >= 0; TF satisfies this.
//!      IDF is NOT applied: NMF is most stable without it on small corpora.
//!      CANONICAL tokenizer: corpus_kit::default_keyword_tokens.
//!
//!   2. Factorize V ≈ W · H via substrate_ml NMFAlternatingLeastSquares
//!      (REUSED, not reimplemented):
//!        V ∈ R+^{m×n}  (m = vocabSize, n = numDocs)
//!        W ∈ R+^{m×k}  (term-factor loadings)
//!        H ∈ R+^{k×n}  (document factor loadings)
//!      Fixed iteration count (tolerance=0) → deterministic output.
//!
//!   3. Document embedding: column d of H = H[r][d] for r in 0..<k,
//!      L2-normalised via substrate_kernel::float_vec_ops::l2_normalize.
//!
//!   4. Query embedding (fold-in formula):
//!        queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
//!      where q is the TF query vector. L2-normalised. OOV terms → 0.
//!
//!   5. Project to Engram via substrate_ml::float_simhash::project with
//!      NMF_PROJECTION_SEED.
//!
//! ## NMF kernel reuse
//!
//!   substrate_ml::nmf::NMFAlternatingLeastSquares is reused directly.
//!   No separate NMF implementation here (Gate-2 requirement).
//!   tolerance=0 forces fixed iteration count for bit-identical output.
//!
//! ## Constants
//!
//!   NMF_PROJECTION_SEED = 0x4E4D465F56315F4D  ("NMF_V1_M" in ASCII)
//!   Model ID = "nmf-v1",  version = "1.0.0"
//!   Default rank k = 32
//!   Default maxIterations = 100
//!   Factorization seed = 0xDEADBEEFCAFEBABE
//!
//! Swift port: packages/kits/CorpusKit/Sources/CorpusKitProviders/NmfProvider.swift

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// NMFAlternatingLeastSquares: substrate_ml::nmf::NMFAlternatingLeastSquares
// FloatSimHash:               substrate_ml::float_simhash::project
// FloatVecOps:                substrate_kernel::float_vec_ops::l2_normalize
// tokenizer:                  corpus_kit::default_keyword_tokens
//
// These are conformance-gated substrate primitives.
// ─────────────────────────────────────────────────────────────────

use crate::term_document_counts::TermDocumentCounts;
use corpus_kit::default_keyword_tokens;
use engram_lib::Engram;
use std::collections::HashMap;
use substrate_kernel::float_vec_ops;
use substrate_ml::float_simhash;
use substrate_ml::nmf::NMFAlternatingLeastSquares;
use vectorkit::{EmbeddingProvider, VectorKitError};

// MARK: - Constants

/// FloatSimHash projection seed for NMF. Encodes "NMF_V1_M" in ASCII.
/// MUST differ from LSA_PROJECTION_SEED, RI_PROJECTION_SEED, and
/// PPMI_PROJECTION_SEED. MUST NOT drift from the Swift constant
/// `nmfProjectionSeed`.
pub const NMF_PROJECTION_SEED: u64 = 0x4E4D465F56315F4D;

/// Default NMF rank k (latent dimensionality).
pub const NMF_DEFAULT_RANK: usize = 32;

/// Default fixed iteration count.
/// tolerance=0 disables convergence stopping: every factorization runs
/// exactly this many iterations — required for bit-identical output.
pub const NMF_DEFAULT_ITERATIONS: usize = 100;

/// SplitMix64 seed for NMF factor initialization.
/// Identical to the Swift constant `nmfFactorizationSeed`.
pub const NMF_FACTORIZATION_SEED: u64 = 0xDEADBEEFCAFEBABE;

// MARK: - NmfProvider

/// NMF distributional-semantics embedding provider.
///
/// ## Lifecycle
///
///   1. `train(document)` — call once per training document.
///   2. `finalize()` — build TF matrix and run NMF factorization.
///   3. `embed` / `embed_float` — fold query into NMF space.
///
/// ## Thread safety
///
/// `NmfProvider` is NOT Send during training. After `finalize()`,
/// the struct is read-only and can be wrapped in an Arc for sharing.
pub struct NmfProvider {
    model_id: String,
    model_version: String,

    /// NMF rank k (latent dimensionality).
    pub rank: usize,

    /// Fixed iteration count. tolerance=0 disables convergence stopping.
    pub max_iterations: usize,

    /// SplitMix64 seed for factor initialization.
    pub seed: u64,

    projection_seed: u64,

    // ── Training-phase state ──────────────────────────────────────────

    /// Shared term-document count builder. Owns vocab construction
    /// (encounter-order index assignment) and TF counts.
    /// NMF uses only TF counts (not DF counts); the builder accumulates
    /// DF counts anyway (zero cost) so the shared type is uniform.
    counts: TermDocumentCounts,

    // ── Post-finalize state ───────────────────────────────────────────

    /// W factor (vocabSize × k). Populated at finalize(). Empty until then.
    w: Vec<Vec<f32>>,

    /// Pre-computed document embeddings: L2-normalised column d of H.
    /// doc_embeddings[d] has length effectiveRank.
    doc_embeddings: Vec<Vec<f32>>,

    /// Effective NMF rank after finalize().
    effective_rank: usize,
}

impl NmfProvider {
    /// Create a new NmfProvider.
    ///
    /// - `rank`: Target NMF rank k (default 32).
    /// - `max_iterations`: Fixed iteration count (default 100; tolerance=0
    ///   disables convergence stopping — pinned for cross-port conformance).
    /// - `seed`: SplitMix64 seed for factor initialization.
    /// - `projection_seed`: FloatSimHash seed.
    pub fn new(rank: usize, max_iterations: usize, seed: u64, projection_seed: u64) -> Self {
        NmfProvider {
            model_id: "nmf-v1".to_string(),
            model_version: "1.0.0".to_string(),
            rank: rank.max(1),
            max_iterations: max_iterations.max(1),
            seed,
            projection_seed,
            counts: TermDocumentCounts::new(),
            w: Vec::new(),
            doc_embeddings: Vec::new(),
            effective_rank: 0,
        }
    }

    /// Create with default rank, iterations, and projection seed.
    pub fn default_new() -> Self {
        Self::new(
            NMF_DEFAULT_RANK,
            NMF_DEFAULT_ITERATIONS,
            NMF_FACTORIZATION_SEED,
            NMF_PROJECTION_SEED,
        )
    }

    // MARK: Training

    /// Add one training document.
    ///
    /// Delegates tokenization, vocabulary construction (encounter-order
    /// index assignment), and TF count accumulation to the shared
    /// `TermDocumentCounts` builder.
    pub fn train(&mut self, document: &str) {
        self.counts.add_document(document);
    }

    // MARK: Finalization

    /// Build the TF matrix and run NMF factorization.
    ///
    /// Must be called after all `train` calls and before `embed`/`embed_float`.
    ///
    /// ## TF weighting (identical to Swift port)
    ///
    ///   tf(t, d) = ln(1 + raw_count(t, d))   [f32::ln]
    ///
    /// ## Fixed iteration count
    ///
    /// tolerance=0.0 disables convergence stopping: abs(prev_error - err) < 0.0
    /// is always false, so the loop runs exactly `max_iterations` iterations.
    pub fn finalize(&mut self) {
        let num_docs = self.counts.document_count();
        let vocab_size = self.counts.vocabulary_size();
        if num_docs == 0 || vocab_size == 0 {
            return;
        }

        // V is vocabSize × numDocs: V[term][doc] = ln(1 + tf[doc][term]).
        // Built from the shared builder's TF counts.
        // This matches the Swift layout: V[termIdx][docIdx].
        let mut v: Vec<Vec<f32>> = vec![vec![0.0_f32; num_docs]; vocab_size];
        for (doc_idx, doc_tf) in self.counts.tf_counts.iter().enumerate() {
            for (&term_idx, &count) in doc_tf {
                // f32::ln matches Swift's log() on f32 — both are logf.
                v[term_idx][doc_idx] = (1.0 + count as f32).ln();
            }
        }

        // Effective rank: min(requested, min(vocabSize, numDocs)).
        let effective_rank = self.rank.min(vocab_size.min(num_docs));

        // Run SubstrateML NMF with tolerance=0.0 (fixed iteration count).
        // tolerance=0.0 makes abs(prev_error - err) < 0.0 always false, so
        // the loop runs to max_iterations exactly. This is intentional.
        // The Rust NMF takes estate+ts for VizGraph telemetry; we pass
        // "" and 0.0 (never calling SystemTime::now() — determinism invariant).
        let result = NMFAlternatingLeastSquares::factorize(
            &v,
            effective_rank,
            self.max_iterations,
            0.0,                   // tolerance=0 → fixed iteration count
            self.seed,
            "",                    // estate tag for telemetry (unused here)
            0.0,                   // ts: caller-supplied epoch seconds (determinism invariant)
        );

        self.effective_rank = result.rank;
        // Store W (vocabSize × k) for query fold-in.
        self.w = result.w;
        let h = result.h;

        // Pre-compute document embeddings: column d of H = H[r][d] for r in 0..<k.
        // L2-normalise via the substrate's conformance-gated primitive.
        self.doc_embeddings = (0..num_docs)
            .map(|d| {
                let col: Vec<f32> = (0..effective_rank).map(|r| h[r][d]).collect();
                // l2_normalize takes Vec<f32> by value and returns Vec<f32>.
                float_vec_ops::l2_normalize(col)
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
        !self.w.is_empty()
    }

    /// Effective NMF rank after `finalize()`.
    pub fn effective_rank(&self) -> usize {
        self.effective_rank
    }

    /// Return the k-dim NMF embedding for `text` via the fold-in formula.
    /// Returns `None` if finalize() not called, text is empty, or all OOV.
    ///
    /// ## Fold-in formula
    ///
    ///   queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
    ///
    /// where q is the TF-weighted query vector (sparse, vocabSize entries).
    pub fn embed_float_nmf(&self, text: &str) -> Option<Vec<f32>> {
        if !self.is_finalized() || text.is_empty() {
            return None;
        }
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return None;
        }

        let vocab_size = self.counts.vocabulary_size();
        let k = self.effective_rank;
        let eps: f32 = 1e-9;

        // Build sparse TF query vector.
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
        // TF weights: ln(1 + count), same as the training matrix.
        let mut q = vec![0.0_f32; vocab_size];
        for (&term_idx, &count) in &raw_counts {
            q[term_idx] = (1.0 + count as f32).ln();
        }

        // Fold-in: queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
        // W is vocabSize × k: self.w[i][r] is the (i, r) entry.
        // Column r of W: self.w[0][r], self.w[1][r], ..., self.w[vocabSize-1][r].
        let mut query_vec = vec![0.0_f32; k];
        let mut has_nonzero = false;
        for r in 0..k {
            let mut dot = 0.0_f32;
            let mut norm_sq = 0.0_f32;
            for i in 0..vocab_size {
                let wir = self.w[i][r];
                dot += wir * q[i];
                norm_sq += wir * wir;
            }
            query_vec[r] = dot / (norm_sq + eps);
            if query_vec[r] != 0.0 {
                has_nonzero = true;
            }
        }
        if !has_nonzero {
            return None;
        }

        // L2-normalise using the substrate's conformance-gated primitive.
        let normalised = float_vec_ops::l2_normalize(query_vec);
        if normalised.iter().all(|&v| v == 0.0) {
            return None;
        }
        Some(normalised)
    }

    /// Return the NMF embedding for `text` as an Engram.
    /// Returns `Engram::ZERO` if the vector cannot be computed.
    pub fn nmf_engram(&self, text: &str) -> Engram {
        match self.embed_float_nmf(text) {
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
        Some(self.doc_embeddings[doc_idx].clone())
    }
}

impl EmbeddingProvider for NmfProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn model_version(&self) -> &str {
        &self.model_version
    }

    /// Produce the NMF Engram for `text`.
    ///
    /// Returns `Engram::ZERO` if finalize() was not called, text is empty,
    /// or all tokens are OOV.
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        Ok(self.nmf_engram(text))
    }

    /// Return the k-dimensional L2-normalised NMF float vector for `text`.
    ///
    /// Returns an empty Vec if finalize() was not called, text is empty,
    /// or all tokens are OOV.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        Ok(NmfProvider::embed_float_nmf(self, text).unwrap_or_default())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    /// Canonical mini-corpus: same 5 documents used by the Swift NMF test.
    fn canonical_corpus() -> Vec<&'static str> {
        vec![
            "car engine drive road vehicle",
            "vehicle road transport car fuel",
            "engine fuel combustion power car",
            "dog bark run fetch animal",
            "animal run cat dog pet",
        ]
    }

    fn trained_provider() -> NmfProvider {
        let mut p = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p.train(doc);
        }
        p.finalize();
        p
    }

    #[test]
    fn finalize_produces_nmf() {
        let p = trained_provider();
        assert!(p.is_finalized());
        assert!(p.effective_rank() <= 3);
        assert!(p.effective_rank() >= 1);
    }

    #[test]
    fn embed_float_returns_unit_vector() {
        let p = trained_provider();
        let v = p.embed_float_nmf("car engine").expect("should produce a vector");
        let norm2: f32 = v.iter().map(|&x| x * x).sum();
        assert!(
            (norm2.sqrt() - 1.0).abs() < 1e-5,
            "embed_float must return a unit vector; norm = {}",
            norm2.sqrt()
        );
    }

    #[test]
    fn embed_float_oov_returns_none() {
        let p = trained_provider();
        let v = p.embed_float_nmf("xyz999 qqq111");
        assert!(v.is_none(), "all-OOV query must return None");
    }

    #[test]
    fn empty_text_returns_zero_engram() {
        let p = trained_provider();
        let eng: Engram = p.nmf_engram("");
        assert_eq!(eng, Engram::ZERO);
    }

    #[test]
    fn determinism() {
        // Two identical training runs must produce identical embeddings.
        let mut p1 = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        let mut p2 = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p1.train(doc);
            p2.train(doc);
        }
        p1.finalize();
        p2.finalize();
        let v1 = p1.embed_float_nmf("car engine");
        let v2 = p2.embed_float_nmf("car engine");
        assert_eq!(v1, v2, "same corpus + query must produce identical embedding");
    }

    #[test]
    fn document_embedding_is_unit_vector() {
        let p = trained_provider();
        let v = p.document_embedding(0).expect("doc 0 must have an embedding");
        let norm2: f32 = v.iter().map(|&x| x * x).sum();
        assert!(
            (norm2.sqrt() - 1.0).abs() < 1e-5,
            "document embedding must be unit vector; norm = {}",
            norm2.sqrt()
        );
    }

    #[test]
    fn semantic_separation_vehicles_vs_animals() {
        // "car engine" and "dog animal" should be far apart in NMF space.
        let p = trained_provider();
        let v_car = p.embed_float_nmf("car engine").expect("car vector");
        let v_dog = p.embed_float_nmf("dog animal").expect("dog vector");
        let dot: f32 = v_car.iter().zip(v_dog.iter()).map(|(&a, &b)| a * b).sum();
        // NMF with rank=3 on 5 docs separates the two semantic clusters.
        assert!(
            dot < 0.9,
            "car and dog should be semantically separated; cosine = {}",
            dot
        );
    }

    #[test]
    fn projection_seed_is_distinct() {
        // NMF seed must differ from LSA, RI, and PPMI seeds for bucket isolation.
        assert_ne!(NMF_PROJECTION_SEED, crate::lsa::LSA_PROJECTION_SEED,
            "NMF and LSA projection seeds must differ");
        assert_ne!(NMF_PROJECTION_SEED, crate::random_indexing::RI_PROJECTION_SEED,
            "NMF and RI projection seeds must differ");
        assert_ne!(NMF_PROJECTION_SEED, crate::ppmi::PPMI_PROJECTION_SEED,
            "NMF and PPMI projection seeds must differ");
    }

    /// Emit canonical bit patterns for cross-port conformance.
    /// Run with: cargo test nmf_provider::tests::emit_canonical_nmf_values -- --nocapture
    #[test]
    fn emit_canonical_nmf_values() {
        let p = trained_provider();
        let v = p.embed_float_nmf("car engine").expect("should produce a vector");
        println!("=== CANONICAL NMF EMBEDDING VALUES ===");
        println!("Query: 'car engine', corpus: 5-doc canonical, rank=3, iterations=100, seed=0xDEADBEEFCAFEBABE");
        for (i, &val) in v.iter().enumerate() {
            println!("  embed_float[{}] = {} (bits: 0x{:08X})", i, val, val.to_bits());
        }
        let eng = p.nmf_engram("car engine");
        println!(
            "Engram: block0=0x{:016X} block1=0x{:016X} block2=0x{:016X} block3=0x{:016X}",
            eng.block0, eng.block1, eng.block2, eng.block3
        );
        if let Some(d0) = p.document_embedding(0) {
            for (i, &val) in d0.iter().enumerate() {
                println!("  doc[0][{}] = {} (bits: 0x{:08X})", i, val, val.to_bits());
            }
        }
        println!("=== END CANONICAL NMF VALUES ===");
    }

    /// Cross-port conformance test: asserts bit-identical embedding values
    /// between Swift and Rust for the canonical mini-corpus.
    ///
    /// Canonical values are pinned from emit_canonical_nmf_values output and
    /// confirmed identical in both the Swift and Rust emit runs.
    #[test]
    fn canonical_nmf_conformance_vectors() {
        let p = trained_provider();

        // Determinism self-check: two identical training runs give same result.
        let v1 = p.embed_float_nmf("car engine").expect("car engine vector");
        let mut p2 = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        for doc in canonical_corpus() {
            p2.train(doc);
        }
        p2.finalize();
        let v2 = p2.embed_float_nmf("car engine").expect("car engine vector 2");

        // Bit-identical on the same port (determinism).
        let bits1: Vec<u32> = v1.iter().map(|&v| v.to_bits()).collect();
        let bits2: Vec<u32> = v2.iter().map(|&v| v.to_bits()).collect();
        assert_eq!(bits1, bits2, "NMF embedding must be deterministic");

        // Structural: unit vector.
        let norm2: f32 = v1.iter().map(|&x| x * x).sum();
        assert!((norm2.sqrt() - 1.0).abs() < 1e-5);

        // Cross-port bit-identity pins (confirmed against Swift emit output):
        //   embed_float[0] = 0.84187937 (bits: 0x3F578568)
        //   embed_float[1] = 0.53966576 (bits: 0x3F0A2789)
        //   embed_float[2] = 0          (bits: 0x00000000)
        assert_eq!(v1.len(), 3, "rank-3 NMF must return 3-dim vector");
        assert_eq!(v1[0].to_bits(), 0x3F578568, "embed_float[0] bit-identity with Swift");
        assert_eq!(v1[1].to_bits(), 0x3F0A2789, "embed_float[1] bit-identity with Swift");
        assert_eq!(v1[2].to_bits(), 0x00000000, "embed_float[2] bit-identity with Swift");

        // Engram bit-identity pins:
        // block0=0xB7AB5528EF12D061 block1=0xC452A7DEFE999697
        // block2=0x325CFC0C6D14A93F block3=0xA1591A2717EBC02B
        let eng = p.nmf_engram("car engine");
        assert_eq!(eng.block0, 0xB7AB5528EF12D061, "Engram block0 bit-identity with Swift");
        assert_eq!(eng.block1, 0xC452A7DEFE999697, "Engram block1 bit-identity with Swift");
        assert_eq!(eng.block2, 0x325CFC0C6D14A93F, "Engram block2 bit-identity with Swift");
        assert_eq!(eng.block3, 0xA1591A2717EBC02B, "Engram block3 bit-identity with Swift");

        // Document embedding bit-identity pins for doc 0:
        // doc[0][0] = 0.015156989 (bits: 0x3C785505)
        // doc[0][1] = 0.9998851   (bits: 0x3F7FF878)
        // doc[0][2] = 0           (bits: 0x00000000)
        let d0 = p.document_embedding(0).expect("doc 0 must have an embedding");
        assert_eq!(d0.len(), 3, "rank-3 NMF must produce 3-dim document embedding");
        assert_eq!(d0[0].to_bits(), 0x3C785505, "doc[0][0] bit-identity with Swift");
        assert_eq!(d0[1].to_bits(), 0x3F7FF878, "doc[0][1] bit-identity with Swift");
        assert_eq!(d0[2].to_bits(), 0x00000000, "doc[0][2] bit-identity with Swift");
    }
}
