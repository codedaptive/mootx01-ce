//! Random Indexing distributional-semantics embedding provider.
//!
//! Rust port of Swift's `RandomIndexingProvider` in `CorpusKitProviders`.
//!
//! Implements the *context-accumulation* (distributional) form of RI:
//!   1. Each term gets a sparse ternary index vector in R^D.
//!   2. A term's context vector is the sum of index vectors of
//!      co-occurring terms within a sliding window over a corpus.
//!   3. A document/query embedding is the L2-normalised sum of its
//!      terms' context vectors.
//!
//! This is a GENUINE distributional method — "car" and "vehicle"
//! share similar context vectors when they co-occur with the same
//! neighbours ("drive", "road", "engine"). It captures co-occurrence
//! meaning, not surface form, satisfying ADR-010 D-1's honesty
//! requirement: the dense lane must not lie about what it computes.
//!
//! The provider conforms to `vectorkit::EmbeddingProvider`:
//!   `embed_float(_)` → the D-dimensional normalised context vector
//!   `embed(_)`       → `float_simhash::project` of that vector (Engram)
//!
//! ## Constants (documented, cross-port identical)
//!
//!   D        = 2048   Dimensionality of index/context vectors.
//!   K        = 10     Nonzero positions per index vector (sparse ternary).
//!   WINDOW   = 4      Co-occurrence window radius (±4 terms).
//!
//! ## Index vector generation (precise PRNG call sequence)
//!
//! For term T (lowercased), seed = `substrate_types::fnv::hash64(T)`.
//! rng = `SplitMix64::new(seed)`.
//! Emit exactly 2*K PRNG draws in interleaved (position, sign) pairs:
//!   for i in 0..K:
//!     pos  = rng.next() % D      → position in [0, D)
//!     sign = (rng.next() & 1) == 1 ? +1.0 : -1.0
//!   write (pos, sign) into the dense vector; if pos collides the
//!   last sign wins. Total draws: 2*K = 20. No platform RNG; no
//!   rejection loop; call count is constant so cross-port PRNG
//!   sequences are always identical.
//!
//! D=2048=2^11 so `% D` is exact (no bias). Modulo is equivalent to
//! masking the low 11 bits: `n % 2048 == n & 2047`. Either form is fine;
//! we use `% D` for readability, matching the Swift.
//!
//! ## Projection seed
//!
//!   RI_PROJECTION_SEED = 0x5249_5F56_315F_4D58  ("RI_V1_MX")
//!   Model ID = "random-indexing-v1",  version = "1.0.0"
//!
//! Swift port: `packages/kits/CorpusKit/Sources/CorpusKitProviders/RandomIndexingProvider.swift`
//!
//! ADR-010 reference: Decision B, signal #2 of the honest fusion.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FNV hashing: substrate_types::fnv::hash64 (I-25)
// SplitMix64: substrate_ml::random_walks::SplitMix64
// FloatSimHash projection: substrate_ml::float_simhash::project
// Float-vector ops: substrate_kernel::float_vec_ops (l2_normalize etc.)
//
// These are conformance-gated substrate primitives. Using them here
// ensures bit-identity against the Swift port and against the
// canonical test vectors. Never reimplement inline.
// ─────────────────────────────────────────────────────────────────

use crate::basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
use corpus_kit::{CorpusKitError, TrainableEmbeddingBasis};
use engram_lib::Engram;
use std::collections::HashMap;
use substrate_kernel::float_vec_ops;
use substrate_ml::float_simhash;
use substrate_ml::random_walks::SplitMix64;
use substrate_types::fnv;
use vectorkit::{EmbeddingProvider, VectorKitError};

// MARK: - Constants
//
// Values are byte-identical to the Swift constants in
// `RandomIndexingProvider.swift`. Any change must be mirrored to both
// ports simultaneously and the canonical test vectors must be regenerated.

/// Dimensionality of every index vector and context vector.
/// 2048 gives a good accuracy/memory trade-off for a resident estate
/// (2048 × 4 bytes = 8 KB per term in the vocab table). D=2^11 so
/// `% RI_DIMENSION` is exact: equivalent to masking the low 11 bits.
pub const RI_DIMENSION: usize = 2048;

/// Number of nonzero ternary (±1) entries in each term's index vector.
/// 10 out of 2048 ≈ 0.5 % density; empirically sufficient for RI.
pub const RI_NONZEROS: usize = 10;

/// Co-occurrence window radius: ±4 terms on each side of the target.
/// Context vectors accumulate index vectors of all terms within this
/// distance in a training document.
pub const RI_WINDOW: usize = 4;

/// FloatSimHash projection seed for Random Indexing. Encodes "RI_V1_MX"
/// in ASCII. MUST NOT drift from the Swift constant `riProjectionSeed`.
pub const RI_PROJECTION_SEED: u64 = 0x5249_5F56_315F_4D58;

/// 4-byte magic identifying a Random Indexing basis blob ("RIB1").
/// Distinct per provider so a blob can never be deserialized by the wrong
/// provider type — `from_serialized_basis` rejects a mismatch. Mirrors the
/// Swift constant `RandomIndexingProvider.basisMagic`.
pub const RI_BASIS_MAGIC: &[u8; 4] = b"RIB1";

/// 4-byte magic identifying an RI COUNTS blob ("RICT"). RI's accumulated state —
/// the per-term context vectors — IS its basis, so the counts blob carries the
/// same `vocab` payload as the basis blob but under a distinct magic, keeping the
/// two stores' contracts uniform across all four providers. Mirrors the Swift
/// constant `RandomIndexingProvider.countsMagic`.
pub const RI_COUNTS_MAGIC: &[u8; 4] = b"RICT";

// MARK: - Index vector generation

/// Generate the sparse ternary index vector for a single term.
///
/// The index vector is deterministic: identical output for the same term
/// across all runs, all processes, and both language ports.
///
/// Algorithm:
///   1. seed = fnv::hash64(term.to_lowercase())
///   2. rng  = SplitMix64::new(seed)
///   3. for i in 0..K: pos = rng.next() % D, sign = if (rng.next() & 1) == 1 { +1 } else { -1 }
///      Write (pos, sign) into the D-dimensional float vector.
///      Collision: last sign wins (no rejection loop, call count stays 2*K).
///
/// The 2K draw sequence is fixed and MUST be identical in the Swift port.
pub fn ri_index_vector(term: &str) -> Vec<f32> {
    let seed = fnv::hash64(&term.to_lowercase());
    let mut rng = SplitMix64::new(seed);
    let mut vec = vec![0.0f32; RI_DIMENSION];
    for _ in 0..RI_NONZEROS {
        // Draw 1: position in [0, D). D=2048=2^11 so % is exact (no bias).
        let pos = (rng.next() % RI_DIMENSION as u64) as usize;
        // Draw 2: sign. Low bit of PRNG output, same rule as Swift.
        let sign: f32 = if (rng.next() & 1) == 1 { 1.0 } else { -1.0 };
        // Collision: last sign wins. No rejection loop needed; 2*K draws total.
        vec[pos] = sign;
    }
    vec
}

// MARK: - RandomIndexingProvider

/// Random Indexing distributional-semantics embedding provider.
///
/// Rust mirror of Swift's `RandomIndexingProvider` in `CorpusKitProviders`.
/// An instance holds a trained vocabulary map: term → context vector.
/// Build the vocabulary by calling `train` one or more times before
/// embedding. An untrained provider returns `Engram::ZERO` and an empty
/// float vector for any text (all terms OOV — the honest no-context signal).
///
/// Training is NOT concurrency-safe. Callers must complete all `train`
/// calls before concurrent `embed`/`embed_float` calls.
///
/// ## Conformance
///
/// Conforms to `vectorkit::EmbeddingProvider`. `model_id = "random-indexing-v1"`,
/// `model_version = "1.0.0"`. Projection seed = `RI_PROJECTION_SEED`.
///
/// ADR-010 Decision B, signal #2 — the first honest distributional provider
/// in the dense recall lane.
pub struct RandomIndexingProvider {
    model_id: String,
    model_version: String,
    /// FloatSimHash projection seed. Fixed to RI_PROJECTION_SEED; stored for
    /// cross-provider seed isolation per spec I-4.
    projection_seed: u64,
    /// Trained context vectors, keyed by lowercased term.
    /// Read-only after training is complete.
    vocab: HashMap<String, Vec<f32>>,
}

impl RandomIndexingProvider {
    /// Build an untrained provider with the canonical defaults:
    /// `model_id = "random-indexing-v1"`, `model_version = "1.0.0"`,
    /// projection seed = `RI_PROJECTION_SEED`.
    pub fn new() -> Self {
        Self::with_parameters("random-indexing-v1", "1.0.0", RI_PROJECTION_SEED)
    }

    /// Build with explicit identity and projection seed.
    ///
    /// The seed is parameterized for test isolation; production callers
    /// use [`RandomIndexingProvider::new`] so the seed stays the cross-port
    /// constant and all stored vectors key consistently.
    pub fn with_parameters(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
    ) -> Self {
        RandomIndexingProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            projection_seed,
            vocab: HashMap::new(),
        }
    }

    // MARK: - Training

    /// Train on a corpus: accumulate co-occurrence context vectors.
    ///
    /// For each term at position i in `terms`, add the index vector of
    /// each neighbour within [i−window, i+window] to the target term's
    /// context vector. Training is additive — multiple `train` calls extend
    /// the same vocabulary, enabling streaming updates over a growing estate.
    ///
    /// The window is symmetric: for position i, all j in
    /// `max(0, i-window)..=min(len-1, i+window)` where j ≠ i are neighbours.
    /// This is bit-identical to the Swift implementation's `lo/hi` logic.
    pub fn train(&mut self, terms: &[&str], window: usize) {
        let n = terms.len();
        if n == 0 {
            return;
        }
        // Precompute each position's index vector ONCE. The previous form called
        // `ri_index_vector(terms[j])` for every (i, j) pair, recomputing each
        // position's (deterministic) index vector ~2·window times. Same values,
        // computed once — bit-identical.
        let idx_vecs: Vec<Vec<f32>> = terms.iter().map(|t| ri_index_vector(t)).collect();
        // Precompute the lowercased vocab keys ONCE. The previous form allocated a
        // fresh `target.to_lowercase()` String (and re-hashed it) for every (i, j)
        // pair; here it is one allocation per position. Terms arrive lowercased, so
        // lowercasing is idempotent — same keys.
        let keys: Vec<String> = terms.iter().map(|t| t.to_lowercase()).collect();
        for i in 0..n {
            // Context: every term within ±window positions, excluding self.
            let lo = i.saturating_sub(window);
            let hi = (i + window).min(n - 1);
            // No neighbours (the window collapses to {i}) → create no entry, exactly
            // as the per-neighbour form did (it only inserted on the first neighbour
            // iteration). A neighbourless term must stay OOV.
            if hi <= lo {
                continue;
            }
            // Bind the target's context vector ONCE per position (was a String
            // hash + entry probe per neighbour), accumulate every neighbour in
            // ascending j order — the same order as before, so bit-identical.
            let cv = self
                .vocab
                .entry(keys[i].clone())
                .or_insert_with(|| vec![0.0f32; RI_DIMENSION]);
            for j in lo..=hi {
                if j == i {
                    continue;
                }
                let neighbour_index = &idx_vecs[j];
                for d in 0..RI_DIMENSION {
                    cv[d] += neighbour_index[d];
                }
            }
        }
    }

    // MARK: - Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) context vector for a term, or `None`
    /// if the term is OOV. Used by conformance tests to verify index vector
    /// accumulation without triggering the full embed pipeline.
    pub fn context_vector_for_term(&self, term: &str) -> Option<&Vec<f32>> {
        self.vocab.get(&term.to_lowercase())
    }

    /// The current trained vocabulary size.
    pub fn vocabulary_size(&self) -> usize {
        self.vocab.len()
    }

    // MARK: - Basis serialization (mission 6a-i)

    /// Serialize the trained RI basis to a versioned, little-endian blob.
    ///
    /// The RI basis is fully determined by the `vocab` map (term → context
    /// vector); the model identity and projection seed are also captured so
    /// the reconstructed provider keys to the same Engram bucket. Byte
    /// layout mirrors Swift's `serializeBasis()` exactly — the same trained
    /// state yields a byte-identical blob on both ports.
    pub fn serialize_basis(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(RI_BASIS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_string_f32_vector_map(&self.vocab);
        w.into_bytes()
    }

    /// Reconstruct a provider from a serialized RI basis blob.
    ///
    /// The reconstructed provider's `embed`/`embed_float` output is identical
    /// to the original trained provider's (round-trip law). Returns
    /// `Err(BasisCodecError)` on a truncated blob, an unknown format version,
    /// or a magic mismatch — never panics.
    pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(RI_BASIS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let model_id = r.read_string()?;
        let model_version = r.read_string()?;
        let projection_seed = r.read_u64()?;
        let vocab = r.read_string_f32_vector_map()?;
        let mut provider = RandomIndexingProvider::with_parameters(
            model_id,
            model_version,
            projection_seed,
        );
        provider.vocab = vocab;
        Ok(provider)
    }

    // MARK: - Counts serialization (incremental-counts change set)

    /// Serialize the maintained context vectors to a versioned counts blob. Same
    /// `vocab` payload as `serialize_basis`, under the RICT counts magic.
    /// Byte-identical to the Swift `RandomIndexingProvider.serializeCounts`.
    pub fn serialize_counts(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(RI_COUNTS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_string_f32_vector_map(&self.vocab);
        w.into_bytes()
    }

    /// Restore the accumulated context vectors in place from a counts blob, so
    /// incremental maintenance resumes after a restart. Returns
    /// `Err(BasisCodecError)` on a bad blob — never panics.
    pub fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(RI_COUNTS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let _model_id = r.read_string()?;
        let _model_version = r.read_string()?;
        let _projection_seed = r.read_u64()?;
        self.vocab = r.read_string_f32_vector_map()?;
        Ok(())
    }

    // MARK: - Private helpers

    /// Compute the normalised context vector for `text` as a pure function
    /// of the current vocab table. Returns `None` for empty text or when
    /// all terms are OOV (out-of-vocabulary).
    fn context_vector(&self, text: &str) -> Option<Vec<f32>> {
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

        let mut sum = vec![0.0f32; RI_DIMENSION];
        let mut hit_count = 0usize;

        for term in &terms {
            if let Some(cv) = self.vocab.get(term.as_str()) {
                for d in 0..RI_DIMENSION {
                    sum[d] += cv[d];
                }
                hit_count += 1;
            }
        }

        // All terms OOV → honest no-context signal.
        if hit_count == 0 {
            return None;
        }
        // Delegate to the substrate's canonical scalar implementation.
        // float_vec_ops::l2_normalize is conformance-gated against the
        // Swift port; using it here guarantees bit-identical output
        // without maintaining a separate inline implementation.
        Some(float_vec_ops::l2_normalize(sum))
    }
}

impl Default for RandomIndexingProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl EmbeddingProvider for RandomIndexingProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn model_version(&self) -> &str {
        &self.model_version
    }

    /// Produce the distributional embedding for `text`.
    ///
    /// Computes the normalised D-dimensional context vector and projects
    /// it through `float_simhash::project` to produce the 256-bit Engram.
    /// Empty input returns `Engram::ZERO` (EmbeddingProvider contract).
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        match self.context_vector(text) {
            None => Ok(Engram::ZERO),
            Some(v) => Ok(float_simhash::project(&v, self.projection_seed)),
        }
    }

    /// Return the D-dimensional normalised context vector for `text`.
    ///
    /// - Untrained provider (empty vocab): returns `Ok(vec![])` — structural
    ///   opt-out, no basis exists yet.
    /// - Empty or non-tokenisable input: returns `Ok(vec![])`.
    /// - Trained provider, all query tokens OOV: returns
    ///   `Err(VectorKitError::EmbedFloatVocabMiss(...))` so the corpus layer
    ///   maps to `FloatLaneOutcome::UnavailableNoVocabHit` rather than the
    ///   misleading `UnavailableProviderOptOut`.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        // Untrained provider: return [] (structural opt-out, not vocabMiss).
        if self.vocab.is_empty() {
            return Ok(vec![]);
        }
        // Empty or non-tokenisable input: return [] without a vocab-miss throw.
        if text.is_empty() {
            return Ok(vec![]);
        }
        let terms = corpus_kit::default_keyword_tokens(text);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        match self.context_vector(text) {
            Some(v) => Ok(v),
            None => {
                // context_vector returns None only when hit_count == 0 (all OOV),
                // because we already guarded empty text and empty tokens above.
                Err(VectorKitError::EmbedFloatVocabMiss(format!(
                    "random-indexing: vocab size {}, but 0 of {} query token(s) matched",
                    self.vocab.len(),
                    terms.len()
                )))
            }
        }
    }

    /// Produce the engram AND the normalised context vector from a SINGLE
    /// context-vector computation.
    ///
    /// `embed` projects the context vector and `embed_float` returns it, so a
    /// caller that needs both would otherwise run `context_vector` twice. This
    /// override computes it ONCE and returns both outputs.
    ///
    /// Byte-identical to calling `embed` then `embed_float` separately: the
    /// engram is `float_simhash::project` of the vector (or `Engram::ZERO` when
    /// `context_vector` returns `None`), and `floats` reproduces `embed_float`'s
    /// result with its vocab-miss error collapsed to `vec![]` (the `embed_pair`
    /// opt-out contract). An empty vocab makes `context_vector` return `None`,
    /// so the engram is `Engram::ZERO` and floats are empty — identical to the
    /// separate calls.
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), VectorKitError> {
        match self.context_vector(text) {
            None => Ok((Engram::ZERO, Vec::new())),
            Some(v) => Ok((float_simhash::project(&v, self.projection_seed), v)),
        }
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

impl TrainableEmbeddingBasis for RandomIndexingProvider {
    /// Train the RI basis on a corpus of raw document texts.
    ///
    /// RI's `train` consumes a term slice per document, so each text is
    /// tokenized with the canonical `corpus_kit::default_keyword_tokens` — the
    /// SAME tokenizer `embed_float` uses — and fed to `train` at `RI_WINDOW`.
    /// RI has no finalization pass. This reproduces the exact trained state of
    /// `train` driven directly from token slices, so a basis serialized after
    /// `train_on_corpus` is byte-identical to the 6a-i fixture whose corpus is
    /// the same texts tokenized.
    fn train_on_corpus(&mut self, texts: &[&str]) {
        for text in texts {
            let terms = corpus_kit::default_keyword_tokens(text);
            let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
            self.train(&term_refs, RI_WINDOW);
        }
    }

    /// Serialize the trained RI basis (6a-i codec), surfaced through the seam.
    fn serialize_basis(&self) -> Vec<u8> {
        RandomIndexingProvider::serialize_basis(self)
    }

    /// Reconstruct a fresh `RandomIndexingProvider` from a basis blob, boxed.
    /// Delegates to `from_serialized_basis` (6a-i); a codec error maps to
    /// `CorpusKitError::DecodingFailure` (parity with Swift's `decodingFailure`).
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        let provider = RandomIndexingProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// ADR-026: release the in-memory vocab to free heap.
    fn release_basis(&mut self) {
        self.vocab.clear();
        self.vocab.shrink_to_fit();
    }

    /// Reconstruct a fresh RI provider from a basis blob, boxed as TRAINABLE so
    /// `Corpus` can rebuild a from-scratch trainable provider for `reindex` /
    /// first-ingest (train_on_corpus is additive — see the trait doc). Same
    /// `from_serialized_basis` constructor as `reconstruct_basis`.
    fn reconstruct_trainable_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError> {
        let provider = RandomIndexingProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// Fold one chunk into the accumulated context vectors. RI's accumulation
    /// consumes a term slice, so the text is tokenized with the canonical
    /// `default_keyword_tokens` and folded at `RI_WINDOW` — the same per-document
    /// step `train_on_corpus` runs (RI has no finalize).
    fn add_to_counts(&mut self, text: &str) {
        let terms = corpus_kit::default_keyword_tokens(text);
        let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
        self.train(&term_refs, RI_WINDOW);
    }

    /// Serialize the maintained context vectors (RICT counts codec), surfaced
    /// through the seam.
    fn serialize_counts(&self) -> Vec<u8> {
        RandomIndexingProvider::serialize_counts(self)
    }

    /// Restore the maintained context vectors; a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError> {
        RandomIndexingProvider::restore_counts(self, bytes)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))
    }

    /// Maintained vocabulary size for the growth trigger.
    fn counts_vocabulary_size(&self) -> usize {
        self.vocab.len()
    }
}

// MARK: - Unit tests

#[cfg(test)]
mod tests {
    use super::*;
    use vectorkit::EmbeddingProvider;

    #[test]
    fn index_vector_is_deterministic_for_same_term() {
        let a = ri_index_vector("car");
        let b = ri_index_vector("car");
        assert_eq!(a, b, "same term must produce same index vector every call");
    }

    #[test]
    fn index_vector_has_d_dimensions() {
        let v = ri_index_vector("hello");
        assert_eq!(v.len(), RI_DIMENSION);
    }

    #[test]
    fn index_vector_contains_only_ternary_values() {
        let v = ri_index_vector("hello");
        for (i, &x) in v.iter().enumerate() {
            assert!(
                x == 0.0 || x == 1.0 || x == -1.0,
                "position {i} has non-ternary value {x}"
            );
        }
    }

    #[test]
    fn index_vector_nonzeros_at_most_k() {
        for term in &["car", "vehicle", "dog", "engine", "road"] {
            let v = ri_index_vector(term);
            let nonzeros = v.iter().filter(|&&x| x != 0.0).count();
            assert!(nonzeros >= 1, "{term}: must have at least 1 nonzero");
            assert!(
                nonzeros <= RI_NONZEROS,
                "{term}: nonzeros={nonzeros} exceeds K={RI_NONZEROS}"
            );
        }
    }

    #[test]
    fn distinct_terms_produce_distinct_index_vectors() {
        let car = ri_index_vector("car");
        let dog = ri_index_vector("dog");
        assert_ne!(car, dog, "distinct terms must produce distinct index vectors");
    }

    #[test]
    fn lowercasing_is_applied_before_hashing() {
        let lower = ri_index_vector("car");
        let upper = ri_index_vector("CAR");
        let mixed = ri_index_vector("Car");
        assert_eq!(lower, upper, "lowercase and uppercase must hash identically");
        assert_eq!(lower, mixed, "mixed case must hash identically to lowercase");
    }

    #[test]
    fn training_accumulates_neighbour_index_vectors() {
        let mut provider = RandomIndexingProvider::new();
        provider.train(&["car", "engine", "drive"], RI_WINDOW);

        let cv = provider.context_vector_for_term("car");
        assert!(cv.is_some(), "car must have a context vector after training");

        // Verify accumulation: car's context = engine_index + drive_index
        let engine_idx = ri_index_vector("engine");
        let drive_idx = ri_index_vector("drive");
        let mut expected = vec![0.0f32; RI_DIMENSION];
        for d in 0..RI_DIMENSION {
            expected[d] = engine_idx[d] + drive_idx[d];
        }
        let got = cv.unwrap();
        assert_eq!(*got, expected, "context vector must equal sum of neighbour index vectors");
    }

    #[test]
    fn self_position_is_excluded_from_context() {
        let mut provider = RandomIndexingProvider::new();
        // Single term, no neighbours — must have no context entry.
        provider.train(&["solo"], RI_WINDOW);
        assert!(
            provider.context_vector_for_term("solo").is_none(),
            "a term with no neighbours must have no context vector"
        );
    }

    #[test]
    fn window_boundary_is_respected() {
        let mut provider = RandomIndexingProvider::new();
        let terms = ["car", "near", "also", "far", "x", "x", "x", "x", "x", "x", "x", "x"];
        provider.train(&terms, 2);

        let cv = provider.context_vector_for_term("car").expect("car must be in vocab");
        let near_idx = ri_index_vector("near");
        let also_idx = ri_index_vector("also");
        let mut expected = vec![0.0f32; RI_DIMENSION];
        for d in 0..RI_DIMENSION {
            expected[d] = near_idx[d] + also_idx[d];
        }
        assert_eq!(*cv, expected, "only terms within ±window contribute to context");
    }

    #[test]
    fn embed_empty_returns_zero_engram() {
        let provider = RandomIndexingProvider::new();
        assert_eq!(provider.embed("").unwrap(), Engram::ZERO);
    }

    #[test]
    fn embed_float_empty_returns_empty_vec() {
        let provider = RandomIndexingProvider::new();
        assert!(provider.embed_float("").unwrap().is_empty());
    }

    #[test]
    fn oov_text_returns_zero_engram() {
        let provider = RandomIndexingProvider::new();
        assert_eq!(provider.embed("unknown word here").unwrap(), Engram::ZERO);
    }

    #[test]
    fn oov_text_returns_empty_float_vec() {
        let provider = RandomIndexingProvider::new();
        assert!(provider.embed_float("unknown word").unwrap().is_empty());
    }

    #[test]
    fn trained_text_returns_unit_length_float_vector() {
        let mut provider = RandomIndexingProvider::new();
        provider.train(&["car", "engine", "drive"], RI_WINDOW);
        let v = provider.embed_float("car engine").unwrap();
        assert!(!v.is_empty(), "embedFloat must be non-empty after training");
        let norm: f32 = v.iter().map(|&x| x * x).sum::<f32>().sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-5,
            "embedFloat must return a unit vector; got norm={norm}"
        );
    }

    #[test]
    fn embed_is_deterministic() {
        let corpus = vec![
            vec!["car", "engine", "drive", "road", "vehicle"],
            vec!["vehicle", "road", "transport", "car", "fuel"],
        ];
        let mut provider = RandomIndexingProvider::new();
        for doc in &corpus {
            provider.train(doc, RI_WINDOW);
        }
        let e1 = provider.embed("car engine").unwrap();
        let e2 = provider.embed("car engine").unwrap();
        assert_eq!(e1, e2, "same text must produce same embedding");
    }
}
