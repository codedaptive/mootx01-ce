//! `SourceCatalogEntry` noun struct + `SourceKind`. Ports
//! `SourceCatalogEntry.swift`.
//!
//! The durable, queryable record of an external source from which
//! references are learned — the substrate behind the `source` slot of the
//! grounding-driven `learn` verb (spec § 7.8.2: `LearnFrame.source`,
//! `LearnedReference.source`).
//!
//! ## Why it exists
//!
//! Every `LearnedReference` must carry a *genuine* lattice anchor, never a
//! sentinel (P1 mandate). The anchor is a property of the *source*, not of
//! each individual handle: every reference learned from one source inherits
//! that source's lattice position. `SourceCatalogEntry` records the genuine
//! anchor once so `learn` derives each reference's anchor from the catalog
//! entry rather than fabricating one from a bare handle.
//!
//! ## Field shape — spec § 7.8.2 intent
//!
//! The spec names `SourceCatalogEntry` without enumerating columns; these
//! fields realise its intent (a source identifier, its kind, its anchor,
//! and when it was first seen). Mirrors `SourceCatalogEntry.swift`
//! field-for-field, with the LocusKit Rust date convention (`Date` →
//! `i64` epoch seconds; the SQLite column stays TEXT ISO8601).
//!
//! Derives `PartialEq, Eq` but **not** `Hash` (the embedded
//! `LatticeAnchor` is not `Hash`), matching the Swift type and every other
//! anchored LocusKit noun.

use crate::estate_types::LatticeAnchor;

/// What class of external source a `SourceCatalogEntry` records.
///
/// Stored as its raw `i64` so the column round-trips a stable integer, and
/// decoded with a fail-closed fallback to `User` for unrecognised raws —
/// the same safe-baseline convention every operational enum follows. The
/// cases mirror `LearnedReferenceSource` (`learned_reference.rs`): the
/// acquisition channel a reference is learned through is the same
/// vocabulary as the kind of source it came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum SourceKind {
    User = 0,
    Federation = 1,
    HouseholdPairing = 2,
    FleetPairing = 3,
    TierInheritance = 4,
    PairedEstate = 5,
}

impl SourceKind {
    /// The stable raw value persisted in the `kind` column.
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode a stored raw with a fail-closed fallback to `User` for
    /// unrecognised values, matching the operational-enum convention.
    pub fn from_raw(raw: i64) -> SourceKind {
        match raw {
            0 => SourceKind::User,
            1 => SourceKind::Federation,
            2 => SourceKind::HouseholdPairing,
            3 => SourceKind::FleetPairing,
            4 => SourceKind::TierInheritance,
            5 => SourceKind::PairedEstate,
            _ => SourceKind::User,
        }
    }
}

/// A source catalog entry. Mirrors `SourceCatalogEntry.swift`
/// field-for-field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceCatalogEntry {
    /// Stable source identifier — the value a `LearnedReference` carries in
    /// `source_catalog_id`. Row identity is a UUID per cookbook I-29.
    pub id: String,

    /// What class of source this is.
    pub kind: SourceKind,

    /// The canonical locator for the source itself (domain, corpus root, or
    /// estate URI). Indexed (`idx_source_catalog_handle`).
    pub handle: String,

    /// The source's genuine lattice anchor — required and non-empty per
    /// cookbook § 2.7 (I-16). `add_source_catalog_entry` rejects an empty
    /// `udc_code`. Every `LearnedReference` learned from this source
    /// inherits this anchor; it is never a fabricated sentinel.
    pub lattice_anchor: LatticeAnchor,

    /// When this source was first cataloged. Epoch seconds; the SQLite
    /// column is TEXT ISO8601 per the fleet date rule.
    pub first_seen: i64,

    /// The agent or process that cataloged this source.
    pub added_by: String,
}

impl SourceCatalogEntry {
    /// Construct a source catalog entry. The arguments mirror the Swift
    /// designated initializer.
    pub fn new(
        id: impl Into<String>,
        kind: SourceKind,
        handle: impl Into<String>,
        lattice_anchor: LatticeAnchor,
        first_seen: i64,
        added_by: impl Into<String>,
    ) -> Self {
        SourceCatalogEntry {
            id: id.into(),
            kind,
            handle: handle.into(),
            lattice_anchor,
            first_seen,
            added_by: added_by.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> SourceCatalogEntry {
        SourceCatalogEntry::new(
            "src-1",
            SourceKind::User,
            "https://example.com",
            LatticeAnchor::udc("004"),
            1_700_000_000,
            "cataloger",
        )
    }

    #[test]
    fn source_kind_round_trips_every_case() {
        for kind in [
            SourceKind::User,
            SourceKind::Federation,
            SourceKind::HouseholdPairing,
            SourceKind::FleetPairing,
            SourceKind::TierInheritance,
            SourceKind::PairedEstate,
        ] {
            assert_eq!(SourceKind::from_raw(kind.raw_value()), kind);
        }
    }

    #[test]
    fn source_kind_unrecognised_raw_falls_back_to_user() {
        assert_eq!(SourceKind::from_raw(6), SourceKind::User);
        assert_eq!(SourceKind::from_raw(-1), SourceKind::User);
        assert_eq!(SourceKind::from_raw(99), SourceKind::User);
    }

    #[test]
    fn fields_round_trip() {
        let e = sample();
        assert_eq!(e.id, "src-1");
        assert_eq!(e.kind, SourceKind::User);
        assert_eq!(e.handle, "https://example.com");
        assert_eq!(e.lattice_anchor.udc_code, "004");
        assert_eq!(e.first_seen, 1_700_000_000);
        assert_eq!(e.added_by, "cataloger");
    }

    #[test]
    fn equality_includes_every_field() {
        let a = sample();
        let mut b = sample();
        assert_eq!(a, b);
        b.handle = "https://other.example".to_string();
        assert_ne!(a, b);
    }
}
