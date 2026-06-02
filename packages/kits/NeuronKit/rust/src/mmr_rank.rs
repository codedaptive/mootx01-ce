//! Standalone Maximal Marginal Relevance (MMR) diversity rerank — Rust
//! version of the Swift `MMREngine` / `mmrRank` in
//! `NeuronKit/Sources/NeuronKit/MMRRank.swift` (NEURONKIT_SPEC § 4.1
//! step 4). Per CLAUDE.md neither version leads; both run identical math and
//! are gated against the shared hand-computed fixtures.
//!
//! MMR re-orders a recall set to balance relevance against redundancy.
//! Each selection step picks the candidate maximising
//!
//! ```text
//! lambda * relevance(candidate, query) - (1-lambda) * maxSim(candidate, selected)
//! ```
//!
//! Relevance and similarity both derive from EngramLib's Hamming
//! `distance` (range 0..=256) normalised into a [0, 1] closeness:
//!
//! ```text
//! closeness = 1 - distance / 256.0
//! ```
//!
//! so identical engrams score 1.0 and bit-inverses 0.0.
//!
//! PORT SHAPE: the Swift `mmrRank(candidates:query:lambda:k:fingerprint:)`
//! wrapper threads `Drawer` rows + a caller-owned fingerprint closure. The
//! Rust version has no `Drawer` (no LocusKit dependency), so it implements the
//! PURE selection core — `mmr_select`, which operates directly on the
//! engram fingerprints and returns selected indices. That is exactly the
//! Swift `MMREngine.select` surface, and it is the conformance-gated unit
//! the Swift `MMRRankTests` already pin. A `Drawer`-facing wrapper is not
//! portable until a Rust estate row type exists; the index-returning core
//! is the portable, gated reference.
//!
//! Determinism: no clock, no randomness. Ties break on ascending input
//! index (strict `>` over an ascending scan), reproduced bit-for-bit
//! across versions.

use engram_lib::{Engram, EngramLib};

/// Maximum Hamming distance between two 256-bit engrams. `distance`
/// returns 0..=256, so dividing by this maps any distance into [0, 1].
/// Named (not inlined) so the normalisation basis matches the Swift
/// `MMREngine.maxEngramDistance` constant exactly.
const MAX_ENGRAM_DISTANCE: f32 = 256.0;

/// Hamming distance normalised into a [0, 1] closeness score:
/// `1 − distance / MAX_ENGRAM_DISTANCE`. Identical engrams → 1.0, complete
/// bit-inverses → 0.0. Serves both the relevance term (candidate vs query)
/// and the similarity term (candidate vs selected).
fn closeness(a: &Engram, b: &Engram) -> f32 {
    1.0 - (EngramLib::distance(a, b) as f32) / MAX_ENGRAM_DISTANCE
}

/// Greedy MMR selection. Returns selected indices into `fingerprints`, in
/// MMR order, truncated to `k`. Mirrors the Swift `MMREngine.select`:
///
/// - `k <= 0` or empty input → empty.
/// - Complexity O(k · n): each round scans the remaining candidates and
///   folds only the just-picked row into a running max-similarity vector
///   (not recomputed against the whole selected set).
/// - Tie-break: ascending input-index scan with strict `>` keeps the
///   earliest candidate when scores are equal.
pub fn mmr_select(fingerprints: &[Engram], query: &Engram, lambda: f32, k: i64) -> Vec<usize> {
    if k <= 0 || fingerprints.is_empty() {
        return Vec::new();
    }
    let n = fingerprints.len();
    let limit = std::cmp::min(k as usize, n);

    // Relevance term per candidate — fixed across rounds.
    let relevance: Vec<f32> = fingerprints.iter().map(|f| closeness(f, query)).collect();

    // Running max similarity of each candidate to the selected set.
    let mut max_sim_to_selected = vec![0.0f32; n];
    let mut is_selected = vec![false; n];
    let mut selected: Vec<usize> = Vec::with_capacity(limit);

    while selected.len() < limit {
        let mut best_idx: isize = -1;
        let mut best_score = f32::NEG_INFINITY;
        for i in 0..n {
            if is_selected[i] {
                continue;
            }
            // MMR(i) = λ·relevance(i) − (1−λ)·maxSim(i, selected).
            let score = lambda * relevance[i] - (1.0 - lambda) * max_sim_to_selected[i];
            // Strict `>` + ascending scan = input-index tie-break.
            if score > best_score {
                best_score = score;
                best_idx = i as isize;
            }
        }

        // best_idx is always valid: the loop runs only while an unselected
        // candidate remains, and any finite score exceeds the -inf seed.
        let pick = best_idx as usize;
        is_selected[pick] = true;
        selected.push(pick);

        // Fold the new pick into every remaining candidate's running max.
        let pick_fp = &fingerprints[pick];
        for i in 0..n {
            if is_selected[i] {
                continue;
            }
            let sim = closeness(&fingerprints[i], pick_fp);
            if sim > max_sim_to_selected[i] {
                max_sim_to_selected[i] = sim;
            }
        }
    }

    selected
}

/// Convenience wrapper that returns the reranked fingerprints (cloned) in
/// MMR order, rather than indices. Equivalent to applying `mmr_select`'s
/// index order to the input — provided so a non-`Drawer` caller can rerank
/// engrams directly. The index-returning `mmr_select` is the canonical,
/// conformance-gated form.
pub fn mmr_rank(fingerprints: &[Engram], query: &Engram, lambda: f32, k: i64) -> Vec<Engram> {
    mmr_select(fingerprints, query, lambda, k)
        .into_iter()
        .map(|i| fingerprints[i].clone())
        .collect()
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror the Swift `MMRRankTests` hand-computed
    //! vectors EXACTLY. Query = all-zero engram, so distance-to-query =
    //! popcount, making every relevance/similarity term hand-checkable.
    //! (Fenced as text so the indented arithmetic is not run as a doctest.)
    //!
    //! ```text
    //!   A: bits 0..40 set  -> popcount 40, dist(A,Q)=40, rel=0.84375
    //!   B: bits 0..44 set  -> popcount 44, dist(B,Q)=44, rel=0.828125
    //!                         dist(A,B)=4 (bits 40..43), sim(A,B)=0.984375
    //!   C: 80 bits in blocks 1..2, disjoint from A,B
    //!                      -> dist(C,Q)=80, rel=0.6875; dist(C,A)=120, sim=0.53125
    //!
    //!   lambda=0.7 over input [A,B,C]:
    //!     step1: 0.7*rel -> A 0.590625, B 0.5796875, C 0.48125 -> pick A
    //!     step2: 0.7*rel - 0.3*sim(x,A) -> B 0.284375, C 0.321875 -> pick C
    //!     step3: B  =>  MMR order [A, C, B]  (pure-relevance would be [A,B,C])
    //! ```
    use super::*;

    /// Engram with the low `count` bits (0..count) set across the four
    /// 64-bit blocks. Mirrors the Swift fixtures' bit ranges.
    fn low_bits(count: usize) -> Engram {
        let mut blocks = [0u64; 4];
        for bit in 0..count {
            blocks[bit / 64] |= 1u64 << (bit % 64);
        }
        Engram::new(blocks[0], blocks[1], blocks[2], blocks[3])
    }

    fn fixture_a() -> Engram {
        low_bits(40)
    }
    fn fixture_b() -> Engram {
        low_bits(44)
    }
    /// C: 80 bits in blocks 1..2 — block1 all 64 set, block2 low 16 set;
    /// disjoint from A and B (which live in block0).
    fn fixture_c() -> Engram {
        Engram::new(0, u64::MAX, (1u64 << 16) - 1, 0)
    }
    fn query() -> Engram {
        Engram::new(0, 0, 0, 0)
    }

    #[test]
    fn fixture_distances_are_as_documented() {
        let q = query();
        assert_eq!(EngramLib::distance(&fixture_a(), &q), 40);
        assert_eq!(EngramLib::distance(&fixture_b(), &q), 44);
        assert_eq!(EngramLib::distance(&fixture_c(), &q), 80);
        assert_eq!(EngramLib::distance(&fixture_a(), &fixture_b()), 4);
        assert_eq!(EngramLib::distance(&fixture_a(), &fixture_c()), 120);
    }

    #[test]
    fn mmr_reorders_for_diversity() {
        // λ=0.7 over [A,B,C] selects [A, C, B] — diversity pulls C ahead
        // of the near-duplicate B. The conformance anchor.
        let fps = [fixture_a(), fixture_b(), fixture_c()];
        let order = mmr_select(&fps, &query(), 0.7, 3);
        assert_eq!(order, vec![0, 2, 1]);
    }

    #[test]
    fn lambda_one_is_pure_relevance() {
        // λ=1.0 ignores similarity → pure relevance order = ascending
        // distance-to-query = [A(40), B(44), C(80)].
        let fps = [fixture_a(), fixture_b(), fixture_c()];
        let order = mmr_select(&fps, &query(), 1.0, 3);
        assert_eq!(order, vec![0, 1, 2]);
    }

    #[test]
    fn k_truncates() {
        let fps = [fixture_a(), fixture_b(), fixture_c()];
        assert_eq!(mmr_select(&fps, &query(), 0.7, 1), vec![0]);
        assert_eq!(mmr_select(&fps, &query(), 0.7, 2), vec![0, 2]);
    }

    #[test]
    fn edge_cases_return_empty() {
        let fps = [fixture_a()];
        assert!(mmr_select(&fps, &query(), 0.7, 0).is_empty());
        assert!(mmr_select(&fps, &query(), 0.7, -1).is_empty());
        assert!(mmr_select(&[], &query(), 0.7, 5).is_empty());
    }

    #[test]
    fn k_exceeding_count_returns_all_reranked() {
        let fps = [fixture_a(), fixture_b(), fixture_c()];
        let order = mmr_select(&fps, &query(), 0.7, 99);
        assert_eq!(order.len(), 3);
        assert_eq!(order, vec![0, 2, 1]);
    }

    #[test]
    fn equal_scores_tie_break_by_ascending_index() {
        // Two identical fingerprints + λ=1.0: equal relevance, so the
        // ascending-index tie-break keeps index 0 before index 1.
        let fp = low_bits(10);
        let fps = [fp.clone(), fp.clone()];
        let order = mmr_select(&fps, &query(), 1.0, 2);
        assert_eq!(order, vec![0, 1]);
    }

    #[test]
    fn rank_wrapper_returns_reranked_fingerprints() {
        let fps = [fixture_a(), fixture_b(), fixture_c()];
        let ranked = mmr_rank(&fps, &query(), 0.7, 3);
        // [A, C, B] — C is the disjoint 80-bit fixture.
        assert_eq!(EngramLib::distance(&ranked[0], &query()), 40); // A
        assert_eq!(EngramLib::distance(&ranked[1], &query()), 80); // C
        assert_eq!(EngramLib::distance(&ranked[2], &query()), 44); // B
    }
}
