// NLEmbeddingProvider.swift
//
// Apple NaturalLanguage sentence embedding provider.
//
// Uses `NLEmbedding.sentenceEmbedding(for:)` — the system-bundled
// Apple sentence similarity model; guarded by `#if canImport(NaturalLanguage)`.
// No model asset download required: the embedding model ships with the
// OS. This makes it the "cheap, immediate" Apple-native comparative
// surface (vs. the CoreML bring-your-own-model path in the named
// EmbeddingModel cases).
//
// ## Design
//
//   item-local: the vector is a pure function of the input text,
//   computed once on write. No trainable basis, no counts, no shadow
//   swap machinery. Sits alongside FDCProvider as a stateless,
//   compute-once-on-write provider (ADR-010 Decision B extended by
//   ADR-019).
//
//   float lane: NLEmbedding.vector(for:) returns [Double] with the
//   underlying sentence-embedding dimension. We cast to [Float] and
//   L2-normalise via the substrate primitive so the lane is live and
//   honest: real semantic coordinates, not a hash.
//
//   binary engram: FloatSimHash.project(vector:seed:) of the pooled
//   float vector — the same pattern every other provider uses.
//
// ## Sanctioned Swift-only divergence
//
//   NaturalLanguage is an Apple system framework. It is gated
//   `#if canImport(NaturalLanguage)` and confined to the Apple layer —
//   exactly the same pattern as the `.nlTagger` novel-token fallback
//   in FDCProvider (and in LocusKit's word-class tagger). Rust has no
//   counterpart; both ports remain conformant because the parity
//   baseline is the classical deterministic providers (bit-identical).
//   The NL lanes are present/absent per platform; recall fusion already
//   handles absent lanes correctly. This divergence is recorded in
//   ADR-019 (Apple NL Embedding Providers).
//
// ## Projection seed
//
//   NL_EMBEDDING_SEED = 0x4150_4E4C_454D_4231  ("APNLEMB1")
//   Distinct from all other provider seeds so that storage keys
//   (model_id partition in the vectors table) never collide.
//
// Model ID  = "apple-nlembedding-v1"
// Version   = "1.0.0"
//
// Rust port: none — sanctioned Swift-only divergence (see ADR-019).
// ADR-019 reference: Swift-only Apple NL embedding providers.

#if canImport(NaturalLanguage)
import NaturalLanguage
import Foundation
import CorpusKit
import EngramLib
import SubstrateKernel
import SubstrateML
import VectorKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FloatSimHash.project: SubstrateML (projection seed isolates buckets)
// FloatVecOps.l2Normalize: SubstrateKernel (canonical scalar impl)
// ─────────────────────────────────────────────────────────────────

// MARK: - Projection seed

/// FloatSimHash projection seed for NLEmbeddingProvider.
///
/// Encodes "APNLEMB1" in ASCII bytes. Must not match any other
/// provider's seed so NL-embedding engrams key to a separate storage
/// bucket and are never compared against RI, PPMI, FDC, or deterministic
/// engrams (per invariant I-4 of CORPUSKIT_SPEC).
public let nlEmbeddingProjectionSeed: UInt64 = 0x4150_4E4C_454D_4231

// MARK: - NLEmbeddingProvider

/// Apple NaturalLanguage sentence embedding provider.
///
/// Uses the OS-bundled `NLEmbedding.sentenceEmbedding(for:)` model.
/// No external model asset, no training step, no CoreML dependency:
/// the model ships with macOS 15+/iOS 18+ and is available immediately.
///
/// This is an item-local, stateless provider — the same text always
/// produces the same vector given the same OS model version. It does not
/// conform to `TrainableEmbeddingBasis` (there is no counts table or
/// retrain path). The binary engram lane is `FloatSimHash.project` of
/// the float vector; the float lane is live.
///
/// ## Graceful degradation
///
/// On a language where `NLEmbedding.sentenceEmbedding(for:)` returns nil
/// (the OS has no model for that language), `embedFloat` returns `[]` and
/// `embed` returns `.zero` — the standard absent-lane opt-out contract,
/// not an error.
///
/// ## Thread safety
///
/// `NLEmbeddingProvider` is `Sendable`. All methods are stateless; the
/// only stored state is the constant language tag and projection seed.
///
/// ## Sanctioned divergence
///
/// This provider is Swift-only (`#if canImport(NaturalLanguage)`).
/// See ADR-019 for the rationale; parity is preserved by the deterministic
/// providers.
///
/// The package minimum deployment target is macOS 26 / iOS 26, which is
/// above the NLEmbedding API floor (macOS 12 / iOS 15), so no @available
/// guard is needed here beyond the `#if canImport(NaturalLanguage)` gate.
public struct NLEmbeddingProvider: EmbeddingProvider, Sendable {

    // MARK: EmbeddingProvider required properties

    public let modelID: String
    public let modelVersion: String

    // MARK: Private

    /// FloatSimHash projection seed. Fixed to nlEmbeddingProjectionSeed;
    /// stored as an instance field so test code can verify seed isolation.
    private let projectionSeed: UInt64

    /// The NaturalLanguage language tag to look up an embedding model for.
    /// Defaults to English; callers may supply a different tag when they
    /// know the estate's primary language.
    private let language: NLLanguage

    // MARK: Initialiser

    /// Create an `NLEmbeddingProvider` for the given language.
    ///
    /// - Parameters:
    ///   - modelID: Storage key for this provider. Default: `"apple-nlembedding-v1"`.
    ///   - modelVersion: Version string stored with every vector for invalidation.
    ///     Default: `"1.0.0"`.
    ///   - language: The NaturalLanguage language tag the OS embedding model is
    ///     looked up under. Default: `.english`. On estates with non-English
    ///     content, pass the appropriate tag; when the OS has no model for the
    ///     language, `embedFloat` opts out (returns `[]`) rather than crashing.
    ///   - projectionSeed: FloatSimHash seed. Defaults to `nlEmbeddingProjectionSeed`
    ///     ("APNLEMB1"). Only override in tests that verify seed isolation.
    public init(
        modelID: String = "apple-nlembedding-v1",
        modelVersion: String = "1.0.0",
        language: NLLanguage = .english,
        projectionSeed: UInt64 = nlEmbeddingProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.language = language
        self.projectionSeed = projectionSeed
    }

    // MARK: EmbeddingProvider

    /// Produce the 256-bit Engram for `text`.
    ///
    /// Embeds via `NLEmbedding.sentenceEmbedding`, projects the resulting
    /// float vector through FloatSimHash. Returns `.zero` when the OS has no
    /// sentence-embedding model for the configured language or when `text` is empty.
    public func embed(_ text: String) async throws -> Engram {
        let v = floatVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the OS sentence-embedding float vector for `text`.
    ///
    /// Returns `[]` when:
    ///   - `text` is empty (no-query signal, not an error).
    ///   - The OS has no sentence-embedding model for the configured language
    ///     (`NLEmbedding.sentenceEmbedding(for:)` returns nil) — the absent-lane
    ///     opt-out contract; the corpus layer degrades gracefully.
    ///
    /// On success, the vector is L2-normalised via `FloatVecOps.l2Normalize`
    /// (the canonical substrate primitive) before being returned.
    public func embedFloat(_ text: String) async throws -> [Float] {
        floatVector(for: text)
    }

    /// Produce the Engram and the L2-normalised float vector from a SINGLE
    /// `NLEmbedding.vector(for:)` call.
    ///
    /// Avoids computing the embedding twice when a caller needs both outputs.
    /// Byte-identical to calling `embed(_:)` then `embedFloat(_:)` separately.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = floatVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the L2-normalised float vector for `text` using NLEmbedding.
    ///
    /// Returns `[]` on empty input or when the OS has no model for the
    /// configured language. This is the canonical opt-out path: the corpus
    /// layer maps `[]` to `FloatLaneOutcome.unavailableProviderOptOut`.
    private func floatVector(for text: String) -> [Float] {
        guard !text.isEmpty else { return [] }
        // Look up the OS-bundled sentence embedding model for the configured
        // language. Returns nil when the OS has no model — that is the graceful
        // degradation path (absent lane), not an error. The English model is
        // broadly available on macOS 12+/iOS 15+; other languages may not be.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return []
        }
        // NLEmbedding.vector(for:) returns nil when the text cannot be embedded
        // (e.g., the token falls outside the model's vocabulary or the text is
        // whitespace-only after normalization). Treat nil as an opt-out.
        guard let raw = embedding.vector(for: text) else {
            return []
        }
        // Cast Double → Float (NLEmbedding returns [Double]) then L2-normalise
        // via the canonical substrate scalar implementation. L2 normalisation
        // ensures the float lane's cosine similarity computation is on a unit
        // sphere — the same invariant every other provider enforces.
        let floats = raw.map { Float($0) }
        return FloatVecOps.l2Normalize(floats)
    }
}
#endif // canImport(NaturalLanguage)
