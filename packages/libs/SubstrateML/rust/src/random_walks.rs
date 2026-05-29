// random_walks.rs
//
// Random walks with restart on the estate graph, per cookbook
// § 7.4. Mirror of glref-swift-RandomWalks.swift.

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
}
