//! Cookbook §2.4 + §2.8 verification-table conformance gate for the
//! Drawer operational bitmap constants LocusKit owns: CaptureChannel,
//! ContentKind, DrawerFeatureFlags, state-extension flag, and the
//! lineage-clustering flag (NEW in v0.6).
//!
//! Mirror of `Tests/LocusKitTests/OperationalBitmapConformanceTests.swift`.
//!
//! Cookbook §2.8: "Implementations MUST surface this table as an
//! automated conformance test that fails when a source constant
//! deviates from spec." When this test fails, the failure message
//! names the specific (constant, expected, actual) triple so the diff
//! against the cookbook is immediate.
//!
//! F12 cascade (2026-05-27): added after the v0.6 raw-value migration.
//!
//! Note: Tunnel/KGFact/Diary operational bitmaps are LocusKit-internal
//! layouts not specified by cookbook §2.4 v0.6 and are not gated here.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::{CaptureChannel, ContentKind, DrawerFeatureFlags};

/// Helper that matches the `sample()` pattern in `drawer_operational.rs` unit tests.
fn conformance_drawer(operational_bitmap: i64) -> Drawer {
    let mut d = Drawer::new("conf-d1", "content", "test-parent", "test", 1_700_000_000, "test-v1");
    d.operational_bitmap = operational_bitmap;
    d
}

// ============================================================
// CaptureChannel (cookbook §2.4 bits 0-5)
// ============================================================

const CAPTURE_CHANNEL_TABLE: &[(CaptureChannel, i64)] = &[
    (CaptureChannel::Typed, 0),
    (CaptureChannel::Voiced, 1),
    (CaptureChannel::Ocr, 2),
    (CaptureChannel::ImportedFile, 3),
    (CaptureChannel::Sensor, 4),
    (CaptureChannel::Actuator, 5), // NEW in v0.6
];

#[test]
fn capture_channel_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(channel, expected) in CAPTURE_CHANNEL_TABLE {
        if channel.raw_value() != expected {
            mismatches.push(format!(
                "CaptureChannel::{:?} expected raw={}, got {}",
                channel,
                expected,
                channel.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "CaptureChannel diverges from cookbook §2.4:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn capture_channel_field_position_bits_0_5() {
    // Round-trip every raw through encode-decode at the cookbook bit position.
    for &(channel, expected) in CAPTURE_CHANNEL_TABLE {
        let bitmap: i64 = expected; // bits 0-5
        let extracted = bitmap & 0x3F;
        assert_eq!(
            CaptureChannel::from_raw(extracted),
            channel,
            "bitmap={} should decode to {:?}",
            bitmap,
            channel
        );
    }
}

// ============================================================
// ContentKind (cookbook §2.4 bits 6-11)
// ============================================================

const CONTENT_KIND_TABLE: &[(ContentKind, i64)] = &[
    (ContentKind::Prose, 0),
    (ContentKind::Code, 1),
    (ContentKind::Transcript, 2),
    (ContentKind::List, 3),
    (ContentKind::StructuredJson, 4),
    (ContentKind::ImageCaption, 5),
    (ContentKind::FingerprintOnly, 6), // NEW in v0.6
    (ContentKind::Dataset, 7),         // NEW per MX-TAB-3
];

#[test]
fn content_kind_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(kind, expected) in CONTENT_KIND_TABLE {
        if kind.raw_value() != expected {
            mismatches.push(format!(
                "ContentKind::{:?} expected raw={}, got {}",
                kind,
                expected,
                kind.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "ContentKind diverges from cookbook §2.4:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn content_kind_field_position_bits_6_11() {
    for &(kind, expected) in CONTENT_KIND_TABLE {
        let bitmap: i64 = expected << 6;
        let extracted = (bitmap >> 6) & 0x3F;
        assert_eq!(
            ContentKind::from_raw(extracted),
            kind,
            "bitmap={} ({} << 6) should decode to {:?}",
            bitmap,
            expected,
            kind
        );
    }
}

// ============================================================
// DrawerFeatureFlags (cookbook §2.4 bits 12-23)
// ============================================================

const FEATURE_FLAG_TABLE: &[(i64, i32, &str)] = &[
    (DrawerFeatureFlags::HAS_ATTACHMENTS, 12, "HAS_ATTACHMENTS"),
    (DrawerFeatureFlags::HAS_VOICE, 13, "HAS_VOICE"),
    (DrawerFeatureFlags::HAS_IMAGE, 14, "HAS_IMAGE"),
    (DrawerFeatureFlags::HAS_LINKS, 15, "HAS_LINKS"),
    (DrawerFeatureFlags::IS_PINNED, 16, "IS_PINNED"),
    (DrawerFeatureFlags::IS_KEYSTONE, 17, "IS_KEYSTONE"), // NEW
    (DrawerFeatureFlags::IS_LOCKED_ZONE, 18, "IS_LOCKED_ZONE"), // NEW
];

#[test]
fn feature_flag_bit_positions_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(actual, expected_bit, name) in FEATURE_FLAG_TABLE {
        let expected: i64 = 1 << expected_bit;
        if actual != expected {
            mismatches.push(format!(
                "{} expected bit {} (={}), got {}",
                name, expected_bit, expected, actual
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "DrawerFeatureFlags diverges from cookbook §2.4:\n{}",
        mismatches.join("\n")
    );
    assert_eq!(
        DrawerFeatureFlags::FIELD_MASK,
        0xFFF000,
        "FIELD_MASK should cover bits 12-23"
    );
}

// ============================================================
// State-extension + lineage-clustering flags (cookbook §2.4 bits 24, 25)
// ============================================================

/// Mirrors Swift `stateExtensionAtBit24()`: bit 24 sets `state_extension_active`,
/// does NOT fire `lineage_clustering_active`. Cookbook §2.4 bit 24.
#[test]
fn state_extension_active_at_bit_24() {
    let d = conformance_drawer(1 << 24);
    assert!(
        d.state_extension_active(),
        "bit 24 must set state_extension_active"
    );
    assert!(
        !d.lineage_clustering_active(),
        "bit 24 must not trigger lineage_clustering_active"
    );
}

/// Mirrors Swift `lineageClusteringAtBit25()`: bit 25 sets `lineage_clustering_active`,
/// does NOT fire `state_extension_active`. Cookbook §2.4 bit 25 (NEW in v0.6).
#[test]
fn lineage_clustering_active_at_bit_25() {
    let d = conformance_drawer(1 << 25);
    assert!(
        d.lineage_clustering_active(),
        "bit 25 must set lineage_clustering_active"
    );
    assert!(
        !d.state_extension_active(),
        "bit 25 must not trigger state_extension_active"
    );
}

// ============================================================
// Full composite — all axes simultaneously
// ============================================================

/// captureChannel=Ocr(2) | contentKind=Code(1)<<6 | hasImage(1<<14) | isPinned(1<<16)
/// = 2 | 0x40 | 0x4000 | 0x10000 = 0x14042.
/// Mirrors Swift `compositeOperationalRoundtrip()`, including the bit-24/25 absence
/// assertions: a composite that sets neither bit must return false for both flags.
#[test]
fn composite_operational_roundtrip() {
    let raw: i64 = CaptureChannel::Ocr.raw_value()
        | (ContentKind::Code.raw_value() << 6)
        | DrawerFeatureFlags::HAS_IMAGE
        | DrawerFeatureFlags::IS_PINNED;
    assert_eq!(
        raw, 0x14042,
        "composite encoding mismatch: {} != 0x14042",
        raw
    );

    // Round-trip every axis.
    assert_eq!(CaptureChannel::from_raw(raw & 0x3F), CaptureChannel::Ocr);
    assert_eq!(ContentKind::from_raw((raw >> 6) & 0x3F), ContentKind::Code);
    assert_eq!(
        raw & DrawerFeatureFlags::HAS_IMAGE,
        DrawerFeatureFlags::HAS_IMAGE
    );
    assert_eq!(
        raw & DrawerFeatureFlags::IS_PINNED,
        DrawerFeatureFlags::IS_PINNED
    );

    // Bits 24 and 25 are not set in this composite — both flags must be false.
    // Mirrors Swift compositeOperationalRoundtrip's `!drawer.stateExtensionActive`
    // and `!drawer.lineageClusteringActive` assertions.
    let d = conformance_drawer(raw);
    assert!(
        !d.state_extension_active(),
        "composite without bit 24 must not report state_extension_active"
    );
    assert!(
        !d.lineage_clustering_active(),
        "composite without bit 25 must not report lineage_clustering_active"
    );
}
