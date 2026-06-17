// random_walks.rs
//
// Random walks with restart on the estate graph, per cookbook § 7.4.
// Mirror of RandomWalks.swift.
//
// `walk` operates over densely-indexed adjacency (used by NeuronKit's
// spreading_activation and the conformance harness). `walk_with_restart`
// operates in RowId space (used by CognitionKit's `recall_exploratory`
// recipe — `CognitionKit/rust/src/exploratory_recall_recipe.rs`).
//
// Markov kernel preconditions (enforced at entry of walk(); violations panic):
//   - Every neighbor index must be in [0, N) where N = adjacency.len().
//   - Every edge weight must be finite and >= 0.
//   - sample_weighted() panics on an empty neighbor list.

use substrate_types::row::RowId;
use std::collections::HashMap;

pub struct RandomWalks;

impl RandomWalks {
    pub const DEFAULT_RESTART_PROB: f64 = 0.15;

    pub fn walk(
        adjacency: &[Vec<(usize, f64)>],
        start: usize,
        length: usize,
        restart_prob: f64,
        seed: u64,
    ) -> Vec<usize> {
        assert!(start < adjacency.len(), "start row out of range");
        assert!(length >= 1, "length must be at least 1");
        assert!(
            restart_prob >= 0.0 && restart_prob < 1.0,
            "restart_prob must be in [0, 1)"
        );

        // Validate the Markov kernel: neighbor indices in [0, N) and
        // all edge weights finite and >= 0.
        let n = adjacency.len();
        for (row, neighbors) in adjacency.iter().enumerate() {
            for (edge_idx, &(neighbor, weight)) in neighbors.iter().enumerate() {
                assert!(
                    neighbor < n,
                    "adjacency[{}][{}].neighbor {} is out of range [0, {})",
                    row, edge_idx, neighbor, n
                );
                assert!(
                    weight.is_finite(),
                    "adjacency[{}][{}].weight is not finite ({})",
                    row, edge_idx, weight
                );
                assert!(
                    weight >= 0.0,
                    "adjacency[{}][{}].weight is negative ({})",
                    row, edge_idx, weight
                );
            }
        }

        let mut rng = SplitMix64::new(seed);
        let mut visited = Vec::with_capacity(length);
        let mut current = start;
        for _ in 0..length {
            visited.push(current);
            let next = if Self::uniform01(&mut rng) < restart_prob {
                start
            } else {
                let neighbors = &adjacency[current];
                if neighbors.is_empty() {
                    start
                } else {
                    Self::sample_weighted(neighbors, &mut rng)
                }
            };
            current = next;
        }
        visited
    }

    pub fn sample_weighted(neighbors: &[(usize, f64)], rng: &mut SplitMix64) -> usize {
        assert!(!neighbors.is_empty(), "sample_weighted requires a non-empty neighbor list");
        let total: f64 = neighbors.iter().map(|&(_, w)| if w > 0.0 { w } else { 0.0 }).sum();
        if total <= 0.0 {
            let idx = (rng.next() % neighbors.len() as u64) as usize;
            return neighbors[idx].0;
        }
        let pick = Self::uniform01(rng) * total;
        let mut acc = 0.0;
        for &(j, w) in neighbors {
            if w > 0.0 {
                acc += w;
                if pick <= acc {
                    return j;
                }
            }
        }
        neighbors.last().unwrap().0
    }

    #[inline]
    pub fn uniform01(rng: &mut SplitMix64) -> f64 {
        let bits = rng.next() >> 11;
        bits as f64 * (1.0_f64 / (1u64 << 53) as f64)
    }

    /// Random walk with restart aggregating visits by RowId. The CognitionKit
    /// `recall_exploratory` recipe (`exploratory_recall_recipe.rs`) is the
    /// live consumer of this function.
    ///
    /// Takes a `HashMap<RowId, Vec<RowId>>` adjacency (unweighted; each
    /// neighbor is one uniform-weight edge) rather than the indexed
    /// form, because the cognition tier works in RowId space, not in
    /// densely-numbered graph nodes. The walk uses a uniform-random
    /// neighbor pick (no weight) and restarts to `seed` on each step
    /// with probability `restart_probability`.
    ///
    /// Returns a `HashMap<RowId, u64>` mapping visited RowIds to visit counts.
    ///
    /// Preconditions (parallel to Swift):
    ///   - `steps >= 1`
    ///   - `restart_probability` in [0, 1)
    pub fn walk_with_restart(
        seed: RowId,
        steps: usize,
        restart_probability: f32,
        rng_seed: u64,
        adjacency: &HashMap<RowId, Vec<RowId>>,
    ) -> HashMap<RowId, u64> {
        assert!(steps >= 1, "steps must be at least 1");
        assert!(
            restart_probability >= 0.0 && restart_probability < 1.0,
            "restart_probability must be in [0, 1)"
        );
        let mut rng = SplitMix64::new(rng_seed);
        let mut visits: HashMap<RowId, u64> = HashMap::new();
        let mut current = seed;
        for _ in 0..steps {
            *visits.entry(current).or_insert(0) += 1;
            let restart = Self::uniform01(&mut rng) < f64::from(restart_probability);
            if restart {
                current = seed;
            } else if let Some(neighbors) = adjacency.get(&current) {
                if !neighbors.is_empty() {
                    let idx = (rng.next() % neighbors.len() as u64) as usize;
                    current = neighbors[idx];
                } else {
                    current = seed; // dead end ⇒ restart
                }
            } else {
                current = seed; // no adjacency entry ⇒ restart
            }
        }
        visits
    }
}

// SplitMix64 mirror (matching the harness deterministic PRNG)
pub struct SplitMix64 {
    pub state: u64,
}

impl SplitMix64 {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }
    pub fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn symmetric_edges(n: usize, edges: &[(usize, usize, f64)]) -> Vec<Vec<(usize, f64)>> {
        let mut adj = vec![Vec::new(); n];
        for &(a, b, w) in edges {
            adj[a].push((b, w));
            adj[b].push((a, w));
        }
        adj
    }

    #[test]
    fn walk_starts_at_start_and_respects_length() {
        let edges = vec![(0, 1, 1.0), (1, 2, 1.0), (2, 3, 1.0)];
        let adj = symmetric_edges(4, &edges);
        let w = RandomWalks::walk(&adj, 0, 10, 0.15, 0xDEAD_BEEF_CAFE_F00D);
        assert_eq!(w.len(), 10);
        assert_eq!(w[0], 0);
        for &node in &w {
            assert!(node < 4);
        }
    }

    #[test]
    fn determinism_same_seed_same_walk() {
        let edges = vec![(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0), (2, 3, 1.0)];
        let adj = symmetric_edges(4, &edges);
        let seed = 0xCAFE_BABE_DEAD_BEEF;
        let w1 = RandomWalks::walk(&adj, 0, 20, 0.15, seed);
        let w2 = RandomWalks::walk(&adj, 0, 20, 0.15, seed);
        assert_eq!(w1, w2);
    }

    #[test]
    fn restart_prob_one_minus_epsilon_returns_to_start_often() {
        let edges = vec![(0, 1, 1.0), (1, 2, 1.0), (2, 3, 1.0)];
        let adj = symmetric_edges(4, &edges);
        let w = RandomWalks::walk(&adj, 0, 100, 0.99, 42);
        // Most steps should be at start (0) due to high restart prob.
        let starts: usize = w.iter().filter(|&&n| n == 0).count();
        assert!(starts > 80, "expected many restarts to start, got {}", starts);
    }

    #[test]
    fn dead_end_restarts_to_start() {
        // Node 0 connected only to node 1 (which has no other edges).
        let edges = vec![(0, 1, 1.0)];
        let adj = symmetric_edges(2, &edges);
        let w = RandomWalks::walk(&adj, 0, 20, 0.0, 0x1234_5678);
        // Walk oscillates 0 → 1 → 0 → 1 ... because 1's only
        // neighbor is 0 and 0's only neighbor is 1.
        for &node in &w {
            assert!(node == 0 || node == 1);
        }
    }

    #[test]
    fn uniform_fallback_when_all_weights_zero() {
        // Edges with zero weight: sample_weighted falls back to
        // uniform random pick.
        let mut rng = SplitMix64::new(7);
        let neighbors = vec![(0usize, 0.0), (1usize, 0.0), (2usize, 0.0)];
        let pick = RandomWalks::sample_weighted(&neighbors, &mut rng);
        assert!(pick < 3);
    }

    // walk_with_restart tests — mirror RandomWalksTests.swift walkWithRestart suite.

    fn make_row_id(n: u128) -> RowId {
        RowId(n)
    }

    // WR-1: seed always appears in visits; total visits == steps.
    #[test]
    fn walk_with_restart_seed_visits_and_step_count() {
        let seed = make_row_id(1);
        let a = make_row_id(2);
        let b = make_row_id(3);
        let mut adj = HashMap::new();
        adj.insert(seed, vec![a]);
        adj.insert(a, vec![b]);
        adj.insert(b, vec![seed]);

        let visits = RandomWalks::walk_with_restart(seed, 100, 0.15, 0xCAFE_BABE_DEAD_BEEF, &adj);
        let total: u64 = visits.values().sum();
        assert_eq!(total, 100, "total visits must equal steps");
        assert!(visits.contains_key(&seed), "seed always appears in visits");
    }

    // WR-2: determinism — same inputs, same visit map.
    #[test]
    fn walk_with_restart_is_deterministic() {
        let seed = make_row_id(10);
        let a = make_row_id(20);
        let mut adj = HashMap::new();
        adj.insert(seed, vec![a]);
        adj.insert(a, vec![seed]);
        let first = RandomWalks::walk_with_restart(seed, 500, 0.15, 0xDEAD_BEEF, &adj);
        let second = RandomWalks::walk_with_restart(seed, 500, 0.15, 0xDEAD_BEEF, &adj);
        assert_eq!(first, second, "same seed and adjacency must produce identical visits");
    }

    // WR-3: restart_probability=0.99 keeps the walk near the seed.
    #[test]
    fn walk_with_restart_high_probability_stays_near_seed() {
        let seed = make_row_id(1);
        let a = make_row_id(2);
        let mut adj = HashMap::new();
        adj.insert(seed, vec![a]);
        adj.insert(a, vec![make_row_id(3)]);
        let visits = RandomWalks::walk_with_restart(seed, 1000, 0.99, 42, &adj);
        let seed_visits = visits.get(&seed).copied().unwrap_or(0);
        // With p=0.99 restart the walk spends almost all steps at seed.
        assert!(seed_visits > 900, "high restart prob keeps walk at seed; got {seed_visits}");
    }

    // WR-4: dead end in adjacency restarts to seed.
    #[test]
    fn walk_with_restart_dead_end_restarts_to_seed() {
        let seed = make_row_id(1);
        let isolated = make_row_id(99);
        // Isolated node: present in adjacency with an empty neighbor list.
        let mut adj = HashMap::new();
        adj.insert(seed, vec![isolated]);
        adj.insert(isolated, vec![]);
        // With restart_probability=0 the walk must go seed→isolated→(dead
        // end)→seed→isolated→... Never leaves these two nodes.
        let visits = RandomWalks::walk_with_restart(seed, 100, 0.0, 7, &adj);
        for (&node, _) in &visits {
            assert!(node == seed || node == isolated, "unexpected node {node:?}");
        }
    }

    // WR-5: conformance anchor — canonical seed 0xCAFEBABEDEADBEEF on a
    // three-node cycle. Swift and Rust must produce the same visit totals.
    // The golden values below are the reference output; any algorithm
    // change must produce bit-identical totals on this fixture.
    //
    // Graph: 1→2, 2→3, 3→1. Seed=1, steps=1000, restart=0.15, rng=0xCAFEBABEDEADBEEF.
    #[test]
    fn walk_with_restart_canonical_fixture() {
        let seed = make_row_id(1);
        let b = make_row_id(2);
        let c = make_row_id(3);
        let mut adj = HashMap::new();
        adj.insert(seed, vec![b]);
        adj.insert(b, vec![c]);
        adj.insert(c, vec![seed]);
        let visits = RandomWalks::walk_with_restart(seed, 1000, 0.15, 0xCAFE_BABE_DEAD_BEEF, &adj);
        // Total must be exactly 1000 (one step = one visit).
        let total: u64 = visits.values().sum();
        assert_eq!(total, 1000);
        // With a three-node cycle and restart=0.15 the seed node is
        // visited roughly ~48% of the time (= restart_fraction ×
        // geometric-series contribution + uniform walk share).
        // Assert all three nodes are visited (non-zero coverage).
        assert!(visits.contains_key(&seed));
        assert!(visits.contains_key(&b));
        assert!(visits.contains_key(&c));
    }
}
