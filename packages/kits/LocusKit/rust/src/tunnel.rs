//! Tunnel struct. Ports `Tunnel.swift`.
//!
//! A typed cross-reference between two locations in the MemPalace
//! surface. Tunnels link wings, rooms, or specific drawers and are
//! stored directionally so that queries can ask "what does this side
//! know about?" without scanning both endpoints. The symmetric-id
//! contract (canonical id is the hash of the sorted endpoint pair) is
//! documented in `Tunnel.swift` but not enforced at this layer; the
//! enforcement arrives in LOCI-5.
//!
//! Source and target endpoints both carry wing + room + optional
//! drawer id. A `None` drawer id at either end means "the room itself"
//! — useful for room-level concepts that are not anchored to any
//! single drawer.
//!
//! `tombstoned_at` and `removed_by_batch` are present from Rev 1.0 so
//! the schema does not need to migrate when the soft-delete workflow
//! lands.
//!
//! ## Swift-to-Rust shape changes
//!
//! - `Date filedAt` → `i64 filed_at` (epoch seconds). Same convention
//!   as `Drawer::filed_at`; the SQLite column is still TEXT ISO8601.
//! - `Date? tombstonedAt` → `Option<i64> tombstoned_at`.
//! - `TunnelKind = .references` Swift default → Rust callers supply
//!   `TunnelKind::References` explicitly. The bit-layout fallback in
//!   `tunnel_operational.rs` still resolves the default for unknown
//!   raw values.

use crate::tunnel_operational::TunnelKind;

/// A typed cross-reference between two locations.
///
/// Mirrors `Tunnel.swift` field-for-field. The three Int64 bitmaps
/// (`adjective_bitmap`, `operational_bitmap`, `provenance_bitmap`)
/// carry the typed-axis state defined in `adjectives.rs`,
/// `tunnel_operational.rs`, and `provenance.rs` respectively.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Tunnel {
    /// Stable identifier. Conventionally the SHA-256 of the
    /// canonicalised endpoint pair so that A→B and B→A collapse to
    /// one row. This mission accepts whatever id the caller supplies;
    /// LOCI-5 enforces the canonicalisation.
    pub id: String,

    /// Wing of the source endpoint.
    pub source_wing: String,

    /// Room of the source endpoint.
    pub source_room: String,

    /// Drawer id at the source endpoint, when the tunnel targets a
    /// specific drawer. `None` means the room itself.
    pub source_drawer_id: Option<String>,

    /// Wing of the target endpoint.
    pub target_wing: String,

    /// Room of the target endpoint.
    pub target_room: String,

    /// Drawer id at the target endpoint. `None` means the room itself.
    pub target_drawer_id: Option<String>,

    /// Free-form relationship label. Domain-specific; LocusKit does
    /// not validate against a closed catalogue.
    pub label: String,

    /// Typed relationship kind from the closed spec vocabulary
    /// (Appendix A). `kind` is the indexed, finite vocabulary the
    /// retrieval layer dispatches on; `label` is the free-form
    /// human-readable companion.
    pub kind: TunnelKind,

    /// Cross-row adjective bitmap (state, sensitivity, exportability,
    /// trust per spec § 5.5). Stored as a single Int64 column.
    pub adjective_bitmap: i64,

    /// Per-noun operational bitmap (spec § 5.6, tunnel layout).
    /// Accessors in `tunnel_operational.rs` decode direction,
    /// lifecycle, origin_class, strength, and has_inverse.
    pub operational_bitmap: i64,

    /// Provenance bitmap (spec § 5.7, Q1-locked layout). Captures
    /// source type, confirmation, confidence, channel, and
    /// sensitivity at row birth.
    pub provenance_bitmap: i64,

    /// Name of the agent or process that filed this tunnel.
    pub added_by: String,

    /// When the tunnel was added. Epoch seconds in the Rust port;
    /// the SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,

    /// When this tunnel was tombstoned, if it has been. Reserved
    /// for the Rev 2.0 soft-delete workflow.
    pub tombstoned_at: Option<i64>,

    /// Batch identifier used for receipt-based rollback of a
    /// tombstone. Reserved for the Rev 2.0 soft-delete workflow.
    pub removed_by_batch: Option<String>,
}

impl Tunnel {
    /// Construct a tunnel with all-zero bitmaps and the default
    /// `TunnelKind::References`. Mirrors the Swift designated
    /// initializer's defaulting behavior — callers wanting non-default
    /// bitmaps or a different kind populate the struct fields directly
    /// because Rust does not have argument defaults. The eight
    /// required arguments mirror the Swift initializer's non-default
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
        added_by: String,
        filed_at: i64,
    ) -> Self {
        Tunnel {
            id,
            source_wing,
            source_room,
            source_drawer_id: None,
            target_wing,
            target_room,
            target_drawer_id: None,
            label,
            kind: TunnelKind::References,
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

    fn sample() -> Tunnel {
        Tunnel::new(
            "t-1".to_string(),
            "wing_owner".to_string(),
            "kitchen".to_string(),
            "wing_owner".to_string(),
            "pantry".to_string(),
            "shelves-into".to_string(),
            "alice".to_string(),
            1_700_000_000,
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let t = sample();
        assert_eq!(t.kind, TunnelKind::References);
        assert_eq!(t.adjective_bitmap, 0);
        assert_eq!(t.operational_bitmap, 0);
        assert_eq!(t.provenance_bitmap, 0);
        assert_eq!(t.source_drawer_id, None);
        assert_eq!(t.target_drawer_id, None);
        assert_eq!(t.tombstoned_at, None);
        assert_eq!(t.removed_by_batch, None);
    }

    #[test]
    fn fields_round_trip() {
        let mut t = sample();
        t.adjective_bitmap = 42;
        t.operational_bitmap = 17;
        t.provenance_bitmap = 99;
        t.source_drawer_id = Some("d-1".to_string());
        t.target_drawer_id = Some("d-2".to_string());
        t.tombstoned_at = Some(1_700_001_000);
        t.removed_by_batch = Some("batch-1".to_string());

        let cloned = t.clone();
        assert_eq!(cloned, t);
    }
}
