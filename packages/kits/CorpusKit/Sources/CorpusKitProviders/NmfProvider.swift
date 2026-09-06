#if MOOTX01_DENSE_FAMILIES
// Dense-family provider — compiled only when the DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See CorpusKit/Package.swift.
// NmfProvider.swift
//
// NMF (Non-Negative Matrix Factorization) distributional-semantics
// embedding provider. Part of the honest semantic fusion honest classical-
// fusion signal set.
//
// ## Algorithm
//
//   1. Build a term-document matrix V (terms × documents) with
//      TF-IDF weighting: tf(t, d) = log(1 + raw_count(t, d)) times the
//      smoothed IDF idf(t) = max(0, log((N+1)/(df+1))). Both factors are
//      non-negative, so V >= 0 as NMF requires; the log-smoothed TF keeps
//      the values bounded and the IDF keeps a term that appears in every
//      document out of the factorization (its column weight is 0), so the
//      latent factors describe what distinguishes documents rather than
//      what they share. CANONICAL tokenizer: CorpusKit.defaultKeywordTokens.
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
//   3. Training-document factor loading: H[:, docIdx] — column docIdx of
//      H, i.e. the k-dim row H[r][docIdx] for r in 0..<k, L2-normalised via
//      FloatVecOps.l2Normalize (`documentEmbedding(at:)`, a raw-factor read
//      for conformance; the product embeds every text through step 4).
//
//   4. Text embedding (documents at index time AND queries at recall time —
//      one function): compute the TF-IDF term vector q (sparse, length
//      vocabSize) with the fitted IDF weights, project into the NMF space
//      via the pseudo-inverse of W:
//        queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
//      (the standard NMF folding-in, analogous to LSA's fold-in via Vᵀ),
//      L2-normalise, remove the component along the unit corpus-mean
//      direction m̂ (`u − (u·m̂) m̂`), and L2-normalise again. OOV terms
//      contribute nothing.
//
//   5. Project to Engram via FloatSimHash.project with `nmfProjectionSeed`.
//
//   The corpus-mean direction is fitted at finalize: every training
//   document's TF-IDF column is folded in through step 4's projection and
//   normalised, the mean of those unit vectors is taken, and m̂ is that
//   mean normalised. Without it the fold-in vectors of long documents all
//   point at the same dominant factor (measured mean pairwise cosine 0.990
//   on a 13,817 drawer estate); with it, cosine measures what differs.
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
// ## TF-IDF weighting (non-negative, per NMF requirement)
//
//   tf(t, d)   = log(1 + raw_count(t, d))         — log-smoothed, >= 0
//   idf(t)     = max(0, log((N + 1) / (df(t) + 1))) — the one shared IDF
//   V[t][d]    = tf(t, d) * idf(t)                 — >= 0
//
//   The same idf(t) weights the query vector, so documents and queries are
//   projected through W from the same weighting the factorization saw.
//
// ## Constants
//
//   NMF_PROJECTION_SEED = 0x4E4D465F56315F4D  ("NMF_V1_M" in ASCII)
//   Model ID = "nmf-v1",  version = "1.1.0"
//   Default rank k = 32
//   Default maxIterations = 100
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/nmf_provider.rs
//
// honest semantic fusion reference: Decision B signal set — NMF latent-factor provider.

import Foundation
import CorpusKit
import EngramLib
import SubstrateTypes
// SubstrateKernel: FloatVecOps.l2Normalize (canonical conformance-gated).
import SubstrateKernel
// SubstrateML: NMFAlternatingLeastSquares (reused, deterministic via
// tolerance=0), FloatSimHash.project (canonical projection to Engram).
import SubstrateML
import SynapseKit

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
/// Conforms to `SynapseKit.EmbeddingProvider`.
/// modelID = "nmf-v1", modelVersion = "1.1.0".
/// Projection seed = `nmfProjectionSeed`.
///
/// — NMF latent-factor provider in the classical-
/// fusion dense recall lane.
public final class NmfProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// NMF rank k (latent dimensionality).
    public let rank: Int

    /// Reduced-vocabulary cap K for the dense factorization. NMF
    /// factors a `K × numDocs` matrix over the top-K informative terms instead
    /// of `full-vocab × numDocs`. Optimizer knob; default `defaultReducedVocabCap`.
    public let reducedVocabCap: Int

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

    /// Per-document factor loadings (H column per doc), populated at finalize().
    /// docEmbeddings[d] = L2-normalised H[:, d] of length effectiveRank.
    private var docEmbeddings: [[Float]]

    /// Smoothed IDF per REDUCED vocabulary column, fitted at `finalize()`.
    /// Weights both the factorized matrix V and every folded-in text.
    private var idfWeights: [Float]

    /// Unit corpus-mean direction in the k-dim fold-in space, fitted at
    /// `finalize()` from the training documents, or empty when no document
    /// folded in. Removed from every embedded text.
    private var meanDirection: [Float]

    /// The frozen reduced vocabulary (term → reduced row) the basis was trained
    /// on. Query projection and basis serialization key on THIS, not
    /// the full `counts.vocab`. Empty until `finalize()`.
    private var basisVocab: [String: Int]

    // MARK: Initialiser

    public init(
        modelID: String = "nmf-v1",
        modelVersion: String = "1.1.0",
        rank: Int = nmfDefaultRank,
        maxIterations: Int = nmfDefaultIterations,
        seed: UInt64 = nmfFactorizationSeed,
        projectionSeed: UInt64 = nmfProjectionSeed,
        reducedVocabCap: Int = defaultReducedVocabCap
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.rank = max(1, rank)
        self.reducedVocabCap = max(1, reducedVocabCap)
        self.maxIterations = max(1, maxIterations)
        self.seed = seed
        self.projectionSeed = projectionSeed
        self.counts = TermDocumentCounts()
        self.nmf = nil
        self.docEmbeddings = []
        self.idfWeights = []
        self.meanDirection = []
        self.basisVocab = [:]
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
    /// V[i][j] = log(1 + tf[j][i]) * idf(i)  — i is the term, j is the document.
    ///
    /// ## Fixed iteration count
    ///
    /// tolerance=0 disables convergence-stopping so every factorization runs
    /// exactly `maxIterations` iterations. This is the deterministic path
    /// required for bit-identical cross-port output.
    public func finalize() {
        let numDocs = counts.documentCount
        guard numDocs > 0, counts.vocabularySize > 0 else { return }

        // factor over a reduced, informative sub-vocabulary so the
        // dense NMF is `K × numDocs` (feasible) instead of `full-vocab × numDocs`
        // (infeasible). The reduced vocab is a corpus property shared with LSA;
        // it is frozen here and drives query projection. `vocabSize` below is the
        // REDUCED row count — the factorization + fold-in below key on it.
        let reduced = selectReducedVocabulary(
            vocab: counts.vocab,
            dfCounts: counts.dfCounts,
            documentCount: numDocs,
            cap: reducedVocabCap
        )
        basisVocab = reduced.termToColumn
        let vocabSize = reduced.size
        guard vocabSize > 0 else {
            nmf = nil; docEmbeddings = []; idfWeights = []; meanDirection = []; return
        }

        // IDF over REDUCED rows, using the full-corpus df (informativeness is
        // corpus-wide) through the one shared smoothed IDF.
        idfWeights = [Float](repeating: 0, count: vocabSize)
        for (fullIdx, row) in reduced.fullIndexToColumn {
            idfWeights[row] = smoothedInverseDocumentFrequency(
                documentFrequency: counts.dfCounts[fullIdx] ?? 0, documentCount: numDocs)
        }

        // V is K × numDocs: V[reducedRow][doc] = log(1 + tf[doc][term]) * idf.
        // Map each doc's TF entries whose term is in the reduced vocab to its
        // reduced row; full-vocab terms outside the reduced set are dropped.
        var V: [[Float]] = [[Float]](
            repeating: [Float](repeating: 0, count: numDocs),
            count: vocabSize
        )
        for (docIdx, docTF) in counts.tfCounts.enumerated() {
            for (fullIdx, count) in docTF {
                guard let row = reduced.fullIndexToColumn[fullIdx] else { continue }
                V[row][docIdx] = log(1 + Float(count)) * idfWeights[row]
            }
        }

        // Effective rank: min(requestedRank, min(K, numDocs)).
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

        // Pre-compute document factor loadings: column d of H = H[r][d] for r
        // in 0..<k. L2-normalise via the substrate's conformance-gated primitive.
        guard let result = nmf else { return }
        let k = result.rank
        docEmbeddings = (0..<numDocs).map { d in
            let col: [Float] = (0..<k).map { r in result.H[r][d] }
            let normalised = FloatVecOps.l2Normalize(col)
            return normalised
        }

        // Corpus-mean direction: fold every training document's TF-IDF column
        // through the SAME projection texts use, average the unit vectors,
        // normalise. Documents that fold to nothing (all-zero column) are skipped.
        var meanSum = [Float](repeating: 0, count: k)
        var folded = 0
        for d in 0..<numDocs {
            let column: [Float] = (0..<vocabSize).map { i in V[i][d] }
            guard let unit = foldInUnit(column, factorization: result) else { continue }
            for r in 0..<k { meanSum[r] += unit[r] }
            folded += 1
        }
        if folded > 0 {
            let divisor = Float(folded)
            let mean = meanSum.map { $0 / divisor }
            let unit = FloatVecOps.l2Normalize(mean)
            meanDirection = unit.contains { $0 != 0 } ? unit : []
        } else {
            meanDirection = []
        }
    }

    // MARK: EmbeddingProvider

    /// Return the k-dimensional NMF embedding for `text`.
    ///
    /// Uses the folding-in formula: project the TF-IDF vector of the text
    /// through W columns via the pseudo-inverse, then centre and normalise.
    ///
    /// Returns Engram.zero if finalize() not called or all terms are OOV.
    public func embed(_ text: String) async throws -> Engram {
        guard let v = nmfVector(for: text), !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the k-dimensional L2-normalised NMF float vector for `text`.
    ///
    /// Returns `[]` when finalize() has not been called (no basis).
    ///
    /// Throws `SynapseKitError.embedFloatVocabMiss` when the provider HAS a
    /// finalized basis and non-empty vocabulary, but all query tokens are
    /// OOV — distinguishing a vocabulary coverage gap from a structural
    /// opt-out so `Corpus.floatNearest` maps to the correct dark-lane reason.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // No finalized basis: return [] (structural no-basis → providerOptOut).
        guard nmf != nil, !basisVocab.isEmpty else { return [] }
        guard !text.isEmpty else { return [] }
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }
        // OOV check before full projection: throw embedFloatVocabMiss when the
        // basis is trained but none of the query tokens hit the reduced vocab.
        let hasInVocab = terms.contains { basisVocab[$0] != nil }
        guard hasInVocab else {
            throw SynapseKitError.embedFloatVocabMiss(
                "nmf: reduced vocab size \(basisVocab.count), but 0 of \(terms.count) query token(s) matched"
            )
        }
        return nmfVector(for: text) ?? []
    }

    /// Single-pass override: compute the NMF fold-in vector ONCE and return both
    /// the projected Engram and the float vector, deduping the double pass that
    /// `embed(_:)` + `embedFloat(_:)` would otherwise run. `nmfVector(for:)` is
    /// deterministic; a non-nil vector v projects to the same Engram and is
    /// returned as the float lane; a nil result (no basis, empty/non-tokenisable
    /// input, all-OOV, or a degenerate all-zero fold-in) yields `(.zero, [])`.
    /// This override calls `nmfVector(for:)` directly and never invokes the
    /// default `embedPair` — the all-OOV `embedFloatVocabMiss` path is bypassed
    /// here, not by the default `try?` collapse.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        guard let v = nmfVector(for: text), !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the NMF embedding vector for `text` — the one function for
    /// documents and queries.
    ///
    /// Builds the TF-IDF vector q of the text over the reduced vocabulary
    /// (`log(1 + count) * idf`, the training matrix's weighting), folds it in
    /// through `foldInUnit`, removes the component along the fitted
    /// corpus-mean direction, and L2-normalises.
    ///
    /// Returns nil when:
    ///   - finalize() not called
    ///   - text is empty
    ///   - all tokens are OOV
    ///   - the projection or the centred vector collapses to zero
    private func nmfVector(for text: String) -> [Float]? {
        guard let result = nmf else { return nil }
        guard !text.isEmpty else { return nil }

        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return nil }

        // Query projection keys on the REDUCED basis vocab. Reduced-set
        // terms map to their row; OOV terms (outside top-K) contribute nothing
        // and are covered by RI.
        let vocabSize = basisVocab.count

        // Build the sparse TF query vector.
        var hasInVocab = false
        var rawCounts: [Int: Int] = [:]
        for term in terms {
            if let idx = basisVocab[term] {
                rawCounts[idx, default: 0] += 1
                hasInVocab = true
            }
        }
        guard hasInVocab else { return nil }

        // TF-IDF weights: log(1 + count) * idf, same as the training matrix.
        var q: [Float] = [Float](repeating: 0, count: vocabSize)
        for (termIdx, count) in rawCounts {
            q[termIdx] = log(1 + Float(count)) * (termIdx < idfWeights.count ? idfWeights[termIdx] : 0)
        }

        guard let unit = foldInUnit(q, factorization: result) else { return nil }
        let centred = DistributionalPooling.removeMeanDirection(from: unit, meanDirection: meanDirection)
        let normalised = FloatVecOps.l2Normalize(centred)
        let allZero = normalised.allSatisfy { $0 == 0 }
        return allZero ? nil : normalised
    }

    /// Fold a TF-IDF vector `q` (length vocabSize) into the NMF space and
    /// L2-normalise:
    ///   queryVec[r] = dot(W[:, r], q) / (||W[:, r]||^2 + eps)
    ///
    /// This is the pseudo-inverse projection of q onto each latent factor
    /// column of W. Analogous to LSA fold-in (Σ^{-1} Vᵀ q). Shared by the
    /// text path and the corpus-mean fit so both see the same projection.
    /// Returns nil when the projection is all-zero.
    private func foldInUnit(_ q: [Float], factorization result: NMFFactorization) -> [Float]? {
        let k = result.rank
        let vocabSize = q.count
        let eps: Float = 1e-9
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

    // MARK: Document factor loadings (training documents)

    /// Return the k-dimensional NMF factor loading of training document
    /// `docIdx`: the L2-normalised column docIdx of H (pre-computed at
    /// finalize()). A raw-factor read for conformance; the product embeds
    /// every text — documents included — through `embedFloat`/`embedPair`.
    /// Only valid after finalize().
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

    /// The fitted unit corpus-mean direction in the fold-in space (k long),
    /// or empty when the basis is not finalized or no document folded in.
    /// Conformance-test accessor.
    public var corpusMeanDirection: [Float] { meanDirection }

    // MARK: Basis serialization

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
    ///     `effectiveRank`. W drives the fold-in; H drives the document
    ///     factor loadings. Both are PORT-NEUTRAL raw factors, so the same
    ///     trained state produces a byte-identical blob on both ports.
    ///   - `idfWeights` (per reduced column) and `meanDirection` (k long) —
    ///     the pooling fit every embedded text is weighted and centred by.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | rank (u32) |
    ///   maxIterations (u32) | seed (u64) | projectionSeed (u64) |
    ///   documentCount (u32) | effectiveRank (u32) | vocab (String→u32 map) |
    ///   W (matrix) | H (matrix) | idfWeights ([Float]) | meanDirection ([Float])
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
        // persist the REDUCED basis vocab (term → reduced row) —
        // projection keys on it. The full counts vocab is persisted separately
        // by serializeCounts() as the drift-trigger anchor.
        w.writeStringU32Map(basisVocab)
        w.writeFloatMatrix(nmf?.W ?? [])
        w.writeFloatMatrix(nmf?.H ?? [])
        w.writeFloatArray(idfWeights)
        w.writeFloatArray(meanDirection)
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
        let idf = try r.readFloatArray()
        let mean = try r.readFloatArray()

        self.init(modelID: modelID,
                  modelVersion: modelVersion,
                  rank: rank,
                  maxIterations: maxIterations,
                  seed: seed,
                  projectionSeed: projectionSeed)
        // The persisted map IS the reduced basis vocab; projection
        // keys on `basisVocab`. counts is restored from the same map so a
        // reconstructed provider reports the basis vocab it embeds against
        // (round-trip). The FULL vocab lives in the counts blob, not here.
        self.basisVocab = vocab
        self.counts = TermDocumentCounts(restoredVocab: vocab, documentCount: documentCount)
        self.idfWeights = idf
        self.meanDirection = mean

        // An empty factor section means the source provider was never
        // finalized; leave `nmf` nil so the restored provider is unfinalized.
        guard effectiveRank > 0 || !W.isEmpty else { return }
        // Reconstruct the factorization. `iterations` and `finalError` are not
        // embed-relevant (embedding reads only W/H), so they carry the
        // configured iteration count and a zero error placeholder.
        self.nmf = NMFFactorization(W: W, H: H, rank: effectiveRank,
                                    iterations: maxIterations, finalError: 0)
        // Re-derive the per-document factor loadings exactly as finalize()
        // does: L2-normalised column d of H.
        let numDocs = documentCount
        self.docEmbeddings = (0..<numDocs).map { d in
            let col: [Float] = (0..<effectiveRank).map { rr in H[rr][d] }
            return FloatVecOps.l2Normalize(col)
        }
    }

    // MARK: Counts serialization (incremental-counts change set)

    /// 4-byte magic identifying an NMF COUNTS blob ("NMFC"). Distinct from the
    /// basis magic: the counts blob persists only the lightweight trigger
    /// anchors (vocabulary + document count), NOT the derived W/H factors. NMF's
    /// heavy factorization input (the per-document TF rows) is re-derived by
    /// re-tokenizing the corpus at refactor, so it is not persisted here.
    static let countsMagic: [UInt8] = Array("NMFC".utf8)

    /// Serialize the maintained trigger anchors (vocabulary + document count).
    /// Byte-identical to the Rust `serialize_counts` (UTF-8-byte-sorted vocab
    /// map, fixed field order).
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | documentCount (u32) | vocab (String→u32 map, byte-sorted keys)
    public func serializeCounts() -> Data {
        var w = BasisWriter()
        w.writeMagic(NmfProvider.countsMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeU32(UInt32(counts.documentCount))
        w.writeStringU32Map(counts.vocab)
        return w.data
    }

    /// Restore the maintained vocabulary + document count from a counts blob
    /// into this provider. Does not touch the W/H factors (derived at refactor).
    /// Throws `CorpusKitError.decodingFailure` on a truncated/unknown/mismatched
    /// blob — never crashes.
    public func restoreCounts(from data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(NmfProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        _ = try r.readString()  // modelID — header for validation; row is keyed by it
        _ = try r.readString()  // modelVersion
        _ = try r.readU64()     // projectionSeed
        let documentCount = Int(try r.readU32())
        let vocab = try r.readStringU32Map()
        self.counts = TermDocumentCounts(restoredVocab: vocab, documentCount: documentCount)
    }
}

// MARK: - TrainableEmbeddingBasis

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
    /// `trainOnCorpus` is byte-identical to the shared fixture trained on the
    /// same texts.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(document: text)
        }
        finalize()
    }

    /// Streamed-training page: the same per-document accumulation
    /// `trainOnCorpus` runs, finalization deferred to `finalizeTraining`.
    public func accumulateTraining(texts: [String]) {
        for text in texts {
            train(document: text)
        }
    }

    public func finalizeTraining() {
        finalize()
    }

    /// Reconstruct a fresh `NmfProvider` from a serialized basis, type-erased.
    /// Delegates to `init(deserializing:)`.
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try NmfProvider(deserializing: basis)
    }

    /// Release the in-memory NMF factorization, factor loadings, and pooling fit.
    public func releaseBasis() {
        nmf = nil
        docEmbeddings.removeAll(keepingCapacity: false)
        basisVocab.removeAll(keepingCapacity: false)
        idfWeights.removeAll(keepingCapacity: false)
        meanDirection.removeAll(keepingCapacity: false)
    }

    // MARK: Maintained counts (incremental-counts change set, P3)

    /// Fold one chunk's text into the maintained vocabulary + document count.
    /// NMF's accumulation consumes a raw document (`train(document:)` tokenizes
    /// internally via `TermDocumentCounts`), so the text is folded unchanged —
    /// the same per-document step `trainOnCorpus` runs, minus the finalize/NMF.
    /// Per-document TF rows are re-derived by re-tokenizing at refactor (Bob's
    /// re-tokenize-at-refactor decision); the table keeps the vocab + doc-count
    /// growth anchor current.
    public func addToCounts(text: String) {
        counts.addDocumentForCountsAnchor(text)
    }

    /// NMF's counts blob holds only vocabulary and documentCount trigger anchors —
    /// NOT the per-document TF rows the NMF factorization requires. `finalize()`
    /// needs the full per-document TF matrix, which is re-derived by re-tokenizing
    /// the corpus at refactor time (open design decision: re-tokenize at refactor).
    /// No counts-only basis derivation is possible; this method makes no state
    /// change and returns `false`.
    ///
    /// This explicit override documents at-site why NMF cannot support
    /// counts-only refactoring, rather than relying silently on the protocol
    /// default. The caller must keep the corpus re-tokenization path.
    public func finalizeFromCounts() -> Bool { false }

    /// Maintained vocabulary size for the growth trigger.
    public var countsVocabularySize: Int { counts.vocabularySize }

    public func countsContainsTerm(_ term: String) -> Bool {
        counts.vocab[term] != nil
    }
}

#endif // MOOTX01_DENSE_FAMILIES
