//! Random Indexing distributional-semantics embedding provider.
//!
//! Rust port of Swift's `RandomIndexingProvider` in `CorpusKitProviders`.
//!
//! Implements the *context-accumulation* (distributional) form of RI:
//!   1. Each term gets a sparse ternary index vector in R^D.
//!   2. A term's context vector is the sum of index vectors of
//!      co-occurring terms within a sliding window over a corpus.
//!   3. A document/query embedding is the pooled context vector of its
//!      distinct terms: IDF-weighted sum, L2-normalised, corpus-mean
//!      direction removed, L2-normalised (`distributional_pooling`).
//!
//! This is a GENUINE distributional method — "car" and "vehicle"
//! share similar context vectors when they co-occur with the same
//! neighbours ("drive", "road", "engine"). It captures co-occurrence
//! meaning, not surface form, satisfying honest semantic fusion D-1's honesty
//! requirement: the dense lane must not lie about what it computes.
//!
//! The provider conforms to `synapsekit::EmbeddingProvider`:
//!   `embed_float(_)` → the D-dimensional pooled unit vector
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
//! ## Lifecycle
//!
//!   `train`     — accumulate context vectors AND the per-term document
//!                 frequency (one call = one document).
//!   `finalize`  — fit the IDF table and the corpus-mean direction from the
//!                 accumulated counts. Required before embedding, the same
//!                 rule PPMI has always had.
//!   `embed` / `embed_float` / `embed_pair` — pool through the fitted basis.
//!
//! ## Projection seed
//!
//!   RI_PROJECTION_SEED = 0x5249_5F56_315F_4D58  ("RI_V1_MX")
//!   Model ID = "random-indexing-v1",  version = "1.1.0"
//!
//! Swift port: `packages/kits/CorpusKit/Sources/CorpusKitProviders/RandomIndexingProvider.swift`
//!
//! honest semantic fusion reference: Decision B, signal #2 of the honest fusion.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FNV hashing: substrate_types::fnv::hash64 (I-25)
// SplitMix64: substrate_ml::random_walks::SplitMix64
// FloatSimHash projection: substrate_ml::float_simhash::project
// Float-vector ops: substrate_kernel::float_vec_ops (via distributional_pooling)
//
// These are conformance-gated substrate primitives. Using them here
// ensures bit-identity against the Swift port and against the
// canonical test vectors. Never reimplement inline.
// ─────────────────────────────────────────────────────────────────

use crate::basis_codec::{BasisCodecError, BasisReader, BasisWriter, BASIS_FORMAT_VERSION};
use crate::distributional_pooling;
use crate::term_document_counts::TermDocumentCounts;
use corpus_kit::{CorpusKitError, TrainableEmbeddingBasis};
use engram_lib::Engram;
use std::collections::HashMap;
use substrate_ml::float_simhash;
use substrate_ml::random_walks::SplitMix64;
use substrate_types::fnv;
use synapsekit::{EmbeddingProvider, SynapseKitError};

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
/// the per-term context vectors plus the document-frequency table — is
/// everything `finalize` needs, so the counts blob carries the `vocab` payload
/// under a distinct magic (a counts row can never be misread as a basis row)
/// followed by the document count and per-term df. Mirrors the Swift constant
/// `RandomIndexingProvider.countsMagic`.
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
/// An instance holds a trained vocabulary map (term → context vector) plus
/// the pooling fit derived from it: the per-term IDF table and the unit
/// corpus-mean direction. Build the vocabulary by calling `train` once per
/// document, then `finalize` before embedding. An unfinalized provider
/// returns `Engram::ZERO` and an empty float vector for any text (no basis);
/// a finalized provider returns them for text whose every term is OOV (the
/// honest no-context signal, surfaced as a vocabulary miss on the float lane).
///
/// Training is NOT concurrency-safe. Callers must complete all `train`
/// calls and the `finalize` before concurrent `embed`/`embed_float` calls.
///
/// ## Conformance
///
/// Conforms to `synapsekit::EmbeddingProvider`. `model_id = "random-indexing-v1"`,
/// `model_version = "1.1.0"`. Projection seed = `RI_PROJECTION_SEED`.
///
/// honest semantic fusion, signal #2 — the first honest distributional provider
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
    /// Document frequency and document count accumulated by `train`, one
    /// document per call. Training-phase state: persisted in the counts blob
    /// (it feeds `finalize`), never in the basis blob.
    counts: TermDocumentCounts,
    /// Smoothed IDF per vocabulary term, fitted at `finalize`. Applied to
    /// documents and queries alike by `distributional_pooling::pool`.
    idf_table: HashMap<String, f32>,
    /// Unit corpus-mean direction fitted at `finalize` (D long), or empty
    /// when no term contributed. Removed from every pooled vector.
    mean_direction: Vec<f32>,
    /// True once `finalize` has fitted the pooling state for the current
    /// vocabulary; cleared by every `train` call.
    is_finalized: bool,
}

impl RandomIndexingProvider {
    /// Build an untrained provider with the canonical defaults:
    /// `model_id = "random-indexing-v1"`, `model_version = "1.1.0"`,
    /// projection seed = `RI_PROJECTION_SEED`.
    pub fn new() -> Self {
        Self::with_parameters("random-indexing-v1", "1.1.0", RI_PROJECTION_SEED)
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
            counts: TermDocumentCounts::new(),
            idf_table: HashMap::new(),
            mean_direction: Vec::new(),
            is_finalized: false,
        }
    }

    // MARK: - Training

    /// Train on one document: accumulate co-occurrence context vectors and
    /// the document-frequency table.
    ///
    /// For each term at position i in `terms`, add the index vector of
    /// each neighbour within [i−window, i+window] to the target term's
    /// context vector. Every distinct term in the call counts once toward
    /// its document frequency, and the call counts as one document (an
    /// empty call is not a document). Training is additive — multiple
    /// `train` calls extend the same vocabulary, enabling streaming updates
    /// over a growing estate. Call `finalize` after the last document.
    ///
    /// The window is symmetric: for position i, all j in
    /// `max(0, i-window)..=min(len-1, i+window)` where j ≠ i are neighbours.
    /// This is bit-identical to the Swift implementation's `lo/hi` logic.
    pub fn train(&mut self, terms: &[&str], window: usize) {
        let n = terms.len();
        if n == 0 {
            return;
        }
        // Document frequency: one document per call, each distinct term once.
        // Terms arrive lowercased (the tokenizer lowercases), so the df keys
        // match the vocab keys.
        self.counts.add_document_terms(terms);
        self.is_finalized = false;
        // Precompute each position's index vector ONCE; each position's
        // (deterministic) index vector is needed for every neighbour pair
        // within the window, and computing it once per position keeps the
        // accumulation bit-identical to a per-pair recomputation.
        let idx_vecs: Vec<Vec<f32>> = terms.iter().map(|t| ri_index_vector(t)).collect();
        // Precompute the lowercased vocab keys ONCE (lowercasing is idempotent
        // on the lowercased tokens the tokenizer emits).
        let keys: Vec<String> = terms.iter().map(|t| t.to_lowercase()).collect();
        for i in 0..n {
            // Context: every term within ±window positions, excluding self.
            let lo = i.saturating_sub(window);
            let hi = (i + window).min(n - 1);
            // No neighbours (the window collapses to {i}) → create no entry. A
            // neighbourless term stays OOV in the vector table (its document
            // frequency is still counted above).
            if hi <= lo {
                continue;
            }
            // Bind the target's context vector ONCE per position, accumulate
            // every neighbour in ascending j order — the order fixes the bits.
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

    /// Fit the pooling state from the accumulated training counts: the
    /// smoothed IDF of every vocabulary term and the unit corpus-mean
    /// direction `l2_normalize(Σ_t df(t)·idf(t)·cv(t))`.
    ///
    /// A pure function of (`vocab`, document frequencies, document count),
    /// so two finalizations over identical accumulated state produce
    /// identical tables, and the counts path (restore counts → finalize)
    /// yields the same basis bytes as the corpus path. Idempotent; must be
    /// called after the last `train` and before any embed. Twin of Swift
    /// `finalize()`.
    pub fn finalize(&mut self) {
        let mut idf: HashMap<String, f32> = HashMap::with_capacity(self.vocab.len());
        for term in self.vocab.keys() {
            idf.insert(term.clone(), self.counts.inverse_document_frequency(term));
        }
        self.idf_table = idf;
        let counts = &self.counts;
        self.mean_direction = distributional_pooling::mean_direction(
            &self.vocab,
            &self.idf_table,
            |term| counts.document_frequency(term),
            RI_DIMENSION,
        );
        self.is_finalized = true;
    }

    // MARK: - Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) context vector for a term, or `None`
    /// if the term is OOV. Used by conformance tests to verify index vector
    /// accumulation without triggering the full embed pipeline.
    pub fn context_vector_for_term(&self, term: &str) -> Option<&Vec<f32>> {
        self.vocab.get(&term.to_lowercase())
    }

    /// The fitted smoothed IDF weight of a vocabulary term, or `None` when
    /// the term is OOV or the basis is not finalized. Conformance accessor.
    pub fn inverse_document_frequency_for_term(&self, term: &str) -> Option<f32> {
        self.idf_table.get(&term.to_lowercase()).copied()
    }

    /// The fitted unit corpus-mean direction (D long), or empty when the
    /// basis is not finalized or no term contributed. Conformance accessor.
    pub fn corpus_mean_direction(&self) -> &[f32] {
        &self.mean_direction
    }

    /// The current trained vocabulary size.
    pub fn vocabulary_size(&self) -> usize {
        self.vocab.len()
    }

    /// Number of documents folded by `train` (the IDF corpus size N).
    pub fn document_count(&self) -> usize {
        self.counts.document_count()
    }

    // MARK: - Basis serialization

    /// Serialize the finalized RI basis to a versioned, little-endian blob.
    ///
    /// The RI basis is the `vocab` map (term → context vector) plus the
    /// pooling fit — the IDF table and the corpus-mean direction — so a
    /// reconstructed provider pools queries exactly as the trainer pooled
    /// documents. The model identity and projection seed are also captured
    /// so the reconstructed provider keys to the same Engram bucket. Byte
    /// layout mirrors Swift's `serializeBasis()` exactly:
    ///
    ///   model_id (string) | model_version (string) | projection_seed (u64)
    ///   | vocab (String→[f32] map, sorted keys)
    ///   | idf (String→f32 map, sorted keys) | mean_direction ([f32])
    pub fn serialize_basis(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        w.write_magic(RI_BASIS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_string_f32_vector_map(&self.vocab);
        w.write_string_f32_map(&self.idf_table);
        w.write_f32_array(&self.mean_direction);
        w.into_bytes()
    }

    /// Reconstruct a provider from a serialized RI basis blob.
    ///
    /// The reconstructed provider's `embed`/`embed_float` output is identical
    /// to the original finalized provider's (round-trip law). The training
    /// counts are not part of the basis, so a reconstructed provider is
    /// read-only for embedding. Returns `Err(BasisCodecError)` on a truncated
    /// blob, a format version other than `BASIS_FORMAT_VERSION`, or a magic
    /// mismatch — never panics.
    pub fn from_serialized_basis(bytes: &[u8]) -> Result<Self, BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        r.expect_magic(RI_BASIS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let model_id = r.read_string()?;
        let model_version = r.read_string()?;
        let projection_seed = r.read_u64()?;
        let vocab = r.read_string_f32_vector_map()?;
        let idf_table = r.read_string_f32_map()?;
        let mean_direction = r.read_f32_array()?;
        let mut provider = RandomIndexingProvider::with_parameters(
            model_id,
            model_version,
            projection_seed,
        );
        provider.vocab = vocab;
        provider.idf_table = idf_table;
        provider.mean_direction = mean_direction;
        provider.is_finalized = true;
        Ok(provider)
    }

    // MARK: - Counts serialization

    /// Emit the counts frame and fields shared by `serialize_counts` and
    /// `decompose_counts`: everything except which vocabulary map is inline.
    fn write_counts_header(&self, w: &mut BasisWriter, vocabulary: &HashMap<String, Vec<f32>>) {
        w.write_magic(RI_COUNTS_MAGIC);
        w.write_byte(BASIS_FORMAT_VERSION);
        w.write_string(&self.model_id);
        w.write_string(&self.model_version);
        w.write_u64(self.projection_seed);
        w.write_string_f32_vector_map(vocabulary);
        w.write_u32(self.counts.document_count() as u32);
        w.write_string_u32_map(&self.counts.document_frequencies());
    }

    /// Serialize the maintained state to a versioned counts blob.
    /// Byte-identical to the Swift `RandomIndexingProvider.serializeCounts`:
    ///
    ///   model_id (string) | model_version (string) | projection_seed (u64)
    ///   | vocab (String→[f32] map, sorted keys)
    ///   | document_count (u32) | document_frequencies (String→u32 map, sorted keys)
    pub fn serialize_counts(&self) -> Vec<u8> {
        let mut w = BasisWriter::new();
        self.write_counts_header(&mut w, &self.vocab);
        w.into_bytes()
    }

    /// Split the counts blob into its fixed header and one entry per term.
    /// Twin of the Swift `RandomIndexingProvider.decomposeCounts()`.
    ///
    /// The header is `serialize_counts` with an EMPTY vocabulary map — so it
    /// stays a decodable RICT blob on its own and the `counts` column never
    /// becomes NULL or undecodable (a reader that ignores term rows still gets
    /// a valid, empty vocabulary plus the document count and df table).
    ///
    /// Each entry's vector is exactly the bytes `write_f32_array` emits for
    /// that term inside the blob: `u32 count` then `count` little-endian f32.
    /// Reusing the same writer is deliberate — the per-term encoding is the
    /// cross-port conformance contract and must not acquire a second encoder
    /// that could drift from the Swift twin.
    pub fn decompose_counts(&self) -> (Vec<u8>, Vec<(String, Vec<u8>)>) {
        let mut header = BasisWriter::new();
        self.write_counts_header(&mut header, &HashMap::new());

        let terms = self
            .vocab
            .iter()
            .map(|(term, vector)| {
                let mut w = BasisWriter::new();
                w.write_f32_array(vector);
                (term.clone(), w.into_bytes())
            })
            .collect();
        (header.into_bytes(), terms)
    }

    /// Read the counts frame and fields written by `write_counts_header`,
    /// returning the inline vocabulary map (empty for a decomposed header).
    /// Installs the restored document-frequency table into `counts` and
    /// clears the pooling fit (the caller finalizes).
    fn read_counts_header(
        &mut self,
        r: &mut BasisReader<'_>,
    ) -> Result<HashMap<String, Vec<f32>>, BasisCodecError> {
        r.expect_magic(RI_COUNTS_MAGIC)?;
        r.expect_version(BASIS_FORMAT_VERSION)?;
        let _model_id = r.read_string()?;
        let _model_version = r.read_string()?;
        let _projection_seed = r.read_u64()?;
        let vocabulary = r.read_string_f32_vector_map()?;
        let document_count = r.read_u32()? as usize;
        let document_frequencies = r.read_string_u32_map()?;
        self.counts = TermDocumentCounts::from_restored_document_frequencies(
            document_frequencies,
            document_count,
        );
        self.idf_table = HashMap::new();
        self.mean_direction = Vec::new();
        self.is_finalized = false;
        Ok(vocabulary)
    }

    /// Rehydrate from a header plus per-term entries — inverse of
    /// `decompose_counts`. Twin of the Swift
    /// `restoreCounts(header:terms:)`.
    ///
    /// The header is validated exactly as `restore_counts` validates a full
    /// blob, so a mismatched provider or format version still fails closed.
    /// Term order is irrelevant: the result is a map, and only the blob WRITER
    /// needs the UTF-8 byte ordering that keeps the two ports byte-identical.
    pub fn restore_counts_from_parts(
        &mut self,
        header: &[u8],
        terms: &[(String, Vec<u8>)],
    ) -> Result<(), BasisCodecError> {
        let mut r = BasisReader::new(header);
        let _ = self.read_counts_header(&mut r)?;

        let mut rebuilt = HashMap::with_capacity(terms.len());
        for (term, vector) in terms {
            let mut vr = BasisReader::new(vector);
            rebuilt.insert(term.clone(), vr.read_f32_array()?);
        }
        self.vocab = rebuilt;
        Ok(())
    }

    /// Restore the accumulated context vectors and document frequencies in
    /// place from a counts blob, so incremental maintenance resumes after a
    /// restart. Returns `Err(BasisCodecError)` on a bad blob — never panics.
    pub fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), BasisCodecError> {
        let mut r = BasisReader::new(bytes);
        let vocabulary = self.read_counts_header(&mut r)?;
        self.vocab = vocabulary;
        Ok(())
    }

    // MARK: - Private helpers

    /// Pool `text` through the finalized basis. Returns `None` for an
    /// unfinalized basis, empty text, all-OOV text, or a pooled vector that
    /// collapsed to zero. The second element counts the distinct terms that
    /// had a context vector (0 = vocabulary miss).
    fn pooled(&self, text: &str) -> (Option<Vec<f32>>, usize) {
        if !self.is_finalized || text.is_empty() {
            return (None, 0);
        }
        // corpus_kit::default_keyword_tokens is the single canonical keyword
        // tokenizer shared by all distributional providers (RI, PPMI, LSA,
        // NMF) and by BM25; parity with Swift's `defaultKeywordTokens`.
        let terms = corpus_kit::default_keyword_tokens(text);
        if terms.is_empty() {
            return (None, 0);
        }
        distributional_pooling::pool(
            &terms,
            &self.vocab,
            &self.idf_table,
            &self.mean_direction,
            RI_DIMENSION,
        )
    }

    /// Compute the pooled unit vector for `text`, or `None` when there is no
    /// signal (see `pooled`).
    fn context_vector(&self, text: &str) -> Option<Vec<f32>> {
        self.pooled(text).0
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
    /// Pools the text through the fitted basis and projects the pooled unit
    /// vector through `float_simhash::project` to produce the 256-bit Engram.
    /// Empty input returns `Engram::ZERO` (EmbeddingProvider contract).
    fn embed(&self, text: &str) -> Result<Engram, SynapseKitError> {
        match self.context_vector(text) {
            None => Ok(Engram::ZERO),
            Some(v) => Ok(float_simhash::project(&v, self.projection_seed)),
        }
    }

    /// Return the D-dimensional pooled unit vector for `text`.
    ///
    /// - No finalized basis (untrained, or trained without `finalize`):
    ///   returns `Ok(vec![])` — structural opt-out, no basis to pool against.
    /// - Empty or non-tokenisable input: returns `Ok(vec![])`.
    /// - Finalized provider, all query tokens OOV: returns
    ///   `Err(SynapseKitError::EmbedFloatVocabMiss(...))` so the corpus layer
    ///   maps to `FloatLaneOutcome::UnavailableNoVocabHit` rather than the
    ///   misleading `UnavailableProviderOptOut`.
    /// - Terms matched but the pooled vector collapsed to zero: `Ok(vec![])`
    ///   (honest no-signal, an opt-out rather than a vocabulary miss).
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        if !self.is_finalized || self.vocab.is_empty() {
            return Ok(vec![]);
        }
        if text.is_empty() {
            return Ok(vec![]);
        }
        let terms = corpus_kit::default_keyword_tokens(text);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        let (vector, hits) = distributional_pooling::pool(
            &terms,
            &self.vocab,
            &self.idf_table,
            &self.mean_direction,
            RI_DIMENSION,
        );
        if hits == 0 {
            return Err(SynapseKitError::EmbedFloatVocabMiss(format!(
                "random-indexing: vocab size {}, but 0 of {} query token(s) matched",
                self.vocab.len(),
                terms.len()
            )));
        }
        Ok(vector.unwrap_or_default())
    }

    /// Produce the engram AND the pooled unit vector from a SINGLE pooling
    /// computation.
    ///
    /// `embed` projects the pooled vector and `embed_float` returns it, so a
    /// caller that needs both would otherwise pool twice. This override pools
    /// ONCE and returns both outputs.
    ///
    /// Byte-identical to calling `embed` then `embed_float` separately: the
    /// engram is `float_simhash::project` of the vector (or `Engram::ZERO` when
    /// there is no signal), and `floats` reproduces `embed_float`'s result with
    /// its vocab-miss error collapsed to `vec![]` (the `embed_pair` opt-out
    /// contract).
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), SynapseKitError> {
        match self.context_vector(text) {
            None => Ok((Engram::ZERO, Vec::new())),
            Some(v) => Ok((float_simhash::project(&v, self.projection_seed), v)),
        }
    }
}

// MARK: - TrainableEmbeddingBasis

impl TrainableEmbeddingBasis for RandomIndexingProvider {
    /// Train the RI basis on a corpus of raw document texts.
    ///
    /// RI's `train` consumes a term slice per document, so each text is
    /// tokenized with the canonical `corpus_kit::default_keyword_tokens` — the
    /// SAME tokenizer `embed_float` uses — and fed to `train` at `RI_WINDOW`;
    /// `finalize` then fits the pooling state. This reproduces the exact state
    /// of `train` + `finalize` driven directly from token slices, so a basis
    /// serialized after `train_on_corpus` is byte-identical to the fixture
    /// whose corpus is the same texts tokenized.
    fn train_on_corpus(&mut self, texts: &[&str]) {
        for text in texts {
            let terms = corpus_kit::default_keyword_tokens(text);
            let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
            self.train(&term_refs, RI_WINDOW);
        }
        self.finalize();
    }

    /// Streamed-training page: the same per-text accumulation
    /// `train_on_corpus` runs, finalization deferred to `finalize_training`.
    fn accumulate_training(&mut self, texts: &[&str]) {
        for text in texts {
            let terms = corpus_kit::default_keyword_tokens(text);
            let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
            self.train(&term_refs, RI_WINDOW);
        }
    }

    fn finalize_training(&mut self) {
        self.finalize();
    }

    /// Serialize the finalized RI basis, surfaced through the seam.
    fn serialize_basis(&self) -> Vec<u8> {
        RandomIndexingProvider::serialize_basis(self)
    }

    /// Reconstruct a fresh `RandomIndexingProvider` from a basis blob, boxed.
    /// Delegates to `from_serialized_basis`; a codec error maps to
    /// `CorpusKitError::DecodingFailure` (parity with Swift's `decodingFailure`).
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        let provider = RandomIndexingProvider::from_serialized_basis(basis)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))?;
        Ok(Box::new(provider))
    }

    /// Release the in-memory vocab and the pooling fit to free heap.
    fn release_basis(&mut self) {
        self.vocab.clear();
        self.vocab.shrink_to_fit();
        self.idf_table.clear();
        self.idf_table.shrink_to_fit();
        self.mean_direction = Vec::new();
        self.is_finalized = false;
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

    /// Fold one chunk into the accumulated context vectors and document
    /// frequencies. RI's accumulation consumes a term slice, so the text is
    /// tokenized with the canonical `default_keyword_tokens` and folded at
    /// `RI_WINDOW` — the same per-document step `train_on_corpus` runs, minus
    /// the finalize.
    fn add_to_counts(&mut self, text: &str) {
        let terms = corpus_kit::default_keyword_tokens(text);
        let term_refs: Vec<&str> = terms.iter().map(String::as_str).collect();
        self.train(&term_refs, RI_WINDOW);
    }

    /// Serialize the maintained state (RICT counts codec), surfaced through
    /// the seam.
    fn serialize_counts(&self) -> Vec<u8> {
        RandomIndexingProvider::serialize_counts(self)
    }

    /// Restore the maintained state; a codec error maps to
    /// `CorpusKitError::DecodingFailure`.
    fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError> {
        RandomIndexingProvider::restore_counts(self, bytes)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))
    }

    /// RandomIndexing is the provider whose counts scale with vocabulary, so it
    /// is the one that overrides the decomposition seam.
    fn decompose_counts(&self) -> Option<(Vec<u8>, Vec<(String, Vec<u8>)>)> {
        Some(RandomIndexingProvider::decompose_counts(self))
    }

    fn restore_counts_from_parts(
        &mut self,
        header: &[u8],
        terms: &[(String, Vec<u8>)],
    ) -> Result<(), CorpusKitError> {
        RandomIndexingProvider::restore_counts_from_parts(self, header, terms)
            .map_err(|e| CorpusKitError::DecodingFailure(e.to_string()))
    }

    /// Maintained vocabulary size for the growth trigger.
    fn counts_vocabulary_size(&self) -> usize {
        self.vocab.len()
    }

    fn counts_contains_term(&self, term: &str) -> bool {
        self.vocab.contains_key(term)
    }

    /// Derive the serving basis from restored counts: the RICT payload holds
    /// the complete accumulated state (context vectors, document frequencies,
    /// document count), and `finalize` is a pure function of it, so the basis
    /// it fits is byte-identical to one trained from scratch over the same
    /// accumulated corpus. Returns `true`.
    fn finalize_from_counts(&mut self) -> bool {
        self.finalize();
        true
    }

    /// RI float accumulation is NOT commutative (Finding F-3): context vectors
    /// are running f32 sums, and IEEE 754 f32 addition is not associative.
    /// Folding additional texts into restored counts in a different order from the
    /// original corpus changes the byte output of `serialize_basis`. Therefore
    /// delta-fold after restore is unsupported for RI; the counts path is
    /// restore-only with an EMPTY delta. Use `train_on_corpus` from scratch for
    /// any fold that changes document order.
    fn counts_delta_fold_safe(&self) -> bool {
        false
    }
}

// MARK: - Unit tests

#[cfg(test)]
mod tests {
    use super::*;
    use synapsekit::EmbeddingProvider;

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
    fn training_counts_documents_and_document_frequency() {
        let mut provider = RandomIndexingProvider::new();
        provider.train(&["car", "car", "engine"], RI_WINDOW);
        provider.train(&["engine", "drive"], RI_WINDOW);
        provider.train(&[], RI_WINDOW);
        assert_eq!(provider.document_count(), 2, "an empty call is not a document");
        provider.finalize();
        // engine: df 2 of N 2 → ln(3/3) = 0; car: df 1 → ln(3/2).
        assert_eq!(provider.inverse_document_frequency_for_term("engine"), Some(0.0));
        assert_eq!(
            provider.inverse_document_frequency_for_term("car"),
            Some((3.0f32 / 2.0).ln())
        );
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
    fn unfinalized_provider_returns_empty_float_vec() {
        let mut provider = RandomIndexingProvider::new();
        provider.train(&["car", "engine", "drive"], RI_WINDOW);
        assert!(
            provider.embed_float("car engine").unwrap().is_empty(),
            "embed_float must return empty before finalize()"
        );
    }

    #[test]
    fn trained_text_returns_unit_length_float_vector() {
        let mut provider = RandomIndexingProvider::new();
        provider.train(&["car", "engine", "drive"], RI_WINDOW);
        provider.train(&["dog", "bark", "run"], RI_WINDOW);
        provider.finalize();
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
        provider.finalize();
        let e1 = provider.embed("car engine").unwrap();
        let e2 = provider.embed("car engine").unwrap();
        assert_eq!(e1, e2, "same text must produce same embedding");
    }
}
