// EmbeddingTestHelpers.swift
//
// Shared float-embedding stubs for GeniusLocusKit tests. Each is a plain
// `EmbeddingProvider` a test hands to CorpusKit through a pass-through
// `EmbeddingModel` case (`.lsa(provider:)` / `.randomIndexing(provider:)`,
// both of which carry any provider and treat a non-`TrainableEmbeddingBasis`
// one as a stateless slot).
//
// All providers use `modelID` to identify the dense lane slot (the storage key is
// "dense:<modelID>"); tests that assert on lane names must use the matching ID.

import EngramLib
import Foundation
import SynapseKit

/// Deterministic 384-d float provider using Unicode-scalar-based cosine mixing.
///
/// Produces distinct, content-dependent vectors so the dense lane carries real
/// signal without requiring any trained model.
///
/// Both `embed()` and `embedFloat()` are live:
/// - `embedFloat()` returns the raw 384-d cosine-mix vector for float lane recall.
/// - `embed()` projects that vector through `FloatSimHash` (via the inner
///   `FloatSimHashEmbeddingProvider`) to produce a distinct Engram, so that
///   `corpus.embed()` —  which calls `embed()` — stores a discriminating
///   Hamming fingerprint rather than the all-zeros identity.
struct HashFloatProvider: EmbeddingProvider, @unchecked Sendable {

    /// Stable test seed ("HashTest" bytes). All tests that compare Hamming
    /// similarity depend on this seed being fixed — do NOT change it.
    private static let projectionSeed: UInt64 = 0x4861_7368_5465_7374

    /// Inner provider that owns the float→Engram projection path.
    private let inner: FloatSimHashEmbeddingProvider

    var modelID: String { inner.modelID }
    var modelVersion: String { inner.modelVersion }

    init(modelID: String = "test-hash-v1") {
        let id = modelID
        inner = FloatSimHashEmbeddingProvider(
            modelID: id,
            modelVersion: "1.0.0",
            projectionSeed: HashFloatProvider.projectionSeed,
            inference: { text in
                guard !text.isEmpty else { return [] }
                // Unicode-scalar cosine mixing: each scalar contributes a
                // sinusoidal wave to the output vector. Documents that share
                // scalars (characters) accumulate overlapping contributions,
                // making their float vectors — and the resulting Engrams —
                // more similar.
                var v = [Float](repeating: 0.0, count: 384)
                for scalar in text.unicodeScalars {
                    let tok = Int32(bitPattern: scalar.value)
                    let key = Float(((tok % 251) + 251) % 251 + 1)
                    for j in 0..<v.count {
                        v[j] += Foundation.cos(key * (Float(j) + 1.0) * 0.1)
                    }
                }
                return v
            }
        )
    }

    func embed(_ text: String) async throws -> Engram {
        // Delegate to the inner FloatSimHashEmbeddingProvider, which runs
        // the inference closure and then projects the float vector through
        // FloatSimHash to produce a content-dependent Engram.
        try await inner.embed(text)
    }

    func embedFloat(_ text: String) async throws -> [Float] {
        try await inner.embedFloat(text)
    }
}

/// FNV-1a 64-bit hash of a text's first whitespace-separated word.
private func firstWordHash(_ text: String) -> UInt64 {
    let first = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
    return first.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { acc, b in
        (acc ^ UInt64(b)) &* 1_099_511_628_211
    }
}

/// One-hot 384-d provider keyed on the FIRST WORD: the word's FNV-1a hash
/// picks the axis and a shared component (`v[0] += 0.5`) pulls every vector
/// toward every other, so a query ranks EVERY document and ranks the one
/// sharing its first word highest. `embed()` is the zero engram: these
/// fixtures steer the float lane alone.
struct FirstWordAxisProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    let modelVersion: String = "1.0.0"

    init(modelID: String) { self.modelID = modelID }

    func embed(_ text: String) async throws -> Engram { Engram.zero }

    func embedFloat(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: 384)
        v[Int(firstWordHash(text) % 384)] = 1.0
        v[0] += 0.5
        return v
    }
}

/// Two-axis 384-d provider keyed on the LEADING CODE POINT: an odd leading
/// scalar ("alpha…") routes to axis 1, an even one ("zeta…") to a distant
/// axis, so only a document that leads like the query aligns with it.
struct TwoAxisProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    let modelVersion: String = "1.0.0"

    init(modelID: String) { self.modelID = modelID }

    func embed(_ text: String) async throws -> Engram { Engram.zero }

    func embedFloat(_ text: String) async throws -> [Float] {
        let lead = text.unicodeScalars.first?.value ?? 0
        var v = [Float](repeating: 0, count: 384)
        v[lead % 2 == 1 ? 1 : 300] = 1.0
        return v
    }
}

/// Monotonic-angle 384-d provider keyed on WORD COUNT: the direction is
/// `[cos θ, sin θ, 0…]` with `θ = words × 0.018 rad`, so cosine-to-query
/// falls monotonically as a document grows and "most dissimilar" has no ties.
/// 0.018 rad/word sweeps roughly 0…82° over 80 words.
struct WordCountAngleProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    let modelVersion: String = "1.0.0"

    init(modelID: String) { self.modelID = modelID }

    func embed(_ text: String) async throws -> Engram { Engram.zero }

    func embedFloat(_ text: String) async throws -> [Float] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).count
        let theta = Float(words) * 0.018
        var v = [Float](repeating: 0, count: 384)
        v[0] = Foundation.cos(theta)
        v[1] = Foundation.sin(theta)
        return v
    }
}
