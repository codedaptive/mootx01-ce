// LsaProvider.swift
//
// Latent Semantic Analysis (LSA / LSI) distributional-semantics
// embedding provider. Part 2 of the ADR-010 Decision B honest
// classical-fusion signal set.
//
// ## Algorithm
//
//   1. Build a term-document matrix M (terms × documents) with
//      TF-IDF weighting (term frequency scaled by inverse document
//      frequency log((N+1)/(df+1)), clamped to >= 0).
//      CANONICAL tokenizer: CorpusKit.defaultKeywordTokens.
//
//   2. Run JacobiSVD.decompose on Mᵀ (documents × terms) with the
//      requested rank k:
//        Mᵀ ≈ U · diag(Σ) · Vᵀ
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
// ADR-010 reference: Decision B, signal #1 (LSA/SVD) of the honest
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
/// ADR-010 Decision B, signal #1 — LSA/SVD provider in the classical-
/// fusion dense recall lane.
public final class LsaProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// Requested LSA rank k.
    public let rank: Int

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

    /// IDF weights, indexed by vocabulary position.
    private var idfWeights: [Float]

    // MARK: Initialiser

    public init(
        modelID: String = "lsa-v1",
        modelVersion: String = "1.0.0",
        rank: Int = lsaDefaultRank,
        svdSweeps: Int = 30,
        projectionSeed: UInt64 = lsaProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.rank = max(1, rank)
        self.svdSweeps = max(0, svdSweeps)
        self.projectionSeed = projectionSeed
        self.counts = TermDocumentCounts()
        self.idfWeights = []
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
        let vocabSize = counts.vocabularySize
        guard N > 0, vocabSize > 0 else { return }

        // Compute IDF weights indexed by vocabulary position.
        // idfWeights[j] = log((N+1) / (dfCounts[j]+1))
        // Natural log: matches Rust's f32::ln().
        idfWeights = [Float](repeating: 0, count: vocabSize)
        for (termIdx, df) in counts.dfCounts {
            let idf = log(Float(N + 1) / Float(df + 1))
            idfWeights[termIdx] = max(0, idf)  // clamp to 0 (always ≥ 0 with add-1 smoothing)
        }

        // Build the TF-IDF matrix M (numDocs × vocabSize, row-major).
        // M[i][j] = log(1 + tf[i][j]) * idfWeights[j]
        var M: [[Float]] = [[Float]](repeating: [Float](repeating: 0, count: vocabSize), count: N)
        for (docIdx, docTF) in counts.tfCounts.enumerated() {
            for (termIdx, count) in docTF {
                let tf = log(1 + Float(count))
                let tfidf = tf * idfWeights[termIdx]
                M[docIdx][termIdx] = tfidf
            }
        }

        // Determine effective rank: min(requestedRank, min(numDocs, vocabSize)).
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
    /// Returns `[]` if finalize() has not been called or all terms are OOV.
    public func embedFloat(_ text: String) async throws -> [Float] {
        return lsaVector(for: text) ?? []
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
        let vocabSize = counts.vocabularySize

        // Compute the TF-IDF vector for the query text.
        // tf(t) = log(1 + raw_count(t)) * idf(t)
        // Terms not in vocab are OOV and contribute nothing.
        var rawCounts: [Int: Int] = [:]
        var hasInVocab = false
        for term in terms {
            if let idx = counts.vocab[term] {
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
}
