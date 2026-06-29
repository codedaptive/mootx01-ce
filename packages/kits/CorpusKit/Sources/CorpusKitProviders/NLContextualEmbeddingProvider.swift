// NLContextualEmbeddingProvider.swift
//
// Apple NaturalLanguage contextual (transformer) embedding provider.
//
// Uses `NLContextualEmbedding` — the on-device transformer model
// available on macOS 13+/iOS 16+. This model is MORE expensive than
// `NLEmbedding` (higher quality, larger asset) but requires a
// downloadable language asset that may not be present on first use.
//
// ## Design
//
//   item-local: the vector is a pure function of the input text,
//   computed once on write. No trainable basis, no counts, no shadow
//   swap machinery — same category as NLEmbeddingProvider.
//
//   asset availability: `NLContextualEmbedding` requires a language
//   asset that is downloaded on first use. The asset may be absent:
//   - when the device has never loaded it, or
//   - when the OS version doesn't support the requested language.
//   This provider treats an absent/unavailable asset as an ABSENT LANE
//   (embedFloat returns [], embed returns .zero) — never a crash or a
//   thrown error. The corpus layer degrades gracefully onto other lanes.
//   The decision to NOT download the asset proactively is deliberate:
//   a provider should never trigger a network fetch as a side effect of
//   an embed call. Asset management is the host app's responsibility.
//
//   float lane: NLContextualEmbedding produces per-token contextual
//   vectors. We mean-pool the per-token float arrays to obtain a single
//   sentence-level embedding and L2-normalise via the substrate primitive.
//   Mean pooling is the conventional strategy for transformer contextual
//   embeddings and is appropriate here because the model is not fine-tuned
//   for a specific pooling strategy.
//
//   binary engram: FloatSimHash.project(vector:seed:) of the pooled
//   float vector — the same pattern every other provider uses.
//
// ## Sanctioned Swift-only divergence
//
//   Same as NLEmbeddingProvider: NaturalLanguage is an Apple system
//   framework. Gated `#if canImport(NaturalLanguage)`. Rust has no
//   counterpart. Recorded in ADR-019.
//
// ## Projection seed
//
//   NL_CONTEXTUAL_SEED = 0x4150_4E4C_4354_5831  ("APNLCTX1")
//   Distinct from nlEmbeddingProjectionSeed and all other provider seeds
//   so that contextual-embedding engrams key to their own storage bucket.
//
// Model ID  = "apple-nlcontextual-v1"
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

/// FloatSimHash projection seed for NLContextualEmbeddingProvider.
///
/// Encodes "APNLCTX1" in ASCII bytes. Must not match any other provider's
/// seed — in particular, must differ from `nlEmbeddingProjectionSeed`
/// ("APNLEMB1") so contextual and sentence-embedding engrams key to
/// separate storage partitions (invariant I-4 of CORPUSKIT_SPEC).
public let nlContextualEmbeddingProjectionSeed: UInt64 = 0x4150_4E4C_4354_5831

// MARK: - NLContextualEmbeddingProvider

/// Apple NaturalLanguage contextual (transformer) embedding provider.
///
/// Uses `NLContextualEmbedding` — an on-device transformer model that
/// produces contextual per-token representations and then mean-pools them
/// to a sentence-level embedding. Higher quality than `NLEmbeddingProvider`
/// at the cost of a larger per-language downloadable asset.
///
/// ## Asset availability
///
/// `NLContextualEmbedding` may not be immediately available: the language
/// asset must be downloaded and the OS must support the language. This
/// provider NEVER blocks on a download and NEVER throws when the asset is
/// absent. Instead it returns `[]` / `.zero` — the standard absent-lane
/// opt-out that the corpus layer maps to `unavailableProviderOptOut`. The
/// host app can trigger asset prefetch via
/// `NLContextualEmbedding.requestAssets(for:completionHandler:)` before
/// constructing this provider; this provider does not do so itself.
///
/// ## Pooling
///
/// `NLContextualEmbedding.embeddingResult(for:language:)` returns per-token
/// float vectors. We mean-pool all token vectors to produce a single
/// sentence-level float array and L2-normalise via `FloatVecOps.l2Normalize`
/// (the canonical substrate primitive). Mean pooling is the conventional
/// choice for a transformer without a dedicated sentence-pooling head.
///
/// ## Thread safety
///
/// `NLContextualEmbeddingProvider` is `Sendable`. All stored fields are
/// constant after initialisation; all async work is side-effect-free
/// (no state mutation).
///
/// ## Sanctioned divergence
///
/// Swift-only (`#if canImport(NaturalLanguage)`). See ADR-019. The package
/// minimum deployment target is macOS 26 / iOS 26, which is above the
/// NLContextualEmbedding API floor (macOS 13 / iOS 16), so no @available
/// guard is needed beyond the `#if canImport(NaturalLanguage)` gate.
public struct NLContextualEmbeddingProvider: EmbeddingProvider, Sendable {

    // MARK: EmbeddingProvider required properties

    public let modelID: String
    public let modelVersion: String

    // MARK: Private

    /// FloatSimHash projection seed. Fixed to nlContextualEmbeddingProjectionSeed;
    /// stored as an instance field so tests can verify seed isolation.
    private let projectionSeed: UInt64

    /// The NaturalLanguage language tag for the contextual embedding asset.
    /// Defaults to English. When the OS has no asset for this language,
    /// embedFloat returns [] (graceful absent-lane opt-out).
    private let language: NLLanguage

    // MARK: Initialiser

    /// Create an `NLContextualEmbeddingProvider` for the given language.
    ///
    /// - Parameters:
    ///   - modelID: Storage key. Default: `"apple-nlcontextual-v1"`.
    ///   - modelVersion: Version string. Default: `"1.0.0"`.
    ///   - language: The language tag for the contextual embedding model.
    ///     Default: `.english`. When the asset for this language is absent
    ///     or unavailable, the provider opts out (returns `[]`) gracefully.
    ///   - projectionSeed: FloatSimHash seed. Defaults to
    ///     `nlContextualEmbeddingProjectionSeed` ("APNLCTX1"). Only override
    ///     in tests that verify seed isolation.
    public init(
        modelID: String = "apple-nlcontextual-v1",
        modelVersion: String = "1.0.0",
        language: NLLanguage = .english,
        projectionSeed: UInt64 = nlContextualEmbeddingProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.language = language
        self.projectionSeed = projectionSeed
    }

    // MARK: EmbeddingProvider

    /// Produce the 256-bit Engram for `text`.
    ///
    /// Mean-pools the contextual token vectors, projects through FloatSimHash.
    /// Returns `.zero` when the asset is unavailable or `text` is empty.
    public func embed(_ text: String) async throws -> Engram {
        let v = await contextualVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the mean-pooled contextual float vector for `text`.
    ///
    /// Returns `[]` when:
    ///   - `text` is empty.
    ///   - The contextual embedding asset is not available (never downloaded,
    ///     OS lacks support, or the embedding call fails for any other reason).
    ///
    /// All failure modes are collapsed to `[]` so the corpus layer applies
    /// the absent-lane opt-out path (`unavailableProviderOptOut`) rather than
    /// surfacing an error. This is intentional: asset absence is an expected
    /// operational state, not a bug.
    public func embedFloat(_ text: String) async throws -> [Float] {
        await contextualVector(for: text)
    }

    /// Produce the Engram and the mean-pooled float vector from a SINGLE
    /// `NLContextualEmbedding` call.
    ///
    /// Avoids running the embedding twice when a caller needs both outputs.
    /// Byte-identical to calling `embed(_:)` then `embedFloat(_:)` separately.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = await contextualVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the mean-pooled, L2-normalised contextual vector for `text`.
    ///
    /// Mean pooling: sum all per-token vectors element-wise, divide by token count.
    /// Then L2-normalise via `FloatVecOps.l2Normalize` (the canonical substrate
    /// scalar implementation). Returns `[]` on any failure (empty input,
    /// unavailable asset, embedding call failure, zero-dimension result).
    private func contextualVector(for text: String) async -> [Float] {
        guard !text.isEmpty else { return [] }

        // Look up the contextual embedding model for the configured language.
        // Returns nil when the OS has no support for the language — graceful
        // absent-lane opt-out.
        guard let contextual = NLContextualEmbedding(language: language) else {
            return []
        }

        // Verify the embedding asset is available WITHOUT triggering a download.
        // hasAvailableAssets is synchronous and free — it does not initiate a
        // network request. We never download proactively from inside embed calls;
        // asset management is the host app's responsibility.
        guard contextual.hasAvailableAssets else {
            return []
        }

        // Run the contextual embedding. This is the expensive path (transformer
        // inference). Failures (model errors, unexpected dimension) return nil.
        guard let result = try? contextual.embeddingResult(for: text, language: language) else {
            return []
        }

        // Collect per-token vectors via the token-enumeration closure.
        // `NLContextualEmbeddingResult.enumerateTokenVectors` visits every token
        // in order and yields its float vector. We accumulate them for mean pooling.
        var tokenVectors: [[Float]] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            // Cast [Double] → [Float] (NLContextualEmbedding uses Double).
            tokenVectors.append(vector.map { Float($0) })
            return true // continue enumeration
        }

        guard !tokenVectors.isEmpty else { return [] }

        let dim = tokenVectors[0].count
        guard dim > 0 else { return [] }

        // Mean pool: sum element-wise then divide by the number of tokens.
        // This is plain Swift floating-point on primitives — no new substrate
        // primitive is required (similar to PPMI's weight accumulation in
        // finalize()). The result is then delegated to the substrate for
        // L2 normalisation, which IS the conformance-gated primitive.
        var sum = [Float](repeating: 0, count: dim)
        for tokenVec in tokenVectors {
            // Guard consistent dimension across tokens (should always hold for
            // a given model version, but defensive check prevents an OOB write).
            guard tokenVec.count == dim else { continue }
            for d in 0..<dim {
                sum[d] += tokenVec[d]
            }
        }
        let count = Float(tokenVectors.count)
        let mean = sum.map { $0 / count }

        // L2-normalise via the canonical substrate scalar implementation.
        // FloatVecOps.l2Normalize is conformance-gated against the Rust port;
        // using it here guarantees output identical to any other provider that
        // normalises the same input float array.
        return FloatVecOps.l2Normalize(mean)
    }
}
#endif // canImport(NaturalLanguage)
