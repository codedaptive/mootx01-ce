// sensitivity_audit_verbs.rs — out-of-band sensitivity grants (Audit) parity coverage.
//
// Mirrors Swift `SensitivityAuditVerbsTests.swift`. Same harness shape as
// grants_parity.rs's GRT-03 coordinator integration tests.

use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use std::sync::Arc;
use uuid::Uuid;

const NOW_MS: i64 = 1_700_000_000_000;

fn open_coord() -> (EstateCoordinator, genius_locus_kit::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW_MS / 1000, None).unwrap());
    let handle = coord.open(store, OwnerCredentials::new("sensitivity-audit-owner"), 0, 100).expect("open");
    (coord, handle)
}

#[test]
fn record_sensitivity_grant_issued_emits_expected_entry() {
    let (mut coord, h) = open_coord();
    let grant_id = Uuid::new_v4();
    let expires_at_ms = NOW_MS + 30 * 60 * 1000;
    coord
        .record_sensitivity_grant_issued(&h, AdjectiveSensitivity::Secret, grant_id, expires_at_ms, NOW_MS)
        .expect("record issued");

    let log = coord.audit_log(&h).expect("audit log");
    let entries: Vec<_> = log
        .ordered_entries()
        .into_iter()
        .filter(|e| e.verb == genius_locus_kit::audit::UnifiedAuditVerb::SensitivityGrantIssued)
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].field_path, "secret");
}

#[test]
fn record_sensitivity_grant_denied_emits_expected_entry() {
    let (mut coord, h) = open_coord();
    coord
        .record_sensitivity_grant_denied(&h, AdjectiveSensitivity::Restricted, NOW_MS)
        .expect("record denied");

    let log = coord.audit_log(&h).expect("audit log");
    let entries: Vec<_> = log
        .ordered_entries()
        .into_iter()
        .filter(|e| e.verb == genius_locus_kit::audit::UnifiedAuditVerb::SensitivityGrantDenied)
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].field_path, "restricted");
}

#[test]
fn record_sensitivity_grant_revoked_correlates_with_issued_by_row_id() {
    let (mut coord, h) = open_coord();
    let grant_id = Uuid::new_v4();
    coord
        .record_sensitivity_grant_issued(&h, AdjectiveSensitivity::Restricted, grant_id, NOW_MS + 3_600_000, NOW_MS)
        .unwrap();
    coord
        .record_sensitivity_grant_revoked(&h, AdjectiveSensitivity::Restricted, grant_id, NOW_MS + 60_000)
        .unwrap();

    let log = coord.audit_log(&h).expect("audit log");
    let all = log.ordered_entries();
    let issued = all.iter().find(|e| e.verb == genius_locus_kit::audit::UnifiedAuditVerb::SensitivityGrantIssued).unwrap();
    let revoked = all.iter().find(|e| e.verb == genius_locus_kit::audit::UnifiedAuditVerb::SensitivityGrantRevoked).unwrap();
    assert_eq!(issued.row_id, revoked.row_id, "revoked entry must correlate with issued entry by row_id");
}

#[test]
fn record_sensitivity_read_under_grant_uses_drawer_id_as_row_id() {
    let (mut coord, h) = open_coord();
    let drawer_id = Uuid::new_v4();
    coord
        .record_sensitivity_read_under_grant(&h, AdjectiveSensitivity::Secret, &drawer_id.to_string(), NOW_MS)
        .unwrap();

    let log = coord.audit_log(&h).expect("audit log");
    let entries: Vec<_> = log
        .ordered_entries()
        .into_iter()
        .filter(|e| e.verb == genius_locus_kit::audit::UnifiedAuditVerb::SensitivityReadUnderGrant)
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].row_id, genius_locus_kit::audit::EntryUUID(drawer_id.as_u128().to_be_bytes()));
}

#[test]
fn record_sensitivity_read_under_grant_silently_skips_a_malformed_drawer_id() {
    let (mut coord, h) = open_coord();
    coord
        .record_sensitivity_read_under_grant(&h, AdjectiveSensitivity::Secret, "not-a-uuid", NOW_MS)
        .expect("must not error even for a malformed drawer id");
    let log = coord.audit_log(&h).expect("audit log");
    assert!(log
        .ordered_entries()
        .into_iter()
        .all(|e| e.verb != genius_locus_kit::audit::UnifiedAuditVerb::SensitivityReadUnderGrant));
}

// NOTE (RUST-AUDIT-DURABILITY, 2026-07-09): Rust's `UnifiedAuditVerb` now
// carries `GrantIssued`/`GrantRevoked` (the FUP-C / GLK-03 grant-lifecycle
// seam durably appends them — `EstateCoordinator::issue_grant`/
// `revoke_grant`), so there is something to accidentally reuse. The Rust
// equivalent of Swift's `sensitivityGrantVerbsNeverReuseFederationReservedVerbs`
// now lives in `audit_durability_grant_sensitivity.rs`'s
// `grant_verbs_never_collide_with_sensitivity_verbs`.
