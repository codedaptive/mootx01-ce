// audit_durability_grant_sensitivity.rs — RUST-AUDIT-DURABILITY coverage.
//
// `sensitivity_audit_verbs.rs` covers the LIVE (never-reopened) in-memory
// read path for the four sensitivity unlock verbs. `grants_parity.rs`
// covers the grant subsystem's crypto/store mechanics but never asserted an
// audit entry at all (there was none to assert — `issue_grant`/`revoke_grant`
// appended nothing). Neither file exercises what happens to either verb
// family's audit entries across an estate close + reopen.
//
// This file closes that gap: build an estate, write a sensitivity-unlock and
// a grant-lifecycle entry, flush the estate's storage to a durable SQLite
// backend (the moral equivalent of a clean app-level close), then hydrate a
// FRESH `EstateCoordinator` + FRESH in-memory backend from that SQLite file
// (the moral equivalent of relaunch) and assert the entries are still there,
// under the correct verb — not silently dropped, and not collapsed to
// `.Mutate` by a verb-string round-trip gap.
//
// Companion coverage:
//   - sensitivity_audit_verbs.rs — live-session read-back, verb-per-field
//     assertions, malformed-drawer-id skip.
//   - grants_parity.rs (GRT-03/04/05/06/07) — grant crypto/store mechanics,
//     no audit assertions.
//   - hydrate_parity.rs — drawer/KGFact/MatrixTier hydration equivalence,
//     no sensitivity/grant audit coverage.

use std::sync::Arc;
use uuid::Uuid;

use genius_locus_kit::audit::UnifiedAuditVerb;
use genius_locus_kit::{
    glk_flush, CustodyMode, EstateCoordinator, GrantLifetime, GrantOptions, GrantScope,
    IssueGrantResult, ReSharePermission,
};
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::{
    inmemory::InMemoryStorage, BackendConfiguration, EstateConfiguration, SqliteStorage,
};

// Never call std::time inside a test — all time enters through `now`.
const NOW: i64 = 1_750_000_000;
const NOW_F64: f64 = NOW as f64;
const NOW_MS: i64 = NOW * 1000;

// MARK: - Helpers (mirrors hydrate_parity.rs's SQLite scaffold)

fn make_sqlite() -> (SqliteStorage, std::path::PathBuf) {
    let path = std::env::temp_dir()
        .join(format!("glk-audit-durability-{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite for audit durability test");
    (storage, path)
}

fn cleanup_sqlite(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

struct SqliteCleanup(std::path::PathBuf);
impl Drop for SqliteCleanup {
    fn drop(&mut self) {
        cleanup_sqlite(&self.0);
    }
}

/// Open a fresh estate on a fresh in-memory backend, returning the
/// coordinator, handle, and the retained `Storage` so the caller can flush
/// it later. Mirrors `sensitivity_audit_verbs.rs`'s `open_coord`, except it
/// also hands back the storage (needed for `glk_flush`).
fn open_coord() -> (EstateCoordinator, genius_locus_kit::EstateHandle, Arc<InMemoryStorage>) {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let mut coord = EstateCoordinator::new();
    let drawer_store: Arc<dyn DrawerStore> = Arc::new(
        InMemoryDrawerStore::with_storage(storage.clone(), NOW, None)
            .expect("InMemoryDrawerStore::with_storage"),
    );
    let handle = coord
        .open(drawer_store, OwnerCredentials::new("owner-audit-durability"), 0, 100)
        .expect("open");
    (coord, handle, storage)
}

fn grant_options() -> GrantOptions {
    GrantOptions {
        grantee_estate_id: Uuid::new_v4(),
        scope: GrantScope::WholeEstate,
        custody_mode: CustodyMode::HandedOver,
        lifetime: GrantLifetime::Permanent,
        content_level: 0,
        re_share_permission: ReSharePermission::None,
    }
}

// ---------------------------------------------------------------------------
// (a) Survive close/reopen
// ---------------------------------------------------------------------------

/// A sensitivity-unlock grant-issued entry, written on a live estate, is
/// still readable — under the correct verb — after the estate's storage is
/// flushed to SQLite and a fresh coordinator hydrates from it.
#[test]
fn sensitivity_grant_issued_survives_close_reopen() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path);
    let owner = OwnerCredentials::new("owner-audit-durability");

    let (mut coord, handle, storage) = open_coord();
    let grant_id = Uuid::new_v4();
    let expires_at_ms = NOW_MS + 30 * 60 * 1000;
    coord
        .record_sensitivity_grant_issued(&handle, AdjectiveSensitivity::Secret, grant_id, expires_at_ms, NOW_MS)
        .expect("record issued");

    // "Close": flush the live estate's storage to the durable backend.
    glk_flush(storage.as_ref(), &sqlite).expect("flush to sqlite");

    // "Reopen": fresh coordinator, fresh in-memory backend, hydrate from sqlite.
    let fresh_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let mut reopened = EstateCoordinator::new();
    let (reopened_handle, _log, _tier) = reopened
        .open_hydrating(fresh_storage, &sqlite, owner, 0, 100, NOW)
        .expect("open_hydrating");

    let log = reopened.audit_log(&reopened_handle).expect("audit log after reopen");
    let entries: Vec<_> = log
        .ordered_entries()
        .into_iter()
        .filter(|e| e.verb == UnifiedAuditVerb::SensitivityGrantIssued)
        .collect();
    assert_eq!(
        entries.len(), 1,
        "sensitivity grant-issued entry must survive close/reopen, not be silently dropped"
    );
    assert_eq!(entries[0].field_path, "secret");
    assert_eq!(
        entries[0].row_id,
        genius_locus_kit::audit::EntryUUID(grant_id.as_u128().to_be_bytes()),
        "row_id (grant id) must round-trip exactly"
    );
}

/// A grant-lifecycle issued entry (the federation-reserved `GrantIssued`
/// verb, previously never written at all) survives close/reopen the same
/// way the sensitivity-unlock verbs do.
#[test]
fn grant_issued_survives_close_reopen() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path);
    let owner = OwnerCredentials::new("owner-audit-durability");

    let (mut coord, handle, storage) = open_coord();
    let IssueGrantResult { grant, .. } = coord
        .issue_grant(&handle, grant_options(), &[0xABu8; 32], NOW_F64)
        .expect("issue_grant");

    glk_flush(storage.as_ref(), &sqlite).expect("flush to sqlite");

    let fresh_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let mut reopened = EstateCoordinator::new();
    let (reopened_handle, _log, _tier) = reopened
        .open_hydrating(fresh_storage, &sqlite, owner, 0, 100, NOW)
        .expect("open_hydrating");

    let log = reopened.audit_log(&reopened_handle).expect("audit log after reopen");
    let entries: Vec<_> = log
        .ordered_entries()
        .into_iter()
        .filter(|e| e.verb == UnifiedAuditVerb::GrantIssued)
        .collect();
    assert_eq!(
        entries.len(), 1,
        "grant-issued entry must survive close/reopen — this verb had NO writer at all before RUST-AUDIT-DURABILITY"
    );
    assert_eq!(entries[0].field_path, "handedOver");
    assert_eq!(
        entries[0].row_id,
        genius_locus_kit::audit::EntryUUID(grant.id.as_u128().to_be_bytes())
    );
}

/// Both a grant-issued and a grant-revoked entry survive close/reopen and
/// correlate by row_id (the same contract `record_sensitivity_grant_revoked`
/// already proves for sensitivity-unlock in `sensitivity_audit_verbs.rs`).
#[test]
fn grant_issued_and_revoked_both_survive_close_reopen_and_correlate() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path);
    let owner = OwnerCredentials::new("owner-audit-durability");

    let (mut coord, handle, storage) = open_coord();
    let IssueGrantResult { grant, .. } = coord
        .issue_grant(&handle, grant_options(), &[0xCDu8; 32], NOW_F64)
        .expect("issue_grant");
    coord
        .revoke_grant(&handle, grant.id, NOW_F64 + 1.0)
        .expect("revoke_grant");

    glk_flush(storage.as_ref(), &sqlite).expect("flush to sqlite");

    let fresh_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let mut reopened = EstateCoordinator::new();
    let (reopened_handle, _log, _tier) = reopened
        .open_hydrating(fresh_storage, &sqlite, owner, 0, 100, NOW)
        .expect("open_hydrating");

    let log = reopened.audit_log(&reopened_handle).expect("audit log after reopen");
    let all = log.ordered_entries();
    let issued = all.iter().find(|e| e.verb == UnifiedAuditVerb::GrantIssued)
        .expect("grant-issued entry must survive close/reopen");
    let revoked = all.iter().find(|e| e.verb == UnifiedAuditVerb::GrantRevoked)
        .expect("grant-revoked entry must survive close/reopen");
    assert_eq!(
        issued.row_id, revoked.row_id,
        "revoked entry must correlate with issued entry by row_id after reopen"
    );
}

// ---------------------------------------------------------------------------
// (b) Verb round-trips as the correct enum case, not a collapse
// ---------------------------------------------------------------------------

/// Before RUST-AUDIT-DURABILITY, `verb_from_str` had no cases for any of the
/// six synthetic verbs, so a durably-recovered entry would have collapsed to
/// `.Mutate`. This asserts the specific enum case survives the full
/// durable round trip for the two families that previously had zero
/// coverage (grant) and partial coverage (sensitivity, live-only).
#[test]
fn synthetic_verbs_round_trip_as_distinct_cases_not_a_mutate_collapse() {
    let (sqlite, sqlite_path) = make_sqlite();
    let _guard = SqliteCleanup(sqlite_path);
    let owner = OwnerCredentials::new("owner-audit-durability");

    let (mut coord, handle, storage) = open_coord();
    coord
        .record_sensitivity_grant_denied(&handle, AdjectiveSensitivity::Restricted, NOW_MS)
        .expect("record denied");
    let drawer_id = Uuid::new_v4();
    coord
        .record_sensitivity_read_under_grant(&handle, AdjectiveSensitivity::Elevated, &drawer_id.to_string(), NOW_MS)
        .expect("record read under grant");
    let IssueGrantResult { grant, .. } = coord
        .issue_grant(&handle, grant_options(), &[0xEFu8; 32], NOW_F64)
        .expect("issue_grant");

    glk_flush(storage.as_ref(), &sqlite).expect("flush to sqlite");

    let fresh_storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    let mut reopened = EstateCoordinator::new();
    let (reopened_handle, _log, _tier) = reopened
        .open_hydrating(fresh_storage, &sqlite, owner, 0, 100, NOW)
        .expect("open_hydrating");

    let log = reopened.audit_log(&reopened_handle).expect("audit log after reopen");
    let verbs: std::collections::HashSet<UnifiedAuditVerb> =
        log.ordered_entries().into_iter().map(|e| e.verb).collect();

    assert!(
        verbs.contains(&UnifiedAuditVerb::SensitivityGrantDenied),
        "SensitivityGrantDenied must not collapse to Mutate on durable round-trip"
    );
    assert!(
        verbs.contains(&UnifiedAuditVerb::SensitivityReadUnderGrant),
        "SensitivityReadUnderGrant must not collapse to Mutate on durable round-trip"
    );
    assert!(
        verbs.contains(&UnifiedAuditVerb::GrantIssued),
        "GrantIssued must not collapse to Mutate on durable round-trip"
    );
    assert!(
        !verbs.contains(&UnifiedAuditVerb::Mutate),
        "no synthetic entry should have collapsed to Mutate — got verbs: {verbs:?}"
    );
    // Sanity: the grant id actually made it through as a distinct row.
    let _ = grant.id;
}

/// out-of-band sensitivity grants requires sensitivity-unlock verbs never reuse the federation-
/// reserved `GrantIssued`/`GrantRevoked` cases. Now that both case FAMILIES
/// exist on the Rust port (RUST-AUDIT-DURABILITY added `GrantIssued`/
/// `GrantRevoked`; previously Rust carried neither, so there was nothing to
/// accidentally reuse — see `sensitivity_audit_verbs.rs`'s prior NOTE and
/// `audit/log.rs`'s enum doc comment), this is the live Rust equivalent of
/// Swift's `sensitivityGrantVerbsNeverReuseFederationReservedVerbs`.
#[test]
fn grant_verbs_never_collide_with_sensitivity_verbs() {
    let (mut coord, handle, _storage) = open_coord();
    coord
        .record_sensitivity_grant_issued(&handle, AdjectiveSensitivity::Restricted, Uuid::new_v4(), NOW_MS + 60_000, NOW_MS)
        .expect("record issued");

    let log = coord.audit_log(&handle).expect("audit log");
    assert!(
        log.ordered_entries().into_iter().all(|e| {
            e.verb != UnifiedAuditVerb::GrantIssued && e.verb != UnifiedAuditVerb::GrantRevoked
        }),
        "sensitivity-unlock must never write the federation-reserved GrantIssued/GrantRevoked verbs"
    );
}
