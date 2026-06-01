//! Keystones — load-bearing memory (SPEC § 7.1, Lens 1 Structure). Surfaces
//! SubstrateML's gated `EigenvalueCentrality` over the drawer/tunnel graph and
//! ranks the nodes the rest of the graph hangs off — "the spine of your
//! thinking." Owns no math (I-17): the centrality is the primitive's; this
//! module only shapes drawer-ids into the graph and the scores into a ranked
//! result. Pure and total over edge inputs (I-18, B-8).

use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;

use crate::structure_graph;

/// One ranked memory: its drawer id and eigenvalue-centrality score.
#[derive(Clone, Debug, PartialEq)]
pub struct Keystone {
    pub id: String,
    pub centrality: f64,
}

/// Rank `node_ids` by eigenvalue centrality over the undirected, unit-weight
/// graph formed by `edges`, returning the top `top_k` keystones — descending by
/// centrality, ties by ascending id. Self-loops and edges with an endpoint
/// absent from `node_ids` are ignored. Empty `node_ids` or `top_k == 0` ⇒ empty
/// (C-16).
pub fn keystones(node_ids: &[String], edges: &[(String, String)], top_k: usize) -> Vec<Keystone> {
    if node_ids.is_empty() || top_k == 0 {
        return Vec::new();
    }

    let adjacency = structure_graph::build(node_ids, edges);
    let scores = EigenvalueCentrality::compute(
        &adjacency,
        EigenvalueCentrality::DEFAULT_MAX_ITERATIONS,
        EigenvalueCentrality::DEFAULT_TOLERANCE,
    );

    let mut ranked: Vec<Keystone> = node_ids
        .iter()
        .zip(scores.iter())
        .map(|(id, &centrality)| Keystone { id: id.clone(), centrality })
        .collect();

    ranked.sort_by(|a, b| {
        b.centrality
            .partial_cmp(&a.centrality)
            .unwrap_or(std::cmp::Ordering::Equal) // descending centrality
            .then_with(|| a.id.cmp(&b.id)) // ties: ascending id
    });
    ranked.truncate(top_k);
    ranked
}

#[cfg(test)]
mod tests {
    // Tests assert the behavioral claims SPEC § 7.1 makes about Keystones:
    // the node the graph hangs off ranks first, ties break ascending id,
    // noise edges are ignored, and the surface is total over edge inputs.
    use super::*;

    fn ids(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }
    fn edges(xs: &[(&str, &str)]) -> Vec<(String, String)> {
        xs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn hub_of_a_star_ranks_first() {
        let nodes = ids(&["hub", "s1", "s2", "s3", "s4"]);
        let g = edges(&[("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]);
        let top = keystones(&nodes, &g, 5);
        assert_eq!(top[0].id, "hub");
        assert!(top[0].centrality > top[1].centrality);
    }

    #[test]
    fn bridge_between_clusters_ranks_first() {
        let nodes = ids(&["a", "b", "bridge", "c", "d"]);
        let g = edges(&[
            ("a", "b"),
            ("a", "bridge"),
            ("b", "bridge"),
            ("bridge", "c"),
            ("bridge", "d"),
            ("c", "d"),
        ]);
        assert_eq!(keystones(&nodes, &g, 5)[0].id, "bridge");
    }

    #[test]
    fn descending_and_capped_to_top_k() {
        let nodes = ids(&["hub", "s1", "s2", "s3"]);
        let g = edges(&[("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("s1", "s2")]);
        let top = keystones(&nodes, &g, 2);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].id, "hub");
        assert!(top[0].centrality >= top[1].centrality);
    }

    #[test]
    fn noise_edges_change_nothing() {
        let nodes = ids(&["hub", "s1", "s2", "s3", "s4"]);
        let clean = edges(&[("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]);
        let mut noisy = clean.clone();
        noisy.push(("hub".into(), "hub".into())); // self-loop
        noisy.push(("hub".into(), "ghost".into())); // absent endpoint
        noisy.push(("ghost".into(), "s1".into())); // absent endpoint
        assert_eq!(keystones(&nodes, &clean, 5), keystones(&nodes, &noisy, 5));
    }

    #[test]
    fn total_over_edge_inputs() {
        assert!(keystones(&[], &[], 5).is_empty());
        assert_eq!(keystones(&ids(&["x", "y", "z"]), &[], 2).len(), 2);
        assert!(keystones(&ids(&["x", "y"]), &edges(&[("x", "y")]), 0).is_empty());
    }
}
