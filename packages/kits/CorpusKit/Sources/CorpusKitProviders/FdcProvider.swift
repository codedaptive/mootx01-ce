// FdcProvider.swift
//
// FDC (Frame Decimal Classification) relatedness embedding provider.
// Part of the ADR-010 Decision B honest-fusion signal set.
//
// ## What this provides
//
// "Drawers near the query's FDC address are topically related."
// The FDC co-classification signal encodes a text into a deterministic
// float vector such that codes sharing a longer prefix (more common
// ancestors in the FDC decimal taxonomy) are CLOSER in cosine. This
// captures taxonomic proximity — broad topical kinship at the root
// levels, fine kinship at deeper subclasses.
//
// ## Existing FDC API reused (Gate 2)
//
// Text → FDC code: `LatticeLib.FDC.encode(text)`.
// Ancestor chain: `LatticeLib.FDC.ancestors(of: code)` (runtime façade
//   over `FDCFrame.ancestors(of:)` — the decimal hierarchy math lives in
//   LatticeLib, not reimplemented here).
// Float-vector math: `SubstrateKernel.FloatVecOps.l2Normalize` (the
// canonical, conformance-gated substrate primitive — not inlined).
// Binary engram: `SubstrateML.FloatSimHash.project` (substrate primitive).
//
// ## Encoding algorithm (documented for cross-port bit-identity)
//
//   Dimension D = 256.
//   FDC_PROJECTION_SEED = 0x4644_435F_5631_5F50 ("FDC_V1_P" in ASCII).
//   Model ID = "fdc-v1", version = "1.0.0".
//
//   For text:
//   1. Encode text to an FDC code via `FDC.encode(text)`.
//      If nil or empty → return empty float vector (opt-out from float lane).
//   2. Build the full hierarchy path, root first:
//        path = FDC.ancestors(of: code) + [code]
//      e.g. "547.7" → ["000", "500", "540", "547", "547.7"]
//   3. For each node at index L (0-based, root = 0) in path:
//      a. Generate a deterministic D-dimensional unit vector for this node:
//            seed    = FNV64(node_string)
//            rng     = SplitMix64(seed)
//            floats  = LCG-generated D values in [-1, 1]   (private FDC LCG constants; distinct from RI's SplitMix64-only draws)
//            nodeVec = l2Normalize(floats)
//         (If norm == 0, nodeVec = zero; this cannot happen for non-empty
//          code strings but is handled by the zero-vector passthrough in
//          l2Normalize.)
//      b. levelWeight = 1.0 / Float(L + 1)
//         (Root = 1.0, next level = 0.5, … — top levels weighted higher.)
//      c. accumulator += levelWeight × nodeVec
//   4. L2-normalise the accumulator (FloatVecOps.l2Normalize).
//   5. Return as the embedFloat vector.
//   6. `embed` projects it through FloatSimHash(seed: FDC_PROJECTION_SEED).
//
//   The FDC PRNG sequence seeds with FNV.hash64, advances SplitMix64
//   once, then draws from private FDC LCG constants. RI's riIndexVector
//   uses repeated SplitMix64 draws for position/sign pairs; no LCG stage.
//
// ## Zero-vector contract
//
// If FDC.encode returns nil (UNRESOLVED text), embedFloat returns `[]`.
// The Corpus float lane interprets `[]` as "no float lane for this chunk"
// and skips the dense lane for this item. This is the honest opt-out:
// a text that cannot be classified should not contribute false vectors.
//
// ## LCG constants (shared with deterministic provider — documented here)
//
//   LCG_MULTIPLIER = 6_364_136_223_846_793_005  (Knuth)
//   LCG_INCREMENT  = 1_442_695_040_888_963_407  (Brown)
//   HIGH-24 bits of LCG output → mantissa in [0, 1) → scale to [-1, 1].
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/fdc_provider.rs
//
// ADR-010 reference: Decision B, "FDC lattice co-classification" signal.

import Foundation
import CorpusKit
import EngramLib
import LatticeLib
import SubstrateKernel
import SubstrateML
import SubstrateTypes
import VectorKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FNV hashing: SubstrateTypes.FNV.hash64 (seeds the SplitMix64 → LCG draw)
// SplitMix64: SubstrateML.SplitMix64
// FloatSimHash projection: SubstrateML.FloatSimHash.project
// Float-vector ops: SubstrateKernel.FloatVecOps.l2Normalize
//
// FDC runtime: LatticeLib.FDC.encode (not reimplemented here)
// FDC ancestor chain: LatticeLib.FDC.ancestors(of:) — the runtime
//   façade over FDCFrame.ancestors(of:). The decimal hierarchy math
//   lives in LatticeLib. Callers use the FDC enum, not FDCFrame.
// ─────────────────────────────────────────────────────────────────

// MARK: - Constants
//
// All constants are public so the test suite and cross-port conformance
// tests can reference them by name. The Rust port mirrors these constants
// in fdc_provider.rs with the same names and values.

/// Dimensionality of the FDC embedding vector.
/// 256 gives compact representation while preserving enough dimensions
/// for the taxonomy depth (FDC frame depth ≤ 5 levels in practice).
public let fdcDimension: Int = 256

/// FloatSimHash projection seed for FDC provider. Encodes "FDC_V1_P"
/// in ASCII — "FDC V1 Proximity" — marking proximity-by-taxonomy.
/// Must not drift from the Rust constant FDC_PROJECTION_SEED.
public let fdcProjectionSeed: UInt64 = 0x4644_435F_5631_5F50

// LCG constants — shared with CorpusKit.EmbeddingModel.deterministic and
// the Rust deterministic provider; documented here for the FDC node-vector
// generation path. Both ports use the same constants.
private let fdcLcgMultiplier: UInt64 = 6_364_136_223_846_793_005
private let fdcLcgIncrement: UInt64 = 1_442_695_040_888_963_407

// MARK: - Node vector generation

/// Generate a deterministic D-dimensional unit vector for a single FDC code string.
///
/// Algorithm (cross-port identical):
///   1. seed = FNV64(code.utf8)
///   2. rng  = SplitMix64(seed)
///   3. Draw D values via LCG in [-1, 1] (same LCG as the deterministic provider)
///   4. L2-normalise → unit vector (zero-vector passthrough if norm == 0)
///
/// The 2-phase seeding (FNV → SplitMix64 → LCG) ensures that:
///   - Different code strings produce independent unit vectors.
///   - The LCG distributes the D dimensions uniformly in [-1, 1].
///   - The result is bit-identical in the Rust port (uses the same constants).
///
/// Using the FNV64 + SplitMix64 pattern from RandomIndexingProvider (riIndexVector)
/// gives cross-provider seed isolation: the FDC node-vector seed space cannot
/// collide with RI/PPMI seeds because the FDC code strings are a different domain.
public func fdcNodeVector(code: String) -> [Float] {
    // FNV-1a 64-bit hash of the code string via the substrate canonical
    // primitive — the single home for dense/deterministic hash math. The
    // Rust port calls substrate_types::fnv::hash64 for the same seed.
    let seed = FNV.hash64(code)

    // SplitMix64 to advance one step before the LCG draw (matches RI pattern:
    // the SplitMix64 output IS the LCG state seed for further draws). We use
    // SplitMix64 exactly once to produce the initial LCG state, then run the
    // same LCG as the deterministic provider for D consecutive values.
    var rng = SplitMix64(seed: seed)
    var h: UInt64 = rng.next()

    var vec = [Float](repeating: 0, count: fdcDimension)
    for i in 0..<fdcDimension {
        h = h &* fdcLcgMultiplier &+ fdcLcgIncrement
        // High 24 bits as a mantissa in [0, 1), then scale to [-1, 1].
        let mantissa = Float(h >> 40) / Float(1 << 24)
        vec[i] = mantissa * 2.0 - 1.0
    }

    // L2-normalise via the substrate canonical scalar implementation.
    // FloatVecOps.l2Normalize is conformance-gated; using it guarantees
    // bit-identity with the Rust port without a separate inline implementation.
    return FloatVecOps.l2Normalize(vec)
}

// MARK: - FDC vector for a text

/// Compute the FDC relatedness vector for `text`.
///
/// Returns `nil` when the text is UNRESOLVED (FDC.encode returned nil or
/// the empty string), indicating the float lane should be dark for this text.
///
/// The returned vector is L2-normalised (unit vector) when non-nil.
///
/// - Parameter text: the text to classify and embed.
/// - Returns: L2-normalised D-dimensional float vector, or nil if unresolved.
func fdcEmbeddingVector(text: String) -> [Float]? {
    // Step 1: encode to FDC code using the existing LatticeLib FDC runtime.
    // FDC.encode is the canonical entry point (delegating to FDCMatcher);
    // not reimplemented here (Gate 2 compliance).
    guard let code = FDC.encode(text), !code.isEmpty else { return nil }

    // Step 2: build the full hierarchy path [ancestors..., code].
    // FDC.ancestors(of:) is the LatticeLib runtime façade over
    // FDCFrame.ancestors(of:). The decimal hierarchy math lives in LatticeLib;
    // this provider does not reimplement it (Gate 2).
    var path = FDC.ancestors(of: code)
    path.append(code)

    // Step 3: accumulate weighted node vectors.
    var accumulator = [Float](repeating: 0, count: fdcDimension)
    for (L, node) in path.enumerated() {
        let nodeVec = fdcNodeVector(code: node)
        // Level weight: root (L=0) = 1.0, decreasing with depth.
        // This gives broad topical kinship (shared root) measurable cosine
        // similarity, while fine kinship (shared deep ancestors) adds to it.
        let weight = 1.0 / Float(L + 1)
        for d in 0..<fdcDimension {
            accumulator[d] += weight * nodeVec[d]
        }
    }

    // Step 4: L2-normalise the accumulated vector.
    let normalised = FloatVecOps.l2Normalize(accumulator)

    // Zero-vector check: if all weighted node vectors cancel out (extremely
    // unlikely but possible for a single-level code with a near-zero node
    // vector), return nil (opt-out) rather than a zero-direction vector.
    let normSq = normalised.reduce(Float(0)) { $0 + $1 * $1 }
    guard normSq > 0 else { return nil }

    return normalised
}

// MARK: - FDCProvider

/// FDC (Frame Decimal Classification) relatedness embedding provider.
///
/// Encodes text into a deterministic float vector derived from the text's
/// FDC classification code. Codes sharing a longer prefix (more common
/// ancestors in the FDC taxonomy) have higher cosine similarity — broad
/// topical kinship at the root, fine kinship at deeper subclasses.
///
/// ## Thread safety
///
/// `FDCProvider` is `Sendable`. It holds no mutable state — each `embed`
/// and `embedFloat` call is a pure function of the text and the FDC runtime
/// (which is a process-global singleton, loaded once). Safe for concurrent use.
///
/// ## Conformance
///
/// Conforms to `VectorKit.EmbeddingProvider`. modelID = "fdc-v1",
/// modelVersion = "1.0.0". Projection seed = `fdcProjectionSeed`.
///
/// ## Float lane
///
/// `embedFloat` returns the D-dimensional FDC relatedness vector. UNRESOLVED
/// text (FDC.encode returns nil) returns `[]` — the expected opt-out signal
/// for the dense float lane. An empty `embedFloat` result causes Corpus.ingest
/// to skip the float lane row for that chunk (the binary engram lane is
/// unaffected). Recall on unresolved chunks falls back to the BM25 lane.
///
/// ADR-010 Decision B: FDC lattice co-classification signal.
public final class FDCProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// FloatSimHash projection seed. Fixed to fdcProjectionSeed.
    private let projectionSeed: UInt64

    // MARK: Initialiser

    /// Create an FDC provider.
    ///
    /// The provider is stateless — it delegates to LatticeLib's FDC runtime
    /// (loaded once per process). No training step is required.
    ///
    /// - Parameters:
    ///   - modelID:       Embedding model identifier. Default "fdc-v1".
    ///   - modelVersion:  Model version string. Default "1.0.0".
    ///   - projectionSeed: FloatSimHash seed. Default `fdcProjectionSeed`.
    public init(
        modelID: String = "fdc-v1",
        modelVersion: String = "1.0.0",
        projectionSeed: UInt64 = fdcProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
    }

    // MARK: EmbeddingProvider

    /// Produce the FDC relatedness engram for `text`.
    ///
    /// Classifies `text` via FDC.encode, derives the ancestor hierarchy,
    /// accumulates level-weighted node vectors, L2-normalises, and projects
    /// through FloatSimHash to produce the 256-bit Engram.
    ///
    /// Empty input returns `Engram.zero` (EmbeddingProvider contract).
    /// UNRESOLVED text also returns `Engram.zero` — same honest no-information
    /// signal as the zero-vector passthrough in other providers.
    public func embed(_ text: String) async throws -> Engram {
        guard let v = fdcEmbeddingVector(text: text), !v.isEmpty else {
            return .zero
        }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the D-dimensional FDC relatedness vector for `text`.
    ///
    /// This is the honest topical-proximity vector: nearby codes in the FDC
    /// taxonomy have high cosine similarity. Callers using the float lane get
    /// real taxonomic coordinates, not a hash-of-surface-form.
    ///
    /// Returns `[]` for empty input or UNRESOLVED text (EmbeddingProvider
    /// opt-out contract: the float lane stays dark for unresolved chunks).
    public func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        return fdcEmbeddingVector(text: text) ?? []
    }

    /// Single-pass override: compute the FDC relatedness vector ONCE, then derive
    /// BOTH outputs from it — the projected engram and the float-lane vector.
    /// This replaces the two independent `fdcEmbeddingVector` calls that `embed`
    /// and `embedFloat` would each make (Corpus ingest needs both per chunk).
    /// Outputs are byte-identical to calling `embed` and `embedFloat` separately:
    /// the engram is `FloatSimHash.project(v)` and the float row is `v`.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        guard let v = fdcEmbeddingVector(text: text), !v.isEmpty else {
            return (.zero, [])
        }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }
}
