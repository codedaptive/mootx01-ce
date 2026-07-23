//! FDC (Frame Decimal Classification) relatedness embedding provider.
//! Rust port of Swift's `FDCProvider` in `CorpusKitProviders`.
//!
//! Part of the honest semantic fusion honest-fusion signal set.
//!
//! ## What this provides
//!
//! "Drawers near the query's FDC address are topically related."
//! The FDC co-classification signal encodes a text into a deterministic
//! float vector such that codes sharing a longer prefix (more common
//! ancestors in the FDC decimal taxonomy) are CLOSER in cosine. This
//! captures taxonomic proximity — broad topical kinship at the root
//! levels, fine kinship at deeper subclasses.
//!
//! ## Existing FDC API reused (Gate 2)
//!
//! Text → FDC code: `lattice_lib::Fdc::encode(text)`.
//! Ancestor chain: `lattice_lib::Fdc::ancestors(code)` — the runtime façade
//!   over `FdcFrame::ancestors`. The decimal hierarchy math lives in LatticeLib,
//!   not reimplemented here.
//! Float-vector math: `substrate_kernel::float_vec_ops::l2_normalize`
//! (the canonical, conformance-gated substrate primitive — not inlined).
//! Binary engram: `substrate_ml::float_simhash::project` (substrate primitive).
//!
//! ## Encoding algorithm (cross-port identical to Swift FdcProvider.swift)
//!
//!   Dimension D = 256.
//!   FDC_PROJECTION_SEED = 0x4644_435F_5631_5F50 ("FDC_V1_P" in ASCII).
//!   Model ID = "fdc-v1", version = "1.0.0".
//!
//!   For text:
//!   1. Encode text to an FDC code via `Fdc::encode(text)`.
//!      If None or empty → return empty float vector (opt-out).
//!   2. Build the full hierarchy path, root first:
//!        path = ancestors(code) + [code]
//!      e.g. "547.7" → ["000", "500", "540", "547", "547.7"]
//!   3. For each node at index L (0-based, root = 0) in path:
//!      a. Generate a deterministic D-dimensional unit vector for this node:
//!            seed    = FNV64(node_string)
//!            rng     = SplitMix64(seed)
//!            h       = rng.next()   (one SplitMix64 advance)
//!            floats  = D values via LCG: h = h*M+I, float=(h>>40)/(2^24)*2-1
//!            nodeVec = l2_normalize(floats)
//!      b. levelWeight = 1.0 / (L + 1) as f32
//!         (Root = 1.0, next level = 0.5, … — top levels weighted higher.)
//!      c. accumulator += levelWeight × nodeVec
//!   4. l2_normalize the accumulator.
//!   5. Return as the embed_float vector.
//!   6. `embed` projects it through float_simhash::project(FDC_PROJECTION_SEED).
//!
//! ## Zero-vector contract
//!
//! If Fdc::encode returns None or empty (UNRESOLVED text), embed_float returns
//! `Vec::new()` (empty). The Corpus float lane interprets this as "no float lane
//! for this chunk" and skips the dense lane row for that item.
//!
//! ## LCG constants (shared with make_deterministic_provider in corpus.rs)
//!
//!   LCG_MULTIPLIER = 6_364_136_223_846_793_005  (Knuth)
//!   LCG_INCREMENT  = 1_442_695_040_888_963_407  (Brown)
//!   h >> 40 → mantissa in [0, 1) → * 2 - 1 → [-1, 1]
//!
//! Swift port: packages/kits/CorpusKit/Sources/CorpusKitProviders/FdcProvider.swift
//!
//! honest semantic fusion reference: Decision B, "FDC lattice co-classification" signal.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FNV hashing: substrate_types::fnv::hash64 (I-25)
// SplitMix64: substrate_ml::random_walks::SplitMix64
// FloatSimHash projection: substrate_ml::float_simhash::project
// Float-vector ops: substrate_kernel::float_vec_ops::l2_normalize
//
// FDC runtime: lattice_lib::Fdc::encode (not reimplemented here)
// FDC ancestor chain: lattice_lib::Fdc::ancestors — the runtime façade over
//   FdcFrame::ancestors. The decimal hierarchy math lives in LatticeLib;
//   callers use Fdc::ancestors, not FdcFrame directly.
// ─────────────────────────────────────────────────────────────────

use engram_lib::Engram;
use lattice_lib::Fdc;
use substrate_kernel::float_vec_ops;
use substrate_ml::float_simhash;
use substrate_ml::random_walks::SplitMix64;
use substrate_types::fnv;
use vectorkit::{EmbeddingProvider, VectorKitError};

// MARK: - Constants
//
// All constants are `pub` so the conformance test can reference them by name.
// Byte-identical to the Swift constants in FdcProvider.swift.

/// Dimensionality of the FDC embedding vector.
/// 256 gives compact representation while preserving enough dimensions
/// for the taxonomy depth (FDC frame depth ≤ 5 levels in practice).
pub const FDC_DIMENSION: usize = 256;

/// FloatSimHash projection seed for FDC provider. Encodes "FDC_V1_P"
/// in ASCII — "FDC V1 Proximity" — marking proximity-by-taxonomy.
/// Must not drift from the Swift constant `fdcProjectionSeed`.
pub const FDC_PROJECTION_SEED: u64 = 0x4644_435F_5631_5F50;

/// LCG multiplier (Knuth). Same as the deterministic provider in corpus.rs.
const LCG_MULTIPLIER: u64 = 6_364_136_223_846_793_005;
/// LCG increment (Brown). Same as the deterministic provider in corpus.rs.
const LCG_INCREMENT: u64 = 1_442_695_040_888_963_407;

// MARK: - Node vector generation

/// Generate a deterministic D-dimensional unit vector for a single FDC code string.
///
/// Algorithm (bit-identical to Swift `fdcNodeVector(code:)`):
///   1. seed = FNV64(code.as_bytes())
///   2. rng  = SplitMix64::new(seed)
///   3. h    = rng.next()   (one SplitMix64 advance, seeds the LCG)
///   4. For each of D dimensions: h = h*M+I; float = (h>>40)/(2^24)*2-1
///   5. l2_normalize(floats) → unit vector
///
/// The FNV64 constant (offset basis / prime) matches substrate_types::fnv::hash64
/// used throughout the substrate. The SplitMix64 + LCG pattern matches RI provider.
pub fn fdc_node_vector(code: &str) -> Vec<f32> {
    // FNV-1a 64-bit hash of the code string bytes.
    // substrate_types::fnv::hash64 uses the standard FNV-1a constants:
    //   offset basis = 14_695_981_039_346_656_037
    //   prime        = 1_099_511_628_211
    let seed = fnv::hash64(code);

    // One SplitMix64 step to advance the state, then use the output as the
    // initial LCG state (mirrors the Swift: `var rng = SplitMix64(seed: seed)`,
    // then `var h: UInt64 = rng.next()`).
    let mut rng = SplitMix64::new(seed);
    let mut h: u64 = rng.next();

    let mut vec: Vec<f32> = (0..FDC_DIMENSION)
        .map(|_| {
            h = h.wrapping_mul(LCG_MULTIPLIER).wrapping_add(LCG_INCREMENT);
            // High 24 bits as a mantissa in [0, 1), then scale to [-1, 1].
            // Matches Swift: `Float(h >> 40) / Float(1 << 24)  * 2.0 - 1.0`
            let mantissa = (h >> 40) as f32 / (1u64 << 24) as f32;
            mantissa * 2.0 - 1.0
        })
        .collect();

    // L2-normalise via the substrate canonical scalar implementation.
    // substrate_kernel::float_vec_ops::l2_normalize is conformance-gated;
    // using it guarantees bit-identity with the Swift port without a
    // separate inline implementation.
    vec = float_vec_ops::l2_normalize(vec);
    vec
}

// MARK: - FDC embedding vector

/// Compute the FDC relatedness vector for `text`.
///
/// Returns `None` when the text is UNRESOLVED (Fdc::encode returned None or
/// the empty string), indicating the float lane should be dark for this text.
///
/// The returned vector is L2-normalised (unit vector) when `Some`.
///
/// Mirrors Swift `fdcEmbeddingVector(text:)` in FdcProvider.swift.
pub fn fdc_embedding_vector(text: &str) -> Option<Vec<f32>> {
    // Step 1: encode to FDC code using the existing LatticeLib FDC runtime.
    let code = Fdc::encode(text)?;
    if code.is_empty() {
        return None;
    }

    // Step 2: build the full hierarchy path [ancestors..., code].
    // Fdc::ancestors is the LatticeLib runtime façade over FdcFrame::ancestors.
    // The decimal hierarchy math lives in LatticeLib; not reimplemented here
    // (Gate 2).
    let mut path = Fdc::ancestors(&code);
    path.push(code.clone());

    // Step 3: accumulate weighted node vectors.
    let mut accumulator = vec![0.0f32; FDC_DIMENSION];
    for (l, node) in path.iter().enumerate() {
        let node_vec = fdc_node_vector(node);
        // Level weight: root (L=0) = 1.0, decreasing with depth.
        let weight = 1.0 / (l + 1) as f32;
        for d in 0..FDC_DIMENSION {
            accumulator[d] += weight * node_vec[d];
        }
    }

    // Step 4: L2-normalise the accumulated vector.
    let normalised = float_vec_ops::l2_normalize(accumulator);

    // Zero-vector check: if all weighted node vectors cancel (unlikely),
    // return None (opt-out) rather than a zero-direction vector.
    let norm_sq: f32 = normalised.iter().map(|&x| x * x).sum();
    if norm_sq <= 0.0 {
        return None;
    }

    Some(normalised)
}

// MARK: - FDCProvider

/// FDC (Frame Decimal Classification) relatedness embedding provider.
/// Rust mirror of Swift's `FDCProvider` in `CorpusKitProviders`.
///
/// Encodes text into a deterministic float vector derived from the text's
/// FDC classification code. Codes sharing a longer prefix (more common
/// ancestors in the FDC taxonomy) have higher cosine similarity.
///
/// The provider is stateless — no training step is required. It delegates
/// to the `lattice_lib::Fdc` runtime (a process-global singleton loaded
/// once at first use via the `include_bytes!` artifact bundle in LatticeLib).
///
/// ## Thread safety
///
/// `FDCProvider` is `Send + Sync`. It holds no mutable state.
///
/// ## Float lane
///
/// `embed_float` returns the D-dimensional FDC relatedness vector. UNRESOLVED
/// text returns `vec![]` — the expected opt-out signal. The Corpus float lane
/// skips the dense lane row for those chunks. Fallback: BM25 lane.
///
/// FDC lattice co-classification signal.
pub struct FDCProvider {
    model_id: String,
    model_version: String,
    projection_seed: u64,
}

impl FDCProvider {
    /// Create an FDC provider.
    ///
    /// The provider is stateless — it delegates to the LatticeLib FDC runtime.
    /// No training step is required.
    ///
    /// - `model_id`: Embedding model identifier. Default "fdc-v1".
    /// - `model_version`: Model version string. Default "1.0.0".
    /// - `projection_seed`: FloatSimHash seed. Default `FDC_PROJECTION_SEED`.
    pub fn new(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
    ) -> Self {
        FDCProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            projection_seed,
        }
    }

    /// Create an FDC provider with default parameters.
    /// model_id = "fdc-v1", model_version = "1.0.0", seed = FDC_PROJECTION_SEED.
    pub fn default_provider() -> Self {
        FDCProvider::new("fdc-v1", "1.0.0", FDC_PROJECTION_SEED)
    }
}

impl EmbeddingProvider for FDCProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }
    fn model_version(&self) -> &str {
        &self.model_version
    }

    /// Produce the FDC relatedness engram for `text`.
    ///
    /// Classifies text via Fdc::encode, derives the ancestor hierarchy,
    /// accumulates level-weighted node vectors, L2-normalises, and projects
    /// through float_simhash::project to produce the 256-bit Engram.
    ///
    /// Empty or UNRESOLVED input returns `Engram::ZERO`.
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        if text.is_empty() {
            return Ok(Engram::ZERO);
        }
        match fdc_embedding_vector(text) {
            Some(v) if !v.is_empty() => {
                Ok(float_simhash::project(&v, self.projection_seed))
            }
            _ => Ok(Engram::ZERO),
        }
    }

    /// Return the D-dimensional FDC relatedness vector for `text`.
    ///
    /// Returns `vec![]` for empty input or UNRESOLVED text (opt-out contract:
    /// the float lane stays dark for unresolved chunks). The vector is
    /// L2-normalised (unit vector) when non-empty.
    ///
    /// Mirrors Swift `FDCProvider.embedFloat(_:)`.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
        Ok(fdc_embedding_vector(text).unwrap_or_default())
    }

    /// Single-pass override: compute the FDC relatedness vector ONCE, then derive
    /// BOTH outputs from it — the projected engram and the float-lane vector.
    /// Replaces the two independent `fdc_embedding_vector` calls that `embed` and
    /// `embed_float` would each make (Corpus ingest needs both per chunk).
    /// Outputs are byte-identical to calling `embed` and `embed_float` separately.
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), VectorKitError> {
        if text.is_empty() {
            return Ok((Engram::ZERO, Vec::new()));
        }
        match fdc_embedding_vector(text) {
            Some(v) if !v.is_empty() => Ok((float_simhash::project(&v, self.projection_seed), v)),
            _ => Ok((Engram::ZERO, Vec::new())),
        }
    }
}

// MARK: - Unit tests

#[cfg(test)]
mod tests {
    use super::*;
    use vectorkit::EmbeddingProvider;

    // ── node vector properties ────────────────────────────────────────────

    #[test]
    fn node_vector_dimension() {
        let v = fdc_node_vector("540");
        assert_eq!(v.len(), FDC_DIMENSION);
    }

    #[test]
    fn node_vector_unit_norm() {
        let v = fdc_node_vector("006.6");
        let norm: f32 = v.iter().map(|&x| x * x).sum::<f32>().sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-5,
            "node vector must be unit-norm; got {norm}"
        );
    }

    #[test]
    fn node_vector_deterministic() {
        let v1 = fdc_node_vector("540");
        let v2 = fdc_node_vector("540");
        assert_eq!(v1, v2, "fdc_node_vector must be deterministic");
    }

    #[test]
    fn node_vector_seed_isolation() {
        let v1 = fdc_node_vector("000");
        let v2 = fdc_node_vector("100");
        let cos: f32 = v1.iter().zip(v2.iter()).map(|(a, b)| a * b).sum();
        assert!(cos < 0.95, "different codes must produce distinct unit vectors");
    }

    // ── FDCProvider properties ────────────────────────────────────────────

    #[test]
    fn empty_embed_float_returns_empty() {
        let p = FDCProvider::default_provider();
        let v = p.embed_float("").expect("must not error");
        assert!(v.is_empty(), "empty text must return vec![] from embed_float");
    }

    #[test]
    fn empty_embed_returns_zero_engram() {
        let p = FDCProvider::default_provider();
        let e = p.embed("").expect("must not error");
        assert_eq!(e, Engram::ZERO, "empty text must return Engram::ZERO from embed");
    }

    #[test]
    fn resolved_text_returns_unit_vector() {
        let p = FDCProvider::default_provider();
        let v = p.embed_float("organic chemistry reactions molecules").expect("must not error");
        if v.is_empty() {
            // Acceptable: FDC couldn't resolve this text on this build.
            return;
        }
        assert_eq!(v.len(), FDC_DIMENSION);
        let norm: f32 = v.iter().map(|&x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-5, "embed_float must return unit-norm; got {norm}");
    }

    #[test]
    fn embed_float_result_is_either_unit_or_empty() {
        // The FDC runtime can classify inputs that look like nonsense by falling
        // back to partial matches. embed_float MUST return either an empty vec
        // (no classification) OR a unit-norm vector. Never a non-unit non-empty.
        let p = FDCProvider::default_provider();
        let inputs = [
            "zxcvqwerty asdfgh nonsense unresolvable",
            "",
            "some completely random text fragment",
        ];
        for text in &inputs {
            let v = p.embed_float(text).expect("must not error");
            if v.is_empty() {
                // Valid opt-out result.
                continue;
            }
            // Non-empty must be unit-norm.
            assert_eq!(v.len(), FDC_DIMENSION, "non-empty result must have FDC_DIMENSION");
            let norm: f32 = v.iter().map(|&x| x * x).sum::<f32>().sqrt();
            assert!(
                (norm - 1.0).abs() < 1e-5,
                "non-empty embed_float for {:?} must be unit-norm; got {norm}",
                text
            );
        }
    }

    #[test]
    fn embed_float_is_deterministic() {
        let p = FDCProvider::default_provider();
        let text = "computer science programming";
        let v1 = p.embed_float(text).expect("must not error");
        let v2 = p.embed_float(text).expect("must not error");
        assert_eq!(v1, v2, "embed_float must be deterministic");
    }

    #[test]
    fn model_id_is_fdc_v1() {
        let p = FDCProvider::default_provider();
        assert_eq!(p.model_id(), "fdc-v1");
    }

    #[test]
    fn model_version_is_1_0_0() {
        let p = FDCProvider::default_provider();
        assert_eq!(p.model_version(), "1.0.0");
    }

    // ── taxonomic kinship ─────────────────────────────────────────────────

    #[test]
    fn taxonomy_kinship_same_class_higher_cosine() {
        let p = FDCProvider::default_provider();
        let chem_a = p.embed_float("organic chemistry reactions").expect("err");
        let chem_b = p.embed_float("inorganic chemistry compounds").expect("err");
        let philo = p.embed_float("ethics philosophy Socrates").expect("err");

        if chem_a.is_empty() || chem_b.is_empty() || philo.is_empty() {
            // Unresolved inputs: skip the assertion.
            return;
        }

        let sim_same: f32 = chem_a.iter().zip(chem_b.iter()).map(|(a, b)| a * b).sum();
        let sim_diff: f32 = chem_a.iter().zip(philo.iter()).map(|(a, b)| a * b).sum();
        assert!(
            sim_same > sim_diff,
            "same-class similarity {sim_same} must exceed cross-class {sim_diff}"
        );
    }
}
