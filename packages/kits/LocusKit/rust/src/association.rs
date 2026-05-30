//! Association noun struct. Ports `Association.swift`.
//!
//! A graph-edge noun linking two locations in the MemPalace surface. The
//! edge-shaped noun behind the `association` lexicon entry (association
//! accepts mutate, expunge, recall; it accepts no capture and no
//! withdraw). An association records that two rows belong together — a
//! statistical or dreaming-derived pairing — rather than a typed semantic
//! claim. The dreaming pass creates or strengthens associations from
//! accumulated signals per cookbook §10.10. Associations are on the
//! *graph* side of the content-vs-graph distinction (cookbook §9.5.1).
//!
//! This mission ships only the value type, its operational accessors, the
//! `associations` table, and store persistence. No verb behaviour
//! (mutate / expunge / recall) is implemented here.
//!
//! `Association` mirrors `Tunnel` structurally — both are directional
//! edges carrying source + target endpoints (wing + room + optional
//! drawer id), three i64 bitmap columns, and the Rev 1.0 soft-delete
//! reservation (`tombstoned_at` / `removed_by_batch`) — with two
//! deliberate differences:
//!
//! - **No `kind`.** `Tunnel` carries a typed `TunnelKind` vocabulary; an
//!   association has none. All association-specific semantics live in the
//!   operational bitmap (`association_operational.rs`): the
//!   signal-sources-seen bitset, decay class, and arity.
//! - **A required `lattice_anchor`.** `Tunnel` predates cookbook §2.7
//!   (I-16); `Association` honours it, anchored to the lattice-midpoint of
//!   its endpoints. `add_association` rejects an empty `udc_code`.
//!
//! ## Swift-to-Rust shape changes
//!
//! - `Date filedAt` → `i64 filed_at` (epoch seconds), the convention used
//!   across the LocusKit Rust port. The SQLite column is still TEXT ISO8601.
//! - `Date? tombstonedAt` → `Option<i64> tombstoned_at`.
//! - Like the Swift type, `Association` derives `PartialEq, Eq` but **not**
//!   `Hash`: the embedded `LatticeAnchor` is not `Hash`, matching the Swift
//!   `LatticeAnchor` (which is `Equatable` but not `Hashable`). This is the
//!   one place `Association` diverges from `Tunnel`, which *is* `Hash`.

use crate::estate_types::LatticeAnchor;

/// A graph-edge noun linking two locations.
///
/// Mirrors `Association.swift` field-for-field. The three i64 bitmaps
/// (`adjective_bitmap`, `operational_bitmap`, `provenance_bitmap`) carry
/// the typed-axis state defined in `adjectives.rs`,
/// `association_operational.rs`, and `provenance.rs` respectively.
/// Equality follows the Rust derive defaults — every field participates,
/// matching Swift's auto-synthesized `Equatable`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Association {
    /// Stable identifier. Row identity is a UUID per cookbook I-29; this
    /// mission accepts whatever id the caller supplies.
    pub id: String,

    /// Wing of the source endpoint.
    pub source_wing: String,

    /// Room of the source endpoint.
    pub source_room: String,

    /// Drawer id at the source endpoint, when the association links a
    /// specific drawer. `None` means the room itself.
    pub source_drawer_id: Option<String>,

    /// Wing of the target endpoint.
    pub target_wing: String,

    /// Room of the target endpoint.
    pub target_room: String,

    /// Drawer id at the target endpoint. `None` means the room itself.
    pub target_drawer_id: Option<String>,

    /// Free-form descriptor for the association. Domain-specific; LocusKit
    /// does not validate against a closed catalogue. Unlike `Tunnel`, an
    /// association carries no typed `kind` vocabulary — the operational
    /// bitmap carries its semantics.
    pub label: String,

    /// The association's lattice anchor — required on every row per
    /// cookbook §2.7 (I-16). An association is anchored to the
    /// lattice-midpoint of its endpoints. `udc_code` must be non-empty at
    /// storage; `add_association` rejects an empty anchor with
    /// `LocusKitError::InvalidContent`.
    pub lattice_anchor: LatticeAnchor,

    /// Cross-row adjective bitmap (state, sensitivity, exportability,
    /// trust per cookbook §2.3). Stored as a single Int64 column.
    pub adjective_bitmap: i64,

    /// Per-noun operational bitmap (cookbook §2.4, association layout).
    /// Accessors in `association_operational.rs` decode the
    /// signal-sources-seen bitset, decay class, and arity.
    pub operational_bitmap: i64,

    /// Provenance bitmap (cookbook §2.5). Captures source type, channel,
    /// confirmation, confidence, and sensitivity at row birth.
    pub provenance_bitmap: i64,

    /// Name of the agent or process that filed this association.
    pub added_by: String,

    /// When the association was added. Epoch seconds in the Rust port; the
    /// SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,

    /// When this association was tombstoned, if it has been. Reserved for
    /// the Rev 2.0 soft-delete workflow.
    pub tombstoned_at: Option<i64>,

    /// Batch identifier used for receipt-based rollback of a tombstone.
    /// Reserved for the Rev 2.0 soft-delete workflow.
    pub removed_by_batch: Option<String>,
}

impl Association {
    /// Construct an association with all-zero bitmaps. Mirrors the Swift
    /// designated initializer's safe-baseline defaults — callers wanting
    /// non-default bitmaps or the optional drawer ids populate the struct
    /// fields directly because Rust does not have argument defaults. The
    /// eight required arguments mirror the Swift initializer's non-default
    /// fields; clippy's too-many-arguments lint is silenced because
    /// shrinking the surface would diverge from the Swift shape.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        source_wing: String,
        source_room: String,
        target_wing: String,
        target_room: String,
        label: String,
        lattice_anchor: LatticeAnchor,
        added_by: String,
        filed_at: i64,
    ) -> Self {
        Association {
            id,
            source_wing,
            source_room,
            source_drawer_id: None,
            target_wing,
            target_room,
            target_drawer_id: None,
            label,
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Association {
        Association::new(
            "a-1".to_string(),
            "wing_owner".to_string(),
            "kitchen".to_string(),
            "wing_owner".to_string(),
            "pantry".to_string(),
            "co-recalled".to_string(),
            LatticeAnchor::udc("547"),
            "dreaming".to_string(),
            1_700_000_000,
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let a = sample();
        assert_eq!(a.adjective_bitmap, 0);
        assert_eq!(a.operational_bitmap, 0);
        assert_eq!(a.provenance_bitmap, 0);
        assert_eq!(a.source_drawer_id, None);
        assert_eq!(a.target_drawer_id, None);
        assert_eq!(a.tombstoned_at, None);
        assert_eq!(a.removed_by_batch, None);
    }

    #[test]
    fn lattice_anchor_round_trips() {
        let a = sample();
        assert_eq!(a.lattice_anchor.udc_code, "547");
    }

    #[test]
    fn fields_round_trip() {
        let mut a = sample();
        a.adjective_bitmap = 42;
        a.operational_bitmap = 17;
        a.provenance_bitmap = 99;
        a.source_drawer_id = Some("d-1".to_string());
        a.target_drawer_id = Some("d-2".to_string());
        a.tombstoned_at = Some(1_700_001_000);
        a.removed_by_batch = Some("batch-1".to_string());

        let cloned = a.clone();
        assert_eq!(cloned, a);
    }

    #[test]
    fn equality_includes_every_field() {
        let a1 = sample();
        let mut a2 = sample();
        assert_eq!(a1, a2);
        a2.target_room = "cellar".to_string();
        assert_ne!(a1, a2);
    }
}
