//! MaxSimScorer — Lane E1: Exact-A (exhaustive) binary MaxSim scorer.
//!
//! Implements binary ColBERT MaxSim late interaction (retrieval algorithms
//! reference §3.B, Exact-A definition) over 256-bit SimHash Engram tokens:
//!
//! ```text
//! MaxSim(Q, D) = Σ_{q ∈ Q} ( 256 − min_{d ∈ D} hamming(q, d) )
//! ```
//!
//! The computation is exhaustive: for every query token, every document token
//! is compared. "Exhaustive" is the correctness guarantee — no document is
//! skipped, no candidate pruning is applied. Documents are ranked by MaxSim
//! descending, ties broken by item_id ascending (§0.3 universal tie-break).
//!
//! SCOPE (read before modifying):
//!   This file implements Exact-A only. The MIH-accelerated two-stage variant
//!   (Exact-B) and MIH-based candidate generation are explicitly out of scope
//!   for this lane. Exact-A scores every document in the input set.
//!
//! I-7 (arch spec §3.1, §3.4): ALL Hamming distances go through `EngramLib`
//! (which routes to SubstrateKernel). There is no XOR or popcount in this
//! file. A raw popcount here would bypass the four-way conformance gate.
//!
//! Determinism (retrieval algorithms reference §3.C):
//!   1. Token similarity is integer: 256 − hamming(q, d). No floats.
//!   2. Inner reduction is min over hamming. Min ties are value-irrelevant
//!      (only the minimal distance matters, not which token achieved it).
//!   3. Query-token iteration order is input order (fixed for trace
//!      reproducibility; integer addition is commutative so the score value
//!      is independent of query-token order).
//!   4. Documents are iterated in sorted ascending item_id order.
//!   5. Result ordering: (score DESC, item_id ASC), truncated to k.
//!   6. Integer arithmetic only. No floats on this path.
//!
//! This scorer is the conformance reference for Lane E1. Any accelerated
//! variant must produce identical results — it is the oracle.

use std::collections::BTreeMap;

use engram_lib::{Engram, EngramLib};

// MARK: - MaxSimHit

/// One document's MaxSim result.
///
/// `score` is the integer MaxSim value: Σ_{q ∈ Q}(256 − min_{d ∈ D} hamming(q,d)).
/// Range: [0, 256 × |Q|].
///
/// Results are ordered (score DESC, item_id ASC) per §0.3 and §3.C rule 5.
/// Equal scores are broken by item_id ascending — the smaller item_id wins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MaxSimHit {
    /// Document identifier. Matches the key in the documents map.
    pub item_id: String,
    /// Integer MaxSim score. Larger = more relevant.
    ///
    /// Maximum: 256 × |Q| (all query tokens at Hamming distance 0).
    /// Minimum: 0 (all query tokens at Hamming distance 256 from every doc token).
    pub score: u32,
}

impl MaxSimHit {
    /// Designated constructor.
    pub fn new(item_id: impl Into<String>, score: u32) -> Self {
        MaxSimHit { item_id: item_id.into(), score }
    }
}

// MARK: - MaxSimScorer

/// Exact-A binary ColBERT MaxSim scorer.
///
/// Computes `MaxSim(Q, D) = Σ_{q ∈ Q}(256 − min_{d ∈ D} hamming(q, d))`
/// exhaustively over every document supplied in the input set.
///
/// Parallel to Swift `MaxSimScorer`. Both ports produce bit-identical scores
/// on the same inputs, as required by the four-way conformance contract.
///
/// # Usage
/// ```ignore
/// use vectorkit::engine::max_sim::MaxSimScorer;
///
/// let scorer = MaxSimScorer::new();
/// let results = scorer.score(&query_tokens, &docs, 10);
/// ```
pub struct MaxSimScorer {
    // MaxSimScorer is stateless: every call creates its own EngramLib session.
    // For hot-loop use, callers may prefer to pass a pre-created session; for
    // now, the per-call session is idiomatic and consistent with the Swift port.
}

impl MaxSimScorer {
    /// Create a new scorer. Stateless; no allocation.
    pub fn new() -> Self {
        MaxSimScorer {}
    }

    /// Score every document against the query and return the top-k by MaxSim.
    ///
    /// Algorithm (Exact-A, retrieval algorithms reference §3.B):
    /// ```text
    /// for each document D, iterated in ascending item_id order:
    ///     score = 0
    ///     for each query token q ∈ Q (input order):
    ///         min_dist = min over d ∈ D of hamming(q, d)   // via EngramLib
    ///         score   += 256 − min_dist
    /// sort (score DESC, item_id ASC), return first k.
    /// ```
    ///
    /// All Hamming calls go through `EngramLib::distance`, which routes to
    /// SubstrateKernel — I-7 absolute. No XOR or popcount appears in this method.
    ///
    /// # Edge cases
    /// - `query_tokens` empty: every document scores 0; ordering is item_id ASC.
    /// - Document token slice empty: every query token contributes 0 (min over
    ///   empty set defined as 256; 256 − 256 = 0). Docs with no tokens score 0.
    /// - `k == 0`: returns empty Vec.
    /// - `documents` empty: returns empty Vec.
    ///
    /// # Parameters
    /// - `query_tokens`: Ordered slice of Engram token fingerprints for the query.
    /// - `documents`: Mapping from item_id to the document's Engram token slice.
    ///   Uses `BTreeMap` so iteration is always in ascending key order (§3.C rule 4).
    /// - `k`: Maximum results to return. Pass `usize::MAX` for the full ranked list.
    ///
    /// # Returns
    /// Up to `k` `MaxSimHit` values sorted (score DESC, item_id ASC).
    pub fn score(
        &self,
        query_tokens: &[Engram],
        documents: &BTreeMap<String, Vec<Engram>>,
        k: usize,
    ) -> Vec<MaxSimHit> {
        if k == 0 || documents.is_empty() {
            return Vec::new();
        }

        // BTreeMap iterates in ascending key order by contract (§3.C rule 4).
        // No additional sorting of keys is needed.
        let mut results: Vec<MaxSimHit> = documents
            .iter()
            .map(|(item_id, doc_tokens)| {
                let score = compute_max_sim(query_tokens, doc_tokens);
                MaxSimHit { item_id: item_id.clone(), score }
            })
            .collect();

        // Sort: score DESC primary, item_id ASC tiebreak (§0.3 universal rule).
        // Truncation to k happens after the total-order sort (§0.4 rule 4).
        results.sort_by(|a, b| {
            // Higher score wins; ties go to smaller item_id.
            b.score.cmp(&a.score).then(a.item_id.cmp(&b.item_id))
        });

        results.truncate(k);
        results
    }
}

// MARK: - Private helpers

/// Compute MaxSim(Q, D) for a single document.
///
/// `MaxSim(Q, D) = Σ_{q ∈ Q} (256 − min_{d ∈ D} hamming(q, d))`
///
/// All Hamming distances are delegated to `EngramLib::distance`, which routes
/// through SubstrateKernel — I-7 absolute. No XOR or popcount appears here.
///
/// Empty `query_tokens` or empty `doc_tokens` → returns 0.
fn compute_max_sim(query_tokens: &[Engram], doc_tokens: &[Engram]) -> u32 {
    if query_tokens.is_empty() || doc_tokens.is_empty() {
        return 0;
    }

    let mut total_score: u32 = 0;

    for query_token in query_tokens {
        // Find the minimum Hamming distance from this query token to any
        // document token. I-7: all distance calls go through EngramLib.
        //
        // We do not care which document token achieved the minimum
        // (§3.C rule 2: min-ties are value-irrelevant for the score).
        let min_dist = doc_tokens
            .iter()
            .map(|d| EngramLib::distance(query_token, d))
            .min()
            .unwrap(); // safe: doc_tokens is non-empty (checked above)

        // Integer similarity contribution (§3.C rule 1, §0.2 integer-only).
        // 256 − min_dist is in [0, 256]; summing over |Q| tokens stays in u32.
        total_score += 256 - min_dist;
    }

    total_score
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Build an Engram from an 8-bit value by placing the byte in the low
    /// byte of block0. All other bits are zero.
    ///
    /// Mirrors the Swift helper `e8(_:)`. Lets us write §3.E test vectors using
    /// 8-bit binary literals while working with real 256-bit Engrams. The Hamming
    /// distance between two such Engrams equals the 8-bit Hamming distance because
    /// no bits outside the low byte are set.
    fn e8(byte: u8) -> Engram {
        Engram::new(byte as u64, 0, 0, 0)
    }

    /// Build a `BTreeMap<String, Vec<Engram>>` from a vec of (key, token-vec) pairs.
    fn docs(pairs: Vec<(&str, Vec<Engram>)>) -> BTreeMap<String, Vec<Engram>> {
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
    }

    /// Naive double-loop MaxSim reference (independent of MaxSimScorer internals).
    ///
    /// Returns Vec<MaxSimHit> sorted (score DESC, item_id ASC), truncated to k.
    /// This is the oracle for the exactness cross-check (§4 harness notes).
    fn naive_max_sim(
        query_tokens: &[Engram],
        documents: &BTreeMap<String, Vec<Engram>>,
        k: usize,
    ) -> Vec<MaxSimHit> {
        let mut results: Vec<MaxSimHit> = documents
            .iter()
            .map(|(item_id, doc_tokens)| {
                let mut doc_score: u32 = 0;
                for q in query_tokens {
                    if doc_tokens.is_empty() { continue; }
                    let min_dist = doc_tokens
                        .iter()
                        .map(|d| EngramLib::distance(q, d))
                        .min()
                        .unwrap();
                    doc_score += 256 - min_dist;
                }
                MaxSimHit { item_id: item_id.clone(), score: doc_score }
            })
            .collect();
        results.sort_by(|a, b| b.score.cmp(&a.score).then(a.item_id.cmp(&b.item_id)));
        results.truncate(k);
        results
    }

    // ── §3.E Canonical vector tests ───────────────────────────────────────────

    /// Vector COLBERT-1 (§3.E): basic MaxSim, 2 docs, exhaustive Exact-A.
    ///
    /// Query:  Q  = [0b00000000, 0b11110000]
    /// Doc 1:  D1 = [0b00000001, 0b11100000]
    /// Doc 2:  D2 = [0b11111111, 0b00001111]
    ///
    /// Using W=256 (sim = 256 − hamming):
    ///   doc1: q0 → min(1,3)=1 → 255; q1 → min(5,1)=1 → 255 → score=510
    ///   doc2: q0 → min(8,4)=4 → 252; q1 → min(4,8)=4 → 252 → score=504
    #[test]
    fn colbert1_basic_max_sim() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b00000000), e8(0b11110000)];
        let documents = docs(vec![
            ("doc1", vec![e8(0b00000001), e8(0b11100000)]),
            ("doc2", vec![e8(0b11111111), e8(0b00001111)]),
        ]);

        let results = scorer.score(&q, &documents, 2);

        assert_eq!(results.len(), 2, "expected 2 results");
        assert_eq!(results[0].item_id, "doc1");
        assert_eq!(results[0].score,   510);
        assert_eq!(results[1].item_id, "doc2");
        assert_eq!(results[1].score,   504);

        // Cross-check against naive reference.
        let reference = naive_max_sim(&q, &documents, 2);
        assert_eq!(results, reference, "scorer must match naive reference");
    }

    /// Vector COLBERT-2 (§3.E): score tie broken by item_id ascending.
    ///
    /// doc1 and doc3 both score 510; doc1 < doc3 → doc1 wins the tie.
    #[test]
    fn colbert2_tie_break() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b00000000), e8(0b11110000)];
        let documents = docs(vec![
            ("doc1", vec![e8(0b00000001), e8(0b11100000)]),
            ("doc2", vec![e8(0b11111111), e8(0b00001111)]),
            ("doc3", vec![e8(0b00000001), e8(0b11100000)]),  // same tokens as doc1
        ]);

        let results = scorer.score(&q, &documents, 2);

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].item_id, "doc1");
        assert_eq!(results[0].score,   510);
        assert_eq!(results[1].item_id, "doc3");
        assert_eq!(results[1].score,   510);
        // doc2 (score=504) must not appear.
        assert!(!results.iter().any(|h| h.item_id == "doc2"));
    }

    /// Vector COLBERT-3 (§3.E): min-tie inside a doc is value-irrelevant.
    ///
    /// Both doc tokens are at hamming=1 from the query token → min=1 → sim=255.
    #[test]
    fn colbert3_min_tie_value_irrelevant() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b00001111)];
        let documents = docs(vec![
            // 0b00001110: bit 0 cleared → hamming=1
            // 0b00001101: bit 1 cleared → hamming=1
            ("doc4", vec![e8(0b00001110), e8(0b00001101)]),
        ]);

        let results = scorer.score(&q, &documents, 1);

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].item_id, "doc4");
        assert_eq!(results[0].score,   255);  // 256 - 1 = 255
    }

    // ── Determinism tests ─────────────────────────────────────────────────────

    /// Same inputs → identical output across multiple calls.
    #[test]
    fn determinism_repeated_calls() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b10101010), e8(0b01010101)];
        let documents = docs(vec![
            ("a", vec![e8(0b11110000), e8(0b00001111)]),
            ("b", vec![e8(0b10101010)]),
            ("c", vec![e8(0b00000000), e8(0b11111111), e8(0b10101010)]),
        ]);

        let r1 = scorer.score(&q, &documents, 3);
        let r2 = scorer.score(&q, &documents, 3);
        let r3 = scorer.score(&q, &documents, 3);

        assert_eq!(r1, r2);
        assert_eq!(r2, r3);
    }

    // ── Edge case tests ───────────────────────────────────────────────────────

    /// Empty query tokens → all documents score 0, ordered by item_id ASC.
    #[test]
    fn empty_query_tokens() {
        let scorer = MaxSimScorer::new();

        let documents = docs(vec![
            ("z", vec![e8(0b11111111)]),
            ("a", vec![e8(0b00000000)]),
            ("m", vec![e8(0b10101010)]),
        ]);

        let results = scorer.score(&[], &documents, 10);

        assert_eq!(results.len(), 3);
        for r in &results {
            assert_eq!(r.score, 0, "empty query → score 0 for {}", r.item_id);
        }
        // With all scores 0, ordering is item_id ASC: a < m < z.
        assert_eq!(results[0].item_id, "a");
        assert_eq!(results[1].item_id, "m");
        assert_eq!(results[2].item_id, "z");
    }

    /// Empty document token slice → document scores 0.
    #[test]
    fn empty_document_tokens() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b11110000)];
        let documents = docs(vec![
            ("empty",  vec![]),
            ("normal", vec![e8(0b11110001)]),  // hamming=1 → 255
        ]);

        let results = scorer.score(&q, &documents, 2);

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].item_id, "normal");
        assert_eq!(results[0].score,   255);
        assert_eq!(results[1].item_id, "empty");
        assert_eq!(results[1].score,   0);
    }

    /// k=0 returns empty Vec.
    #[test]
    fn k_zero_returns_empty() {
        let scorer = MaxSimScorer::new();
        let documents = docs(vec![("doc", vec![e8(0)])]);
        let results = scorer.score(&[e8(0xFF)], &documents, 0);
        assert!(results.is_empty());
    }

    /// Empty documents BTreeMap returns empty Vec.
    #[test]
    fn empty_documents_returns_empty() {
        let scorer = MaxSimScorer::new();
        let documents: BTreeMap<String, Vec<Engram>> = BTreeMap::new();
        let results = scorer.score(&[e8(0xFF)], &documents, 10);
        assert!(results.is_empty());
    }

    /// k truncation returns min(k, documents.len()) results.
    #[test]
    fn k_truncation() {
        let scorer = MaxSimScorer::new();

        let q = vec![e8(0b00000000)];
        let documents = docs(vec![
            ("a", vec![e8(0b00000001)]),  // hamming=1, score=255
            ("b", vec![e8(0b00000011)]),  // hamming=2, score=254
            ("c", vec![e8(0b00000111)]),  // hamming=3, score=253
            ("d", vec![e8(0b00001111)]),  // hamming=4, score=252
        ]);

        let r2 = scorer.score(&q, &documents, 2);
        assert_eq!(r2.len(), 2);
        assert_eq!(r2[0].item_id, "a");
        assert_eq!(r2[1].item_id, "b");

        let r1 = scorer.score(&q, &documents, 1);
        assert_eq!(r1.len(), 1);
        assert_eq!(r1[0].item_id, "a");

        let r10 = scorer.score(&q, &documents, 10);
        assert_eq!(r10.len(), 4);  // only 4 docs
    }

    // ── Exactness cross-check (reference gate) ────────────────────────────────

    /// Exactness gate: MaxSimScorer must match the naive double-loop reference
    /// on random 256-bit Engram inputs across several configurations.
    ///
    /// Seed: 0xCAFE_BABE_DEAD_BEEF (the canonical substrate seed).
    #[test]
    fn exactness_gate_random_engrams() {
        let scorer = MaxSimScorer::new();

        // xorshift64 with canonical seed.
        let mut rng: u64 = 0xCAFE_BABE_DEAD_BEEF;
        let mut next_u64 = || -> u64 {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng
        };
        let mut random_engram = || -> Engram {
            Engram::new(next_u64(), next_u64(), next_u64(), next_u64())
        };

        let configs: &[(usize, usize, usize, usize)] = &[
            (3, 2, 3, 2),
            (5, 3, 4, 3),
            (8, 1, 5, 4),
            (4, 4, 2, 10),
            (6, 2, 1, 3),
        ];

        for &(n_docs, n_query_toks, n_doc_toks, k) in configs {
            let mut documents: BTreeMap<String, Vec<Engram>> = BTreeMap::new();
            for i in 0..n_docs {
                let tokens: Vec<Engram> = (0..n_doc_toks).map(|_| random_engram()).collect();
                documents.insert(format!("item{}", i), tokens);
            }
            let query: Vec<Engram> = (0..n_query_toks).map(|_| random_engram()).collect();

            let scored    = scorer.score(&query, &documents, k);
            let reference = naive_max_sim(&query, &documents, k);

            assert_eq!(
                scored, reference,
                "mismatch on config (n_docs={}, n_query={}, n_doc_toks={}, k={})",
                n_docs, n_query_toks, n_doc_toks, k
            );
        }
    }

    /// Perfect match: single token, identical doc token → score = 256.
    #[test]
    fn perfect_match_score_256() {
        let scorer = MaxSimScorer::new();

        let token = Engram::new(0xDEAD_BEEF_CAFE_BABE, 0x1234_5678_9ABC_DEF0, 0, 0);
        let documents = docs(vec![
            ("exact", vec![token.clone()]),
            ("other", vec![Engram::new(0, 0, 0, 0)]),
        ]);

        let results = scorer.score(&[token], &documents, 2);
        assert_eq!(results[0].item_id, "exact");
        assert_eq!(results[0].score,   256);
    }
}
