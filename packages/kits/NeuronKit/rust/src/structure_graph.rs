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
    let index: HashMap<&str, usize> =
        node_ids.iter().enumerate().map(|(i, s)| (s.as_str(), i)).collect();

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
