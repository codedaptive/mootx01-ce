//! BM25 as one impact weighting for the inverted index.
//!
//! Lane D — BM25 collapse into the generalized weighted-impact framework.
//! Retrieval algorithms reference §2.6 is the authoritative spec.
//!
//! The float BM25 math runs once at index build time; the resulting impacts
//! are quantized (round-half-to-even, QUANT_SCALE=100) and stored as i32.
//! The query path is pure integer thereafter.
//!
//! Parity: Swift twin in CorpusKit/Sources/CorpusKit/Engine/BM25Weighting.swift.

use crate::engine::inverted_index::{InvertedIndex, QUANT_SCALE};
use crate::engine::sparse_types::ImpactPosting;
use std::collections::HashMap;

/// BM25 hyperparameters. Defaults follow Robertson-Sparck Jones recommendations.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BM25Parameters {
    /// Term frequency saturation constant. Default: 1.5.
    pub k1: f64,
    /// Length normalization constant. Default: 0.75.
    pub b: f64,
}

impl BM25Parameters {
    pub fn new(k1: f64, b: f64) -> Self {
        BM25Parameters { k1, b }
    }
}

impl Default for BM25Parameters {
    fn default() -> Self {
        BM25Parameters { k1: 1.5, b: 0.75 }
    }
}

// MARK: — Fixed-point quantization

/// Round-half-to-even (banker's rounding), pinned per §2.2.
///
/// `round_half_even(value * QUANT_SCALE)` as i32.
pub fn quantize_impact(value: f64) -> i32 {
    let scaled = value * QUANT_SCALE as f64;
    let rounded = round_half_even(scaled);
    rounded.clamp(i32::MIN as f64, i32::MAX as f64) as i32
}

/// Banker's rounding: round to nearest; on exact half, round to even.
fn round_half_even(x: f64) -> f64 {
    let floor = x.floor();
    let frac = x - floor;
    if (frac - 0.5).abs() < f64::EPSILON * 4.0 {
        // Exactly at 0.5 (within floating-point tolerance): round to even.
        let floor_i = floor as i64;
        if floor_i % 2 == 0 { floor } else { floor + 1.0 }
    } else {
        x.round()
    }
}

// MARK: — Term frequency table type

/// term → item_id → frequency.
pub type TermFreqTable = HashMap<String, HashMap<String, usize>>;

// MARK: — BM25Weighting

/// BM25 weighting: build an `InvertedIndex` with quantized BM25 impacts.
pub struct BM25Weighting;

impl BM25Weighting {
    /// Build an `InvertedIndex` from BM25-weighted impacts.
    ///
    /// Returns the built index and the term→u32 mapping used.
    /// Float BM25 math happens once here; the output index is integer-only.
    pub fn build(
        term_freqs: &TermFreqTable,
        doc_lengths: &HashMap<String, usize>,
        parameters: BM25Parameters,
    ) -> (InvertedIndex, HashMap<String, u32>) {
        let num_docs = doc_lengths.len();
        if num_docs == 0 {
            return (InvertedIndex::new(HashMap::new(), 0), HashMap::new());
        }

        // avgdl
        let total_len: usize = doc_lengths.values().sum();
        let avgdl = total_len as f64 / num_docs as f64;

        // Stable term→u32 mapping (sorted alphabetically for reproducibility).
        let term_mapping = Self::build_term_id_map(term_freqs);

        // Compute per-posting quantized impacts.
        let mut postings: HashMap<u32, Vec<ImpactPosting>> = HashMap::new();
        for (term, doc_tfs) in term_freqs {
            let Some(&term_id) = term_mapping.get(term) else { continue };
            let df = doc_tfs.len() as f64;
            let idf = (1.0 + ((num_docs as f64) - df + 0.5) / (df + 0.5)).ln();

            let mut term_postings = Vec::with_capacity(doc_tfs.len());
            for (item_id, &tf) in doc_tfs {
                let dl = *doc_lengths.get(item_id).unwrap_or(&0) as f64;
                let denom = (tf as f64)
                    + parameters.k1 * (1.0 - parameters.b + parameters.b * dl / avgdl.max(1.0));
                let raw = idf * (tf as f64 * (parameters.k1 + 1.0)) / denom.max(0.0001);
                let impact = quantize_impact(raw);
                term_postings.push(ImpactPosting {
                    item_id: item_id.clone(),
                    impact,
                });
            }
            postings.insert(term_id, term_postings);
        }

        let index = InvertedIndex::new(postings, num_docs);
        (index, term_mapping)
    }

    /// Build a stable term→u32 mapping (sorted alphabetically).
    pub fn build_term_id_map(term_freqs: &TermFreqTable) -> HashMap<String, u32> {
        let mut terms: Vec<&str> = term_freqs.keys().map(String::as_str).collect();
        terms.sort_unstable();
        terms.into_iter()
            .enumerate()
            .map(|(idx, term)| (term.to_owned(), idx as u32))
            .collect()
    }

    /// Prepare a BM25 query: map query terms to (term_id, query_weight) pairs.
    ///
    /// BM25 query_weight = QUANT_SCALE for every term (§2.6).
    /// Unknown terms (not in the mapping) are silently dropped.
    pub fn query_pairs(
        query_terms: &[String],
        term_mapping: &HashMap<String, u32>,
    ) -> Vec<(u32, i32)> {
        let mut seen = std::collections::HashSet::new();
        let mut result = Vec::new();
        for term in query_terms {
            if let Some(&term_id) = term_mapping.get(term) {
                if seen.insert(term_id) {
                    result.push((term_id, QUANT_SCALE));
                }
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-half-to-even: 0.5 → 0 (nearest even), 1.5 → 2, 2.5 → 2, 3.5 → 4.
    #[test]
    fn quantize_round_half_even() {
        assert_eq!(quantize_impact(0.0), 0);
        assert_eq!(quantize_impact(1.0), 100);
        assert_eq!(quantize_impact(0.005), 0,   "0.5 → nearest even 0");
        assert_eq!(quantize_impact(0.015), 2,   "1.5 → nearest even 2");
        assert_eq!(quantize_impact(0.025), 2,   "2.5 → nearest even 2");
        assert_eq!(quantize_impact(0.035), 4,   "3.5 → nearest even 4");
        // Negative
        assert_eq!(quantize_impact(-0.005), 0,  "-0.5 → nearest even 0");
    }

    #[test]
    fn build_empty_returns_empty_index() {
        let (index, mapping) = BM25Weighting::build(&HashMap::new(), &HashMap::new(), BM25Parameters::default());
        assert!(mapping.is_empty());
        let hits = index.top_k(&[(0u32, 100i32)], 5, crate::engine::inverted_index::Algorithm::Wand);
        assert!(hits.is_empty());
    }

    /// SPARSE-3 (Rust): BM25 quantization matches expected impacts.
    #[test]
    fn sparse3_bm25_quantization() {
        let params = BM25Parameters::new(1.2, 0.75);
        let mut term_freqs = TermFreqTable::new();
        // cat: doc1=2, doc2=1
        let mut cat = HashMap::new(); cat.insert("doc1".to_owned(), 2); cat.insert("doc2".to_owned(), 1);
        term_freqs.insert("cat".to_owned(), cat);
        // dog: doc1=1, doc3=3
        let mut dog = HashMap::new(); dog.insert("doc1".to_owned(), 1); dog.insert("doc3".to_owned(), 3);
        term_freqs.insert("dog".to_owned(), dog);
        // bird: doc2=1, doc3=1
        let mut bird = HashMap::new(); bird.insert("doc2".to_owned(), 1); bird.insert("doc3".to_owned(), 1);
        term_freqs.insert("bird".to_owned(), bird);

        let doc_lengths: HashMap<String, usize> = [
            ("doc1".to_owned(), 3usize), ("doc2".to_owned(), 2), ("doc3".to_owned(), 4)
        ].into_iter().collect();

        let (index, term_mapping) = BM25Weighting::build(&term_freqs, &doc_lengths, params);

        let cat_id = *term_mapping.get("cat").expect("cat in mapping");
        let dog_id = *term_mapping.get("dog").expect("dog in mapping");
        let query = vec![(cat_id, QUANT_SCALE), (dog_id, QUANT_SCALE)];

        // Exhaustive scan for all 3 docs.
        let all3 = index.exhaustive_scan(&query, 3);
        let by_id: HashMap<&str, f32> = all3.iter().map(|h| (h.item_id.as_str(), h.impact)).collect();

        let doc1 = by_id["doc1"];
        let doc2 = by_id.get("doc2").copied().unwrap_or(0.0);
        let doc3 = by_id["doc3"];

        // doc1 has both cat+dog → must rank first.
        assert!(doc1 > doc3, "doc1 (cat+dog) must outscore doc3 (dog only), got doc1={doc1}, doc3={doc3}");
        assert!(doc1 > doc2, "doc1 (cat+dog) must outscore doc2 (cat only), got doc1={doc1}, doc2={doc2}");
        // doc3 has high TF for dog (3) → must outrank doc2.
        assert!(doc3 > doc2, "doc3 (dog×3) must outscore doc2 (cat×1), got doc3={doc3}, doc2={doc2}");

        // Top-2: WAND must agree with exhaustive.
        let wand_top2 = index.top_k(&query, 2, crate::engine::inverted_index::Algorithm::Wand);
        let bmw_top2  = index.top_k(&query, 2, crate::engine::inverted_index::Algorithm::BlockMaxWand);
        let scan_top2 = index.exhaustive_scan(&query, 2);

        let wand_ids: Vec<&str> = wand_top2.iter().map(|h| h.item_id.as_str()).collect();
        let bmw_ids:  Vec<&str> = bmw_top2.iter().map(|h| h.item_id.as_str()).collect();
        let scan_ids: Vec<&str> = scan_top2.iter().map(|h| h.item_id.as_str()).collect();

        assert_eq!(wand_ids, scan_ids, "WAND top-2 must match exhaustive");
        assert_eq!(bmw_ids,  scan_ids, "BMW top-2 must match exhaustive");
        assert_eq!(wand_ids[0], "doc1", "doc1 must rank first");
    }

    #[test]
    fn query_pairs_deduplicates_terms() {
        let mut mapping = HashMap::new();
        mapping.insert("cat".to_owned(), 0u32);
        mapping.insert("dog".to_owned(), 1u32);
        let pairs = BM25Weighting::query_pairs(
            &["cat".to_owned(), "dog".to_owned(), "cat".to_owned()],
            &mapping,
        );
        // "cat" appears twice in query but should only produce one pair.
        assert_eq!(pairs.len(), 2);
        let ids: Vec<u32> = pairs.iter().map(|(id, _)| *id).collect();
        assert!(ids.contains(&0));
        assert!(ids.contains(&1));
    }
}
