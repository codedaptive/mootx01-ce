//! Constellation — emergent communities (SPEC § 7.1, Lens 1 Structure).
//! Surfaces SubstrateML's gated Louvain `CommunityDetection` over the same
//! drawer/tunnel graph Keystones reads, then groups drawer-ids by the community
//! label the primitive assigns. Finds the CLUSTERS the user never named. Owns
//! no math (I-17); pure and total (I-18, B-8).

use std::collections::BTreeMap;

use substrate_ml::community_detection::CommunityDetection;

use crate::structure_graph;

/// Default Louvain passes for the lens; phase-1 convergence on the graphs the
/// surface sees.
pub const DEFAULT_MAX_PASSES: usize = 10;

/// The emergent communities of a graph.
#[derive(Clone, Debug, PartialEq)]
pub struct Constellation {
    /// Each community is an ascending-sorted group of drawer ids; the groups are
    /// ordered by their smallest member. Both orderings derive purely from the
    /// ids, so the result does not depend on which integers the primitive
    /// assigned its labels — the determinism C-Det requires.
    pub communities: Vec<Vec<String>>,
}

/// Detect communities over the undirected, unit-weight graph formed by `edges`,
/// grouping `node_ids` by community. Self-loops and absent-endpoint edges are
/// ignored. Empty `node_ids` ⇒ no communities (C-16).
pub fn constellations(
    node_ids: &[String],
    edges: &[(String, String)],
    max_passes: usize,
) -> Constellation {
    if node_ids.is_empty() {
        return Constellation {
            communities: Vec::new(),
        };
    }

    let adjacency = structure_graph::build(node_ids, edges);
    // estate and ts are empty/0: callers that want VizGraph telemetry
    // should pass the estate id and a caller-supplied timestamp. The
    // default empty values produce a no-op emit when monitoring is off.
    let labels = CommunityDetection::detect(&adjacency, max_passes, "", 0.0);

    // Group ids by their assigned label, then impose an id-derived canonical
    // ordering so the result is independent of the label integers.
    let mut by_label: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for (i, &label) in labels.iter().enumerate() {
        by_label.entry(label).or_default().push(node_ids[i].clone());
    }
    let mut communities: Vec<Vec<String>> = by_label
        .into_values()
        .map(|mut group| {
            group.sort();
            group
        })
        .collect();
    communities.sort_by(|a, b| a[0].cmp(&b[0]));

    Constellation { communities }
}

#[cfg(test)]
mod tests {
    // Tests assert the behavioral claims SPEC § 7.1 makes about Constellation:
    // clusters are recovered from raw connectivity, the result is deterministic
    // regardless of input order, and the surface is total over edge inputs.
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
    fn disjoint_cliques_become_separate_communities() {
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
        assert_eq!(c.communities.len(), 2);
        assert!(c.communities.contains(&ids(&["A1", "A2", "A3"])));
        assert!(c.communities.contains(&ids(&["B1", "B2", "B3"])));
    }

    #[test]
    fn ordering_is_independent_of_input_order() {
        let g = edges(&[
            ("A1", "A2"),
            ("A1", "A3"),
            ("A2", "A3"),
            ("B1", "B2"),
            ("B1", "B3"),
            ("B2", "B3"),
        ]);
        let forward = constellations(
            &ids(&["A1", "A2", "A3", "B1", "B2", "B3"]),
            &g,
            DEFAULT_MAX_PASSES,
        );
        let shuffled = constellations(
            &ids(&["B3", "A2", "B1", "A3", "A1", "B2"]),
            &g,
            DEFAULT_MAX_PASSES,
        );
        assert_eq!(forward, shuffled);
        for group in &forward.communities {
            let mut sorted = group.clone();
            sorted.sort();
            assert_eq!(group, &sorted, "each community ascending");
        }
        let firsts: Vec<&String> = forward.communities.iter().map(|g| &g[0]).collect();
        let mut sorted_firsts = firsts.clone();
        sorted_firsts.sort();
        assert_eq!(
            firsts, sorted_firsts,
            "communities ordered by smallest member"
        );
    }

    #[test]
    fn total_over_edge_inputs() {
        assert!(constellations(&[], &[], DEFAULT_MAX_PASSES)
            .communities
            .is_empty());
    }
}
