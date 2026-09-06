#if APPLE_ENCODERS
// Apple encoder provider — compiled only when the AppleEncoders trait is on.
// Off by default; held for v1.2 iOS and Apple cloud compute. See Package.swift.
// NeuralEmbedProvider.swift
//
// Engine-neutral neural embedding provider — the Swift twin of the Rust
// `tools/neural-embed` backend (RENAME-EMBED #72).
//
// Both ports answer to the SAME engine-neutral provider id
// ("neural-embed-v1") on the provision surface; the inference machinery
// underneath is an invisible per-port backend detail:
//
//     Rust  → tools/neural-embed (token embeddings, attention-masked
//             mean pooling; standalone tool crate, subprocess protocol)
//     Swift → this file (NLTagger word tokenization + NLEmbedding
//             word vectors, mean pooling; Apple NaturalLanguage
//             framework, in-process)
//
// ## Shape: NLTagger tokens → NLEmbedding word vectors → mean pool
//
//   The Rust backend mean-pools per-token embeddings. This twin mirrors
//   that shape with Apple's frameworks: `NLTagger` (.tokenType scheme)
//   enumerates word tokens; `NLEmbedding.wordEmbedding(for:)` supplies a
//   per-word vector; the provider mean-pools the vectors of every token
//   the OS lexicon covers. Tokens without a vector (numbers, rare words,
//   punctuation runs) contribute nothing — the divisor is the count of
//   covered tokens, mirroring the attention-mask divisor on the Rust side.
//
// ## UNNORMALIZED
//
//   Like AppleNLProvider (and like the Rust backend's default), the
//   output preserves raw magnitude — no L2 normalization — so l2/dot
//   metrics stay geometrically meaningful. FloatSimHash scale-invariance
//   partitions binary engrams regardless.
//
// ## Selection policy — OFF by default
//
//   This provider is NEVER part of the default ensemble. It joins the
//   ensemble only when an estate's `embedding_provider` manifest key is
//   provisioned to "neural-embed-v1" (see
//   `EstateLifecycle.applyProvisionedEmbeddingProvider`), the same
//   opt-in path as "apple-nl-v1". The benchmark default embedding path
//   (deterministic distributional providers) is untouched.
//
// ## Projection seed
//
//   NEURAL_EMBED_SEED = 0x4E45_5545_4D42_4431  ("NEUEMBD1")
//   Distinct from every other provider seed so binary engrams key to
//   their own storage partition (invariant I-4 of CORPUSKIT_SPEC).
//
// ## Determinism / absent lane
//
//   Deterministic within a given OS + model version (NLEmbedding word
//   vectors are fixed OS assets). When the OS has no word-embedding
//   model for the configured language, or no token has a vector,
//   `embedFloat` returns `[]` and `embed` returns `.zero` — the
//   standard absent-lane opt-out contract.
//
// Model ID  = "neural-embed-v1"
// Version   = "1.0.0"
//
// Rust twin: tools/neural-embed (PROVIDER_ID, resolve(model_id:dir:)).
// The two backends produce DIFFERENT vector spaces (different models,
// different dimensions); the shared id names the neutral surface, and
// cross-port vectors are never compared (vectors are per-estate,
// per-port artifacts tagged by modelVersion).

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
// FloatVecOps.l2Normalize: deliberately NOT called — raw magnitudes
// are preserved for l2/dot metrics (same contract as AppleNLProvider).
// ─────────────────────────────────────────────────────────────────

// MARK: - Projection seed

/// FloatSimHash projection seed for NeuralEmbedProvider.
///
/// Encodes "NEUEMBD1" in ASCII bytes: 0x4E='N', 0x45='E', 0x55='U',
/// 0x45='E', 0x4D='M', 0x42='B', 0x44='D', 0x31='1'. Must differ from
/// every other provider projection seed so this provider's binary
/// engrams partition to their own storage bucket (invariant I-4).
public let neuralEmbedProjectionSeed: UInt64 = 0x4E45_5545_4D42_4431

// MARK: - NeuralEmbedProvider

/// Engine-neutral neural embedding provider: NLTagger word tokens
/// mean-pooled over NLEmbedding word vectors, UNNORMALIZED output.
///
/// The Swift twin of the Rust `tools/neural-embed` backend — both ports
/// resolve the provider id `"neural-embed-v1"` on the provision surface.
/// See the file header for the twin shape, the OFF-by-default selection
/// policy, and the absent-lane contract.
///
/// `NeuralEmbedProvider` is `Sendable`: all methods are stateless; the
/// only stored state is constants (`NLTagger`/`NLEmbedding` instances
/// are created per call, never stored).
public struct NeuralEmbedProvider: EmbeddingProvider, Sendable {

    // MARK: EmbeddingProvider required properties

    public let modelID: String
    public let modelVersion: String

    // MARK: Private

    /// FloatSimHash projection seed. Fixed to neuralEmbedProjectionSeed;
    /// stored as an instance field so tests can verify seed isolation.
    private let projectionSeed: UInt64

    /// The NaturalLanguage language tag the OS word-embedding model is
    /// looked up under.
    private let language: NLLanguage

    // MARK: Initialiser

    /// Create a `NeuralEmbedProvider` for the given language.
    ///
    /// - Parameters:
    ///   - modelID: Storage key for this provider. Default: `"neural-embed-v1"`
    ///     — the engine-neutral id shared with the Rust twin.
    ///   - modelVersion: Version string stored with every vector for
    ///     invalidation. Default: `"1.0.0"`.
    ///   - language: Language tag for `NLEmbedding.wordEmbedding(for:)`.
    ///     Default: `.english`. When the OS has no word-embedding model for
    ///     the language, `embedFloat` opts out (returns `[]`).
    ///   - projectionSeed: FloatSimHash seed. Defaults to
    ///     `neuralEmbedProjectionSeed` ("NEUEMBD1"). Only override in tests
    ///     that verify seed isolation.
    public init(
        modelID: String = "neural-embed-v1",
        modelVersion: String = "1.0.0",
        language: NLLanguage = .english,
        projectionSeed: UInt64 = neuralEmbedProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.language = language
        self.projectionSeed = projectionSeed
    }

    // MARK: EmbeddingProvider

    /// Produce the 256-bit Engram for `text`.
    ///
    /// Projects the RAW (unnormalized) mean-pooled float vector through
    /// FloatSimHash. Returns `.zero` when the OS has no word-embedding
    /// model for the configured language, when no token has a vector, or
    /// when `text` is empty (cross-provider empty-string contract).
    public func embed(_ text: String) async throws -> Engram {
        let v = rawFloatVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the RAW (unnormalized) mean-pooled word-vector embedding for
    /// `text`.
    ///
    /// Dimension equals the OS word-embedding model's dimension for the
    /// configured language (`NLEmbedding.wordEmbedding(for:)?.dimension`).
    ///
    /// Returns `[]` when:
    ///   - `text` is empty (no-query signal, not an error).
    ///   - The OS has no word-embedding model for the configured language.
    ///   - No token of `text` is covered by the OS lexicon.
    /// All three are the absent-lane opt-out contract, not errors.
    public func embedFloat(_ text: String) async throws -> [Float] {
        rawFloatVector(for: text)
    }

    /// Produce the Engram and the RAW float vector from a SINGLE pooling
    /// pass. Byte-identical to calling `embed(_:)` then `embedFloat(_:)`.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = rawFloatVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Tokenize with NLTagger, look up each word token's NLEmbedding
    /// vector, and mean-pool the covered tokens. UNNORMALIZED by design.
    ///
    /// The divisor is the count of tokens that HAVE a vector — mirroring
    /// the Rust backend's attention-mask divisor (real-token count), so
    /// uncovered tokens dilute nothing.
    private func rawFloatVector(for text: String) -> [Float] {
        guard !text.isEmpty else { return [] }
        // Word-level OS embedding model. nil when the OS carries no model
        // for the language — graceful absent-lane opt-out, not an error.
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else {
            return []
        }
        let dimension = embedding.dimension

        // NLTagger with the .tokenType scheme enumerates word units. The
        // tagger is created per call: NLTagger is not Sendable and this
        // provider must stay stateless.
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text

        // Mean-pool accumulator over covered tokens. Double accumulation
        // avoids Float summation drift on long texts; the final divide
        // casts back to Float once per dimension.
        var sum = [Double](repeating: 0, count: dimension)
        var covered = 0
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .tokenType,
            options: [.omitWhitespace, .omitPunctuation]
        ) { _, range in
            // NLEmbedding lexicon lookup is case-sensitive toward lowercase
            // entries; lowercasing maximizes coverage deterministically.
            let token = String(text[range]).lowercased()
            if let vector = embedding.vector(for: token) {
                for i in 0..<dimension {
                    sum[i] += vector[i]
                }
                covered += 1
            }
            return true
        }

        // No covered token → absent-lane opt-out (same contract as an
        // absent OS model). A zero vector would poison the FloatSimHash
        // projection with a fixed all-sign pattern; [] keeps the lane dark.
        guard covered > 0 else { return [] }
        let divisor = Double(covered)
        return sum.map { Float($0 / divisor) }
    }
}
#endif // canImport(NaturalLanguage)

#endif // APPLE_ENCODERS
