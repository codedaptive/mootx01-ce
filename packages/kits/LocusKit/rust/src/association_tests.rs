//! Store-level conformance tests for the `Association` noun. Mirrors the
//! store section of `AssociationTests.swift` case-for-case (conformance
//! gate I-19), per mission NOUN-ASC-01 Part 3.
//!
//! The §2.4 operational-bitmap conformance cases (signal-sources-seen
//! bitset, decay class, arity) live inline in `association_operational.rs`
//! (the rust convention — `tunnel_operational.rs` likewise holds the
//! Tunnel operational conformance). This file holds the persistence
//! round-trip, the required lattice anchor, and edge-index resolution —
//! the rust counterparts of `AssociationTests.swift`'s store suite.
//!
//! The in-memory `InMemoryStorage` backend is ephemeral, so the Swift
//! `idempotentReopen` test (which re-opens a SQLite file) has no rust
//! counterpart — the same divergence the proposal rust store tests carry.

#![cfg(test)]

use crate::association::Association;
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use crate::estate_types::LatticeAnchor;
use persistence_kit::inmemory::InMemoryStorage;
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

fn open_store() -> InMemoryDrawerStore {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    InMemoryDrawerStore::new(storage, NOW, None).unwrap()
}

fn sample(id: &str, source_room: &str, target_room: &str, filed_at: i64) -> Association {
    Association::new(
        id.to_string(),
        "wing-a".to_string(),
        source_room.to_string(),
        "wing-b".to_string(),
        target_room.to_string(),
        "co-recalled".to_string(),
        LatticeAnchor::udc("547"),
        "dreaming".to_string(),
        filed_at,
    )
}

#[test]
fn add_and_get_round_trip_every_field() {
    let store = open_store();
    let mut a = sample("a1", "room-a", "room-b", NOW);
    a.source_drawer_id = Some("d-src".to_string());
    a.target_drawer_id = Some("d-tgt".to_string());
    a.adjective_bitmap = 0x0001;
    a.operational_bitmap = 0x4_3211;
    a.provenance_bitmap = 0xABCD;
    store.add_association(&a).unwrap();
    let loaded = store.get_association("a1").unwrap();
    assert_eq!(loaded, Some(a));
}

#[test]
fn all_bitmaps_byte_identical() {
    let store = open_store();
    let mut a = sample("a1", "room-a", "room-b", NOW);
    a.adjective_bitmap = 0x0021;
    a.operational_bitmap = 0x5_8001;
    a.provenance_bitmap = 0xABCD;
    store.add_association(&a).unwrap();
    let loaded = store.get_association("a1").unwrap().unwrap();
    assert_eq!(loaded.adjective_bitmap, 0x0021);
    assert_eq!(loaded.operational_bitmap, 0x5_8001);
    assert_eq!(loaded.provenance_bitmap, 0xABCD);
}

#[test]
fn lattice_anchor_round_trips() {
    let store = open_store();
    let anchor = LatticeAnchor::new(
        "547",
        Some("54".to_string()),
        Some("Q11351".to_string()),
        Some("Q2329,Q11173".to_string()),
    );
    let mut a = sample("a1", "room-a", "room-b", NOW);
    a.lattice_anchor = anchor.clone();
    store.add_association(&a).unwrap();
    let loaded = store.get_association("a1").unwrap().unwrap();
    assert_eq!(loaded.lattice_anchor, anchor);
}

#[test]
fn lattice_anchor_required_rejects_empty() {
    let store = open_store();
    let mut a = sample("a1", "room-a", "room-b", NOW);
    a.lattice_anchor = LatticeAnchor::udc("");
    let err = store.add_association(&a).unwrap_err();
    assert!(
        matches!(err, LocusKitError::InvalidContent(_)),
        "got {:?}",
        err
    );
    // The rejected association must not have landed.
    assert_eq!(store.get_association("a1").unwrap(), None);
}

#[test]
fn associations_from_filters_source_and_orders() {
    let store = open_store();
    store
        .add_association(&sample("a-late", "r", "room-b", NOW + 300))
        .unwrap();
    store
        .add_association(&sample("a-early", "r", "room-b", NOW + 100))
        .unwrap();
    store
        .add_association(&sample("a-mid", "r", "room-b", NOW + 200))
        .unwrap();
    store
        .add_association(&sample("a-other", "other", "room-b", NOW + 150))
        .unwrap();

    let here = store.associations_from("wing-a", "r").unwrap();
    let other = store.associations_from("wing-a", "other").unwrap();
    let here_ids: Vec<&str> = here.iter().map(|a| a.id.as_str()).collect();
    let other_ids: Vec<&str> = other.iter().map(|a| a.id.as_str()).collect();
    assert_eq!(here_ids, vec!["a-early", "a-mid", "a-late"]);
    assert_eq!(other_ids, vec!["a-other"]);
}

#[test]
fn associations_to_filters_target() {
    let store = open_store();
    store
        .add_association(&sample("a1", "room-a", "tr", NOW + 100))
        .unwrap();
    store
        .add_association(&sample("a2", "room-a", "tr", NOW + 200))
        .unwrap();
    store
        .add_association(&sample("a3", "room-a", "elsewhere", NOW + 150))
        .unwrap();

    let to_tr = store.associations_to("wing-b", "tr").unwrap();
    let to_tr_ids: Vec<&str> = to_tr.iter().map(|a| a.id.as_str()).collect();
    assert_eq!(to_tr_ids, vec!["a1", "a2"]);
    let elsewhere = store.associations_to("wing-b", "elsewhere").unwrap();
    assert_eq!(elsewhere.len(), 1);
    assert_eq!(elsewhere[0].id, "a3");
}

#[test]
fn tombstoned_excluded_from_edge_lookups_but_fetchable_by_id() {
    let store = open_store();
    let live = sample("a-live", "r", "room-b", NOW + 100);
    let mut dead = sample("a-dead", "r", "room-b", NOW + 200);
    dead.tombstoned_at = Some(NOW + 250);
    dead.removed_by_batch = Some("batch-1".to_string());
    store.add_association(&live).unwrap();
    store.add_association(&dead).unwrap();

    let from = store.associations_from("wing-a", "r").unwrap();
    let from_ids: Vec<&str> = from.iter().map(|a| a.id.as_str()).collect();
    assert_eq!(from_ids, vec!["a-live"]);
    // Fetchable by id regardless of tombstone.
    assert_eq!(store.get_association("a-dead").unwrap(), Some(dead));
}

#[test]
fn get_miss_returns_none() {
    let store = open_store();
    assert_eq!(store.get_association("no-such-association").unwrap(), None);
}

#[test]
fn table_isolation_does_not_touch_tunnels() {
    use crate::tunnel::Tunnel;
    let store = open_store();
    let t = Tunnel::new(
        "t-1".to_string(),
        "wing-a".to_string(),
        "room-a".to_string(),
        "wing-b".to_string(),
        "room-b".to_string(),
        "references".to_string(),
        "bilby".to_string(),
        NOW,
    );
    store.add_tunnel(&t).unwrap();
    store
        .add_association(&sample("a-iso", "room-a", "room-b", NOW))
        .unwrap();

    // Tunnel surface unaffected by the association write.
    assert_eq!(
        store
            .tunnels_from_wing_room("wing-a", "room-a")
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        store.associations_from("wing-a", "room-a").unwrap().len(),
        1
    );
    // And the association did not leak into the tunnel fetch.
    assert_eq!(store.get_tunnel("a-iso").unwrap(), None);
}
