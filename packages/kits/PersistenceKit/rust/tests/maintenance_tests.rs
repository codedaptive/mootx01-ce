// maintenance_tests.rs
//
// StorageMaintenance contract coverage (GLK shared-content 1.1, P5) —
// Rust twin of Swift `StorageMaintenanceTests.swift`: WAL checkpoint +
// VACUUM release freed pages to the FILESYSTEM, with quiescence, progress,
// cancellation, and post-operation introspection contracts, plus the
// explicit in-memory no-op behaviour.

use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::maintenance::{MaintenanceError, MaintenancePhase};
use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, IsolationLevel,
    SchemaDeclaration, SqliteStorage, Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use uuid::Uuid;

fn scratch_path(tag: &str) -> String {
    let dir = std::env::temp_dir().join(format!("pk-maintenance-{tag}-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir.join("estate.sqlite").to_string_lossy().to_string()
}

fn make_sqlite(path: &str) -> SqliteStorage {
    SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    ))
    .expect("open sqlite storage")
}

fn schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "MaintenanceTestKit",
        1,
        vec![TableDeclaration::new(
            "bulk",
            vec![
                ColumnDeclaration::text("row_id"),
                ColumnDeclaration::text("payload"),
            ],
            vec!["row_id".to_string()],
        )],
    )
}

/// Fill the bulk table with ~2 MB of rows, then delete every row — the
/// deleted pages land on the freelist, NOT back on the filesystem.
fn churn(storage: &SqliteStorage) {
    let blob = "x".repeat(4096);
    let rows = storage.row_store();
    for index in 0..500 {
        let mut values = BTreeMap::new();
        values.insert("row_id".to_string(), TypedValue::Text(format!("row-{index}")));
        values.insert("payload".to_string(), TypedValue::Text(blob.clone()));
        rows.insert("bulk", values).expect("insert");
    }
    rows.delete("bulk", &StoragePredicate::IsTrue).expect("delete");
}

// ─────────────────────────────────────────────────────────────────────
// Reclamation
// ─────────────────────────────────────────────────────────────────────

#[test]
fn vacuum_releases_freed_pages_to_the_filesystem() {
    let path = scratch_path("reclaim");
    let storage = make_sqlite(&path);
    storage.open(&schema()).expect("open");
    churn(&storage);

    // Deleted pages are reclaimable but NOT yet released.
    let estimate = storage.estimated_reclaimable_bytes().expect("estimate");
    assert!(estimate > 0, "estimate should see freelist/WAL bytes");

    let report = storage.perform_maintenance(None, None).expect("maintenance");
    assert_eq!(report.backend, "sqlite");
    assert!(report.performed);
    assert!(report.note.is_none());
    assert!(report.freelist_pages_before > 0);
    assert_eq!(report.freelist_pages_after, 0);
    assert!(report.page_count_after < report.page_count_before);
    assert_eq!(report.wal_bytes_after, 0);
    assert!(report.reclaimed_bytes > 0);
    assert!(
        report.file_size_bytes_after + report.wal_bytes_after
            < report.file_size_bytes_before + report.wal_bytes_before
    );
    assert!(report.duration_seconds >= 0.0);

    // The report's after-size is the REAL file size on disk.
    let on_disk = std::fs::metadata(&path).expect("stat").len() as i64;
    assert_eq!(on_disk, report.file_size_bytes_after);

    // Post-maintenance the estimate collapses to 0 (no freelist, no WAL).
    assert_eq!(storage.estimated_reclaimable_bytes().expect("estimate"), 0);

    // Data written before maintenance is untouched (VACUUM is lossless).
    assert_eq!(storage.row_store().count("bulk", None).expect("count"), 0);
}

// ─────────────────────────────────────────────────────────────────────
// Progress
// ─────────────────────────────────────────────────────────────────────

#[test]
fn progress_reports_all_phases_in_order() {
    let path = scratch_path("progress");
    let storage = make_sqlite(&path);
    storage.open(&schema()).expect("open");
    churn(&storage);

    let phases: Mutex<Vec<MaintenancePhase>> = Mutex::new(vec![]);
    let record = |p: persistence_kit::maintenance::MaintenanceProgress| {
        phases.lock().unwrap().push(p.phase);
    };
    storage
        .perform_maintenance(Some(&record), None)
        .expect("maintenance");
    assert_eq!(
        *phases.lock().unwrap(),
        vec![
            MaintenancePhase::Preflight,
            MaintenancePhase::WalCheckpoint,
            MaintenancePhase::Vacuum,
            MaintenancePhase::Introspection,
        ]
    );
}

// ─────────────────────────────────────────────────────────────────────
// Cancellation
// ─────────────────────────────────────────────────────────────────────

#[test]
fn cancellation_is_honoured_at_the_phase_boundary() {
    let path = scratch_path("cancel");
    let storage = make_sqlite(&path);
    storage.open(&schema()).expect("open");
    churn(&storage);

    // Cancel at the third boundary — the VACUUM phase. The checkpoint has
    // run; the freelist must be UNTOUCHED (no partial reclaim).
    let calls = AtomicUsize::new(0);
    let cancel = || calls.fetch_add(1, Ordering::SeqCst) + 1 >= 3;
    let result = storage.perform_maintenance(None, Some(&cancel));
    assert_eq!(
        result.unwrap_err(),
        MaintenanceError::Cancelled {
            at_phase: MaintenancePhase::Vacuum
        }
    );
    // Freelist pages still awaiting reclaim — cancellation lost nothing.
    assert!(storage.estimated_reclaimable_bytes().expect("estimate") > 0);
}

// ─────────────────────────────────────────────────────────────────────
// Quiescence
// ─────────────────────────────────────────────────────────────────────

#[test]
fn open_transaction_is_rejected_not_quiescent() {
    let path = scratch_path("quiesce");
    let storage = make_sqlite(&path);
    storage.open(&schema()).expect("open");

    let observed: Mutex<Option<MaintenanceError>> = Mutex::new(None);
    storage
        .transaction(IsolationLevel::Serializable, &mut |_txn| {
            // The estate connection holds an open transaction here; the
            // maintenance pass must refuse rather than deadlock or corrupt.
            let err = storage
                .perform_maintenance(None, None)
                .expect_err("must refuse inside a transaction");
            *observed.lock().unwrap() = Some(err);
            Ok(())
        })
        .expect("transaction");
    assert_eq!(
        observed.lock().unwrap().clone(),
        Some(MaintenanceError::NotQuiescent {
            reason: "a transaction is open on the estate connection".to_string()
        })
    );

    // After the transaction commits, maintenance proceeds normally.
    let report = storage.perform_maintenance(None, None).expect("maintenance");
    assert!(report.performed);
}

// ─────────────────────────────────────────────────────────────────────
// Explicit in-memory behaviour
// ─────────────────────────────────────────────────────────────────────

#[test]
fn in_memory_backend_is_an_explicit_no_op() {
    let storage = InMemoryStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
    ));
    storage.open(&schema()).expect("open");
    assert_eq!(storage.estimated_reclaimable_bytes().expect("estimate"), 0);
    let report = storage.perform_maintenance(None, None).expect("maintenance");
    assert_eq!(report.backend, "inmemory");
    assert!(!report.performed);
    assert!(report.note.is_some());
    assert_eq!(report.reclaimed_bytes, 0);
}
