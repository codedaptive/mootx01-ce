//! Keystones — eigenvalue-centrality "load-bearing memory" detection: the
//! NeuronKit reasoning surface over SubstrateML's gated
//! `EigenvalueCentrality`. The first brainstormed reasoning lens made real
//! (Lens 1, Structure): given the estate's drawer/tunnel graph, rank the
//! memories the rest hangs off — "the spine of your thinking."
//!
//! Layer discipline (B-1): the deep matrix math lives in SubstrateML; this
//! module turns the primitive into a substrate-shaped reasoning result.
//! CognitionKit sequences it into a recipe; the estate supplies the graph.
//! This is the first instance of the "surface-then-sequence" archetype — the
//! conformance-gated math was built and idle; nothing reasoned with it until
//! now.

use std::collections::BTreeMap;

use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;

/// One ranked memory: its drawer id and eigenvalue-centrality score.
#[derive(Clone, Debug, PartialEq)]
pub struct Keystone {
    pub id: String,
    pub centrality: f64,
}

/// Rank `node_ids` by eigenvalue centrality over the UNDIRECTED graph formed
/// by `edges` (drawer-id pairs), returning the top `top_k` keystones —
/// descending by centrality, ties broken by ascending id for determinism.
///
/// Edges are undirected (a load-bearing memory is one many others connect to
/// OR from), weight 1 each; a self-loop or an edge whose endpoint is absent
/// from `node_ids` is ignored. Power iteration via SubstrateML's gated
/// `EigenvalueCentrality::compute` (the math is byte-identical across ports).
pub fn keystones(node_ids: &[String], edges: &[(String, String)], top_k: usize) -> Vec<Keystone> {
    let n = node_ids.len();
    if n == 0 {
        return Vec::new();
    }

    // Map each drawer id to its node index. BTreeMap keeps construction
    // deterministic; lookups ignore unknown endpoints.
    let index: BTreeMap<&str, usize> =
        node_ids.iter().enumerate().map(|(i, s)| (s.as_str(), i)).collect();

    let mut adjacency: Vec<Vec<(usize, f64)>> = vec![Vec::new(); n];
    for (a, b) in edges {
        if let (Some(&i), Some(&j)) = (index.get(a.as_str()), index.get(b.as_str())) {
            if i != j {
                adjacency[i].push((j, 1.0));
                adjacency[j].push((i, 1.0)); // undirected
            }
        }
    }

    let scores = EigenvalueCentrality::compute(
        &adjacency,
        EigenvalueCentrality::DEFAULT_MAX_ITERATIONS,
        EigenvalueCentrality::DEFAULT_TOLERANCE,
    );

    let mut ranked: Vec<Keystone> = node_ids
        .iter()
        .enumerate()
        .map(|(i, id)| Keystone { id: id.clone(), centrality: scores[i] })
        .collect();
    ranked.sort_by(|a, b| {
        b.centrality
            .partial_cmp(&a.centrality)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.id.cmp(&b.id))
    });
    ranked.truncate(top_k);
    ranked
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }
    fn edges(xs: &[(&str, &str)]) -> Vec<(String, String)> {
        xs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    // KS-1: a star graph — the hub connects to every spoke, the spokes to
    // nothing else. The hub is the load-bearing memory: highest centrality,
    // the top keystone. (The structural intuition of the whole lens.)
    #[test]
    fn ks1_star_hub_is_the_top_keystone() {
        let nodes = ids(&["hub", "s1", "s2", "s3", "s4"]);
        let g = edges(&[("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]);
        let top = keystones(&nodes, &g, 5);
        assert_eq!(top[0].id, "hub", "the hub is the spine");
        assert!(top[0].centrality > top[1].centrality, "hub strictly dominates a spoke");
    }

    // KS-2: top_k truncates; the result is the K most central, in order.
    #[test]
    fn ks2_top_k_truncates() {
        let nodes = ids(&["hub", "s1", "s2", "s3"]);
        let g = edges(&[("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("s1", "s2")]);
        let top = keystones(&nodes, &g, 2);
        assert_eq!(top.len(), 2);
        assert_eq!(top[0].id, "hub");
    }

    // KS-3: a denser-connected node outranks a sparser one — centrality
    // reflects how much of the graph hangs off a memory, not just degree of
    // one hop. Two triangles joined at a bridge node: the bridge is central.
    #[test]
    fn ks3_bridge_node_is_central() {
        let nodes = ids(&["a", "b", "bridge", "c", "d"]);
        let g = edges(&[
            ("a", "b"),
            ("a", "bridge"),
            ("b", "bridge"),
            ("bridge", "c"),
            ("bridge", "d"),
            ("c", "d"),
        ]);
        let top = keystones(&nodes, &g, 5);
        assert_eq!(top[0].id, "bridge", "the join node carries the most weight");
    }

    // KS-4: empty graph / no nodes is a guarded empty result (no panic).
    #[test]
    fn ks4_empty_is_guarded() {
        assert!(keystones(&[], &[], 5).is_empty());
        // Nodes but no edges: all centralities equal; top_k still bounded.
        let nodes = ids(&["x", "y", "z"]);
        let top = keystones(&nodes, &[], 2);
        assert_eq!(top.len(), 2);
    }
}
