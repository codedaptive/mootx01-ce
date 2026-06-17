// RandomIndexingProvider.swift
//
// Random Indexing distributional-semantics embedding provider.
//
// Implements the *context-accumulation* (distributional) form of RI:
//   1. Each term gets a sparse ternary index vector in R^D.
//   2. A term's context vector is the sum of index vectors of
//      co-occurring terms within a sliding window over a corpus.
//   3. A document/query embedding is the L2-normalised sum of its
//      terms' context vectors.
//
// This is a GENUINE distributional method — "car" and "vehicle"
// share similar context vectors when they co-occur with the same
// neighbours ("drive", "road", "engine"). It captures co-occurrence
// meaning, not surface form, satisfying ADR-010 D-1's honesty
// requirement: the dense lane must not lie about what it computes.
//
// The provider conforms to VectorKit.EmbeddingProvider:
//   embedFloat(_:)  → the D-dimensional normalised context vector
//   embed(_:)       → FloatSimHash.project of that vector (Engram)
//
// Both operations are honest: `embedFloat` returns real RI coordinates,
// `embed` projects them to the 256-bit binary Engram through the
// substrate-canonical SimHash (per the EmbeddingProvider protocol's
// "providers that run a real computation override embedFloat" contract).
//
// ## Constants (documented, cross-port identical)
//
//   D        = 2048   Dimensionality of index/context vectors.
//   K        = 10     Nonzero positions per index vector (sparse ternary).
//   WINDOW   = 4      Co-occurrence window radius (±4 terms).
//
// ## Index vector generation (precise PRNG call sequence)
//
// For term T (lowercased), seed = FNV.hash64(T).
// rng = SplitMix64(seed).
// Emit exactly 2*K PRNG draws in interleaved (position, sign) pairs:
//   for i in 0..<K:
//     pos  = rng.next() % D      → position in [0, D)
//     sign = (rng.next() & 1) == 1 ? +1.0 : -1.0
//   write (pos, sign) into the dense vector; if pos collides the
//   last sign wins. Total draws: 2*K = 20. No platform RNG; no
//   rejection loop; call count is constant so cross-port PRNG
//   sequences are always identical.
//
// ## Projection seed
//
//   RI_PROJECTION_SEED = 0x5249_5F56_315F_4D58  ("RI_V1_MX")
//   Model ID = "random-indexing-v1",  version = "1.0.0"
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/random_indexing.rs
//
// ADR-010 reference: Decision B, signal #2 of the honest fusion.

import Foundation
import CorpusKit
import EngramLib
import SubstrateTypes
// SubstrateKernel: FloatVecOps.l2Normalize is the canonical scalar
// float-vector normalisation. Using the substrate primitive guarantees
// bit-identity with the Rust port and with all other providers that
// need L2 normalisation.
import SubstrateKernel
import VectorKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, float-vector ops (L2 norm,
// L2 normalise, dot, cosine), or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateML

// MARK: - Constants
//
// All constants are public so the test suite and cross-port conformance
// tests can reference them by name. The Rust port mirrors these constants
// in random_indexing.rs with the same names and values.

/// Dimensionality of every index vector and context vector.
/// 2048 gives a good accuracy/memory trade-off for a resident
/// estate (2048 × 4 bytes = 8 KB per term in the vocab table).
public let riDimension: Int = 2048

/// Number of nonzero ternary (±1) entries in each term's index vector.
/// 10 out of 2048 ≈ 0.5 % density; empirically sufficient for RI.
public let riNonzeros: Int = 10

/// Co-occurrence window radius: ±4 terms on each side of the target.
/// Context vectors accumulate index vectors of all terms within this
/// distance in a training document.
public let riWindow: Int = 4

/// FloatSimHash projection seed for Random Indexing. Encodes "RI_V1_MX"
/// in ASCII. Must not drift from the Rust constant RI_PROJECTION_SEED.
public let riProjectionSeed: UInt64 = 0x5249_5F56_315F_4D58

// MARK: - Index vector generation

/// Generate the sparse ternary index vector for a single term.
///
/// The index vector is deterministic: identical output for the same
/// term across all runs, all processes, and both language ports.
///
/// Algorithm:
///  1. seed  = FNV.hash64(term.lowercased())
///  2. rng   = SplitMix64(seed)
///  3. For i in 0..<K: pos = next() % D, sign = (next() & 1) == 1 ? +1 : -1
///     Write into the D-dimensional float vector (collision = last sign wins).
///
/// The 2K draw sequence is fixed and MUST be identical in the Rust port.
/// Using modulo for positions introduces a small bias for non-power-of-two D,
/// but since D=2048=2^11, modulo is exact (no bias: D divides 2^64 cleanly
/// because D is itself a power of two; every position is equally probable).
public func riIndexVector(term: String) -> [Float] {
    let seed = FNV.hash64(term.lowercased())
    var rng = SplitMix64(seed: seed)
    var vec = [Float](repeating: 0, count: riDimension)
    for _ in 0..<riNonzeros {
        // Draw 1: position in [0, D). D=2048=2^11 so % is exact.
        let pos = Int(rng.next() % UInt64(riDimension))
        // Draw 2: sign. Low bit of PRNG output, same rule in Rust.
        let sign: Float = (rng.next() & 1) == 1 ? 1.0 : -1.0
        // Collision: last sign wins (deterministic, no rejection loop
        // needed, call count stays exactly 2*K = 20 per term).
        vec[pos] = sign
    }
    return vec
}

// MARK: - RandomIndexingProvider

/// Random Indexing distributional-semantics embedding provider.
///
/// An instance holds a trained vocabulary map: term → context vector.
/// The vocabulary is built by calling `train(corpus:tokenizer:)` one
/// or more times before embedding. An untrained provider returns the
/// zero vector for any term not in the vocabulary (which projects to
/// Engram.zero through FloatSimHash — the same honest zero as a no-
/// context signal, not a spurious match).
///
/// ## Thread safety
///
/// `RandomIndexingProvider` is `Sendable`. The vocab table is built
/// once during training and then read-only during inference. Training
/// is not concurrency-safe; callers must finish all `train` calls
/// before concurrent `embed` calls.
///
/// ## Conformance
///
/// Conforms to `VectorKit.EmbeddingProvider`. modelID = "random-indexing-v1",
/// modelVersion = "1.0.0". Projection seed = `riProjectionSeed`.
///
/// ADR-010 Decision B, signal #2 — the first honest distributional
/// provider in the dense recall lane.
public final class RandomIndexingProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// FloatSimHash projection seed. Fixed to riProjectionSeed; stored
    /// for cross-provider seed isolation per spec I-4.
    private let projectionSeed: UInt64

    /// Trained context vectors, keyed by lowercased term.
    /// Read-only after training is complete.
    private var vocab: [String: [Float]]

    // MARK: Initialiser

    public init(
        modelID: String = "random-indexing-v1",
        modelVersion: String = "1.0.0",
        projectionSeed: UInt64 = riProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
        self.vocab = [:]
    }

    // MARK: Training

    /// Train on a corpus: accumulate co-occurrence context vectors.
    ///
    /// For each term at position i in `terms`, add the index vector of
    /// each neighbour within [i−window, i+window] to the target term's
    /// context vector. Training is additive — multiple `train` calls
    /// extend the same vocabulary, enabling streaming updates over a
    /// growing estate.
    ///
    /// - Parameters:
    ///   - terms: Lowercased, tokenized term sequence for one document.
    ///   - window: Co-occurrence window radius (default: riWindow = 4).
    ///
    /// - Note: Pass `now` at the call site; this method never calls
    ///   Date() (determinism invariant).
    public func train(terms: [String], window: Int = riWindow) {
        for (i, target) in terms.enumerated() {
            // Context: every term within ±window positions, excluding self.
            let lo = max(0, i - window)
            let hi = min(terms.count - 1, i + window)
            for j in lo...hi where j != i {
                let neighbourIndex = riIndexVector(term: terms[j])
                // Accumulate into the target term's context vector.
                if vocab[target] == nil {
                    vocab[target] = [Float](repeating: 0, count: riDimension)
                }
                for d in 0..<riDimension {
                    vocab[target]![d] += neighbourIndex[d]
                }
            }
        }
    }

    // MARK: EmbeddingProvider

    /// Produce the distributional embedding for `text`.
    ///
    /// Splits text into keyword tokens, looks up each term's context
    /// vector, sums them, and L2-normalises the result. The normalised
    /// D-dimensional vector is then projected through FloatSimHash to
    /// produce the 256-bit Engram.
    ///
    /// Empty input returns Engram.zero (EmbeddingProvider contract).
    public func embed(_ text: String) async throws -> Engram {
        let v = await contextVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the D-dimensional normalised context vector for `text`.
    ///
    /// This is the honest semantic vector: a point in the RI space
    /// where nearby terms share context. Callers using the float lane
    /// get real distributional coordinates — never a hash-of-surface-form
    /// masquerading as a semantic embedding.
    ///
    /// Empty input returns `[]` (EmbeddingProvider.embedFloat contract).
    public func embedFloat(_ text: String) async throws -> [Float] {
        return await contextVector(for: text)
    }

    // MARK: Private helpers

    /// Compute the normalised context vector for `text` as a pure function
    /// of the current vocab table. Returns `[]` for empty text or when
    /// all terms are OOV (out-of-vocabulary).
    private func contextVector(for text: String) async -> [Float] {
        guard !text.isEmpty else { return [] }
        // Tokenize into keyword tokens (lowercase, alpha/digit split) via the
        // single canonical CorpusKit tokenizer — shared by BM25 and every
        // distributional provider (RI/PPMI/LSA/NMF), and parity with the Rust
        // port's corpus_kit::default_keyword_tokens.
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }

        var sum = [Float](repeating: 0, count: riDimension)
        var hitCount = 0
        for term in terms {
            if let cv = vocab[term] {
                for d in 0..<riDimension {
                    sum[d] += cv[d]
                }
                hitCount += 1
            }
        }
        // All terms OOV → zero vector → honest no-context signal.
        guard hitCount > 0 else { return [] }
        // Delegate to the substrate's canonical scalar implementation.
        // FloatVecOps.l2Normalize is conformance-gated against the Rust
        // port; using it here guarantees bit-identical output without
        // maintaining a separate inline implementation.
        return FloatVecOps.l2Normalize(sum)
    }

    // MARK: Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) context vector for a term, or nil
    /// if the term is OOV. Used by conformance tests to verify index
    /// vector accumulation without triggering the full embed pipeline.
    public func contextVector(forTerm term: String) -> [Float]? {
        vocab[term.lowercased()]
    }

    /// The current trained vocabulary size.
    public var vocabularySize: Int { vocab.count }
}
