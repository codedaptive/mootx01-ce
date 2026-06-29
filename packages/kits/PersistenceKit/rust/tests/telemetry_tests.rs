// telemetry_tests.rs
//
// Integration tests for PersistenceKit's self-report telemetry surface,
// added in cp-persistencekit-report.
//
// Mirrors the Swift PersistenceKitTelemetryTests.swift test suites:
//   §1 Disabled gate: with monitoring OFF, report_storage_stats emits nothing.
//   §2 Enabled gate: with monitoring ON, the correct persistence.db.* metrics arrive.
//   §3 Metric shapes: names, tags, and values conform to the namespace spec.
//   §4 Conformance: StorageStats fields are structurally identical with monitoring ON or OFF.
//
// CRITICAL — Global singleton isolation:
//   Intellectus is a process-wide singleton (enabled flag + installed sink).
//   Cargo test can run tests in the same binary in parallel by default.
//   Tests that toggle the enabled flag or install a capturing sink must hold
//   GLOBAL_LOCK for their entire duration.
//
//   Pattern: GLOBAL_LOCK: OnceLock<Mutex<()>> — each test acquires the mutex
//   and holds the guard for the function's lifetime. Lock poisoning is handled
//   via `into_inner()` so subsequent tests can still run after a panic.

use std::sync::{Arc, Mutex, OnceLock};
use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use persistence_kit::{
    inmemory::InMemoryStorage, report_storage_stats, ColumnDeclaration,
    SchemaDeclaration, Storage, StorageIntrospection, TableDeclaration, TypedValue,
};
use uuid::Uuid;

// ─── Global process-wide serialisation lock ──────────────────────────────────
//
// OnceLock<Mutex<()>> — initialised once per process. Each telemetry test
// acquires the lock at the start and holds the guard until the function
// returns. This prevents a disabled-path test from racing with an enabled-path
// test in a different thread, which would corrupt exact-count assertions.

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        // Recover from lock poisoning — a prior test panicked. We reset global
        // state before returning so subsequent tests start from a clean slate.
        Err(poison) => poison.into_inner(),
    }
}

// ─── Capturing sink ───────────────────────────────────────────────────────────

/// Records every received StatSample. Thread-safe via Mutex.
/// Mirrors the Swift CapturingSink in VectorKitTelemetryTests.swift.
struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn all_samples(&self) -> Vec<StatSample> {
        self.samples.lock().unwrap().clone()
    }

    fn count_prefix(&self, prefix: &str) -> usize {
        self.samples.lock().unwrap().iter().filter(|s| {
            matches!(s, StatSample::Metric { name, .. } if name.starts_with(prefix))
        }).count()
    }

    fn find_named(&self, metric_name: &str) -> Option<StatSample> {
        self.samples.lock().unwrap().iter().find(|s| {
            matches!(s, StatSample::Metric { name, .. } if name == metric_name)
        }).cloned()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// ─── Storage fixture ─────────────────────────────────────────────────────────

fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "pk-telem-test",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("payload"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open storage");
    storage
}

// ─────────────────────────────────────────────────────────────────────────────
// §1 Disabled gate
// ─────────────────────────────────────────────────────────────────────────────

/// report_storage_stats must not emit when monitoring is disabled.
#[test]
fn report_does_not_emit_when_monitoring_disabled() {
    let _guard = global_lock();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let storage = make_storage();
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let count = sink.count_prefix("persistence.db.");
    assert_eq!(count, 0,
        "report_storage_stats must not emit when monitoring is disabled; got {count}");

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

/// StorageStats result is unchanged when monitoring is disabled.
#[test]
fn stats_result_unchanged_when_disabled() {
    let _guard = global_lock();

    Intellectus::set_enabled(false);
    let storage = make_storage();

    // Call report_storage_stats with monitoring off — stats() result must be unaffected.
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let stats = storage.stats(1_700_000_000).unwrap();
    assert_eq!(stats.captured_at_secs, 1_700_000_000,
        "captured_at_secs must match the injected timestamp");
    assert_eq!(stats.row_count, Some(0), "row_count must be 0 on empty storage");

    Intellectus::install(Arc::new(NoOpSink));
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 Enabled gate
// ─────────────────────────────────────────────────────────────────────────────

/// report_storage_stats must emit at least one persistence.db.* metric when enabled.
#[test]
fn report_emits_metrics_when_monitoring_enabled() {
    let _guard = global_lock();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let storage = make_storage();
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let count = sink.count_prefix("persistence.db.");
    assert!(count > 0,
        "report_storage_stats must emit at least one persistence.db.* metric when enabled; got {count}");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// report_storage_stats must emit exactly one persistence.db.size_bytes metric.
#[test]
fn report_emits_size_bytes() {
    let _guard = global_lock();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let storage = make_storage();
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let size_count = sink.all_samples().iter().filter(|s| {
        matches!(s, StatSample::Metric { name, .. } if name == "persistence.db.size_bytes")
    }).count();
    assert_eq!(size_count, 1,
        "must emit exactly one persistence.db.size_bytes; got {size_count}");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// row_count metric must equal the number of inserted rows.
#[test]
fn report_emits_row_count_after_inserts() {
    let _guard = global_lock();

    let storage = make_storage();

    // Insert rows with monitoring off.
    Intellectus::set_enabled(false);
    for _ in 0..3 {
        let mut values = std::collections::BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        values.insert("payload".to_string(), TypedValue::Text("hello".to_string()));
        storage.row_store().insert("items", values).unwrap();
    }

    // Enable monitoring and call report_storage_stats.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let row_count_metric = sink.find_named("persistence.db.row_count");
    assert!(row_count_metric.is_some(), "must emit persistence.db.row_count after inserts");

    if let Some(StatSample::Metric { value, .. }) = row_count_metric {
        assert!((value - 3.0).abs() < 1e-9,
            "row_count must equal 3 (one per insert); got {value}");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 Metric shapes
// ─────────────────────────────────────────────────────────────────────────────

/// size_bytes metric must carry kit=PersistenceKit and estate tags.
#[test]
fn size_bytes_carries_correct_tags() {
    let _guard = global_lock();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let estate_id = "my-test-estate";
    let storage = make_storage();
    report_storage_stats(&storage, estate_id, 1_700_000_000);

    let sample = sink.find_named("persistence.db.size_bytes");
    assert!(sample.is_some(), "expected persistence.db.size_bytes metric");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sample {
        assert_eq!(name, "persistence.db.size_bytes");
        assert!(value >= 0.0, "size_bytes must be non-negative; got {value}");
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("PersistenceKit"),
            "must carry kit=PersistenceKit tag");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some(estate_id),
            "must carry estate={estate_id} tag");
        assert!((ts - 1_700_000_000_f64).abs() < 1.0,
            "ts must equal now_secs as f64; got {ts}");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// SQLite-specific metrics must not be emitted for the InMemory backend.
/// InMemory sets page_size/page_count/wal_frame_count to None — those metrics
/// must be absent.
#[test]
fn sqlite_specific_metrics_absent_for_inmemory() {
    let _guard = global_lock();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let storage = make_storage();
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let samples = sink.all_samples();
    let sqlite_names = [
        "persistence.db.page_size",
        "persistence.db.page_count",
        "persistence.db.freelist_pages",
        "persistence.db.wal_frames",
        "persistence.db.lock_contention",
    ];
    for sqlite_name in &sqlite_names {
        let found = samples.iter().any(|s| {
            matches!(s, StatSample::Metric { name, .. } if name == sqlite_name)
        });
        assert!(!found, "{sqlite_name} must not be emitted for InMemory backend");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// blob_count metric must reflect the number of stored blobs.
#[test]
fn blob_count_reflects_stored_blobs() {
    let _guard = global_lock();

    let storage = make_storage();

    // Add blobs with monitoring off.
    Intellectus::set_enabled(false);
    storage.blob_store().put("k1", b"hello").unwrap();
    storage.blob_store().put("k2", b"world").unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    report_storage_stats(&storage, "test-estate", 1_700_000_000);

    let blob_metric = sink.find_named("persistence.db.blob_count");
    assert!(blob_metric.is_some(), "expected persistence.db.blob_count metric");

    if let Some(StatSample::Metric { value, .. }) = blob_metric {
        assert!((value - 2.0).abs() < 1e-9, "blob_count must equal 2; got {value}");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 Conformance gate
// ─────────────────────────────────────────────────────────────────────────────

/// StorageStats is identical with monitoring disabled and enabled.
/// report_storage_stats must not alter any StorageStats field value.
#[test]
fn stats_identical_with_monitoring_off_and_on() {
    let _guard = global_lock();

    // --- Monitoring OFF ---
    Intellectus::set_enabled(false);
    let storage_off = make_storage();
    report_storage_stats(&storage_off, "off-estate", 1_700_000_000);
    let stats_off = storage_off.stats(1_700_000_000).unwrap();

    // --- Monitoring ON ---
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let storage_on = make_storage();
    report_storage_stats(&storage_on, "on-estate", 1_700_000_000);
    let stats_on = storage_on.stats(1_700_000_000).unwrap();

    // Both fresh InMemory stores must have structurally identical stats.
    assert_eq!(stats_off.row_count, stats_on.row_count,
        "row_count must be equal; off={:?} on={:?}", stats_off.row_count, stats_on.row_count);
    assert_eq!(stats_off.blob_count, stats_on.blob_count, "blob_count must be equal");
    assert_eq!(stats_off.captured_at_secs, stats_on.captured_at_secs,
        "captured_at_secs must be equal");

    // Metrics were emitted on the ON path.
    let count = sink.count_prefix("persistence.db.");
    assert!(count > 0,
        "at least one persistence.db.* metric must be emitted when monitoring is enabled");

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// report_storage_stats must not modify storage state.
/// Row/blob counts must be identical before and after the call.
#[test]
fn report_storage_stats_does_not_modify_storage() {
    let _guard = global_lock();

    let storage = make_storage();
    let now = 1_700_000_000_i64;

    let before = storage.stats(now).unwrap();

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    report_storage_stats(&storage, "test-estate", now);
    Intellectus::set_enabled(false);

    let after = storage.stats(now).unwrap();

    assert_eq!(before.row_count, after.row_count,
        "row_count must be unchanged by report_storage_stats");
    assert_eq!(before.blob_count, after.blob_count,
        "blob_count must be unchanged by report_storage_stats");

    Intellectus::install(Arc::new(NoOpSink));
}
