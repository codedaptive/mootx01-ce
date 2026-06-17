//! `LearnedReference` noun struct + operational accessors. Ports
//! `LearnedReference.swift` and `LearnedReferenceOperational.swift`.
//!
//! The durable record of an external reference brought into the estate by
//! the grounding-driven `learn` verb (`learnedReference` is the only noun
//! that accepts `learn`). A *product* noun in the language taxonomy. This
//! module ships the value type, its operational accessors, the
//! `learned_references` table, and store persistence — the noun/persistence
//! layer. The `learn` verb that derives a `LearnedReference` and writes it
//! through this layer is implemented in `estate_verbs.rs` (`Estate::learn`).
//!
//! ## Field shape — source-grounded
//!
//! Follows the architecture spec § 7.8.2 `LearnedReference` shape
//! (`{rowID, source, handle, mode, three bitmaps}`), with two
//! reconciliations (documented in the Swift port and the completion
//! report):
//! - `source: SourceCatalogEntry` → `source_catalog_id: String`: the noun
//!   stores the catalog entry's stable identifier, not an embedded value.
//!   The `SourceCatalogEntry` type is implemented (`source_catalog_entry.rs`,
//!   mirroring `SourceCatalogEntry.swift`); each reference references it by id
//!   (like `KGFact.source_drawer_id`) and inherits the source's lattice anchor.
//! - `mode: LearnMode` lives in the operational bitmap (bit 12) per
//!   cookbook v1.0 § 2.4, not as a struct field — matching every other
//!   LocusKit noun's operational axes.
//!
//! ## Structure — mirrors `Association`
//!
//! Mirrors `Association`: id, content columns, a required `lattice_anchor`
//! (cookbook § 2.7 / I-16), three i64 bitmaps, `added_by` / `filed_at`, and
//! the Rev 1.0 soft-delete reservation. Derives `PartialEq, Eq` but **not**
//! `Hash` (the embedded `LatticeAnchor` is not `Hash`), matching Swift.
//!
//! Swift-to-Rust shape changes mirror `association.rs`: `Date filedAt` →
//! `i64 filed_at` (epoch seconds; the SQLite column is still TEXT ISO8601),
//! `Date? tombstonedAt` → `Option<i64> tombstoned_at`.

use crate::estate_types::LatticeAnchor;
// Bit-field extraction goes through the conformance-gated substrate-kernel
// primitive (the same one `association_operational.rs` uses); do not
// reimplement shift/mask math.
use substrate_kernel::bit_field;

// MARK: - Operational axes (cookbook §2.4, temporal-dominant)
//
//   bits 0–5    refresh_policy   (scale-gapped, raws 0/16/24/32/48/56)
//   bits 6–11   drift_severity   (scale-gapped, raws 0/16/32/48)
//   bit  12     mode             (1 bit, 0=byReference 1=byIngestion)
//   bits 13–18  source           (contiguous, raws 0…5)
//   bits 19–63  reserved

/// Refresh policy — cookbook §2.4 bits 0–5 (scale-gapped). Mirrors the
/// Swift `RefreshPolicy`. Unrecognised raws fall back to `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshPolicy {
    None,
    Monthly,
    Weekly,
    Daily,
    OnDemand,
    Realtime,
}

impl RefreshPolicy {
    pub fn from_raw(raw: i64) -> RefreshPolicy {
        match raw {
            0 => RefreshPolicy::None,
            16 => RefreshPolicy::Monthly,
            24 => RefreshPolicy::Weekly,
            32 => RefreshPolicy::Daily,
            48 => RefreshPolicy::OnDemand,
            56 => RefreshPolicy::Realtime,
            _ => RefreshPolicy::None,
        }
    }

    /// The scale-gapped raw value persisted in the operational bitmap
    /// (cookbook § 2.4 bits 0–5). Mirrors the Swift `RefreshPolicy` raw.
    pub fn raw_value(self) -> i64 {
        match self {
            RefreshPolicy::None => 0,
            RefreshPolicy::Monthly => 16,
            RefreshPolicy::Weekly => 24,
            RefreshPolicy::Daily => 32,
            RefreshPolicy::OnDemand => 48,
            RefreshPolicy::Realtime => 56,
        }
    }
}

/// Drift severity — cookbook §2.4 bits 6–11 (scale-gapped). Mirrors the
/// Swift `DriftSeverity`. Unrecognised raws fall back to `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriftSeverity {
    None,
    Minor,
    Major,
    Critical,
}

impl DriftSeverity {
    pub fn from_raw(raw: i64) -> DriftSeverity {
        match raw {
            0 => DriftSeverity::None,
            16 => DriftSeverity::Minor,
            32 => DriftSeverity::Major,
            48 => DriftSeverity::Critical,
            _ => DriftSeverity::None,
        }
    }
}

/// Learn mode — cookbook §2.4 bit 12 (single bit). Mirrors the Swift
/// `LearnMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LearnMode {
    ByReference,
    ByIngestion,
}

/// Acquisition source — cookbook §2.4 bits 13–18 (contiguous). Mirrors the
/// Swift `LearnedReferenceSource`. Unrecognised raws fall back to `User`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LearnedReferenceSource {
    User,
    Federation,
    HouseholdPairing,
    FleetPairing,
    TierInheritance,
    PairedEstate,
}

impl LearnedReferenceSource {
    pub fn from_raw(raw: i64) -> LearnedReferenceSource {
        match raw {
            0 => LearnedReferenceSource::User,
            1 => LearnedReferenceSource::Federation,
            2 => LearnedReferenceSource::HouseholdPairing,
            3 => LearnedReferenceSource::FleetPairing,
            4 => LearnedReferenceSource::TierInheritance,
            5 => LearnedReferenceSource::PairedEstate,
            _ => LearnedReferenceSource::User,
        }
    }
}

/// A learned-reference noun. Mirrors `LearnedReference.swift` field-for-field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LearnedReference {
    /// Stable identifier. Row identity is a UUID per cookbook I-29.
    pub id: String,

    /// Reference to the `SourceCatalogEntry` this reference was learned from
    /// (spec § 7.8.2 `source`). Stored as the catalog entry's identifier.
    pub source_catalog_id: String,

    /// The reference handle — the URI / locator string (spec `handle`).
    pub handle: String,

    /// Required lattice anchor (cookbook § 2.7 / I-16). `add_learned_reference`
    /// rejects an empty `udc_code`.
    pub lattice_anchor: LatticeAnchor,

    /// Cross-row adjective bitmap (cookbook § 2.3).
    pub adjective_bitmap: i64,

    /// Per-noun operational bitmap (cookbook § 2.4, LearnedReference layout).
    pub operational_bitmap: i64,

    /// Provenance bitmap (cookbook § 2.5).
    pub provenance_bitmap: i64,

    /// Name of the agent or process that filed this reference.
    pub added_by: String,

    /// When the reference was learned. Epoch seconds; the SQLite column is
    /// TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,

    /// When this reference was tombstoned, if it has been (Rev 2.0 reserve).
    pub tombstoned_at: Option<i64>,

    /// Batch identifier for receipt-based rollback of a tombstone.
    pub removed_by_batch: Option<String>,
}

impl LearnedReference {
    /// Construct a learned reference with all-zero bitmaps. Mirrors the
    /// Swift designated initializer's safe-baseline defaults; callers
    /// wanting non-default bitmaps or the optional tombstone fields populate
    /// the struct fields directly. The required arguments mirror the Swift
    /// initializer's non-default fields.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        source_catalog_id: String,
        handle: String,
        lattice_anchor: LatticeAnchor,
        added_by: String,
        filed_at: i64,
    ) -> Self {
        LearnedReference {
            id,
            source_catalog_id,
            handle,
            lattice_anchor,
            adjective_bitmap: 0,
            operational_bitmap: 0,
            provenance_bitmap: 0,
            added_by,
            filed_at,
            tombstoned_at: None,
            removed_by_batch: None,
        }
    }

    // Operational accessors — mirror the Swift computed properties.
    // Bit-field extraction goes through the conformance-gated
    // `substrate_kernel::bit_field` primitive; do not reimplement shift/mask math.

    /// Refresh policy (bits 0–5).
    pub fn refresh_policy(&self) -> RefreshPolicy {
        RefreshPolicy::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 6))
    }

    /// Drift severity (bits 6–11).
    pub fn drift_severity(&self) -> DriftSeverity {
        DriftSeverity::from_raw(bit_field::extract_field(self.operational_bitmap, 6, 6))
    }

    /// Learn mode (bit 12). A single-bit field decoded as a 1-bit slice.
    pub fn mode(&self) -> LearnMode {
        if bit_field::extract_field(self.operational_bitmap, 12, 1) != 0 {
            LearnMode::ByIngestion
        } else {
            LearnMode::ByReference
        }
    }

    /// Acquisition source (bits 13–18).
    pub fn acquisition_source(&self) -> LearnedReferenceSource {
        LearnedReferenceSource::from_raw(bit_field::extract_field(self.operational_bitmap, 13, 6))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::estate_types::LatticeAnchor;

    fn sample() -> LearnedReference {
        LearnedReference::new(
            "lr-1".to_string(),
            "catalog:docs".to_string(),
            "https://example.com/spec".to_string(),
            LatticeAnchor::udc("004"),
            "learner".to_string(),
            1_700_000_000,
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let r = sample();
        assert_eq!(r.adjective_bitmap, 0);
        assert_eq!(r.operational_bitmap, 0);
        assert_eq!(r.provenance_bitmap, 0);
        assert_eq!(r.tombstoned_at, None);
        assert_eq!(r.removed_by_batch, None);
    }

    #[test]
    fn lattice_anchor_round_trips() {
        let r = sample();
        assert_eq!(r.lattice_anchor.udc_code, "004");
    }

    #[test]
    fn equality_includes_every_field() {
        let a = sample();
        let mut b = sample();
        assert_eq!(a, b);
        b.handle = "https://example.com/other".to_string();
        assert_ne!(a, b);
    }

    // Operational bitmap conformance (cookbook §2.4) — mirrors the Swift
    // LearnedReferenceTests operational cases.

    fn with_op(op: i64) -> LearnedReference {
        let mut r = sample();
        r.operational_bitmap = op;
        r
    }

    #[test]
    fn refresh_policy_decodes_scale_gapped() {
        assert_eq!(with_op(0).refresh_policy(), RefreshPolicy::None);
        assert_eq!(with_op(16).refresh_policy(), RefreshPolicy::Monthly);
        assert_eq!(with_op(24).refresh_policy(), RefreshPolicy::Weekly);
        assert_eq!(with_op(32).refresh_policy(), RefreshPolicy::Daily);
        assert_eq!(with_op(48).refresh_policy(), RefreshPolicy::OnDemand);
        assert_eq!(with_op(56).refresh_policy(), RefreshPolicy::Realtime);
        // scale-gap sentinel falls back to None
        assert_eq!(with_op(8).refresh_policy(), RefreshPolicy::None);
    }

    #[test]
    fn drift_severity_decodes_scale_gapped() {
        assert_eq!(with_op(0 << 6).drift_severity(), DriftSeverity::None);
        assert_eq!(with_op(16 << 6).drift_severity(), DriftSeverity::Minor);
        assert_eq!(with_op(32 << 6).drift_severity(), DriftSeverity::Major);
        assert_eq!(with_op(48 << 6).drift_severity(), DriftSeverity::Critical);
        assert_eq!(with_op(8 << 6).drift_severity(), DriftSeverity::None);
    }

    #[test]
    fn mode_decodes_bit_twelve() {
        assert_eq!(with_op(0).mode(), LearnMode::ByReference);
        assert_eq!(with_op(1 << 12).mode(), LearnMode::ByIngestion);
    }

    #[test]
    fn source_decodes_contiguous() {
        assert_eq!(
            with_op(0 << 13).acquisition_source(),
            LearnedReferenceSource::User
        );
        assert_eq!(
            with_op(1 << 13).acquisition_source(),
            LearnedReferenceSource::Federation
        );
        assert_eq!(
            with_op(2 << 13).acquisition_source(),
            LearnedReferenceSource::HouseholdPairing
        );
        assert_eq!(
            with_op(3 << 13).acquisition_source(),
            LearnedReferenceSource::FleetPairing
        );
        assert_eq!(
            with_op(4 << 13).acquisition_source(),
            LearnedReferenceSource::TierInheritance
        );
        assert_eq!(
            with_op(5 << 13).acquisition_source(),
            LearnedReferenceSource::PairedEstate
        );
        // reserved raw falls back to User
        assert_eq!(
            with_op(6 << 13).acquisition_source(),
            LearnedReferenceSource::User
        );
    }

    #[test]
    fn composite_operational_decodes_all_axes_independently() {
        // refresh=weekly(24) | drift=major(32<<6) | mode=byIngestion(1<<12)
        // | source=federation(1<<13)
        let op = 24_i64 | (32_i64 << 6) | (1_i64 << 12) | (1_i64 << 13);
        let r = with_op(op);
        assert_eq!(r.refresh_policy(), RefreshPolicy::Weekly);
        assert_eq!(r.drift_severity(), DriftSeverity::Major);
        assert_eq!(r.mode(), LearnMode::ByIngestion);
        assert_eq!(r.acquisition_source(), LearnedReferenceSource::Federation);
    }
}
