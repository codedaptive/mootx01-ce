//! Free association — the conscious "what does this remind you of" recipe
//! (Lens 1, Structure). From one seed memory, wander the wing's drawer-to-
//! drawer tunnel graph with restart (NeuronKit `spreading_activation` over
//! SubstrateML's random walk) and rank the memories the walk keeps landing on.
//! The transitive companion to Keystones (global spine) and Constellation
//! (clusters) over the SAME graph read: this one is SEED-relative — personalized
//! relevance, not a global property.
//!
//! Paired with the Swift version (`Sources/CognitionKit/FreeAssociation.swift`).
//! Pure CognitionKit sequencing: the tunnel graph via GLK
//! `recall_tunnels` (the accessor Keystones added) + NeuronKit
//! `spreading_activation`. Read-only.
//!
//! Determinism: the walk's PRNG seed is derived from the seed drawer id by FNV
//! hash — never a clock — so the same seed memory always produces the same
//! associations (the same property the Mind-Overlap recipe relies on for its
//! shared DP seed).

use std::collections::BTreeSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use neuron_kit::spreading_activation;

use crate::error::{RecipeRunError, SubstrateError};

/// Teleport-home probability for the restart walk — SubstrateML's cookbook
/// § 7.4 default (`RandomWalks::DEFAULT_RESTART_PROB`).
const RESTART_PROB: f64 = 0.15;

/// One associated memory: the drawer the walk reached and its activation (the
/// fraction of walk steps that landed there). Strongest association first.
#[derive(Debug, Clone, PartialEq)]
pub struct Association {
    pub drawer_id: String,
    pub activation: f64,
}

/// Free-associate from `seed_drawer_id` over `wing`'s tunnel graph: walk
/// `walk_length` steps with restart and return the top `k` most-activated
/// drawers. A seed absent from the graph (no tunnel touches it) yields no
/// associations. Read-only; a recall failure propagates as
/// `RecipeRunError::Substrate`.
pub fn run_free_association(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    wing: &str,
    seed_drawer_id: &str,
    walk_length: usize,
    k: usize,
) -> Result<Vec<Association>, RecipeRunError> {
    let tunnels = coord
        .recall_tunnels(handle, wing)
        .map_err(|e| SubstrateError::new("recall_tunnels", format!("{e:?}")))?;

    let edges: Vec<(String, String)> = tunnels
        .iter()
        .filter_map(|t| match (&t.source_drawer_id, &t.target_drawer_id) {
            (Some(a), Some(b)) => Some((a.clone(), b.clone())),
            _ => None,
        })
        .collect();

    // Sorted node set ⇒ deterministic index assignment (same discipline as
    // Constellation / Keystones over this graph).
    let mut node_set: BTreeSet<String> = BTreeSet::new();
    for (a, b) in &edges {
        node_set.insert(a.clone());
        node_set.insert(b.clone());
    }
    let nodes: Vec<String> = node_set.into_iter().collect();
    let seed_idx = match nodes.iter().position(|n| n == seed_drawer_id) {
        Some(i) => i,
        None => return Ok(Vec::new()), // seed not in the graph ⇒ no associations
    };

    // Directed weighted adjacency; each tunnel is one unit-weight out-edge.
    let mut index = std::collections::BTreeMap::new();
    for (i, n) in nodes.iter().enumerate() {
        index.insert(n.as_str(), i);
    }
    let mut adjacency: Vec<Vec<(usize, f64)>> = vec![Vec::new(); nodes.len()];
    for (a, b) in &edges {
        let (ai, bi) = (index[a.as_str()], index[b.as_str()]);
        adjacency[ai].push((bi, 1.0));
    }

    // Deterministic walk seed from the seed drawer id (no clock).
    let rng_seed = substrate_types::fnv::hash64(seed_drawer_id);
    let activated =
        spreading_activation(&adjacency, seed_idx, walk_length, RESTART_PROB, rng_seed, k);

    Ok(activated
        .into_iter()
        .map(|a| Association {
            drawer_id: nodes[a.node].clone(),
            activation: a.activation,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use locus_kit::tunnel::Tunnel;

    const NOW: i64 = 1_700_000_000;
    const WING: &str = "study";
    // Long deterministic walk so visit frequencies are stable to assert on.
    const LEN: usize = 20_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        (coord, h)
    }

    fn add_edge(coord: &EstateCoordinator, h: &EstateHandle, id: &str, src: &str, tgt: &str) {
        let mut t = Tunnel::new(
            id.to_string(),
            WING.to_string(),
            "r".to_string(),
            WING.to_string(),
            "r".to_string(),
            "relates".to_string(),
            "user".to_string(),
            NOW,
        );
        t.source_drawer_id = Some(src.to_string());
        t.target_drawer_id = Some(tgt.to_string());
        coord.estate_for(h).unwrap().add_tunnel(&t).unwrap();
    }

    // CK-FA-1: from a seed, the directly-tunneled memory activates more than the
    // two-hop one, and a memory in a disconnected part of the graph never
    // surfaces — end-to-end "what does this remind you of."
    #[test]
    fn ck_fa1_associates_reachable_excludes_unreachable() {
        let (coord, h) = coord_with_parent();
        // Seed component: S<->A, A<->C (C is two hops from S).
        add_edge(&coord, &h, "e1", "S", "A");
        add_edge(&coord, &h, "e2", "A", "S");
        add_edge(&coord, &h, "e3", "A", "C");
        add_edge(&coord, &h, "e4", "C", "A");
        // Disconnected component: D<->E.
        add_edge(&coord, &h, "e5", "D", "E");
        add_edge(&coord, &h, "e6", "E", "D");

        let assoc = run_free_association(&coord, &h, WING, "S", LEN, 10).expect("free association");
        let ids: Vec<&str> = assoc.iter().map(|a| a.drawer_id.as_str()).collect();

        assert!(ids.contains(&"A"), "the directly-tunneled memory surfaces");
        assert!(ids.contains(&"C"), "the two-hop memory surfaces, weaker");
        assert!(!ids.contains(&"S"), "the seed is not its own association");
        assert!(
            !ids.contains(&"D") && !ids.contains(&"E"),
            "the disconnected component never surfaces"
        );

        let a = assoc
            .iter()
            .find(|x| x.drawer_id == "A")
            .unwrap()
            .activation;
        let c = assoc
            .iter()
            .find(|x| x.drawer_id == "C")
            .unwrap()
            .activation;
        assert!(
            a > c,
            "direct neighbor outranks the two-hop memory: {a} vs {c}"
        );
    }

    // CK-FA-2: a seed that no tunnel touches has no associations (guarded).
    #[test]
    fn ck_fa2_seed_absent_from_graph_is_empty() {
        let (coord, h) = coord_with_parent();
        add_edge(&coord, &h, "e1", "A", "B");
        let assoc = run_free_association(&coord, &h, WING, "S", LEN, 10).expect("free association");
        assert!(assoc.is_empty());
    }
}
