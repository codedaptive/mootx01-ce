// PpmiProvider.swift
//
// Positive Pointwise Mutual Information (PPMI) distributional-semantics
// embedding provider.
//
// Implements PPMI-weighted context accumulation producing a fixed-D dense
// vector:
//   1. Each context term gets a sparse ternary index vector in R^D
//      (same seeded-index-vector machinery as RI — same FNV+SplitMix64
//      pipeline, same D, K constants).
//   2. Build term-context co-occurrence counts over a sliding window
//      across the corpus.
//   3. Compute PPMI weights:
//        ppmi(t,c) = max(0, log( P(t,c) / (P(t) * P(c)) ))
//      where:
//        P(t,c) = coCount(t,c) / totalPairs
//        P(t)   = termCount(t) / totalTerms
//        P(c)   = termCount(c) / totalTerms
//   4. A term's embedding = PPMI-weighted sum of context terms' index
//      vectors.  (Contrast RI: RI adds the full index vector for every
//      co-occurrence; PPMI scales each addition by the informative
//      weight, so stopword-like co-occurrences shrink toward zero.)
//   5. A document/query embedding = the L2-normalised sum of its terms'
//      PPMI context vectors.
//
// The PPMI weighting is the whole point.  A term pair that co-occurs
// frequently but whose members also co-occur widely with everything else
// (stopword behaviour) contributes near-zero weight.  A term pair that
// genuinely associates gets full weight.  This is mathematically
// distinct from RI: do not reduce to plain RI by omitting the weight.
//
// ## Constants (documented, cross-port identical)
//
//   D        = 2048   Dimensionality of index/context vectors.
//   K        = 10     Nonzero positions per index vector (sparse ternary).
//   WINDOW   = 4      Co-occurrence window radius (±4 terms).
//
// ## Index vector generation
//
// Identical to RI: seed = FNV.hash64(term.lowercased()),
// rng = SplitMix64(seed), 2*K draws in (pos, sign) pairs.
// Cross-port: the same term produces the same index vector in RI and
// PPMI because the seeding is identical.  This is intentional — the
// index space is shared.  What differs is the weight applied when
// accumulating a context term's index vector into the target term's
// context sum.
//
// ## Projection seed
//
//   PPMI_PROJECTION_SEED = 0x5050_4D49_5F56_314D  ("PPMI_V1M")
//   Model ID = "ppmi-v1",  version = "1.0.0"
//
// The seed MUST differ from RI's riProjectionSeed (0x5249_5F56_315F_4D58)
// so PPMI and RI engrams key to different storage buckets when both
// providers coexist in one estate.
//
// ## PPMI computation detail
//
// Training is a two-phase process:
//   Phase 1 — sliding window pass: count(t,c) and count(t) from the
//              corpus.
//   Phase 2 — PPMI pass: for each (t,c) pair, compute the PPMI weight
//              and accumulate weight * indexVector(c) into the context
//              sum for t.
//
// The PPMI kernel (log ratio) is new code; everything else (index
// vectors, L2 normalisation, FloatSimHash projection) is substrate
// reuse.  Per the substrate mandate: if PPMI needs a primitive the
// substrate lacks, add it to SubstrateKernel (both ports, conformance-
// gated).  For PPMI the log/probability arithmetic is plain Swift
// floating-point on primitives already available; no new substrate
// primitive is required.
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/ppmi.rs
//
// ADR-010 reference: Decision B, signal #3 of the honest fusion.

import Foundation
import CorpusKit
import EngramLib
import SubstrateTypes
import SubstrateKernel
import VectorKit
import SubstrateML

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// Index vectors:  riIndexVector (same FNV+SplitMix64 pipeline as RI)
// FloatVecOps:    SubstrateKernel.FloatVecOps.l2Normalize
// FloatSimHash:   SubstrateML.FloatSimHash.project
// FNV hash:       SubstrateTypes.FNV.hash64
// SplitMix64:     SubstrateML.SplitMix64
//
// All of these are conformance-gated substrate primitives.
// ─────────────────────────────────────────────────────────────────

// MARK: - Constants
//
// All constants are public so the test suite and cross-port conformance
// tests can reference them by name.  The Rust port mirrors these in
// ppmi.rs with the same names and values.

/// Dimensionality of every PPMI index/context vector.
/// Shared with RI: same index space, different accumulation weights.
/// 2048 × 4 bytes = 8 KB per term in the vocab table.
public let ppmiDimension: Int = 2048

/// Number of nonzero ternary (±1) entries in each term's index vector.
/// Shared with RI: 10/2048 ≈ 0.5 % density.
public let ppmiNonzeros: Int = 10

/// Co-occurrence window radius: ±4 terms on each side of the target.
/// Shared with RI for direct comparability of the two methods.
public let ppmiWindow: Int = 4

/// FloatSimHash projection seed for PPMI.  Encodes "PPMI_V1M" in ASCII
/// bytes.  MUST differ from riProjectionSeed so PPMI and RI vectors key
/// to different buckets in a shared VectorStore.
public let ppmiProjectionSeed: UInt64 = 0x5050_4D49_5F56_314D

// MARK: - PpmiProvider

/// PPMI distributional-semantics embedding provider.
///
/// An instance holds per-term PPMI context vectors built from the
/// training corpus.  Training is a two-phase process:
///
///   1. `train(terms:window:)` accumulates raw co-occurrence counts.
///   2. `finalize()` converts counts to PPMI weights and fills the
///      context vector table.  `finalize()` must be called before
///      any `embed` call.
///
/// Once `finalize()` has been called, additional `train` calls are
/// allowed (followed by another `finalize()`) to extend the vocabulary
/// with new documents.
///
/// ## Thread safety
///
/// `PpmiProvider` is `Sendable`.  The count tables are mutated only
/// during training (not concurrency-safe); the PPMI vector table is
/// read-only after `finalize()`.  Callers must complete all training
/// and finalization before concurrent `embed` calls.
///
/// ## Conformance
///
/// Conforms to `VectorKit.EmbeddingProvider`.
/// modelID = "ppmi-v1", modelVersion = "1.0.0".
/// Projection seed = `ppmiProjectionSeed`.
///
/// ADR-010 Decision B, signal #3 — PPMI co-occurrence provider in the
/// dense recall lane.
public final class PpmiProvider: EmbeddingProvider, @unchecked Sendable {

    // MARK: Properties

    public let modelID: String
    public let modelVersion: String

    /// FloatSimHash projection seed.  Fixed to ppmiProjectionSeed.
    private let projectionSeed: UInt64

    // ── Count tables (accumulated during training, cleared after finalize) ──

    /// co-occurrence counts: coCount[t][c] = number of times c appeared
    /// in t's sliding window across all training documents.
    private var coCount: [String: [String: Int]]

    /// marginal term counts: termCount[t] = total number of times t
    /// appeared as a *target* term across all training documents.
    private var termCount: [String: Int]

    /// Total number of (target, context) pairs observed.  This is the
    /// denominator for P(t,c): totalPairs = sum over all (t,c) of
    /// coCount[t][c].
    private var totalPairs: Int

    /// Total number of target-term observations.  This is the denominator
    /// for the marginal probabilities: totalTerms = sum over t of
    /// termCount[t].
    private var totalTerms: Int

    // ── PPMI vectors (filled by finalize, read during embed) ──

    /// PPMI context vectors, keyed by lowercased term.
    /// The vectors are the PPMI-weighted sums of context-term index
    /// vectors.  They are NOT L2-normalised here; normalisation happens
    /// at embed time so that per-term inspection can access the raw
    /// weighted sums.
    private var ppmiVectors: [String: [Float]]

    // MARK: Initialiser

    public init(
        modelID: String = "ppmi-v1",
        modelVersion: String = "1.0.0",
        projectionSeed: UInt64 = ppmiProjectionSeed
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
        self.coCount = [:]
        self.termCount = [:]
        self.totalPairs = 0
        self.totalTerms = 0
        self.ppmiVectors = [:]
    }

    // MARK: Training — Phase 1 (count accumulation)

    /// Accumulate raw co-occurrence counts from a single document.
    ///
    /// For each target term t at position i, every term c in
    /// [i−window, i+window] (excluding i) is a context term.
    /// Increments coCount[t][c] and termCount[t] accordingly.
    ///
    /// Training is additive across multiple calls: each call extends
    /// the count tables without resetting them.  After training all
    /// documents, call `finalize()` to convert counts to PPMI vectors.
    ///
    /// - Parameters:
    ///   - terms: Lowercased, tokenized term sequence for one document.
    ///   - window: Co-occurrence window radius (default: ppmiWindow = 4).
    ///
    /// - Note: Does NOT call Date() — determinism invariant.
    public func train(terms: [String], window: Int = ppmiWindow) {
        for (i, target) in terms.enumerated() {
            let lo = max(0, i - window)
            let hi = min(terms.count - 1, i + window)
            // Guard: a negative `window` makes lo > hi (e.g. window = -5,
            // i = 3 → lo = 8, hi = -2). The closed range lo...hi traps when
            // lo > hi. Skip the context loop entirely — a negative window
            // means "no context", producing no co-occurrence counts but not
            // crashing. Mirrors the identical guard in RandomIndexingProvider.
            if hi < lo { continue }
            for j in lo...hi where j != i {
                let context = terms[j]
                // Increment co-occurrence count.
                if coCount[target] == nil { coCount[target] = [:] }
                coCount[target]![context, default: 0] += 1
                // Increment total pair count.
                totalPairs += 1
            }
            // Increment marginal target-term count for every occurrence
            // (whether or not it had any context — a term at the edge of
            // a short document still counts as a target observation).
            termCount[target, default: 0] += 1
            totalTerms += 1
        }
    }

    // MARK: Training — Phase 2 (PPMI computation)

    /// Convert the accumulated co-occurrence counts to PPMI context vectors.
    ///
    /// Must be called after all `train(terms:window:)` calls and before
    /// any `embed` calls.  Calling `finalize()` is idempotent: a second
    /// call recomputes the PPMI vectors from the current counts (useful
    /// when `train` was called again after the first `finalize`).
    ///
    /// ## PPMI weight formula
    ///
    ///   P(t,c)  = coCount[t][c] / totalPairs
    ///   P(t)    = termCount[t] / totalTerms
    ///   P(c)    = termCount[c] / totalTerms
    ///   ppmi(t,c) = max(0, log( P(t,c) / (P(t) * P(c)) ))
    ///             = max(0, log(P(t,c)) − log(P(t)) − log(P(c)))
    ///
    /// The log is the natural logarithm.  Max(0, ·) clamps negative PMI
    /// to zero (the "positive" in PPMI): co-occurrences below chance are
    /// treated as non-informative, not as anti-associations.
    ///
    /// ## Context vector construction
    ///
    ///   contextVec(t) = sum over c in coCount[t] of
    ///                     ppmi(t,c) * indexVector(c)
    ///
    /// This is the accumulated PPMI-weighted index vector: each context
    /// term's index vector is added with weight = ppmi(t,c).  Context
    /// terms with weight 0 (below-chance or zero-count pairs) contribute
    /// nothing.  Normalisation happens at embed time.
    public func finalize() {
        guard totalPairs > 0, totalTerms > 0 else { return }

        let fTotalPairs = Float(totalPairs)
        let fTotalTerms = Float(totalTerms)

        ppmiVectors = [:]

        for (target, contextCounts) in coCount {
            // Marginal probability for the target term.
            // If termCount has no entry (should not happen since train
            // increments both tables, but guard defensively), skip.
            guard let tc = termCount[target], tc > 0 else { continue }
            let logPt = log(Float(tc) / fTotalTerms)

            var vec = [Float](repeating: 0, count: ppmiDimension)

            for (context, pairCount) in contextCounts {
                guard pairCount > 0 else { continue }
                // Marginal probability for the context term.
                guard let cc = termCount[context], cc > 0 else { continue }
                let logPc = log(Float(cc) / fTotalTerms)

                // Joint probability.
                let logPtc = log(Float(pairCount) / fTotalPairs)

                // PPMI weight: max(0, PMI).
                let pmiVal = logPtc - logPt - logPc
                let weight = max(Float(0), pmiVal)

                // Skip zero-weight context terms: they contribute nothing.
                guard weight > 0 else { continue }

                // Accumulate: weight * indexVector(context).
                // Reuse the RI index vector machinery (FNV + SplitMix64,
                // same constants D=2048, K=10).  The shared index space
                // is intentional: PPMI and RI are comparable because they
                // project into the same coordinate system.
                let idxVec = riIndexVector(term: context)
                for d in 0..<ppmiDimension {
                    vec[d] += weight * idxVec[d]
                }
            }

            // Only store if at least one context term contributed a
            // nonzero weight (sparse PPMI: terms that only co-occur with
            // very common terms may get an all-zero weighted sum).
            let hasNonzero = vec.contains { $0 != 0 }
            if hasNonzero {
                ppmiVectors[target] = vec
            }
        }
    }

    // MARK: EmbeddingProvider

    /// Produce the PPMI distributional embedding for `text`.
    ///
    /// Splits text into keyword tokens, looks up each term's PPMI
    /// context vector (if any), sums them, L2-normalises the result,
    /// and projects through FloatSimHash to produce the 256-bit Engram.
    ///
    /// Empty input or all-OOV input returns Engram.zero (EmbeddingProvider
    /// contract).
    public func embed(_ text: String) async throws -> Engram {
        let v = await ppmiContextVector(for: text)
        guard !v.isEmpty else { return .zero }
        return FloatSimHash.project(vector: v, seed: projectionSeed)
    }

    /// Return the D-dimensional L2-normalised PPMI context vector for `text`.
    ///
    /// This is the honest semantic vector: a point in the PPMI-weighted
    /// index space where terms that genuinely associate dominate.
    /// Stopword-like co-occurrences shrink toward zero because their
    /// PMI is near zero or negative.
    ///
    /// Returns `[]` when the provider has no trained basis (ppmiVectors empty).
    ///
    /// Throws `VectorKitError.embedFloatVocabMiss` when the provider HAS a
    /// trained basis (ppmiVectors non-empty) but all query tokens are OOV —
    /// distinguishing a vocabulary coverage gap from a structural opt-out so
    /// `Corpus.floatNearest` maps to the correct dark-lane reason.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // No trained basis: return [] (structural no-basis → providerOptOut).
        if ppmiVectors.isEmpty { return [] }
        guard !text.isEmpty else { return [] }
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }
        // OOV check: throw embedFloatVocabMiss when the basis is trained but
        // none of the query tokens appear in the PPMI vector table.
        let hasInVocab = terms.contains { ppmiVectors[$0.lowercased()] != nil }
        guard hasInVocab else {
            throw VectorKitError.embedFloatVocabMiss(
                "ppmi: vocab size \(ppmiVectors.count), but 0 of \(terms.count) query token(s) matched"
            )
        }
        return await ppmiContextVector(for: text)
    }

    /// Produce the engram AND the normalised PPMI context vector from a SINGLE
    /// context-vector computation.
    ///
    /// `embed` projects the PPMI context vector and `embedFloat` returns it, so
    /// a caller that needs both would otherwise run `ppmiContextVector(for:)`
    /// twice. This override computes it ONCE and returns both outputs.
    ///
    /// Single-pass equivalent for the common case: the engram is
    /// `FloatSimHash.project` of the vector (or `.zero` when the
    /// vector is empty), and `floats` reproduces `embedFloat`'s result
    /// with its vocab-miss throw collapsed to `[]`. Note: for trained
    /// providers with a non-empty all-OOV query, `embedFloat` throws
    /// `embedFloatVocabMiss` but this override returns `(.zero, [])`;
    /// outputs match for all other inputs. An untrained basis (empty
    /// `ppmiVectors`) yields an empty vector: engram `.zero`, floats `[]`.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        let v = await ppmiContextVector(for: text)
        guard !v.isEmpty else { return (.zero, []) }
        return (FloatSimHash.project(vector: v, seed: projectionSeed), v)
    }

    // MARK: Private helpers

    /// Compute the L2-normalised PPMI context vector for `text`.
    /// Returns `[]` for empty text or when all terms are OOV.
    private func ppmiContextVector(for text: String) async -> [Float] {
        guard !text.isEmpty else { return [] }
        // The single canonical CorpusKit tokenizer — shared by BM25 and every
        // distributional provider (RI/PPMI/LSA/NMF); parity with the Rust port's
        // corpus_kit::default_keyword_tokens.
        let terms = defaultKeywordTokens(text)
        guard !terms.isEmpty else { return [] }

        var sum = [Float](repeating: 0, count: ppmiDimension)
        var hitCount = 0
        for term in terms {
            if let cv = ppmiVectors[term] {
                for d in 0..<ppmiDimension {
                    sum[d] += cv[d]
                }
                hitCount += 1
            }
        }
        guard hitCount > 0 else { return [] }
        // Delegate to the substrate's canonical scalar implementation.
        // FloatVecOps.l2Normalize is conformance-gated against the Rust
        // port; using it here guarantees bit-identical output.
        return FloatVecOps.l2Normalize(sum)
    }

    // MARK: Vocabulary access (for conformance tests)

    /// Return the raw (unnormalised) PPMI context vector for a term, or
    /// nil if the term is OOV or has no nonzero PPMI-weighted context.
    /// Used by conformance tests to verify PPMI accumulation.
    public func ppmiVector(forTerm term: String) -> [Float]? {
        ppmiVectors[term.lowercased()]
    }

    /// The current trained vocabulary size (terms with a PPMI vector).
    public var vocabularySize: Int { ppmiVectors.count }

    /// The number of unique target terms seen during training (before
    /// PPMI filtering).  Useful for tests: `vocabularySize <= trainingVocabSize`.
    public var trainingVocabSize: Int { coCount.count }

    // MARK: Basis serialization (mission 6a-i)

    /// 4-byte magic identifying a PPMI basis blob ("PPB1").
    static let basisMagic: [UInt8] = Array("PPB1".utf8)

    /// Serialize the finalized PPMI basis to a versioned, little-endian blob.
    ///
    /// PPMI's `embed`/`embedFloat` output is fully determined by the
    /// finalized `ppmiVectors` map plus the projection seed. The raw
    /// co-occurrence count tables (`coCount`, `termCount`, totals) are
    /// training-phase scratch and are NOT part of the embed-relevant basis,
    /// so they are intentionally excluded — the round-trip law concerns
    /// embedding identity, which depends only on `ppmiVectors`.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | ppmiVectors (String→[Float] map, sorted keys)
    public func serializeBasis() -> Data {
        var w = BasisWriter()
        w.writeMagic(PpmiProvider.basisMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeStringFloatVectorMap(ppmiVectors)
        return w.data
    }

    /// Reconstruct a provider from a serialized PPMI basis blob.
    ///
    /// The reconstructed provider's `embed`/`embedFloat` output is identical
    /// to the original finalized provider's. The count tables are left empty
    /// (a deserialized provider is read-only for embedding; calling `train`
    /// again then requires a fresh `finalize`). Throws
    /// `CorpusKitError.decodingFailure` on a truncated blob, unknown version,
    /// or magic mismatch — never crashes.
    public convenience init(deserializing data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(PpmiProvider.basisMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let projectionSeed = try r.readU64()
        let ppmiVectors = try r.readStringFloatVectorMap()
        self.init(modelID: modelID, modelVersion: modelVersion, projectionSeed: projectionSeed)
        self.ppmiVectors = ppmiVectors
    }

    // MARK: Counts serialization (incremental-counts change set)

    /// 4-byte magic identifying a PPMI COUNTS blob ("PPMC"). Distinct from the
    /// basis magic ("PPB1"): the counts blob persists the RAW additive
    /// co-occurrence state (the maintained statistics table), not the derived
    /// `ppmiVectors` basis. The two are stored separately — the counts in
    /// `corpus_provider_counts`, the basis in `corpus_provider_basis`.
    static let countsMagic: [UInt8] = Array("PPMC".utf8)

    /// Serialize the raw accumulated co-occurrence counts to a versioned,
    /// little-endian blob, so they can be persisted and incrementally extended
    /// rather than rebuilt from scratch on every reindex. Unlike the basis blob
    /// (which holds only the derived `ppmiVectors`), this is the additive state
    /// `finalize()` consumes — persisting it lets a refactor re-derive
    /// `ppmiVectors` WITHOUT re-tokenizing the corpus.
    ///
    /// Blob layout (after MAGIC + version):
    ///   modelID (string) | modelVersion (string) | projectionSeed (u64)
    ///   | totalPairs (u64) | totalTerms (u64)
    ///   | termCount (String→u32 map, byte-sorted keys)
    ///   | coCount: u32 outer-count, then per byte-sorted outer key:
    ///       outer key (string) | inner (String→u32 map, byte-sorted keys)
    ///
    /// Byte-identical to the Rust `serialize_counts` (cross-port gate): the map
    /// writers sort keys by raw UTF-8 bytes (matching Rust `Ord for str`), and
    /// the outer keys are sorted the same way here.
    public func serializeCounts() -> Data {
        var w = BasisWriter()
        w.writeMagic(PpmiProvider.countsMagic)
        w.writeByte(basisFormatVersion)
        w.writeString(modelID)
        w.writeString(modelVersion)
        w.writeU64(projectionSeed)
        w.writeU64(UInt64(totalPairs))
        w.writeU64(UInt64(totalTerms))
        w.writeStringU32Map(termCount)
        // coCount is a nested map; serialize the outer level inline (the codec
        // has no nested-map primitive) with outer keys sorted by UTF-8 bytes so
        // the order matches Rust's BTreeMap iteration.
        let outerKeys = coCount.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        w.writeU32(UInt32(outerKeys.count))
        for key in outerKeys {
            w.writeString(key)
            w.writeStringU32Map(coCount[key]!)
        }
        return w.data
    }

    /// Reconstruct a provider from a serialized PPMI counts blob, restoring the
    /// raw co-occurrence state ready for incremental extension + `finalize()`.
    /// `ppmiVectors` is left empty (call `finalize()` to derive it). Throws
    /// `CorpusKitError.decodingFailure` on a truncated blob, unknown version, or
    /// magic mismatch — never crashes.
    public convenience init(deserializingCounts data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(PpmiProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        let modelID = try r.readString()
        let modelVersion = try r.readString()
        let projectionSeed = try r.readU64()
        let totalPairs = Int(try r.readU64())
        let totalTerms = Int(try r.readU64())
        let termCount = try r.readStringU32Map()
        let outerCount = Int(try r.readU32())
        var coCount: [String: [String: Int]] = [:]
        coCount.reserveCapacity(outerCount)
        for _ in 0..<outerCount {
            let key = try r.readString()
            coCount[key] = try r.readStringU32Map()
        }
        self.init(modelID: modelID, modelVersion: modelVersion, projectionSeed: projectionSeed)
        self.coCount = coCount
        self.termCount = termCount
        self.totalPairs = totalPairs
        self.totalTerms = totalTerms
    }
}

// MARK: - TrainableEmbeddingBasis (mission 6a-ii-α)

extension PpmiProvider: TrainableEmbeddingBasis {

    /// Train the PPMI basis on a corpus of raw document texts.
    ///
    /// PPMI's training API consumes a term sequence per document, so each text
    /// is tokenized with the canonical `defaultKeywordTokens` and fed to
    /// `train(terms:window:)` at the canonical `ppmiWindow`. PPMI requires the
    /// Phase-2 `finalize()` pass to convert accumulated co-occurrence counts to
    /// PPMI-weighted context vectors; this method runs it once after all
    /// documents are counted. This reproduces the exact trained+finalized state
    /// of `train(terms:)` + `finalize()` driven directly from token arrays, so
    /// a basis serialized after `trainOnCorpus` is byte-identical to the 6a-i
    /// fixture whose corpus is the same texts tokenized.
    public func trainOnCorpus(texts: [String]) {
        for text in texts {
            train(terms: defaultKeywordTokens(text), window: ppmiWindow)
        }
        finalize()
    }

    /// Reconstruct a fresh `PpmiProvider` from a serialized basis, type-erased.
    /// Delegates to `init(deserializing:)` (6a-i).
    public func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        try PpmiProvider(deserializing: basis)
    }

    // MARK: Maintained counts (incremental-counts change set, P3)

    /// Fold one chunk's text into the accumulated co-occurrence counts. PPMI's
    /// accumulation consumes a term sequence, so the text is tokenized with the
    /// canonical `defaultKeywordTokens` and folded at the canonical `ppmiWindow`
    /// — the same per-document step `trainOnCorpus` runs, minus the finalize.
    public func addToCounts(text: String) {
        train(terms: defaultKeywordTokens(text), window: ppmiWindow)
    }

    /// Restore the accumulated co-occurrence counts in place from a counts blob,
    /// so incremental maintenance resumes after a restart. Sets `coCount`,
    /// `termCount`, and the running totals WITHOUT clearing the derived
    /// `ppmiVectors` (the serving basis is restored separately from the basis
    /// blob). Throws `CorpusKitError.decodingFailure` on a bad blob — never
    /// crashes. Mirrors `init(deserializingCounts:)`, but mutates self.
    public func restoreCounts(from data: Data) throws {
        var r = BasisReader(data)
        try r.expectMagic(PpmiProvider.countsMagic)
        try r.expectVersion(basisFormatVersion)
        _ = try r.readString()  // modelID — header for validation; row is keyed by it
        _ = try r.readString()  // modelVersion
        _ = try r.readU64()     // projectionSeed
        let totalPairs = Int(try r.readU64())
        let totalTerms = Int(try r.readU64())
        let termCount = try r.readStringU32Map()
        let outerCount = Int(try r.readU32())
        var coCount: [String: [String: Int]] = [:]
        coCount.reserveCapacity(outerCount)
        for _ in 0..<outerCount {
            let key = try r.readString()
            coCount[key] = try r.readStringU32Map()
        }
        self.coCount = coCount
        self.termCount = termCount
        self.totalPairs = totalPairs
        self.totalTerms = totalTerms
    }

    /// Maintained vocabulary size for the growth trigger: the count of unique
    /// target terms seen during accumulation (before PPMI filtering), which is
    /// the vocabulary the next finalize will derive from.
    public var countsVocabularySize: Int { coCount.count }
}
