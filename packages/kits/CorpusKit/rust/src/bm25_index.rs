//! BM25 inverted index. In-memory; rebuilt from the underlying
//! bundle store as needed. The Rust version of the Swift BM25Index:
//! the index owns its state directly and the mutating methods
//! (`index_documents`, `remove`) take `&mut self`; scoring reads
//! (`top_k`, `document_count`) take `&self`.

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

    /// Top-k BM25 scoring over pre-tokenised keyword tokens using a bounded min-heap.
    ///
    /// The caller is responsible for tokenising the query with the same tokenizer
    /// vocabulary used when documents were indexed (use `tokenize_query` for
    /// convenience). This method:
    /// 1. Accepts pre-tokenised tokens so the caller controls tokenisation and
    ///    can reuse tokens across multiple calls.
    /// 2. Maintains a min-heap of capacity `k` — O(M log k) — so the candidate
    ///    set is bounded at every stage; no unbounded intermediate sort.
    ///
    /// The heap root is the weakest survivor (lowest score; latest UUID string on
    /// tie, matching Swift's ascending-UUID tiebreak). Candidates enter only when
    /// they outrank the current root.
    ///
    /// Returns up to `k` `(Uuid, f32)` pairs, descending by score. Mirrors the
    /// Swift `BM25Index.topK(_:for:)` signature (score as `f32`).
    pub fn top_k(&self, k: usize, tokens: &[String]) -> Vec<(Uuid, f32)> {
        if k == 0 || tokens.is_empty() {
            return Vec::new();
        }
        let state = &self.state;
        if state.total_docs == 0 {
            return Vec::new();
        }
        let avg_doc_len = (state.total_length_sum as f64) / (state.total_docs as f64);

        // Score only documents that appear in postings for the supplied tokens.
        let mut raw_scores: HashMap<Uuid, f64> = HashMap::new();
        for term in tokens {
            let Some(posting) = state.postings.get(term.as_str()) else {
                continue;
            };
            if posting.is_empty() {
                continue;
            }
            let n = posting.len() as f64;
            // IDF with +1 smoothing for non-negative scores (same formula as Swift topK).
            let idf = (1.0 + ((state.total_docs as f64) - n + 0.5) / (n + 0.5)).ln();
            for (doc_id, tf) in posting {
                let dl = *state.doc_lengths.get(doc_id).unwrap_or(&0) as f64;
                let denom = (*tf as f64)
                    + self.parameters.k1
                        * (1.0 - self.parameters.b
                            + self.parameters.b * dl / avg_doc_len.max(1.0));
                let contribution =
                    idf * ((*tf as f64) * (self.parameters.k1 + 1.0)) / denom.max(0.0001);
                *raw_scores.entry(*doc_id).or_insert(0.0) += contribution;
            }
        }
        if raw_scores.is_empty() {
            return Vec::new();
        }

        // Min-heap of capacity k. "Weaker" = lower score; on equal scores,
        // later UUID string (ascending UUID wins ties, matching Swift topK).
        // The root is always the weakest of the current top-k survivors.
        //
        // Ordering helper: returns true when a is weaker than b (a belongs
        // below b in the max-winner heap, i.e. a is a worse candidate).
        let cmp_weaker = |a_score: f64, a_id: &Uuid, b_score: f64, b_id: &Uuid| -> bool {
            if a_score != b_score {
                return a_score < b_score;
            }
            a_id.to_string() > b_id.to_string()
        };

        let sift_up = |heap: &mut Vec<(Uuid, f64)>, start: usize| {
            let mut i = start;
            while i > 0 {
                let parent = (i - 1) / 2;
                let (a_id, a_score) = heap[i];
                let (b_id, b_score) = heap[parent];
                if cmp_weaker(a_score, &a_id, b_score, &b_id) {
                    heap.swap(i, parent);
                    i = parent;
                } else {
                    break;
                }
            }
        };

        let sift_down = |heap: &mut Vec<(Uuid, f64)>| {
            let n = heap.len();
            let mut i = 0;
            loop {
                let l = 2 * i + 1;
                let r = 2 * i + 2;
                let mut w = i;
                if l < n {
                    let (w_id, w_score) = heap[w];
                    let (l_id, l_score) = heap[l];
                    if cmp_weaker(w_score, &w_id, l_score, &l_id) {
                        w = l;
                    }
                }
                if r < n {
                    let (w_id, w_score) = heap[w];
                    let (r_id, r_score) = heap[r];
                    if cmp_weaker(w_score, &w_id, r_score, &r_id) {
                        w = r;
                    }
                }
                if w == i {
                    break;
                }
                heap.swap(i, w);
                i = w;
            }
        };

        let mut heap: Vec<(Uuid, f64)> = Vec::with_capacity(k + 1);
        for (id, score) in &raw_scores {
            let candidate = (*id, *score);
            if heap.len() < k {
                let last = heap.len();
                heap.push(candidate);
                sift_up(&mut heap, last);
            } else {
                let (root_id, root_score) = heap[0];
                if cmp_weaker(root_score, &root_id, candidate.1, &candidate.0) {
                    // Candidate outranks the current weakest — displace root.
                    heap[0] = candidate;
                    sift_down(&mut heap);
                }
            }
        }

        // Final descending sort on the small heap (at most k elements), convert score to f32.
        heap.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.to_string().cmp(&b.0.to_string()))
        });
        heap.into_iter().map(|(id, score)| (id, score as f32)).collect()
    }

    /// Tokenise a query string using the index's own tokenizer vocabulary.
    ///
    /// Callers that need to call `top_k` but don't hold a reference to the
    /// tokenizer separately can use this to produce compatible tokens. The
    /// returned tokens are identical to what `index_documents` would produce
    /// for text passed through the same tokenizer.
    pub fn tokenize_query(&self, query: &str) -> Vec<String> {
        self.tokenizer.keyword_tokens(query)
    }

    pub fn document_count(&self) -> usize {
        self.state.total_docs
    }
}
