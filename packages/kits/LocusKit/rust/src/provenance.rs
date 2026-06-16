//! Provenance bitmap axis types. Ports `Provenance.swift`.
//!
//! Per cookbook §2.5 (v0.36 amendments) and §2.8 (verification table).
//!
//! The provenance bitmap is the third of three Int64 columns each drawer
//! row carries (the first being `adjective_bitmap` per §2.3, the second
//! `operational_bitmap` per §2.4, and this one per §2.5). Where adjective
//! is cross-noun and operational is per-noun-mechanical, provenance
//! records HOW the row came into being and HOW it has been reviewed since.
//!
//! ## Provenance bitmap layout (cookbook §2.5 v0.6, low-to-high)
//!
//! ```text
//! bits 0–5    source_type            (contiguous, 10 cases at raw 0..9)
//! bits 6–11   channel                (contiguous with gaps)
//! bits 12–17  capture_channel        (mirrors operational §2.4)
//! bits 18–23  confirmation           (contiguous, 5 cases at raw 0..4)
//! bits 24–29  confidence             (scale-gapped, 0/16/32/48/56)
//! bits 30–35  sensitivity_at_capture (scale-gapped, mirrors adjective sensitivity)
//! bits 36–41  enrichment_status      (contiguous, 5 cases at raw 0..4)
//! bits 42–63  reserved
//! ```
//!
//! F13 cascade (2026-05-27): bumped from v0.35 4-bit-floor layout to
//! cookbook v0.6 6-bit-floor with vocabulary rewrites. See
//! `Provenance.swift` header for the full migration log.
//!
//! `CaptureChannel` is re-exported from `drawer_operational` (cookbook
//! §2.5 says the bits 12–17 field "mirrors" the operational §2.4
//! capture_channel — same enum, same raws).

pub use crate::drawer_operational::CaptureChannel;

// ============================================================
// SourceType (cookbook §2.5 bits 0-5)
// ============================================================

/// Source type axis — how the content originated.
/// Lives in bits 0–5 of the drawer's `provenance` bitmap (6 bits, 64
/// values; 10 used, 54 reserved). Per cookbook §2.5.
///
/// F13 cascade (2026-05-27): vocab restructured. v0.35 cases `Unknown`,
/// `UserStated`, `ModelInferred`, `ExternalDoc`, `Instruction` removed
/// or remapped. NEW raws 5–9 added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum SourceType {
    /// Raw 0 — content supplied by the user directly. F13: replaces
    /// v0.35 `Unknown` (raw 0) and `UserStated` (raw 2). Default fallback.
    User = 0,
    /// Raw 1 — substrate observed the content.
    Observed = 1,
    /// Raw 2 — imported from an external corpus or file. F13: subsumes
    /// v0.35 `ExternalDoc`.
    Imported = 2,
    /// Raw 3 — substrate-blessed canonical reference (NEW in v0.6).
    Canonical = 3,
    /// Raw 4 — derived from existing content. F13: subsumes v0.35
    /// `ModelInferred`.
    Derived = 4,
    /// Raw 5 — aggregated across estate boundary (NEW in v0.6 §7.4).
    FederationAggregate = 5,
    /// Raw 6 — aggregated across tier (NEW in v0.6 case 3).
    TierAggregate = 6,
    /// Raw 7 — paired-estate content (NEW in v0.6 case 1).
    PairedEstate = 7,
    /// Raw 8 — AmbientSample noun type (NEW in v0.6 §2.5).
    Ambient = 8,
    /// Raw 9 — actuator-originated content (NEW in v0.6 case 2).
    Actuator = 9,
}

impl SourceType {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `SourceType::User` for unrecognised
    /// raw values — `user` is the v0.6 default fallback per cookbook §2.5.
    pub fn from_raw(v: i64) -> SourceType {
        match v {
            0 => SourceType::User,
            1 => SourceType::Observed,
            2 => SourceType::Imported,
            3 => SourceType::Canonical,
            4 => SourceType::Derived,
            5 => SourceType::FederationAggregate,
            6 => SourceType::TierAggregate,
            7 => SourceType::PairedEstate,
            8 => SourceType::Ambient,
            9 => SourceType::Actuator,
            // Raw values 10–63 are reserved for future additions.
            _ => SourceType::User,
        }
    }
}

// ============================================================
// Channel (cookbook §2.5 bits 6-11)
// ============================================================

/// Channel axis — the system surface the content arrived on.
/// Lives in bits 6–11 of `provenance` (6 bits per cookbook §2.5).
///
/// F13 vocab pivot from messaging-platform-focused v0.35 to
/// system-surface-focused v0.6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum Channel {
    UiTyped = 0,
    UiVoiced = 1,
    McpAgent = 2,
    FileImport = 3,
    ApiGrounding = 4,
    FederationInbound = 5,
    DreamProposal = 6,
    DreamAssociation = 7,
    DreamMiningResult = 8,
    // raws 9–14 reserved per cookbook §2.5
    DeviceSensor = 15, // NEW
    ActuatorOutcome = 16, // NEW
                       // raws 17–63 reserved
}

impl Channel {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Channel::UiTyped` (v0.6 default
    /// fallback) for unrecognised raw values (including reserved-gap
    /// raws 9–14 and 17–63).
    pub fn from_raw(v: i64) -> Channel {
        match v {
            0 => Channel::UiTyped,
            1 => Channel::UiVoiced,
            2 => Channel::McpAgent,
            3 => Channel::FileImport,
            4 => Channel::ApiGrounding,
            5 => Channel::FederationInbound,
            6 => Channel::DreamProposal,
            7 => Channel::DreamAssociation,
            8 => Channel::DreamMiningResult,
            15 => Channel::DeviceSensor,
            16 => Channel::ActuatorOutcome,
            _ => Channel::UiTyped,
        }
    }
}

// ============================================================
// Confirmation (cookbook §2.5 bits 18-23)
// ============================================================

/// Confirmation axis — review status. Lives in bits 18–23 of
/// `provenance` (6 bits per cookbook §2.5).
///
/// F13 rename from `ConfirmationState`. Misplaced v0.35 state cases
/// (`Contested`, `Superseded`, `Tombstoned`) removed — those belong
/// in the adjective bitmap's State field, not on the confirmation axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum Confirmation {
    Unconfirmed = 0,
    UserConfirmed = 1,
    AutomatedConfirmed = 2, // F13: was v0.35 `ModelConfirmed`
    PeerConfirmed = 3,      // NEW: cross-estate confirmation
    ActuatorConfirmed = 4,  // NEW
                            // raws 5–63 reserved
}

impl Confirmation {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Confirmation::Unconfirmed` for
    /// unrecognised raw values so retrieval-layer filters that exclude
    /// unconfirmed content fail closed rather than open.
    pub fn from_raw(v: i64) -> Confirmation {
        match v {
            0 => Confirmation::Unconfirmed,
            1 => Confirmation::UserConfirmed,
            2 => Confirmation::AutomatedConfirmed,
            3 => Confirmation::PeerConfirmed,
            4 => Confirmation::ActuatorConfirmed,
            _ => Confirmation::Unconfirmed,
        }
    }
}

// ============================================================
// Confidence (cookbook §2.5 bits 24-29)
// ============================================================

/// Confidence axis — system posterior. Lives in bits 24–29 of
/// `provenance` (6 bits scale-gapped per cookbook §2.5).
///
/// F13 raw-value rewrite: v0.35 had 7 contiguous cases (Unknown=0
/// through Certain=6); cookbook v0.6 has 5 scale-gapped cases.
/// `Ord` is derived so retrieval-layer filters like "confidence >=
/// Medium" compose without raw-value math.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(i64)]
pub enum Confidence {
    Null = 0, // F13: was `Unknown` in v0.35
    Low = 16,
    Medium = 32,
    High = 48,
    Verified = 56, // F13: was `Certain` in v0.35
}

impl Confidence {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Confidence::Null` for unrecognised
    /// raw values (including the scale gaps between cookbook §2.5 raws
    /// 0/16/32/48/56).
    pub fn from_raw(v: i64) -> Confidence {
        match v {
            0 => Confidence::Null,
            16 => Confidence::Low,
            32 => Confidence::Medium,
            48 => Confidence::High,
            56 => Confidence::Verified,
            _ => Confidence::Null,
        }
    }
}

// ============================================================
// Sensitivity (cookbook §2.5 bits 30-35)
// ============================================================

/// Sensitivity at capture — per-drawer access posture frozen at the
/// moment of capture. Lives in bits 30–35 of `provenance` (6 bits
/// scale-gapped per cookbook §2.5; mirrors adjective sensitivity raws).
///
/// F13 raw-value rewrite: v0.35 contiguous 0/1/2/3 → v0.6 scale-gapped
/// 0/16/32/48 to mirror `AdjectiveSensitivity`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum Sensitivity {
    Normal = 0,
    Elevated = 16,
    Restricted = 32,
    Secret = 48,
}

impl Sensitivity {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Sensitivity::Normal` for
    /// unrecognised raw values, matching the estate-level default.
    pub fn from_raw(v: i64) -> Sensitivity {
        match v {
            0 => Sensitivity::Normal,
            16 => Sensitivity::Elevated,
            32 => Sensitivity::Restricted,
            48 => Sensitivity::Secret,
            _ => Sensitivity::Normal,
        }
    }
}

// ============================================================
// EnrichmentStatus (cookbook §2.5 bits 36-41, NEW in v0.6)
// ============================================================

/// Enrichment status — QID resolution lifecycle. Lives in bits 36–41
/// of `provenance` (6 bits per cookbook §2.5). NEW in v0.6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum EnrichmentStatus {
    None = 0,
    QidPending = 1,
    QidCompleted = 2,
    ClosureCached = 3,
    /// Q-ID could not be resolved by deterministic re-inference and an
    /// enrichment proposal has been filed for human/agent review. A
    /// terminal "in workflow" state, NOT passive pending: the maintenance
    /// daemon's `qid_pending` scan does not re-pick these rows. Proposal
    /// acceptance moves the row to `QidCompleted` (cookbook §2.5;
    /// Q-ID-completion terminal workflow).
    QidProposed = 4,
    // raws 5–63 reserved
}

impl EnrichmentStatus {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `EnrichmentStatus::None` for
    /// unrecognised raw values.
    pub fn from_raw(v: i64) -> EnrichmentStatus {
        match v {
            0 => EnrichmentStatus::None,
            1 => EnrichmentStatus::QidPending,
            2 => EnrichmentStatus::QidCompleted,
            3 => EnrichmentStatus::ClosureCached,
            4 => EnrichmentStatus::QidProposed,
            _ => EnrichmentStatus::None,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- SourceType raw values (cookbook §2.5 bits 0-5) ---

    #[test]
    fn source_type_raw_values() {
        assert_eq!(SourceType::User.raw_value(), 0);
        assert_eq!(SourceType::Observed.raw_value(), 1);
        assert_eq!(SourceType::Imported.raw_value(), 2);
        assert_eq!(SourceType::Canonical.raw_value(), 3);
        assert_eq!(SourceType::Derived.raw_value(), 4);
        assert_eq!(SourceType::FederationAggregate.raw_value(), 5);
        assert_eq!(SourceType::TierAggregate.raw_value(), 6);
        assert_eq!(SourceType::PairedEstate.raw_value(), 7);
        assert_eq!(SourceType::Ambient.raw_value(), 8);
        assert_eq!(SourceType::Actuator.raw_value(), 9);
    }

    #[test]
    fn source_type_roundtrip_10_cases() {
        for v in 0i64..=9 {
            assert_eq!(SourceType::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn source_type_reserved_falls_back_to_user() {
        // Raws 10–63 are reserved per cookbook §2.5.
        assert_eq!(SourceType::from_raw(10), SourceType::User);
        assert_eq!(SourceType::from_raw(63), SourceType::User);
        assert_eq!(SourceType::from_raw(-1), SourceType::User);
    }

    // --- Channel raw values (cookbook §2.5 bits 6-11) ---

    #[test]
    fn channel_raw_values() {
        assert_eq!(Channel::UiTyped.raw_value(), 0);
        assert_eq!(Channel::UiVoiced.raw_value(), 1);
        assert_eq!(Channel::McpAgent.raw_value(), 2);
        assert_eq!(Channel::FileImport.raw_value(), 3);
        assert_eq!(Channel::ApiGrounding.raw_value(), 4);
        assert_eq!(Channel::FederationInbound.raw_value(), 5);
        assert_eq!(Channel::DreamProposal.raw_value(), 6);
        assert_eq!(Channel::DreamAssociation.raw_value(), 7);
        assert_eq!(Channel::DreamMiningResult.raw_value(), 8);
        assert_eq!(Channel::DeviceSensor.raw_value(), 15);
        assert_eq!(Channel::ActuatorOutcome.raw_value(), 16);
    }

    #[test]
    fn channel_reserved_gaps_fall_back() {
        // Raws 9–14 + 17–63 are reserved per cookbook §2.5.
        for v in 9i64..=14 {
            assert_eq!(Channel::from_raw(v), Channel::UiTyped);
        }
        assert_eq!(Channel::from_raw(17), Channel::UiTyped);
        assert_eq!(Channel::from_raw(63), Channel::UiTyped);
    }

    // --- Confirmation raw values (cookbook §2.5 bits 18-23) ---

    #[test]
    fn confirmation_raw_values() {
        assert_eq!(Confirmation::Unconfirmed.raw_value(), 0);
        assert_eq!(Confirmation::UserConfirmed.raw_value(), 1);
        assert_eq!(Confirmation::AutomatedConfirmed.raw_value(), 2);
        assert_eq!(Confirmation::PeerConfirmed.raw_value(), 3);
        assert_eq!(Confirmation::ActuatorConfirmed.raw_value(), 4);
    }

    #[test]
    fn confirmation_roundtrip_5_cases() {
        for v in 0i64..=4 {
            assert_eq!(Confirmation::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn confirmation_reserved_falls_back() {
        // Raws 5–63 reserved.
        assert_eq!(Confirmation::from_raw(5), Confirmation::Unconfirmed);
        assert_eq!(Confirmation::from_raw(63), Confirmation::Unconfirmed);
    }

    // --- Confidence raw values (cookbook §2.5 bits 24-29, scale-gapped) ---

    #[test]
    fn confidence_raw_values_scale_gapped() {
        assert_eq!(Confidence::Null.raw_value(), 0);
        assert_eq!(Confidence::Low.raw_value(), 16);
        assert_eq!(Confidence::Medium.raw_value(), 32);
        assert_eq!(Confidence::High.raw_value(), 48);
        assert_eq!(Confidence::Verified.raw_value(), 56);
    }

    #[test]
    fn confidence_roundtrip_5_cases() {
        for v in [0i64, 16, 32, 48, 56] {
            assert_eq!(Confidence::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn confidence_scale_gap_values_fall_back() {
        // The scale gaps between named raws fall back to Null per cookbook §2.5.
        assert_eq!(Confidence::from_raw(1), Confidence::Null);
        assert_eq!(Confidence::from_raw(15), Confidence::Null);
        assert_eq!(Confidence::from_raw(17), Confidence::Null);
        assert_eq!(Confidence::from_raw(63), Confidence::Null);
    }

    #[test]
    fn confidence_ord_preserves_scale() {
        assert!(Confidence::Null < Confidence::Low);
        assert!(Confidence::Low < Confidence::Medium);
        assert!(Confidence::Medium < Confidence::High);
        assert!(Confidence::High < Confidence::Verified);
        assert!(Confidence::Verified > Confidence::Null);
    }

    #[test]
    fn confidence_filter_example() {
        let values = [
            Confidence::Null,
            Confidence::Low,
            Confidence::Medium,
            Confidence::High,
            Confidence::Verified,
        ];
        let filtered: Vec<_> = values
            .iter()
            .filter(|&&c| c >= Confidence::Medium)
            .collect();
        assert_eq!(filtered.len(), 3); // Medium, High, Verified
    }

    // --- Sensitivity raw values (cookbook §2.5 bits 30-35, scale-gapped) ---

    #[test]
    fn sensitivity_raw_values_scale_gapped() {
        assert_eq!(Sensitivity::Normal.raw_value(), 0);
        assert_eq!(Sensitivity::Elevated.raw_value(), 16);
        assert_eq!(Sensitivity::Restricted.raw_value(), 32);
        assert_eq!(Sensitivity::Secret.raw_value(), 48);
    }

    #[test]
    fn sensitivity_scale_gap_values_fall_back() {
        assert_eq!(Sensitivity::from_raw(1), Sensitivity::Normal);
        assert_eq!(Sensitivity::from_raw(63), Sensitivity::Normal);
    }

    // --- EnrichmentStatus (cookbook §2.5 bits 36-41) ---

    #[test]
    fn enrichment_status_raw_values() {
        assert_eq!(EnrichmentStatus::None.raw_value(), 0);
        assert_eq!(EnrichmentStatus::QidPending.raw_value(), 1);
        assert_eq!(EnrichmentStatus::QidCompleted.raw_value(), 2);
        assert_eq!(EnrichmentStatus::ClosureCached.raw_value(), 3);
        assert_eq!(EnrichmentStatus::QidProposed.raw_value(), 4);
    }

    #[test]
    fn enrichment_status_roundtrip_5_cases() {
        for v in 0i64..=4 {
            assert_eq!(EnrichmentStatus::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn enrichment_status_reserved_falls_back() {
        assert_eq!(EnrichmentStatus::from_raw(5), EnrichmentStatus::None);
        assert_eq!(EnrichmentStatus::from_raw(63), EnrichmentStatus::None);
    }
}
