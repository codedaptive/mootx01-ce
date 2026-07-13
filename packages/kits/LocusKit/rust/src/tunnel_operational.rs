//! Tunnel operational value types. Ports `TunnelOperational.swift`.
//!
//! Per `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` Appendix A
//! and § 5.6.
//!
//! Five typed axes describe a tunnel's relationship semantics and
//! operational state. `TunnelKind` is the relationship vocabulary
//! (10 cases) stored in a dedicated `kind_id` column. The remaining
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
//! bit  13    is_retired         (1 bit, T13 / ADR-021 Phase 7)
//! bits 14–63 reserved
//! ```
//!
//! ## Tunnel provenance layout (low-to-high)
//!
//! ```text
//! bit  0     is_dreamed         (1 bit, T13 / ADR-021 Phase 7)
//! bits 1–63  reserved
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
    /// Outline containment edge (ADR-017 §11). Source is the child,
    /// target is the parent. One parent per child enforced in
    /// `add_tunnel` (kit-level constraint, not a DB-level partial
    /// unique index). The companion `order_key` on the Tunnel
    /// struct provides fractional-index sibling ordering.
    Parent = 9,
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
            9 => TunnelKind::Parent,
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

    // ─── Retirement accessors (T13 / ADR-021 Phase 7) ───────────────

    /// Bit 13 of `operational_bitmap` — retirement flag (T13 / ADR-021 Phase 7).
    ///
    /// Set to 1 when OMEGA retires an unreinforced dreamed tunnel. Cleared
    /// to 0 by `unretire_tunnel` when a subsequent co-recall re-forms the
    /// tunnel. A retired tunnel is excluded from active reads (`all_active_tunnels`,
    /// the dreaming suppression set) but preserved in full audit history —
    /// no hard delete. Reversible by design (§ 12.8).
    ///
    /// Mirrors Swift `Tunnel.isRetiredBit` (bit 13).
    pub const IS_RETIRED_BIT: i64 = 1 << 13;

    /// True when this tunnel is retired (bit 13 of `operational_bitmap` is set).
    ///
    /// Retired tunnels are excluded from active tunnel reads. They remain in
    /// the database for audit continuity and may be un-retired when subsequent
    /// co-recall reinforces their endpoints again.
    pub fn is_retired(&self) -> bool {
        self.operational_bitmap & Self::IS_RETIRED_BIT != 0
    }

    /// Return a copy of this tunnel with bit 13 set (retired state).
    ///
    /// Used by `DrawerStore::retire_tunnel`. The caller is responsible for
    /// persisting the updated bitmap to the database and recording an audit
    /// diary entry (B-1: NeuronKit reaches this via the GLK seam, never
    /// directly).
    pub fn with_retired(&self) -> Tunnel {
        let mut copy = self.clone();
        copy.operational_bitmap |= Self::IS_RETIRED_BIT;
        copy
    }

    /// Return a copy of this tunnel with bit 13 cleared (active state).
    ///
    /// Used by `DrawerStore::unretire_tunnel` when a later co-recall
    /// re-reinforces a previously-retired dreamed tunnel.
    pub fn with_unretired(&self) -> Tunnel {
        let mut copy = self.clone();
        copy.operational_bitmap &= !Self::IS_RETIRED_BIT;
        copy
    }

    /// Return a copy of this tunnel with lifecycle bits 3–5 rewritten to
    /// `lifecycle`. Used by `DrawerStore::respond_to_tunnel` to move a
    /// `Proposed` tunnel to `Active` (accepted) or `Withdrawn` (rejected).
    /// The caller is responsible for persisting the updated bitmap.
    /// Mirrors Swift `Tunnel.withLifecycle(_:)`.
    pub fn with_lifecycle(&self, lifecycle: TunnelLifecycle) -> Tunnel {
        let mut copy = self.clone();
        copy.operational_bitmap = substrate_kernel::bit_field::write_field(
            lifecycle.raw_value(),
            copy.operational_bitmap,
            3,
            3,
        );
        copy
    }
}

// MARK: - Tunnel provenance accessors

// Tunnel `provenance_bitmap` layout (T13 / ADR-021 Phase 7, low-to-high):
//   bit  0   is_dreamed   (1 bit) — set by dreaming pipeline when the
//            tunnel was proposed by REM-ALPHA or REM-THETA (emergent channel).
//            Cleared for declared tunnels (palace tunnels.json, vault wikilinks,
//            user-explicit `capture` tunnel frames). OMEGA retires only tunnels
//            where is_dreamed = 1 (§ 12.8 "provenance = dreamed AND not
//            reinforced by recall"). Declared tunnels (is_dreamed = 0) are
//            NEVER retired by OMEGA regardless of recall activity.
//   bits 1–63 reserved for future provenance axes.
impl Tunnel {
    // ─── Provenance accessors (T13 / ADR-021 Phase 7) ───────────────

    /// Bit 0 of `provenance_bitmap` — dreamed-provenance flag (T13 / ADR-021 Phase 7).
    ///
    /// Set to 1 when this tunnel entered the substrate through the dreaming
    /// pipeline (REM-ALPHA or REM-THETA co-recall proposal, subsequently accepted).
    /// Set to 0 for all declared tunnels. OMEGA's retire predicate requires
    /// `is_dreamed == true` — declared tunnels are never retired (§ 12.8).
    ///
    /// Mirrors Swift `Tunnel.isDreamedBit` (bit 0).
    pub const IS_DREAMED_BIT: i64 = 1 << 0;

    /// True when this tunnel has dreamed provenance (emerged from REM-ALPHA
    /// or REM-THETA co-recall). False for all declared tunnels.
    pub fn is_dreamed(&self) -> bool {
        self.provenance_bitmap & Self::IS_DREAMED_BIT != 0
    }

    /// Return a copy of this tunnel with `is_dreamed` stamped (bit 0 set).
    ///
    /// Used when the dreaming pipeline forms a real Tunnel from an accepted
    /// proposal. Declared tunnels never call this method.
    pub fn with_dreamed_provenance(&self) -> Tunnel {
        let mut copy = self.clone();
        copy.provenance_bitmap |= Self::IS_DREAMED_BIT;
        copy
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
        assert_eq!(TunnelKind::Parent.raw_value(), 9);
    }

    #[test]
    fn tunnel_kind_from_raw_falls_back_to_references() {
        assert_eq!(TunnelKind::from_raw(0), TunnelKind::Supersedes);
        assert_eq!(TunnelKind::from_raw(8), TunnelKind::RespondsTo);
        assert_eq!(TunnelKind::from_raw(9), TunnelKind::Parent);
        assert_eq!(TunnelKind::from_raw(10), TunnelKind::References);
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

    // ─── Retirement accessor tests (T13 / ADR-021 Phase 7) ──────────

    #[test]
    fn is_retired_is_bit_thirteen() {
        let t = t_with(0);
        assert!(!t.is_retired(), "fresh tunnel should not be retired");
        let retired = t.with_retired();
        assert!(retired.is_retired(), "with_retired should set bit 13");
        // verify bit 13 specifically: 1 << 13 = 8192
        assert_eq!(retired.operational_bitmap & (1 << 13), 1 << 13);
    }

    #[test]
    fn with_retired_does_not_disturb_other_operational_bits() {
        // Set bits 0, 3, 12 (direction=bidirectional, lifecycle=proposed, has_inverse)
        let bits: i64 = 1 | (1 << 3) | (1 << 12);
        let t = t_with(bits);
        let retired = t.with_retired();
        assert!(retired.is_retired());
        // other bits must be preserved
        assert_eq!(retired.direction(), TunnelDirection::Bidirectional);
        assert_eq!(retired.lifecycle(), TunnelLifecycle::Proposed);
        assert!(retired.has_inverse());
    }

    #[test]
    fn with_unretired_clears_retirement_flag() {
        let t = t_with(1 << 13); // start retired
        assert!(t.is_retired());
        let active = t.with_unretired();
        assert!(!active.is_retired(), "with_unretired should clear bit 13");
    }

    #[test]
    fn retire_then_unretire_round_trips() {
        let original = t_with(0b101); // some bits set
        let retired = original.with_retired();
        let restored = retired.with_unretired();
        assert_eq!(
            original.operational_bitmap,
            restored.operational_bitmap,
            "bitmap must be identical after retire→unretire"
        );
    }

    #[test]
    fn is_retired_bit_matches_swift_constant() {
        // Swift: isRetiredBit = 1 << 13 = 8192. Rust must agree.
        assert_eq!(Tunnel::IS_RETIRED_BIT, 8192);
    }

    // ─── Provenance accessor tests (T13 / ADR-021 Phase 7) ──────────

    fn p_with(prov_bits: i64) -> Tunnel {
        let mut t = Tunnel::new(
            "p".to_string(),
            "w".to_string(),
            "r".to_string(),
            "w".to_string(),
            "r".to_string(),
            "label".to_string(),
            "u".to_string(),
            0,
        );
        t.provenance_bitmap = prov_bits;
        t
    }

    #[test]
    fn is_dreamed_is_bit_zero_of_provenance_bitmap() {
        let t = p_with(0);
        assert!(!t.is_dreamed(), "default provenance is declared (not dreamed)");
        let dreamed = t.with_dreamed_provenance();
        assert!(dreamed.is_dreamed(), "with_dreamed_provenance must set bit 0");
        assert_eq!(dreamed.provenance_bitmap & 1, 1);
    }

    #[test]
    fn with_dreamed_provenance_does_not_disturb_operational_bitmap() {
        let mut t = p_with(0);
        t.operational_bitmap = 0b111; // direction=Hub and some other bits
        let dreamed = t.with_dreamed_provenance();
        assert_eq!(
            dreamed.operational_bitmap,
            0b111,
            "operational_bitmap must be unchanged by provenance stamp"
        );
    }

    #[test]
    fn declared_tunnel_never_dreamed_by_default() {
        let t = Tunnel::new(
            "d".to_string(),
            "w".to_string(),
            "r".to_string(),
            "w".to_string(),
            "r".to_string(),
            "label".to_string(),
            "u".to_string(),
            0,
        );
        assert!(!t.is_dreamed());
        assert!(!t.is_retired());
    }

    #[test]
    fn is_dreamed_bit_matches_swift_constant() {
        // Swift: isDreamedBit = 1 << 0 = 1. Rust must agree.
        assert_eq!(Tunnel::IS_DREAMED_BIT, 1);
    }
}
