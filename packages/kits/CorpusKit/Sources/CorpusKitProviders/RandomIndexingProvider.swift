// RandomIndexingProvider.swift
//
// Random Indexing distributional-semantics embedding provider.
//
// Implements the *context-accumulation* (distributional) form of RI:
//   1. Each term gets a sparse ternary index vector in R^D.
//   2. A term's context vector is the sum of index vectors of
//      co-occurring terms within a sliding window over a corpus.
//   3. A document/query embedding is the pooled context vector of its
//      distinct terms: IDF-weighted sum, L2-normalised, corpus-mean
//      direction removed, L2-normalised (DistributionalPooling.swift).
//
// This is a GENUINE distributional method — "car" and "vehicle"
// share similar context vectors when they co-occur with the same
// neighbours ("drive", "road", "engine"). It captures co-occurrence
// meaning, not surface form, satisfying honest semantic fusion D-1's honesty
// requirement: the dense lane must not lie about what it computes.
//
// The provider conforms to SynapseKit.EmbeddingProvider:
//   embedFloat(_:)  → the D-dimensional pooled unit vector
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
// ## Lifecycle
//
//   train(terms:)  — accumulate context vectors AND the per-term document
//                    frequency (one call = one document).
//   finalize()     — fit the IDF table and the corpus-mean direction from
//                    the accumulated counts. Required before embedding.
//   embed / embedFloat / embedPair — pool through the fitted basis.
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
import SynapseKit
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
/// An instance holds a trained vocabulary map (term → context vector) plus
/// the pooling fit derived from it: the per-term IDF table and the unit
/// corpus-mean direction. The vocabulary is built by calling
/// `train(terms:window:)` once per document; `finalize()` then fits the
/// pooling state. An unfinalized provider returns the empty vector / `.zero`
/// for any text (no basis), and a finalized provider returns them for text
/// whose every term is OOV (the explicit no-context signal, surfaced as a
/// vocabulary miss on the float lane).
///
/// ## Thread safety
///
/// `RandomIndexingProvider` is `Sendable`. The vocab table and the pooling
/// fit are built during training/finalize and then read-only during
/// inference. Training is not concurrency-safe; callers must finish all
/// `train` calls and the `finalize()` before concurrent `embed` calls.
///
/// ## Conformance
///
/// Conforms to `SynapseKit.EmbeddingProvider`. modelID = "random-indexing-v1",
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

    /// Document frequency and document count accumulated by `train`, one
    /// document per call. The IDF table and the corpus-mean direction are
    /// derived from this at `finalize()`; it is training-phase state and is
    /// persisted in the counts blob, never in the basis blob.
    private var counts: TermDocumentCounts

    /// Smoothed IDF per vocabulary term, fitted at `finalize()`. Applied to
    /// documents and queries alike by `DistributionalPooling.pool`.
    private var idfTable: [String: Float]

    /// Unit corpus-mean direction fitted at `finalize()` (D long), or empty
    /// when no term contributed. Removed from every pooled vector.
    private var meanDirection: [Float]

    /// True once `finalize()` has fitted the pooling state for the current
    /// vocabulary; cleared by every `train` call. Embedding an unfinalized
    /// provider yields the no-basis signal rather than an unweighted sum.
    private var isFinalized: Bool

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
        self.counts = TermDocumentCounts()
        self.idfTable = [:]
        self.meanDirection = []
        self.isFinalized = false
    }

    // MARK: Training

    /// Train on one document: accumulate co-occurrence context vectors and
    /// the document-frequency table.
    ///
    /// For each term at position i in `terms`, add the index vector of
    /// each neighbour within [i−window, i+window] to the target term's
    /// context vector. Every distinct term in the call counts once toward
    /// its document frequency, and the call counts as one document (an
    /// empty call is not a document). Training is additive — multiple
    /// `train` calls extend the same vocabulary, enabling streaming updates
    /// over a growing estate. Call `finalize()` after the last document.
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
        // Document frequency: one document per call, each distinct term once.
        counts.addDocumentTerms(terms)
        isFinalized = false
        // Precompute each position's index vector ONCE; each position's
        // (deterministic) index vector is needed for every neighbour pair
        // within the window, and computing it once per position keeps the
        // accumulation bit-identical to a per-pair recomputation.
        let idxVecs = terms.map { riIndexVector(term: $0) }
        for (i, target) in terms.enumerated() {
            // Context: every term within ±window positions, excluding self.
            let lo = max(0, i - window)
            let hi = min(n - 1, i + window)
            // No neighbours (the window collapses to {i}) → leave vocab untouched.
            // A neighbourless term stays OOV in the vector table (its document
            // frequency is still counted above).
            if hi <= lo { continue }
            // Bind the target's context vector ONCE per position, accumulate every
            // neighbour into the local copy (neighbours in ascending j order), then
            // write back once. Accumulation order is what fixes the float bits.
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

    /// Fit the pooling state from the accumulated training counts: the
    /// smoothed IDF of every vocabulary term and the unit corpus-mean
    /// direction `l2Normalize(Σ_t df(t)·idf(t)·cv(t))`.
    ///
    /// A pure function of (`vocab`, document frequencies, document count),
    /// so two finalizations over identical accumulated state produce
    /// identical tables, and the counts path (restore counts → finalize)
    /// yields the same basis bytes as the corpus path. Idempotent; must be
    /// called after the last `train` and before any embed.
    public func finalize() {
        var idf: [String: Float] = [:]
        idf.reserveCapacity(vocab.count)
        for term in vocab.keys {
            idf[term] = counts.inverseDocumentFrequency(of: term)
        }
        idfTable = idf
        meanDirection = DistributionalPooling.meanDirection(
            vectors: vocab,
            idf: idfTable,
            documentFrequency: { counts.documentFrequency(of: $0) },
            dimension: riDimension)
        isFinalized = true
    }

    // MARK: EmbeddingProvider

    /// Produce the distributional embedding for `text`.
    ///
    /// Splits text into keyword tokens, pools their context vectors through
    /// the fitted basis (`DistributionalPooling.pool`), and projects the
    /// pooled unit vector through FloatSimHash to produce the 256-bit Engram.
    ///
    /// Empty input returns Engram.zero (EmbeddingProvider contract).
    public func embed(_ text: String) async throws -> Engram {
        let v = await contextVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the D-dimensional pooled unit vector for `text`.
    ///
    /// This is the honest semantic vector: a point in the RI space
    /// where nearby terms share context. Callers using the float lane
    /// get real distributional coordinates — never a hash-of-surface-form
    /// masquerading as a semantic embedding.
    ///
    /// Empty input returns `[]` (EmbeddingProvider.embedFloat contract).
    ///
    /// When the provider HAS a finalized basis but all query tokens are OOV,
    /// throws `SynapseKitError.embedFloatVocabMiss` so the corpus layer can
    /// surface `FloatLaneOutcome.unavailableNoVocabHit` instead of
    /// misclassifying the miss as a structural opt-out.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // No finalized basis (untrained, or trained without finalize): return
        // [] so the corpus layer uses the structural opt-out path
        // (unavailableProviderOptOut) — no basis exists to pool against.
        guard isFinalized, !vocab.isEmpty else { return [] }
        // Empty or token-free input: return [] without a vocab-miss throw.
        // The corpus layer's Corpus.floatNearest guards limit==0 and empty
        // query before calling embedFloat, but callers can bypass that guard
        // by calling embedFloat directly. Empty is structurally "no query",
        // not a vocabulary miss — emit no float vector, no error.
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }

        let pooled = DistributionalPooling.pool(
            terms: terms, vectors: vocab, idf: idfTable,
            meanDirection: meanDirection, dimension: riDimension)
        if pooled.hits == 0 {
            // Finalized provider, non-empty query, but all query terms OOV:
            // throw a vocab-miss error so the corpus layer maps to
            // unavailableNoVocabHit instead of the misleading providerOptOut.
            throw SynapseKitError.embedFloatVocabMiss(
                "random-indexing: vocab size \(vocab.count), but 0 of \(terms.count) query token(s) matched"
            )
        }
        // Terms matched but the pooled vector collapsed to zero (every matched
        // term weighs 0, or the text is the corpus mean itself): explicit
        // no-signal, reported as an opt-out rather than a vocabulary miss.
        return pooled.vector ?? []
    }

    /// Produce the engram AND the pooled unit vector from a SINGLE pooling
    /// computation.
    ///
    /// `embed` projects the pooled vector and `embedFloat` returns it, so a
    /// caller that needs both would otherwise run `contextVector(for:)` twice.
    /// This override computes it ONCE and returns both outputs.
    ///
    /// Byte-identical to calling `embed` then `embedFloat` separately:
    /// the engram is `FloatSimHash.project` of the vector (or `.zero` when the
    /// vector is empty), and `floats` reproduces `embedFloat`'s result with its
    /// vocab-miss throw collapsed to `[]` (the `embedPair` opt-out contract).
    /// When the basis is not finalized the pooled vector is `[]`, so the engram
    /// is `.zero` and floats are `[]` — identical to the separate calls.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = await contextVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the pooled unit vector for `text` as a pure function of the
    /// finalized basis. Returns `[]` for an unfinalized basis, empty text,
    /// all-OOV text, or a pooled vector that collapsed to zero.
    private func contextVector(for text: String) async -> [Float] {
        guard isFinalized, !text.isEmpty else { return [] }
        // Tokenize into keyword tokens (lowercase, alpha/digit split) via the
        // single canonical CorpusKit tokenizer — shared by BM25 and every
        // distributional provider (RI/LSA), and parity with the Rust
        // port's corpus_kit::default_keyword_tokens.
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }
        return DistributionalPooling.pool(
            terms: terms, vectors: vocab, idf: idfTable,
            meanDirection: meanDirection, dimension: riDimension).vector ?? []
    }

    // MARK: Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) context vector for a term, or nil
    /// if the term is OOV. Used by conformance tests to verify index
    /// vector accumulation without triggering the full embed pipeline.
    public func contextVector(forTerm term: String) -> [Float]? {
        vocab[term.lowercased()]
    }

    /// The fitted smoothed IDF weight of a vocabulary term, or nil when the
    /// term is OOV or the basis is not finalized. Conformance-test accessor.
    public func inverseDocumentFrequency(forTerm term: String) -> Float? {
        idfTable[term.lowercased()]
    }

    /// The fitted unit corpus-mean direction (D long), or empty when the
    /// basis is not finalized or no term contributed. Conformance-test accessor.
    public var corpusMeanDirection: [Float] { meanDirection }

    /// The current trained vocabulary size.
    public var vocabularySize: Int { vocab.count }

    /// Number of documents folded by `train` (the IDF corpus size N).
    public var documentCount: Int { counts.documentCount }

    // MARK: Basis serialization

    /// 4-byte magic identifying a Random Indexing basis blob ("RIB1").
    /// Distinct per provider so a blob can never be deserialized by the
    /// wrong provider type — `init(deserializing:)` rejects a mismatch.
    static let basisMagic: [UInt8] = Array("RIB1".utf8)

    /// Serialize the finalized RI basis to a versioned, little-endian blob.
    ///
    /// The RI basis is the `vocab` map (term → context vector) plus the
    /// pooling fit — the IDF table and the corpus-mean direction — so a
    /// reconstructed provider pools queries exactly as the trainer pooled
    /// documents. The model identity and projection seed are also captured
    /// so the reconstructed provider keys to the same Engram bucket.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | vocab (String→[Float] map, sorted keys)
    ///   | idf (String→Float32 map, sorted keys) | meanDirection ([Float])
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
        w.writeStringF32Map(idfTable)
        w.writeFloatArray(meanDirection)
        return w.data
    }

    /// Reconstruct a provider from a serialized RI basis blob.
    ///
    /// The reconstructed provider's `embed`/`embedFloat` output is identical
    /// to the original finalized provider's (round-trip law). The training
    /// counts are not part of the basis, so a reconstructed provider is
    /// read-only for embedding. Throws `CorpusKitError.decodingFailure` on a
    /// truncated blob, a format version other than `basisFormatVersion`, or
    /// a magic mismatch — never crashes.
    public convenience init(deserializing data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(RandomIndexingProvider.basisMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let projectionSeed = try r.readU64()
        let vocab = try r.readStringFloatVectorMap()
        let idf = try r.readStringF32Map()
        let mean = try r.readFloatArray()
        self.init(modelID: modelID, modelVersion: modelVersion, projectionSeed: projectionSeed)
        self.vocab = vocab
        self.idfTable = idf
        self.meanDirection = mean
        self.isFinalized = true
    }
}

// MARK: - TrainableEmbeddingBasis

extension RandomIndexingProvider: TrainableEmbeddingBasis {

    /// Train the RI basis on a corpus of raw document texts.
    ///
    /// RI's training API consumes a term sequence per document, so each text
    /// is tokenized with the canonical `defaultKeywordTokens` — the SAME
    /// tokenizer `embedFloat` uses — and fed to `train(terms:window:)` at the
    /// canonical `riWindow`; `finalize()` then fits the pooling state. This
    /// reproduces the exact state of `train(terms:)` + `finalize()` driven
    /// directly from token arrays, so a basis serialized after `trainOnCorpus`
    /// is byte-identical to the fixture whose corpus is the same texts tokenized.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(terms: defaultKeywordTokens(text), window: riWindow)
        }
        finalize()
    }

    /// Streamed-training page: the same per-text accumulation
    /// `trainOnCorpus` runs, finalization deferred to `finalizeTraining`.
    public func accumulateTraining(texts: [String]) {
        for text in texts {
            train(terms: defaultKeywordTokens(text), window: riWindow)
        }
    }

    public func finalizeTraining() {
        finalize()
    }

    /// Reconstruct a fresh `RandomIndexingProvider` from a serialized basis,
    /// type-erased. Delegates to `init(deserializing:)`.
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try RandomIndexingProvider(deserializing: basis)
    }

    /// Release the in-memory vocab dictionary (~1GB on a 50K estate) and the
    /// pooling fit. The next embed call must go through reconstructBasis
    /// from BasisStore.
    public func releaseBasis() {
        vocab.removeAll(keepingCapacity: false)
        idfTable.removeAll(keepingCapacity: false)
        meanDirection.removeAll(keepingCapacity: false)
        isFinalized = false
    }

    // MARK: Maintained counts

    /// 4-byte magic identifying an RI COUNTS blob ("RICT"). RI's accumulated
    /// state — the per-term context vectors plus the document-frequency table —
    /// is everything `finalize()` needs, so the counts blob carries the `vocab`
    /// payload under a distinct magic (a counts row can never be misread as a
    /// basis row) followed by the document count and per-term df.
    static let countsMagic: [UInt8] = Array("RICT".utf8)

    /// Fold one chunk's text into the accumulated context vectors and
    /// document frequencies. RI's accumulation consumes a term sequence, so
    /// the text is tokenized with the canonical `defaultKeywordTokens` and
    /// folded at the canonical `riWindow` — the same per-document step
    /// `trainOnCorpus` runs, minus the finalize.
    public func addToCounts(text: String) {
        train(terms: defaultKeywordTokens(text), window: riWindow)
    }

    /// Serialize the maintained state to a versioned counts blob.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | vocab (String→[Float] map, sorted keys)
    ///   | documentCount (u32) | documentFrequencies (String→u32 map, sorted keys)
    public func serializeCounts() -> Data {
        var w = BasisWriter()
        writeCountsHeader(&w, vocabulary: vocab)
        return w.data
    }

    /// Emit the counts frame and fields shared by `serializeCounts` and
    /// `decomposeCounts`: everything except which vocabulary map is inline.
    private func writeCountsHeader(_ w: inout BasisWriter, vocabulary: [String: [Float]]) {
        w.writeMagic(RandomIndexingProvider.countsMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeStringFloatVectorMap(vocabulary)
        w.writeU32(UInt32(counts.documentCount))
        w.writeStringU32Map(counts.documentFrequencies)
    }

    /// Split the counts blob into its fixed header and one entry per term.
    ///
    /// The header is `serializeCounts()` with an EMPTY vocabulary map — so it
    /// stays a decodable RICT blob on its own (a reader that knows nothing
    /// about term rows still gets a valid, empty vocabulary plus the document
    /// count and df table rather than a decode failure or a NULL column).
    ///
    /// Each term's `vector` is exactly the bytes `writeFloatArray` emits for
    /// that term inside the blob: `u32 count` followed by `count` little-endian
    /// f32. Reusing the same writer is deliberate — the per-term bytes are the
    /// cross-port conformance contract, so they must not acquire a second
    /// encoder that could drift from the Rust twin.
    public func decomposeCounts() -> (header: Data, terms: [(term: String, vector: Data)])? {
        var headerWriter = BasisWriter()
        writeCountsHeader(&headerWriter, vocabulary: [:])

        let terms = vocab.map { key, value -> (term: String, vector: Data) in
            var vectorWriter = BasisWriter()
            vectorWriter.writeFloatArray(value)
            return (term: key, vector: vectorWriter.data)
        }
        return (header: headerWriter.data, terms: terms)
    }

    /// Read the counts frame and fields written by `writeCountsHeader`,
    /// returning the inline vocabulary map (empty for a decomposed header).
    /// Installs the restored document-frequency table into `counts` and
    /// clears the pooling fit (the caller finalizes).
    private func readCountsHeader(_ r: inout BasisReader) throws -> [String: [Float]] {
        try r.expectMagic(RandomIndexingProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        _ = try r.readString()  // modelID — validated by magic + row key
        _ = try r.readString()  // modelVersion
        _ = try r.readU64()     // projectionSeed
        let vocabulary = try r.readStringFloatVectorMap()
        let documentCount = Int(try r.readU32())
        let documentFrequencies = try r.readStringU32Map()
        self.counts = TermDocumentCounts(
            restoredDocumentFrequencies: documentFrequencies, documentCount: documentCount)
        self.idfTable = [:]
        self.meanDirection = []
        self.isFinalized = false
        return vocabulary
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
        _ = try readCountsHeader(&headerReader)

        var rebuilt: [String: [Float]] = [:]
        rebuilt.reserveCapacity(terms.count)
        for entry in terms {
            var vectorReader = BasisReader(entry.vector)
            rebuilt[entry.term] = try vectorReader.readFloatArray()
        }
        self.vocab = rebuilt
    }

    /// Restore the accumulated context vectors and document frequencies in
    /// place from a counts blob, so incremental maintenance resumes after a
    /// restart. Throws `CorpusKitError.decodingFailure` on a bad blob — never
    /// crashes.
    public func restoreCounts(from data: Data) throws {
        var r = BasisReader(data)
        self.vocab = try readCountsHeader(&r)
    }

    /// Maintained vocabulary size for the growth trigger.
    public var countsVocabularySize: Int { vocab.count }

    public func countsContainsTerm(_ term: String) -> Bool {
        vocab[term] != nil
    }

    /// Derive the serving basis from restored counts: the RICT payload holds
    /// the complete accumulated state (context vectors, document frequencies,
    /// document count), and `finalize()` is a pure function of it, so the
    /// basis it fits is byte-identical to one trained from scratch over the
    /// same accumulated corpus. Returns `true`.
    public func finalizeFromCounts() -> Bool {
        finalize()
        return true
    }

    /// RI's float in-place accumulation is order-sensitive (reviewer finding F-3):
    /// float addition is not associative, so folding additional texts into a
    /// restored vocab can produce context vectors that differ by a floating-point
    /// rounding step from a from-scratch fold in canonical document order. For RI
    /// the correct retrain path is restore-only — the RICT blob holds the complete
    /// accumulated state, so no delta is applied after restore.
    ///
    /// This explicit `false` is documentation at-site of the F-3 constraint; the
    /// protocol default is also `false`, but the override records the WHY so the
    /// next reader does not assume RI is commutative.
    public var countsDeltaFoldSafe: Bool { false }
}
