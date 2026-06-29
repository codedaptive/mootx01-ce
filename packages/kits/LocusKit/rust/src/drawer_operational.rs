//! Operational bitmap value types and adjective bitmap accessors for the
//! `Drawer` entity. Ports `DrawerOperational.swift` (operational axis) and
//! the `Adjectives.swift` `Drawer` extension (adjective axis).
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
// docs/engineering/HARNESS_REFERENCE.md. If you
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

    /// Decode bits 18–23 of `adjective_bitmap` as a `Trust`. Returns
    /// `Verbatim` for unrecognised raw values; verbatim is the neutral
    /// baseline (unqualified content as filed). Cookbook §2.3 6-bit field.
    /// The parity of the Swift `Drawer.trust` computed property in
    /// `Adjectives.swift`; lives here alongside `adjective_sensitivity()`,
    /// the other adjective-bitmap accessor.
    pub fn trust(&self) -> crate::adjectives::Trust {
        // Cookbook §2.3: trust at bits 18-23 of adjective_bitmap.
        crate::adjectives::Trust::from_raw(bit_field::extract_field(self.adjective_bitmap, 18, 6))
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

    // -------------------------------------------------------------------------
    // Adjective-bitmap axis accessors — mirrors the `Drawer` extension in
    // `Adjectives.swift`. `adjective_sensitivity()` and `trust()` are above
    // in this file; the remaining axes follow.
    // -------------------------------------------------------------------------

    /// Decode bits 0–5 of `adjective_bitmap` as a `State`. Returns `Active`
    /// for unrecognised raw values so retrieval filters that look for current
    /// beliefs fail closed (an unknown row surfaces for review rather than
    /// silently disappearing). Cookbook §2.3 6-bit field.
    ///
    /// Mirrors Swift `Drawer.state`.
    pub fn state(&self) -> crate::adjectives::State {
        // Cookbook §2.3: state at bits 0–5 of adjective_bitmap.
        crate::adjectives::State::from_raw(bit_field::extract_field(self.adjective_bitmap, 0, 6))
    }

    /// Decode bits 12–17 of `adjective_bitmap` as an `AdjectiveExportability`.
    /// Returns `Private` for unrecognised raw values — non-exportable is the
    /// safe fallback for an unknown encoding. Cookbook §2.3 6-bit field.
    ///
    /// Mirrors Swift `Drawer.exportability`.
    pub fn exportability(&self) -> crate::adjectives::AdjectiveExportability {
        // Cookbook §2.3: exportability at bits 12–17 of adjective_bitmap.
        crate::adjectives::AdjectiveExportability::from_raw(bit_field::extract_field(
            self.adjective_bitmap,
            12,
            6,
        ))
    }

    /// True when the row sits in Cluster A (active / becoming) per cookbook
    /// §2.3 — `Active`, `Pending`, `Contested`, or `Accepted`. F11 cascade
    /// (2026-05-27): `Accepted` moved here from the v0.35 terminal cluster.
    /// Cookbook semantics: accepted is the audit-grade endpoint of
    /// becoming-true belief.
    ///
    /// Mathematically equivalent to `(state.raw_value() >> 4) & 0x3 == 0`.
    ///
    /// Mirrors Swift `Drawer.isCurrentlyBelieved`.
    pub fn is_currently_believed(&self) -> bool {
        self.state().is_cluster_a()
    }

    /// True when the row sits in Cluster B (superseded / historical) per
    /// cookbook §2.3 — `Superseded`, `Decayed`, `Withdrawn`, or `Expired`.
    ///
    /// Mathematically equivalent to `(state.raw_value() >> 4) & 0x3 == 1`.
    ///
    /// Mirrors Swift `Drawer.isKnewPast`.
    pub fn is_knew_past(&self) -> bool {
        matches!(
            self.state(),
            crate::adjectives::State::Superseded
                | crate::adjectives::State::Decayed
                | crate::adjectives::State::Withdrawn
                | crate::adjectives::State::Expired
        )
    }

    /// True when the row sits in Cluster C (terminal) per cookbook §2.3 —
    /// `Rejected` or `Tombstoned`. F11 cascade (2026-05-27): `Accepted`
    /// moved OUT of this cluster (now in `is_currently_believed`). Cluster C
    /// is "externally rejected / removed," not merely "no further transitions."
    ///
    /// Mathematically equivalent to `(state.raw_value() >> 4) & 0x3 == 2`.
    ///
    /// Mirrors Swift `Drawer.isTerminal`.
    pub fn is_terminal(&self) -> bool {
        matches!(
            self.state(),
            crate::adjectives::State::Rejected | crate::adjectives::State::Tombstoned
        )
    }

    // dreaming_recalc_required() and sealed() are defined in `drawer.rs`
    // alongside the adjective-bitmap layout comment where they were first
    // introduced (F17 cascade / custody cascade). They are part of the
    // adjective axis but pre-date this file's existence as a home for
    // operational-bitmap code. They live in drawer.rs to avoid a duplicate
    // definition across two `impl Drawer` blocks in the same crate.
    // See `Drawer::dreaming_recalc_required()` and `Drawer::sealed()`.
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Drawer {
        Drawer::new("d1", "hello", "test-parent", "alice", 1_700_000_000, "test-v1")
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
    // The accessor reads a 6-bit field from bits 0-5, not a low nibble.
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

    #[test]
    fn trust_accessor_reads_bits_18_23() {
        use crate::adjectives::Trust;
        let mut d = sample();
        // Default is the neutral baseline.
        assert_eq!(d.trust(), Trust::Verbatim);
        // Canonical (raw 3) at bits 18-23.
        d.adjective_bitmap = Trust::Canonical.raw_value() << 18;
        assert_eq!(d.trust(), Trust::Canonical);
        // Lower-field bits (sensitivity at 6-11) don't leak into trust.
        d.adjective_bitmap |= crate::adjectives::AdjectiveSensitivity::Secret.raw_value() << 6;
        assert_eq!(d.trust(), Trust::Canonical);
        // Ambient (raw 6) — the highest used case.
        d.adjective_bitmap = Trust::Ambient.raw_value() << 18;
        assert_eq!(d.trust(), Trust::Ambient);
    }

    // -------------------------------------------------------------------------
    // Adjective-bitmap axis accessor tests (Item C parity)
    // Mirrors Swift's Adjectives.swift Drawer extension tests.
    // -------------------------------------------------------------------------

    #[test]
    fn state_accessor_reads_bits_0_5() {
        use crate::adjectives::State;
        let mut d = sample();
        // Default bitmap → Active (raw 0).
        assert_eq!(d.state(), State::Active);
        // Tombstoned (raw 33) at bits 0–5.
        d.adjective_bitmap = State::Tombstoned.raw_value();
        assert_eq!(d.state(), State::Tombstoned);
        // Pending (raw 1).
        d.adjective_bitmap = State::Pending.raw_value();
        assert_eq!(d.state(), State::Pending);
        // Upper fields (sensitivity at 6–11) must not bleed into state read.
        d.adjective_bitmap = State::Accepted.raw_value()
            | (crate::adjectives::AdjectiveSensitivity::Secret.raw_value() << 6);
        assert_eq!(d.state(), State::Accepted);
    }

    #[test]
    fn state_accessor_unknown_raw_falls_back_to_active() {
        // A reserved raw value (e.g., 4) in bits 0–5 must fall back to Active.
        let mut d = sample();
        d.adjective_bitmap = 4i64; // raw 4 is reserved per cookbook §2.3
        assert_eq!(d.state(), crate::adjectives::State::Active);
    }

    #[test]
    fn exportability_accessor_reads_bits_12_17() {
        use crate::adjectives::AdjectiveExportability;
        let mut d = sample();
        // Default → Private (raw 0).
        assert_eq!(d.exportability(), AdjectiveExportability::Private);
        // Public (raw 32) at bits 12–17.
        d.adjective_bitmap = AdjectiveExportability::Public.raw_value() << 12;
        assert_eq!(d.exportability(), AdjectiveExportability::Public);
        // Sensitivity at bits 6–11 must not bleed into exportability read.
        d.adjective_bitmap = (AdjectiveExportability::Public.raw_value() << 12)
            | (crate::adjectives::AdjectiveSensitivity::Restricted.raw_value() << 6);
        assert_eq!(d.exportability(), AdjectiveExportability::Public);
    }

    #[test]
    fn exportability_accessor_unknown_raw_falls_back_to_private() {
        // A raw value of 1 at bits 12–17 is reserved; must fall back to Private.
        let mut d = sample();
        d.adjective_bitmap = 1i64 << 12; // raw 1 is not a legal exportability value
        assert_eq!(
            d.exportability(),
            crate::adjectives::AdjectiveExportability::Private
        );
    }

    #[test]
    fn is_currently_believed_cluster_a_states() {
        use crate::adjectives::State;
        // All four Cluster A states must return true.
        for s in [State::Active, State::Pending, State::Contested, State::Accepted] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(
                d.is_currently_believed(),
                "{s:?} must be in Cluster A (isCurrentlyBelieved)"
            );
        }
    }

    #[test]
    fn is_currently_believed_false_for_cluster_b_and_c() {
        use crate::adjectives::State;
        // Cluster B and C states must return false.
        for s in [
            State::Superseded,
            State::Decayed,
            State::Withdrawn,
            State::Expired,
            State::Rejected,
            State::Tombstoned,
        ] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(
                !d.is_currently_believed(),
                "{s:?} must NOT be in Cluster A"
            );
        }
    }

    #[test]
    fn is_knew_past_cluster_b_states() {
        use crate::adjectives::State;
        // All four Cluster B states must return true.
        for s in [
            State::Superseded,
            State::Decayed,
            State::Withdrawn,
            State::Expired,
        ] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(d.is_knew_past(), "{s:?} must be in Cluster B (isKnewPast)");
        }
    }

    #[test]
    fn is_knew_past_false_for_cluster_a_and_c() {
        use crate::adjectives::State;
        for s in [
            State::Active,
            State::Pending,
            State::Contested,
            State::Accepted,
            State::Rejected,
            State::Tombstoned,
        ] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(!d.is_knew_past(), "{s:?} must NOT be in Cluster B");
        }
    }

    #[test]
    fn is_terminal_cluster_c_states() {
        use crate::adjectives::State;
        // Both Cluster C states must return true.
        for s in [State::Rejected, State::Tombstoned] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(d.is_terminal(), "{s:?} must be in Cluster C (isTerminal)");
        }
    }

    #[test]
    fn is_terminal_false_for_cluster_a_and_b() {
        use crate::adjectives::State;
        for s in [
            State::Active,
            State::Pending,
            State::Contested,
            State::Accepted,
            State::Superseded,
            State::Decayed,
            State::Withdrawn,
            State::Expired,
        ] {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            assert!(!d.is_terminal(), "{s:?} must NOT be in Cluster C");
        }
    }

    /// The three cluster predicates are mutually exclusive and collectively
    /// exhaustive for every defined State value. Mirrors the Swift exhaustiveness
    /// check pattern used across the adjective test suite.
    #[test]
    fn cluster_predicates_mutually_exclusive_exhaustive() {
        use crate::adjectives::State;
        let all_states = [
            State::Active,
            State::Pending,
            State::Contested,
            State::Accepted,
            State::Superseded,
            State::Decayed,
            State::Withdrawn,
            State::Expired,
            State::Rejected,
            State::Tombstoned,
        ];
        for s in all_states {
            let mut d = sample();
            d.adjective_bitmap = s.raw_value();
            let true_count = [
                d.is_currently_believed(),
                d.is_knew_past(),
                d.is_terminal(),
            ]
            .iter()
            .filter(|&&b| b)
            .count();
            assert_eq!(
                true_count, 1,
                "{s:?}: expected exactly 1 cluster predicate true, got {true_count}"
            );
        }
    }

    #[test]
    fn dreaming_recalc_required_is_adjective_bit_26() {
        let mut d = sample();
        // Default — no recalc owed.
        assert!(!d.dreaming_recalc_required());
        // Set bit 26 in adjective_bitmap.
        d.adjective_bitmap = 1i64 << 26;
        assert!(d.dreaming_recalc_required());
        // Adjacent bit must not trigger.
        d.adjective_bitmap = 1i64 << 25;
        assert!(!d.dreaming_recalc_required());
        d.adjective_bitmap = 1i64 << 27;
        assert!(!d.dreaming_recalc_required());
    }

    #[test]
    fn sealed_is_adjective_bit_27() {
        let mut d = sample();
        // Default — unsealed.
        assert!(!d.sealed());
        // Set bit 27 in adjective_bitmap.
        d.adjective_bitmap = 1i64 << 27;
        assert!(d.sealed());
        // Adjacent bit must not trigger.
        d.adjective_bitmap = 1i64 << 26;
        assert!(!d.sealed());
        d.adjective_bitmap = 1i64 << 28;
        assert!(!d.sealed());
    }

    #[test]
    fn adjective_bits_independent_across_fields() {
        // Verify that state, sensitivity, exportability, trust, dreaming_recalc,
        // and sealed all decode from independent bit ranges with no cross-field
        // leakage. Compose a bitmap with all axes at non-zero values and check
        // each accessor independently.
        use crate::adjectives::{
            AdjectiveExportability, AdjectiveSensitivity, State, Trust,
        };
        let mut d = sample();
        // State = Tombstoned (raw 33 at bits 0–5)
        // Sensitivity = Secret (raw 48 at bits 6–11)
        // Exportability = Public (raw 32 at bits 12–17)
        // Trust = Canonical (raw 3 at bits 18–23)
        // dreaming_recalc_required = true (bit 26)
        // sealed = true (bit 27)
        d.adjective_bitmap = State::Tombstoned.raw_value()
            | (AdjectiveSensitivity::Secret.raw_value() << 6)
            | (AdjectiveExportability::Public.raw_value() << 12)
            | (Trust::Canonical.raw_value() << 18)
            | (1i64 << 26)
            | (1i64 << 27);
        assert_eq!(d.state(), State::Tombstoned);
        assert_eq!(d.adjective_sensitivity(), AdjectiveSensitivity::Secret);
        assert_eq!(d.exportability(), AdjectiveExportability::Public);
        assert_eq!(d.trust(), Trust::Canonical);
        assert!(d.dreaming_recalc_required());
        assert!(d.sealed());
        // Cluster predicates must reflect the composed state (Tombstoned → terminal).
        assert!(d.is_terminal());
        assert!(!d.is_currently_believed());
        assert!(!d.is_knew_past());
    }
}
