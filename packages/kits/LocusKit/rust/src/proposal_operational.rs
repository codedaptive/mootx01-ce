//! Proposal operational value types. Ports `ProposalOperational.swift`.
//!
//! Per cookbook §2.4 ("Proposal operational", v0.36, 6-bit floor).
//!
//! Five typed axes describe what a proposal proposes and how it was
//! generated. They pack into the low 30 bits of
//! `Proposal::operational_bitmap`:
//!
//! ```text
//! bits 0–5   ProposalKind                (contiguous, raws 0..8)
//! bits 6–11  ProposalTargetObjectType    (contiguous, raws 0..6)
//! bits 12–17 ProposalConfirmationSource  (contiguous, raws 0..3)
//! bits 18–23 ProposalGeneratedByClass    (contiguous, raws 0..4)
//! bits 24–29 ProposalConfidenceBucket    (scale-gapped, raws 0/8/16/32/48)
//! bits 30–63 reserved
//! ```
//!
//! Named-enum accessors decode each axis from a single i64 column with
//! a safe fallback to the zero case for unrecognised raw values
//! (including the intentional scale-gap sentinels of the confidence
//! bucket).

use crate::proposal::Proposal;
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

// MARK: - ProposalKind

/// What kind of write this proposal proposes. Per cookbook §2.4 bits
/// 0–5. Contiguous encoding: 9 used (raws 0..8), the rest reserved
/// within the 6-bit field.
///
/// Distinct from `genius-locus-kit`'s Brain-layer `ProposalKind` (the
/// routing-queue signal labels) — this is the substrate row's kind
/// axis from cookbook §2.4, a different vocabulary at a different
/// altitude.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum ProposalKind {
    NewTunnel = 0,
    MutateDrawer = 1,
    WithdrawDrawer = 2,
    NewKGFact = 3,
    AssociationPromotion = 4,
    MiningPatternAdjustment = 5,
    ActionProposal = 6,
    RecordObservation = 7,
    TierAdvisory = 8,
}

impl ProposalKind {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 6-bit slice. Returns `NewTunnel` for unrecognised
    /// raw values (raws 9–63 reserved).
    pub fn from_raw(v: i64) -> ProposalKind {
        match v {
            0 => ProposalKind::NewTunnel,
            1 => ProposalKind::MutateDrawer,
            2 => ProposalKind::WithdrawDrawer,
            3 => ProposalKind::NewKGFact,
            4 => ProposalKind::AssociationPromotion,
            5 => ProposalKind::MiningPatternAdjustment,
            6 => ProposalKind::ActionProposal,
            7 => ProposalKind::RecordObservation,
            8 => ProposalKind::TierAdvisory,
            _ => ProposalKind::NewTunnel,
        }
    }
}

// MARK: - ProposalTargetObjectType

/// The kind of row this proposal targets. Per cookbook §2.4 bits 6–11.
/// Contiguous encoding; 7 used (raws 0..6).
///
/// `NoneBrandNew` marks a proposal that creates a row not yet in the
/// substrate (e.g. a `NewTunnel` proposal), where `target_row_id` is
/// empty. `SystemState` (case 2) targets the estate's own state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum ProposalTargetObjectType {
    Drawer = 0,
    Tunnel = 1,
    Kgfact = 2,
    Association = 3,
    NoneBrandNew = 4,
    AmbientSample = 5,
    SystemState = 6,
}

impl ProposalTargetObjectType {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 6-bit slice. Returns `Drawer` for unrecognised raw
    /// values (raws 7–63 reserved).
    pub fn from_raw(v: i64) -> ProposalTargetObjectType {
        match v {
            0 => ProposalTargetObjectType::Drawer,
            1 => ProposalTargetObjectType::Tunnel,
            2 => ProposalTargetObjectType::Kgfact,
            3 => ProposalTargetObjectType::Association,
            4 => ProposalTargetObjectType::NoneBrandNew,
            5 => ProposalTargetObjectType::AmbientSample,
            6 => ProposalTargetObjectType::SystemState,
            _ => ProposalTargetObjectType::Drawer,
        }
    }
}

// MARK: - ProposalConfirmationSource

/// Who or what confirms this proposal. Per cookbook §2.4 bits 12–17.
/// Contiguous encoding; 4 used (raws 0..3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum ProposalConfirmationSource {
    Human = 0,
    Agent = 1,
    AutomatedThreshold = 2,
    Actuator = 3,
}

impl ProposalConfirmationSource {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 6-bit slice. Returns `Human` for unrecognised raw
    /// values (raws 4–63 reserved).
    pub fn from_raw(v: i64) -> ProposalConfirmationSource {
        match v {
            0 => ProposalConfirmationSource::Human,
            1 => ProposalConfirmationSource::Agent,
            2 => ProposalConfirmationSource::AutomatedThreshold,
            3 => ProposalConfirmationSource::Actuator,
            _ => ProposalConfirmationSource::Human,
        }
    }
}

// MARK: - ProposalGeneratedByClass

/// What class of producer generated this proposal. Per cookbook §2.4
/// bits 18–23. Contiguous encoding; 5 used (raws 0..4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum ProposalGeneratedByClass {
    DreamingDaemon = 0,
    McpAgent = 1,
    FederationSync = 2,
    Manual = 3,
    TierAggregator = 4,
}

impl ProposalGeneratedByClass {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a 6-bit slice. Returns `DreamingDaemon` for
    /// unrecognised raw values (raws 5–63 reserved).
    pub fn from_raw(v: i64) -> ProposalGeneratedByClass {
        match v {
            0 => ProposalGeneratedByClass::DreamingDaemon,
            1 => ProposalGeneratedByClass::McpAgent,
            2 => ProposalGeneratedByClass::FederationSync,
            3 => ProposalGeneratedByClass::Manual,
            4 => ProposalGeneratedByClass::TierAggregator,
            _ => ProposalGeneratedByClass::DreamingDaemon,
        }
    }
}

// MARK: - ProposalConfidenceBucket

/// Coarse confidence bucket for the proposal. Per cookbook §2.4 bits
/// 24–29. Scale-gapped encoding (raws 0/8/16/32/48) so future
/// intermediate buckets can slot in without disturbing existing
/// equality or ordering masks; every other raw is an intentional
/// sentinel that falls back to `Null`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i64)]
pub enum ProposalConfidenceBucket {
    Null = 0,
    Low = 8,
    Medium = 16,
    High = 32,
    Verified = 48,
}

impl ProposalConfidenceBucket {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn from_raw(v: i64) -> ProposalConfidenceBucket {
        match v {
            0 => ProposalConfidenceBucket::Null,
            8 => ProposalConfidenceBucket::Low,
            16 => ProposalConfidenceBucket::Medium,
            32 => ProposalConfidenceBucket::High,
            48 => ProposalConfidenceBucket::Verified,
            _ => ProposalConfidenceBucket::Null,
        }
    }
}

impl PartialOrd for ProposalConfidenceBucket {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ProposalConfidenceBucket {
    fn cmp(&self, other: &Self) -> Ordering {
        self.raw_value().cmp(&other.raw_value())
    }
}

// MARK: - Proposal accessors

impl Proposal {
    /// Decode bits 0–5 of `operational_bitmap` as a `ProposalKind`.
    pub fn proposal_kind(&self) -> ProposalKind {
        ProposalKind::from_raw(bit_field::extract_field(self.operational_bitmap, 0, 6))
    }

    /// Decode bits 6–11 of `operational_bitmap` as a
    /// `ProposalTargetObjectType`.
    pub fn target_object_type(&self) -> ProposalTargetObjectType {
        ProposalTargetObjectType::from_raw(bit_field::extract_field(self.operational_bitmap, 6, 6))
    }

    /// Decode bits 12–17 of `operational_bitmap` as a
    /// `ProposalConfirmationSource`.
    pub fn confirmation_source(&self) -> ProposalConfirmationSource {
        ProposalConfirmationSource::from_raw(bit_field::extract_field(
            self.operational_bitmap,
            12,
            6,
        ))
    }

    /// Decode bits 18–23 of `operational_bitmap` as a
    /// `ProposalGeneratedByClass`.
    pub fn generated_by_class(&self) -> ProposalGeneratedByClass {
        ProposalGeneratedByClass::from_raw(bit_field::extract_field(self.operational_bitmap, 18, 6))
    }

    /// Decode bits 24–29 of `operational_bitmap` as a
    /// `ProposalConfidenceBucket`. Returns `Null` for the
    /// intentionally-gapped scale sentinels.
    pub fn confidence_bucket(&self) -> ProposalConfidenceBucket {
        ProposalConfidenceBucket::from_raw(bit_field::extract_field(self.operational_bitmap, 24, 6))
    }
}

/// Compose a proposal `operational_bitmap` from its four typed axes per
/// cookbook §2.4 (kind 0–5, target object type 6–11, generated-by class
/// 18–23, confidence bucket 24–29; confirmation source 12–17 is left at its
/// zero case `Human` until a confirmation step runs). Field placement goes
/// through the conformance-gated `bit_field::write_field` primitive — never
/// hand-rolled shift/mask math. Mirrors Swift `Proposal.composeOperational`.
/// Used by the autonomic daemon sinks to stamp genuine provenance on the
/// proposals they emit.
pub fn compose_operational(
    kind: ProposalKind,
    target_object_type: ProposalTargetObjectType,
    generated_by: ProposalGeneratedByClass,
    confidence: ProposalConfidenceBucket,
) -> i64 {
    let mut bits: i64 = 0;
    bits = bit_field::write_field(kind.raw_value(), bits, 0, 6);
    bits = bit_field::write_field(target_object_type.raw_value(), bits, 6, 6);
    bits = bit_field::write_field(generated_by.raw_value(), bits, 18, 6);
    bits = bit_field::write_field(confidence.raw_value(), bits, 24, 6);
    bits
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::estate_types::LatticeAnchor;

    fn p_with(bits: i64) -> Proposal {
        let mut p = Proposal::new(
            "p".to_string(),
            "d".to_string(),
            LatticeAnchor::udc("547"),
            0,
        );
        p.operational_bitmap = bits;
        p
    }

    #[test]
    fn proposal_kind_decodes_low_six_bits() {
        for (raw, expected) in [
            (0, ProposalKind::NewTunnel),
            (1, ProposalKind::MutateDrawer),
            (2, ProposalKind::WithdrawDrawer),
            (3, ProposalKind::NewKGFact),
            (4, ProposalKind::AssociationPromotion),
            (5, ProposalKind::MiningPatternAdjustment),
            (6, ProposalKind::ActionProposal),
            (7, ProposalKind::RecordObservation),
            (8, ProposalKind::TierAdvisory),
        ] {
            assert_eq!(p_with(raw).proposal_kind(), expected);
        }
    }

    #[test]
    fn proposal_kind_reserved_raws_fall_back_to_new_tunnel() {
        for raw in 9..=63i64 {
            assert_eq!(p_with(raw).proposal_kind(), ProposalKind::NewTunnel);
        }
    }

    #[test]
    fn target_object_type_decodes_bits_six_through_eleven() {
        for (raw, expected) in [
            (0, ProposalTargetObjectType::Drawer),
            (1, ProposalTargetObjectType::Tunnel),
            (2, ProposalTargetObjectType::Kgfact),
            (3, ProposalTargetObjectType::Association),
            (4, ProposalTargetObjectType::NoneBrandNew),
            (5, ProposalTargetObjectType::AmbientSample),
            (6, ProposalTargetObjectType::SystemState),
        ] {
            assert_eq!(p_with(raw << 6).target_object_type(), expected);
        }
        // Reserved raw 7 falls back to Drawer.
        assert_eq!(
            p_with(7 << 6).target_object_type(),
            ProposalTargetObjectType::Drawer
        );
    }

    #[test]
    fn confirmation_source_decodes_bits_twelve_through_seventeen() {
        assert_eq!(
            p_with(0).confirmation_source(),
            ProposalConfirmationSource::Human
        );
        assert_eq!(
            p_with(1 << 12).confirmation_source(),
            ProposalConfirmationSource::Agent
        );
        assert_eq!(
            p_with(2 << 12).confirmation_source(),
            ProposalConfirmationSource::AutomatedThreshold
        );
        assert_eq!(
            p_with(3 << 12).confirmation_source(),
            ProposalConfirmationSource::Actuator
        );
        assert_eq!(
            p_with(4 << 12).confirmation_source(),
            ProposalConfirmationSource::Human
        );
    }

    #[test]
    fn generated_by_class_decodes_bits_eighteen_through_twenty_three() {
        assert_eq!(
            p_with(0).generated_by_class(),
            ProposalGeneratedByClass::DreamingDaemon
        );
        assert_eq!(
            p_with(1 << 18).generated_by_class(),
            ProposalGeneratedByClass::McpAgent
        );
        assert_eq!(
            p_with(2 << 18).generated_by_class(),
            ProposalGeneratedByClass::FederationSync
        );
        assert_eq!(
            p_with(3 << 18).generated_by_class(),
            ProposalGeneratedByClass::Manual
        );
        assert_eq!(
            p_with(4 << 18).generated_by_class(),
            ProposalGeneratedByClass::TierAggregator
        );
        assert_eq!(
            p_with(5 << 18).generated_by_class(),
            ProposalGeneratedByClass::DreamingDaemon
        );
    }

    #[test]
    fn confidence_bucket_decodes_scale_gapped_raws() {
        assert_eq!(
            p_with(0).confidence_bucket(),
            ProposalConfidenceBucket::Null
        );
        assert_eq!(
            p_with(8 << 24).confidence_bucket(),
            ProposalConfidenceBucket::Low
        );
        assert_eq!(
            p_with(16 << 24).confidence_bucket(),
            ProposalConfidenceBucket::Medium
        );
        assert_eq!(
            p_with(32 << 24).confidence_bucket(),
            ProposalConfidenceBucket::High
        );
        assert_eq!(
            p_with(48 << 24).confidence_bucket(),
            ProposalConfidenceBucket::Verified
        );
    }

    #[test]
    fn confidence_bucket_scale_gap_sentinels_fall_back_to_null() {
        for raw in [1i64, 2, 4, 7, 9, 15, 17, 31, 33, 47, 49, 63] {
            assert_eq!(
                p_with(raw << 24).confidence_bucket(),
                ProposalConfidenceBucket::Null
            );
        }
    }

    #[test]
    fn confidence_bucket_ordering_matches_raw_values() {
        assert!(ProposalConfidenceBucket::Null < ProposalConfidenceBucket::Low);
        assert!(ProposalConfidenceBucket::Low < ProposalConfidenceBucket::Medium);
        assert!(ProposalConfidenceBucket::Medium < ProposalConfidenceBucket::High);
        assert!(ProposalConfidenceBucket::High < ProposalConfidenceBucket::Verified);
    }

    #[test]
    fn composite_operational_round_trips_all_axes() {
        // kind=MutateDrawer(1) | target=Tunnel(1)<<6 | confirm=Agent(1)<<12
        // | genby=Manual(3)<<18 | confidence=High(32)<<24
        let raw: i64 = 1 | (1 << 6) | (1 << 12) | (3 << 18) | (32 << 24);
        let p = p_with(raw);
        assert_eq!(p.proposal_kind(), ProposalKind::MutateDrawer);
        assert_eq!(p.target_object_type(), ProposalTargetObjectType::Tunnel);
        assert_eq!(p.confirmation_source(), ProposalConfirmationSource::Agent);
        assert_eq!(p.generated_by_class(), ProposalGeneratedByClass::Manual);
        assert_eq!(p.confidence_bucket(), ProposalConfidenceBucket::High);
    }
}
