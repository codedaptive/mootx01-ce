//! Bradley-Terry batch maximum-likelihood ranker — Rust version.
//!
//! Parallel implementation of the Swift `bradleyTerry(outcomes:)` in
//! `NeuronKit/Sources/NeuronKit/Tournament/BradleyTerry.swift`. Neither
//! version leads; both must agree (CLAUDE.md). Conformance is gated by the
//! tests in this module, which fit the same fixtures as the Swift
//! `BradleyTerryTests` and assert the same rankings and strengths to a
//! documented tolerance (1e-6 on the log-strength scale; the two versions
//! run the identical f64 MM iteration so they agree far more tightly in
//! practice).
//!
//! This is the BATCH MLE form — distinct from the cookbook § 8.12
//! online-gradient `bradley_terry_update`. It shares the BT sigmoid
//! model and nothing else.
//!
//! DETERMINISM: no clock, no randomness, no unordered iteration. The
//! competitor set is a `BTreeSet` (lexicographically ordered); every
//! loop walks the resulting `Vec` by index. Tally accumulation is
//! commutative, so the result is invariant to `outcomes` order.

use intellectus_lib::{report, StatSample};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Convergence tolerance: stop when the largest relative change of any
/// linear strength across a sweep falls below this. Matches the Swift
/// `bradleyTerryEpsilon`.
const EPSILON: f64 = 1e-9;

/// Hard cap on MM sweeps. The update converges geometrically on a
/// strongly-connected graph; the cap only bounds ill-conditioned
/// inputs. Matches the Swift `bradleyTerryMaxIterations`.
const MAX_ITERATIONS: usize = 10_000;

/// Standard-normal 0.975 quantile, scaling a standard error to a
/// two-sided 95% interval (`strength ± z·SE`). Matches the Swift
/// `bradleyTerryZ95`.
const Z95: f64 = 1.96;

/// One directed win/loss record: `winner` beat `loser`, `count` times.
///
/// Mirrors the Swift `PairwiseOutcome`. Invariant `winner != loser` is
/// enforced by the fitter (returns `SelfPairing`), not the
/// constructor, so a malformed record can still round-trip serde.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairwiseOutcome {
    pub winner: String,
    pub loser: String,
    /// Times this exact outcome occurred. Non-positive contributes no
    /// tally weight to the fit, but winner and loser are still added
    /// to the competitor set — can influence the connectivity gate.
    /// (Rust has no default arguments; use `single` for `count == 1`.)
    pub count: i64,
}

impl PairwiseOutcome {
    /// A record with an explicit count.
    pub fn new(winner: &str, loser: &str, count: i64) -> Self {
        Self {
            winner: winner.to_string(),
            loser: loser.to_string(),
            count,
        }
    }

    /// A single comparison (`count == 1`) — the Swift default.
    pub fn single(winner: &str, loser: &str) -> Self {
        Self::new(winner, loser, 1)
    }
}

/// A competitor's fitted strength and 95% confidence interval.
///
/// Mirrors the Swift `BradleyTerryScore`. `strength` is on the LOG BT
/// scale, gauge-fixed so all returned strengths sum to zero; the CI is
/// symmetric on that scale (`strength ± 1.96·SE`). See the Swift type's
/// documentation for the full scale and CI semantics.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BradleyTerryScore {
    pub competitor_id: String,
    pub strength: f64,
    pub confidence_low: f64,
    pub confidence_high: f64,
}

/// Errors raised by the fitter. Counterpart of the Swift
/// `MOOTx01Error` cases `.selfPairing` and `.disconnectedComparisonGraph`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TournamentError {
    /// A record had `winner == loser`. Carries the offending ID.
    SelfPairing(String),
    /// The directed win graph is not strongly connected, so the MLE is
    /// not finite (a competitor that never wins has strength −∞). See
    /// the Swift documentation for why strong connectivity is the exact
    /// finiteness condition (Ford 1957; Hunter 2004 § 3).
    DisconnectedComparisonGraph,
    /// More competitors than the fitter admits. Bradley-Terry allocates
    /// dense O(n²) matrices and runs up to MAX_ITERATIONS O(n²) sweeps, so
    /// an unbounded competitor count (e.g. one preference room per
    /// attacker-created room) is a CPU/memory-exhaustion vector. Carries
    /// the offending count. Mirrors Swift `MOOTx01Error.tooManyCompetitors`.
    TooManyCompetitors(usize),
}

/// Fits the Bradley-Terry model and returns one score per competitor,
/// ranked strongest first (ties broken by ascending `competitor_id`).
/// Empty input returns an empty vec.
pub fn bradley_terry(
    outcomes: &[PairwiseOutcome],
) -> Result<Vec<BradleyTerryScore>, TournamentError> {
    // 1. Validate self-pairings regardless of count, then short-circuit
    //    empty input.
    for outcome in outcomes {
        if outcome.winner == outcome.loser {
            return Err(TournamentError::SelfPairing(outcome.winner.clone()));
        }
    }
    if outcomes.is_empty() {
        return Ok(Vec::new());
    }

    // 2. Sorted-unique competitor set. The BTreeSet fixes iteration
    //    order lexicographically; `ids` indexes every array below.
    let mut id_set: BTreeSet<&str> = BTreeSet::new();
    for outcome in outcomes {
        id_set.insert(&outcome.winner);
        id_set.insert(&outcome.loser);
    }
    let ids: Vec<String> = id_set.iter().map(|s| s.to_string()).collect();
    let n = ids.len();
    let mut index: BTreeMap<&str, usize> = BTreeMap::new();
    for (slot, id) in ids.iter().enumerate() {
        index.insert(id.as_str(), slot);
    }

    // 3. Tallies: wins[i] = w_i, pair_count[i][j] = n_ij (symmetric),
    //    win_edge[i][j] = i beat j at least once. Commutative addition,
    //    so order-independent.
    let mut wins = vec![0.0_f64; n];
    let mut pair_count = vec![vec![0.0_f64; n]; n];
    let mut win_edge = vec![vec![false; n]; n];
    for outcome in outcomes {
        if outcome.count <= 0 {
            continue;
        }
        let c = outcome.count as f64;
        let i = index[outcome.winner.as_str()];
        let j = index[outcome.loser.as_str()];
        wins[i] += c;
        pair_count[i][j] += c;
        pair_count[j][i] += c;
        win_edge[i][j] = true;
    }

    // 4. Finiteness gate.
    if !is_strongly_connected(&win_edge, n) {
        return Err(TournamentError::DisconnectedComparisonGraph);
    }

    // 5. MM fixed-point iteration on linear strengths p_i > 0:
    //        p_i ← w_i / Σ_{j≠i} n_ij / (p_i + p_j)
    //    renormalised to geometric mean 1 each sweep (log strengths sum
    //    to zero). Strong connectivity keeps every p_i > 0.
    let mut p = vec![1.0_f64; n];
    for _ in 0..MAX_ITERATIONS {
        let mut p_next = vec![0.0_f64; n];
        for i in 0..n {
            let mut denominator = 0.0;
            for j in 0..n {
                if j == i {
                    continue;
                }
                let nij = pair_count[i][j];
                if nij != 0.0 {
                    denominator += nij / (p[i] + p[j]);
                }
            }
            p_next[i] = wins[i] / denominator;
        }
        let mut log_sum = 0.0;
        for &value in &p_next {
            log_sum += value.ln();
        }
        let geometric_mean = (log_sum / n as f64).exp();
        for value in &mut p_next {
            *value /= geometric_mean;
        }
        let mut max_relative_change = 0.0_f64;
        for i in 0..n {
            let change = (p_next[i] - p[i]).abs() / p[i];
            if change > max_relative_change {
                max_relative_change = change;
            }
        }
        p = p_next;
        if max_relative_change < EPSILON {
            break;
        }
    }

    // 6 & 7. Log strength + diagonal Fisher-information SE.
    //   I_ii = Σ_{j≠i} n_ij · π_ij · π_ji,  π_ij = p_i/(p_i+p_j).
    //   SE_i = 1/√I_ii (diagonal/independence approximation — no matrix
    //   inversion, deterministic, dependency-free; a mild under-estimate
    //   of the true marginal SE). No bootstrap.
    let mut scores: Vec<BradleyTerryScore> = Vec::with_capacity(n);
    for i in 0..n {
        let strength = p[i].ln();
        let mut information = 0.0;
        for j in 0..n {
            if j == i {
                continue;
            }
            let nij = pair_count[i][j];
            if nij == 0.0 {
                continue;
            }
            let total = p[i] + p[j];
            let pi_win = p[i] / total;
            let pj_win = p[j] / total;
            information += nij * pi_win * pj_win;
        }
        let standard_error = 1.0 / information.sqrt();
        let half_width = Z95 * standard_error;
        scores.push(BradleyTerryScore {
            competitor_id: ids[i].clone(),
            strength,
            confidence_low: strength - half_width,
            confidence_high: strength + half_width,
        });
    }

    // 8. Rank strongest first; ties by ascending ID (total, deterministic).
    scores.sort_by(|lhs, rhs| match rhs.strength.partial_cmp(&lhs.strength) {
        Some(std::cmp::Ordering::Equal) | None => lhs.competitor_id.cmp(&rhs.competitor_id),
        Some(order) => order,
    });

    // Self-report: one bt_update event + one competitor_count gauge per call.
    // Off-path cost is a single AtomicBool::load + branch (~1 ns). Matches the
    // Swift bradleyTerry emit sites in BradleyTerry.swift (NEURONKIT_REPORT_001).
    let competitor_count = scores.len();
    {
        use std::time::{SystemTime, UNIX_EPOCH};
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64();
        let mut bt_tags = std::collections::HashMap::new();
        bt_tags.insert("competitor_count".to_string(), competitor_count.to_string());
        report!(StatSample::metric(
            "neuronkit.tournament.bt_update".to_string(),
            1.0,
            bt_tags,
            ts,
        ));
        report!(StatSample::metric(
            "neuronkit.tournament.competitor_count".to_string(),
            competitor_count as f64,
            std::collections::HashMap::new(),
            ts,
        ));
    }

    Ok(scores)
}

/// Whether the directed win graph (edge `i → j` when `win_edge[i][j]`)
/// is strongly connected. A digraph is strongly connected iff, from one
/// vertex, all are reachable AND it is reachable from all (checked on
/// the transposed graph). Two integer-indexed iterative traversals.
fn is_strongly_connected(win_edge: &[Vec<bool>], n: usize) -> bool {
    if n <= 1 {
        return true;
    }
    let forward = reachable_count(n, |from, to| win_edge[from][to]);
    if forward != n {
        return false;
    }
    let reverse = reachable_count(n, |from, to| win_edge[to][from]);
    reverse == n
}

/// Counts vertices reachable from vertex 0 over `has_edge`. Iterative
/// DFS with a visited array; no recursion.
fn reachable_count(n: usize, has_edge: impl Fn(usize, usize) -> bool) -> usize {
    let mut visited = vec![false; n];
    let mut stack = vec![0usize];
    visited[0] = true;
    let mut reached = 1;
    while let Some(vertex) = stack.pop() {
        for (neighbour, seen) in visited.iter_mut().enumerate() {
            if !*seen && has_edge(vertex, neighbour) {
                *seen = true;
                reached += 1;
                stack.push(neighbour);
            }
        }
    }
    reached
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Strongly-connected transitive dominance ladder, identical to the
    /// Swift `dominanceLadder` fixture: A>B ×3, B>C ×3, A>C ×3, C>A ×1.
    fn dominance_ladder() -> Vec<PairwiseOutcome> {
        vec![
            PairwiseOutcome::new("A", "B", 3),
            PairwiseOutcome::new("B", "C", 3),
            PairwiseOutcome::new("A", "C", 3),
            PairwiseOutcome::new("C", "A", 1),
        ]
    }

    /// Conformance anchor: values produced by the Swift version for the
    /// dominance ladder. The Rust version must reproduce them to 1e-6.
    /// Swift: A strength=1.2240355728942105, lo=-0.9407234625180512,
    ///        hi=3.388794608306472; B strength≈0 (1.03e-9),
    ///        lo=-1.9095211749834127, hi=1.909521177047359;
    ///        C strength=-1.2240355739261835, lo=-3.388794610513182,
    ///        hi=0.940723462660815.
    #[test]
    fn conformance_matches_swift_port_to_tolerance() {
        let scores = bradley_terry(&dominance_ladder()).unwrap();
        let tol = 1e-6;
        assert_eq!(
            scores
                .iter()
                .map(|s| s.competitor_id.as_str())
                .collect::<Vec<_>>(),
            vec!["A", "B", "C"]
        );

        assert!((scores[0].strength - 1.2240355728942105).abs() < tol);
        assert!((scores[0].confidence_low - (-0.9407234625180512)).abs() < tol);
        assert!((scores[0].confidence_high - 3.388794608306472).abs() < tol);

        assert!(scores[1].strength.abs() < tol); // B ≈ 0
        assert!((scores[1].confidence_low - (-1.9095211749834127)).abs() < tol);
        assert!((scores[1].confidence_high - 1.909521177047359).abs() < tol);

        assert!((scores[2].strength - (-1.2240355739261835)).abs() < tol);
        assert!((scores[2].confidence_low - (-3.388794610513182)).abs() < tol);
        assert!((scores[2].confidence_high - 0.940723462660815).abs() < tol);
    }

    #[test]
    fn same_inputs_produce_identical_scores() {
        assert_eq!(
            bradley_terry(&dominance_ladder()).unwrap(),
            bradley_terry(&dominance_ladder()).unwrap()
        );
    }

    #[test]
    fn ranking_is_invariant_to_input_order() {
        let mut reversed = dominance_ladder();
        reversed.reverse();
        assert_eq!(
            bradley_terry(&dominance_ladder()).unwrap(),
            bradley_terry(&reversed).unwrap()
        );
    }

    #[test]
    fn transitive_dominance_ranks_a_over_b_over_c() {
        let scores = bradley_terry(&dominance_ladder()).unwrap();
        assert!(scores[0].strength > scores[1].strength);
        assert!(scores[1].strength > scores[2].strength);
        assert_eq!(scores[0].competitor_id, "A");
    }

    #[test]
    fn every_score_has_finite_ci_bracketing_strength() {
        for s in bradley_terry(&dominance_ladder()).unwrap() {
            assert!(
                s.strength.is_finite()
                    && s.confidence_low.is_finite()
                    && s.confidence_high.is_finite()
            );
            assert!(s.confidence_low <= s.strength && s.strength <= s.confidence_high);
        }
    }

    #[test]
    fn symmetric_outcomes_produce_equal_strengths() {
        let symmetric = vec![
            PairwiseOutcome::single("A", "B"),
            PairwiseOutcome::single("B", "A"),
            PairwiseOutcome::single("B", "C"),
            PairwiseOutcome::single("C", "B"),
            PairwiseOutcome::single("A", "C"),
            PairwiseOutcome::single("C", "A"),
        ];
        for s in bradley_terry(&symmetric).unwrap() {
            assert!(s.strength.abs() < 1e-9);
            assert!(s.confidence_low < 0.0 && s.confidence_high > 0.0);
        }
    }

    #[test]
    fn count_aggregation_equals_repeated_singles() {
        let aggregated = vec![
            PairwiseOutcome::new("A", "B", 5),
            PairwiseOutcome::new("B", "A", 2),
        ];
        let mut expanded = Vec::new();
        for _ in 0..5 {
            expanded.push(PairwiseOutcome::single("A", "B"));
        }
        for _ in 0..2 {
            expanded.push(PairwiseOutcome::single("B", "A"));
        }
        assert_eq!(
            bradley_terry(&aggregated).unwrap(),
            bradley_terry(&expanded).unwrap()
        );
    }

    #[test]
    fn self_pairing_errors() {
        let bad = vec![PairwiseOutcome::single("A", "A")];
        assert_eq!(
            bradley_terry(&bad),
            Err(TournamentError::SelfPairing("A".to_string()))
        );
    }

    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(bradley_terry(&[]).unwrap(), Vec::new());
    }

    #[test]
    fn disconnected_components_error() {
        let islands = vec![
            PairwiseOutcome::single("A", "B"),
            PairwiseOutcome::single("B", "A"),
            PairwiseOutcome::single("C", "D"),
            PairwiseOutcome::single("D", "C"),
        ];
        assert_eq!(
            bradley_terry(&islands),
            Err(TournamentError::DisconnectedComparisonGraph)
        );
    }

    #[test]
    fn pure_transitive_is_not_finite() {
        let pure = vec![
            PairwiseOutcome::single("A", "B"),
            PairwiseOutcome::single("B", "C"),
            PairwiseOutcome::single("A", "C"),
        ];
        assert_eq!(
            bradley_terry(&pure),
            Err(TournamentError::DisconnectedComparisonGraph)
        );
    }
}
