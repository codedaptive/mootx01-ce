//! Cookbook §2.8 verification-table conformance gate for the
//! adjective-bitmap constants LocusKit owns: AdjectiveSensitivity,
//! AdjectiveExportability, Trust, and State.
//!
//! Mirror of `Tests/LocusKitTests/AdjectiveBitmapConformanceTests.swift`.
//! Sibling of SubstrateLib's `bitmap_field_constants_conformance.rs`
//! (which covers RowState).
//!
//! Cookbook §2.8: "Implementations MUST surface this table as an
//! automated conformance test that fails when a source constant
//! deviates from spec." When this test fails, the failure message
//! names the specific (constant, expected, actual) triple per §2.8 row
//! so the diff against the cookbook is immediate.
//!
//! F11 cascade (2026-05-27): added after the v0.6 raw-value migration
//! to lock the new constants in place. Any drift from cookbook §2.8
//! MUST fail this test before it ships.

use locus_kit::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};

// ============================================================
// State (cookbook §2.3 / §2.8 rows 1-10)
// ============================================================

const STATE_TABLE: &[(State, i64, usize)] = &[
    (State::Active, 0, 1),
    (State::Pending, 1, 2),
    (State::Contested, 2, 3),
    (State::Accepted, 3, 4),
    (State::Superseded, 16, 5),
    (State::Decayed, 17, 6),
    (State::Withdrawn, 18, 7),
    (State::Expired, 19, 8),
    (State::Rejected, 32, 9),
    (State::Tombstoned, 33, 10),
];

#[test]
fn state_raw_values_match_verification_table() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(state, expected, row) in STATE_TABLE {
        if state.raw_value() != expected {
            mismatches.push(format!(
                "§2.8 row {}: State::{:?} expected raw={}, got {}",
                row,
                state,
                expected,
                state.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "State diverges from cookbook §2.8:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn state_cluster_predicate_resolves_correctly() {
    let cluster_a = [
        State::Active,
        State::Pending,
        State::Contested,
        State::Accepted,
    ];
    let cluster_b = [
        State::Superseded,
        State::Decayed,
        State::Withdrawn,
        State::Expired,
    ];
    let cluster_c = [State::Rejected, State::Tombstoned];
    for s in &cluster_a {
        assert_eq!(
            (s.raw_value() >> 4) & 0x3,
            0,
            "{:?} should be in Cluster A",
            s
        );
    }
    for s in &cluster_b {
        assert_eq!(
            (s.raw_value() >> 4) & 0x3,
            1,
            "{:?} should be in Cluster B",
            s
        );
    }
    for s in &cluster_c {
        assert_eq!(
            (s.raw_value() >> 4) & 0x3,
            2,
            "{:?} should be in Cluster C",
            s
        );
    }
}

// ============================================================
// AdjectiveSensitivity (cookbook §2.3 / §2.8 rows 11-14)
// ============================================================

const SENSITIVITY_TABLE: &[(AdjectiveSensitivity, i64, usize)] = &[
    (AdjectiveSensitivity::Normal, 0, 11),
    (AdjectiveSensitivity::Elevated, 16, 12),
    (AdjectiveSensitivity::Restricted, 32, 13),
    (AdjectiveSensitivity::Secret, 48, 14),
];

#[test]
fn adjective_sensitivity_raw_values_match_verification_table() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(sens, expected, row) in SENSITIVITY_TABLE {
        if sens.raw_value() != expected {
            mismatches.push(format!(
                "§2.8 row {}: AdjectiveSensitivity::{:?} expected raw={}, got {}",
                row,
                sens,
                expected,
                sens.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "AdjectiveSensitivity diverges from cookbook §2.8:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn adjective_sensitivity_field_position() {
    for &(sens, expected, row) in SENSITIVITY_TABLE {
        let bitmap: i64 = expected << 6;
        let extracted = (bitmap >> 6) & 0x3F;
        assert_eq!(
            AdjectiveSensitivity::from_raw(extracted),
            sens,
            "§2.8 row {}: bitmap={} should decode to {:?}",
            row,
            bitmap,
            sens
        );
    }
}

// ============================================================
// AdjectiveExportability (cookbook §2.3 / §2.8 rows 15-16)
// ============================================================

const EXPORTABILITY_TABLE: &[(AdjectiveExportability, i64, usize)] = &[
    (AdjectiveExportability::Private, 0, 15),
    (AdjectiveExportability::Public, 32, 16),
];

#[test]
fn adjective_exportability_raw_values_match_verification_table() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(exp, expected, row) in EXPORTABILITY_TABLE {
        if exp.raw_value() != expected {
            mismatches.push(format!(
                "§2.8 row {}: AdjectiveExportability::{:?} expected raw={}, got {}",
                row,
                exp,
                expected,
                exp.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "AdjectiveExportability diverges from cookbook §2.8:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn adjective_exportability_field_position() {
    for &(exp, expected, row) in EXPORTABILITY_TABLE {
        let bitmap: i64 = expected << 12;
        let extracted = (bitmap >> 12) & 0x3F;
        assert_eq!(
            AdjectiveExportability::from_raw(extracted),
            exp,
            "§2.8 row {}: bitmap={} should decode to {:?}",
            row,
            bitmap,
            exp
        );
    }
}

// ============================================================
// Trust (cookbook §2.3 / §2.8 rows 17-23)
// ============================================================

const TRUST_TABLE: &[(Trust, i64, usize)] = &[
    (Trust::Verbatim, 0, 17),
    (Trust::Observed, 1, 18),
    (Trust::Imported, 2, 19),
    (Trust::Canonical, 3, 20),
    (Trust::Derived, 4, 21),
    (Trust::Proposed, 5, 22),
    (Trust::Ambient, 6, 23), // NEW in v0.6 per cookbook §2.3
];

#[test]
fn trust_raw_values_match_verification_table() {
    let mut mismatches: Vec<String> = Vec::new();
    for &(trust, expected, row) in TRUST_TABLE {
        if trust.raw_value() != expected {
            mismatches.push(format!(
                "§2.8 row {}: Trust::{:?} expected raw={}, got {}",
                row,
                trust,
                expected,
                trust.raw_value()
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "Trust diverges from cookbook §2.8:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn trust_field_position() {
    for &(trust, expected, row) in TRUST_TABLE {
        let bitmap: i64 = expected << 18;
        let extracted = (bitmap >> 18) & 0x3F;
        assert_eq!(
            Trust::from_raw(extracted),
            trust,
            "§2.8 row {}: bitmap={} should decode to {:?}",
            row,
            bitmap,
            trust
        );
    }
}

// ============================================================
// Full composite (all four axes simultaneously)
// ============================================================

/// state=Contested(2) | sensitivity=Elevated(16)<<6 | exportability=Private(0)<<12 | trust=Observed(1)<<18
/// = 2 | 1024 | 0 | 262144 = 263170 = 0x40402.
#[test]
fn composite_four_axis_roundtrip() {
    let raw: i64 = State::Contested.raw_value()
        | (AdjectiveSensitivity::Elevated.raw_value() << 6)
        | (AdjectiveExportability::Private.raw_value() << 12)
        | (Trust::Observed.raw_value() << 18);
    assert_eq!(
        raw, 0x40402,
        "composite encoding mismatch: {} != 0x40402",
        raw
    );

    assert_eq!(State::from_raw(raw & 0x3F), State::Contested);
    assert_eq!(
        AdjectiveSensitivity::from_raw((raw >> 6) & 0x3F),
        AdjectiveSensitivity::Elevated
    );
    assert_eq!(
        AdjectiveExportability::from_raw((raw >> 12) & 0x3F),
        AdjectiveExportability::Private
    );
    assert_eq!(Trust::from_raw((raw >> 18) & 0x3F), Trust::Observed);
}

// ============================================================
// dreaming_recalc_required (cookbook §2.3 bit 26, F17 cascade)
// ============================================================

#[test]
fn dreaming_recalc_required_at_bit_26() {
    use locus_kit::drawer::Drawer;
    // Default zero ⇒ flag false.
    let mut d = Drawer::new("d", "c", "test-parent", "test", 0, "minilm-v6");
    assert!(!d.dreaming_recalc_required());

    // Bit 26 set ⇒ flag true.
    d.adjective_bitmap = 1i64 << 26;
    assert!(d.dreaming_recalc_required());

    // Bit 27 set without bit 26 ⇒ flag false (no bleed from upper bits).
    d.adjective_bitmap = 1i64 << 27;
    assert!(!d.dreaming_recalc_required());
}

#[test]
fn dreaming_recalc_required_composes_with_other_fields() {
    use locus_kit::adjectives::{State, Trust};
    use locus_kit::drawer::Drawer;
    let raw: i64 = State::Active.raw_value() | (Trust::Canonical.raw_value() << 18) | (1i64 << 26);
    let mut d = Drawer::new("d", "c", "test-parent", "test", 0, "minilm-v6");
    d.adjective_bitmap = raw;
    assert_eq!(d.adjective_bitmap & 0x3F, State::Active.raw_value());
    assert_eq!(
        (d.adjective_bitmap >> 18) & 0x3F,
        Trust::Canonical.raw_value()
    );
    assert!(d.dreaming_recalc_required());
}
