//! Cookbook § 2.8 verification-table conformance gate. Cookbook
//! § 2.8: "Implementations MUST surface this table as an automated
//! conformance test that fails when a source constant deviates
//! from spec."
//!
//! This file enforces that gate for the constants substrate_lib
//! owns. Currently that covers the ten RowState raw values
//! (cookbook § 2.3 / § 2.8 rows 1-10). substrate_lib also defines
//! AuditSensitivity, AuditExportability, and AuditTrust constants
//! in audit_gate.rs; conformance coverage for those is pending
//! expansion of this test file.
//!
//! Rust mirror of `BitmapFieldConstantsConformanceTests.swift`;
//! both legs run independently per cookbook I-19 byte-identical
//! conformance.

use substrate_lib::row_state::RowState;

/// Cookbook § 2.8 verification table, rows 1-10 — (case, expected
/// raw, §2.8 row number). Cluster boundaries 0 / 16 / 32 chosen so
/// cluster(s) = (s >> 4) & 0x3 is a single shift-and-mask per
/// cookbook §2.3.
const STATE_TABLE: &[(RowState, u8, u32)] = &[
    // Cluster A — active / becoming.
    (RowState::Active,      0,  1),
    (RowState::Pending,     1,  2),
    (RowState::Contested,   2,  3),
    (RowState::Accepted,    3,  4),
    // Cluster B — superseded / historical (boundary at 16).
    (RowState::Superseded, 16,  5),
    (RowState::Decayed,    17,  6),
    (RowState::Withdrawn,  18,  7),
    (RowState::Expired,    19,  8),
    // Cluster C — terminal (boundary at 32).
    (RowState::Rejected,   32,  9),
    (RowState::Tombstoned, 33, 10),
];

#[test]
fn row_state_raw_values_match_verification_table() {
    let mut mismatches: Vec<String> = Vec::new();
    for (state, expected_raw, row) in STATE_TABLE {
        let actual_raw = *state as u8;
        if actual_raw != *expected_raw {
            mismatches.push(format!(
                "§2.8 row {row}: RowState::{state:?} expected raw={expected_raw}, got {actual_raw}"
            ));
        }
    }
    assert!(
        mismatches.is_empty(),
        "RowState diverges from cookbook §2.8:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn row_state_case_set_round_trips_via_from_raw() {
    // Every raw value in the §2.3 set round-trips through from_raw.
    let expected: &[u8] = &[0, 1, 2, 3, 16, 17, 18, 19, 32, 33];
    for &raw in expected {
        let state = RowState::from_raw(raw)
            .unwrap_or_else(|| panic!("from_raw({raw}) returned None; expected a case"));
        assert_eq!(state as u8, raw, "round-trip failed for raw={raw}");
    }

    // Any raw value NOT in the §2.3 set returns None (caps the case
    // set at exactly ten members).
    for raw in 0u8..64 {
        let valid = matches!(raw, 0 | 1 | 2 | 3 | 16 | 17 | 18 | 19 | 32 | 33);
        let result = RowState::from_raw(raw);
        if valid {
            assert!(result.is_some(), "from_raw({raw}) returned None for a §2.3 raw");
        } else {
            assert!(result.is_none(), "from_raw({raw}) returned Some for a non-§2.3 raw");
        }
    }
}

#[test]
fn cluster_predicate_resolves_correctly() {
    // Cookbook §2.3: cluster(s) = (s >> 4) & 0x3 resolves to
    // 0 (A), 1 (B), 2 (C). Verifies the encoding choice that
    // motivated the raw values is internally consistent.
    let cluster_a: &[RowState] = &[
        RowState::Active, RowState::Pending, RowState::Contested, RowState::Accepted,
    ];
    let cluster_b: &[RowState] = &[
        RowState::Superseded, RowState::Decayed, RowState::Withdrawn, RowState::Expired,
    ];
    let cluster_c: &[RowState] = &[RowState::Rejected, RowState::Tombstoned];

    for s in cluster_a {
        let cluster = (*s as u8 >> 4) & 0x3;
        assert_eq!(cluster, 0, "{s:?} should resolve to cluster A (0), got {cluster}");
    }
    for s in cluster_b {
        let cluster = (*s as u8 >> 4) & 0x3;
        assert_eq!(cluster, 1, "{s:?} should resolve to cluster B (1), got {cluster}");
    }
    for s in cluster_c {
        let cluster = (*s as u8 >> 4) & 0x3;
        assert_eq!(cluster, 2, "{s:?} should resolve to cluster C (2), got {cluster}");
    }
}
