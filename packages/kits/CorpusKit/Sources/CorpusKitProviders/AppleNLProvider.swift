#if APPLE_ENCODERS
// Apple encoder provider — compiled only when the AppleEncoders trait is on.
// Retained in case Apple improves the NaturalLanguage framework, or for a device class
// that cannot host a Core AI encoder.
// Off by default; held for v1.2 iOS and Apple cloud compute. See Package.swift.
// AppleNLProvider.swift
//
// Apple NaturalLanguage sentence embedding provider — UNNORMALIZED float lane.
//
// Uses `NLEmbedding.sentenceEmbedding(for:)` — the same OS-bundled model as
// NLEmbeddingProvider — but deliberately does NOT L2-normalise the output
// vector. The raw float magnitude is preserved so that L2 distance and dot-
// product comparisons are geometrically meaningful. This is the provider that
// unlocks the l2/dot float-NN metric pair: those metrics are null-by-
// construction when all providers normalise to the unit sphere (cosine = dot
// for unit vectors), but become distinct and useful when the embedding
// magnitude carries information.
//
// ## Relationship to NLEmbeddingProvider
//
//   `NLEmbeddingProvider` (model_id "apple-nlembedding-v1") L2-normalises
//   its output so that cosine similarity is the authoritative metric. It and
//   `AppleNLProvider` ("apple-nl-v1") call the SAME OS embedding model but
//   differ in the post-inference normalisation step:
//
//     NLEmbeddingProvider  →  L2-normalised  →  cosine-only metric
//     AppleNLProvider      →  raw (unnorm.)  →  l2, dot, cosine all valid
//
//   They MUST NOT share a modelID. They key to distinct storage buckets in
//   the vectors table (per invariant I-4 of CORPUSKIT_SPEC). Their projection
//   seeds must also differ so their binary engrams never collide.
//
// ## Binary engram (FloatSimHash)
//
//   `FloatSimHash.project(vector:seed:)` assigns each dimension a random
//   hyperplane direction and sets a bit based on the sign of the dot product.
//   The sign of a dot product is invariant under positive scaling of the
//   vector — L2 normalisation does not change it. Therefore the binary engram
//   from `AppleNLProvider` is IDENTICAL to the one from `NLEmbeddingProvider`
//   for the same text (same OS model, same direction, same sign). The ONLY
//   reason their engrams differ at all is the distinct projection seed, which
//   maps to a different set of random hyperplanes.
//
// ## Projection seed
//
//   APPLE_NL_RAW_SEED = 0x4150_4E4C_5241_5731  ("APNLRAW1")
//   Distinct from nlEmbeddingProjectionSeed ("APNLEMB1") and
//   nlContextualEmbeddingProjectionSeed ("APNLCTX1") so this provider's
//   binary engrams key to their own storage partition (invariant I-4).
//
// ## Determinism
//
//   `NLEmbedding` is deterministic within a given OS + model version: the
//   same input text yields the same float vector in the same OS build. The
//   modelVersion field ("1.0.0") does NOT encode the underlying OS model
//   version because `NLEmbedding` does not expose it. Vector invalidation
//   on an OS upgrade that changed the underlying model is a known limitation;
//   production users would need to trigger a reindex. This is consistent with
//   how other on-device model providers handle weight updates.
//
// ## Absent lane
//
//   On a language where `NLEmbedding.sentenceEmbedding(for:)` returns nil
//   (the OS has no model for that language), `embedFloat` returns `[]` and
//   `embed` returns `.zero` — the standard absent-lane opt-out contract.
//
// ## Sanctioned Swift-only divergence
//
//   NaturalLanguage is an Apple system framework. Gated
//   `#if canImport(NaturalLanguage)`. Rust has no counterpart; parity is
//   preserved by the deterministic providers (the classical baseline). This
//   divergence is consistent with NLEmbeddingProvider and recorded in the
//   opt-in Apple embedding providers section of the kit documentation.
//
// Model ID  = "apple-nl-v1"
// Version   = "1.0.0"
//
// Rust port: none — sanctioned Swift-only divergence.

#if canImport(NaturalLanguage)
import NaturalLanguage
import Foundation
import CorpusKit
import EngramLib
import SubstrateML
import SynapseKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// FloatSimHash.project: SubstrateML (projection seed isolates buckets)
// FloatVecOps.l2Normalize: SubstrateKernel — deliberately NOT called
// here; this provider preserves raw magnitudes for l2/dot metrics.
// ─────────────────────────────────────────────────────────────────

// MARK: - Projection seed

/// FloatSimHash projection seed for AppleNLProvider.
///
/// Encodes "APNLRAW1" in ASCII bytes: 0x41='A', 0x50='P', 0x4E='N',
/// 0x4C='L', 0x52='R', 0x41='A', 0x57='W', 0x31='1'.
/// Must differ from `nlEmbeddingProjectionSeed` ("APNLEMB1") and
/// `nlContextualEmbeddingProjectionSeed` ("APNLCTX1") so this provider's
/// binary engrams partition to their own storage bucket (invariant I-4).
public let appleNLProviderProjectionSeed: UInt64 = 0x4150_4E4C_5241_5731

// MARK: - AppleNLProvider

/// Apple NaturalLanguage sentence embedding provider with UNNORMALIZED float output.
///
/// Uses the OS-bundled `NLEmbedding.sentenceEmbedding(for:)` model to produce
/// float vectors. Unlike `NLEmbeddingProvider`, this provider does NOT
/// L2-normalise the output. The raw float magnitude is preserved, making
/// L2 distance and dot-product comparisons geometrically valid alongside
/// cosine similarity.
///
/// ## Why unnormalized?
///
/// When all embedding providers normalise to the unit sphere, the cosine
/// similarity between two vectors equals their dot product, and the L2
/// distance is a monotone function of the cosine — the three metrics carry
/// identical rank information. By preserving the raw magnitude this provider
/// makes the three metrics genuinely distinct, enabling the float-NN l2 and
/// dot lanes to contribute independent recall signal.
///
/// ## Graceful degradation
///
/// On a language where `NLEmbedding.sentenceEmbedding(for:)` returns nil
/// (the OS has no model for that language), `embedFloat` returns `[]` and
/// `embed` returns `.zero` — the standard absent-lane opt-out contract.
///
/// ## Determinism
///
/// Deterministic within a given OS + model version. The `modelVersion` field
/// ("1.0.0") does not encode the underlying OS model version because
/// `NLEmbedding` does not expose it. Vectors should be considered stale
/// after a major OS upgrade if the underlying model changed.
///
/// ## Thread safety
///
/// `AppleNLProvider` is `Sendable`. All methods are stateless; the only stored
/// state is the constant language tag and projection seed.
///
/// ## Sanctioned divergence
///
/// Swift-only (`#if canImport(NaturalLanguage)`). Parity is preserved by the
/// deterministic providers.
///
/// The package minimum deployment target is macOS 26 / iOS 26, above the
/// NLEmbedding API floor (macOS 12 / iOS 15), so no @available guard is
/// needed beyond the `#if canImport(NaturalLanguage)` gate.
public struct AppleNLProvider: EmbeddingProvider, Sendable {

    // MARK: EmbeddingProvider required properties

    public let modelID: String
    public let modelVersion: String

    // MARK: Private

    /// FloatSimHash projection seed. Fixed to appleNLProviderProjectionSeed;
    /// stored as an instance field so tests can verify seed isolation.
    private let projectionSeed: UInt64

    /// The NaturalLanguage language tag to look up an embedding model for.
    /// Defaults to English; callers may supply a different tag when they
    /// know the estate's primary language.
    private let language: NLLanguage

    // MARK: Initialiser

    /// Create an `AppleNLProvider` for the given language.
    ///
    /// - Parameters:
    ///   - modelID: Storage key for this provider. Default: `"apple-nl-v1"`.
    ///   - modelVersion: Version string stored with every vector for
    ///     invalidation. Default: `"1.0.0"`.
    ///   - language: The NaturalLanguage language tag the OS embedding model
    ///     is looked up under. Default: `.english`. On estates with non-English
    ///     content, pass the appropriate tag; when the OS has no model for the
    ///     language, `embedFloat` opts out (returns `[]`) rather than crashing.
    ///   - projectionSeed: FloatSimHash seed. Defaults to
    ///     `appleNLProviderProjectionSeed` ("APNLRAW1"). Only override in tests
    ///     that verify seed isolation.
    public init(
        modelID: String = "apple-nl-v1",
        modelVersion: String = "1.0.0",
        language: NLLanguage = .english,
        projectionSeed: UInt64 = appleNLProviderProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.language = language
        self.projectionSeed = projectionSeed
    }

    // MARK: EmbeddingProvider

    /// Produce the 256-bit Engram for `text`.
    ///
    /// Projects the RAW (unnormalized) float vector through FloatSimHash.
    /// Returns `.zero` when the OS has no sentence-embedding model for the
    /// configured language or when `text` is empty.
    ///
    /// Note: the binary engram is direction-based (sign of dot products with
    /// random hyperplanes) and therefore invariant under positive scaling.
    /// The engram is structurally identical to what `NLEmbeddingProvider`
    /// would produce for the same text with the same OS model, EXCEPT that
    /// the projection seeds differ — this provider uses
    /// `appleNLProviderProjectionSeed` ("APNLRAW1"), so engrams key to a
    /// distinct storage partition (invariant I-4 of CORPUSKIT_SPEC).
    public func embed(_ text: String) async throws -> Engram {
        let v = rawFloatVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the RAW (unnormalized) OS sentence-embedding float vector for `text`.
    ///
    /// This is the key distinction from `NLEmbeddingProvider.embedFloat`: this
    /// method does NOT call `FloatVecOps.l2Normalize`. The vector's magnitude
    /// reflects the underlying `NLEmbedding` model output.
    ///
    /// Returns `[]` when:
    ///   - `text` is empty (no-query signal, not an error).
    ///   - The OS has no sentence-embedding model for the configured language
    ///     — the absent-lane opt-out contract.
    ///
    /// The caller can verify non-normalisation by computing the L2 magnitude:
    ///   `sqrt(floats.reduce(0) { $0 + $1 * $1 })` will differ from 1.0 for
    ///   non-trivial text on a working OS model.
    public func embedFloat(_ text: String) async throws -> [Float] {
        rawFloatVector(for: text)
    }

    /// Produce the Engram and the RAW float vector from a SINGLE
    /// `NLEmbedding.vector(for:)` call.
    ///
    /// Avoids computing the embedding twice when a caller needs both outputs.
    /// Byte-identical to calling `embed(_:)` then `embedFloat(_:)` separately.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = rawFloatVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the RAW (unnormalized) float vector for `text` using NLEmbedding.
    ///
    /// Returns `[]` on empty input or when the OS has no model for the
    /// configured language. This is the canonical opt-out path. The
    /// deliberate absence of `FloatVecOps.l2Normalize` is the core design
    /// decision: preserving magnitude enables l2 and dot-product metrics.
    private func rawFloatVector(for text: String) -> [Float] {
        guard !text.isEmpty else { return [] }
        // Look up the OS-bundled sentence embedding model for the configured
        // language. Returns nil when the OS has no model — graceful absent-lane
        // opt-out, not an error. The English model is broadly available on
        // macOS 12+/iOS 15+; other languages may not be.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return []
        }
        // NLEmbedding.vector(for:) returns nil when the text cannot be embedded.
        // Treat nil as an opt-out (same contract as NLEmbeddingProvider).
        guard let raw = embedding.vector(for: text) else {
            return []
        }
        // Cast Double → Float (NLEmbedding returns [Double]).
        // Do NOT call FloatVecOps.l2Normalize here — preserving the raw
        // magnitude is the explicit design goal of this provider. See file
        // header for the rationale.
        return raw.map { Float($0) }
    }
}
#endif // canImport(NaturalLanguage)

#endif // APPLE_ENCODERS
