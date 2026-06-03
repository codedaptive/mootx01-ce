//! BM25 inverted index. In-memory; rebuilt from the underlying
//! bundle store as needed. The Rust version of the Swift BM25Index:
//! the index owns its state directly and the mutating methods
//! (`index_documents`, `remove`) take `&mut self`; scoring reads
//! (`search`, `document_count`) take `&self`.

use crate::tokenizer::Tokenizer;
use std::collections::HashMap;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
pub struct BM25Parameters {
    pub k1: f64,
    pub b: f64,
}

impl BM25Parameters {
    pub const fn new(k1: f64, b: f64) -> Self {
        BM25Parameters { k1, b }
    }
}

impl Default for BM25Parameters {
    fn default() -> Self {
        BM25Parameters::new(1.5, 0.75)
    }
}

struct IndexState {
    total_docs: usize,
    total_length_sum: usize,
    /// term -> (doc_id -> term frequency)
    postings: HashMap<String, HashMap<Uuid, usize>>,
    doc_lengths: HashMap<Uuid, usize>,
}

pub struct BM25Index {
    tokenizer: Arc<dyn Tokenizer>,
    parameters: BM25Parameters,
    state: IndexState,
}

impl BM25Index {
    pub fn new(tokenizer: Arc<dyn Tokenizer>) -> Self {
        Self::with_parameters(tokenizer, BM25Parameters::default())
    }

    pub fn with_parameters(tokenizer: Arc<dyn Tokenizer>, parameters: BM25Parameters) -> Self {
        BM25Index {
            tokenizer,
            parameters,
            state: IndexState {
                total_docs: 0,
                total_length_sum: 0,
                postings: HashMap::new(),
                doc_lengths: HashMap::new(),
            },
        }
    }

    /// Index a batch of (document id, text) pairs.
    pub fn index_documents<'a, I>(&mut self, documents: I)
    where
        I: IntoIterator<Item = (Uuid, &'a str)>,
    {
        let state = &mut self.state;
        for (id, text) in documents {
            let tokens = self.tokenizer.keyword_tokens(text);
            let len = tokens.len();
            state.doc_lengths.insert(id, len);
            state.total_length_sum += len;
            state.total_docs += 1;
            let mut tf: HashMap<String, usize> = HashMap::new();
            for t in tokens {
                *tf.entry(t).or_insert(0) += 1;
            }
            for (term, freq) in tf {
                state.postings.entry(term).or_default().insert(id, freq);
            }
        }
    }

    pub fn remove(&mut self, doc_id: Uuid) {
        let state = &mut self.state;
        if let Some(len) = state.doc_lengths.remove(&doc_id) {
            state.total_length_sum = state.total_length_sum.saturating_sub(len);
            state.total_docs = state.total_docs.saturating_sub(1);
        }
        let terms: Vec<String> = state.postings.keys().cloned().collect();
        for term in terms {
            if let Some(posting) = state.postings.get_mut(&term) {
                posting.remove(&doc_id);
                if posting.is_empty() {
                    state.postings.remove(&term);
                }
            }
        }
    }

    /// Top-k BM25 scoring over the given query string. Returns
    /// (doc_id, score) pairs sorted by descending score with a
    /// uuid-string tiebreak (matches Swift).
    pub fn search(&self, query: &str, limit: usize) -> Vec<(Uuid, f64)> {
        if limit == 0 {
            return Vec::new();
        }
        let state = &self.state;
        if state.total_docs == 0 {
            return Vec::new();
        }
        let query_tokens = self.tokenizer.keyword_tokens(query);
        if query_tokens.is_empty() {
            return Vec::new();
        }
        let avg_doc_len = (state.total_length_sum as f64) / (state.total_docs as f64);
        let mut scores: HashMap<Uuid, f64> = HashMap::new();

        for term in &query_tokens {
            let Some(posting) = state.postings.get(term) else {
                continue;
            };
            if posting.is_empty() {
                continue;
            }
            let n = posting.len() as f64;
            // IDF with the +1 smoothing for non-negative scores.
            let idf = (1.0 + ((state.total_docs as f64) - n + 0.5) / (n + 0.5)).ln();
            for (doc_id, tf) in posting {
                let dl = *state.doc_lengths.get(doc_id).unwrap_or(&0) as f64;
                let denom = (*tf as f64)
                    + self.parameters.k1
                        * (1.0 - self.parameters.b + self.parameters.b * dl / avg_doc_len.max(1.0));
                let contribution =
                    idf * ((*tf as f64) * (self.parameters.k1 + 1.0)) / denom.max(0.0001);
                *scores.entry(*doc_id).or_insert(0.0) += contribution;
            }
        }

        let mut ranked: Vec<(Uuid, f64)> = scores.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.to_string().cmp(&b.0.to_string()))
        });
        ranked.truncate(limit);
        ranked
    }

    pub fn document_count(&self) -> usize {
        self.state.total_docs
    }
}
