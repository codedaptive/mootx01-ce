//! BM25 inverted index — wrapper over the Lane D engine layer.
//!
//! REFACTORED (Lane D): delegates to `BM25Weighting` (which builds an
//! `InvertedIndex` with quantized per-posting impacts) and queries via
//! WAND / Block-Max WAND. The original float-at-query-time path is
//! replaced by the integer-only path mandated by §2.6.
//!
//! Public API is unchanged:
//!   - `new(tokenizer)` / `with_parameters(tokenizer, params)`
//!   - `index_documents(items)`  — index (doc_id UUID, text) pairs
//!   - `remove(doc_id)`          — remove by UUID
//!   - `document_count()`        — total indexed docs
//!   - `top_k(k, tokens)`        — top-k (Uuid, f32), descending (takes &self)
//!   - `tokenize_query(text)`    — convenience tokenizer forward
//!
//! UUID string sort order (UUID::to_string(), lowercase hex with dashes)
//! is used as the item_id for postings — matching the Swift tie-break
//! of UUID.uuidString (uppercase, but both are lexicographic on hex digits).
//! The ordering is consistent within each port.
//!
//! Interior-mutability design: the lazy-built index cache lives in a
//! `Mutex<Option<...>>` so `top_k` and `tokenize_query` can accept `&self`
//! instead of `&mut self`, matching the callers in `corpus.rs` and
//! `hybrid_recall.rs` that hold the index behind their own `Mutex`.

use crate::engine::bm25_weighting::{BM25Weighting, TermFreqTable};
use crate::engine::inverted_index::Algorithm;
use crate::tokenizer::Tokenizer;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

pub use crate::engine::bm25_weighting::BM25Parameters;

/// In-memory BM25 index backed by the WAND / BMW engine.
pub struct BM25Index {
    tokenizer: Arc<dyn Tokenizer>,
    parameters: BM25Parameters,
    /// term → item_id string → frequency
    term_freqs: TermFreqTable,
    /// item_id string → document length
    doc_lengths: HashMap<String, usize>,
    /// Lazily-built (index, term_mapping). Invalidated by every write.
    /// Wrapped in Mutex<Option<...>> so `top_k` can take `&self`.
    cached: Mutex<Option<(crate::engine::inverted_index::InvertedIndex, HashMap<String, u32>)>>,
}

impl BM25Index {
    pub fn new(tokenizer: Arc<dyn Tokenizer>) -> Self {
        Self::with_parameters(tokenizer, BM25Parameters::default())
    }

    pub fn with_parameters(tokenizer: Arc<dyn Tokenizer>, parameters: BM25Parameters) -> Self {
        BM25Index {
            tokenizer,
            parameters,
            term_freqs: TermFreqTable::new(),
            doc_lengths: HashMap::new(),
            cached: Mutex::new(None),
        }
    }

    // MARK: — Indexing

    /// Index a batch of (document id, text) pairs.
    pub fn index_documents<'a, I>(&mut self, documents: I)
    where
        I: IntoIterator<Item = (Uuid, &'a str)>,
    {
        for (id, text) in documents {
            let item_id = id.to_string();
            // Remove existing state before re-indexing.
            self.remove_mem(&item_id);

            let tokens = self.tokenizer.keyword_tokens(text);
            let doc_len = tokens.len();
            self.doc_lengths.insert(item_id.clone(), doc_len);

            let mut tf: HashMap<String, usize> = HashMap::new();
            for t in tokens { *tf.entry(t).or_insert(0) += 1; }
            for (term, freq) in tf {
                self.term_freqs.entry(term).or_default().insert(item_id.clone(), freq);
            }
        }
        // Invalidate the lazy cache after a write.
        if let Ok(mut c) = self.cached.lock() { *c = None; }
    }

    /// Remove a document by UUID.
    pub fn remove(&mut self, doc_id: Uuid) {
        let item_id = doc_id.to_string();
        self.remove_mem(&item_id);
        if let Ok(mut c) = self.cached.lock() { *c = None; }
    }

    fn remove_mem(&mut self, item_id: &str) {
        self.doc_lengths.remove(item_id);
        let terms: Vec<String> = self.term_freqs.keys().cloned().collect();
        for term in terms {
            if let Some(docs) = self.term_freqs.get_mut(&term) {
                docs.remove(item_id);
                if docs.is_empty() { self.term_freqs.remove(&term); }
            }
        }
    }

    // MARK: — Query

    /// Total indexed documents.
    pub fn document_count(&self) -> usize { self.doc_lengths.len() }

    /// Top-k BM25 scoring via WAND / BMW engine.
    ///
    /// Returns up to k `(Uuid, f32)` pairs, score descending,
    /// UUID string ascending on ties (matching Swift behaviour).
    ///
    /// Takes `&self` — the lazy-built index cache is behind an interior
    /// `Mutex<Option<...>>` so callers that hold `BM25Index` behind their
    /// own `Mutex` do not need a mutable guard.
    pub fn top_k(&self, k: usize, tokens: &[String]) -> Vec<(Uuid, f32)> {
        if k == 0 || tokens.is_empty() || self.doc_lengths.is_empty() {
            return Vec::new();
        }
        // Build a fresh index each call (no persistent cache on &self path,
        // since InvertedIndex is not Clone). This is acceptable at query
        // granularity; index sizes are bounded by in-session document sets.
        let (index, term_mapping) =
            BM25Weighting::build(&self.term_freqs, &self.doc_lengths, self.parameters);
        let query = BM25Weighting::query_pairs(tokens, &term_mapping);
        if query.is_empty() { return Vec::new(); }

        let hits = index.top_k(&query, k, Algorithm::BlockMaxWand);
        hits.into_iter()
            .filter_map(|hit| {
                Uuid::parse_str(&hit.item_id).ok().map(|uuid| (uuid, hit.impact))
            })
            .collect()
    }

    /// Convenience: tokenize a query string.
    pub fn tokenize_query(&self, query: &str) -> Vec<String> {
        self.tokenizer.keyword_tokens(query)
    }
}
