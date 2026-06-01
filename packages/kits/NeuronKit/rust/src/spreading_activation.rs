//! Spreading activation — free association from a seed (SPEC § 7.1, Lens 1
//! Structure). Surfaces SubstrateML's gated random-walk-with-restart: wander
//! from the seed, and the fraction of steps spent on each other node IS its
//! activation — how strongly the seed reaches it. The transitive companion to
//! Keystones (global centrality) and Constellation (clusters). Deterministic
//! for a fixed `rng_seed` (B-5). Owns no math (I-17); pure and total (I-18,
//! B-8).

use substrate_ml::random_walks::RandomWalks;

/// One node's activation: the fraction of walk steps that landed on it, in
/// `[0, 1]`. Higher = more strongly associated with the seed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Activation {
    pub node: usize,
    pub activation: f64,
}

/// Walk `walk_length` steps from `seed` over `adjacency` (`adjacency[i]` =
/// node `i`'s weighted out-edges), teleporting home with probability
/// `restart_prob`, and return the top `k` nodes by visit frequency —
/// descending, ties by ascending node index. The seed is excluded (association
/// is what the seed reaches, not the seed). An out-of-range seed, a zero-length
/// walk, or `k == 0` yields nothing (C-16).
pub fn spreading_activation(
    adjacency: &[Vec<(usize, f64)>],
    seed: usize,
    walk_length: usize,
    restart_prob: f64,
    rng_seed: u64,
    k: usize,
) -> Vec<Activation> {
    if seed >= adjacency.len() || walk_length == 0 || k == 0 {
        return Vec::new();
    }

    let visits = RandomWalks::walk(adjacency, seed, walk_length, restart_prob, rng_seed);

    // Visit frequency, normalised to a fraction of the walk.
    let mut counts = vec![0u64; adjacency.len()];
    for &node in &visits {
        counts[node] += 1;
    }
    let steps = walk_length as f64;

    let mut ranked: Vec<Activation> = counts
        .iter()
        .enumerate()
        .filter(|&(node, &c)| node != seed && c > 0) // exclude the seed itself
        .map(|(node, &c)| Activation { node, activation: c as f64 / steps })
        .collect();

    ranked.sort_by(|a, b| {
        b.activation
            .partial_cmp(&a.activation)
            .unwrap_or(std::cmp::Ordering::Equal) // descending activation
            .then_with(|| a.node.cmp(&b.node)) // ties: ascending node index
    });
    ranked.truncate(k);
    ranked
}

#[cfg(test)]
mod tests {
    // Tests assert the behavioral claims SPEC § 7.1 makes about spreading
    // activation: it ranks reachability, excludes the seed and unreachable
    // nodes, is deterministic for a fixed seed, and is total over edge inputs.
    use super::*;

    const RESTART: f64 = 0.15;
    const LEN: usize = 20_000; // long & deterministic ⇒ stable ordering, not flaky
    const RNG: u64 = 0xABCDEF;

    #[test]
    fn ranks_reachability_excludes_seed_and_unreachable() {
        // Seed component: 0—1—2 (2 is two hops). Separate component: 3—4.
        let adj: Vec<Vec<(usize, f64)>> = vec![
            vec![(1, 1.0)],
            vec![(0, 1.0), (2, 1.0)],
            vec![(1, 1.0)],
            vec![(4, 1.0)],
            vec![(3, 1.0)],
        ];
        let act = spreading_activation(&adj, 0, LEN, RESTART, RNG, 10);
        assert!(act.iter().all(|a| a.node != 0), "seed excluded");
        let a1 = act.iter().find(|a| a.node == 1).unwrap().activation;
        let a2 = act.iter().find(|a| a.node == 2).unwrap().activation;
        assert!(a1 > a2, "direct neighbor outranks two-hop node");
        assert!(act.iter().all(|a| a.node != 3 && a.node != 4), "disconnected component never activates");
        assert!(act.iter().all(|a| a.activation >= 0.0 && a.activation <= 1.0), "activation is a fraction");
    }

    #[test]
    fn descending_and_capped_to_k() {
        let adj: Vec<Vec<(usize, f64)>> = vec![
            vec![(1, 1.0), (2, 1.0), (3, 1.0)],
            vec![(0, 1.0)],
            vec![(0, 1.0)],
            vec![(0, 1.0)],
        ];
        let act = spreading_activation(&adj, 0, LEN, RESTART, RNG, 2);
        assert_eq!(act.len(), 2);
        assert!(act[0].activation >= act[1].activation);
    }

    #[test]
    fn deterministic_for_fixed_seed() {
        let adj: Vec<Vec<(usize, f64)>> = vec![
            vec![(1, 1.0), (2, 1.0)],
            vec![(0, 1.0), (2, 1.0)],
            vec![(0, 1.0), (1, 1.0)],
        ];
        let a = spreading_activation(&adj, 0, 5_000, RESTART, 42, 10);
        let b = spreading_activation(&adj, 0, 5_000, RESTART, 42, 10);
        assert_eq!(a, b);
    }

    #[test]
    fn total_over_edge_inputs() {
        let adj: Vec<Vec<(usize, f64)>> = vec![vec![(1, 1.0)], vec![(0, 1.0)]];
        assert!(spreading_activation(&adj, 5, LEN, RESTART, RNG, 10).is_empty(), "out-of-range seed");
        assert!(spreading_activation(&adj, 0, 0, RESTART, RNG, 10).is_empty(), "zero-length walk");
    }
}
