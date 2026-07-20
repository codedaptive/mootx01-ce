// LsaProvider.swift
//
// Latent Semantic Analysis (LSA / LSI) distributional-semantics
// embedding provider. Part 2 of the honest semantic fusion honest
// classical-fusion signal set.
//
// ## Algorithm
//
//   1. Build a term-document matrix M (documents × terms) with
//      TF-IDF weighting (term frequency scaled by inverse document
//      frequency log((N+1)/(df+1)), clamped to >= 0).
//      CANONICAL tokenizer: CorpusKit.defaultKeywordTokens.
//
//   2. Run JacobiSVD.decompose on M (documents × terms), transposing
//      only for the wide-matrix case:
//        M ≈ U · diag(Σ) · Vᵀ
//      where U is documents × k, Σ is k×k, Vᵀ is k × terms.
//
//   3. Document embedding (for document d trained in the corpus):
//        docVec(d) = U[d] · Σ  (= the d-th row of U scaled by Σ)
//      This is the standard LSA document projection into the k-dim
//      semantic space.
//
//   4. For query embedding (arbitrary text, may be OOV):
//        queryVec(q) = (Mᵀ_q · V) / Σ
//        where Mᵀ_q is the tf-idf row for the query text treated as
//        a new document.  Equivalently, the "folding-in" formula:
//          queryVec(q) = termRow(q) · V  · Σ^{-1}
//      (see Notes below).
//
//   5. L2-normalise the resulting k-dim vector (FloatVecOps.l2Normalize).
//      Project to Engram via FloatSimHash.project (projection seed below).
//
// ## TF-IDF weighting
//
//   tf(t, d)  = log(1 + raw_count(t, d))    — log-smoothed raw count
//   idf(t)    = log((N + 1) / (df(t) + 1))  — add-1-smoothed IDF
//   tfidf(t,d) = tf(t, d) * idf(t)
//
// The IDF denominator uses the same +1 smoothing on both sides so OOV
// terms at query time (df=0) get idf = log((N+1)/1) > 0, which is
// intentional — an unseen query term is informative. This formula is
// identical in both ports (verified by canonical vectors).
//
// NOTE: The TF-IDF computation uses natural logarithm (Swift log(),
// Rust f32::ln()), which is identical between the two ports because
// the Swift Foundation `log` function is logf under the hood for f32.
// The canonical conformance test pins the bit patterns so any platform
// divergence is immediately caught.
//
// ## Query folding-in formula
//
// After SVD: Mᵀ = U Σ Vᵀ → Mᵀᵀ = M = V Σ Uᵀ.
// A new query vector q (in term-frequency space) folds into the
// latent semantic space as:
//   q_lsa = Σ^{-1} Vᵀ q    (k-dim)
// where Vᵀ is k×terms from the SVD.
//
// In the implementation:
//   - `Vt` from JacobiSVD is k×n (k rows, n=vocabSize columns)
//   - each row Vt[r] is the r-th right singular vector (length n)
//   - for a query with TF-IDF weights tfidf_q[t] at position t
//     in the vocabulary:
//       q_lsa[r] = (1 / Σ[r]) * sum_t( Vt[r][t] * tfidf_q[t] )
//   - result is L2-normalised.
//
// ## Constants
//
//   LSA_DIMENSION = configured at training time via `rank` (default 64)
//   LSA_PROJECTION_SEED = 0x4C53415F56315F4D  ("LSA_V1_M" in ASCII)
//   Model ID = "lsa-v1",  version = "1.0.0"
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/lsa.rs
//
// honest semantic fusion reference: Decision B, signal #1 (LSA/SVD) of the honest
// classical-fusion. The SVD kernel (JacobiSVD) lives in SubstrateML;
// only LSA-specific composition (TF-IDF matrix, folding-in) lives here.

import Foundation
import CorpusKit
import EngramLib
import SubstrateTypes
// SubstrateKernel: FloatVecOps.l2Normalize (canonical conformance-gated).
import SubstrateKernel
// SubstrateML: JacobiSVD (deterministic one-sided Jacobi SVD) and
// FloatSimHash.project (canonical projection to Engram).
import SubstrateML
import VectorKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// JacobiSVD:   SubstrateML.JacobiSVD.decompose (deterministic, cross-port)
// FloatSimHash: SubstrateML.FloatSimHash.project
// FloatVecOps: SubstrateKernel.FloatVecOps.l2Normalize
//
// These are conformance-gated substrate primitives. Using them here
// guarantees bit-identity with the Rust port and with the canonical
// test vectors.
// ─────────────────────────────────────────────────────────────────

// MARK: - Constants

/// FloatSimHash projection seed for LSA. Encodes "LSA_V1_M" in ASCII.
/// MUST differ from riProjectionSeed and ppmiProjectionSeed so LSA
/// engrams key to a separate storage bucket when all three providers
/// coexist in one estate. Must not drift from the Rust constant
/// LSA_PROJECTION_SEED.
public let lsaProjectionSeed: UInt64 = 0x4C53415F56315F4D

/// Default latent-semantic rank k for LSA.
/// 64 dimensions is a standard choice for document retrieval (Deerwester
/// et al. 1990). Configurable at initialisation time.
public let lsaDefaultRank: Int = 64

// MARK: - LsaProvider

/// LSA (Latent Semantic Analysis) distributional-semantics embedding provider.
///
/// An instance builds a term-document matrix from a training corpus, runs
/// the deterministic Jacobi SVD, and then provides document and query
/// embeddings via the LSA folding-in formula.
///
/// ## Lifecycle
///
///   1. `train(document:)` — call once per training document.
///      Accumulates TF and DF statistics.
///   2. `finalize()` — converts statistics to TF-IDF weights, builds
///      the term-document matrix, runs JacobiSVD. Must be called before
///      `embed` / `embedFloat`.
///   3. `embed(_:)` / `embedFloat(_:)` — fold a new text into the
///      LSA space and return Engram / float vector.
///
/// ## Thread safety
///
/// `LsaProvider` is `Sendable`. Training is NOT concurrency-safe;
/// callers must complete all `train` calls before concurrent `embed` calls.
/// After `finalize()`, the provider is read-only.
///
/// ## Conformance
///
/// Conforms to `VectorKit.EmbeddingProvider`.
/// modelID = "lsa-v1", modelVersion = "1.0.0".
/// Projection seed = `lsaProjectionSeed`.
///
/// honest semantic fusion, signal #1 — LSA/SVD provider in the classical-
/// fusion dense recall lane.
public final class LsaProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// Requested LSA rank k.
    public let rank: Int

    /// Reduced-vocabulary cap K for the dense factorization. The SVD
    /// factors a `docs × K` matrix over the top-K informative terms instead of
    /// `docs × full-vocab`. Optimizer knob; default `defaultReducedVocabCap`.
    public let reducedVocabCap: Int

    /// Number of Jacobi sweeps for SVD. Pinned at 30 (same as Rust default).
    /// Changing this invalidates all conformance vectors.
    public let svdSweeps: Int

    /// FloatSimHash projection seed.
    private let projectionSeed: UInt64

    // ── Training-phase state ──────────────────────────────────────────

    /// Shared term-document count builder.  Owns vocab construction,
    /// encounter-order index assignment, TF counts, and DF counts.
    /// LSA reads both TF and DF from this builder for TF-IDF weighting.
    private var counts: TermDocumentCounts

    // ── Post-finalize state ───────────────────────────────────────────

    /// SVD result from finalize(). Nil until finalize() is called.
    private var svd: SVDResult?

    /// IDF weights, indexed by REDUCED vocabulary column.
    private var idfWeights: [Float]

    /// The frozen reduced vocabulary (term → reduced column) the basis was
    /// trained on. Query projection and basis serialization key on
    /// THIS, not the full `counts.vocab`. Empty until `finalize()`.
    private var basisVocab: [String: Int]

    // MARK: Initialiser

    public init(
        modelID: String = "lsa-v1",
        modelVersion: String = "1.0.0",
        rank: Int = lsaDefaultRank,
        svdSweeps: Int = 30,
        projectionSeed: UInt64 = lsaProjectionSeed,
        reducedVocabCap: Int = defaultReducedVocabCap
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.rank = max(1, rank)
        self.reducedVocabCap = max(1, reducedVocabCap)
        self.svdSweeps = max(0, svdSweeps)
        self.projectionSeed = projectionSeed
        self.counts = TermDocumentCounts()
        self.idfWeights = []
        self.basisVocab = [:]
        self.svd = nil
    }

    // MARK: Training

    /// Add a training document to the term-document matrix.
    ///
    /// Delegates tokenization, vocabulary construction (encounter-order
    /// index assignment), TF count accumulation, and DF count accumulation
    /// to the shared `TermDocumentCounts` builder.
    ///
    /// Training is additive across multiple `train` calls (each call
    /// adds one document column to the term-document matrix).
    ///
    /// - Parameter document: Raw document text. Tokenized by
    ///   `defaultKeywordTokens` (lowercase, alpha/digit split).
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public func train(document: String) {
        counts.addDocument(document)
    }

    // MARK: Finalization

    /// Compute TF-IDF weights, build the term-document matrix, and run SVD.
    ///
    /// Must be called after all `train` calls and before any `embed` calls.
    /// Calling `finalize()` again recomputes from the current counts (useful
    /// when `train` was called again after the first `finalize()`).
    ///
    /// ## Matrix layout
    ///
    /// The term-document matrix M is documents × terms (numDocs × vocabSize).
    /// Row i is document i; column j is term j in the vocabulary.
    /// M[i][j] = tfidf(term_j, doc_i).
    ///
    /// The SVD is applied to M directly (JacobiSVD requires m ≥ n, so
    /// the matrix is oriented as numDocs × vocabSize which is tall/square
    /// when the corpus has more documents than unique terms — typical for
    /// most estates). If the corpus has fewer documents than vocab size,
    /// the rank is automatically clamped to numDocs.
    ///
    /// ## TF-IDF formula
    ///
    ///   tf(t, d)   = log(1 + raw_count(t, d))
    ///   idf(t)     = log((N + 1) / (df(t) + 1))
    ///   tfidf(t,d) = tf(t, d) * idf(t)
    ///
    /// Natural log on both sides; add-1 smoothing in IDF denominator.
    public func finalize() {
        let N = counts.documentCount
        guard N > 0, counts.vocabularySize > 0 else { return }

        // factor over a reduced, informative sub-vocabulary so the
        // dense SVD is `docs × K` (feasible) instead of `docs × full-vocab`
        // (~10^15 ops, infeasible). The reduced vocab is a corpus property
        // shared with NMF; it is frozen here and drives query projection.
        // `vocabSize` below is the REDUCED column count — the SVD block that
        // follows is unchanged and keys on it.
        let reduced = selectReducedVocabulary(
            vocab: counts.vocab,
            dfCounts: counts.dfCounts,
            documentCount: N,
            cap: reducedVocabCap
        )
        basisVocab = reduced.termToColumn
        let vocabSize = reduced.size
        guard vocabSize > 0 else { svd = nil; idfWeights = []; return }

        // IDF over REDUCED columns, using the full-corpus df (informativeness is
        // corpus-wide). idfWeights[col] = log((N+1)/(df+1)); natural log with
        // add-1 smoothing — matches Rust's f32::ln().
        idfWeights = [Float](repeating: 0, count: vocabSize)
        for (fullIdx, col) in reduced.fullIndexToColumn {
            let df = counts.dfCounts[fullIdx] ?? 0
            idfWeights[col] = max(0, log(Float(N + 1) / Float(df + 1)))
        }

        // Build the TF-IDF matrix M (numDocs × K, row-major). Map each doc's TF
        // entries whose term is in the reduced vocab to its reduced column;
        // full-vocab terms outside the reduced set are dropped.
        var M: [[Float]] = [[Float]](repeating: [Float](repeating: 0, count: vocabSize), count: N)
        for (docIdx, docTF) in counts.tfCounts.enumerated() {
            for (fullIdx, count) in docTF {
                guard let col = reduced.fullIndexToColumn[fullIdx] else { continue }
                let tf = log(1 + Float(count))
                M[docIdx][col] = tf * idfWeights[col]
            }
        }

        // Determine effective rank: min(requestedRank, min(numDocs, K)).
        let effectiveRank = min(rank, min(N, vocabSize))

        // Run the deterministic Jacobi SVD on M (numDocs × vocabSize).
        // JacobiSVD requires m ≥ n (tall or square). If vocabSize > numDocs
        // the precondition would fail; guard by transposing if needed.
        // In practice, with a meaningful corpus, numDocs >> vocabSize is rare
        // for on-device estates; we handle both orientations.
        if N >= vocabSize {
            // Tall matrix: SVD on M directly (numDocs × vocabSize).
            svd = JacobiSVD.decompose(A: M, rank: effectiveRank, sweeps: svdSweeps)
        } else {
            // Wide matrix: SVD on Mᵀ (vocabSize × numDocs), then swap U/Vt.
            var Mt: [[Float]] = [[Float]](repeating: [Float](repeating: 0, count: N), count: vocabSize)
            for i in 0..<N {
                for j in 0..<vocabSize {
                    Mt[j][i] = M[i][j]
                }
            }
            let transposedSVD = JacobiSVD.decompose(A: Mt, rank: effectiveRank, sweeps: svdSweeps)
            // Swap: U becomes Vt, Vt becomes U (transposed).
            // For the wide case: M = V Σ Uᵀ where V is vocabSize × k,
            // U is numDocs × k. We want docVec = U[d] · Σ and queryVec
            // via folding. After swap, our "svd.U" is numDocs × k and
            // "svd.Vt" is k × vocabSize — same orientation as the tall case.
            let k = transposedSVD.rank
            // transposedSVD.U = vocabSize × k (left vectors of Mᵀ = right of M)
            // transposedSVD.Vt = k × numDocs (right vectors of Mᵀ = left rows of M)
            // For document embeddings we need U (numDocs × k) = transposedSVD.Vt transposed.
            let uNew: [[Float]] = (0..<N).map { d in
                (0..<k).map { r in transposedSVD.Vt[r][d] }
            }
            // Vt (k × vocabSize) = transposedSVD.U transposed.
            let vtNew: [[Float]] = (0..<k).map { r in
                (0..<vocabSize).map { j in transposedSVD.U[j][r] }
            }
            svd = SVDResult(U: uNew, singularValues: transposedSVD.singularValues, Vt: vtNew, rank: k)
        }
    }

    // MARK: EmbeddingProvider

    /// Return the k-dimensional LSA embedding for `text`.
    ///
    /// Uses the "fold-in" formula for query texts not in the training corpus:
    ///   queryVec[r] = (1 / σ_r) * dot(Vt[r], tfidfQuery)
    /// Then L2-normalised and projected through FloatSimHash.
    ///
    /// Returns Engram.zero if the SVD is not ready (finalize() not called)
    /// or all query terms are OOV.
    public func embed(_ text: String) async throws -> Engram {
        guard let v = lsaVector(for: text), !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the k-dimensional L2-normalised LSA float vector for `text`.
    ///
    /// Returns `[]` when finalize() has not been called (no basis) or when
    /// the projection produces an all-zero result (e.g. all-zero SVD from a
    /// 1-doc corpus — a basis quality issue, not a vocabulary miss).
    ///
    /// Throws `VectorKitError.embedFloatVocabMiss` when the provider HAS a
    /// finalized basis and non-empty vocabulary, but all query tokens are
    /// OOV — distinguishing a vocabulary coverage gap from a structural
    /// opt-out so `Corpus.floatNearest` maps to the correct dark-lane reason.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // No finalized basis: return [] (structural no-basis → providerOptOut
        // is the correct dark-lane signal, not vocabMiss).
        guard svd != nil, !basisVocab.isEmpty else { return [] }
        // Empty or non-tokenisable input: return [] (emptyQuery guard fires
        // in Corpus.floatNearest before this path is reached in practice).
        guard !text.isEmpty else { return [] }
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }
        // Check OOV before computing the full LSA projection.
        // When the reduced vocab is non-empty but the query hits none of it,
        // throw embedFloatVocabMiss so the corpus layer surfaces the reason.
        let hasInVocab = terms.contains { basisVocab[$0] != nil }
        guard hasInVocab else {
            throw VectorKitError.embedFloatVocabMiss(
                "lsa: reduced vocab size \(basisVocab.count), but 0 of \(terms.count) query token(s) matched"
            )
        }
        // Projection may still return nil (e.g. all singular values near zero,
        // meaning the basis is degenerate). That is a basis quality issue, not
        // a vocabulary miss — return [] to signal providerOptOut.
        return lsaVector(for: text) ?? []
    }

    /// Single-pass override: compute the LSA fold-in vector ONCE and return both
    /// the projected Engram and the float vector, deduping the double pass that
    /// `embed(_:)` + `embedFloat(_:)` would otherwise run. `lsaVector(for:)` is
    /// deterministic; a non-nil vector v projects to the same Engram and is
    /// returned as the float lane; a nil result (no basis, empty/non-tokenisable
    /// input, all-OOV, or a degenerate all-zero fold-in) yields `(.zero, [])`.
    /// This override calls `lsaVector(for:)` directly and never invokes the
    /// default `embedPair` — the all-OOV `embedFloatVocabMiss` path is bypassed
    /// here, not by the default `try?` collapse.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        guard let v = lsaVector(for: text), !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the LSA embedding vector for `text` using the fold-in formula.
    ///
    /// Returns nil (→ Engram.zero / []) when:
    ///   - finalize() not called yet
    ///   - text is empty or tokenizes to nothing
    ///   - all tokens are OOV
    ///   - all singular values are zero
    private func lsaVector(for text: String) -> [Float]? {
        guard let svdResult = svd else { return nil }
        guard !text.isEmpty else { return nil }

        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return nil }

        let k = svdResult.rank
        // Query projection keys on the REDUCED basis vocab, not the
        // full counts vocab. Reduced-set terms map to their column; OOV terms
        // (outside top-K) contribute nothing and are covered by RI.
        let vocabSize = basisVocab.count

        // Compute the TF-IDF vector for the query text.
        // tf(t) = log(1 + raw_count(t)) * idf(t)
        // Terms not in the reduced vocab are OOV and contribute nothing.
        var rawCounts: [Int: Int] = [:]
        var hasInVocab = false
        for term in terms {
            if let idx = basisVocab[term] {
                rawCounts[idx, default: 0] += 1
                hasInVocab = true
            }
        }
        guard hasInVocab else { return nil }

        // Build the sparse TF-IDF query vector.
        var queryTfIdf: [Float] = [Float](repeating: 0, count: vocabSize)
        for (termIdx, count) in rawCounts {
            let tf = log(1 + Float(count))
            let tfidf = tf * (termIdx < idfWeights.count ? idfWeights[termIdx] : 0)
            queryTfIdf[termIdx] = tfidf
        }

        // Fold-in formula: queryVec[r] = (1 / σ_r) * dot(Vt[r], queryTfIdf)
        // Both singular values and Vt rows are from JacobiSVD.
        // Singular values below eps are skipped (zero singular value means
        // the latent direction is undefined).
        let sigmaEps: Float = 1e-9
        var queryVec = [Float](repeating: 0, count: k)
        var hasNonZero = false
        for r in 0..<k {
            let sigma = svdResult.singularValues[r]
            if sigma < sigmaEps { continue }
            // dot product: Vt[r] · queryTfIdf
            // Both vectors have length vocabSize.
            var dot: Float = 0
            let vtRow = svdResult.Vt[r]
            for j in 0..<vocabSize {
                dot += vtRow[j] * queryTfIdf[j]
            }
            queryVec[r] = dot / sigma
            if queryVec[r] != 0 { hasNonZero = true }
        }
        guard hasNonZero else { return nil }

        // L2-normalise using the substrate's conformance-gated primitive.
        // FloatVecOps.l2Normalize returns the input unchanged if norm == 0
        // (zero vector stays zero — honest no-signal).
        let normalised = FloatVecOps.l2Normalize(queryVec)
        // Post-normalise zero check: if all components are zero,
        // return nil so the caller gets honest no-signal.
        let allZero = normalised.allSatisfy { $0 == 0 }
        return allZero ? nil : normalised
    }

    // MARK: Document embedding (training documents)

    /// Return the k-dimensional LSA document embedding for training
    /// document at index `docIdx`.
    ///
    /// For documents in the training corpus the exact document projection
    /// is U[docIdx] · Σ (L2-normalised). Only valid after finalize().
    ///
    /// - Returns: L2-normalised k-dim float vector, or nil if docIdx is
    ///   out of range or finalize() has not been called.
    public func documentEmbedding(at docIdx: Int) -> [Float]? {
        guard let svdResult = svd, docIdx >= 0, docIdx < counts.documentCount else { return nil }
        let k = svdResult.rank
        // docVec[r] = U[docIdx][r] * sigma[r]
        var docVec = [Float](repeating: 0, count: k)
        for r in 0..<k {
            docVec[r] = svdResult.U[docIdx][r] * svdResult.singularValues[r]
        }
        let normalised = FloatVecOps.l2Normalize(docVec)
        let allZero = normalised.allSatisfy { $0 == 0 }
        return allZero ? nil : normalised
    }

    // MARK: Vocabulary access (for conformance tests)

    /// Number of training documents added so far.
    public var documentCount: Int { counts.documentCount }

    /// Size of the vocabulary built from training documents.
    public var vocabularySize: Int { counts.vocabularySize }

    /// True if finalize() has been called with at least one document.
    public var isFinalized: Bool { svd != nil }

    /// The effective rank k used in the SVD (may be less than `rank` if
    /// the corpus has fewer documents or terms than requested).
    public var effectiveRank: Int { svd?.rank ?? 0 }

    // MARK: Basis serialization (mission 6a-i)

    /// 4-byte magic identifying an LSA basis blob ("LSB1").
    static let basisMagic: [UInt8] = Array("LSB1".utf8)

    /// Serialize the finalized LSA basis to a versioned, little-endian blob.
    ///
    /// The LSA basis that determines both query embeddings (fold-in) and
    /// training-document embeddings is the SVD factorization plus the
    /// TF-IDF support state:
    ///   - `rank`, `svdSweeps`, `projectionSeed` — configuration that the
    ///     reconstructed provider reports (and that pins the Engram bucket).
    ///   - vocab (term → index) and `documentCount` — query tokens map to
    ///     vocab positions; documentCount bounds `documentEmbedding(at:)`.
    ///   - `idfWeights` — per-vocab IDF, applied to the query TF-IDF vector.
    ///   - SVD factors `U` (numDocs × k), σ (length k), `Vt` (k × vocabSize),
    ///     and `effectiveRank` — U drives document embeddings, σ + Vt drive
    ///     the query fold-in.
    ///
    /// U, σ, and Vᵀ are PORT-NEUTRAL: serializing the raw factors lets each
    /// port reconstruct its own internal representation (Swift keeps the full
    /// SVDResult; Rust derives its pre-normalised doc_vecs from U·σ). This is
    /// why the same trained state produces a byte-identical blob on both ports.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | rank (u32) |
    ///   svdSweeps (u32) | projectionSeed (u64) | documentCount (u32) |
    ///   effectiveRank (u32) | vocab (String→u32 map) |
    ///   idfWeights ([Float]) | U (matrix) | sigma ([Float]) | Vt (matrix)
    ///
    /// Returns a blob with an empty SVD section if `finalize()` has not been
    /// called (U/sigma/Vt are empty); the round-trip still holds (an
    /// unfinalized provider embeds to zero, and so does its restoration).
    public func serializeBasis() -> Data {
        var w = BasisWriter()
        w.writeMagic(LsaProvider.basisMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU32(UInt32(rank))
        w.writeU32(UInt32(svdSweeps))
        w.writeU64(projectionSeed)
        w.writeU32(UInt32(counts.documentCount))
        w.writeU32(UInt32(svd?.rank ?? 0))
        // persist the REDUCED basis vocab (term → reduced column) —
        // projection keys on it. The full counts vocab is persisted separately
        // by serializeCounts() as the drift-trigger anchor.
        w.writeStringU32Map(basisVocab)
        w.writeFloatArray(idfWeights)
        w.writeFloatMatrix(svd?.U ?? [])
        w.writeFloatArray(svd?.singularValues ?? [])
        w.writeFloatMatrix(svd?.Vt ?? [])
        return w.data
    }

    /// Reconstruct a provider from a serialized LSA basis blob.
    ///
    /// The reconstructed provider's `embed`/`embedFloat`/`documentEmbedding`
    /// output is identical to the original finalized provider's (round-trip
    /// law). Throws `CorpusKitError.decodingFailure` on a truncated blob,
    /// unknown version, or magic mismatch — never crashes.
    public convenience init(deserializing data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(LsaProvider.basisMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let rank = Int(try r.readU32())
        let svdSweeps = Int(try r.readU32())
        let projectionSeed = try r.readU64()
        let documentCount = Int(try r.readU32())
        let effectiveRank = Int(try r.readU32())
        let vocab = try r.readStringU32Map()
        let idfWeights = try r.readFloatArray()
        let U = try r.readFloatMatrix()
        let sigma = try r.readFloatArray()
        let Vt = try r.readFloatMatrix()

        self.init(modelID: modelID,
                  modelVersion: modelVersion,
                  rank: rank,
                  svdSweeps: svdSweeps,
                  projectionSeed: projectionSeed)
        // Restore the term-document support (vocab + doc count) without
        // re-tokenizing; raw TF rows are not embed-relevant.
        // The persisted map IS the reduced basis vocab; projection
        // keys on `basisVocab`. counts is restored from the same map so a
        // reconstructed provider reports the basis vocab it embeds against
        // (round-trip). The FULL vocab lives in the counts blob, not here.
        self.basisVocab = vocab
        self.counts = TermDocumentCounts(restoredVocab: vocab, documentCount: documentCount)
        self.idfWeights = idfWeights
        // An empty SVD section means the source provider was never finalized;
        // leave `svd` nil so the restored provider is also unfinalized.
        if effectiveRank > 0 || !sigma.isEmpty {
            self.svd = SVDResult(U: U, singularValues: sigma, Vt: Vt, rank: effectiveRank)
        }
    }

    // MARK: Counts serialization (incremental-counts change set)

    /// 4-byte magic identifying an LSA COUNTS blob ("LSAC"). Distinct from the
    /// basis magic ("LSB1"): the counts blob persists only the lightweight
    /// trigger anchors — the maintained vocabulary and document count — NOT the
    /// derived SVD basis. LSA's heavy factorization input (the per-document TF
    /// rows) is re-derived by re-tokenizing the corpus at refactor (Bob's
    /// re-tokenize-at-refactor decision), so it is deliberately not persisted
    /// here. The persisted vocab/doc-count let the vocab-growth retrain trigger
    /// read current vocab size cheaply and survive a restart.
    static let countsMagic: [UInt8] = Array("LSAC".utf8)

    /// Serialize the maintained trigger anchors (vocabulary + document count) to
    /// a versioned, little-endian blob. Byte-identical to the Rust
    /// `serialize_counts` (UTF-8-byte-sorted vocab map, fixed field order).
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | documentCount (u32) | vocab (String→u32 map, byte-sorted keys)
    public func serializeCounts() -> Data {
        var w = BasisWriter()
        w.writeMagic(LsaProvider.countsMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeU32(UInt32(counts.documentCount))
        w.writeStringU32Map(counts.vocab)
        return w.data
    }

    /// Restore the maintained vocabulary + document count from a counts blob
    /// into this provider, so incremental maintenance resumes across a restart.
    /// Does not touch the SVD basis (derived separately at refactor). Throws
    /// `CorpusKitError.decodingFailure` on a truncated blob, unknown version, or
    /// magic mismatch — never crashes.
    public func restoreCounts(from data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(LsaProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        _ = try r.readString()  // modelID — header for validation; row is keyed by it
        _ = try r.readString()  // modelVersion
        _ = try r.readU64()     // projectionSeed
        let documentCount = Int(try r.readU32())
        let vocab = try r.readStringU32Map()
        self.counts = TermDocumentCounts(restoredVocab: vocab, documentCount: documentCount)
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

extension LsaProvider: TrainableEmbeddingBasis {

    /// Train the LSA basis on a corpus of raw document texts.
    ///
    /// LSA's training API consumes a raw document per call (`train(document:)`
    /// tokenizes internally via the shared `TermDocumentCounts` builder, which
    /// uses `defaultKeywordTokens`), so each text is passed through unchanged —
    /// one document column per text. The `finalize()` pass then computes the
    /// TF-IDF matrix and runs the deterministic Jacobi SVD. This reproduces the
    /// exact trained+finalized state of per-document `train` + `finalize`, so a
    /// basis serialized after `trainOnCorpus` is byte-identical to the 6a-i
    /// fixture trained on the same texts.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(document: text)
        }
        finalize()
    }

    /// Reconstruct a fresh `LsaProvider` from a serialized basis, type-erased.
    /// Delegates to `init(deserializing:)` (6a-i).
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try LsaProvider(deserializing: basis)
    }

    /// release the in-memory SVD result and weights.
    public func releaseBasis() {
        svd = nil
        idfWeights.removeAll(keepingCapacity: false)
        basisVocab.removeAll(keepingCapacity: false)
    }

    // MARK: Maintained counts (incremental-counts change set, P3)

    /// Fold one chunk's text into the maintained vocabulary + document count.
    /// LSA's accumulation consumes a raw document (`train(document:)` tokenizes
    /// internally via `TermDocumentCounts`), so the text is folded unchanged —
    /// the same per-document step `trainOnCorpus` runs, minus the finalize/SVD.
    /// The per-document TF rows are re-derived by re-tokenizing at refactor
    /// (Bob's re-tokenize-at-refactor decision); what the counts table keeps
    /// current is the vocab + doc-count growth anchor.
    public func addToCounts(text: String) {
        counts.addDocumentForCountsAnchor(text)
    }

    /// Maintained vocabulary size for the growth trigger.
    public var countsVocabularySize: Int { counts.vocabularySize }
}
