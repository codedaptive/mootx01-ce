//! Store-level conformance tests for the `LearnedReference` noun. Mirrors the
//! store section of `LearnedReferenceTests.swift` case-for-case (conformance
//! gate I-19), per mission NOUN-LRF-01 Part 3.
//!
//! The §2.4 operational-bitmap conformance cases (refresh_policy,
//! drift_severity, mode, source) live inline in `learned_reference.rs` (the
//! rust convention — `association_operational.rs` likewise holds the
//! Association operational conformance). This file holds the persistence
//! round-trip, the required lattice anchor, the content-field survival, and
//! source-index resolution — the rust counterparts of
//! `LearnedReferenceTests.swift`'s store suite.
//!
//! The in-memory `InMemoryStorage` backend is ephemeral, so the Swift
//! `idempotentReopen` test (which re-opens a SQLite file) has no rust
//! counterpart — the same divergence the association/proposal rust store
//! tests carry.

#![cfg(test)]

use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use crate::estate_types::LatticeAnchor;
use crate::learned_reference::LearnedReference;

const NOW: i64 = 1_700_000_000;

fn open_store() -> InMemoryDrawerStore {
    // InMemoryDrawerStore::new allocates InMemoryStorage internally —
    // backend identity is visible at the type, not the argument.
    InMemoryDrawerStore::new(NOW, None).unwrap()
}

fn sample(id: &str, source_catalog_id: &str, filed_at: i64) -> LearnedReference {
    LearnedReference::new(
        id.to_string(),
        source_catalog_id.to_string(),
        "https://example.com/spec".to_string(),
        LatticeAnchor::udc("004"),
        "learner".to_string(),
        filed_at,
    )
}

#[test]
fn add_and_get_round_trip_every_field() {
    let store = open_store();
    let mut r = sample("lr1", "cat-a", NOW);
    r.adjective_bitmap = 0x0001;
    r.operational_bitmap = 0x4_3018;
    r.provenance_bitmap = 0xABCD;
    store.add_learned_reference(&r).unwrap();
    let loaded = store.get_learned_reference("lr1").unwrap();
    assert_eq!(loaded, Some(r));
}

#[test]
fn all_bitmaps_byte_identical() {
    let store = open_store();
    let mut r = sample("lr1", "cat-a", NOW);
    r.adjective_bitmap = 0x0021;
    r.operational_bitmap = 0x5_8018;
    r.provenance_bitmap = 0xABCD;
    store.add_learned_reference(&r).unwrap();
    let loaded = store.get_learned_reference("lr1").unwrap().unwrap();
    assert_eq!(loaded.adjective_bitmap, 0x0021);
    assert_eq!(loaded.operational_bitmap, 0x5_8018);
    assert_eq!(loaded.provenance_bitmap, 0xABCD);
}

#[test]
fn lattice_anchor_round_trips() {
    let store = open_store();
    let anchor = LatticeAnchor::new(
        "004",
        Some("00".to_string()),
        Some("Q11366".to_string()),
        Some("Q2329,Q11173".to_string()),
    );
    let mut r = sample("lr1", "cat-a", NOW);
    r.lattice_anchor = anchor.clone();
    store.add_learned_reference(&r).unwrap();
    let loaded = store.get_learned_reference("lr1").unwrap().unwrap();
    assert_eq!(loaded.lattice_anchor, anchor);
}

#[test]
fn lattice_anchor_required_rejects_empty() {
    let store = open_store();
    let mut r = sample("lr1", "cat-a", NOW);
    r.lattice_anchor = LatticeAnchor::udc("");
    let err = store.add_learned_reference(&r).unwrap_err();
    assert!(
        matches!(err, LocusKitError::InvalidContent(_)),
        "got {:?}",
        err
    );
    // The rejected reference must not have landed.
    assert_eq!(store.get_learned_reference("lr1").unwrap(), None);
}

#[test]
fn content_fields_survive_round_trip() {
    let store = open_store();
    let mut r = sample("lr1", "catalog:wikipedia/en", NOW);
    r.handle = "https://en.wikipedia.org/wiki/Memory_palace#History".to_string();
    store.add_learned_reference(&r).unwrap();
    let loaded = store.get_learned_reference("lr1").unwrap().unwrap();
    assert_eq!(loaded.source_catalog_id, "catalog:wikipedia/en");
    assert_eq!(
        loaded.handle,
        "https://en.wikipedia.org/wiki/Memory_palace#History"
    );
}

#[test]
fn learned_references_from_source_filters_and_orders() {
    let store = open_store();
    store
        .add_learned_reference(&sample("r-late", "cat-a", NOW + 300))
        .unwrap();
    store
        .add_learned_reference(&sample("r-early", "cat-a", NOW + 100))
        .unwrap();
    store
        .add_learned_reference(&sample("r-mid", "cat-a", NOW + 200))
        .unwrap();
    store
        .add_learned_reference(&sample("r-other", "cat-b", NOW + 150))
        .unwrap();

    let cat_a = store.learned_references_from_source("cat-a").unwrap();
    let cat_b = store.learned_references_from_source("cat-b").unwrap();
    let a_ids: Vec<&str> = cat_a.iter().map(|r| r.id.as_str()).collect();
    let b_ids: Vec<&str> = cat_b.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(a_ids, vec!["r-early", "r-mid", "r-late"]);
    assert_eq!(b_ids, vec!["r-other"]);
}

#[test]
fn tombstoned_excluded_from_source_lookup_but_fetchable_by_id() {
    let store = open_store();
    let live = sample("r-live", "cat-a", NOW + 100);
    let mut dead = sample("r-dead", "cat-a", NOW + 200);
    dead.tombstoned_at = Some(NOW + 250);
    dead.removed_by_batch = Some("batch-1".to_string());
    store.add_learned_reference(&live).unwrap();
    store.add_learned_reference(&dead).unwrap();

    let from = store.learned_references_from_source("cat-a").unwrap();
    let from_ids: Vec<&str> = from.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(from_ids, vec!["r-live"]);
    // Fetchable by id regardless of tombstone.
    assert_eq!(store.get_learned_reference("r-dead").unwrap(), Some(dead));
}

#[test]
fn get_miss_returns_none() {
    let store = open_store();
    assert_eq!(
        store.get_learned_reference("no-such-reference").unwrap(),
        None
    );
}

#[test]
fn table_isolation_does_not_touch_associations() {
    use crate::association::Association;
    let store = open_store();
    let a = Association::new(
        "a-iso".to_string(),
        "wing-a".to_string(),
        "room-a".to_string(),
        "wing-b".to_string(),
        "room-b".to_string(),
        "co-recalled".to_string(),
        LatticeAnchor::udc("547"),
        "dreaming".to_string(),
        NOW,
    );
    store.add_association(&a).unwrap();
    store
        .add_learned_reference(&sample("lr-iso", "cat-a", NOW))
        .unwrap();

    // Association surface unaffected by the learned-reference write.
    assert_eq!(store.get_association("a-iso").unwrap(), Some(a));
    // The learned reference did not leak into the association fetch.
    assert_eq!(store.get_association("lr-iso").unwrap(), None);
    // And the association did not leak into the learned-reference fetch.
    assert_eq!(store.get_learned_reference("a-iso").unwrap(), None);
}
