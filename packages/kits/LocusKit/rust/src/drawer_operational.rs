//! Operational bitmap value types. Ports `DrawerOperational.swift`.
//!
//! Per cookbook §2.4 (Drawer operational layout, v0.6 6-bit floor) and
//! §2.8 (verification table).
//!
//! F12 cascade (2026-05-27): bumped from v0.35's 4-bit fields to
//! cookbook v0.6's 6-bit fields per I-15. NEW raws:
//! `CaptureChannel::Actuator` (raw 5), `ContentKind::FingerprintOnly`
//! (raw 6 for AmbientSample per cookbook §2.5). NEW feature flags:
//! `IS_KEYSTONE` (bit 17 per §7.2), `IS_LOCKED_ZONE` (bit 18). NEW
//! lineage-clustering flag at bit 25.
//!
//! ## Drawer operational layout (cookbook §2.4 v0.6)
//!
//! ```text
//! bits 0–5    capture_channel        (contiguous, 6 cases at raw 0..5)
//! bits 6–11   content_kind           (contiguous, 7 cases at raw 0..6)
//! bits 12–23  feature_flags          (bitset, 7 named bits 12..18)
//! bit  24     state_extension flag
//! bit  25     lineage_clustering flag (NEW in v0.6)
//! bits 26–63  reserved
//! ```
//!
//! ## Swift-to-Rust shape change
//!
//! Swift defines `DrawerFeatureFlags` as an `OptionSet` struct (a typed
//! bitset with `.contains` membership testing). The Rust port exposes
//! the same wire layout as a set of `pub const` i64 constants in the
//! `DrawerFeatureFlags` namespace plus a `has_feature_flag` accessor on
//! `Drawer`. Same bit positions, same semantics; idiomatic Rust shape.

use crate::drawer::Drawer;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;

// MARK: - CaptureChannel

/// Capture channel — how the drawer's content entered the system.
/// Lives in bits 0–5 of `Drawer::operational_bitmap` (6 bits, 64 values;
/// 6 used, 58 reserved). Per cookbook §2.4.
///
/// F12 cascade (2026-05-27): added `Actuator = 5` per cookbook v0.6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum CaptureChannel {
    Typed = 0,
    Voiced = 1,
    Ocr = 2,
    ImportedFile = 3,
    Sensor = 4,
    Actuator = 5, // NEW in v0.6 per cookbook §2.4
                  // Raw values 6–63 are reserved for future capture channels.
}

impl CaptureChannel {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Typed` for unrecognised raw
    /// values — typed input is the neutral default channel for content
    /// of unknown origin. Matches the Swift fallback.
    pub fn from_raw(v: i64) -> CaptureChannel {
        match v {
            0 => CaptureChannel::Typed,
            1 => CaptureChannel::Voiced,
            2 => CaptureChannel::Ocr,
            3 => CaptureChannel::ImportedFile,
            4 => CaptureChannel::Sensor,
            5 => CaptureChannel::Actuator,
            _ => CaptureChannel::Typed,
        }
    }
}

// MARK: - ContentKind

/// Content kind — the shape of the drawer's content. Lives in bits 6–11
/// of `Drawer::operational_bitmap` (6 bits, 64 values; 7 used, 57
/// reserved). Per cookbook §2.4.
///
/// F12 cascade (2026-05-27): added `FingerprintOnly = 6` per cookbook
/// v0.6 (the AmbientSample noun type uses fingerprint-only rows;
/// see §2.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum ContentKind {
    Prose = 0,
    Code = 1,
    Transcript = 2,
    List = 3,
    StructuredJson = 4,
    ImageCaption = 5,
    FingerprintOnly = 6, // NEW in v0.6 per cookbook §2.4 / §2.5
                         // Raw values 7–63 are reserved for future kinds.
}

impl ContentKind {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Prose` for unrecognised raw
    /// values — prose is the neutral default kind for unstructured
    /// text. Matches the Swift fallback.
    pub fn from_raw(v: i64) -> ContentKind {
        match v {
            0 => ContentKind::Prose,
            1 => ContentKind::Code,
            2 => ContentKind::Transcript,
            3 => ContentKind::List,
            4 => ContentKind::StructuredJson,
            5 => ContentKind::ImageCaption,
            6 => ContentKind::FingerprintOnly,
            _ => ContentKind::Prose,
        }
    }
}

// MARK: - DrawerFeatureFlags

/// Feature-flag bitset constants. Lives in bits 12–23 of
/// `Drawer::operational_bitmap` (12-bit bitset; 7 named bits 12..18,
/// bits 19..23 reserved). Per cookbook §2.4.
///
/// F12 cascade (2026-05-27): shifted from v0.35 bits 8–15 to v0.6
/// bits 12–23. NEW flags: `IS_KEYSTONE` (bit 17, cookbook §7.2),
/// `IS_LOCKED_ZONE` (bit 18).
///
/// Bit positions match `DrawerFeatureFlags` OptionSet members in
/// `DrawerOperational.swift`. The Swift OptionSet's `rawValue` and
/// these Rust constants are the same i64 wire value, so cross-leg
/// equality holds.
pub struct DrawerFeatureFlags;

impl DrawerFeatureFlags {
    /// Bit 12 — drawer has one or more file attachments alongside its
    /// `content` field. Attachment storage itself is out of scope for
    /// this rev.
    pub const HAS_ATTACHMENTS: i64 = 1 << 12;

    /// Bit 13 — drawer was captured with or carries voice audio.
    pub const HAS_VOICE: i64 = 1 << 13;

    /// Bit 14 — drawer was captured from or carries an image.
    pub const HAS_IMAGE: i64 = 1 << 14;

    /// Bit 15 — drawer's content contains links (URLs, citations).
    pub const HAS_LINKS: i64 = 1 << 15;

    /// Bit 16 — user-pinned drawer; retrieval surfaces this with
    /// elevated priority regardless of recency.
    pub const IS_PINNED: i64 = 1 << 16;

    /// Bit 17 — keystone drawer per cookbook §7.2 (NEW in v0.6).
    /// Keystones anchor a lineage/cluster.
    pub const IS_KEYSTONE: i64 = 1 << 17;

    /// Bit 18 — locked-zone drawer (NEW in v0.6 per cookbook §2.4).
    /// Privacy-aware bucket; recall gated by zone-policy check.
    pub const IS_LOCKED_ZONE: i64 = 1 << 18;

    /// Mask covering the 12-bit feature region (bits 12–23). Matches
    /// the Swift `featureFlags` accessor's `0xFFF000` mask.
    pub const FIELD_MASK: i64 = 0xFFF000;
}

// MARK: - Drawer accessors

impl Drawer {
    /// Decode bits 0–5 of `operational_bitmap` as a `CaptureChannel`.
    /// Returns `Typed` for unrecognised raw values. Cookbook §2.4 6-bit field.
    pub fn capture_channel(&self) -> CaptureChannel {
        // Cookbook §2.4: capture_channel at bits 0-5.
        CaptureChannel::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 6))
    }

    /// Decode bits 6–11 of `operational_bitmap` as a `ContentKind`.
    /// Returns `Prose` for unrecognised raw values. Cookbook §2.4 6-bit field.
    pub fn content_kind(&self) -> ContentKind {
        // Cookbook §2.4: content_kind at bits 6-11.
        ContentKind::from_raw(bit_field::extract_field(self.operational_bitmap, 6, 6))
    }

    /// Decode bits 6–11 of `adjective_bitmap` as an `AdjectiveSensitivity`.
    /// Returns `Normal` for unrecognised raw values. Cookbook §2.3 6-bit
    /// field. The parity of the Swift `Drawer.adjectiveSensitivity` computed
    /// property; named `adjective_sensitivity` (not `sensitivity`) to avoid
    /// colliding with the provenance-bitmap `sensitivity()` accessor.
    pub fn adjective_sensitivity(&self) -> crate::adjectives::AdjectiveSensitivity {
        // Cookbook §2.3: adjective sensitivity at bits 6-11 of adjective_bitmap.
        crate::adjectives::AdjectiveSensitivity::from_raw(bit_field::extract_field(
            self.adjective_bitmap,
            6,
            6,
        ))
    }

    /// The feature-flag region of `operational_bitmap` masked to bits
    /// 12–23. Bit positions inside the masked value match the
    /// `DrawerFeatureFlags` constants exactly. Cookbook §2.4.
    pub fn feature_flags(&self) -> i64 {
        self.operational_bitmap & DrawerFeatureFlags::FIELD_MASK
    }

    /// True when `flag` is present in the operational bitmap. Pass any
    /// of the `DrawerFeatureFlags::HAS_*` / `IS_PINNED` / `IS_KEYSTONE`
    /// / `IS_LOCKED_ZONE` constants (or a bitwise-OR composition).
    /// Mirrors the Swift `hasFeatureFlag(_:)`.
    pub fn has_feature_flag(&self, flag: i64) -> bool {
        (self.operational_bitmap & flag) == flag
    }

    /// True when bit 24 of `operational_bitmap` is set, indicating the
    /// adjective state field has overflowed its 6-bit allotment per
    /// cookbook §2.9 (state-extension growth budget).
    pub fn state_extension_active(&self) -> bool {
        // Cookbook §2.4 bit 24: state_extension flag.
        bit_field::extract_flag(self.operational_bitmap, 24)
    }

    /// True when bit 25 of `operational_bitmap` is set, indicating the
    /// drawer belongs to a lineage cluster per cookbook §2.4 (NEW in v0.6).
    pub fn lineage_clustering_active(&self) -> bool {
        // Cookbook §2.4 bit 25: lineage_clustering flag.
        bit_field::extract_flag(self.operational_bitmap, 25)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Drawer {
        Drawer::new("d1", "hello", "w", "r", "alice", 1_700_000_000, "test-v1")
    }

    #[test]
    fn capture_channel_raw_values() {
        assert_eq!(CaptureChannel::Typed.raw_value(), 0);
        assert_eq!(CaptureChannel::Voiced.raw_value(), 1);
        assert_eq!(CaptureChannel::Ocr.raw_value(), 2);
        assert_eq!(CaptureChannel::ImportedFile.raw_value(), 3);
        assert_eq!(CaptureChannel::Sensor.raw_value(), 4);
        assert_eq!(CaptureChannel::Actuator.raw_value(), 5); // NEW in v0.6
    }

    #[test]
    fn capture_channel_roundtrip_6_cases() {
        for v in 0i64..=5 {
            assert_eq!(CaptureChannel::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn capture_channel_reserved_falls_back_to_typed() {
        // Raws 6–63 are reserved per cookbook §2.4.
        assert_eq!(CaptureChannel::from_raw(6), CaptureChannel::Typed);
        assert_eq!(CaptureChannel::from_raw(63), CaptureChannel::Typed);
        assert_eq!(CaptureChannel::from_raw(-1), CaptureChannel::Typed);
    }

    #[test]
    fn content_kind_raw_values() {
        assert_eq!(ContentKind::Prose.raw_value(), 0);
        assert_eq!(ContentKind::Code.raw_value(), 1);
        assert_eq!(ContentKind::Transcript.raw_value(), 2);
        assert_eq!(ContentKind::List.raw_value(), 3);
        assert_eq!(ContentKind::StructuredJson.raw_value(), 4);
        assert_eq!(ContentKind::ImageCaption.raw_value(), 5);
        assert_eq!(ContentKind::FingerprintOnly.raw_value(), 6); // NEW in v0.6
    }

    #[test]
    fn content_kind_roundtrip_7_cases() {
        for v in 0i64..=6 {
            assert_eq!(ContentKind::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn content_kind_reserved_falls_back_to_prose() {
        // Raws 7–63 are reserved per cookbook §2.4.
        assert_eq!(ContentKind::from_raw(7), ContentKind::Prose);
        assert_eq!(ContentKind::from_raw(63), ContentKind::Prose);
    }

    #[test]
    fn feature_flag_constants_match_bit_positions() {
        // Cookbook §2.4: feature_flags at bits 12-23.
        assert_eq!(DrawerFeatureFlags::HAS_ATTACHMENTS, 1 << 12);
        assert_eq!(DrawerFeatureFlags::HAS_VOICE, 1 << 13);
        assert_eq!(DrawerFeatureFlags::HAS_IMAGE, 1 << 14);
        assert_eq!(DrawerFeatureFlags::HAS_LINKS, 1 << 15);
        assert_eq!(DrawerFeatureFlags::IS_PINNED, 1 << 16);
        assert_eq!(DrawerFeatureFlags::IS_KEYSTONE, 1 << 17); // NEW
        assert_eq!(DrawerFeatureFlags::IS_LOCKED_ZONE, 1 << 18); // NEW
        assert_eq!(DrawerFeatureFlags::FIELD_MASK, 0xFFF000);
    }

    #[test]
    fn capture_channel_accessor_reads_low_nibble() {
        let mut d = sample();
        d.operational_bitmap = CaptureChannel::Ocr.raw_value();
        assert_eq!(d.capture_channel(), CaptureChannel::Ocr);
        // High bits don't leak in.
        d.operational_bitmap |= 1 << 30;
        assert_eq!(d.capture_channel(), CaptureChannel::Ocr);
    }

    #[test]
    fn content_kind_accessor_reads_bits_6_11() {
        let mut d = sample();
        d.operational_bitmap = ContentKind::Transcript.raw_value() << 6;
        assert_eq!(d.content_kind(), ContentKind::Transcript);
    }

    #[test]
    fn feature_flags_returns_masked_region() {
        let mut d = sample();
        d.operational_bitmap = DrawerFeatureFlags::HAS_VOICE | DrawerFeatureFlags::IS_PINNED;
        let flags = d.feature_flags();
        assert_eq!(
            flags & DrawerFeatureFlags::HAS_VOICE,
            DrawerFeatureFlags::HAS_VOICE
        );
        assert_eq!(
            flags & DrawerFeatureFlags::IS_PINNED,
            DrawerFeatureFlags::IS_PINNED
        );
        // Other regions are masked out.
        d.operational_bitmap = (1 << 30) | DrawerFeatureFlags::HAS_VOICE;
        assert_eq!(d.feature_flags(), DrawerFeatureFlags::HAS_VOICE);
    }

    #[test]
    fn has_feature_flag_single_bit() {
        let mut d = sample();
        d.operational_bitmap = DrawerFeatureFlags::HAS_IMAGE;
        assert!(d.has_feature_flag(DrawerFeatureFlags::HAS_IMAGE));
        assert!(!d.has_feature_flag(DrawerFeatureFlags::HAS_VOICE));
    }

    #[test]
    fn has_feature_flag_composed() {
        // Composed mask: caller asks "all of HAS_VOICE AND HAS_IMAGE set?"
        let mut d = sample();
        d.operational_bitmap = DrawerFeatureFlags::HAS_VOICE | DrawerFeatureFlags::HAS_IMAGE;
        let composed = DrawerFeatureFlags::HAS_VOICE | DrawerFeatureFlags::HAS_IMAGE;
        assert!(d.has_feature_flag(composed));

        d.operational_bitmap = DrawerFeatureFlags::HAS_VOICE; // missing HAS_IMAGE
        assert!(!d.has_feature_flag(composed));
    }

    #[test]
    fn state_extension_flag_is_bit_24() {
        let mut d = sample();
        assert!(!d.state_extension_active());
        d.operational_bitmap = 1 << 24;
        assert!(d.state_extension_active());
        // Other bits don't trigger.
        d.operational_bitmap = 1 << 23;
        assert!(!d.state_extension_active());
    }

    #[test]
    fn lineage_clustering_flag_is_bit_25() {
        let mut d = sample();
        assert!(!d.lineage_clustering_active());
        d.operational_bitmap = 1 << 25;
        assert!(d.lineage_clustering_active());
        // Other bits don't trigger.
        d.operational_bitmap = 1 << 24;
        assert!(!d.lineage_clustering_active());
    }
}
