//! Cookbook §2.5 + §2.8 verification-table conformance gate for the
//! Drawer provenance bitmap constants LocusKit owns: SourceType,
//! Channel, CaptureChannel (mirrored from operational §2.4),
//! Confirmation, Confidence, Sensitivity, EnrichmentStatus.
//!
//! Mirror of `Tests/LocusKitTests/ProvenanceBitmapConformanceTests.swift`.
//!
//! Cookbook §2.8: "Implementations MUST surface this table as an
//! automated conformance test that fails when a source constant
//! deviates from spec." When this test fails, the failure message
//! names the specific (constant, expected, actual) triple so the diff
//! against the cookbook is immediate.
//!
//! F13 cascade (2026-05-27): added after the v0.6 vocab + raw-value
//! migration.

use locus_kit::provenance::{
    Channel, Confidence, Confirmation, EnrichmentStatus, Sensitivity, SourceType,
};

// ============================================================
// SourceType (cookbook §2.5 bits 0-5)
// ============================================================

const SOURCE_TYPE_TABLE: &[(SourceType, i64)] = &[
    (SourceType::User, 0),
    (SourceType::Observed, 1),
    (SourceType::Imported, 2),
    (SourceType::Canonical, 3),
    (SourceType::Derived, 4),
    (SourceType::FederationAggregate, 5),
    (SourceType::TierAggregate, 6),
    (SourceType::PairedEstate, 7),
    (SourceType::Ambient, 8),
    (SourceType::Actuator, 9),
];

#[test]
fn source_type_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(source, expected) in SOURCE_TYPE_TABLE {
        if source.raw_value() != expected {
            mismatches.push(format!(
                "SourceType::{:?} expected raw={}, got {}",
                source,
                expected,
                source.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "SourceType diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn source_type_field_position_bits_0_5() {
    for &(source, expected) in SOURCE_TYPE_TABLE {
        let bitmap: i64 = expected; // bits 0-5
        let extracted = bitmap & 0x3F;
        assert_eq!(
            SourceType::from_raw(extracted),
            source,
            "provenance={} should decode to {:?}",
            bitmap,
            source
        );
    }
}

// ============================================================
// Channel (cookbook §2.5 bits 6-11)
// ============================================================

const CHANNEL_TABLE: &[(Channel, i64)] = &[
    (Channel::UiTyped, 0),
    (Channel::UiVoiced, 1),
    (Channel::McpAgent, 2),
    (Channel::FileImport, 3),
    (Channel::ApiGrounding, 4),
    (Channel::FederationInbound, 5),
    (Channel::DreamProposal, 6),
    (Channel::DreamAssociation, 7),
    (Channel::DreamMiningResult, 8),
    (Channel::DeviceSensor, 15),
    (Channel::ActuatorOutcome, 16),
];

#[test]
fn channel_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(channel, expected) in CHANNEL_TABLE {
        if channel.raw_value() != expected {
            mismatches.push(format!(
                "Channel::{:?} expected raw={}, got {}",
                channel,
                expected,
                channel.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "Channel diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn channel_field_position_bits_6_11() {
    for &(channel, expected) in CHANNEL_TABLE {
        let bitmap: i64 = expected << 6;
        let extracted = (bitmap >> 6) & 0x3F;
        assert_eq!(
            Channel::from_raw(extracted),
            channel,
            "provenance={} ({} << 6) should decode to {:?}",
            bitmap,
            expected,
            channel
        );
    }
}

// ============================================================
// Confirmation (cookbook §2.5 bits 18-23)
// ============================================================

const CONFIRMATION_TABLE: &[(Confirmation, i64)] = &[
    (Confirmation::Unconfirmed, 0),
    (Confirmation::UserConfirmed, 1),
    (Confirmation::AutomatedConfirmed, 2),
    (Confirmation::PeerConfirmed, 3),
    (Confirmation::ActuatorConfirmed, 4),
];

#[test]
fn confirmation_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(confirmation, expected) in CONFIRMATION_TABLE {
        if confirmation.raw_value() != expected {
            mismatches.push(format!(
                "Confirmation::{:?} expected raw={}, got {}",
                confirmation,
                expected,
                confirmation.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "Confirmation diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn confirmation_field_position_bits_18_23() {
    for &(confirmation, expected) in CONFIRMATION_TABLE {
        let bitmap: i64 = expected << 18;
        let extracted = (bitmap >> 18) & 0x3F;
        assert_eq!(
            Confirmation::from_raw(extracted),
            confirmation,
            "provenance={} ({} << 18) should decode to {:?}",
            bitmap,
            expected,
            confirmation
        );
    }
}

// ============================================================
// Confidence (cookbook §2.5 bits 24-29, scale-gapped)
// ============================================================

const CONFIDENCE_TABLE: &[(Confidence, i64)] = &[
    (Confidence::Null, 0),
    (Confidence::Low, 16),
    (Confidence::Medium, 32),
    (Confidence::High, 48),
    (Confidence::Verified, 56),
];

#[test]
fn confidence_raw_values_scale_gapped_per_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(confidence, expected) in CONFIDENCE_TABLE {
        if confidence.raw_value() != expected {
            mismatches.push(format!(
                "Confidence::{:?} expected raw={}, got {}",
                confidence,
                expected,
                confidence.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "Confidence diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn confidence_field_position_bits_24_29() {
    for &(confidence, expected) in CONFIDENCE_TABLE {
        let bitmap: i64 = expected << 24;
        let extracted = (bitmap >> 24) & 0x3F;
        assert_eq!(
            Confidence::from_raw(extracted),
            confidence,
            "provenance={} ({} << 24) should decode to {:?}",
            bitmap,
            expected,
            confidence
        );
    }
}

// ============================================================
// Sensitivity (cookbook §2.5 bits 30-35, scale-gapped, mirrors adjective)
// ============================================================

const SENSITIVITY_TABLE: &[(Sensitivity, i64)] = &[
    (Sensitivity::Normal, 0),
    (Sensitivity::Elevated, 16),
    (Sensitivity::Restricted, 32),
    (Sensitivity::Secret, 48),
];

#[test]
fn sensitivity_raw_values_mirror_adjective_per_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(sensitivity, expected) in SENSITIVITY_TABLE {
        if sensitivity.raw_value() != expected {
            mismatches.push(format!(
                "Sensitivity::{:?} expected raw={}, got {}",
                sensitivity,
                expected,
                sensitivity.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "Sensitivity diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn sensitivity_field_position_bits_30_35() {
    for &(sensitivity, expected) in SENSITIVITY_TABLE {
        let bitmap: i64 = expected << 30;
        let extracted = (bitmap >> 30) & 0x3F;
        assert_eq!(
            Sensitivity::from_raw(extracted),
            sensitivity,
            "provenance={} ({} << 30) should decode to {:?}",
            bitmap,
            expected,
            sensitivity
        );
    }
}

// ============================================================
// EnrichmentStatus (cookbook §2.5 bits 36-41, NEW in v0.6)
// ============================================================

const ENRICHMENT_TABLE: &[(EnrichmentStatus, i64)] = &[
    (EnrichmentStatus::None, 0),
    (EnrichmentStatus::QidPending, 1),
    (EnrichmentStatus::QidCompleted, 2),
    (EnrichmentStatus::ClosureCached, 3),
    (EnrichmentStatus::QidProposed, 4),
];

#[test]
fn enrichment_status_raw_values_match_cookbook() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(enrichment, expected) in ENRICHMENT_TABLE {
        if enrichment.raw_value() != expected {
            mismatches.push(format!(
                "EnrichmentStatus::{:?} expected raw={}, got {}",
                enrichment,
                expected,
                enrichment.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "EnrichmentStatus diverges from cookbook §2.5:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn enrichment_status_field_position_bits_36_41() {
    for &(enrichment, expected) in ENRICHMENT_TABLE {
        let bitmap: i64 = expected << 36;
        let extracted = (bitmap >> 36) & 0x3F;
        assert_eq!(
            EnrichmentStatus::from_raw(extracted),
            enrichment,
            "provenance={} ({} << 36) should decode to {:?}",
            bitmap,
            expected,
            enrichment
        );
    }
}

// ============================================================
// Full composite — all six axes simultaneously
// ============================================================

#[test]
fn composite_provenance_roundtrip() {
    let raw: i64 = SourceType::Observed.raw_value()
        | (Channel::McpAgent.raw_value() << 6)
        | (Confirmation::UserConfirmed.raw_value() << 18)
        | (Confidence::High.raw_value() << 24)
        | (Sensitivity::Elevated.raw_value() << 30)
        | (EnrichmentStatus::QidCompleted.raw_value() << 36);

    assert_eq!(SourceType::from_raw(raw & 0x3F), SourceType::Observed);
    assert_eq!(Channel::from_raw((raw >> 6) & 0x3F), Channel::McpAgent);
    assert_eq!(
        Confirmation::from_raw((raw >> 18) & 0x3F),
        Confirmation::UserConfirmed
    );
    assert_eq!(Confidence::from_raw((raw >> 24) & 0x3F), Confidence::High);
    assert_eq!(
        Sensitivity::from_raw((raw >> 30) & 0x3F),
        Sensitivity::Elevated
    );
    assert_eq!(
        EnrichmentStatus::from_raw((raw >> 36) & 0x3F),
        EnrichmentStatus::QidCompleted
    );
}
