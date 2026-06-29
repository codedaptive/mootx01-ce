// BM25Weighting.swift
//
// BM25 as one impact weighting for the InvertedIndex.
//
// Lane D — BM25 collapse into the generalized weighted-impact framework.
// Retrieval algorithms reference §2.6 is the authoritative spec.
//
// Design contract (§2.6):
// - BM25 score(d) = Σ_{t ∈ Q} IDF(t) · f(t,d)·(k1+1) / (f(t,d) + k1·(1−b+b·|d|/avgdl))
// - The per-term, per-document contribution is quantized once at index build time
//   with round-half-to-even at QUANT_SCALE=100 (§2.2). Never recomputed at query time.
// - query_weight = QUANT_SCALE (100) for each query term (standard BM25).
// - IDF formula: ln((N − df(t) + 0.5) / (df(t) + 0.5) + 1) — same formula as the
//   existing BM25Index.swift implementation.
//
// Refactoring note:
//   BM25Index.swift is refactored to call BM25Weighting.build(...) instead
//   of implementing its own scoring. The resulting InvertedIndex is stored
//   inside BM25Index and used for topK queries. The original
//   float-at-query-time path is replaced by the integer-only WAND path.
//   This preserves the public API of BM25Index (same signature for topK /
//   index / remove / documentCount) while routing through the new engine.
//
// Parity: Rust twin in CorpusKit/rust/src/engine/bm25_weighting.rs.

import Foundation

/// BM25 hyperparameters. Defaults follow Robertson-Sparck Jones recommendations.
public struct BM25Parameters: Sendable, Equatable {
    /// Term frequency saturation constant. Default: 1.5.
    public var k1: Double
    /// Length normalization constant. Default: 0.75.
    public var b: Double

    public init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }
}

// MARK: - Fixed-point quantization

/// Round-half-to-even (banker's rounding) as required by retrieval algorithms
/// reference §2.2. Swift's standard rounding rounds half-away-from-zero
/// (`.toNearestOrAwayFromZero`), which differs at the .5 boundary. We pin
/// `.toNearestOrEven` for cross-language bit-identity.
///
/// - Parameter value: the float64 value to quantize.
/// - Returns: `round_half_even(value * QUANT_SCALE)` as Int32.
public func quantizeImpact(_ value: Double) -> Int32 {
    let scaled = value * Double(invertedIndexQuantScale)
    // Foundation's Decimal or manual banker's rounding.
    let rounded = scaled.rounded(.toNearestOrEven)
    let clamped = max(Double(Int32.min), min(Double(Int32.max), rounded))
    return Int32(clamped)
}

// MARK: - BM25Weighting

/// BM25 as an impact weighting scheme for `InvertedIndex`.
///
/// Computes per-posting quantized impacts from raw term frequencies and
/// document lengths, then hands the result to `InvertedIndex` for WAND / BMW
/// top-k retrieval. The float BM25 math happens exactly once at build time;
/// the query path is pure integer thereafter (§2.6 determinism caveat).
///
/// `build()` returns an `InvertedIndex` with BM25-weighted impacts and the
/// required `query_weight` for each query term (= QUANT_SCALE = 100). To
/// query this index with BM25 semantics, use `queryWeight = invertedIndexQuantScale`
/// for every query term.
public enum BM25Weighting {

    // MARK: - Term frequency table

    /// Term → doc_id → frequency table, as consumed by BM25 impact computation.
    public typealias TermFreqTable = [String: [String: Int]]

    // MARK: - Term ID mapping

    /// Convert a TermFreqTable (String term IDs) to UInt32 term IDs with a stable
    /// mapping. Returns the mapping so callers can map query terms to the same IDs.
    public static func buildTermIDMap(
        from table: TermFreqTable
    ) -> (mapping: [String: UInt32], reverseMapping: [UInt32: String]) {
        // Stable assignment: sort terms for reproducibility across runs.
        let sortedTerms = table.keys.sorted()
        var mapping = [String: UInt32](minimumCapacity: sortedTerms.count)
        var reverseMapping = [UInt32: String](minimumCapacity: sortedTerms.count)
        for (idx, term) in sortedTerms.enumerated() {
            let id = UInt32(idx)
            mapping[term] = id
            reverseMapping[id] = term
        }
        return (mapping, reverseMapping)
    }

    // MARK: - Build

    /// Build an `InvertedIndex` from BM25-weighted impacts.
    ///
    /// Float BM25 math is performed once here; the output index is integer-only.
    ///
    /// - Parameters:
    ///   - termFreqs: term → (itemID → term frequency). itemIDs are typically chunk UUID strings.
    ///   - docLengths: itemID → document length in tokens.
    ///   - parameters: BM25 k1, b.
    ///   - termMapping: pre-existing term→UInt32 mapping (or nil to derive one here).
    ///     Pass nil on first build; pass the existing mapping when updating incrementally.
    /// - Returns: Built `InvertedIndex` and the term→UInt32 mapping used.
    public static func build(
        termFreqs: TermFreqTable,
        docLengths: [String: Int],
        parameters: BM25Parameters = BM25Parameters()
    ) -> (index: InvertedIndex, termMapping: [String: UInt32]) {
        let numDocs = docLengths.count
        guard numDocs > 0 else {
            return (InvertedIndex(postings: [:], numDocs: 0), [:])
        }

        // Compute avgdl (average document length).
        let totalLen = docLengths.values.reduce(0, +)
        let avgdl = Double(totalLen) / Double(numDocs)

        // Build term ID mapping (stable sort order).
        let (termMapping, _) = buildTermIDMap(from: termFreqs)

        // Compute per-posting quantized impacts.
        var postings = [UInt32: [ImpactPosting]](minimumCapacity: termFreqs.count)
        for (term, docTFs) in termFreqs {
            guard let termID = termMapping[term] else { continue }
            let df = Double(docTFs.count)
            // IDF: ln((N - df + 0.5) / (df + 0.5) + 1). Same as existing BM25Index.swift.
            let idf = log(1.0 + (Double(numDocs) - df + 0.5) / (df + 0.5))

            var termPostings = [ImpactPosting]()
            termPostings.reserveCapacity(docTFs.count)
            for (itemID, tf) in docTFs {
                let dl = Double(docLengths[itemID] ?? 0)
                // BM25 per-term contribution (§2.6):
                // impact(t,d) = IDF(t) · tf·(k1+1) / (tf + k1·(1 − b + b·|d|/avgdl))
                let denom = Double(tf) + parameters.k1 * (1.0 - parameters.b + parameters.b * dl / max(avgdl, 1.0))
                let rawImpact = idf * (Double(tf) * (parameters.k1 + 1.0)) / max(denom, 0.0001)
                let quantizedImpact = quantizeImpact(rawImpact)
                termPostings.append(ImpactPosting(itemID: itemID, impact: quantizedImpact))
            }
            postings[termID] = termPostings
        }

        let index = InvertedIndex(postings: postings, numDocs: numDocs)
        return (index, termMapping)
    }

    // MARK: - Query preparation

    /// Prepare a BM25 query: map query term strings to (termID, queryWeight) pairs.
    ///
    /// BM25 query_weight is QUANT_SCALE (100) per term (§2.6: "query_weight(t) = quantize(1.0) = QUANT_SCALE").
    /// Terms not present in the term mapping are silently dropped (not in the index corpus).
    ///
    /// - Parameters:
    ///   - queryTerms: tokenized query term strings.
    ///   - termMapping: the term→UInt32 mapping returned by `build(...)`.
    /// - Returns: array of (termID, queryWeight) ready for `InvertedIndex.topK(query:k:)`.
    public static func queryPairs(
        queryTerms: [String],
        termMapping: [String: UInt32]
    ) -> [(termID: UInt32, queryWeight: Int32)] {
        var result = [(termID: UInt32, queryWeight: Int32)]()
        result.reserveCapacity(queryTerms.count)
        var seen = Set<UInt32>()
        for term in queryTerms {
            guard let termID = termMapping[term], !seen.contains(termID) else { continue }
            seen.insert(termID)
            result.append((termID: termID, queryWeight: invertedIndexQuantScale))
        }
        return result
    }
}
