//! KGFact operational value types. Ports `KGFactOperational.swift`.
//!
//! Per `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 5.6.
//!
//! Four typed axes plus one flag describe how a fact was extracted and
//! how strongly it is asserted. They pack into the low 14 bits of
//! `KGFact::operational_bitmap`:
//!
//! ```text
//! bits 0–3   KGExtractorClass   (contiguous, 6 cases at raw 0..5)
//! bits 4–6   KGAssertionKind    (contiguous, 4 cases at raw 0..3)
//! bits 7–9   KGSpecificity      (scale-gapped, raws 0/2/4/6)
//! bits 10–12 KGConfidenceBand   (scale-gapped, raws 0/1/2/4/6)
//! bit  13    is_canonical       (1 bit, exclusive)
//! bits 14–63 reserved
//! ```
//!
//! Named-enum accessors decode each axis from a single i64 column with
//! a safe fallback to the zero case for unrecognised raw values
//! (including the intentional scale-gap sentinels — raws 1, 3, 5 for
//! specificity; raws 3, 5 for confidence band).

use crate::kg_fact::KGFact;
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

// MARK: - KGExtractorClass

/// What kind of extractor produced this fact. Per spec § 5.6.
/// Contiguous encoding: 6 used, 10 reserved within the 4-bit field.
///
/// The cases form a rough rigour ladder — `Manual` is human-asserted,
/// `FoundationModel` is general-purpose LLM extraction,
/// `SpecializedModel` is a domain-tuned extractor, `RulesBased` is
/// deterministic pattern matching, `ImportedKG` is content lifted
/// from an external knowledge graph, and `Federated` is a fact
/// replicated from another estate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum KGExtractorClass {
    Manual = 0,
    FoundationModel = 1,
    SpecializedModel = 2,
    RulesBased = 3,
    ImportedKG = 4,
    Federated = 5,
}

impl KGExtractorClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from the low 4 bits. Returns `Manual` for unrecognised
    /// raw values (raws 6–15 reserved). Surfacing an unknown future-
    /// version extractor as "human-asserted" makes the fact look more
    /// trustworthy than it should — which is the failure mode we
    /// want: forces a review pass rather than silently downgrading.
    pub fn from_raw(v: i64) -> KGExtractorClass {
        match v {
            0 => KGExtractorClass::Manual,
            1 => KGExtractorClass::FoundationModel,
            2 => KGExtractorClass::SpecializedModel,
            3 => KGExtractorClass::RulesBased,
            4 => KGExtractorClass::ImportedKG,
            5 => KGExtractorClass::Federated,
            _ => KGExtractorClass::Manual,
        }
    }
}

// MARK: - KGAssertionKind

/// How firmly the fact is asserted. Per spec § 5.6. Contiguous
/// encoding; 4 used, 4 reserved.
///
/// `Asserted` is the default (the extractor stands behind the
/// triple). `Inferred` marks derived facts that did not appear
/// verbatim in the source. `Hypothesized` is provisional and
/// downgrades retrieval weight. `Contradicted` records that another
/// fact disputes this one without retracting either — the resolution
/// happens at retrieval time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum KGAssertionKind {
    Asserted = 0,
    Inferred = 1,
    Hypothesized = 2,
    Contradicted = 3,
}

impl KGAssertionKind {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 3-bit slice. Returns `Asserted` for unrecognised
    /// raw values (raws 4–7 reserved).
    pub fn from_raw(v: i64) -> KGAssertionKind {
        match v {
            0 => KGAssertionKind::Asserted,
            1 => KGAssertionKind::Inferred,
            2 => KGAssertionKind::Hypothesized,
            3 => KGAssertionKind::Contradicted,
            _ => KGAssertionKind::Asserted,
        }
    }
}

// MARK: - KGSpecificity

/// How specific the fact's claim is along the entity-to-instance
/// spectrum. Per spec § 5.6. Scale-gapped encoding (raws 0/2/4/6) so
/// future intermediate tiers can slot in without disturbing existing
/// equality or ordering masks. Sentinels at raws 1, 3, 5 are
/// intentionally absent and fall back to `General`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum KGSpecificity {
    General = 0,
    Domain = 2,
    Specific = 4,
    Instance = 6,
}

impl KGSpecificity {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> KGSpecificity {
        match v {
            0 => KGSpecificity::General,
            2 => KGSpecificity::Domain,
            4 => KGSpecificity::Specific,
            6 => KGSpecificity::Instance,
            _ => KGSpecificity::General,
        }
    }
}

impl PartialOrd for KGSpecificity {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for KGSpecificity {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - KGConfidenceBand

/// Coarse confidence band for the fact. Per spec § 5.6. Scale-gapped
/// encoding with one near-zero cluster (`Unknown` / `Low` / `Medium`
/// at raws 0/1/2) and a gap before `High` (raw 4) and `Certain` (raw
/// 6); sentinels at raws 3, 5 are intentionally absent so a future
/// `VeryHigh` tier can slot between `High` and `Certain` without
/// renumbering.
///
/// Distinct from `provenance.rs::Confidence` — that axis describes
/// the *source* of a drawer, this axis describes the *extractor*'s
/// belief in the fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum KGConfidenceBand {
    Unknown = 0,
    Low = 1,
    Medium = 2,
    High = 4,
    Certain = 6,
}

impl KGConfidenceBand {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> KGConfidenceBand {
        match v {
            0 => KGConfidenceBand::Unknown,
            1 => KGConfidenceBand::Low,
            2 => KGConfidenceBand::Medium,
            4 => KGConfidenceBand::High,
            6 => KGConfidenceBand::Certain,
            _ => KGConfidenceBand::Unknown,
        }
    }
}

impl PartialOrd for KGConfidenceBand {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for KGConfidenceBand {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - KGFact accessors

impl KGFact {
    /// Decode bits 0–3 of `operational_bitmap` as a `KGExtractorClass`.
    pub fn extractor_class(&self) -> KGExtractorClass {
        KGExtractorClass::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 4))
    }

    /// Decode bits 4–6 of `operational_bitmap` as a `KGAssertionKind`.
    pub fn assertion_kind(&self) -> KGAssertionKind {
        KGAssertionKind::from_raw(bit_field::extract_field(self.operational_bitmap, 4, 3))
    }

    /// Decode bits 7–9 of `operational_bitmap` as a `KGSpecificity`.
    /// Returns `General` for the intentionally-gapped scale raws (1,
    /// 3, 5, 7).
    pub fn specificity(&self) -> KGSpecificity {
        KGSpecificity::from_raw(bit_field::extract_field(self.operational_bitmap, 7, 3))
    }

    /// Decode bits 10–12 of `operational_bitmap` as a
    /// `KGConfidenceBand`. Returns `Unknown` for the intentionally-
    /// gapped scale raws (3, 5, 7).
    pub fn confidence_band(&self) -> KGConfidenceBand {
        KGConfidenceBand::from_raw(bit_field::extract_field(self.operational_bitmap, 10, 3))
    }

    /// Decode bit 13 of `operational_bitmap`. True when this fact has
    /// been promoted to canonical-to-estate status (a fact every
    /// agent in the estate should treat as load-bearing); false when
    /// it is local to its source drawer.
    pub fn is_canonical(&self) -> bool {
        bit_field::extract_flag(self.operational_bitmap, 13)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f_with(bits: i64) -> KGFact {
        let mut f = KGFact::new(
            "f".to_string(),
            "s".to_string(),
            "p".to_string(),
            "o".to_string(),
            "d".to_string(),
            0,
        );
        f.operational_bitmap = bits;
        f
    }

    #[test]
    fn extractor_class_decodes_low_four_bits() {
        for (raw, expected) in [
            (0, KGExtractorClass::Manual),
            (1, KGExtractorClass::FoundationModel),
            (2, KGExtractorClass::SpecializedModel),
            (3, KGExtractorClass::RulesBased),
            (4, KGExtractorClass::ImportedKG),
            (5, KGExtractorClass::Federated),
        ] {
            assert_eq!(f_with(raw).extractor_class(), expected);
        }
    }

    #[test]
    fn extractor_class_reserved_raws_fall_back_to_manual() {
        for raw in 6..=15i64 {
            assert_eq!(f_with(raw).extractor_class(), KGExtractorClass::Manual);
        }
    }

    #[test]
    fn assertion_kind_decodes_bits_four_through_six() {
        assert_eq!(f_with(0).assertion_kind(), KGAssertionKind::Asserted);
        assert_eq!(f_with(1 << 4).assertion_kind(), KGAssertionKind::Inferred);
        assert_eq!(
            f_with(2 << 4).assertion_kind(),
            KGAssertionKind::Hypothesized
        );
        assert_eq!(
            f_with(3 << 4).assertion_kind(),
            KGAssertionKind::Contradicted
        );
        assert_eq!(f_with(4 << 4).assertion_kind(), KGAssertionKind::Asserted);
    }

    #[test]
    fn specificity_decodes_scale_gapped_raws() {
        assert_eq!(f_with(0).specificity(), KGSpecificity::General);
        assert_eq!(f_with(2 << 7).specificity(), KGSpecificity::Domain);
        assert_eq!(f_with(4 << 7).specificity(), KGSpecificity::Specific);
        assert_eq!(f_with(6 << 7).specificity(), KGSpecificity::Instance);
    }

    #[test]
    fn specificity_scale_gap_sentinels_fall_back_to_general() {
        for raw in [1i64, 3, 5, 7] {
            assert_eq!(f_with(raw << 7).specificity(), KGSpecificity::General);
        }
    }

    #[test]
    fn specificity_ordering_matches_raw_values() {
        assert!(KGSpecificity::General < KGSpecificity::Domain);
        assert!(KGSpecificity::Domain < KGSpecificity::Specific);
        assert!(KGSpecificity::Specific < KGSpecificity::Instance);
    }

    #[test]
    fn confidence_band_decodes_bits_ten_through_twelve() {
        assert_eq!(f_with(0).confidence_band(), KGConfidenceBand::Unknown);
        assert_eq!(f_with(1 << 10).confidence_band(), KGConfidenceBand::Low);
        assert_eq!(f_with(2 << 10).confidence_band(), KGConfidenceBand::Medium);
        assert_eq!(f_with(4 << 10).confidence_band(), KGConfidenceBand::High);
        assert_eq!(f_with(6 << 10).confidence_band(), KGConfidenceBand::Certain);
    }

    #[test]
    fn confidence_band_scale_gap_sentinels_fall_back_to_unknown() {
        for raw in [3i64, 5, 7] {
            assert_eq!(
                f_with(raw << 10).confidence_band(),
                KGConfidenceBand::Unknown
            );
        }
    }

    #[test]
    fn confidence_band_ordering_matches_raw_values() {
        assert!(KGConfidenceBand::Unknown < KGConfidenceBand::Low);
        assert!(KGConfidenceBand::Low < KGConfidenceBand::Medium);
        assert!(KGConfidenceBand::Medium < KGConfidenceBand::High);
        assert!(KGConfidenceBand::High < KGConfidenceBand::Certain);
    }

    #[test]
    fn is_canonical_is_bit_thirteen() {
        assert!(!f_with(0).is_canonical());
        assert!(f_with(1 << 13).is_canonical());
        assert!(!f_with((1 << 14) | (1 << 12)).is_canonical());
    }
}
