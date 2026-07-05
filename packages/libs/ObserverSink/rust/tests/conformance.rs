// conformance.rs
//
// Both-ports conformance tests for ObserverSink (Rust port).
//
// Mirrors ObserverSinkConformanceTests.swift exactly — same twelve scenarios:
//   1. Schema/open — schema version correct.
//   2. Control rows seeded on open — monitoring defaults to off.
//   3. Monitoring flag write-read round-trip.
//   4. Metric emit path via StatsSink → stored → readback matches.
//   5. Event emit path via StatsSink → stored → readback matches.
//   6. Monitoring off — sink discards samples.
//   7. Retention: deleteMetricsBefore rolls off old rows, keeps new.
//   8. Retention: deleteEventsBefore rolls off old event rows, keeps new.
//   9. Tags JSON round-trip.
//  10. Empty tags round-trip.
//  11. Monitoring flag set to ON survives closing and re-opening the store.
//       (regression lock for the seed-if-absent fix — seed-if-absent must NOT
//        overwrite an operator-set "monitoring"="1" on reopen)
//  12. storageStats reports the SQLite-backed store's own DB-layer health.
//
// Schema parity with Swift:
//   Same table names, same column names, same TEXT (ISO-8601) timestamp format.
//   Timestamp comparisons use 1-second tolerance (millisecond encoding rounding).

use observer_sink::{PersistenceStatsSink, StatsStore};
use intellectus_lib::{EventKind, Intellectus, StatSample};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
// StatsStore::new is needed for the reopen test (testing a named path across two open cycles).
// StorageStats is re-exported from observer_sink for callers naming the return type.

// ─────────────────────────────────────────────────────────────────────────────
// Global test serialization for the Intellectus global singleton.
//
// Intellectus holds a process-wide installed sink and enabled flag. Tests that
// install a sink and report through the global (tests 4, 5, 6) race each other
// when the test runner's thread pool schedules them concurrently. Each such test
// must hold this mutex for the duration of its install → report → query →
// disable cycle so only one Intellectus-global consumer is active at a time.
// ─────────────────────────────────────────────────────────────────────────────
static INTELLECTUS_TEST_LOCK: std::sync::LazyLock<Mutex<()>> =
    std::sync::LazyLock::new(|| Mutex::new(()));

/// Create a temporary SQLite path for each test (unique per-test UUID in the name).
fn make_temp_path() -> String {
    let id = uuid::Uuid::new_v4();
    std::env::temp_dir()
        .join(format!("observer-sink-test-{id}.sqlite"))
        .to_string_lossy()
        .to_string()
}

/// Open a fresh StatsStore at a temporary path.
fn make_store() -> Arc<StatsStore> {
    let path = make_temp_path();
    let store = StatsStore::new(&path).expect("StatsStore::new");
    store.open().expect("StatsStore::open");
    Arc::new(store)
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Schema / open
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn schema_version() {
    // Schema version 3: topology_snapshots.topology_fingerprint added (v2→v3).
    assert_eq!(StatsStore::SCHEMA_VERSION, 3);
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Control rows seeded on open — wave 8.1: monitoring defaults ON
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn control_rows_seeded_on_open() {
    let store = make_store();
    let monitoring_on = store.is_monitoring_enabled().expect("is_monitoring_enabled");
    // Wave 8.1: monitoring defaults to ON for new estates.
    assert!(monitoring_on, "Expected monitoring ON by default (wave 8.1)");
}

/// Wave 8.1: setMonitoringEnabled writes monitoring_source="user" so the
/// one-time migration in open() never reverts an explicit operator choice.
/// Mirrors Swift `monitoringUserSourceMarkerPreventsRevert`.
#[test]
fn monitoring_user_source_marker_prevents_revert() {
    // Open a named path so we can re-open it and test migration.
    let path = make_temp_path();
    let store1 = StatsStore::new(&path).expect("StatsStore::new");
    store1.open().expect("open");

    // Fresh estate: monitoring defaults ON, source=default.
    assert!(store1.is_monitoring_enabled().expect("is_monitoring_enabled"));

    // Operator explicitly turns monitoring off → source becomes "user".
    store1.set_monitoring_enabled(false).expect("set false");
    assert!(!store1.is_monitoring_enabled().expect("is_monitoring_enabled"));
    store1.close().expect("close");

    // Re-open: migration must NOT flip monitoring back to "1" because source="user".
    let store2 = StatsStore::new(&path).expect("StatsStore::new");
    store2.open().expect("open");
    assert!(
        !store2.is_monitoring_enabled().expect("is_monitoring_enabled"),
        "User-set monitoring=off must survive a store re-open (wave 8.1 migration must not revert it)"
    );
    store2.close().expect("close");
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Monitoring flag round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn monitoring_flag_round_trip() {
    let store = make_store();

    // Wave 8.1 default: ON.
    assert!(store.is_monitoring_enabled().unwrap(), "Expected monitoring ON by default (wave 8.1)");

    // Disable.
    store.set_monitoring_enabled(false).unwrap();
    assert!(!store.is_monitoring_enabled().unwrap());

    // Re-enable.
    store.set_monitoring_enabled(true).unwrap();
    assert!(store.is_monitoring_enabled().unwrap());
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Metric emit path via StatsSink
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn metric_emit_readback() {
    // Serialize Intellectus-global tests — see INTELLECTUS_TEST_LOCK above.
    let _lock = INTELLECTUS_TEST_LOCK.lock().unwrap();

    let store = make_store();
    store.set_monitoring_enabled(true).unwrap();

    let dropbox_id = "rust-test-dropbox-metric";
    let sink = Arc::new(PersistenceStatsSink::new(Arc::clone(&store), dropbox_id.to_string()));
    Intellectus::install(sink);
    Intellectus::set_enabled(true);

    let ts: f64 = 1_700_000_000.0;
    let mut tags = std::collections::HashMap::new();
    tags.insert("kit".to_string(), "TestKit".to_string());
    tags.insert("op".to_string(), "capture".to_string());

    Intellectus::report_sample(StatSample::metric(
        "locus.capture.latency_ms".to_string(),
        42.0,
        tags,
        ts,
    ));

    // Rust sink is synchronous — no need to sleep; the insert happened inline.
    let rows = store.query_metrics(Some(dropbox_id)).unwrap();
    assert_eq!(rows.len(), 1, "Expected exactly one metric row");

    let row = rows.into_iter().next().unwrap();
    assert_eq!(row.name, "locus.capture.latency_ms");
    assert_eq!(row.value, 42.0);
    assert_eq!(row.tags.get("kit").map(|s| s.as_str()), Some("TestKit"));
    assert_eq!(row.tags.get("op").map(|s| s.as_str()), Some("capture"));
    assert_eq!(row.dropbox_id, dropbox_id);
    // ts stored as ISO-8601 TEXT; decoded back as epoch seconds (i64 via Timestamp).
    // Allow 1-second tolerance for millisecond rounding.
    assert!((row.ts_epoch - ts).abs() < 1.0, "ts mismatch: {} vs {}", row.ts_epoch, ts);

    Intellectus::set_enabled(false);
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Event emit path via StatsSink
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn event_emit_readback() {
    // Serialize Intellectus-global tests — see INTELLECTUS_TEST_LOCK above.
    let _lock = INTELLECTUS_TEST_LOCK.lock().unwrap();

    let store = make_store();
    store.set_monitoring_enabled(true).unwrap();

    let dropbox_id = "rust-test-dropbox-event";
    let sink = Arc::new(PersistenceStatsSink::new(Arc::clone(&store), dropbox_id.to_string()));
    Intellectus::install(sink);
    Intellectus::set_enabled(true);

    let ts: f64 = 1_700_000_001.0;
    let row_uuid = uuid::Uuid::new_v4().to_string();
    let estate_id = "estate-abc-123";

    Intellectus::report_sample(StatSample::event(
        EventKind::Think,
        7,
        row_uuid.clone(),
        estate_id.to_string(),
        ts,
    ));

    let rows = store.query_events(Some(dropbox_id)).unwrap();
    assert_eq!(rows.len(), 1, "Expected exactly one event row");

    let row = rows.into_iter().next().unwrap();
    assert_eq!(row.kind, "think");
    assert_eq!(row.noun_type, 7);
    assert_eq!(row.estate_row_id, row_uuid);
    assert_eq!(row.estate, estate_id);
    assert_eq!(row.dropbox_id, dropbox_id);
    assert!((row.ts_epoch - ts).abs() < 1.0, "ts mismatch: {} vs {}", row.ts_epoch, ts);

    Intellectus::set_enabled(false);
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Monitoring off — sink discards samples
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn sink_discards_when_monitoring_off() {
    // Serialize Intellectus-global tests — see INTELLECTUS_TEST_LOCK above.
    let _lock = INTELLECTUS_TEST_LOCK.lock().unwrap();

    let store = make_store();
    // Wave 8.1: monitoring defaults ON — disable explicitly to exercise the discard path.
    store.set_monitoring_enabled(false).expect("set_monitoring_enabled(false)");

    let dropbox_id = "rust-test-dropbox-off";
    let sink = Arc::new(PersistenceStatsSink::new(Arc::clone(&store), dropbox_id.to_string()));
    Intellectus::install(sink);
    Intellectus::set_enabled(true);

    Intellectus::report_sample(StatSample::metric(
        "should.not.land".to_string(),
        99.0,
        Default::default(),
        1_000_000.0,
    ));

    let rows = store.query_metrics(Some(dropbox_id)).unwrap();
    assert!(rows.is_empty(), "Expected no rows when monitoring is off");

    Intellectus::set_enabled(false);
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Retention: deleteMetricsBefore
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn retention_metrics() {
    let store = make_store();
    let dropbox_id = "rust-test-retention-metrics";

    let cutoff_secs = 1000.0_f64;
    let now_secs = 2000.0_f64;

    // Two old rows (ts < cutoff).
    store.insert_metric("old.metric", 1.0, &BTreeMap::new(), 500.0, dropbox_id).unwrap();
    store.insert_metric("old.metric", 2.0, &BTreeMap::new(), 999.0, dropbox_id).unwrap();

    // Two new rows (ts >= cutoff).
    store.insert_metric("new.metric", 3.0, &BTreeMap::new(), 1000.0, dropbox_id).unwrap();
    store.insert_metric("new.metric", 4.0, &BTreeMap::new(), 1500.0, dropbox_id).unwrap();

    let before_count = store.query_metrics(Some(dropbox_id)).unwrap().len();
    assert_eq!(before_count, 4);

    let deleted = store.delete_metrics_before(cutoff_secs, now_secs).unwrap();
    assert_eq!(deleted, 2, "Expected 2 old rows deleted");

    let after_rows = store.query_metrics(Some(dropbox_id)).unwrap();
    assert_eq!(after_rows.len(), 2, "Expected 2 new rows kept");

    for row in &after_rows {
        assert!(
            row.ts_epoch >= cutoff_secs - 1.0,
            "Survived row ts {} should be >= cutoff {}", row.ts_epoch, cutoff_secs
        );
        assert_eq!(row.name, "new.metric");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Retention: deleteEventsBefore
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn retention_events() {
    let store = make_store();
    let dropbox_id = "rust-test-retention-events";
    let cutoff_secs = 1000.0_f64;
    let now_secs = 2000.0_f64;

    let uuid1 = uuid::Uuid::new_v4().to_string();
    let uuid2 = uuid::Uuid::new_v4().to_string();
    let uuid3 = uuid::Uuid::new_v4().to_string();
    let uuid4 = uuid::Uuid::new_v4().to_string();

    store.insert_event("capture", 1, &uuid1, "e1", 500.0, dropbox_id).unwrap();
    store.insert_event("think", 2, &uuid2, "e1", 999.0, dropbox_id).unwrap();
    store.insert_event("capture", 3, &uuid3, "e1", 1000.0, dropbox_id).unwrap();
    store.insert_event("think", 4, &uuid4, "e1", 1500.0, dropbox_id).unwrap();

    let deleted = store.delete_events_before(cutoff_secs, now_secs).unwrap();
    assert_eq!(deleted, 2);

    let after_rows = store.query_events(Some(dropbox_id)).unwrap();
    assert_eq!(after_rows.len(), 2);

    for row in &after_rows {
        assert!(row.ts_epoch >= cutoff_secs - 1.0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Tags JSON round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn tags_json_round_trip() {
    let store = make_store();
    let dropbox_id = "rust-test-tags";

    let mut tags = BTreeMap::new();
    tags.insert("alpha".to_string(), "one".to_string());
    tags.insert("beta".to_string(), "two".to_string());
    tags.insert("gamma".to_string(), "three".to_string());

    store.insert_metric("tags.test", 0.0, &tags, 1_000_000.0, dropbox_id).unwrap();

    let rows = store.query_metrics(Some(dropbox_id)).unwrap();
    let row = rows.into_iter().next().expect("Expected a row");
    assert_eq!(row.tags.get("alpha").map(|s| s.as_str()), Some("one"));
    assert_eq!(row.tags.get("beta").map(|s| s.as_str()), Some("two"));
    assert_eq!(row.tags.get("gamma").map(|s| s.as_str()), Some("three"));
    assert_eq!(row.tags.len(), 3);
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. Empty tags
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn empty_tags_round_trip() {
    let store = make_store();
    let dropbox_id = "rust-test-emptytags";

    store.insert_metric("no.tags", 5.0, &BTreeMap::new(), 1_000_000.0, dropbox_id).unwrap();

    let rows = store.query_metrics(Some(dropbox_id)).unwrap();
    let row = rows.into_iter().next().expect("Expected a row");
    assert!(row.tags.is_empty());
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. Monitoring flag survives store close + reopen (seed-if-absent regression lock)
//
// This test is the regression lock for the seed-if-absent fix (Swift commit
// 852821cc). Before the fix, `open()` unconditionally upserted "monitoring"="0"
// on every open, so a persistent "1" set by the operator was silently reset to
// "0" on process restart — the global on/off switch could never stay ON.
//
// Correct behaviour: seed-if-absent means the first open installs the default
// ("0") and every subsequent open is a no-op for that row. An operator-set
// "monitoring"="1" must survive a close + reopen cycle.
//
// Mirrors Swift test `monitoringFlagSurvivesReopen`.
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn monitoring_flag_survives_reopen() {
    // Use a named temp file so we can reopen the same path.
    let path = make_temp_path();

    // First open: install defaults.
    {
        let store = StatsStore::new(&path).expect("StatsStore::new (first open)");
        store.open().expect("open (first open)");

        // Wave 8.1: default is ON.
        assert!(store.is_monitoring_enabled().unwrap(), "Wave 8.1: default must be ON");

        // Operator turns it OFF — source becomes "user", migration must not flip it back.
        store.set_monitoring_enabled(false).unwrap();
        assert!(!store.is_monitoring_enabled().unwrap(), "Must be off after set");

        // Close — simulates process restart boundary.
        store.close().expect("close");
    }

    // Second open: seed-if-absent + migration must preserve the operator's "0".
    {
        let store = StatsStore::new(&path).expect("StatsStore::new (reopen)");
        store.open().expect("open (reopen)");

        // The monitoring flag must still be "0" — migration must not revert operator's choice.
        assert!(
            !store.is_monitoring_enabled().unwrap(),
            "Operator-set monitoring=off must survive a close/reopen cycle (wave 8.1 migration guard)"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. storageStats reports the SQLite-backed store's own DB-layer health
//
// Mirrors Swift test `storageStatsReportsBackendHealth`.
//
// Verifies:
//   - storage_stats() returns Some(StorageStats) for the SQLite backend.
//   - The snapshot is stamped with the caller-supplied now_secs (determinism).
//   - SQLite-specific fields (page_size, page_count, freelist_page_count,
//     wal_frame_count) are Some (SQLite backend always populates them).
//   - logical_size_bytes > 0 (the freshly-opened store has at least the
//     header page).
//   - PostgreSQL-only and InMemory-only fields are None for SQLite.
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn storage_stats_reports_backend_health() {
    let store = make_store();

    // Insert a metric so the DB is non-trivially populated.
    store
        .insert_metric("stats.test", 1.0, &BTreeMap::new(), 1_700_000_000.0, "stats-test-dropbox")
        .unwrap();

    // Caller-supplied timestamp (determinism: no SystemTime::now() inside engine).
    let now_secs: i64 = 1_700_000_100;
    let stats_opt = store.storage_stats(now_secs).expect("storage_stats failed");

    let stats = stats_opt.expect("Expected Some(StorageStats) for SQLite backend");

    // The snapshot must be stamped with the caller-supplied now_secs.
    assert_eq!(
        stats.captured_at_secs, now_secs,
        "captured_at_secs must equal the caller-supplied now_secs (determinism)"
    );

    // logical_size_bytes > 0: even an empty SQLite database occupies at least
    // one page (the header page, always page_size bytes).
    assert!(
        stats.logical_size_bytes > 0,
        "logical_size_bytes must be > 0 for any opened SQLite database"
    );

    // SQLite-specific fields must be Some for the SQLite backend.
    assert!(
        stats.page_size.is_some(),
        "page_size must be Some for SQLite backend"
    );
    assert!(
        stats.page_count.is_some(),
        "page_count must be Some for SQLite backend"
    );
    assert!(
        stats.freelist_page_count.is_some(),
        "freelist_page_count must be Some for SQLite backend"
    );
    // wal_frame_count: Some(N) where N >= 0 for SQLite. The WAL file may not
    // exist yet (journal_mode=WAL auto-creates on first write); either way the
    // field is Some.
    assert!(
        stats.wal_frame_count.is_some(),
        "wal_frame_count must be Some for SQLite backend"
    );

    // PostgreSQL-only fields must be None for SQLite.
    assert!(
        stats.cache_hit_ratio.is_none(),
        "cache_hit_ratio must be None for SQLite backend"
    );
    assert!(
        stats.transaction_commit_count.is_none(),
        "transaction_commit_count must be None for SQLite backend"
    );
    assert!(
        stats.deadlock_count.is_none(),
        "deadlock_count must be None for SQLite backend"
    );

    // InMemory-only fields must be None for SQLite.
    assert!(
        stats.row_count.is_none(),
        "row_count must be None for SQLite backend"
    );
    assert!(
        stats.blob_count.is_none(),
        "blob_count must be None for SQLite backend"
    );
    // vector_count was removed from StorageStats in ADR-008 (blast-radius miss fix).
    // The field no longer exists on the struct; the InMemory-only assertion is gone.
}

// ─────────────────────────────────────────────────────────────────────────────
// 13–16. Topology snapshot — mirrors Swift tests 12–16
// ─────────────────────────────────────────────────────────────────────────────

/// 13. write_topology_snapshot stores payload and latest_topology_snapshot returns it.
#[test]
fn topology_snapshot_round_trip() {
    let store = make_store();
    let estate = "estate-topology-001";
    let generated_at_secs = 1_700_000_000.0f64;
    let payload = r#"{"nodes":[],"edges":[],"communities":[],"structurePending":false,"generatedTs":"2023-11-14T22:13:20.000Z"}"#;

    store
        .write_topology_snapshot(estate, generated_at_secs, payload, None)
        .expect("write_topology_snapshot must succeed");

    let result = store
        .latest_topology_snapshot(Some(estate))
        .expect("latest_topology_snapshot must not error");
    let got = result.expect("Expected Some(payload) after write");
    assert_eq!(got, payload, "Stored payload must round-trip verbatim");
}

/// 13b. write_topology_snapshot persists the fingerprint; load_topology_fingerprint
/// returns it (F5). Mirrors Swift `topologyFingerprintRoundTrip`.
#[test]
fn topology_fingerprint_round_trip() {
    let store = make_store();
    let estate = "estate-topology-fp-001";
    let payload = r#"{"nodes":[],"structurePending":false}"#;
    let fingerprint = "3:1:0:0:0:42:7:18446744073709551615";

    // No fingerprint persisted yet → load returns None.
    let before = store
        .load_topology_fingerprint(estate)
        .expect("load_topology_fingerprint must not error");
    assert_eq!(before, None, "No fingerprint should exist before the first write");

    store
        .write_topology_snapshot(estate, 1_700_000_000.0, payload, Some(fingerprint))
        .expect("write must succeed");

    let after = store
        .load_topology_fingerprint(estate)
        .expect("load_topology_fingerprint must not error");
    assert_eq!(after.as_deref(), Some(fingerprint), "Persisted fingerprint must round-trip verbatim");
}

/// 13c. write_topology_snapshot without a fingerprint leaves the column null (F5).
/// Mirrors Swift `topologyFingerprintNullWhenOmitted`.
#[test]
fn topology_fingerprint_null_when_omitted() {
    let store = make_store();
    let estate = "estate-topology-fp-002";
    let payload = r#"{"structurePending":false}"#;

    store
        .write_topology_snapshot(estate, 1_700_000_000.0, payload, None)
        .expect("write must succeed");

    let fp = store
        .load_topology_fingerprint(estate)
        .expect("load_topology_fingerprint must not error");
    assert_eq!(fp, None, "Omitted fingerprint must read back as None (null column)");
}

/// 13d. A later write updates the persisted fingerprint (F5).
/// Mirrors Swift `topologyFingerprintLatestWins`.
#[test]
fn topology_fingerprint_latest_wins() {
    let store = make_store();
    let estate = "estate-topology-fp-003";
    let payload = r#"{"structurePending":false}"#;

    store
        .write_topology_snapshot(estate, 1_000_000.0, payload, Some("fp-old"))
        .expect("first write must succeed");
    store
        .write_topology_snapshot(estate, 2_000_000.0, payload, Some("fp-new"))
        .expect("second write must succeed");

    let fp = store
        .load_topology_fingerprint(estate)
        .expect("load_topology_fingerprint must not error");
    assert_eq!(fp.as_deref(), Some("fp-new"), "Latest write must supersede the previous fingerprint");
}

/// 14. write_topology_snapshot overwrites the previous snapshot for the same estate.
#[test]
fn topology_snapshot_latest_wins() {
    let store = make_store();
    let estate = "estate-topology-002";

    store
        .write_topology_snapshot(estate, 1_000_000.0, "first-payload", None)
        .expect("first write must succeed");
    store
        .write_topology_snapshot(estate, 2_000_000.0, "second-payload", None)
        .expect("second write must succeed");

    let result = store
        .latest_topology_snapshot(Some(estate))
        .expect("latest_topology_snapshot must not error");
    let got = result.expect("Expected Some after two writes");
    // Latest-wins: only second-payload survives.
    assert_eq!(got, "second-payload", "Second write must supersede the first");
}

/// 15. Topology snapshots for different estates are independent.
#[test]
fn topology_snapshot_per_estate_isolation() {
    let store = make_store();
    let estate_a = "estate-topology-A";
    let estate_b = "estate-topology-B";

    store
        .write_topology_snapshot(estate_a, 1_000_000.0, "payload-A", None)
        .expect("write estate A must succeed");
    store
        .write_topology_snapshot(estate_b, 1_000_000.0, "payload-B", None)
        .expect("write estate B must succeed");

    let got_a = store
        .latest_topology_snapshot(Some(estate_a))
        .expect("read estate A must not error")
        .expect("estate A must be Some");
    let got_b = store
        .latest_topology_snapshot(Some(estate_b))
        .expect("read estate B must not error")
        .expect("estate B must be Some");

    assert_eq!(got_a, "payload-A", "Estate A payload must be isolated");
    assert_eq!(got_b, "payload-B", "Estate B payload must be isolated");
}

/// 16. latest_topology_snapshot returns None for unknown estate.
#[test]
fn topology_snapshot_missing_returns_none() {
    let store = make_store();
    let result = store
        .latest_topology_snapshot(Some("no-such-estate"))
        .expect("query must not error");
    assert!(result.is_none(), "Unknown estate must return None");
}

/// 17. None estate returns the newest snapshot across all estates — the
/// moot-mgr dashboard's default ("all") view reads without an estate key.
#[test]
fn topology_snapshot_none_estate_returns_newest() {
    let store = make_store();
    store
        .write_topology_snapshot("estate-older", 1_000_000.0, "payload-older", None)
        .expect("write older must succeed");
    store
        .write_topology_snapshot("estate-newer", 2_000_000.0, "payload-newer", None)
        .expect("write newer must succeed");

    let got = store
        .latest_topology_snapshot(None)
        .expect("query must not error")
        .expect("must be Some");
    assert_eq!(got, "payload-newer",
               "None estate must return the newest generated_at across estates");
}

/// 17b. Newest wins regardless of write/iteration order — regression for the
/// generated_at tie-break bug (every row read as i64::MIN because the read only
/// matched `Timestamp`, but the column is TEXT ISO-8601, so all rows tied and an
/// arbitrary one won). Newest is written FIRST here, so a tie-break-by-iteration
/// would wrongly return the OLDER row.
#[test]
fn topology_snapshot_none_newest_wins_regardless_of_order() {
    let store = make_store();
    store
        .write_topology_snapshot("estate-newer", 2_000_000.0, "payload-newer", None)
        .expect("write newer must succeed");
    store
        .write_topology_snapshot("estate-older", 1_000_000.0, "payload-older", None)
        .expect("write older must succeed");

    let got = store
        .latest_topology_snapshot(None)
        .expect("query must not error")
        .expect("must be Some");
    assert_eq!(
        got, "payload-newer",
        "newest generated_at must win even when the newer row is written/iterated first"
    );
}

/// 18. None estate returns None on an empty store.
#[test]
fn topology_snapshot_none_estate_empty_store() {
    let store = make_store();
    let result = store
        .latest_topology_snapshot(None)
        .expect("query must not error");
    assert!(result.is_none());
}
