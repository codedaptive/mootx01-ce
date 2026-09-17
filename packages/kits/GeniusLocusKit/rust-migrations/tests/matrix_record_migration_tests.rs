#![cfg(feature = "migration-v1-9-to-v1-10")]
use genius_locus_kit::{estate_format::*, matrix::*};
use genius_locus_kit_migrations::{legacy_matrix_schema, migrate_matrix_records};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use persistence_kit::*;
use std::sync::Arc;
use uuid::Uuid;

fn legacy_bytes() -> Vec<u8> {
    let mut b = 2u32.to_le_bytes().to_vec();
    b.extend([0; 40]);
    // A disposable large F field ensures physical page reclamation is measured.
    b.extend(1u32.to_le_bytes());
    b.extend(262_144u32.to_le_bytes());
    b.extend(std::iter::repeat(b'x').take(262_144));
    b.extend([0; 9]);
    b.extend(0u32.to_le_bytes());
    b.extend(0u32.to_le_bytes()); // O,T
    b.extend(1u32.to_le_bytes());
    b.extend(5u32.to_le_bytes());
    b.extend(b"model");
    b.extend(20u32.to_le_bytes());
    for i in 0..20 {
        b.extend((if i == 16 { 1i32 } else { 0 }).to_le_bytes());
        b.extend((if i == 16 { 1f32 } else { 0.0 }).to_le_bytes());
    }
    b.extend([0; 16]);
    b.extend(1u32.to_le_bytes());
    b.extend(5u32.to_le_bytes());
    b.extend(b"model");
    b.extend(1_700_000_000f64.to_le_bytes());
    b
}
#[test]
fn corrupt_calibration_blocks_drop_then_retry_preserves_and_reclaims() {
    let id = Uuid::new_v4();
    let path = std::env::temp_dir().join(format!("matrix-upgrade-{id}.sqlite"));
    let storage: Arc<dyn Storage> = Arc::new(
        SqliteStorage::new(EstateConfiguration::new(
            id,
            BackendConfiguration::Sqlite {
                path: path.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        ))
        .unwrap(),
    );
    storage.open(&locus_kit::schema::schema()).unwrap();
    storage.migrate(&legacy_matrix_schema()).unwrap();
    let format = EstateFormatStore::new(storage.clone());
    format
        .stamp(EstateFormatVersion::V1_9, 1_700_000_000_000)
        .unwrap();
    let id = id.to_string();
    let write = |bytes: Vec<u8>| {
        storage
            .row_store()
            .upsert(
                "matrix_snapshot",
                std::collections::BTreeMap::from([
                    ("estate_id".into(), TypedValue::Text(id.clone())),
                    ("schema_version".into(), TypedValue::Int(2)),
                    ("snapshot".into(), TypedValue::Blob(bytes)),
                    ("last_hlc".into(), TypedValue::Text("0.0.0".into())),
                    (
                        "updated_at".into(),
                        TypedValue::Timestamp(1_700_000_000_000),
                    ),
                ]),
                &["estate_id".into()],
            )
            .unwrap();
    };
    write(vec![0]);
    assert!(
        migrate_matrix_records(storage.clone(), &id, 1_700_000_000_000, Default::default())
            .is_err()
    );
    assert_eq!(
        storage
            .current_schema_version_for("GeniusLocusKitMatrix")
            .unwrap(),
        1
    );
    assert_eq!(
        format.read_if_present().unwrap(),
        Some(EstateFormatVersion::V1_9)
    );
    write(legacy_bytes());
    migrate_matrix_records(storage.clone(), &id, 1_700_000_000_000, Default::default()).unwrap();
    let records = MatrixRecordStore::new(storage.clone());
    let calibration = records.load_calibration(&id).unwrap();
    assert_eq!(calibration.curves["model"].buckets[16].count, 1);
    assert_eq!(calibration.update_timestamps["model"], 1_700_000_000.0);
    assert_eq!(
        format.read_if_present().unwrap(),
        Some(EstateFormatVersion::V1_10)
    );
    assert_eq!(
        storage
            .current_schema_version_for("GeniusLocusKitMatrix")
            .unwrap(),
        2
    );
    assert!(
        matches!(records.state(&id).unwrap().unwrap().get("reclaimed_bytes"),Some(TypedValue::Int(n)) if *n>0)
    );
    migrate_matrix_records(storage.clone(), &id, 1_700_000_000_000, Default::default()).unwrap();
    assert_eq!(records.load_calibration(&id).unwrap(), calibration);
    drop(records);
    drop(format);
    storage.close().unwrap();
    drop(storage);
    std::fs::remove_file(&path).unwrap();
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

/// F5: the migration must not refuse when the estate's actual audit-event or
/// source-row count exceeds the CALLER-SUPPLIED `limits` floor — it widens
/// `limits` to the estate's real counts before calling the worker. A fixture
/// with literally 1,000,001 rows would be impractically slow for a unit
/// test; passing an artificially tiny floor (`1` for every field) against a
/// small real fixture (a handful of drawers, each with its own capture audit
/// event) exercises the exact same widening code path deterministically and
/// fast — the mechanism under test is "does `limits` get raised to cover the
/// actual count", not the literal magnitude of the default.
///
/// Before the fix this refused with `MatrixRecordError::workingSetLimit`
/// (surfaced here as `StorageError::BackendError`) on the very first
/// audit-replay page, because the un-widened floor of 1 event/row is below
/// the handful this fixture writes.
#[test]
fn fixture_over_the_requested_floor_still_migrates() {
    let id = Uuid::new_v4();
    let path = std::env::temp_dir().join(format!("matrix-upgrade-oversize-{id}.sqlite"));
    let now_millis: i64 = 1_700_000_000_000;

    // Phase 1: write real drawers (and their capture audit events) through
    // the ordinary DrawerStore path, so the estate's audit log and drawers
    // table both carry more rows than the tiny floor below.
    {
        let store = SqliteDrawerStore::from_path(&path.display().to_string(), now_millis, None, 5.0)
            .expect("open sqlite drawer store");
        for i in 0..6 {
            let drawer_id = Uuid::new_v4().to_string();
            let mut drawer = Drawer::new(
                &drawer_id,
                &format!("F5 fixture drawer {i}"),
                "00000000-0000-4000-8000-000000000001",
                "bilby",
                now_millis,
                "test-v1",
            );
            drawer.udc_code = "001".into();
            store.add_drawer(&drawer, now_millis).expect("add_drawer");
        }
    }

    // Phase 2: reopen as a bare Storage handle (the shape the migration
    // itself is called with in production) and stamp the pre-migration
    // format.
    let storage: Arc<dyn Storage> = Arc::new(
        SqliteStorage::new(EstateConfiguration::new(
            id,
            BackendConfiguration::Sqlite {
                path: path.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        ))
        .unwrap(),
    );
    storage.open(&locus_kit::schema::schema()).unwrap();
    let format = EstateFormatStore::new(storage.clone());
    format.stamp(EstateFormatVersion::V1_9, now_millis).unwrap();
    let id_string = id.to_string();

    // A floor of 1 for every field is far below the 6 drawers (and their
    // matching audit events) actually on disk.
    let tiny_floor = MatrixRefreshLimits {
        audit_events: 1,
        cells: 1,
        source_rows: 1,
    };
    let result = migrate_matrix_records(storage.clone(), &id_string, now_millis, tiny_floor);
    assert!(
        result.is_ok(),
        "a migration whose real counts exceed the requested floor must still succeed, not refuse: {result:?}"
    );
    assert_eq!(
        format.read_if_present().unwrap(),
        Some(EstateFormatVersion::V1_10),
        "the format must advance to v1.10 on a successful migration"
    );

    drop(format);
    storage.close().unwrap();
    drop(storage);
    std::fs::remove_file(&path).unwrap();
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}
