//! Keyed records: SQLite fidelity, publication isolation, independent calibration.
use genius_locus_kit::audit::*;
use genius_locus_kit::matrix::*;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
use std::sync::{atomic::AtomicBool, Arc};
use substrate_types::hlc::HLC;
use uuid::Uuid;

#[test]
fn records_round_trip_without_publishing_partial_or_clobbering_calibration() {
    let path = std::env::temp_dir().join(format!("matrix-records-{}.sqlite", Uuid::new_v4()));
    let id = Uuid::new_v4();
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
    let store = MatrixRecordStore::new(storage.clone());
    store.prepare().unwrap();
    let mut log = UnifiedAuditLog::new();
    for n in 1..=2 {
        log.add(UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(n * 60_000, 0, 1),
            UnifiedAuditVerb::Capture,
            EntryUUID([n as u8; 16]),
            "adjective",
            UnifiedAuditValue::Null,
            UnifiedAuditValue::Bitmap(3),
            None,
        ));
    }
    let mut tier = MatrixTier::full_rebuild(&log, &Default::default());
    tier.last_hlc = HLC::new(1_789_588_235_633, 12345, 1_338_739_188);
    tier.temporal_watermark_hlc = HLC::new(1_789_588_235_634, 456, -1_338_739_188);
    tier.co_occurrence_decayed = MatrixTier::decayed_co_occurrence(&log, 180_000);
    tier.temporal_causality_decayed = MatrixTier::rebuild_temporal_from_with_decay(
        &log,
        HLC::ZERO,
        &Default::default(),
        Some(180_000),
    )
    .temporal_causality_decayed;
    tier.decayed_as_of_ms = 180_000;
    let id = id.to_string();
    let cancel = AtomicBool::new(false);
    store
        .record_calibration(&id, "model", 0.8, MatrixCalibrationOutcome::Success, 180.0)
        .unwrap();
    let cal = store.load_calibration(&id).unwrap();
    store
        .stage(&id, &tier, "candidate", 180_000, 1000, &cancel)
        .unwrap();
    assert!(store.load(&id, 1000).unwrap().is_none());
    store
        .publish(&id, "candidate", None, None, &cancel)
        .unwrap();
    assert_eq!(store.load(&id, 1000).unwrap(), Some(tier));
    assert_eq!(store.load_calibration(&id).unwrap(), cal);
    assert!(store
        .publish(&id, "incomplete", Some("candidate"), None, &cancel)
        .is_err());
    assert_eq!(
        store.active_generation(&id).unwrap().as_deref(),
        Some("candidate")
    );
    let worker = MatrixRefreshWorker::new(storage.clone(), id.clone(), None, false);
    let limits = MatrixRefreshLimits {
        cells: 1,
        ..Default::default()
    };
    let (_, ticket) = worker.request(180_000, limits, false).unwrap();
    assert!(ticket.wait().unwrap_err().contains("deferred:"));
    assert_eq!(worker.status().phase, "deferred");
    assert_eq!(
        store.active_generation(&id).unwrap().as_deref(),
        Some("candidate")
    );
    worker.close();
    assert!(worker.request(180_000, limits, false).is_err());
    drop(worker);
    drop(store);
    storage.close().unwrap();
    drop(storage);
    std::fs::remove_file(&path).unwrap();
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}
