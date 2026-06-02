//! Store-level conformance tests for the `Proposal` noun. Mirrors the
//! store section of `ProposalTests.swift` case-for-case (conformance
//! gate I-19), per mission NOUN-PRO-01 Part 3.
//!
//! The §2.4 operational-bitmap conformance cases and the adjective
//! `state` accessor live inline in `proposal_operational.rs` and
//! `proposal.rs` (the rust convention — `kg_fact_operational.rs`
//! likewise holds the KGFact operational conformance). This file holds
//! the persistence round-trip, the required lattice anchor, and index
//! resolution — the rust counterparts of `ProposalTests.swift`'s store
//! suite.
//!
//! The in-memory `InMemoryStorage` backend is ephemeral, so the Swift
//! `idempotentReopen` test (which re-opens a SQLite file) has no rust
//! counterpart — the same divergence the KGFact rust store tests carry.

#![cfg(test)]

use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use crate::estate_types::LatticeAnchor;
use crate::proposal::Proposal;
use crate::proposal_operational::ProposalTargetObjectType;

const NOW: i64 = 1_700_000_000;

fn open_store() -> InMemoryDrawerStore {
    // InMemoryDrawerStore::new allocates InMemoryStorage internally —
    // backend identity is visible at the type, not the argument.
    InMemoryDrawerStore::new(NOW, None).unwrap()
}

fn sample(id: &str, target: &str, filed_at: i64) -> Proposal {
    let mut p = Proposal::new(
        id.to_string(),
        target.to_string(),
        LatticeAnchor::udc("547"),
        filed_at,
    );
    p.justification = Some("drift detected".to_string());
    p
}

#[test]
fn add_and_get_round_trip_every_field() {
    let store = open_store();
    let mut p = sample("p1", "d1", NOW);
    p.candidate_state = 0x1F;
    p.operational_bitmap = 0x3211;
    p.provenance_bitmap = 0xABCD;
    store.add_proposal(&p).unwrap();
    let loaded = store.get_proposal("p1").unwrap();
    assert_eq!(loaded, Some(p));
}

#[test]
fn all_bitmaps_byte_identical() {
    let store = open_store();
    let mut p = sample("p1", "d1", NOW);
    p.candidate_state = 0x1234;
    p.adjective_bitmap = 0x0001;
    p.operational_bitmap = 0x3211;
    p.provenance_bitmap = 0xABCD;
    store.add_proposal(&p).unwrap();
    let loaded = store.get_proposal("p1").unwrap().unwrap();
    assert_eq!(loaded.candidate_state, 0x1234);
    assert_eq!(loaded.adjective_bitmap, 0x0001);
    assert_eq!(loaded.operational_bitmap, 0x3211);
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
    let mut p = sample("p1", "d1", NOW);
    p.lattice_anchor = anchor.clone();
    store.add_proposal(&p).unwrap();
    let loaded = store.get_proposal("p1").unwrap().unwrap();
    assert_eq!(loaded.lattice_anchor, anchor);
}

#[test]
fn lattice_anchor_required_rejects_empty() {
    let store = open_store();
    let mut p = sample("p1", "d1", NOW);
    p.lattice_anchor = LatticeAnchor::udc("");
    let err = store.add_proposal(&p).unwrap_err();
    assert!(
        matches!(err, LocusKitError::InvalidContent(_)),
        "got {:?}",
        err
    );
    // The rejected proposal must not have landed.
    assert_eq!(store.get_proposal("p1").unwrap(), None);
}

#[test]
fn empty_target_allowed_for_brand_new_object() {
    let store = open_store();
    let mut p = sample("p1", "", NOW);
    // target_object_type = NoneBrandNew (raw 4) at bits 6–11.
    p.operational_bitmap = ProposalTargetObjectType::NoneBrandNew.raw_value() << 6;
    store.add_proposal(&p).unwrap();
    assert_eq!(store.get_proposal("p1").unwrap(), Some(p));
}

#[test]
fn proposals_for_target_filters_and_orders() {
    let store = open_store();
    store
        .add_proposal(&sample("p-late", "d1", NOW + 300))
        .unwrap();
    store
        .add_proposal(&sample("p-early", "d1", NOW + 100))
        .unwrap();
    store
        .add_proposal(&sample("p-mid", "d1", NOW + 200))
        .unwrap();
    store
        .add_proposal(&sample("p-other", "d2", NOW + 150))
        .unwrap();

    let d1 = store.proposals_for_target("d1").unwrap();
    let d2 = store.proposals_for_target("d2").unwrap();
    let d1_ids: Vec<&str> = d1.iter().map(|p| p.id.as_str()).collect();
    let d2_ids: Vec<&str> = d2.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(d1_ids, vec!["p-early", "p-mid", "p-late"]);
    assert_eq!(d2_ids, vec!["p-other"]);
}

#[test]
fn get_miss_returns_none() {
    let store = open_store();
    assert_eq!(store.get_proposal("no-such-proposal").unwrap(), None);
}

#[test]
fn table_isolation_does_not_touch_kg_facts() {
    use crate::kg_fact::KGFact;
    let store = open_store();
    let f = KGFact::new(
        "f1".to_string(),
        "alice".to_string(),
        "livesIn".to_string(),
        "berlin".to_string(),
        "d1".to_string(),
        NOW,
    );
    store.add_kg_fact(&f).unwrap();
    store.add_proposal(&sample("p-iso", "d1", NOW)).unwrap();

    // KGFact surface unaffected by the proposal write.
    assert_eq!(store.kg_facts_for_drawer("d1").unwrap().len(), 1);
    assert_eq!(store.proposals_for_target("d1").unwrap().len(), 1);
    // And the proposal did not leak into the kg_facts fetch.
    assert_eq!(store.get_kg_fact("p-iso").unwrap(), None);
}
