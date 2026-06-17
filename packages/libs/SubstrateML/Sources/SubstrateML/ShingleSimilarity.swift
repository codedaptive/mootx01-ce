// ShingleSimilarity.swift
//
// Character-shingle Jaccard similarity — the substrate-owned set
// similarity primitive used by recall-ranking diversity passes (MMR).
//
//   sim(a, b) = |S(a) ∩ S(b)| / |S(a) ∪ S(b)|
//
// where S(x) is the set of 3-character lowercase shingles (contiguous
// character windows) of x. Identical strings score 1.0; strings with
// no shared shingle score 0.0.
//
// WHY THIS LIVES IN THE SUBSTRATE (I-25). The same character-shingle
// Jaccard is computed in two kits: NeuronKit
// (`HybridRecallEngine.shingleSimilarity`, the MMR rerank similarity
// term on the hybrid-recall page path) and GeniusLocusKit
// (`RecallDirector.glkShingleSimilarity`, the unionBest MMR
// deduplication term). Those copies exist because GLK cannot depend on
// NeuronKit (layering — GLK is the composition layer, above NeuronKit's
// siblings). Both kits already depend on SubstrateML, which sits below
// both, so the math has a single correct home here. One implementation
// per substrate atomic; both kits' similarity wrappers delegate to it
// (rewire complete — no duplicated math remains in GLK or NeuronKit).
//
// DETERMINISM AND CONFORMANCE. The math is a pure function of the two
// input strings — no locale-sensitive transforms, no stemming, no
// tokeniser, no randomness, no clock. Case folding is `lowercased()`
// (Swift) / `to_lowercase()` (Rust); for the ASCII content the recall
// path shingles, the two agree byte for byte. The result is an f32
// ratio of two integer cardinalities, so the value is bit-identical
// across the Swift and Rust ports and is conformance-gated on the
// shared seed.
//
// EDGE-CASE CONTRACT (preserved from the canonical NeuronKit copy so
// delegation is behaviour-preserving):
//   - A string shorter than the window (1–2 characters) yields a single
//     shingle: the whole (lowercased) string. The empty string yields
//     the empty set.
//   - When BOTH shingle sets are empty (both inputs empty), similarity
//     is 0.0 by definition (no overlap).
//   - When the union is non-empty, similarity is |∩| / |∪| in f32.
//
// Used by:
//   NeuronKit HybridRecallEngine — MMR rerank similarity term
//   GeniusLocusKit RecallDirector — unionBest MMR deduplication term

import Foundation

/// Character-shingle Jaccard similarity over strings.
///
/// The substrate-owned set-similarity primitive for recall-ranking
/// diversity passes. Pure, deterministic, conformance-gated to
/// bit-identity across the Swift and Rust ports.
public enum ShingleSimilarity {

    /// Shingle window width. Three-character windows are the recall
    /// path's standard: long enough to discriminate near-duplicate
    /// content, short enough to share substrings across paraphrases.
    public static let windowSize: Int = 3

    /// The set of `windowSize`-character lowercase shingles of `s`.
    ///
    /// Folds to lowercase, then windows over every contiguous
    /// `windowSize`-character run. A string shorter than the window
    /// yields a single shingle — the whole lowercased string — unless
    /// it is empty, in which case the set is empty.
    ///
    /// - Parameter s: the input string.
    /// - Returns: the deduplicated shingle set.
    public static func shingles(_ s: String) -> Set<String> {
        let lower = s.lowercased()
        let chars = Array(lower)
        guard chars.count >= windowSize else {
            // 1–2 characters collapse to a single whole-string shingle;
            // the empty string yields no shingle at all. This matches the
            // canonical recall-path behaviour the kits delegate from.
            return chars.isEmpty ? [] : [String(chars)]
        }
        var out = Set<String>()
        out.reserveCapacity(chars.count - (windowSize - 1))
        for i in 0...(chars.count - windowSize) {
            out.insert(String(chars[i..<(i + windowSize)]))
        }
        return out
    }

    /// Jaccard similarity over the character-shingle sets of `a` and `b`.
    ///
    /// Returns `|S(a) ∩ S(b)| / |S(a) ∪ S(b)|` as an f32. Two empty
    /// inputs (both shingle sets empty) score 0.0; otherwise the ratio
    /// of intersection to union cardinality.
    ///
    /// - Parameters:
    ///   - a: the first string.
    ///   - b: the second string.
    /// - Returns: similarity in `[0, 1]`.
    public static func similarity(_ a: String, _ b: String) -> Float32 {
        let sa = shingles(a)
        let sb = shingles(b)
        // Both empty: no shingles to compare, define as fully dissimilar.
        if sa.isEmpty && sb.isEmpty { return 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        // Union can be zero only if both sets are empty, handled above;
        // the guard keeps the division provably safe for any future edit.
        guard union > 0 else { return 0 }
        return Float32(inter) / Float32(union)
    }
}
