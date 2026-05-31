//! Anticipate — the conscious "what comes next" recipe (Lens 8, Prediction).
//! Given an anchor memory, follow its OUTGOING tunnels (the directed
//! association graph) and rank where they lead by frequency — "after this,
//! you tend to reach these." Pre-stage the memory before it's asked for.
//!
//! NET-NEW, Rust-first (ninth lens). Pure CognitionKit sequencing over GLK
//! `recall_tunnels` (the directed edges). Read-only.
//!
//! v1 model: directed tunnel-successor frequency. The brainstorm's full
//! Anticipate folds in the action-outcome / temporal-causality T-matrix
//! (`SubstrateML::action_outcome`), which needs an HLC-stamped action→outcome
//! EVENT STREAM the estate does not yet expose; the tunnel graph is the
//! available causal signal, and that refinement layers on when the stream
//! lands.

use std::collections::BTreeMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;

use crate::error::{RecipeRunError, SubstrateError};

/// A predicted-next memory: the target drawer id and how many tunnels lead to
/// it from the anchor.
#[derive(Debug, Clone, PartialEq)]
pub struct Anticipation {
    pub id: String,
    pub weight: usize,
}

/// Predict the memories most likely to follow `anchor_id` in `wing`: rank the
/// targets of its outgoing drawer-to-drawer tunnels by frequency, top `k`
/// (ties broken by id). Read-only; recall failure → `RecipeRunError::Substrate`.
pub fn run_anticipate(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    wing: &str,
    anchor_id: &str,
    k: usize,
) -> Result<Vec<Anticipation>, RecipeRunError> {
    let tunnels = coord
        .recall_tunnels(handle, wing)
        .map_err(|e| SubstrateError::new("recall_tunnels", format!("{e:?}")))?;

    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for t in &tunnels {
        if t.source_drawer_id.as_deref() == Some(anchor_id) {
            if let Some(target) = &t.target_drawer_id {
                if target != anchor_id {
                    *counts.entry(target.clone()).or_insert(0) += 1;
                }
            }
        }
    }

    let mut ranked: Vec<Anticipation> =
        counts.into_iter().map(|(id, weight)| Anticipation { id, weight }).collect();
    ranked.sort_by(|a, b| b.weight.cmp(&a.weight).then_with(|| a.id.cmp(&b.id)));
    ranked.truncate(k);
    Ok(ranked)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

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

    fn edge(coord: &EstateCoordinator, h: &EstateHandle, id: &str, src: &str, tgt: &str) {
        let mut t = Tunnel::new(
            id.to_string(),
            WING.to_string(),
            "r".to_string(),
            WING.to_string(),
            "r".to_string(),
            "leads-to".to_string(),
            "user".to_string(),
            NOW,
        );
        t.source_drawer_id = Some(src.to_string());
        t.target_drawer_id = Some(tgt.to_string());
        coord.estate_for(h).unwrap().add_tunnel(&t).unwrap();
    }

    // CK-AN-1: from the anchor, the more-frequently-tunneled target is the
    // stronger prediction; an unrelated edge elsewhere is ignored.
    #[test]
    fn ck_an1_frequent_successor_ranks_first() {
        let (coord, h) = coord_with_parent();
        edge(&coord, &h, "t1", "anchor", "X");
        edge(&coord, &h, "t2", "anchor", "X"); // X twice
        edge(&coord, &h, "t3", "anchor", "Y"); // Y once
        edge(&coord, &h, "t4", "other", "Z"); // unrelated to anchor

        let out = run_anticipate(&coord, &h, WING, "anchor", 5).expect("anticipate");
        assert_eq!(out.len(), 2, "only the anchor's successors");
        assert_eq!(out[0].id, "X", "the frequent successor leads");
        assert_eq!(out[0].weight, 2);
        assert_eq!(out[1].id, "Y");
    }

    // CK-AN-2: an anchor with no outgoing tunnels predicts nothing (guarded).
    #[test]
    fn ck_an2_no_successors_empty() {
        let (coord, h) = coord_with_parent();
        edge(&coord, &h, "t1", "other", "Z");
        let out = run_anticipate(&coord, &h, WING, "anchor", 5).expect("anticipate");
        assert!(out.is_empty());
    }
}
