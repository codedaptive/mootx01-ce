//! Shared term-document count builder used by every distributional-semantics
//! provider in corpus-kit-providers (Random Indexing and LSA).
//!
//! ## What this module owns
//!
//!   - Tokenization via the canonical `corpus_kit::default_keyword_tokens`
//!     (for the text-consuming providers) or acceptance of an already-
//!     tokenized term sequence (for the term-consuming provider, RI).
//!   - Vocabulary construction in ENCOUNTER ORDER: terms are assigned
//!     integer indices as they are first seen across the training sequence.
//!     Deterministic for a fixed document sequence. This is a correctness
//!     invariant — the downstream SVD factorization depends on
//!     stable column indices.
//!   - Raw per-document term-frequency counts: tf_counts[docIdx][termIdx]
//!     (LSA only).
//!   - Per-term document-frequency counts: df_counts[termIdx] = number of
//!     documents that contain the term at least once. Every distributional
//!     provider derives its IDF weights from these through the ONE smoothed
//!     IDF function below.
//!
//! ## What this module does NOT own
//!
//!   - Matrix orientation (documents×terms for LSA).
//!   - Factorization (SVD for LSA).
//!   - Pooling (see distributional_pooling.rs).
//!
//! ## Swift port
//!
//!   Swift port: packages/kits/CorpusKit/Sources/CorpusKitProviders/TermDocumentCounts.swift
//!   The two implementations must agree on vocab encounter order and raw counts.
//!   Downstream conformance vectors pin the bit-identical contract.

use corpus_kit::default_keyword_tokens;
use std::collections::HashMap;

// MARK: - Smoothed inverse document frequency

/// The one IDF weighting shared by every distributional provider:
///
/// ```text
/// idf(t) = max(0, ln((N + 1) / (df(t) + 1)))
/// ```
///
/// Add-1 smoothing on both sides keeps the ratio finite for df = 0 (an
/// unseen term is informative, not undefined) and drives a term that
/// appears in every document to exactly 0. Natural log on f32, so
/// `f32::ln` and Swift's `log` (logf) produce identical bits — the LSA
/// canonical vectors pin this. Twin of Swift
/// `smoothedInverseDocumentFrequency(documentFrequency:documentCount:)`.
pub fn smoothed_inverse_document_frequency(df: usize, n: usize) -> f32 {
    (((n + 1) as f32) / ((df + 1) as f32)).ln().max(0.0)
}

// MARK: - TermDocumentCounts

/// Shared term-document count builder for distributional-semantics providers.
///
/// Maintains a vocabulary (term → encounter-order index), per-document
/// raw TF counts, and per-term document-frequency counts across a sequence
/// of training documents.
///
/// After all `add_document` calls, consumers read:
///   - `vocab` — term → index map (encounter order)
///   - `tf_counts` — tf_counts[docIdx][termIdx] = raw count
///   - `df_counts` — df_counts[termIdx] = number of documents with that term
///   - `document_count()` — number of documents added
///   - `vocabulary_size()` — vocabulary cardinality
///
/// ## Encounter-order vocabulary
///
/// The first call to `add_document` that contains a new term `t` assigns
/// `vocab[t] = vocab.len()` at that moment (before insertion). This ensures
/// indices are contiguous and stable across all subsequent documents.
///
/// ## Thread safety
///
/// `TermDocumentCounts` is NOT thread-safe. All `add_document` calls must
/// complete before any consumer reads the output fields.
pub struct TermDocumentCounts {
    /// Term → vocabulary index (encounter order, deterministic for fixed sequence).
    pub vocab: HashMap<String, usize>,

    /// tf counts: tf_counts[docIdx][termIdx] = raw count in that document.
    pub tf_counts: Vec<HashMap<usize, usize>>,

    /// Document frequency: df_counts[termIdx] = number of documents containing term.
    /// LSA uses this for IDF weighting.
    pub df_counts: HashMap<usize, usize>,
}

impl TermDocumentCounts {
    /// Create a new, empty builder.
    pub fn new() -> Self {
        TermDocumentCounts {
            vocab: HashMap::new(),
            tf_counts: Vec::new(),
            df_counts: HashMap::new(),
        }
    }

    /// Reconstruct a count builder from a known vocabulary and document
    /// count, WITHOUT re-tokenizing any text (the deserialization path).
    ///
    /// LSA reads only `vocab` (term → index, for query fold-in) and
    /// `document_count()` (for the `document_embedding(doc_idx)` range check)
    /// from a finalized provider — the raw per-document TF counts are
    /// training-phase scratch not needed for embedding. A deserialized
    /// provider therefore seeds this builder with the persisted vocab and one
    /// empty TF row per document so `document_count()` is preserved while the
    /// (non-embed-relevant) raw counts are left empty.
    ///
    /// Mirror of Swift's `TermDocumentCounts.init(restoredVocab:documentCount:)`.
    pub fn from_restored(vocab: HashMap<String, usize>, document_count: usize) -> Self {
        TermDocumentCounts {
            vocab,
            // One empty TF row per document preserves `document_count()`.
            tf_counts: vec![HashMap::new(); document_count],
            df_counts: HashMap::new(),
        }
    }

    /// Reconstruct the document-frequency table of a term-consuming provider
    /// (RI) from persisted counts: term → df, plus the document count.
    ///
    /// Terms receive indices in ascending UTF-8 byte order of the term — the
    /// order the counts codec writes them in — so the restored table is a
    /// deterministic function of the persisted map on both ports. The TF rows
    /// are placeholders (the providers never kept them). Twin of Swift
    /// `TermDocumentCounts.init(restoredDocumentFrequencies:documentCount:)`.
    pub fn from_restored_document_frequencies(
        document_frequencies: HashMap<String, usize>,
        document_count: usize,
    ) -> Self {
        let mut ordered: Vec<(String, usize)> = document_frequencies.into_iter().collect();
        ordered.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        let mut vocab = HashMap::with_capacity(ordered.len());
        let mut df_counts = HashMap::with_capacity(ordered.len());
        for (index, (term, df)) in ordered.into_iter().enumerate() {
            vocab.insert(term, index);
            df_counts.insert(index, df);
        }
        TermDocumentCounts {
            vocab,
            tf_counts: vec![HashMap::new(); document_count],
            df_counts,
        }
    }

    /// Tokenize `text` and accumulate TF counts for one document.
    ///
    /// Terms new to the corpus are assigned the next available vocabulary
    /// index in encounter order (`vocab.len()` before insertion). Returns
    /// without recording the document if `text` tokenizes to nothing.
    ///
    /// - Note: Does not call `SystemTime::now()` — determinism invariant.
    pub fn add_document(&mut self, text: &str) {
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return;
        }

        // Assign vocab indices in encounter order (deterministic for a fixed
        // training sequence). New terms receive vocab.len() as their index at
        // the moment of first insertion.
        let mut doc_tf: HashMap<usize, usize> = HashMap::new();
        for term in &terms {
            let idx = if let Some(&existing) = self.vocab.get(term.as_str()) {
                existing
            } else {
                let idx = self.vocab.len();
                self.vocab.insert(term.clone(), idx);
                idx
            };
            *doc_tf.entry(idx).or_insert(0) += 1;
        }

        // Accumulate per-term document-frequency counts.
        // A term contributes exactly 1 to df_counts regardless of how many
        // times it appears in this document.
        for &term_idx in doc_tf.keys() {
            *self.df_counts.entry(term_idx).or_insert(0) += 1;
        }

        self.tf_counts.push(doc_tf);
    }

    /// Fold one document into the maintained COUNTS ANCHOR only: grow the
    /// vocabulary (encounter order) and increment the document count, WITHOUT
    /// retaining the per-document TF row or accumulating document frequency.
    ///
    /// Used by the incremental-counts maintenance path (P3). The heavy TF/DF
    /// inputs the factorization needs are re-derived by re-tokenizing the corpus
    /// at refactor (re-tokenize-at-refactor decision), so the maintained table
    /// keeps only the lightweight growth anchor — vocabulary size and document
    /// count — current, bounding maintained state to O(vocab) rather than the
    /// O(corpus) a full `add_document` per chunk would accumulate.
    ///
    /// Vocabulary indices are assigned in the SAME encounter order as
    /// `add_document`, so the anchor's vocab map is deterministic and matches the
    /// Swift port byte-for-byte. An empty TF row is pushed so `document_count`
    /// reports correctly (the raw counts are intentionally not retained).
    ///
    /// - Note: Does not call `SystemTime::now()` — determinism invariant.
    pub fn add_document_for_counts_anchor(&mut self, text: &str) {
        let terms = default_keyword_tokens(text);
        if terms.is_empty() {
            return;
        }
        for term in &terms {
            if !self.vocab.contains_key(term.as_str()) {
                let idx = self.vocab.len();
                self.vocab.insert(term.clone(), idx);
            }
        }
        self.tf_counts.push(HashMap::new());
    }

    /// Fold one ALREADY-TOKENIZED document into the vocabulary and the
    /// document-frequency table, without retaining a TF row.
    ///
    /// Entry point for the term-consuming provider (RI), whose `train`
    /// receives one document's term sequence per call. Each distinct term
    /// counts once toward `df_counts` no matter how often it repeats; a
    /// document with no terms is not recorded (same rule as `add_document`).
    /// Vocabulary indices follow the same encounter order as `add_document`.
    /// Twin of Swift `addDocumentTerms(_:)`.
    ///
    /// - Note: Does not call `SystemTime::now()` — determinism invariant.
    pub fn add_document_terms(&mut self, terms: &[&str]) {
        if terms.is_empty() {
            return;
        }
        let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
        for term in terms {
            let idx = if let Some(&existing) = self.vocab.get(*term) {
                existing
            } else {
                let idx = self.vocab.len();
                self.vocab.insert((*term).to_string(), idx);
                idx
            };
            if seen.insert(idx) {
                *self.df_counts.entry(idx).or_insert(0) += 1;
            }
        }
        self.tf_counts.push(HashMap::new());
    }

    /// Number of documents added so far.
    pub fn document_count(&self) -> usize {
        self.tf_counts.len()
    }

    /// Number of documents that contain `term` at least once; 0 for a term
    /// the corpus never produced.
    pub fn document_frequency(&self, term: &str) -> usize {
        match self.vocab.get(term) {
            Some(idx) => *self.df_counts.get(idx).unwrap_or(&0),
            None => 0,
        }
    }

    /// The smoothed IDF weight of `term` over this corpus — see
    /// `smoothed_inverse_document_frequency`.
    pub fn inverse_document_frequency(&self, term: &str) -> f32 {
        smoothed_inverse_document_frequency(self.document_frequency(term), self.document_count())
    }

    /// term → document frequency for every term in the vocabulary — the
    /// shape the counts codec persists (`write_string_u32_map`).
    pub fn document_frequencies(&self) -> HashMap<String, usize> {
        self.vocab
            .iter()
            .map(|(term, idx)| (term.clone(), *self.df_counts.get(idx).unwrap_or(&0)))
            .collect()
    }

    /// Vocabulary cardinality.
    pub fn vocabulary_size(&self) -> usize {
        self.vocab.len()
    }
}

impl Default for TermDocumentCounts {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    /// The canonical 5-doc mini-corpus shared by LSA and this test.
    fn canonical_corpus() -> Vec<&'static str> {
        vec![
            "car engine drive road vehicle",
            "vehicle road transport car fuel",
            "engine fuel combustion power car",
            "dog bark run fetch animal",
            "animal run cat dog pet",
        ]
    }

    #[test]
    fn vocab_encounter_order_is_deterministic() {
        // Two identical training runs must produce identical vocabs.
        let mut a = TermDocumentCounts::new();
        let mut b = TermDocumentCounts::new();
        for doc in canonical_corpus() {
            a.add_document(doc);
            b.add_document(doc);
        }
        // Same terms, same indices — maps are equal.
        assert_eq!(a.vocab, b.vocab, "vocab must be identical for identical training sequence");
    }

    #[test]
    fn document_count_matches_non_empty_docs() {
        let mut tdc = TermDocumentCounts::new();
        for doc in canonical_corpus() {
            tdc.add_document(doc);
        }
        assert_eq!(tdc.document_count(), 5);
    }

    #[test]
    fn empty_document_is_not_recorded() {
        let mut tdc = TermDocumentCounts::new();
        tdc.add_document("");
        tdc.add_document("   ");
        assert_eq!(tdc.document_count(), 0, "empty-tokenizing docs must not be recorded");
        assert_eq!(tdc.vocabulary_size(), 0);
    }

    #[test]
    fn tf_counts_accumulate_correctly() {
        // "car" appears 3 times in doc 0 after tokenization of the corpus.
        // Verify the count at the vocab index for "car".
        let mut tdc = TermDocumentCounts::new();
        tdc.add_document("car car car");
        let car_idx = tdc.vocab["car"];
        assert_eq!(tdc.tf_counts[0][&car_idx], 3);
    }

    #[test]
    fn df_counts_count_documents_not_occurrences() {
        // "car" appears in doc 0 twice and doc 1 once — df should be 2.
        let mut tdc = TermDocumentCounts::new();
        tdc.add_document("car car");
        tdc.add_document("car dog");
        let car_idx = tdc.vocab["car"];
        assert_eq!(
            tdc.df_counts[&car_idx], 2,
            "df_counts counts documents, not occurrences"
        );
    }

    #[test]
    fn vocab_indices_are_contiguous_from_zero() {
        let mut tdc = TermDocumentCounts::new();
        for doc in canonical_corpus() {
            tdc.add_document(doc);
        }
        let n = tdc.vocabulary_size();
        // Every index in 0..n must appear exactly once.
        let mut seen = vec![false; n];
        for &idx in tdc.vocab.values() {
            assert!(idx < n, "vocab index out of range");
            seen[idx] = true;
        }
        assert!(seen.iter().all(|&v| v), "vocab indices must be contiguous from 0");
    }

    #[test]
    fn first_term_encounter_order_matches_across_runs() {
        // The index of "car" must equal the index of "car" in a separate run
        // over the same corpus (encounter order is stable).
        let mut a = TermDocumentCounts::new();
        let mut b = TermDocumentCounts::new();
        for doc in canonical_corpus() {
            a.add_document(doc);
            b.add_document(doc);
        }
        // All terms in a must have the same index in b.
        for (term, &idx_a) in &a.vocab {
            let idx_b = b.vocab.get(term).copied().expect("term should be in b");
            assert_eq!(idx_a, idx_b, "term '{}' has different index between runs", term);
        }
    }
}
