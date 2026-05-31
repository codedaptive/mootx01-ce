//! Keystones — the conscious "spine of your thinking" recipe (Lens 1,
//! Structure). Reads a wing's drawer-to-drawer tunnel graph from the estate
//! and ranks the load-bearing memories by eigenvalue centrality, returning
//! the top-K.
//!
//! NET-NEW, Rust-first: there is no Swift `Keystones` recipe yet — this is the
//! first reasoning lens chased BEYOND the shipped recipe set, proving the
//! through-line can grow new behaviour now that the foundation is real
//! (real estate, real graph read, real gated centrality math). A Swift parity
//! port follows the spec this establishes.
//!
//! Layer discipline: the recipe only SEQUENCES — it reads the graph via GLK
//! (`recall_tunnels`) and ranks via NeuronKit (`keystones`, which surfaces
//! SubstrateML's `EigenvalueCentrality`). No capability gate: it composes a
//! structural graph read, not one of the declared `NeuronKitCapability`
//! reasoning functions. Read-only — no estate write.

use std::collections::BTreeSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use neuron_kit::{keystones, Keystone};

use crate::error::{RecipeRunError, SubstrateError};

/// Rank the load-bearing memories in `wing` by eigenvalue centrality over its
/// drawer-to-drawer tunnel graph; return the top `top_k` keystones (descending
/// centrality, deterministic tie-break). A recall-tunnels failure propagates
/// as `RecipeRunError::Substrate`.
pub fn run_keystones(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    wing: &str,
    top_k: usize,
) -> Result<Vec<Keystone>, RecipeRunError> {
    let tunnels = coord
        .recall_tunnels(handle, wing)
        .map_err(|e| SubstrateError::new("recall_tunnels", format!("{e:?}")))?;

    // Edges: drawer-to-drawer tunnels only — room/wing-level tunnels are not
    // edges between individual memories.
    let edges: Vec<(String, String)> = tunnels
        .iter()
        .filter_map(|t| match (&t.source_drawer_id, &t.target_drawer_id) {
            (Some(a), Some(b)) => Some((a.clone(), b.clone())),
            _ => None,
        })
        .collect();

    // Nodes: the union of edge endpoints. An isolated drawer has zero
    // centrality and is never load-bearing, so the edge set defines the graph.
    // Sorted (BTreeSet) for a deterministic node ordering.
    let mut node_set: BTreeSet<String> = BTreeSet::new();
    for (a, b) in &edges {
        node_set.insert(a.clone());
        node_set.insert(b.clone());
    }
    let nodes: Vec<String> = node_set.into_iter().collect();

    Ok(keystones(&nodes, &edges, top_k))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use genius_locus_kit::handle::EstateHandle;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use locus_kit::tunnel::Tunnel;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;
    const WING: &str = "study";

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        (coord, h)
    }

    /// Seed one drawer-to-drawer tunnel in WING (the graph the lens reads).
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

    // CK-KS-1: the lens RUNS end-to-end over a real estate — a star graph's
    // hub surfaces as the top keystone, "the spine of your thinking."
    #[test]
    fn ck_ks1_star_hub_is_the_keystone() {
        let (coord, h) = coord_with_parent();
        add_edge(&coord, &h, "t1", "hub", "s1");
        add_edge(&coord, &h, "t2", "hub", "s2");
        add_edge(&coord, &h, "t3", "hub", "s3");
        add_edge(&coord, &h, "t4", "hub", "s4");

        let top = run_keystones(&coord, &h, WING, 3).expect("keystones");
        assert!(!top.is_empty());
        assert_eq!(top[0].id, "hub", "the hub is the load-bearing memory");
        assert!(top.len() <= 3, "top_k bounds the result");
    }

    // CK-KS-2: a wing with no tunnels yields an empty result — no graph, no
    // keystones, no panic.
    #[test]
    fn ck_ks2_empty_wing_has_no_keystones() {
        let (coord, h) = coord_with_parent();
        let top = run_keystones(&coord, &h, WING, 5).expect("keystones");
        assert!(top.is_empty());
    }
}
