//! Shared graph construction for the structure lenses (SPEC § 7.1). Keystones
//! and Constellation both read "the undirected graph formed by drawer-id edge
//! pairs (weight 1; self-loops and absent-endpoint edges ignored)" — that one
//! shaping step lives here so both surface the same graph to their gated
//! SubstrateML primitive. Owns no math (I-17).

use std::collections::HashMap;

/// Build the undirected, unit-weight adjacency over `node_ids` from drawer-id
/// `edges`. Node `i` is `node_ids[i]` — input order fixes the index space, so
/// the adjacency is a deterministic function of the inputs. A self-loop (both
/// endpoints the same node) and an edge with an endpoint not in `node_ids`
/// contribute nothing; each surviving pair adds a symmetric edge.
pub fn build(node_ids: &[String], edges: &[(String, String)]) -> Vec<Vec<(usize, f64)>> {
    let index: HashMap<&str, usize> = node_ids
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();

    let mut adjacency: Vec<Vec<(usize, f64)>> = vec![Vec::new(); node_ids.len()];
    for (a, b) in edges {
        if let (Some(&i), Some(&j)) = (index.get(a.as_str()), index.get(b.as_str())) {
            if i != j {
                adjacency[i].push((j, 1.0));
                adjacency[j].push((i, 1.0)); // undirected
            }
        }
    }
    adjacency
}

#[cfg(test)]
mod tests {
    // Tests assert the SPEC § 7.1 shaping claims: undirected symmetric
    // weight-1.0 edges, self-loops and absent-endpoint edges ignored,
    // input node order fixing the index space deterministically, and
    // totality over empty inputs.
    use super::*;

    fn ids(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| s.to_string()).collect()
    }
    fn edges(xs: &[(&str, &str)]) -> Vec<(String, String)> {
        xs.iter()
            .map(|(a, b)| (a.to_string(), b.to_string()))
            .collect()
    }

    #[test]
    fn edge_is_symmetric_and_unit_weight() {
        let adj = build(&ids(&["a", "b"]), &edges(&[("a", "b")]));
        assert_eq!(adj[0], vec![(1, 1.0)]);
        assert_eq!(adj[1], vec![(0, 1.0)]);
    }

    #[test]
    fn self_loop_contributes_nothing() {
        let nodes = ids(&["a", "b"]);
        let clean = build(&nodes, &edges(&[("a", "b")]));
        let noisy = build(&nodes, &edges(&[("a", "b"), ("a", "a")]));
        assert_eq!(noisy, clean);
    }

    #[test]
    fn absent_endpoint_edge_contributes_nothing() {
        let nodes = ids(&["a", "b"]);
        let clean = build(&nodes, &edges(&[("a", "b")]));
        let noisy = build(
            &nodes,
            &edges(&[("a", "b"), ("a", "ghost"), ("ghost", "b")]),
        );
        assert_eq!(noisy, clean);
    }

    #[test]
    fn input_node_order_fixes_the_index_space() {
        let g = edges(&[("a", "b")]);
        let forward = build(&ids(&["a", "b"]), &g);
        let reversed = build(&ids(&["b", "a"]), &g);
        // Same edge, different index space: node 0 is "a" in one build
        // and "b" in the other, so each adjacency is the other mirrored.
        assert_eq!(forward, vec![vec![(1, 1.0)], vec![(0, 1.0)]]);
        assert_eq!(reversed, vec![vec![(1, 1.0)], vec![(0, 1.0)]]);
    }

    #[test]
    fn total_over_empty_inputs() {
        assert!(build(&[], &[]).is_empty());
        let nodes_no_edges = build(&ids(&["a", "b"]), &[]);
        assert_eq!(nodes_no_edges, vec![Vec::new(), Vec::new()]);
    }
}
