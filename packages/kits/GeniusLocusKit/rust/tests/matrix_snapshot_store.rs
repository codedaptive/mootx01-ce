// matrix_snapshot_store.rs — Rust conformance for the on-disk matrix snapshot
// store. Mirrors the Swift `MatrixSnapshotPersistenceTests` (round-trip against a
// real SQLite backend + stale-schema-version rejection), proving the matrix tier
// is persisted as a SQLite TABLE and survives the primitive read-back path
// (BLOB→Blob, INTEGER→Int).

use std::sync::Arc;

use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, SqliteStorage, Storage, StoragePredicate,
    TypedValue,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

use genius_locus_kit::audit::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};
use genius_locus_kit::matrix::{
    MatrixCalibrationRegistry, MatrixSnapshot, MatrixSnapshotStore, MatrixTier,
};

const NOW: i64 = 1_750_000_000;

fn make_sqlite() -> (SqliteStorage, std::path::PathBuf) {
    let path = std::env::temp_dir().join(format!("glk-matrix-snap-{}.sqlite", Uuid::new_v4()));
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).expect("open sqlite");
    (storage, path)
}

fn cleanup(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

fn cap(row: EntryUUID, field: &str, bm: u64, h: HLC) -> UnifiedAuditEntry {
    UnifiedAuditEntry::new(
        AuditTier::Locus, h, UnifiedAuditVerb::Capture, row, field.to_string(),
        UnifiedAuditValue::Null, UnifiedAuditValue::Bitmap(bm), None,
    )
}

/// A snapshot upserted to SQLite loads back cell-for-cell equal — the tier
/// survives the BLOB round-trip through a real SQLite backend.
#[test]
fn snapshot_round_trips_through_sqlite() {
    let (storage, path) = make_sqlite();
    let storage: Arc<dyn Storage> = Arc::new(storage);
    storage
        .migrate(&MatrixSnapshotStore::schema_declaration())
        .expect("migrate snapshot schema");
    let store = MatrixSnapshotStore::new(Arc::clone(&storage));

    // Build a non-trivial tier from a small log.
    let mut log = UnifiedAuditLog::new();
    log.add(cap(EntryUUID([1; 16]), "bm.a", 0b101, HLC::new(1_000, 0, 1)));
    log.add(cap(EntryUUID([2; 16]), "bm.a", 0b001, HLC::new(2_000, 0, 1)));
    log.add(cap(EntryUUID([2; 16]), "bm.b", 0b010, HLC::new(2_000, 0, 1)));
    let tier = MatrixTier::full_rebuild(&log, &std::collections::HashMap::new());

    let estate_id = Uuid::new_v4().to_string();
    let snapshot = MatrixSnapshot::new(tier.clone(), MatrixCalibrationRegistry::default(), tier.last_hlc);
    store.upsert(&estate_id, &snapshot, NOW).expect("upsert");

    let loaded = store.load(&estate_id).expect("load").expect("present");
    assert_eq!(loaded.tier, tier, "loaded tier must equal persisted tier");
    assert_eq!(loaded.schema_version, MatrixSnapshot::CURRENT_SCHEMA_VERSION);
    assert_eq!(loaded.tier.live_row_count, 2);

    cleanup(&path);
}

/// A row carrying a foreign schema_version is rejected on load (returns None) so
/// the caller falls back to a full rebuild — the cheap column gate must not trust
/// the blob. Mirrors Swift `staleSchemaVersionRejectedOnLoad`.
#[test]
fn stale_schema_version_rejected_on_load() {
    let (storage, path) = make_sqlite();
    let storage: Arc<dyn Storage> = Arc::new(storage);
    storage
        .migrate(&MatrixSnapshotStore::schema_declaration())
        .expect("migrate snapshot schema");

    let estate_id = Uuid::new_v4().to_string();
    // Write a row with a foreign schema_version and an undecodable blob directly.
    let mut values: std::collections::BTreeMap<String, TypedValue> = std::collections::BTreeMap::new();
    values.insert("estate_id".into(), TypedValue::Text(estate_id.clone()));
    values.insert(
        "schema_version".into(),
        TypedValue::Int((MatrixSnapshot::CURRENT_SCHEMA_VERSION + 99) as i64),
    );
    values.insert("snapshot".into(), TypedValue::Blob(vec![0x00]));
    values.insert("last_hlc".into(), TypedValue::Text("0.0.0".into()));
    values.insert("updated_at".into(), TypedValue::Timestamp(NOW));
    storage
        .row_store()
        .upsert("matrix_snapshot", values, &["estate_id".to_string()])
        .expect("raw upsert");

    let store = MatrixSnapshotStore::new(Arc::clone(&storage));
    assert!(store.load(&estate_id).expect("load").is_none(), "stale version must be rejected");

    // delete_all wipes the row.
    store.delete_all().expect("delete_all");
    let rows = storage
        .row_store()
        .query(
            "matrix_snapshot",
            Some(&StoragePredicate::Eq(
                Column::new("matrix_snapshot", "estate_id"),
                TypedValue::Text(estate_id.clone()),
            )),
            &[],
            None,
            None,
        )
        .expect("query");
    assert!(rows.is_empty(), "delete_all must remove the row");

    cleanup(&path);
}

/// update_timestamps survives encode→decode round-trip (Part 4 regression gate).
///
/// Before the fix, update_timestamps was always loaded as an empty HashMap
/// regardless of what was saved. After restart, the first record_with_decay
/// had no last_ts and silently skipped decay computation.
///
/// This test upserts a snapshot with non-empty update_timestamps and verifies
/// they are reloaded correctly. Mirrors Swift MatrixSnapshotPersistenceTests
/// which covers this through Codable's automatic round-trip.
#[test]
fn update_timestamps_survive_round_trip() {
    use genius_locus_kit::matrix::MatrixCalibrationRegistry;

    let (storage, path) = make_sqlite();
    let storage: Arc<dyn Storage> = Arc::new(storage);
    storage
        .migrate(&MatrixSnapshotStore::schema_declaration())
        .expect("migrate snapshot schema");
    let store = MatrixSnapshotStore::new(Arc::clone(&storage));

    // Build a calibration registry with non-empty update_timestamps.
    let mut calibration = MatrixCalibrationRegistry::default();
    // update_timestamps records the last observation epoch-seconds per model.
    // Insert three synthetic model timestamps to verify all three survive.
    calibration.update_timestamps.insert("model-a".to_string(), 1_750_000_000.0_f64);
    calibration.update_timestamps.insert("model-b".to_string(), 1_750_001_000.0_f64);
    calibration.update_timestamps.insert("model-c".to_string(), 0.0_f64); // edge: zero timestamp

    let tier = MatrixTier::new();
    let estate_id = Uuid::new_v4().to_string();
    let snapshot = MatrixSnapshot::new(tier, calibration.clone(), HLC::new(1_000, 0, 1));
    // Snapshot must be written with schema_version 2 so update_timestamps section is included.
    assert_eq!(snapshot.schema_version, MatrixSnapshot::CURRENT_SCHEMA_VERSION);
    assert_eq!(MatrixSnapshot::CURRENT_SCHEMA_VERSION, 2, "schema version must be 2 after Part 4 fix");

    store.upsert(&estate_id, &snapshot, NOW).expect("upsert");

    let loaded = store.load(&estate_id).expect("load").expect("present");
    assert_eq!(
        loaded.calibration.update_timestamps.len(),
        3,
        "all three update_timestamps must survive the round-trip"
    );
    assert_eq!(
        loaded.calibration.update_timestamps.get("model-a"),
        Some(&1_750_000_000.0_f64),
        "model-a timestamp must survive round-trip"
    );
    assert_eq!(
        loaded.calibration.update_timestamps.get("model-b"),
        Some(&1_750_001_000.0_f64),
        "model-b timestamp must survive round-trip"
    );
    assert_eq!(
        loaded.calibration.update_timestamps.get("model-c"),
        Some(&0.0_f64),
        "edge case: zero timestamp must survive round-trip"
    );

    cleanup(&path);
}
