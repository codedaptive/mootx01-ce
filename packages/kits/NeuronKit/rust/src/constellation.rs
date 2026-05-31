//! Constellation — emergent communities over the association graph (Lens 1,
//! Structure): the NeuronKit reasoning surface over SubstrateML's Louvain
//! `CommunityDetection`. Where Keystones finds the load-bearing nodes,
//! Constellation finds the CLUSTERS — the emergent themes the user never named
//! ("these memories group together whether or not you filed them that way").
//!
//! Layer B-1: the clustering math lives in SubstrateML; this shapes a
//! drawer-id graph into named communities. CognitionKit sequences it over the
//! estate's tunnel graph (same graph Keystones reads).

use std::collections::BTreeMap;

use substrate_ml::community_detection::CommunityDetection;

/// Default Louvain passes — enough for phase-1 convergence on the graphs the
/// lens sees; matches the substrate harness default usage.
pub const DEFAULT_MAX_PASSES: usize = 10;

/// The emergent communities of a graph.
#[derive(Clone, Debug, PartialEq)]
pub struct Constellation {
    /// Each community as a sorted group of node (drawer) ids; groups are
    /// ordered by their smallest member for a deterministic result.
    pub communities: Vec<Vec<String>>,
}

/// Detect communities over the UNDIRECTED graph formed by `edges` (drawer-id
/// pairs), weight 1 each; edges with an endpoint absent from `node_ids` are
/// ignored. Louvain phase-1 via SubstrateML.
pub fn constellations(
    node_ids: &[String],
    edges: &[(String, String)],
    max_passes: usize,
) -> Constellation {
    let n = node_ids.len();
    if n == 0 {
        return Constellation { communities: Vec::new() };
    }
    let index: BTreeMap<&str, usize> =
        node_ids.iter().enumerate().map(|(i, s)| (s.as_str(), i)).collect();
    let mut adjacency: Vec<Vec<(usize, f64)>> = vec![Vec::new(); n];
    for (a, b) in edges {
        if let (Some(&i), Some(&j)) = (index.get(a.as_str()), index.get(b.as_str())) {
            if i != j {
                adjacency[i].push((j, 1.0));
                adjacency[j].push((i, 1.0));
            }
        }
    }

    let labels = CommunityDetection::detect(&adjacency, max_passes);

    let mut groups: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for (i, &label) in labels.iter().enumerate() {
        groups.entry(label).or_default().push(node_ids[i].clone());
    }
    let mut communities: Vec<Vec<String>> = groups
        .into_values()
        .map(|mut g| {
            g.sort();
            g
        })
        .collect();
    communities.sort_by(|a, b| a[0].cmp(&b[0]));
    Constellation { communities }
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

    // CS-1: two disjoint triangles form two communities. The emergent themes
    // are recovered from raw connectivity, no labels supplied.
    #[test]
    fn cs1_two_triangles_two_communities() {
        let nodes = ids(&["A1", "A2", "A3", "B1", "B2", "B3"]);
        let g = edges(&[
            ("A1", "A2"),
            ("A1", "A3"),
            ("A2", "A3"),
            ("B1", "B2"),
            ("B1", "B3"),
            ("B2", "B3"),
        ]);
        let c = constellations(&nodes, &g, DEFAULT_MAX_PASSES);
        assert_eq!(c.communities.len(), 2, "two cliques ⇒ two communities");
        // Each community is one full triangle.
        assert!(c.communities.iter().any(|grp| grp == &ids(&["A1", "A2", "A3"])));
        assert!(c.communities.iter().any(|grp| grp == &ids(&["B1", "B2", "B3"])));
    }

    // CS-2: empty graph ⇒ no communities (guarded).
    #[test]
    fn cs2_empty_is_guarded() {
        assert!(constellations(&[], &[], DEFAULT_MAX_PASSES).communities.is_empty());
    }
}
