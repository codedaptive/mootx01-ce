// NmfProvider.swift
//
// NMF (Non-Negative Matrix Factorization) distributional-semantics
// embedding provider. Part of the ADR-010 Decision B honest classical-
// fusion signal set.
//
// ## Algorithm
//
//   1. Build a term-document matrix V (terms × documents) with
//      TF weighting (log-smoothed raw count). TF (not TF-IDF) is
//      used because NMF requires non-negative input AND the Lee-Seung
//      multiplicative updates are most stable when the input is
//      uniformly scaled. TF satisfies non-negativity; the log-smoothing
//      tf(t, d) = log(1 + raw_count(t, d)) keeps the values bounded.
//      CANONICAL tokenizer: CorpusKit.defaultKeywordTokens.
//
//      NOTE: V is arranged as terms × documents (vocabSize × numDocs) so
//      that the H matrix is rank × numDocs and column j of H is the
//      k-dimensional latent representation of document j. This is the
//      standard NMF layout for document embeddings.
//
//   2. Factorize V ≈ W · H via the SubstrateML NMFAlternatingLeastSquares
//      kernel (reused, not reimplemented):
//        V ∈ R+^{m×n}  (m = vocabSize, n = numDocs)
//        W ∈ R+^{m×k}  (term-factor loadings)
//        H ∈ R+^{k×n}  (document factor loadings)
//      Rank k is the embedding dimensionality (default 32).
//      Fixed iteration count (tolerance = 0) produces DETERMINISTIC output
//      independent of floating-point convergence — a requirement for the
//      recall identity contract.
//
//   3. Document embedding: H[:, docIdx] — column docIdx of H, i.e. the
//      k-dim row H[r][docIdx] for r in 0..<k. L2-normalised via
//      FloatVecOps.l2Normalize.
//
//   4. Query embedding: for query text Q, compute the TF-weighted term
//      vector q (sparse, length vocabSize), then project into the NMF
//      space via the pseudo-inverse of W:
//        queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
//      This is the standard NMF query folding-in (analogous to LSA's
//      fold-in via Vᵀ). L2-normalised. OOV terms contribute nothing.
//
//   5. L2-normalise and project to Engram via FloatSimHash.project with
//      `nmfProjectionSeed`.
//
// ## NMF kernel reuse
//
//   The NMFAlternatingLeastSquares kernel lives in SubstrateML. This
//   provider reuses it directly — no separate NMF implementation here.
//   This satisfies the Gate-2 requirement: only NMF-retrieval-specific
//   composition (TF matrix, query folding-in) lives in this file.
//
//   The kernel call uses tolerance=0 to force a fixed iteration count.
//   `tolerance=0` makes `abs(prevError - err) < 0` always false, so the
//   loop always runs to `maxIterations`. This is intentional and
//   documented: for retrieval the bit-identity requirement overrides
//   the convergence-stopping behaviour.
//
// ## TF weighting (non-negative, per NMF requirement)
//
//   tf(t, d) = log(1 + raw_count(t, d))   — log-smoothed, always >= 0
//
//   IDF is deliberately NOT applied. IDF would require a corpus-wide
//   document count and would change the per-entry values in V, but
//   the multiplicative update rules are most stable when V has entries
//   in a compact range. Log-TF without IDF keeps the matrix well-
//   conditioned for small estates while still satisfying V >= 0.
//
// ## Constants
//
//   NMF_PROJECTION_SEED = 0x4E4D465F56315F4D  ("NMF_V1_M" in ASCII)
//   Model ID = "nmf-v1",  version = "1.0.0"
//   Default rank k = 32
//   Default maxIterations = 100
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/nmf_provider.rs
//
// ADR-010 reference: Decision B signal set — NMF latent-factor provider.

import Foundation
import CorpusKit
import EngramLib
import SubstrateTypes
// SubstrateKernel: FloatVecOps.l2Normalize (canonical conformance-gated).
import SubstrateKernel
// SubstrateML: NMFAlternatingLeastSquares (reused, deterministic via
// tolerance=0), FloatSimHash.project (canonical projection to Engram).
import SubstrateML
import VectorKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// NMFAlternatingLeastSquares: SubstrateML.NMFAlternatingLeastSquares.factorize
// FloatSimHash:               SubstrateML.FloatSimHash.project
// FloatVecOps:                SubstrateKernel.FloatVecOps.l2Normalize
//
// These are conformance-gated substrate primitives. Using them here
// guarantees bit-identity with the Rust port and with the canonical
// test vectors.
// ─────────────────────────────────────────────────────────────────

// MARK: - Constants

/// FloatSimHash projection seed for NMF. Encodes "NMF_V1_M" in ASCII.
/// MUST differ from lsaProjectionSeed, riProjectionSeed, and
/// ppmiProjectionSeed so NMF engrams key to a separate storage bucket
/// when all providers coexist in one estate.
/// MUST NOT drift from the Rust constant NMF_PROJECTION_SEED.
public let nmfProjectionSeed: UInt64 = 0x4E4D465F56315F4D

/// Default NMF rank k (latent dimensionality).
/// 32 dimensions balances expressiveness and compute for on-device estates.
public let nmfDefaultRank: Int = 32

/// Default fixed iteration count.
/// tolerance=0 disables early exit so every factorization runs exactly
/// this many iterations — a requirement for bit-identical output.
public let nmfDefaultIterations: Int = 100

/// SplitMix64 seed for NMF factor initialization.
/// Using the canonical substrate seed so the PRNG sequence is
/// deterministic and documented. This seed is the same across both ports.
public let nmfFactorizationSeed: UInt64 = 0xDEADBEEFCAFEBABE

// MARK: - NmfProvider

/// NMF (Non-Negative Matrix Factorization) distributional-semantics
/// embedding provider.
///
/// An instance builds a TF-weighted term-document matrix, factorizes it
/// via the SubstrateML NMFAlternatingLeastSquares kernel (reused, not
/// reimplemented), and provides document and query embeddings via the NMF
/// factor loadings.
///
/// ## Lifecycle
///
///   1. `train(document:)` — call once per training document.
///      Accumulates TF statistics.
///   2. `finalize()` — builds the TF matrix, runs NMF. Must be called
///      before `embed` / `embedFloat`.
///   3. `embed(_:)` / `embedFloat(_:)` — fold a new text into the NMF
///      space and return Engram / float vector.
///
/// ## Thread safety
///
/// `NmfProvider` is `Sendable`. Training is NOT concurrency-safe;
/// callers must complete all `train` calls before concurrent `embed` calls.
/// After `finalize()`, the provider is read-only.
///
/// ## Conformance
///
/// Conforms to `VectorKit.EmbeddingProvider`.
/// modelID = "nmf-v1", modelVersion = "1.0.0".
/// Projection seed = `nmfProjectionSeed`.
///
/// ADR-010 Decision B — NMF latent-factor provider in the classical-
/// fusion dense recall lane.
public final class NmfProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// NMF rank k (latent dimensionality).
    public let rank: Int

    /// Fixed iteration count. tolerance=0 disables convergence stopping.
    public let maxIterations: Int

    /// SplitMix64 seed for factor initialization. Fixed for cross-port
    /// bit-identity — changing this invalidates all conformance vectors.
    public let seed: UInt64

    /// FloatSimHash projection seed.
    private let projectionSeed: UInt64

    // ── Training-phase state ──────────────────────────────────────────

    /// Shared term-document count builder.  Owns vocab construction,
    /// encounter-order index assignment, and TF counts.
    /// NMF uses only TF counts (not DF counts); the builder accumulates
    /// DF counts anyway (zero cost) so the shared type is uniform.
    private var counts: TermDocumentCounts

    // ── Post-finalize state ───────────────────────────────────────────

    /// NMF factorization result. Nil until finalize() is called.
    private var nmf: NMFFactorization?

    /// Per-document embeddings (H column per doc), populated at finalize().
    /// docEmbeddings[d] = L2-normalised H[:, d] of length effectiveRank.
    private var docEmbeddings: [[Float]]

    // MARK: Initialiser

    public init(
        modelID: String = "nmf-v1",
        modelVersion: String = "1.0.0",
        rank: Int = nmfDefaultRank,
        maxIterations: Int = nmfDefaultIterations,
        seed: UInt64 = nmfFactorizationSeed,
        projectionSeed: UInt64 = nmfProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.rank = max(1, rank)
        self.maxIterations = max(1, maxIterations)
        self.seed = seed
        self.projectionSeed = projectionSeed
        self.counts = TermDocumentCounts()
        self.nmf = nil
        self.docEmbeddings = []
    }

    // MARK: Training

    /// Add a training document to the TF term-document matrix.
    ///
    /// Delegates tokenization, vocabulary construction (encounter-order
    /// index assignment), and TF count accumulation to the shared
    /// `TermDocumentCounts` builder.
    ///
    /// - Parameter document: Raw document text. Tokenized by
    ///   `defaultKeywordTokens` (lowercase, alpha/digit split).
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public func train(document: String) {
        counts.addDocument(document)
    }

    // MARK: Finalization

    /// Build the TF matrix and run NMF factorization.
    ///
    /// Must be called after all `train` calls and before any `embed` calls.
    /// Calling `finalize()` again recomputes from the current counts.
    ///
    /// ## Matrix layout
    ///
    /// V is arranged as vocabSize × numDocs (terms as rows, documents as
    /// columns). H is rank × numDocs; column d of H is the k-dimensional
    /// embedding for document d.
    ///
    /// V[i][j] = log(1 + tf[j][i])  — i is the term, j is the document.
    ///
    /// ## Fixed iteration count
    ///
    /// tolerance=0 disables convergence-stopping so every factorization runs
    /// exactly `maxIterations` iterations. This is the deterministic path
    /// required for bit-identical cross-port output.
    public func finalize() {
        let numDocs = counts.documentCount
        let vocabSize = counts.vocabularySize
        guard numDocs > 0, vocabSize > 0 else { return }

        // V is vocabSize × numDocs: V[term][doc] = log(1 + tf[doc][term]).
        // Built from the shared builder's TF counts.
        var V: [[Float]] = [[Float]](
            repeating: [Float](repeating: 0, count: numDocs),
            count: vocabSize
        )
        for (docIdx, docTF) in counts.tfCounts.enumerated() {
            for (termIdx, count) in docTF {
                V[termIdx][docIdx] = log(1 + Float(count))
            }
        }

        // Effective rank: min(requestedRank, min(vocabSize, numDocs)).
        let effectiveRank = min(rank, min(vocabSize, numDocs))

        // Run SubstrateML NMF with tolerance=0 (fixed iteration count).
        // tolerance=0 makes abs(prevError - err) < 0 always false, so the
        // loop runs to maxIterations exactly. This is intentional: bit-
        // identity requires a fixed computation path, not convergence-dependent.
        nmf = NMFAlternatingLeastSquares.factorize(
            V: V,
            rank: effectiveRank,
            maxIterations: maxIterations,
            tolerance: 0,          // FIXED ITERATIONS — do not change
            seed: seed
        )

        // Pre-compute document embeddings: column d of H = H[r][d] for r in 0..<k.
        // L2-normalise via the substrate's conformance-gated primitive.
        guard let result = nmf else { return }
        let k = result.rank
        docEmbeddings = (0..<numDocs).map { d in
            let col: [Float] = (0..<k).map { r in result.H[r][d] }
            let normalised = FloatVecOps.l2Normalize(col)
            return normalised
        }
    }

    // MARK: EmbeddingProvider

    /// Return the k-dimensional NMF embedding for `text`.
    ///
    /// Uses the query folding-in formula: project the TF query vector
    /// through W columns via the pseudo-inverse.
    ///
    /// Returns Engram.zero if finalize() not called or all terms are OOV.
    public func embed(_ text: String) async throws -> Engram {
        guard let v = nmfVector(for: text), !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the k-dimensional L2-normalised NMF float vector for `text`.
    ///
    /// Returns `[]` if finalize() has not been called or all terms are OOV.
    public func embedFloat(_ text: String) async throws -> [Float] {
        return nmfVector(for: text) ?? []
    }

    // MARK: Private helpers

    /// Compute the NMF embedding vector for `text` using the fold-in formula.
    ///
    /// For a query with TF-weighted term vector q (sparse, vocabSize entries):
    ///   queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
    ///
    /// This is the pseudo-inverse projection of q onto each latent factor
    /// column of W. Analogous to LSA fold-in (Σ^{-1} Vᵀ q).
    ///
    /// Returns nil when:
    ///   - finalize() not called
    ///   - text is empty
    ///   - all tokens are OOV
    private func nmfVector(for text: String) -> [Float]? {
        guard let result = nmf else { return nil }
        guard !text.isEmpty else { return nil }

        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return nil }

        let k = result.rank
        let vocabSize = counts.vocabularySize
        let eps: Float = 1e-9

        // Build sparse TF query vector.
        var hasInVocab = false
        var rawCounts: [Int: Int] = [:]
        for term in terms {
            if let idx = counts.vocab[term] {
                rawCounts[idx, default: 0] += 1
                hasInVocab = true
            }
        }
        guard hasInVocab else { return nil }

        // TF weights: log(1 + count), same as the training matrix.
        var q: [Float] = [Float](repeating: 0, count: vocabSize)
        for (termIdx, count) in rawCounts {
            q[termIdx] = log(1 + Float(count))
        }

        // Fold-in: queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
        // W is vocabSize × k (result.W[i][r] is the (i, r) entry).
        // Column r of W is: W[0][r], W[1][r], ..., W[vocabSize-1][r].
        var queryVec = [Float](repeating: 0, count: k)
        var hasNonZero = false
        for r in 0..<k {
            var dot: Float = 0
            var normSq: Float = 0
            for i in 0..<vocabSize {
                let wir = result.W[i][r]
                dot += wir * q[i]
                normSq += wir * wir
            }
            queryVec[r] = dot / (normSq + eps)
            if queryVec[r] != 0 { hasNonZero = true }
        }
        guard hasNonZero else { return nil }

        // L2-normalise using the substrate's conformance-gated primitive.
        let normalised = FloatVecOps.l2Normalize(queryVec)
        let allZero = normalised.allSatisfy { $0 == 0 }
        return allZero ? nil : normalised
    }

    // MARK: Document embedding (training documents)

    /// Return the k-dimensional NMF document embedding for training
    /// document at index `docIdx`.
    ///
    /// This is the L2-normalised column docIdx of H (pre-computed at
    /// finalize()). Only valid after finalize().
    ///
    /// - Returns: L2-normalised k-dim float vector, or nil if docIdx is
    ///   out of range or finalize() has not been called.
    public func documentEmbedding(at docIdx: Int) -> [Float]? {
        guard nmf != nil, docIdx >= 0, docIdx < docEmbeddings.count else { return nil }
        return docEmbeddings[docIdx]
    }

    // MARK: Vocabulary access (for conformance tests)

    /// Number of training documents added so far.
    public var documentCount: Int { counts.documentCount }

    /// Size of the vocabulary built from training documents.
    public var vocabularySize: Int { counts.vocabularySize }

    /// True if finalize() has been called with at least one document.
    public var isFinalized: Bool { nmf != nil }

    /// The effective rank k used in the NMF (may be less than `rank` if
    /// the corpus has fewer documents or terms than requested).
    public var effectiveRank: Int { nmf?.rank ?? 0 }

    // MARK: Basis serialization (mission 6a-i)

    /// 4-byte magic identifying an NMF basis blob ("NMB1").
    static let basisMagic: [UInt8] = Array("NMB1".utf8)

    /// Serialize the finalized NMF basis to a versioned, little-endian blob.
    ///
    /// The NMF basis that determines both query embeddings (fold-in via W)
    /// and training-document embeddings (column of H) is the W·H
    /// factorization plus the term-document support:
    ///   - `rank`, `maxIterations`, `seed`, `projectionSeed` — configuration
    ///     the reconstructed provider reports (and that pins the Engram bucket).
    ///   - vocab (term → index) and `documentCount` — query tokens map to
    ///     vocab positions; documentCount bounds `documentEmbedding(at:)`.
    ///   - factors `W` (vocabSize × k) and `H` (k × numDocs), plus
    ///     `effectiveRank`. W drives the query fold-in; H drives document
    ///     embeddings. Both are PORT-NEUTRAL raw factors, so the same trained
    ///     state produces a byte-identical blob on both ports.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | rank (u32) |
    ///   maxIterations (u32) | seed (u64) | projectionSeed (u64) |
    ///   documentCount (u32) | effectiveRank (u32) | vocab (String→u32 map) |
    ///   W (matrix) | H (matrix)
    public func serializeBasis() -> Data {
        var w = BasisWriter()
        w.writeMagic(NmfProvider.basisMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU32(UInt32(rank))
        w.writeU32(UInt32(maxIterations))
        w.writeU64(seed)
        w.writeU64(projectionSeed)
        w.writeU32(UInt32(counts.documentCount))
        w.writeU32(UInt32(nmf?.rank ?? 0))
        w.writeStringU32Map(counts.vocab)
        w.writeFloatMatrix(nmf?.W ?? [])
        w.writeFloatMatrix(nmf?.H ?? [])
        return w.data
    }

    /// Reconstruct a provider from a serialized NMF basis blob.
    ///
    /// The reconstructed provider's `embed`/`embedFloat`/`documentEmbedding`
    /// output is identical to the original finalized provider's (round-trip
    /// law). Throws `CorpusKitError.decodingFailure` on a truncated blob,
    /// unknown version, or magic mismatch — never crashes.
    public convenience init(deserializing data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(NmfProvider.basisMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let rank = Int(try r.readU32())
        let maxIterations = Int(try r.readU32())
        let seed = try r.readU64()
        let projectionSeed = try r.readU64()
        let documentCount = Int(try r.readU32())
        let effectiveRank = Int(try r.readU32())
        let vocab = try r.readStringU32Map()
        let W = try r.readFloatMatrix()
        let H = try r.readFloatMatrix()

        self.init(modelID: modelID,
                  modelVersion: modelVersion,
                  rank: rank,
                  maxIterations: maxIterations,
                  seed: seed,
                  projectionSeed: projectionSeed)
        self.counts = TermDocumentCounts(restoredVocab: vocab, documentCount: documentCount)

        // An empty factor section means the source provider was never
        // finalized; leave `nmf` nil so the restored provider is unfinalized.
        guard effectiveRank > 0 || !W.isEmpty else { return }
        // Reconstruct the factorization. `iterations` and `finalError` are not
        // embed-relevant (embedding reads only W/H), so they carry the
        // configured iteration count and a zero error placeholder.
        self.nmf = NMFFactorization(W: W, H: H, rank: effectiveRank,
                                    iterations: maxIterations, finalError: 0)
        // Re-derive the per-document embeddings exactly as finalize() does:
        // L2-normalised column d of H.
        let numDocs = documentCount
        self.docEmbeddings = (0..<numDocs).map { d in
            let col: [Float] = (0..<effectiveRank).map { rr in H[rr][d] }
            return FloatVecOps.l2Normalize(col)
        }
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

extension NmfProvider: TrainableEmbeddingBasis {

    /// Train the NMF basis on a corpus of raw document texts.
    ///
    /// NMF's training API consumes a raw document per call (`train(document:)`
    /// tokenizes internally via the shared `TermDocumentCounts` builder, which
    /// uses `defaultKeywordTokens`), so each text is passed through unchanged —
    /// one document column per text. The `finalize()` pass then builds the
    /// TF matrix and runs the SubstrateML NMF factorization (tolerance=0, fixed
    /// iterations, deterministic). This reproduces the exact trained+finalized
    /// state of per-document `train` + `finalize`, so a basis serialized after
    /// `trainOnCorpus` is byte-identical to the 6a-i fixture trained on the
    /// same texts.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(document: text)
        }
        finalize()
    }

    /// Reconstruct a fresh `NmfProvider` from a serialized basis, type-erased.
    /// Delegates to `init(deserializing:)` (6a-i).
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try NmfProvider(deserializing: basis)
    }
}
