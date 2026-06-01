//! Conformance for standalone tunnel capture — `Estate::capture_tunnel`
//! (mission VERB-CAP-01). Rust mirror of `CaptureTunnelTests.swift`.

#![cfg(test)]

use crate::drawer_operational::CaptureChannel;
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::{CaptureFrame, TunnelCaptureFrame};
use crate::tunnel_operational::TunnelKind;
use persistence_kit::inmemory::InMemoryStorage;
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

fn make_estate_with_store() -> (Estate, Arc<InMemoryDrawerStore>) {
    let storage: Arc<dyn persistence_kit::storage::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let store = Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();
    (estate, store)
}

fn sample_frame() -> TunnelCaptureFrame {
    TunnelCaptureFrame::new("wing_a", "room_1", "wing_b", "room_2", "links", "bilby")
}

fn drawer_frame(content: &str, lineage: Uuid) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content, CaptureChannel::Typed, "test-room",
        LatticeAnchor::udc("004"), "test-agent", "minilm-v6",
    );
    f.lineage_id = Some(lineage);
    f
}

#[test]
fn capture_round_trips() {
    let (estate, store) = make_estate_with_store();
    let captured = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    assert!(!captured.id.is_empty());
    assert_eq!(captured.source_wing, "wing_a");
    assert_eq!(captured.source_room, "room_1");
    assert_eq!(captured.target_wing, "wing_b");
    assert_eq!(captured.target_room, "room_2");
    assert_eq!(captured.label, "links");
    assert_eq!(captured.kind, TunnelKind::References);
    assert_eq!(captured.added_by, "bilby");
    assert_eq!(captured.tombstoned_at, None);
    assert_eq!(captured.removed_by_batch, None);
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    assert_eq!(loaded, captured);
}

#[test]
fn capture_zero_bitmaps() {
    let (estate, store) = make_estate_with_store();
    let captured = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    assert_eq!(captured.adjective_bitmap, 0);
    assert_eq!(captured.operational_bitmap, 0);
    assert_eq!(captured.provenance_bitmap, 0);
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    assert_eq!(loaded.adjective_bitmap, 0);
    assert_eq!(loaded.operational_bitmap, 0);
    assert_eq!(loaded.provenance_bitmap, 0);
}

#[test]
fn byte_identical_to_cascade() {
    let (estate, store) = make_estate_with_store();
    let lineage = Uuid::new_v4();
    let first = estate.capture(drawer_frame("v1", lineage), NOW).unwrap();
    let second = estate.capture(drawer_frame("v2", lineage), NOW + 100).unwrap();
    let cascade_tunnel = store
        .get_tunnel(&format!("supersedes:{}:{}", second.id, first.id))
        .unwrap().unwrap();
    let mut frame = TunnelCaptureFrame::new(
        second.wing.clone(), second.room.clone(),
        first.wing.clone(), first.room.clone(),
        "supersedes", "test-agent",
    );
    frame.kind = TunnelKind::Supersedes;
    frame.source_drawer_id = Some(second.id.clone());
    frame.target_drawer_id = Some(first.id.clone());
    let standalone = estate.capture_tunnel(frame, NOW).unwrap();
    assert_eq!(standalone.source_wing, cascade_tunnel.source_wing);
    assert_eq!(standalone.source_room, cascade_tunnel.source_room);
    assert_eq!(standalone.source_drawer_id, cascade_tunnel.source_drawer_id);
    assert_eq!(standalone.target_wing, cascade_tunnel.target_wing);
    assert_eq!(standalone.target_room, cascade_tunnel.target_room);
    assert_eq!(standalone.target_drawer_id, cascade_tunnel.target_drawer_id);
    assert_eq!(standalone.label, cascade_tunnel.label);
    assert_eq!(standalone.kind, cascade_tunnel.kind);
    assert_eq!(standalone.adjective_bitmap, cascade_tunnel.adjective_bitmap);
    assert_eq!(standalone.operational_bitmap, cascade_tunnel.operational_bitmap);
    assert_eq!(standalone.provenance_bitmap, cascade_tunnel.provenance_bitmap);
    assert_eq!(standalone.tombstoned_at, cascade_tunnel.tombstoned_at);
    assert_eq!(standalone.removed_by_batch, cascade_tunnel.removed_by_batch);
}

#[test]
fn endpoints_resolve() {
    let (estate, store) = make_estate_with_store();
    let mut frame = sample_frame();
    frame.source_drawer_id = Some("d-src".to_string());
    frame.target_drawer_id = Some("d-tgt".to_string());
    let captured = estate.capture_tunnel(frame, NOW).unwrap();
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    assert_eq!(loaded.source_drawer_id.as_deref(), Some("d-src"));
    assert_eq!(loaded.target_drawer_id.as_deref(), Some("d-tgt"));
    assert_eq!(loaded.source_wing, "wing_a");
    assert_eq!(loaded.target_wing, "wing_b");
}

#[test]
fn room_level_endpoints() {
    let (estate, store) = make_estate_with_store();
    let captured = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    assert_eq!(loaded.source_drawer_id, None);
    assert_eq!(loaded.target_drawer_id, None);
}

#[test]
fn recallable_from_source() {
    let (estate, store) = make_estate_with_store();
    let captured = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    let from = store.tunnels_from_wing_room("wing_a", "room_1").unwrap();
    assert!(from.iter().any(|t| t.id == captured.id));
}

#[test]
fn recallable_to_target() {
    let (estate, store) = make_estate_with_store();
    let captured = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    let to = store.tunnels_to_wing("wing_b").unwrap();
    assert!(to.iter().any(|t| t.id == captured.id));
}

#[test]
fn kind_default_and_round_trip() {
    let (estate, store) = make_estate_with_store();
    let def = estate.capture_tunnel(sample_frame(), NOW).unwrap();
    assert_eq!(def.kind, TunnelKind::References);
    let mut frame = sample_frame();
    frame.kind = TunnelKind::Blocks;
    let blocks = estate.capture_tunnel(frame, NOW).unwrap();
    let loaded = store.get_tunnel(&blocks.id).unwrap().unwrap();
    assert_eq!(loaded.kind, TunnelKind::Blocks);
}

fn assert_invalid(frame: TunnelCaptureFrame) {
    let (estate, _store) = make_estate_with_store();
    let err = estate.capture_tunnel(frame, NOW).unwrap_err();
    assert!(matches!(err, LocusKitError::InvalidContent(_)));
}

#[test]
fn rejects_empty_source_wing() { let mut f = sample_frame(); f.source_wing = String::new(); assert_invalid(f); }
#[test]
fn rejects_empty_source_room() { let mut f = sample_frame(); f.source_room = String::new(); assert_invalid(f); }
#[test]
fn rejects_empty_target_wing() { let mut f = sample_frame(); f.target_wing = String::new(); assert_invalid(f); }
#[test]
fn rejects_empty_target_room() { let mut f = sample_frame(); f.target_room = String::new(); assert_invalid(f); }
#[test]
fn rejects_empty_label() { let mut f = sample_frame(); f.label = String::new(); assert_invalid(f); }
#[test]
fn rejects_empty_added_by() { let mut f = sample_frame(); f.added_by = String::new(); assert_invalid(f); }
