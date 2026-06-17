// Runs the backend-agnostic conformance suite against the SQLite backend.
// Each factory() call opens a fresh temp-file database.

mod conformance;

use conformance::{run_all, vector_fixtures, Factory};
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use uuid::Uuid;

#[test]
fn sqlite_conformance() {
    let factory: Factory = Box::new(|| {
        let path = std::env::temp_dir().join(format!("pk_conf_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        Box::new(SqliteStorage::new(config).expect("open sqlite storage")) as Box<dyn Storage>
    });
    run_all("SQLite", &factory);
    vector_fixtures("SQLite", &factory);
}

// ─────────────────────────────────────────────────────────────────────
// Audit-log reason round-trip tests for the SQLite backend.
// These tests verify that the nullable `reason` column persists and
// reads back through appendAuditEvent → decodeAuditRow with fidelity.
// ─────────────────────────────────────────────────────────────────────

use persistence_kit::{AuditEvent, Storage as _};
use substrate_types::hlc::HLC;

fn make_sqlite_audit_storage() -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_audit_reason_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = persistence_kit::SchemaDeclaration::new("reason-test", 1, vec![]);
    storage.open(&schema).expect("open schema");
    storage
}

#[test]
fn sqlite_audit_reason_some_round_trips() {
    // A supplied reason must survive the INSERT → decodeAuditRow path unchanged.
    let storage = make_sqlite_audit_storage();
    let log = storage.audit_log();
    let event = AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid: Uuid::new_v4(),
        row_id: Uuid::new_v4(),
        hlc: HLC { physical_time: 1_000_000, logical_count: 0, node_id: 1 },
        verb: "expunge".into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 1,
        after_operational: 2,
        after_provenance: 3,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        actor: "test-actor".into(),
        reason: Some("GDPR erasure request #42".into()),
    };
    log.append(event).unwrap();
    let events = log.iterate(None, None, 10).unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].reason.as_deref(),
        Some("GDPR erasure request #42"),
        "reason should round-trip through SQLite audit storage"
    );
}

#[test]
fn sqlite_audit_reason_none_round_trips() {
    // A None reason must be stored as NULL and read back as None.
    let storage = make_sqlite_audit_storage();
    let log = storage.audit_log();
    let event = AuditEvent {
        event_id: Uuid::new_v4(),
        estate_uuid: Uuid::new_v4(),
        row_id: Uuid::new_v4(),
        hlc: HLC { physical_time: 2_000_000, logical_count: 0, node_id: 1 },
        verb: "mutate".into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 4,
        after_operational: 5,
        after_provenance: 6,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        actor: "test-actor".into(),
        reason: None,
    };
    log.append(event).unwrap();
    let events = log.iterate(None, None, 10).unwrap();
    assert_eq!(events.len(), 1);
    assert!(
        events[0].reason.is_none(),
        "reason should be None when not supplied; got {:?}",
        events[0].reason
    );
}

// ─────────────────────────────────────────────────────────────────────
// StorageIntrospection tests for the SQLite backend.
// ─────────────────────────────────────────────────────────────────────

use persistence_kit::{
    ColumnDeclaration, SchemaDeclaration, StorageIntrospection, TableDeclaration,
};

fn make_sqlite_introspect() -> SqliteStorage {
    let path = std::env::temp_dir()
        .join(format!("pk_introspect_{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite storage");
    let schema = SchemaDeclaration::new(
        "introspect-test",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("label"),
            ],
            vec!["id".into()],
        )],
    );
    storage.open(&schema).expect("open schema");
    storage
}

#[test]
fn sqlite_introspection_logical_size_non_negative() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert!(stats.logical_size_bytes >= 0, "logicalSizeBytes must be non-negative");
}

#[test]
fn sqlite_introspection_page_size_is_power_of_two() {
    // SQLite page sizes are always a power of two in [512, 65536].
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let ps = stats.page_size.expect("SQLite backend must supply page_size");
    assert!(ps > 0, "page_size must be positive");
    assert_eq!(ps & (ps - 1), 0, "page_size must be a power of two");
}

#[test]
fn sqlite_introspection_page_count_positive() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let pc = stats.page_count.expect("SQLite backend must supply page_count");
    assert!(pc > 0, "page_count must be positive after open");
}

#[test]
fn sqlite_introspection_size_equals_page_count_times_page_size() {
    // logical_size_bytes = page_count * page_size.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let ps = stats.page_size.expect("page_size") as i64;
    let pc = stats.page_count.expect("page_count") as i64;
    assert_eq!(
        stats.logical_size_bytes,
        pc * ps,
        "logical_size_bytes must equal page_count * page_size"
    );
}

#[test]
fn sqlite_introspection_freelist_page_count_non_negative() {
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let fl = stats.freelist_page_count.expect("freelist_page_count");
    assert!(fl >= 0, "freelist_page_count must be non-negative");
}

#[test]
fn sqlite_introspection_wal_frame_count_non_negative() {
    // WAL mode is set at open; wal_frame_count must be present and >= 0.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    let wfc = stats.wal_frame_count.expect("wal_frame_count must be present in WAL mode");
    assert!(wfc >= 0, "wal_frame_count must be non-negative");
}

#[test]
fn sqlite_introspection_postgres_fields_are_none() {
    // PostgreSQL-specific fields must be None for the SQLite backend.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.cache_hit_ratio, None, "cache_hit_ratio must be None for SQLite");
    assert_eq!(stats.transaction_commit_count, None, "transaction_commit_count must be None for SQLite");
    assert_eq!(stats.transaction_rollback_count, None, "transaction_rollback_count must be None for SQLite");
    assert_eq!(stats.deadlock_count, None, "deadlock_count must be None for SQLite");
}

#[test]
fn sqlite_introspection_inmemory_fields_are_none() {
    // InMemory-specific fields must be None for the SQLite backend.
    let storage = make_sqlite_introspect();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.row_count, None, "row_count must be None for SQLite");
    assert_eq!(stats.blob_count, None, "blob_count must be None for SQLite");
}

#[test]
fn sqlite_introspection_captured_at_matches_input() {
    let storage = make_sqlite_introspect();
    let now = 1_700_000_000_i64;
    let stats = storage.stats(now).unwrap();
    assert_eq!(stats.captured_at_secs, now);
}
