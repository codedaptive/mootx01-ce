//! shingle_similarity.rs — character-shingle Jaccard similarity.
//!
//! The substrate-owned set-similarity primitive used by recall-ranking
//! diversity passes (MMR). Mirrors the Swift `ShingleSimilarity`
//! reference exactly.
//!
//!   sim(a, b) = |S(a) ∩ S(b)| / |S(a) ∪ S(b)|
//!
//! where S(x) is the set of 3-character lowercase shingles of x.
//!
//! WHY THIS LIVES IN THE SUBSTRATE (I-25). The same character-shingle
//! Jaccard is computed in two kits — NeuronKit (`HybridRecallEngine`
//! MMR rerank) and GeniusLocusKit (`RecallDirector` unionBest MMR).
//! Those copies exist because GLK cannot depend on NeuronKit (layering).
//! Both kits depend on SubstrateML, which sits below both, so the math
//! has a single correct home here (the kit rewire is a follow-up).
//!
//! DETERMINISM. A pure function of the two input strings — no locale
//! transforms, no stemming, no tokeniser, no randomness, no clock. Case
//! folding via `to_lowercase()` matches Swift's `lowercased()` for the
//! ASCII content the recall path shingles. The result is an f32 ratio of
//! integer cardinalities, bit-identical across the Swift and Rust ports
//! and conformance-gated on the shared seed.
//!
//! EDGE-CASE CONTRACT (preserved from the canonical NeuronKit copy):
//!   - A string shorter than the window (1–2 chars) yields a single
//!     shingle: the whole lowercased string. The empty string yields the
//!     empty set.
//!   - Both sets empty -> 0.0 (no overlap).
//!   - Union non-empty -> |∩| / |∪| in f32.

use std::collections::BTreeSet;

/// Shingle window width (3-character windows — the recall path standard).
pub const WINDOW_SIZE: usize = 3;

/// The set of `WINDOW_SIZE`-character lowercase shingles of `s`.
///
/// A string shorter than the window yields a single shingle (the whole
/// lowercased string) unless it is empty, in which case the set is empty.
/// `BTreeSet` keeps the set construction deterministic; only the
/// cardinalities feed the similarity, so the ordering is incidental.
pub fn shingles(s: &str) -> BTreeSet<String> {
    let lower = s.to_lowercase();
    let chars: Vec<char> = lower.chars().collect();
    let mut out = BTreeSet::new();
    if chars.len() < WINDOW_SIZE {
        // 1–2 chars collapse to a single whole-string shingle; empty
        // input yields no shingle. Matches the canonical recall path.
        if !chars.is_empty() {
            out.insert(chars.iter().collect::<String>());
        }
        return out;
    }
    for i in 0..=(chars.len() - WINDOW_SIZE) {
        out.insert(chars[i..(i + WINDOW_SIZE)].iter().collect::<String>());
    }
    out
}

/// Jaccard similarity over the character-shingle sets of `a` and `b`.
///
/// Returns `|S(a) ∩ S(b)| / |S(a) ∪ S(b)|` as an f32. Two empty inputs
/// score 0.0; otherwise the ratio of intersection to union cardinality.
pub fn similarity(a: &str, b: &str) -> f32 {
    similarity_sets(&shingles(a), &shingles(b))
}

/// Jaccard over PRE-COMPUTED shingle sets — the same math as the string
/// version, which delegates here (I-25: one implementation per substrate
/// atomic). Exists so a caller comparing one corpus pairwise (e.g.
/// NeuronKit's MMR rerank) can shingle each text ONCE and reuse the sets:
/// rebuilding both sets per pairwise call measured 181 s over a
/// 250-drawer pool. `|A ∩ B| / |A ∪ B|`, with the union computed as
/// |A| + |B| − |A ∩ B| (identical value, no set materialization).
/// Twin of Swift `ShingleSimilarity.similarity(_:_:)` (set overload).
pub fn similarity_sets(sa: &BTreeSet<String>, sb: &BTreeSet<String>) -> f32 {
    // Both empty: no shingles to compare, define as fully dissimilar.
    if sa.is_empty() && sb.is_empty() {
        return 0.0;
    }
    let inter = sa.intersection(sb).count();
    let union = sa.len() + sb.len() - inter;
    // Union is zero only if both sets are empty (handled above); the
    // guard keeps the division provably safe for any future edit.
    if union == 0 {
        return 0.0;
    }
    inter as f32 / union as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_has_no_shingles() {
        assert!(shingles("").is_empty());
    }

    #[test]
    fn short_input_returns_whole_lowercased_string() {
        let mut expect = BTreeSet::new();
        expect.insert("ab".to_string());
        assert_eq!(shingles("ab"), expect);
        assert_eq!(shingles("AB"), expect);
    }

    #[test]
    fn windows_are_three_char_lowercased() {
        let mut expect = BTreeSet::new();
        for w in ["cat", "atd", "tdo", "dog"] {
            expect.insert(w.to_string());
        }
        assert_eq!(shingles("catdog"), expect);
        assert_eq!(shingles("CatDog"), expect);
    }

    #[test]
    fn identical_strings_score_one() {
        assert_eq!(similarity("organic chemistry", "organic chemistry"), 1.0);
    }

    #[test]
    fn disjoint_strings_score_zero() {
        assert_eq!(similarity("abcdef", "ghijkl"), 0.0);
    }

    #[test]
    fn both_empty_score_zero() {
        assert_eq!(similarity("", ""), 0.0);
    }

    #[test]
    fn one_empty_scores_zero() {
        // S("") is empty, so intersection is 0 and union is |S(other)|.
        assert_eq!(similarity("", "catdog"), 0.0);
    }

    #[test]
    fn partial_overlap_is_ratio() {
        // "abcd" -> {abc, bcd}; "abce" -> {abc, bce}.
        // intersection {abc} = 1; union {abc, bcd, bce} = 3.
        let s = similarity("abcd", "abce");
        assert_eq!(s, 1.0 / 3.0);
    }
}
