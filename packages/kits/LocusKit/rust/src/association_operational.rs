//! Association operational value types. Ports `AssociationOperational.swift`.
//!
//! Per cookbook §2.4 ("Association operational", empirical-dominant,
//! 6-bit floor).
//!
//! Three axes describe how an association formed and how it ages. They
//! pack into the low 20 bits of `Association::operational_bitmap`:
//!
//! ```text
//! bits 0–11   signal_sources_seen  (bitset — each bit independent)
//! bits 12–17  decay_class          (scale-gapped, raws 0/16/32/48)
//! bits 18–19  arity                (contiguous, raws 0/1)
//! bits 20–63  reserved
//! ```
//!
//! Unlike the contiguous-field axes of `tunnel_operational` /
//! `proposal_operational`, `signal_sources_seen` is a **bitset**: more
//! than one source can be set at once. It is surfaced as the
//! `AssociationSignalSources` newtype read off the masked low 12 bits, not
//! as a named-enum field extract. `decay_class` and `arity` are ordinary
//! fields decoded with `bit_field::extract_field` and a safe fallback to
//! the zero case, matching `tunnel_operational.rs`.

use crate::association::Association;
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

// MARK: - AssociationSignalSources

/// The set of signals that have contributed to an association, per
/// cookbook §2.4 bits 0–11 (a bitset). Mirrors the Swift `OptionSet`:
/// each `const` is one independent bit and `contains` tests membership.
/// Bits 10–11 are reserved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AssociationSignalSources(pub i64);

impl AssociationSignalSources {
    /// Bit 0 — the two rows were recalled together.
    pub const CO_RECALL: AssociationSignalSources = AssociationSignalSources(1 << 0);
    /// Bit 1 — the two rows were confirmed together.
    pub const CO_CONFIRMED: AssociationSignalSources = AssociationSignalSources(1 << 1);
    /// Bit 2 — paired by a dreaming pass.
    pub const DREAM_PAIRING: AssociationSignalSources = AssociationSignalSources(1 << 2);
    /// Bit 3 — paired by vector similarity.
    pub const VECTOR_SIMILARITY: AssociationSignalSources = AssociationSignalSources(1 << 3);
    /// Bit 4 — the rows share an entity.
    pub const SHARED_ENTITY: AssociationSignalSources = AssociationSignalSources(1 << 4);
    /// Bit 5 — asserted explicitly by a human.
    pub const EXPLICIT_HUMAN: AssociationSignalSources = AssociationSignalSources(1 << 5);
    /// Bit 6 — paired by fingerprint similarity. (NEW, v0.36.)
    pub const FINGERPRINT_SIMILARITY: AssociationSignalSources = AssociationSignalSources(1 << 6);
    /// Bit 7 — the pairing crosses estates. (NEW, v0.36 case 1.)
    pub const CROSS_ESTATE: AssociationSignalSources = AssociationSignalSources(1 << 7);
    /// Bit 8 — the pairing crosses tiers. (NEW, v0.36 case 3.)
    pub const CROSS_TIER: AssociationSignalSources = AssociationSignalSources(1 << 8);
    /// Bit 9 — derived from an action outcome. (NEW, v0.36 case 2.)
    pub const ACTION_OUTCOME: AssociationSignalSources = AssociationSignalSources(1 << 9);

    /// Mask covering the assigned bits 0–11 (bits 10–11 reserved).
    pub const MASK: i64 = 0xFFF;

    /// The raw masked bits.
    pub fn raw_value(self) -> i64 {
        self.0
    }

    /// True when every bit of `other` is set in `self`. Mirrors the Swift
    /// `OptionSet.contains`.
    pub fn contains(self, other: AssociationSignalSources) -> bool {
        self.0 & other.0 == other.0
    }
}

// MARK: - AssociationDecayClass

/// How fast an association ages out of relevance. Per cookbook §2.4 bits
/// 12–17. Scale-gapped encoding (raws 0/16/32/48); every other raw is an
/// intentional sentinel that falls back to `Pinned`. Ordering runs
/// pinned < slow < normal < fast — increasing decay speed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum AssociationDecayClass {
    Pinned = 0,
    Slow = 16,
    Normal = 32,
    Fast = 48,
}

impl AssociationDecayClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 6-bit slice. Returns `Pinned` for unrecognised raw
    /// values, including the intentionally-gapped scale sentinels.
    pub fn from_raw(v: i64) -> AssociationDecayClass {
        match v {
            0 => AssociationDecayClass::Pinned,
            16 => AssociationDecayClass::Slow,
            32 => AssociationDecayClass::Normal,
            48 => AssociationDecayClass::Fast,
            _ => AssociationDecayClass::Pinned,
        }
    }
}

impl PartialOrd for AssociationDecayClass {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for AssociationDecayClass {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - AssociationArity

/// The arity of an association. Per cookbook §2.4 bits 18–19. Contiguous
/// encoding. v1 is always `Binary` (I-23 limits associations to binary);
/// `NAry` is reserved for v2+.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum AssociationArity {
    Binary = 0,
    NAry = 1,
}

impl AssociationArity {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 2-bit slice. Returns `Binary` for unrecognised raw
    /// values (raws 2–3 reserved).
    pub fn from_raw(v: i64) -> AssociationArity {
        match v {
            0 => AssociationArity::Binary,
            1 => AssociationArity::NAry,
            _ => AssociationArity::Binary,
        }
    }
}

// MARK: - Association accessors

impl Association {
    /// Decode bits 0–11 of `operational_bitmap` as the set of signals that
    /// have contributed to this association. A bitset; reserved bits 10–11
    /// and all higher bits are masked off.
    pub fn signal_sources_seen(&self) -> AssociationSignalSources {
        AssociationSignalSources(self.operational_bitmap & AssociationSignalSources::MASK)
    }

    /// Decode bits 12–17 of `operational_bitmap` as an
    /// `AssociationDecayClass`.
    pub fn decay_class(&self) -> AssociationDecayClass {
        AssociationDecayClass::from_raw(bit_field::extract_field(self.operational_bitmap, 12, 6))
    }

    /// Decode bits 18–19 of `operational_bitmap` as an `AssociationArity`.
    pub fn arity(&self) -> AssociationArity {
        AssociationArity::from_raw(bit_field::extract_field(self.operational_bitmap, 18, 2))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::estate_types::LatticeAnchor;

    fn a_with(bits: i64) -> Association {
        let mut a = Association::new(
            "a".to_string(),
            "w".to_string(),
            "r".to_string(),
            "w".to_string(),
            "r".to_string(),
            "label".to_string(),
            LatticeAnchor::udc("547"),
            "u".to_string(),
            0,
        );
        a.operational_bitmap = bits;
        a
    }

    #[test]
    fn signal_sources_individual_bits_match_cookbook() {
        assert_eq!(AssociationSignalSources::CO_RECALL.raw_value(), 1 << 0);
        assert_eq!(AssociationSignalSources::CO_CONFIRMED.raw_value(), 1 << 1);
        assert_eq!(AssociationSignalSources::DREAM_PAIRING.raw_value(), 1 << 2);
        assert_eq!(
            AssociationSignalSources::VECTOR_SIMILARITY.raw_value(),
            1 << 3
        );
        assert_eq!(AssociationSignalSources::SHARED_ENTITY.raw_value(), 1 << 4);
        assert_eq!(AssociationSignalSources::EXPLICIT_HUMAN.raw_value(), 1 << 5);
        assert_eq!(
            AssociationSignalSources::FINGERPRINT_SIMILARITY.raw_value(),
            1 << 6
        );
        assert_eq!(AssociationSignalSources::CROSS_ESTATE.raw_value(), 1 << 7);
        assert_eq!(AssociationSignalSources::CROSS_TIER.raw_value(), 1 << 8);
        assert_eq!(AssociationSignalSources::ACTION_OUTCOME.raw_value(), 1 << 9);
    }

    #[test]
    fn signal_sources_decodes_each_bit() {
        for shift in 0..=9i64 {
            let set = a_with(1 << shift).signal_sources_seen();
            assert!(set.contains(AssociationSignalSources(1 << shift)));
        }
    }

    #[test]
    fn signal_sources_is_a_bitset_multiple_can_coexist() {
        let raw = AssociationSignalSources::CO_RECALL.raw_value()
            | AssociationSignalSources::VECTOR_SIMILARITY.raw_value()
            | AssociationSignalSources::EXPLICIT_HUMAN.raw_value();
        let set = a_with(raw).signal_sources_seen();
        assert!(set.contains(AssociationSignalSources::CO_RECALL));
        assert!(set.contains(AssociationSignalSources::VECTOR_SIMILARITY));
        assert!(set.contains(AssociationSignalSources::EXPLICIT_HUMAN));
        // A bit that was not set is absent.
        assert!(!set.contains(AssociationSignalSources::CROSS_TIER));
    }

    #[test]
    fn signal_sources_masks_reserved_and_higher_bits() {
        // Reserved bits 10–11 and bits in higher axes must not appear in
        // the set.
        let raw = (1 << 10) | (1 << 11) | (1 << 12) | (1 << 18);
        let set = a_with(raw).signal_sources_seen();
        // Only assigned bits 0–11 survive the mask; the decay/arity bits
        // (12, 18) are stripped. Bits 10–11 are within the mask but
        // unassigned, so they round-trip as raw bits without a named member.
        assert_eq!(set.raw_value(), (1 << 10) | (1 << 11));
    }

    #[test]
    fn decay_class_decodes_scale_gapped_raws() {
        assert_eq!(a_with(0).decay_class(), AssociationDecayClass::Pinned);
        assert_eq!(a_with(16 << 12).decay_class(), AssociationDecayClass::Slow);
        assert_eq!(
            a_with(32 << 12).decay_class(),
            AssociationDecayClass::Normal
        );
        assert_eq!(a_with(48 << 12).decay_class(), AssociationDecayClass::Fast);
    }

    #[test]
    fn decay_class_scale_gap_sentinels_fall_back_to_pinned() {
        for raw in [1i64, 8, 15, 17, 31, 33, 47, 49, 63] {
            assert_eq!(
                a_with(raw << 12).decay_class(),
                AssociationDecayClass::Pinned
            );
        }
    }

    #[test]
    fn decay_class_ordering_matches_raw_values() {
        assert!(AssociationDecayClass::Pinned < AssociationDecayClass::Slow);
        assert!(AssociationDecayClass::Slow < AssociationDecayClass::Normal);
        assert!(AssociationDecayClass::Normal < AssociationDecayClass::Fast);
    }

    #[test]
    fn arity_field_decodes_correctly() {
        assert_eq!(a_with(0).arity(), AssociationArity::Binary);
        assert_eq!(a_with(1 << 18).arity(), AssociationArity::NAry);
        // Reserved raws 2–3 fall back to Binary.
        assert_eq!(a_with(2 << 18).arity(), AssociationArity::Binary);
        assert_eq!(a_with(3 << 18).arity(), AssociationArity::Binary);
    }

    #[test]
    fn composite_operational_round_trips_all_axes() {
        // signals = co_recall | shared_entity | bits 0,4
        // decay_class = Normal(32)<<12 | arity = NAry(1)<<18
        let raw: i64 = (1 << 0) | (1 << 4) | (32 << 12) | (1 << 18);
        let a = a_with(raw);
        let set = a.signal_sources_seen();
        assert!(set.contains(AssociationSignalSources::CO_RECALL));
        assert!(set.contains(AssociationSignalSources::SHARED_ENTITY));
        assert!(!set.contains(AssociationSignalSources::CO_CONFIRMED));
        assert_eq!(a.decay_class(), AssociationDecayClass::Normal);
        assert_eq!(a.arity(), AssociationArity::NAry);
    }

    #[test]
    fn unknown_bits_above_layout_are_ignored() {
        let a = a_with(i64::MIN);
        // bits 0–19 are zero in i64::MIN (sign bit is bit 63), so every
        // accessor returns the zero-case default and an empty signal set.
        assert_eq!(a.signal_sources_seen().raw_value(), 0);
        assert_eq!(a.decay_class(), AssociationDecayClass::Pinned);
        assert_eq!(a.arity(), AssociationArity::Binary);
    }
}
