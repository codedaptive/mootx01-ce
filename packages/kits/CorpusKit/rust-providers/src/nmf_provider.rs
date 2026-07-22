//! NMF (Non-Negative Matrix Factorization) distributional-semantics
//! embedding provider. Rust port of Swift's `NmfProvider` in
//! `CorpusKitProviders`.
//!
//! — NMF latent-factor provider in the classical-
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
//!   Model ID = "nmf-v1",  version = "1.1.0"
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

use crate::basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
use corpus_kit::{CorpusKitError, TrainableEmbeddingBasis};
use crate::term_document_counts::TermDocumentCounts;
use crate::reduced_vocab::{select_reduced_vocabulary, DEFAULT_REDUCED_VOCAB_CAP};
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

/// 4-byte magic identifying an NMF basis blob ("NMB1"). Mirrors the Swift
/// constant `NmfProvider.basisMagic`.
pub const NMF_BASIS_MAGIC: &[u8; 4] = b"NMB1";

/// 4-byte magic identifying an NMF COUNTS blob ("NMFC"). Holds only the
/// lightweight trigger anchors (vocabulary + document count), not the W/H
/// factors — the heavy TF matrix is re-tokenized at refactor. Mirrors the Swift
/// constant `NmfProvider.countsMagic`.
pub const NMF_COUNTS_MAGIC: &[u8; 4] = b"NMFC";

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

    /// H factor (k × numDocs). Populated at finalize(). Empty until then.
    /// Retained (not just the derived `doc_embeddings`) because the basis
    /// blob serializes the raw factors W/H — keeping H lets the Rust port
    /// emit a blob byte-identical to Swift's (which keeps the full
    /// NMFFactorization). Document embeddings are served from `doc_embeddings`.
    h: Vec<Vec<f32>>,

    /// Pre-computed document embeddings: L2-normalised column d of H.
    /// doc_embeddings[d] has length effectiveRank.
    doc_embeddings: Vec<Vec<f32>>,

    /// Effective NMF rank after finalize().
    effective_rank: usize,

    /// Reduced-vocabulary cap K for the dense factorization.
    reduced_vocab_cap: usize,

    /// The frozen reduced vocabulary (term → reduced row) the basis was trained
    /// on. Projection + serialization key on THIS, not the full
    /// `counts.vocab`. Empty until `finalize()`.
    basis_vocab: HashMap<String, usize>,
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
        Self::with_parameters("nmf-v1", "1.1.0", rank, max_iterations, seed, projection_seed)
    }

    /// Build with explicit identity — the Swift `NmfProvider(modelID:modelVersion:…)`
    /// twin (fixture tests pin the historical 1.0 envelope through this).
    pub fn with_parameters(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        rank: usize,
        max_iterations: usize,
        seed: u64,
        projection_seed: u64,
    ) -> Self {
        NmfProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            rank: rank.max(1),
            max_iterations: max_iterations.max(1),
            seed,
            projection_seed,
            counts: TermDocumentCounts::new(),
            w: Vec::new(),
            h: Vec::new(),
            doc_embeddings: Vec::new(),
            effective_rank: 0,
            reduced_vocab_cap: DEFAULT_REDUCED_VOCAB_CAP,
            basis_vocab: HashMap::new(),
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
        if num_docs == 0 || self.counts.vocabulary_size() == 0 {
            return;
        }

        // factor over a reduced, informative sub-vocabulary so the
        // dense NMF is `K × numDocs` (feasible) instead of `full-vocab × numDocs`
        // (infeasible). Shared with LSA; frozen here; drives query projection.
        // `vocab_size` below is the REDUCED row count — the factorize + fold-in
        // key on it.
        let reduced = select_reduced_vocabulary(
            &self.counts.vocab,
            &self.counts.df_counts,
            num_docs,
            self.reduced_vocab_cap,
        );
        let vocab_size = reduced.size();
        if vocab_size == 0 {
            // Full state reset required to match the Swift empty-reduction path.
            //
            // Swift sets `basisVocab = reduced.termToColumn` (empty) BEFORE the
            // guard that clears `nmf` and `docEmbeddings`, so Swift automatically
            // clears basisVocab in the zero-vocab case. Rust's early return fires
            // BEFORE the `self.basis_vocab = reduced.term_to_column` assignment at
            // the non-zero path, so without this explicit reset, `h`,
            // `effective_rank`, and `basis_vocab` from a prior successful
            // `finalize()` remain stale.
            //
            // If left stale, `serialize_basis()` writes the new (larger)
            // `document_count` together with the stale `effective_rank` and stale
            // `h`. `from_serialized_basis()` then drives a per-document rebuild
            // loop that indexes `h_factor[rr][d]` for every serialized document,
            // causing an out-of-bounds panic when the stale `h` has fewer rows or
            // columns than the new `document_count`. The full reset makes the
            // serialized basis self-consistent (empty) so the round-trip is safe.
            self.w = Vec::new();
            self.h = Vec::new();
            self.doc_embeddings = Vec::new();
            self.effective_rank = 0;
            self.basis_vocab = HashMap::new();
            return;
        }

        // V is K × numDocs: V[reducedRow][doc] = ln(1 + tf[doc][term]). Map each
        // doc's TF entries whose term is in the reduced vocab to its reduced row;
        // full-vocab terms outside the reduced set are dropped.
        let mut v: Vec<Vec<f32>> = vec![vec![0.0_f32; num_docs]; vocab_size];
        for (doc_idx, doc_tf) in self.counts.tf_counts.iter().enumerate() {
            for (&full_idx, &count) in doc_tf {
                if let Some(&row) = reduced.full_index_to_column.get(&full_idx) {
                    // f32::ln matches Swift's log() on f32 — both are logf.
                    v[row][doc_idx] = (1.0 + count as f32).ln();
                }
            }
        }
        self.basis_vocab = reduced.term_to_column;

        // Effective rank: min(requested, min(K, numDocs)).
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
        // Retain H (k × numDocs) so `serialize_basis` can emit it byte-
        // identically to the Swift port (which keeps the full NMFFactorization).
        self.h = result.h;

        // Pre-compute document embeddings: column d of H = H[r][d] for r in 0..<k.
        // L2-normalise via the substrate's conformance-gated primitive.
        self.doc_embeddings = (0..num_docs)
            .map(|d| {
                let col: Vec<f32> = (0..effective_rank).map(|r| self.h[r][d]).collect();
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

    // MARK: Basis serialization (mission 6a-i)

    /// Serialize the finalized NMF basis to a versioned, little-endian blob.
    ///
    /// Emits configuration (`rank`, `max_iterations`, `seed`,
    /// `projection_seed`), the term-document support (vocab + document count),
    /// and the raw factors W (vocabSize × k) and H (k × numDocs) plus
    /// `effective_rank`. The factors are PORT-NEUTRAL, so the same trained
    /// state yields a byte-identical blob on both ports. Byte layout mirrors
    /// Swift's `serializeBasis()` exactly.
    /// Serialize the maintained trigger anchors (vocabulary + document count).
    /// Byte-identical to the Swift `NmfProvider.serializeCounts`. The W/H factors
    /// and per-document TF rows are not persisted — the TF matrix is re-tokenized
    /// at refactor.
    ///
    /// Blob layout (after MAGIC + version):
    ///   model_id (string) | model_version (string) | projection_seed (u64)
    ///   | document_count (u32) | vocab (String→u32 map, byte-sorted keys)
    pub fn serialize_counts(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(NMF_COUNTS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_u32(self.counts.document_count() as u32);
        w.write_string_u32_map(&self.counts.vocab);
        w.into_bytes()
    }

    /// Restore the maintained vocabulary + document count from a counts blob into
    /// this provider. Does not touch the W/H factors. Returns
    /// `Err(BasisCodecError)` on a truncated/unknown/mismatched blob — never panics.
    pub fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(NMF_COUNTS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let _model_id = r.read_string()?;
        let _model_version = r.read_string()?;
        let _projection_seed = r.read_u64()?;
        let document_count = r.read_u32()? as usize;
        let vocab = r.read_string_u32_map()?;
        self.counts = TermDocumentCounts::from_restored(vocab, document_count);
        Ok(())
    }

    pub fn serialize_basis(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(NMF_BASIS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u32(self.rank as u32);
        w.write_u32(self.max_iterations as u32);
        w.write_u64(self.seed);
        w.write_u64(self.projection_seed);
        w.write_u32(self.counts.document_count() as u32);
        w.write_u32(self.effective_rank as u32);
        // persist the REDUCED basis vocab; projection keys on it. The
        // full counts vocab is persisted by serialize_counts as the drift anchor.
        w.write_string_u32_map(&self.basis_vocab);
        w.write_f32_matrix(&self.w);
        w.write_f32_matrix(&self.h);
        w.into_bytes()
    }

    /// Reconstruct a provider from a serialized NMF basis blob.
    ///
    /// The reconstructed provider's `embed`/`embed_float`/`document_embedding`
    /// output is identical to the original finalized provider's. Returns
    /// `Err(BasisCodecError)` on a truncated blob, an unknown format version,
    /// or a magic mismatch — never panics.
    pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(NMF_BASIS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let model_id = r.read_string()?;
        let model_version = r.read_string()?;
        let rank = r.read_u32()? as usize;
        let max_iterations = r.read_u32()? as usize;
        let seed = r.read_u64()?;
        let projection_seed = r.read_u64()?;
        let document_count = r.read_u32()? as usize;
        let effective_rank = r.read_u32()? as usize;
        let vocab = r.read_string_u32_map()?;
        let w_factor = r.read_f32_matrix()?;
        let h_factor = r.read_f32_matrix()?;

        // Re-derive per-document embeddings exactly as finalize() does:
        // L2-normalised column d of H. An empty factor section (never-
        // finalized source) yields empty doc_embeddings and an empty `w`,
        // so `is_finalized()` stays false.
        let doc_embeddings: Vec<Vec<f32>> = (0..document_count)
            .map(|d| {
                let col: Vec<f32> = (0..effective_rank).map(|rr| h_factor[rr][d]).collect();
                float_vec_ops::l2_normalize(col)
            })
            .collect();

        Ok(NmfProvider {
            model_id,
            model_version,
            rank: rank.max(1),
            max_iterations: max_iterations.max(1),
            seed,
            projection_seed,
            counts: TermDocumentCounts::from_restored(vocab.clone(), document_count),
            w: w_factor,
            h: h_factor,
            doc_embeddings,
            effective_rank,
            reduced_vocab_cap: DEFAULT_REDUCED_VOCAB_CAP,
            basis_vocab: vocab,
        })
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

        // Projection keys on the REDUCED basis vocab; OOV terms
        // outside top-K contribute nothing (covered by RI).
        let vocab_size = self.basis_vocab.len();
        let k = self.effective_rank;
        let eps: f32 = 1e-9;

        // Build sparse TF query vector.
        let mut raw_counts: HashMap<usize, usize> = HashMap::new();
        let mut has_in_vocab = false;
        for term in &terms {
            if let Some(&idx) = self.basis_vocab.get(term.as_str()) {
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
    /// - Not finalized / no basis: returns `Ok(vec![])` — structural opt-out.
    /// - Empty or non-tokenisable input: returns `Ok(vec![])`.
    /// - Trained basis, all query tokens OOV: returns
    ///   `Err(VectorKitError::EmbedFloatVocabMiss(...))` so the corpus layer
    ///   maps to `FloatLaneOutcome::UnavailableNoVocabHit`.
    /// - Degenerate projection (all-zero result): returns `Ok(vec![])`.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        // No finalized basis: structural opt-out, not vocabMiss.
        if !self.is_finalized() || self.basis_vocab.is_empty() {
            return Ok(vec![]);
        }
        if text.is_empty() {
            return Ok(vec![]);
        }
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        // OOV check before full NMF fold-in projection.
        let has_in_vocab = terms.iter().any(|t| self.basis_vocab.contains_key(t.as_str()));
        if !has_in_vocab {
            return Err(VectorKitError::EmbedFloatVocabMiss(format!(
                "nmf: reduced vocab size {}, but 0 of {} query token(s) matched",
                self.basis_vocab.len(),
                terms.len()
            )));
        }
        Ok(NmfProvider::embed_float_nmf(self, text).unwrap_or_default())
    }

    /// Single-pass override: compute the NMF fold-in vector ONCE (via the
    /// inherent `embed_float_nmf`) and return both the projected Engram and the
    /// float vector, deduping the double pass that `embed` + `embed_float` would
    /// otherwise run. The inherent `embed_float_nmf` is deterministic, so the
    /// outputs are byte-identical to calling the two trait methods separately: a
    /// non-empty vector v projects to the same Engram and is returned as the float
    /// lane; a `None`/empty result (no basis, empty/non-tokenisable input, all-OOV,
    /// or a degenerate all-zero fold-in) yields `(Engram::ZERO, vec![])` — matching
    /// `embed`'s `ZERO` and `embed_float`'s `vec![]` (its all-OOV `EmbedFloatVocabMiss`
    /// is swallowed to `vec![]` by the default `embed_pair`'s `unwrap_or_default`).
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), VectorKitError> {
        match NmfProvider::embed_float_nmf(self, text) {
            Some(v) if !v.is_empty() => {
                Ok((float_simhash::project(&v, self.projection_seed), v))
            }
            _ => Ok((Engram::ZERO, Vec::new())),
        }
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

impl TrainableEmbeddingBasis for NmfProvider {
    /// Train the NMF basis on a corpus of raw document texts.
    ///
    /// NMF's `train` consumes a raw document per call (it tokenizes internally
    /// via the shared `TermDocumentCounts` builder, which uses
    /// `default_keyword_tokens`), so each text is passed through unchanged — one
    /// document column per text. The `finalize` pass then builds the TF matrix
    /// and runs the SubstrateML NMF factorization (tolerance=0, fixed iterations,
    /// deterministic). This reproduces the exact trained+finalized state of
    /// per-document `train` + `finalize`, so a basis serialized after
    /// `train_on_corpus` is byte-identical to the 6a-i fixture trained on the
    /// same texts.
    fn train_on_corpus(&mut self, texts: &[&str]) {
        for text in texts {
            self.train(text);
        }
        self.finalize();
    }

    /// Streamed-training page: the same per-document accumulation
    /// `train_on_corpus` runs, finalization deferred to `finalize_training`.
    fn accumulate_training(&mut self, texts: &[&str]) {
        for text in texts {
            self.train(text);
        }
    }

    fn finalize_training(&mut self) {
        self.finalize();
    }

    /// Serialize the finalized NMF basis (6a-i codec), surfaced through the seam.
    fn serialize_basis(&self) -> Vec<u8> {
        NmfProvider::serialize_basis(self)
    }

    /// Reconstruct a fresh `NmfProvider` from a basis blob, boxed. Delegates to
    /// `from_serialized_basis` (6a-i); a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        let provider = NmfProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    fn release_basis(&mut self) {
        self.w = Vec::new();
        self.h = Vec::new();
        self.doc_embeddings = Vec::new();
    }

    /// Reconstruct a fresh NMF provider from a basis blob, boxed as TRAINABLE so
    /// `Corpus` can rebuild a from-scratch trainable provider for `reindex` /
    /// first-ingest (train_on_corpus is additive — see the trait doc). Same
    /// `from_serialized_basis` constructor as `reconstruct_basis`.
    fn reconstruct_trainable_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError> {
        let provider = NmfProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// Fold one chunk into the maintained vocab + document-count anchor. NMF's
    /// heavy TF inputs are re-derived by re-tokenizing at refactor, so the anchor
    /// is accumulated through `add_document_for_counts_anchor` — O(vocab) state,
    /// not the O(corpus) a full `train` per chunk would retain.
    fn add_to_counts(&mut self, text: &str) {
        self.counts.add_document_for_counts_anchor(text);
    }

    /// Serialize the maintained counts (6a-i counts codec), surfaced through the
    /// seam.
    fn serialize_counts(&self) -> Vec<u8> {
        NmfProvider::serialize_counts(self)
    }

    /// Restore maintained counts; a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError> {
        NmfProvider::restore_counts(self, bytes)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))
    }

    /// Maintained vocabulary size for the growth trigger.
    fn counts_vocabulary_size(&self) -> usize {
        self.counts.vocabulary_size()
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

    // ── Counts codec (incremental-counts change set), mirrors the Swift suite ──

    #[test]
    fn counts_round_trip_preserves_anchors() {
        let original = trained_provider();
        let blob = original.serialize_counts();
        let mut restored = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        restored.restore_counts(&blob).expect("restore counts");
        assert_eq!(restored.vocabulary_size(), original.vocabulary_size());
        assert_eq!(restored.document_count(), original.document_count());
    }

    #[test]
    fn counts_blob_header_versioned() {
        let bytes = trained_provider().serialize_counts();
        assert!(bytes.len() >= 5);
        assert_eq!(&bytes[0..4], NMF_COUNTS_MAGIC);
        assert_eq!(bytes[4], BASIS_FORMAT_VERSION);
    }

    #[test]
    fn counts_truncated_blob_errors() {
        let blob = trained_provider().serialize_counts();
        let mut fresh = NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED);
        assert!(fresh.restore_counts(&blob[..blob.len() / 2]).is_err());
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

    /// Regression test for codex e25c03fd — Rust-only parity gap vs Swift.
    ///
    /// shared reduced embedding vocabulary empty-vocabulary reduction (corpus vocab above `reduced_vocab_cap`
    /// AND all terms are hapax, df < 2) must fully reset finalized state so that
    /// a subsequent `serialize_basis()` + `from_serialized_basis()` round-trip is
    /// self-consistent and OOB-safe.
    ///
    /// Before the fix: the zero-vocab branch of `finalize()` cleared only `w` and
    /// `doc_embeddings`, leaving `h`, `effective_rank`, and `basis_vocab` stale
    /// from the prior successful `finalize()`. `serialize_basis()` then emitted the
    /// new (larger) `document_count` paired with the stale `effective_rank` and
    /// stale `h`. `from_serialized_basis()` indexed `h_factor[rr][d]` for every
    /// `document_count` document — out of bounds when the stale `h` had fewer
    /// columns than the new document count → OOB panic on reload.
    ///
    /// Scenario that triggers the panic:
    ///   Phase 1 (cap=2, 2 docs with unique terms):
    ///     full_size=2 <= cap=2 → no-op reduced-vocab path → vocab_size=2
    ///     → finalize() produces a valid 2-doc basis (h is rank×2).
    ///   Phase 2 (add 1 more doc with another unique term):
    ///     full_size=3 > cap=2 → above-cap path; all three terms are hapax
    ///     (df=1 < 2) → candidates empty → vocab_size=0 → zero-vocab branch.
    ///     Without the fix: h stays rank×2 (stale from phase 1),
    ///     effective_rank stays >0; serialize_basis() writes document_count=3
    ///     but effective_rank=stale and h=stale; from_serialized_basis()
    ///     indexes h_factor[rr][2] on a matrix with only 2 columns → PANIC.
    ///     With the fix: full reset → serialize emits an empty-rank, empty-h
    ///     blob; round-trip is OOB-safe.
    #[test]
    fn empty_reduced_vocab_second_finalize_round_trips_without_panic() {
        // Set reduced_vocab_cap = 2 to control the reduction threshold.
        // Private field access from this child module is valid in Rust.
        let mut p = NmfProvider {
            reduced_vocab_cap: 2,
            ..NmfProvider::new(3, 100, NMF_FACTORIZATION_SEED, NMF_PROJECTION_SEED)
        };

        // Phase 1: two documents, each with a unique term (both hapax, but
        // full_size=2 <= cap=2 → no-op reduced-vocab path → vocab_size=2).
        // finalize() produces a valid non-empty basis (h is rank×2).
        p.train("alpha");
        p.train("beta");
        p.finalize();
        assert!(
            p.is_finalized(),
            "phase 1: basis must be non-empty after first finalize"
        );
        assert!(
            p.effective_rank() > 0,
            "phase 1: effective_rank must be > 0 after first finalize"
        );

        // Phase 2: add one more document with a third unique term. Now
        // full_size=3 > cap=2 → above-cap path; all three terms have df=1
        // (hapax, df < 2) → candidates empty → vocab_size=0 → zero-vocab branch.
        p.train("gamma");
        p.finalize();

        // After the empty-reduction finalize the provider must not be finalized.
        assert!(
            !p.is_finalized(),
            "phase 2 empty-reduction: must not be finalized"
        );
        assert_eq!(
            p.effective_rank(),
            0,
            "phase 2: effective_rank must be 0 after empty-reduction finalize"
        );

        // Critical check: serialize_basis() + from_serialized_basis() must not
        // panic. Before the fix, stale h (rank×2 from phase 1) + stale
        // effective_rank (>0) + new document_count (3) caused h_factor[rr][2]
        // to index a matrix with only 2 columns → OOB panic.
        let blob = p.serialize_basis();
        let reloaded = NmfProvider::from_serialized_basis(&blob)
            .expect("from_serialized_basis must not fail on an empty-reduction basis");

        // Reloaded provider must also be non-finalized (empty basis round-trips).
        assert!(
            !reloaded.is_finalized(),
            "reloaded: empty-reduction basis must not be finalized"
        );
        assert_eq!(
            reloaded.effective_rank(),
            0,
            "reloaded: effective_rank must be 0 for empty-reduction basis"
        );
        // Embed on a non-finalized provider must return None — no OOB.
        assert!(
            reloaded.embed_float_nmf("alpha").is_none(),
            "reloaded: embed on non-finalized provider must return None"
        );
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
