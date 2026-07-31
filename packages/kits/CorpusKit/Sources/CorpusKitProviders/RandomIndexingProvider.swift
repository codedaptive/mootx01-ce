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
// meaning, not surface form, satisfying honest semantic fusion D-1's honesty
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
//   Model ID = "random-indexing-v1",  version = "1.1.0"
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/random_indexing.rs
//
// honest semantic fusion reference: Decision B, signal #2 of the honest fusion.

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
/// modelVersion = "1.1.0". Projection seed = `riProjectionSeed`.
///
/// honest semantic fusion, signal #2 — the first honest distributional
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
        modelVersion: String = "1.1.0",
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
        let n = terms.count
        guard n > 0 else { return }
        // Precompute each position's index vector ONCE. The previous form called
        // `riIndexVector(terms[j])` for every (i, j) pair, recomputing each
        // position's (deterministic) index vector ~2·window times. Same values,
        // computed once — bit-identical.
        let idxVecs = terms.map { riIndexVector(term: $0) }
        for (i, target) in terms.enumerated() {
            // Context: every term within ±window positions, excluding self.
            let lo = max(0, i - window)
            let hi = min(n - 1, i + window)
            // No neighbours (the window collapses to {i}) → leave vocab untouched,
            // exactly as the per-neighbour form did. A neighbourless term stays OOV.
            if hi <= lo { continue }
            // Bind the target's context vector ONCE per position, accumulate every
            // neighbour into the local copy (neighbours in ascending j order — the
            // same order as before), then write back once. The previous form
            // re-looked-up `vocab[target]` (a String hash + dictionary probe + CoW
            // uniqueness check) for EVERY dimension of EVERY neighbour — 2048 dict
            // lookups per neighbour pair. Accumulation order is unchanged, so the
            // stored context vector is bit-identical.
            var cv = vocab[target] ?? [Float](repeating: 0, count: riDimension)
            for j in lo...hi where j != i {
                let neighbourIndex = idxVecs[j]
                for d in 0..<riDimension {
                    cv[d] += neighbourIndex[d]
                }
            }
            vocab[target] = cv
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
    ///
    /// When the provider HAS a trained basis (vocab non-empty) but all query
    /// tokens are OOV, throws `VectorKitError.embedFloatVocabMiss` so the
    /// corpus layer can surface `FloatLaneOutcome.unavailableNoVocabHit`
    /// instead of misclassifying the miss as a structural opt-out.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // Untrained provider (empty vocab): return [] so the corpus layer
        // uses the structural opt-out path (unavailableProviderOptOut),
        // which is the correct signal — no basis exists at all.
        if vocab.isEmpty {
            return []
        }
        // Empty or token-free input: return [] without a vocab-miss throw.
        // The corpus layer's Corpus.floatNearest guards limit==0 and empty
        // query before calling embedFloat, but callers can bypass that guard
        // by calling embedFloat directly. Empty is structurally "no query",
        // not a vocabulary miss — emit no float vector, no error.
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }

        let result = await contextVector(for: text)
        if result.isEmpty {
            // Trained provider, non-empty query, but all query terms OOV:
            // throw a vocab-miss error so the corpus layer maps to
            // unavailableNoVocabHit instead of the misleading providerOptOut.
            throw VectorKitError.embedFloatVocabMiss(
                "random-indexing: vocab size \(vocab.count), but 0 of \(terms.count) query token(s) matched"
            )
        }
        return result
    }

    /// Produce the engram AND the normalised context vector from a SINGLE
    /// context-vector computation.
    ///
    /// `embed` projects the context vector and `embedFloat` returns it, so a
    /// caller that needs both would otherwise run `contextVector(for:)` twice.
    /// This override computes it ONCE and returns both outputs.
    ///
    /// Byte-identical to calling `embed` then `embedFloat` separately:
    /// the engram is `FloatSimHash.project` of the vector (or `.zero` when the
    /// vector is empty), and `floats` reproduces `embedFloat`'s result with its
    /// vocab-miss throw collapsed to `[]` (the `embedPair` opt-out contract).
    /// When the vocab is empty the context vector is `[]`, so the engram is
    /// `.zero` and floats are `[]` — identical to the separate calls.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = await contextVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
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

    // MARK: Basis serialization (mission 6a-i)

    /// 4-byte magic identifying a Random Indexing basis blob ("RIB1").
    /// Distinct per provider so a blob can never be deserialized by the
    /// wrong provider type — `init(deserializing:)` rejects a mismatch.
    static let basisMagic: [UInt8] = Array("RIB1".utf8)

    /// Serialize the trained RI basis to a versioned, little-endian blob.
    ///
    /// The RI basis is fully determined by the `vocab` map (term → context
    /// vector); the model identity and projection seed are also captured so
    /// the reconstructed provider keys to the same Engram bucket.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | vocab (String→[Float] map, sorted keys)
    ///
    /// The same trained state produces byte-identical output on the Rust
    /// port (`serialize_basis`), which is the cross-port conformance gate.
    public func serializeBasis() -> Data {
        var w = BasisWriter()
        w.writeMagic(RandomIndexingProvider.basisMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeStringFloatVectorMap(vocab)
        return w.data
    }

    /// Reconstruct a provider from a serialized RI basis blob.
    ///
    /// The reconstructed provider's `embed`/`embedFloat` output is identical
    /// to the original trained provider's (round-trip law). Throws
    /// `CorpusKitError.decodingFailure` on a truncated blob, an unknown
    /// format version, or a magic mismatch — never crashes.
    public convenience init(deserializing data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(RandomIndexingProvider.basisMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let projectionSeed = try r.readU64()
        let vocab = try r.readStringFloatVectorMap()
        self.init(modelID: modelID, modelVersion: modelVersion, projectionSeed: projectionSeed)
        self.vocab = vocab
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

extension RandomIndexingProvider: TrainableEmbeddingBasis {

    /// Train the RI basis on a corpus of raw document texts.
    ///
    /// RI's training API consumes a term sequence per document, so each text
    /// is tokenized with the canonical `defaultKeywordTokens` — the SAME
    /// tokenizer `embedFloat` uses — and fed to `train(terms:window:)` at the
    /// canonical `riWindow`. RI has no finalization pass: the context vectors
    /// are complete once every document has been windowed. This reproduces the
    /// exact trained state of `train(terms:)` driven directly from token
    /// arrays, so a basis serialized after `trainOnCorpus` is byte-identical to
    /// the 6a-i fixture whose corpus is the same texts tokenized.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(terms: defaultKeywordTokens(text), window: riWindow)
        }
    }

    /// Streamed-training page: the same per-text accumulation
    /// `trainOnCorpus` runs. RI has no finalization pass.
    public func accumulateTraining(texts: [String]) {
        for text in texts {
            train(terms: defaultKeywordTokens(text), window: riWindow)
        }
    }

    public func finalizeTraining() {
        // Random Indexing is finalization-free: vectors are the accumulated
        // state itself (mirrors trainOnCorpus, which runs no finalize).
    }

    /// Reconstruct a fresh `RandomIndexingProvider` from a serialized basis,
    /// type-erased. Delegates to `init(deserializing:)` (6a-i).
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try RandomIndexingProvider(deserializing: basis)
    }

    /// release the in-memory vocab dictionary (~1GB on a 50K estate).
    /// The next embed call must go through reconstructBasis from BasisStore.
    public func releaseBasis() {
        vocab.removeAll(keepingCapacity: false)
    }

    // MARK: Maintained counts (incremental-counts change set, P3)

    /// 4-byte magic identifying an RI COUNTS blob ("RICT"). RI is unique among
    /// the trainable providers: its accumulated state — the per-term context
    /// vectors — IS its basis (there is no separate factorization step). The
    /// counts blob therefore carries the same `vocab` payload as the basis blob,
    /// but under a distinct magic so a counts row can never be misread as a basis
    /// row, keeping the two stores' contracts uniform across all four providers.
    static let countsMagic: [UInt8] = Array("RICT".utf8)

    /// Fold one chunk's text into the accumulated context vectors. RI's
    /// accumulation consumes a term sequence, so the text is tokenized with the
    /// canonical `defaultKeywordTokens` and folded at the canonical `riWindow` —
    /// the same per-document step `trainOnCorpus` runs (RI has no finalize).
    public func addToCounts(text: String) {
        train(terms: defaultKeywordTokens(text), window: riWindow)
    }

    /// Serialize the maintained context vectors to a versioned counts blob.
    /// Same `vocab` payload as `serializeBasis()`, under the RICT counts magic.
    public func serializeCounts() -> Data {
        var w = BasisWriter()
        w.writeMagic(RandomIndexingProvider.countsMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeStringFloatVectorMap(vocab)
        return w.data
    }

    /// Restore the accumulated context vectors in place from a counts blob, so
    /// incremental maintenance resumes after a restart. Throws
    /// `CorpusKitError.decodingFailure` on a bad blob — never crashes.
    /// Split the counts blob into its fixed header and one entry per term.
    ///
    /// The header is the identical prefix `serializeCounts()` writes, followed
    /// by an EMPTY map — so it stays a decodable RICT blob on its own and a
    /// reader that knows nothing about term rows still gets a valid (empty)
    /// vocabulary rather than a decode failure or a NULL column.
    ///
    /// Each term's `vector` is exactly the bytes `writeFloatArray` emits for
    /// that term inside the blob: `u32 count` followed by `count` little-endian
    /// f32. Reusing the same writer is deliberate — the per-term bytes are the
    /// cross-port conformance contract, so they must not acquire a second
    /// encoder that could drift from the Rust twin.
    public func decomposeCounts() -> (header: Data, terms: [(term: String, vector: Data)])? {
        var headerWriter = BasisWriter()
        headerWriter.writeMagic(RandomIndexingProvider.countsMagic)
        headerWriter.writeByte(basisFormatVersion)
        headerWriter.writeString(modelID)
        headerWriter.writeString(modelVersion)
        headerWriter.writeU64(projectionSeed)
        headerWriter.writeStringFloatVectorMap([:])

        let terms = vocab.map { key, value -> (term: String, vector: Data) in
            var vectorWriter = BasisWriter()
            vectorWriter.writeFloatArray(value)
            return (term: key, vector: vectorWriter.data)
        }
        return (header: headerWriter.data, terms: terms)
    }

    /// Rehydrate from a header plus per-term entries — inverse of
    /// `decomposeCounts()`.
    ///
    /// The header is validated exactly as `restoreCounts(from:)` validates a
    /// full blob, so a mismatched provider or format version still fails
    /// closed. Term order is irrelevant: the result is a dictionary, and only
    /// the blob WRITER needs the UTF-8 byte ordering that keeps the two ports
    /// byte-identical.
    public func restoreCounts(header: Data, terms: [(term: String, vector: Data)]) throws {
        var headerReader = BasisReader(header)
        try headerReader.expectMagic(RandomIndexingProvider.countsMagic)
        try headerReader.expectVersion(basisFormatVersion)
        _ = try headerReader.readString()  // modelID — validated by magic + row key
        _ = try headerReader.readString()  // modelVersion
        _ = try headerReader.readU64()     // projectionSeed

        var rebuilt: [String: [Float]] = [:]
        rebuilt.reserveCapacity(terms.count)
        for entry in terms {
            var vectorReader = BasisReader(entry.vector)
            rebuilt[entry.term] = try vectorReader.readFloatArray()
        }
        self.vocab = rebuilt
    }

    public func restoreCounts(from data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(RandomIndexingProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        _ = try r.readString()  // modelID — header for validation; row is keyed by it
        _ = try r.readString()  // modelVersion
        _ = try r.readU64()     // projectionSeed
        self.vocab = try r.readStringFloatVectorMap()
    }

    /// Maintained vocabulary size for the growth trigger.
    public var countsVocabularySize: Int { vocab.count }

    public func countsContainsTerm(_ term: String) -> Bool {
        vocab[term] != nil
    }
}
