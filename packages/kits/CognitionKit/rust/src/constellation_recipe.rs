//! Constellation — the conscious "emergent themes" recipe (Lens 1, Structure).
//! Reads a wing's drawer-to-drawer tunnel graph and clusters it into the
//! communities the user never explicitly named (Louvain via NeuronKit
//! `constellations`). The companion to Keystones over the same graph: keystones
//! finds the spine, constellation finds the constellations.
//!
//! Paired with the Swift version (`Sources/CognitionKit/Constellation.swift`).
//! Pure CognitionKit sequencing: the tunnel
//! graph via GLK `recall_tunnels` (the accessor Keystones added) + NeuronKit
//! `constellations` (SubstrateML community detection). Read-only.

use std::collections::BTreeSet;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use neuron_kit::{constellations, Constellation};

use crate::error::{RecipeRunError, SubstrateError};

/// Cluster the drawer-to-drawer tunnel graph of `wing` into emergent
/// communities. Read-only; a recall failure propagates as
/// `RecipeRunError::Substrate`.
pub fn run_constellation(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    wing: &str,
) -> Result<Constellation, RecipeRunError> {
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

    let mut node_set: BTreeSet<String> = BTreeSet::new();
    for (a, b) in &edges {
        node_set.insert(a.clone());
        node_set.insert(b.clone());
    }
    let nodes: Vec<String> = node_set.into_iter().collect();

    Ok(constellations(
        &nodes,
        &edges,
        neuron_kit::constellation::DEFAULT_MAX_PASSES,
    ))
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

    // CK-CS-1: two tunnel-cliques in a wing surface as two emergent themes,
    // end-to-end over a real estate. The estate finds clusters you never named.
    #[test]
    fn ck_cs1_two_cliques_two_constellations() {
        let (coord, h) = coord_with_parent();
        // Triangle A.
        add_edge(&coord, &h, "t1", "A1", "A2");
        add_edge(&coord, &h, "t2", "A1", "A3");
        add_edge(&coord, &h, "t3", "A2", "A3");
        // Triangle B.
        add_edge(&coord, &h, "t4", "B1", "B2");
        add_edge(&coord, &h, "t5", "B1", "B3");
        add_edge(&coord, &h, "t6", "B2", "B3");

        let c = run_constellation(&coord, &h, WING).expect("constellation");
        assert_eq!(c.communities.len(), 2, "two cliques ⇒ two emergent themes");
    }

    // CK-CS-2: an empty wing ⇒ no constellations (guarded).
    #[test]
    fn ck_cs2_empty_wing_guarded() {
        let (coord, h) = coord_with_parent();
        let c = run_constellation(&coord, &h, WING).expect("constellation");
        assert!(c.communities.is_empty());
    }
}
