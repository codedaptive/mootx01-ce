#![cfg(feature = "migration-v1-9-to-v1-10")]
use genius_locus_kit::{estate_format::*, matrix::*};
use genius_locus_kit_migrations::{legacy_matrix_schema, migrate_matrix_records};
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
