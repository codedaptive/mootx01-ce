// DistributionalPooling.swift
//
// The ONE pooling function that turns a bag of terms into a unit document
// vector for the sparse-index distributional families (Random Indexing and
// PPMI). Documents at index time and queries at recall time go through this
// same function, so the two sides of a cosine comparison are built the same
// way — a document's own opening sentence lands on the document.
//
// ## Why weighting and centring are both required
//
// A plain sum of every token's context vector is dominated by the terms
// that appear in most documents: their context vectors are the largest (they
// co-occur with everything) and they occur in every long text. Every
// document therefore points at one shared direction — the corpus mean — and
// pairwise cosines sit near 1 regardless of content. Measured on a 13,817
// drawer estate: mean pairwise cosine 0.999 (RI), 0.955 (PPMI). Two fixes,
// each necessary:
//
//   1. IDF weighting shrinks the contribution of a term that appears in many
//      documents (a term in every document weighs exactly 0), so the sum is
//      carried by the terms that distinguish this document.
//   2. Mean-direction removal subtracts whatever shared component survives
//      the weighting. It is a projection, `u − (u·m̂) m̂`, not a translation:
//      the unit vector `u` loses only its component along the unit corpus
//      mean `m̂`, so the operation is scale-free (a long document and a short
//      query are treated identically) and needs only the DIRECTION of the
//      corpus mean.
//
// ## The pooling function
//
//   pool(terms):
//     1. distinct(terms), ordered by UTF-8 bytes — the result is a set
//        function of the bag: token order and repetition never change it,
//        and the float accumulation order is identical on both ports.
//     2. raw = Σ idf(t) · vector(t) over the distinct terms that have a
//        vector (an OOV term contributes nothing; a term whose idf is 0
//        contributes nothing).
//     3. u = l2Normalize(raw)
//     4. v = u − (u · m̂) m̂
//     5. result = l2Normalize(v); an all-zero result is "no signal" (nil).
//
// ## The corpus-mean direction
//
//   m = Σ_t df(t) · idf(t) · vector(t), keys in UTF-8 order;  m̂ = l2Normalize(m)
//
// Under the binary term weighting the pooling function uses (each distinct
// term counted once per document), Σ_d raw_d = Σ_t df(t)·idf(t)·vector(t)
// exactly, so m̂ IS the direction of the mean raw document vector — and it is
// a closed form over the maintained counts (df, N) and the vector table.
// That closed form is what lets the counts path (restore counts → finalize)
// produce a basis byte-identical to the corpus path: no second pass over the
// documents is needed to fit the mean.
//
// Rust port: packages/kits/CorpusKit/rust-providers/src/distributional_pooling.rs

import Foundation
// SubstrateKernel: FloatVecOps.l2Normalize / FloatVecOps.dot are the
// canonical scalar implementations, conformance-gated against the Rust port.
import SubstrateKernel

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// L2 normalisation and the dot product come from SubstrateKernel.FloatVecOps.
// Only the composition (weighted sum, projection removal) lives here.
// ─────────────────────────────────────────────────────────────────

/// Shared pooling for the term-vector distributional providers (RI, PPMI).
public enum DistributionalPooling {

    /// Pool a bag of terms into a unit vector — the same function for a
    /// document and for a query.
    ///
    /// - Parameters:
    ///   - terms: the keyword tokens of the text (order and repetition are
    ///     irrelevant — the function reduces them to a UTF-8-ordered set).
    ///   - vectors: term → context vector, every vector `dimension` long.
    ///   - idf: term → smoothed IDF weight fitted at training time.
    ///   - meanDirection: the unit corpus-mean direction fitted at training
    ///     time (`dimension` long), or empty to skip centring.
    ///   - dimension: vector dimensionality (RI/PPMI: 2048).
    /// - Returns: `vector` — the pooled unit vector, or nil when nothing
    ///   contributed or the result collapsed to zero; `hits` — how many
    ///   distinct terms had a context vector (0 means every term was OOV,
    ///   which callers report as a vocabulary miss).
    public static func pool(
        terms: [String],
        vectors: [String: [Float]],
        idf: [String: Float],
        meanDirection: [Float],
        dimension: Int
    ) -> (vector: [Float]?, hits: Int) {
        let distinct = Set(terms).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var sum = [Float](repeating: 0, count: dimension)
        var hits = 0
        for term in distinct {
            guard let cv = vectors[term], cv.count == dimension else { continue }
            hits += 1
            // idf == 0 (a term in every document) or no fitted weight:
            // adding 0·cv leaves the sum unchanged, so skip the loop.
            guard let weight = idf[term], weight > 0 else { continue }
            for d in 0..<dimension {
                sum[d] += weight * cv[d]
            }
        }
        guard hits > 0 else { return (nil, 0) }
        let unit = FloatVecOps.l2Normalize(sum)
        let centred = removeMeanDirection(from: unit, meanDirection: meanDirection)
        let result = FloatVecOps.l2Normalize(centred)
        let allZero = result.allSatisfy { $0 == 0 }
        return (allZero ? nil : result, hits)
    }

    /// Remove the component of `unit` along the unit direction `meanDirection`:
    /// `unit − (unit · m̂) m̂`. Returns `unit` unchanged when no mean direction
    /// is fitted (empty) or its length does not match.
    public static func removeMeanDirection(from unit: [Float], meanDirection: [Float]) -> [Float] {
        guard !meanDirection.isEmpty, meanDirection.count == unit.count else { return unit }
        let projection = FloatVecOps.dot(unit, meanDirection)
        var out = unit
        for d in 0..<out.count {
            out[d] -= projection * meanDirection[d]
        }
        return out
    }

    /// Fit the unit corpus-mean direction from the vector table and the
    /// maintained document frequencies:
    /// `m̂ = l2Normalize(Σ_t df(t)·idf(t)·vector(t))`, keys in UTF-8 order.
    ///
    /// Returns an empty array when nothing contributed (no terms, or every
    /// term has df 0 or idf 0), which `pool` treats as "no centring".
    ///
    /// - Parameters:
    ///   - vectors: term → context vector, every vector `dimension` long.
    ///   - idf: term → smoothed IDF weight.
    ///   - documentFrequency: term → number of documents containing it.
    ///   - dimension: vector dimensionality.
    public static func meanDirection(
        vectors: [String: [Float]],
        idf: [String: Float],
        documentFrequency: (String) -> Int,
        dimension: Int
    ) -> [Float] {
        let orderedTerms = vectors.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var sum = [Float](repeating: 0, count: dimension)
        for term in orderedTerms {
            guard let cv = vectors[term], cv.count == dimension else { continue }
            guard let weight = idf[term], weight > 0 else { continue }
            let df = documentFrequency(term)
            guard df > 0 else { continue }
            // Float(df) * idf first, then scaled into the accumulator — the
            // same two-step product in the Rust port.
            let coefficient = Float(df) * weight
            for d in 0..<dimension {
                sum[d] += coefficient * cv[d]
            }
        }
        let unit = FloatVecOps.l2Normalize(sum)
        return unit.contains { $0 != 0 } ? unit : []
    }
}
