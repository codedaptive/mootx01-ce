//! Tunnel operational value types. Ports `TunnelOperational.swift`.
//!
//! Per `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` Appendix A
//! and § 5.6.
//!
//! Five typed axes describe a tunnel's relationship semantics and
//! operational state. `TunnelKind` is the relationship vocabulary
//! (9 cases) stored in a dedicated `kind_id` column. The remaining
//! four axes — `TunnelDirection`, `TunnelLifecycle`, `TunnelOriginClass`,
//! `TunnelStrength` — pack into the per-row `operational_bitmap` Int64
//! column.
//!
//! ## Tunnel operational layout (low-to-high)
//!
//! ```text
//! bits 0–2   TunnelDirection    (3 bits, contiguous, 4 cases)
//! bits 3–5   TunnelLifecycle    (3 bits, contiguous, 4 cases)
//! bits 6–8   TunnelOriginClass  (3 bits, contiguous, 5 cases)
//! bits 9–11  TunnelStrength     (3 bits, scale-gapped, raws 0/2/4/6)
//! bit  12    has_inverse        (1 bit, exclusive)
//! bits 13–63 reserved
//! ```
//!
//! Pattern mirrors `drawer_operational.rs`: named-enum accessors decode
//! each axis from a single i64 column with a safe fallback to the zero
//! case when an unrecognised raw value appears (including the
//! intentional scale-gap sentinels — raws 1, 3, 5, 7 for strength).

use crate::tunnel::Tunnel;
use std::cmp::Ordering;
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

// MARK: - TunnelKind

/// Relationship kind — the typed vocabulary for what one tunnel
/// asserts between source and target. Per spec Appendix A. The default
/// for new tunnels is `References`; the supersession cascade in the
/// Swift `DrawerStore.addDrawerWithCascade` sets `Supersedes`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum TunnelKind {
    Supersedes = 0,
    References = 1,
    Blocks = 2,
    Validates = 3,
    Contradicts = 4,
    DerivesFrom = 5,
    Covers = 6,
    Elaborates = 7,
    RespondsTo = 8,
}

impl TunnelKind {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `References` for unrecognised
    /// raw values — the safe default for the closed vocabulary because
    /// "this row points at that row" is the weakest semantic claim and
    /// surfaces an unknown future kind without overstating the
    /// relationship.
    pub fn from_raw(v: i64) -> TunnelKind {
        match v {
            0 => TunnelKind::Supersedes,
            1 => TunnelKind::References,
            2 => TunnelKind::Blocks,
            3 => TunnelKind::Validates,
            4 => TunnelKind::Contradicts,
            5 => TunnelKind::DerivesFrom,
            6 => TunnelKind::Covers,
            7 => TunnelKind::Elaborates,
            8 => TunnelKind::RespondsTo,
            _ => TunnelKind::References,
        }
    }
}

// MARK: - TunnelDirection

/// Directionality of a tunnel — whether traversal is meaningful one
/// way, both ways, fully symmetric, or hub-like. Per spec § 5.6.
/// Contiguous encoding; 4 used, 4 reserved within the 3-bit field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum TunnelDirection {
    Directional = 0,
    Bidirectional = 1,
    Symmetric = 2,
    Hub = 3,
}

impl TunnelDirection {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from the low 3 bits. Returns `Directional` for
    /// unrecognised raw values (raws 4–7 reserved).
    pub fn from_raw(v: i64) -> TunnelDirection {
        match v {
            0 => TunnelDirection::Directional,
            1 => TunnelDirection::Bidirectional,
            2 => TunnelDirection::Symmetric,
            3 => TunnelDirection::Hub,
            _ => TunnelDirection::Directional,
        }
    }
}

// MARK: - TunnelLifecycle

/// Lifecycle state of a tunnel — analogous to the drawer adjective
/// state but with a smaller closed set tailored to relationship rows.
/// Per spec § 5.6. Contiguous encoding; 4 used, 4 reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum TunnelLifecycle {
    Active = 0,
    Proposed = 1,
    Superseded = 2,
    Withdrawn = 3,
}

impl TunnelLifecycle {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 3-bit slice. Returns `Active` for unrecognised
    /// raw values — the neutral baseline matching Swift.
    pub fn from_raw(v: i64) -> TunnelLifecycle {
        match v {
            0 => TunnelLifecycle::Active,
            1 => TunnelLifecycle::Proposed,
            2 => TunnelLifecycle::Superseded,
            3 => TunnelLifecycle::Withdrawn,
            _ => TunnelLifecycle::Active,
        }
    }
}

// MARK: - TunnelOriginClass

/// How the tunnel entered the substrate — user assertion, agent
/// derivation, import path, sync replication, or schema migration.
/// Per spec § 5.6. Contiguous encoding; 5 used, 3 reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum TunnelOriginClass {
    UserExplicit = 0,
    Derived = 1,
    Imported = 2,
    FederatedSync = 3,
    Migration = 4,
}

impl TunnelOriginClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 3-bit slice. Returns `UserExplicit` for
    /// unrecognised raw values — surfacing an unknown future origin
    /// class as "user-asserted" makes the row look more load-bearing
    /// than it should, which is the failure mode we want.
    pub fn from_raw(v: i64) -> TunnelOriginClass {
        match v {
            0 => TunnelOriginClass::UserExplicit,
            1 => TunnelOriginClass::Derived,
            2 => TunnelOriginClass::Imported,
            3 => TunnelOriginClass::FederatedSync,
            4 => TunnelOriginClass::Migration,
            _ => TunnelOriginClass::UserExplicit,
        }
    }
}

// MARK: - TunnelStrength

/// Strength axis — scale-gapped encoding (raws 0/2/4/6) so future
/// intermediate tiers can slot in without disturbing existing equality
/// or ordering masks. Per spec § 5.6. Sentinels: raws 1, 3, 5, 7
/// resolve to `Weak` (the zero-case fallback) so a future intermediate
/// tier can be added without renumbering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum TunnelStrength {
    Weak = 0,
    Normal = 2,
    Strong = 4,
    LoadBearing = 6,
}

impl TunnelStrength {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> TunnelStrength {
        match v {
            0 => TunnelStrength::Weak,
            2 => TunnelStrength::Normal,
            4 => TunnelStrength::Strong,
            6 => TunnelStrength::LoadBearing,
            _ => TunnelStrength::Weak,
        }
    }
}

impl PartialOrd for TunnelStrength {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TunnelStrength {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - Tunnel accessors

impl Tunnel {
    /// Decode bits 0–2 of `operational_bitmap` as a `TunnelDirection`.
    pub fn direction(&self) -> TunnelDirection {
        TunnelDirection::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 3))
    }

    /// Decode bits 3–5 of `operational_bitmap` as a `TunnelLifecycle`.
    pub fn lifecycle(&self) -> TunnelLifecycle {
        TunnelLifecycle::from_raw(bit_field::extract_field(self.operational_bitmap, 3, 3))
    }

    /// Decode bits 6–8 of `operational_bitmap` as a `TunnelOriginClass`.
    pub fn origin_class(&self) -> TunnelOriginClass {
        TunnelOriginClass::from_raw(bit_field::extract_field(self.operational_bitmap, 6, 3))
    }

    /// Decode bits 9–11 of `operational_bitmap` as a `TunnelStrength`.
    /// Returns `Weak` for the intentionally-gapped scale raws (1, 3,
    /// 5, 7) and any future-reserved values.
    pub fn strength(&self) -> TunnelStrength {
        TunnelStrength::from_raw(bit_field::extract_field(self.operational_bitmap, 9, 3))
    }

    /// Decode bit 12 of `operational_bitmap`. True when a paired
    /// inverse tunnel exists in the substrate.
    pub fn has_inverse(&self) -> bool {
        bit_field::extract_flag(self.operational_bitmap, 12)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tunnel::Tunnel;

    fn t_with(bits: i64) -> Tunnel {
        let mut t = Tunnel::new(
            "t".to_string(),
            "w".to_string(),
            "r".to_string(),
            "w".to_string(),
            "r".to_string(),
            "label".to_string(),
            "u".to_string(),
            0,
        );
        t.operational_bitmap = bits;
        t
    }

    #[test]
    fn tunnel_kind_raw_values_match_swift() {
        assert_eq!(TunnelKind::Supersedes.raw_value(), 0);
        assert_eq!(TunnelKind::References.raw_value(), 1);
        assert_eq!(TunnelKind::Blocks.raw_value(), 2);
        assert_eq!(TunnelKind::Validates.raw_value(), 3);
        assert_eq!(TunnelKind::Contradicts.raw_value(), 4);
        assert_eq!(TunnelKind::DerivesFrom.raw_value(), 5);
        assert_eq!(TunnelKind::Covers.raw_value(), 6);
        assert_eq!(TunnelKind::Elaborates.raw_value(), 7);
        assert_eq!(TunnelKind::RespondsTo.raw_value(), 8);
    }

    #[test]
    fn tunnel_kind_from_raw_falls_back_to_references() {
        assert_eq!(TunnelKind::from_raw(0), TunnelKind::Supersedes);
        assert_eq!(TunnelKind::from_raw(8), TunnelKind::RespondsTo);
        assert_eq!(TunnelKind::from_raw(9), TunnelKind::References);
        assert_eq!(TunnelKind::from_raw(-1), TunnelKind::References);
    }

    #[test]
    fn direction_decodes_low_three_bits() {
        assert_eq!(t_with(0).direction(), TunnelDirection::Directional);
        assert_eq!(t_with(1).direction(), TunnelDirection::Bidirectional);
        assert_eq!(t_with(2).direction(), TunnelDirection::Symmetric);
        assert_eq!(t_with(3).direction(), TunnelDirection::Hub);
        assert_eq!(t_with(4).direction(), TunnelDirection::Directional);
    }

    #[test]
    fn lifecycle_decodes_bits_three_through_five() {
        assert_eq!(t_with(0).lifecycle(), TunnelLifecycle::Active);
        assert_eq!(t_with(1 << 3).lifecycle(), TunnelLifecycle::Proposed);
        assert_eq!(t_with(2 << 3).lifecycle(), TunnelLifecycle::Superseded);
        assert_eq!(t_with(3 << 3).lifecycle(), TunnelLifecycle::Withdrawn);
        assert_eq!(t_with(4 << 3).lifecycle(), TunnelLifecycle::Active);
    }

    #[test]
    fn origin_class_decodes_bits_six_through_eight() {
        assert_eq!(t_with(0).origin_class(), TunnelOriginClass::UserExplicit);
        assert_eq!(t_with(1 << 6).origin_class(), TunnelOriginClass::Derived);
        assert_eq!(t_with(2 << 6).origin_class(), TunnelOriginClass::Imported);
        assert_eq!(
            t_with(3 << 6).origin_class(),
            TunnelOriginClass::FederatedSync
        );
        assert_eq!(t_with(4 << 6).origin_class(), TunnelOriginClass::Migration);
        assert_eq!(
            t_with(5 << 6).origin_class(),
            TunnelOriginClass::UserExplicit
        );
    }

    #[test]
    fn strength_decodes_scale_gapped_raws() {
        assert_eq!(t_with(0).strength(), TunnelStrength::Weak);
        assert_eq!(t_with(2 << 9).strength(), TunnelStrength::Normal);
        assert_eq!(t_with(4 << 9).strength(), TunnelStrength::Strong);
        assert_eq!(t_with(6 << 9).strength(), TunnelStrength::LoadBearing);
    }

    #[test]
    fn strength_scale_gap_sentinels_fall_back_to_weak() {
        assert_eq!(t_with(1 << 9).strength(), TunnelStrength::Weak);
        assert_eq!(t_with(3 << 9).strength(), TunnelStrength::Weak);
        assert_eq!(t_with(5 << 9).strength(), TunnelStrength::Weak);
        assert_eq!(t_with(7 << 9).strength(), TunnelStrength::Weak);
    }

    #[test]
    fn strength_ordering_matches_raw_values() {
        assert!(TunnelStrength::Weak < TunnelStrength::Normal);
        assert!(TunnelStrength::Normal < TunnelStrength::Strong);
        assert!(TunnelStrength::Strong < TunnelStrength::LoadBearing);
    }

    #[test]
    fn has_inverse_is_bit_twelve() {
        assert!(!t_with(0).has_inverse());
        assert!(t_with(1 << 12).has_inverse());
        assert!(!t_with((1 << 13) | (1 << 11)).has_inverse());
    }

    #[test]
    fn unknown_bits_above_layout_are_ignored() {
        let t = t_with(i64::MIN);
        // bits 0–12 are zero in i64::MIN (sign bit is bit 63), so every
        // accessor returns the zero-case default.
        assert_eq!(t.direction(), TunnelDirection::Directional);
        assert_eq!(t.lifecycle(), TunnelLifecycle::Active);
        assert_eq!(t.origin_class(), TunnelOriginClass::UserExplicit);
        assert_eq!(t.strength(), TunnelStrength::Weak);
        assert!(!t.has_inverse());
    }
}
