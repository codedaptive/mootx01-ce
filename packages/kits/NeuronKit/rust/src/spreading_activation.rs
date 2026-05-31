//! Spreading activation — personalized relevance from a seed (Lens 1,
//! Structure): the NeuronKit reasoning surface over SubstrateML's
//! random-walk-with-restart (`RandomWalks`, cookbook § 7.4). From one seed
//! node, wander the estate's tunnel graph — at each step either follow a
//! weighted edge or teleport back to the seed — and rank the other nodes by how
//! often the walk lands on them. That visit frequency IS the activation: nodes
//! the seed reaches easily (directly, or through dense paths) light up; nodes
//! in other components never do. "What does this remind you of" — free
//! association, the transitive companion to Keystones (GLOBAL centrality) and
//! Constellation (CLUSTERS) over the same graph.
//!
//! Layer B-1: the walk + weighted sampling live in SubstrateML; this shapes the
//! walk into a normalized, seed-excluded, ranked activation. CognitionKit
//! sequences it (build the adjacency from tunnels, derive a deterministic walk
//! seed, then call this). Determinism: the walk is a pure function of
//! `rng_seed` — the caller passes a fixed seed, never a clock.

use substrate_ml::random_walks::RandomWalks;

/// One node's activation: the fraction of walk steps that landed on it. In
/// `[0, 1]`; higher = more strongly associated with the seed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Activation {
    pub node: usize,
    pub activation: f64,
}

/// Run a restart walk of `walk_length` steps from `seed` over `adjacency`
/// (`adjacency[i]` = the weighted out-edges `(neighbor, weight)` of node `i`)
/// and return the top `k` most-activated nodes, strongest first (ties by
/// ascending node index). The seed itself is excluded — association is about
/// what the seed REACHES, not the seed. `restart_prob` is the teleport-home
/// probability (SubstrateML default 0.15). Deterministic for a fixed
/// `rng_seed`. An out-of-range seed or zero-length walk yields no activations.
pub fn spreading_activation(
    adjacency: &[Vec<(usize, f64)>],
    seed: usize,
    walk_length: usize,
    restart_prob: f64,
    rng_seed: u64,
    k: usize,
) -> Vec<Activation> {
    if seed >= adjacency.len() || walk_length == 0 {
        return Vec::new();
    }

    let visited = RandomWalks::walk(adjacency, seed, walk_length, restart_prob, rng_seed);

    // Tally visits per node, then normalize by the walk length so activation is
    // a fraction comparable across walks.
    let mut counts = vec![0u64; adjacency.len()];
    for &node in &visited {
        counts[node] += 1;
    }
    let denom = walk_length as f64;

    let mut out: Vec<Activation> = counts
        .iter()
        .enumerate()
        .filter(|(node, &c)| *node != seed && c > 0) // exclude the seed itself
        .map(|(node, &c)| Activation { node, activation: c as f64 / denom })
        .collect();
    out.sort_by(|a, b| {
        b.activation
            .partial_cmp(&a.activation)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.node.cmp(&b.node))
    });
    out.truncate(k);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const RESTART: f64 = 0.15;
    // A long walk so the visit frequencies are stable enough to assert
    // ordering; the walk is deterministic, so this is reproducible, not flaky.
    const LEN: usize = 20_000;
    const SEED_RNG: u64 = 0xABCDEF;

    // SA-1: a node the seed reaches directly activates more than one reached
    // only transitively, and a node in a disconnected component never activates.
    #[test]
    fn sa1_reachable_outranks_distant_and_excludes_unreachable() {
        // Component of the seed (0): 0<->1, 1<->2 (so 2 is two hops from 0).
        // Separate component: 3<->4 (unreachable from 0).
        let adj: Vec<Vec<(usize, f64)>> = vec![
            vec![(1, 1.0)],           // 0 -> 1
            vec![(0, 1.0), (2, 1.0)], // 1 -> 0, 2
            vec![(1, 1.0)],           // 2 -> 1
            vec![(4, 1.0)],           // 3 -> 4
            vec![(3, 1.0)],           // 4 -> 3
        ];
        let act = spreading_activation(&adj, 0, LEN, RESTART, SEED_RNG, 10);

        // Seed excluded.
        assert!(act.iter().all(|a| a.node != 0), "seed is not its own association");
        // Direct neighbor 1 outranks transitive 2.
        let a1 = act.iter().find(|a| a.node == 1).expect("node 1 activated").activation;
        let a2 = act.iter().find(|a| a.node == 2).expect("node 2 activated").activation;
        assert!(a1 > a2, "direct neighbor outranks the two-hop node: {a1} vs {a2}");
        // The disconnected component never lights up.
        assert!(act.iter().all(|a| a.node != 3 && a.node != 4), "other component unreachable");
    }

    // SA-2: k caps the result; the strongest associations are kept.
    #[test]
    fn sa2_k_caps_to_strongest() {
        let adj: Vec<Vec<(usize, f64)>> = vec![
            vec![(1, 1.0), (2, 1.0), (3, 1.0)],
            vec![(0, 1.0)],
            vec![(0, 1.0)],
            vec![(0, 1.0)],
        ];
        let act = spreading_activation(&adj, 0, LEN, RESTART, SEED_RNG, 2);
        assert_eq!(act.len(), 2, "k caps the count");
        // Returned in descending activation order.
        assert!(act[0].activation >= act[1].activation);
    }

    // SA-3: an out-of-range seed yields no activations (guarded).
    #[test]
    fn sa3_bad_seed_empty() {
        let adj: Vec<Vec<(usize, f64)>> = vec![vec![(0, 1.0)]];
        assert!(spreading_activation(&adj, 5, LEN, RESTART, SEED_RNG, 10).is_empty());
    }
}
