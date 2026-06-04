//! Conformance for standalone tunnel capture — `Estate::capture_tunnel`
//! (mission VERB-CAP-01). Rust mirror of `CaptureTunnelTests.swift`.

#![cfg(test)]

use crate::drawer_operational::{CaptureChannel, DrawerFeatureFlags};
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::{CaptureFrame, TunnelCaptureFrame};
use crate::tunnel_operational::{TunnelKind, TunnelOriginClass};
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

fn make_estate_with_store() -> (Estate, Arc<InMemoryDrawerStore>) {
    // InMemoryDrawerStore::new allocates InMemoryStorage internally —
    // backend identity is visible at the type, not the argument.
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();
    (estate, store)
}

fn sample_frame() -> TunnelCaptureFrame {
    TunnelCaptureFrame::new("wing_a", "room_1", "wing_b", "room_2", "links", "bilby")
}

fn drawer_frame(content: &str, lineage: Uuid) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("004"),
        "test-agent",
        "minilm-v6",
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
    let second = estate
        .capture(drawer_frame("v2", lineage), NOW + 100)
        .unwrap();
    let cascade_tunnel = store
        .get_tunnel(&format!("supersedes:{}:{}", second.id, first.id))
        .unwrap()
        .unwrap();
    let mut frame = TunnelCaptureFrame::new(
        second.wing.clone(),
        second.room.clone(),
        first.wing.clone(),
        first.room.clone(),
        "supersedes",
        "test-agent",
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
    assert_eq!(
        standalone.operational_bitmap,
        cascade_tunnel.operational_bitmap
    );
    assert_eq!(
        standalone.provenance_bitmap,
        cascade_tunnel.provenance_bitmap
    );
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
fn rejects_empty_source_wing() {
    let mut f = sample_frame();
    f.source_wing = String::new();
    assert_invalid(f);
}
#[test]
fn rejects_empty_source_room() {
    let mut f = sample_frame();
    f.source_room = String::new();
    assert_invalid(f);
}
#[test]
fn rejects_empty_target_wing() {
    let mut f = sample_frame();
    f.target_wing = String::new();
    assert_invalid(f);
}
#[test]
fn rejects_empty_target_room() {
    let mut f = sample_frame();
    f.target_room = String::new();
    assert_invalid(f);
}
#[test]
fn rejects_empty_label() {
    let mut f = sample_frame();
    f.label = String::new();
    assert_invalid(f);
}
#[test]
fn rejects_empty_added_by() {
    let mut f = sample_frame();
    f.added_by = String::new();
    assert_invalid(f);
}

// --------------------------------------------------------------------------
// origin_class round-trip tests (TCO-001)
// --------------------------------------------------------------------------

/// Default `origin_class` is `UserExplicit` and the captured tunnel's
/// `operational_bitmap` is zero.
#[test]
fn origin_class_default_is_user_explicit_and_zero_bitmap() {
    let (estate, store) = make_estate_with_store();
    let frame = sample_frame(); // origin_class defaults to UserExplicit
    let captured = estate.capture_tunnel(frame, NOW).unwrap();
    assert_eq!(captured.origin_class(), TunnelOriginClass::UserExplicit);
    assert_eq!(captured.operational_bitmap, 0);
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    assert_eq!(loaded.origin_class(), TunnelOriginClass::UserExplicit);
    assert_eq!(loaded.operational_bitmap, 0);
}

/// Round-trip all five `TunnelOriginClass` variants through capture and
/// verify both the decoded enum and the raw bit pattern.
#[test]
fn origin_class_round_trips_all_five_raws() {
    let (estate, store) = make_estate_with_store();
    // (origin_class, expected bits 6–8 in operational_bitmap)
    let cases: &[(TunnelOriginClass, i64)] = &[
        (TunnelOriginClass::UserExplicit, 0 << 6),  // raw 0
        (TunnelOriginClass::Derived, 1 << 6),       // raw 1
        (TunnelOriginClass::Imported, 2 << 6),      // raw 2
        (TunnelOriginClass::FederatedSync, 3 << 6), // raw 3
        (TunnelOriginClass::Migration, 4 << 6),     // raw 4
    ];
    for &(origin_class, expected_bits) in cases {
        let mut frame = sample_frame();
        frame.origin_class = origin_class;
        let captured = estate.capture_tunnel(frame, NOW).unwrap();
        let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
        assert_eq!(loaded.origin_class(), origin_class);
        assert_eq!(loaded.operational_bitmap, expected_bits);
    }
}

/// `.Imported` (raw 2) encodes to `2 << 6 = 0x80 = 128`.
/// This is the canonical VaultKit use case that motivated the mission.
/// Mirrors the Swift `importedOriginClassBitPattern` test.
#[test]
fn imported_origin_class_encodes_to_0x80() {
    let (estate, store) = make_estate_with_store();
    let mut frame = sample_frame();
    frame.origin_class = TunnelOriginClass::Imported;
    let captured = estate.capture_tunnel(frame, NOW).unwrap();
    let loaded = store.get_tunnel(&captured.id).unwrap().unwrap();
    // imported (raw 2) at shift 6, width 3 → 2 << 6 = 0x80.
    assert_eq!(loaded.operational_bitmap, 0x80);
    assert_eq!(loaded.origin_class().raw_value(), 2);
    assert_eq!(loaded.origin_class(), TunnelOriginClass::Imported);
}

/// Swift/Rust parity: `.Imported` → `operational_bitmap == 0x80`.
/// Asserts the same value the Swift `importedOriginClassSwiftRustParity` test asserts.
#[test]
fn imported_origin_class_swift_rust_parity() {
    let (estate, _store) = make_estate_with_store();
    let mut frame = sample_frame();
    frame.origin_class = TunnelOriginClass::Imported;
    let captured = estate.capture_tunnel(frame, NOW).unwrap();
    assert_eq!(captured.operational_bitmap, 0x80);
}

// --------------------------------------------------------------------------
// DrawerFeatureFlags round-trip tests (TCO-001)
// --------------------------------------------------------------------------

fn drawer_frame_with_flags(content: &str, feature_flags: i64) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("004"),
        "test-agent",
        "minilm-v6",
    );
    f.feature_flags = feature_flags;
    f
}

/// Default frame produces no feature flags; bits 12–23 of the operational
/// bitmap are all zero.
#[test]
fn feature_flags_default_produces_zero_feature_bits() {
    let (estate, store) = make_estate_with_store();
    let frame = drawer_frame_with_flags("plain drawer", 0);
    let drawer = estate.capture(frame, NOW).unwrap();
    let loaded = store.get_drawer(&drawer.id).unwrap().unwrap();
    assert_eq!(
        loaded.operational_bitmap & DrawerFeatureFlags::FIELD_MASK,
        0
    );
    assert_eq!(loaded.feature_flags(), 0);
}

/// `HAS_LINKS | HAS_ATTACHMENTS` round-trips and sets the exact bits 12–23;
/// the encoded value is `0x9000`. Mirrors the Swift parity assertion.
#[test]
fn has_links_has_attachments_encodes_to_0x9000() {
    let (estate, store) = make_estate_with_store();
    let flags = DrawerFeatureFlags::HAS_LINKS | DrawerFeatureFlags::HAS_ATTACHMENTS;
    let frame = drawer_frame_with_flags("linked drawer", flags);
    let drawer = estate.capture(frame, NOW).unwrap();
    let loaded = store.get_drawer(&drawer.id).unwrap().unwrap();
    // hasLinks = 1<<15 = 0x8000, hasAttachments = 1<<12 = 0x1000 → 0x9000
    assert_eq!(
        loaded.operational_bitmap & DrawerFeatureFlags::FIELD_MASK,
        0x9000
    );
    assert!(loaded.has_feature_flag(DrawerFeatureFlags::HAS_LINKS));
    assert!(loaded.has_feature_flag(DrawerFeatureFlags::HAS_ATTACHMENTS));
    // No other feature flags set.
    assert!(!loaded.has_feature_flag(DrawerFeatureFlags::HAS_VOICE));
    assert!(!loaded.has_feature_flag(DrawerFeatureFlags::HAS_IMAGE));
    assert!(!loaded.has_feature_flag(DrawerFeatureFlags::IS_PINNED));
}

/// The channel/kind bits (0–11) are not disturbed by feature flags.
#[test]
fn feature_flags_do_not_disturb_channel_or_kind_bits() {
    let (estate, store) = make_estate_with_store();
    let mut frame = CaptureFrame::new(
        "test",
        CaptureChannel::Ocr, // raw 2 → bits 0–5
        "test-room",
        LatticeAnchor::udc("4"),
        "test-agent",
        "minilm-v6",
    );
    frame.kind = crate::drawer_operational::ContentKind::Code; // raw 1 → bits 6–11
    frame.feature_flags = DrawerFeatureFlags::HAS_LINKS;
    let drawer = estate.capture(frame, NOW).unwrap();
    let loaded = store.get_drawer(&drawer.id).unwrap().unwrap();
    assert_eq!(loaded.capture_channel(), CaptureChannel::Ocr);
    assert_eq!(
        loaded.content_kind(),
        crate::drawer_operational::ContentKind::Code
    );
    assert!(loaded.has_feature_flag(DrawerFeatureFlags::HAS_LINKS));
}

/// Swift/Rust parity: `HAS_LINKS | HAS_ATTACHMENTS` → feature-flag bits == `0x9000`.
#[test]
fn feature_flags_swift_rust_parity() {
    let (estate, _store) = make_estate_with_store();
    let flags = DrawerFeatureFlags::HAS_LINKS | DrawerFeatureFlags::HAS_ATTACHMENTS;
    let drawer = estate
        .capture(drawer_frame_with_flags("parity", flags), NOW)
        .unwrap();
    assert_eq!(
        drawer.operational_bitmap & DrawerFeatureFlags::FIELD_MASK,
        0x9000
    );
}
