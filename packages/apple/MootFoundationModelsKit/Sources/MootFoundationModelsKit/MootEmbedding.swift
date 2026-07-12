import Foundation
import NaturalLanguage

// MARK: - MootEmbeddingProvider  (Tier 3 — the replaceable embedding lane)
//
// The Apple-side seam for on-device text embeddings. MOOT's recall envelope
// is BM25-strong / vector-weak today (the v1.1 embedding encoder is planned
// engine work); this protocol is where an Apple-platform embedder plugs in
// WITHOUT forking MOOT storage or creating Apple-only classification truth:
// providers produce vectors, callers own what (if anything) is persisted,
// and the engine's Swift/Rust parity surface is untouched (ADR-005).
//
// Two adapters were scoped from the WWDC26 study corpus:
//   - ContextualEmbeddingProvider (below): NLContextualEmbedding — shipping
//     API, ANE-accelerated, multilingual, assets download on demand.
//   - A CoreAI `.aimodel` provider (wwdc2026-324/325/326): CoreAI is a
//     bring-your-own-model deployment layer (AIModelCache, coreai-build
//     AOT, Background Assets). That adapter is NOT written until a real
//     embedding model asset exists to load — a stub returning fabricated
//     vectors would violate the no-pretend-no-ops rule. It conforms here
//     when it lands.

public protocol MootEmbeddingProvider: Sendable {
    /// Stable identifier for provenance (which model produced a vector).
    var identifier: String { get }
    /// The dimensionality every returned vector has.
    var dimension: Int { get }
    /// Embed each text into one vector. Implementations must throw on
    /// unavailable models/assets — never fabricate or zero-fill.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum MootEmbeddingError: Error, CustomStringConvertible {
    /// The OS embedding model exists but its assets are not on this device.
    /// Remedy: NLContextualEmbedding.requestAssets (attended — it downloads).
    case assetsUnavailable(String)
    /// No embedding model exists for the requested language/script.
    case modelUnavailable(String)

    public var description: String {
        switch self {
        case .assetsUnavailable(let what):
            return "Embedding assets for \(what) are not on this device; request them before embedding."
        case .modelUnavailable(let what):
            return "No contextual embedding model exists for \(what)."
        }
    }
}

// MARK: - ContextualEmbeddingProvider

/// NLContextualEmbedding-backed provider. Sentence vectors are the mean of
/// the model's token vectors (standard pooling for BERT-style contextual
/// models). An actor because NLContextualEmbedding is not Sendable and the
/// model should load once, not per call.
public actor ContextualEmbeddingProvider: MootEmbeddingProvider {

    private let embedding: NLContextualEmbedding
    private let language: NLLanguage
    private var loaded = false

    public nonisolated let identifier: String
    public nonisolated let dimension: Int

    /// Fails explicitly when no model exists for the language or its assets
    /// are not downloaded — the caller decides whether to request assets
    /// (an attended, user-visible download), per the consent posture.
    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLContextualEmbedding(language: language) else {
            throw MootEmbeddingError.modelUnavailable(language.rawValue)
        }
        guard embedding.hasAvailableAssets else {
            throw MootEmbeddingError.assetsUnavailable(language.rawValue)
        }
        self.embedding = embedding
        self.language = language
        self.identifier = "nl-contextual/\(embedding.modelIdentifier)"
        self.dimension = embedding.dimension
    }

    /// Whether the default (English) model's assets are on this device —
    /// the test gate and a cheap capability probe for UI.
    public static func assetsAreAvailable(language: NLLanguage = .english) -> Bool {
        NLContextualEmbedding(language: language)?.hasAvailableAssets == true
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        if !loaded {
            try embedding.load()
            loaded = true
        }
        return try texts.map { text in
            let result = try embedding.embeddingResult(for: text, language: language)
            var tokenVectors: [[Float]] = []
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                tokenVectors.append(vector.map(Float.init))
                return true
            }
            return Self.meanPool(tokenVectors)
        }
    }

    /// Component-wise mean of token vectors; empty in → empty out (an empty
    /// string has no tokens — the caller sees an empty vector, not a guess).
    static func meanPool(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for (i, component) in vector.enumerated() where i < sum.count {
                sum[i] += component
            }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }
}
