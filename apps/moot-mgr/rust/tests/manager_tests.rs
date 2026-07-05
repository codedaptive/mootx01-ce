// manager_tests.rs — Rust twin of the Swift MootManagerTests.swift +
// ManagerConfig + CLI coverage. Exercises the manager core (store ownership,
// the monitoring switch, retention, the status surface, and the read-API payload
// builders) and the CLI parse→dispatch path. All against SCRATCH stores in a
// temp dir; the real estate and ~/.mempalace are never touched.

use std::collections::BTreeMap;

use moot_mgr::manager::{epoch_to_iso8601, ManagerError, MootManager};
use moot_mgr::manager_cli::{self, ManagerCommand};
use moot_mgr::manager_config::ManagerConfig;

/// A fresh, unique scratch store path inside its OWN temp directory.
///
/// Each store gets a dedicated parent directory (mirrors the Swift
/// `makeTempStoreURL()` helper) so that the retention sidecar
/// (`<store-parent>/moot-mgr-prefs.json`) is unique per test. Putting the
/// store file directly in the shared temp dir would make every test share one
/// sidecar — leaking persisted overrides between tests and racing under
/// parallel execution. `start()` create_dir_all's this parent on open.
fn scratch_store() -> String {
    std::env::temp_dir()
        .join(format!("moot-mgr-rs-{}", uuid::Uuid::new_v4()))
        .join("stats.sqlite")
        .to_string_lossy()
        .into_owned()
}

fn started_manager() -> MootManager {
    let cfg = ManagerConfig::new(scratch_store(), 7 * 24 * 60 * 60, 3600);
    let mut m = MootManager::new(cfg);
    m.start().expect("store must open");
    m
}

const NOW: f64 = 1_700_000_000.0;

// ───────────────────────────── lifecycle / store ───────────────────────────

#[test]
fn operations_before_start_error() {
    let cfg = ManagerConfig::new(scratch_store(), 100, 100);
    let m = MootManager::new(cfg);
    assert!(matches!(m.is_monitoring(), Err(ManagerError::NotStarted)));
}

#[test]
fn monitoring_switch_round_trips() {
    let mut m = started_manager();
    // Wave 8.1 (v1.0.17): monitoring defaults ON for new stores so the read
    // plane is live immediately. The seed value is "1", not "0".
    assert!(m.is_monitoring().unwrap()); // on by default (wave 8.1 seed)
    m.set_monitoring(false).unwrap();
    assert!(!m.is_monitoring().unwrap());
    m.set_monitoring(true).unwrap();
    assert!(m.is_monitoring().unwrap());
    m.stop();
}

#[test]
fn start_is_idempotent() {
    let cfg = ManagerConfig::new(scratch_store(), 100, 100);
    let mut m = MootManager::new(cfg);
    m.start().unwrap();
    // Re-open cleanly (StatsStore::open is forward-only).
    m.start().unwrap();
    m.stop();
}

// ───────────────────────────── retention ───────────────────────────────────

#[test]
fn retention_override_survives_restart() {
    // Two manager instances share one store path; the second must restore the
    // window set by the first from the persisted sidecar. Mirrors the Swift
    // test `retentionOverrideSurvivesRestart` in MootManagerRetentionPersistenceTests.
    let store_path = scratch_store();
    let custom_window: i64 = 42 * 60; // 42 minutes, arbitrary non-default

    // First manager: set a custom window and stop.
    {
        let cfg = ManagerConfig::new(store_path.clone(), 7 * 24 * 60 * 60, 3600);
        let mut m = MootManager::new(cfg);
        m.start().expect("first start must succeed");
        m.set_retention(custom_window)
            .expect("set_retention must accept a positive window");
        assert_eq!(
            m.effective_retention_window_secs(),
            custom_window,
            "in-process override must apply immediately"
        );
        m.stop();
    }

    // Second manager at the same path: the override must be restored from the sidecar.
    {
        let cfg = ManagerConfig::new(store_path, 7 * 24 * 60 * 60, 3600);
        let mut m = MootManager::new(cfg);
        m.start().expect("second start must succeed");
        assert_eq!(
            m.effective_retention_window_secs(),
            custom_window,
            "retention override must survive restart via persisted sidecar"
        );
        m.stop();
    }
}

#[test]
fn invalid_retention_does_not_corrupt_sidecar() {
    // A rejected set_retention call must not change the persisted or in-memory value.
    // Mirrors the Swift test `invalidRetentionIsRejected`.
    let cfg = ManagerConfig::new(scratch_store(), 7 * 24 * 60 * 60, 3600);
    let mut m = MootManager::new(cfg);
    m.start().expect("store must open");

    let valid_window: i64 = 3600;
    m.set_retention(valid_window).expect("valid window must be accepted");
    assert_eq!(m.effective_retention_window_secs(), valid_window);

    // Non-positive window must be rejected.
    assert!(
        matches!(m.set_retention(0), Err(ManagerError::InvalidRetention)),
        "zero window must be rejected"
    );
    // In-memory override must be unchanged after the rejection.
    assert_eq!(
        m.effective_retention_window_secs(),
        valid_window,
        "failed set_retention must leave the existing override intact"
    );
    m.stop();
}

#[test]
fn retention_window_override_takes_effect() {
    let mut m = started_manager();
    assert_eq!(m.effective_retention_window_secs(), 7 * 24 * 60 * 60);
    m.set_retention(3600).unwrap();
    assert_eq!(m.effective_retention_window_secs(), 3600);
    // Non-positive window rejected.
    assert!(matches!(
        m.set_retention(0),
        Err(ManagerError::InvalidRetention)
    ));
    m.stop();
}

#[test]
fn retention_pass_rolls_off_old_samples() {
    let mut m = started_manager();
    m.set_retention(100).unwrap(); // 100-second window
    let store = m.stats_store().unwrap();
    // One old event (well before cutoff) and one fresh.
    store
        .insert_event("capture", 0, "row-old", "estate-a", NOW - 1000.0, "dropbox-x")
        .unwrap();
    store
        .insert_event("capture", 0, "row-new", "estate-a", NOW - 1.0, "dropbox-x")
        .unwrap();
    // cutoff = NOW - 100 → the old event (NOW-1000) is rolled off, the fresh kept.
    let deleted = m.run_retention(NOW).unwrap();
    assert!(deleted >= 1, "the stale event must be rolled off");
    let remaining = m.stats_store().unwrap().query_events(None).unwrap();
    assert!(remaining.iter().all(|e| e.estate_row_id != "row-old"));
    assert!(remaining.iter().any(|e| e.estate_row_id == "row-new"));
    m.stop();
}

// ───────────────────────────── status surface ──────────────────────────────

#[test]
fn status_groups_by_dropbox_and_estate() {
    let mut m = started_manager();
    {
        let store = m.stats_store().unwrap();
        store.insert_metric("server.rss_mb", 12.0, &BTreeMap::new(), NOW, "dropbox-a").unwrap();
        store.insert_event("capture", 0, "r1", "estate-a", NOW, "dropbox-a").unwrap();
        store.insert_event("think", 1, "r2", "estate-b", NOW, "dropbox-b").unwrap();
    }
    let report = m.status(NOW, 20).unwrap();
    assert_eq!(report.total_events, 2);
    // By-dropbox: dropbox-a has 1 metric + 1 event; dropbox-b has 1 event.
    assert_eq!(report.by_dropbox.len(), 2);
    // By-estate: estate-a and estate-b each have 1 event.
    assert_eq!(report.by_estate.len(), 2);
    // renderText is deterministic and human-readable.
    let text = report.render_text();
    assert!(text.contains("moot-mgr status"));
    assert!(text.contains("by dropbox:"));
    assert!(text.contains("by estate:"));
    m.stop();
}

// ───────────────────────────── read-API payloads ───────────────────────────

#[test]
fn server_payload_reports_totals_and_dropboxes() {
    let mut m = started_manager();
    m.set_monitoring(true).unwrap();
    {
        let store = m.stats_store().unwrap();
        store.insert_metric("server.rss_mb", 42.0, &BTreeMap::new(), NOW, "dropbox-a").unwrap();
        store.insert_event("capture", 0, "r1", "estate-a", NOW, "dropbox-a").unwrap();
    }
    let p = m.server_payload(NOW, 123).unwrap();
    assert!(p.monitoring_enabled);
    assert_eq!(p.uptime_seconds, 123);
    assert_eq!(p.estate_count, 1);
    assert_eq!(p.total_events, 1);
    assert_eq!(p.total_metrics, 1);
    // The latest server.rss_mb sample is surfaced.
    assert_eq!(p.rss_mb, Some(42.0));
    assert!(p.by_dropbox.iter().any(|d| d.name == "dropbox-a"));
    m.stop();
}

#[test]
fn estates_payload_rolls_up_events_per_estate() {
    let mut m = started_manager();
    {
        let store = m.stats_store().unwrap();
        store.insert_event("capture", 0, "r1", "estate-a", NOW - 5.0, "dropbox-a").unwrap();
        store.insert_event("capture", 0, "r2", "estate-a", NOW, "dropbox-a").unwrap();
        store.insert_event("capture", 0, "r3", "estate-b", NOW, "dropbox-a").unwrap();
    }
    let p = m.estates_payload().unwrap();
    let a = p.estates.iter().find(|e| e.id == "estate-a").unwrap();
    assert_eq!(a.event_count, 2);
    assert!(a.last_event_ts.is_some());
    // admin is populated by the daemon proxy when a daemon is reachable at
    // the configured address; in CI and on machines without a live daemon it
    // is None. The test verifies the rollup shape only — admin presence is
    // environment-dependent and not under the manager's control.
    m.stop();
}

#[test]
fn events_payload_is_newest_first() {
    let mut m = started_manager();
    {
        let store = m.stats_store().unwrap();
        store.insert_event("capture", 0, "old", "e", NOW - 100.0, "d").unwrap();
        store.insert_event("capture", 0, "new", "e", NOW, "d").unwrap();
    }
    let p = m.events_payload(100).unwrap();
    assert_eq!(p.events.len(), 2);
    // Newest first: the NOW event leads.
    assert_eq!(p.events[0].drawer_id.as_deref(), Some("new"));
    m.stop();
}

#[test]
fn config_payload_reflects_monitoring_and_retention() {
    let mut m = started_manager();
    m.set_monitoring(true).unwrap();
    m.set_retention(3600).unwrap();
    let p = m.config_payload().unwrap();
    assert!(p.monitoring_enabled);
    assert_eq!(p.retention_seconds, 3600);
    // No retention pass run yet → epoch-zero sentinel.
    assert_eq!(p.retention_cutoff, "1970-01-01T00:00:00.000Z");
    m.stop();
}

#[test]
fn graph_payload_is_pending_without_snapshot() {
    let mut m = started_manager();
    let p = m.graph_payload(NOW, None).unwrap();
    assert!(p.structure_pending);
    assert!(p.nodes.is_empty());
    assert_eq!(p.estate, "all");
    assert!(!p.pending.is_empty());
    m.stop();
}

#[test]
fn graph_payload_serves_stored_snapshot() {
    let mut m = started_manager();
    {
        let store = m.stats_store().unwrap();
        // A minimal stored snapshot the governor would write.
        let snapshot = r#"{"nodes":[{"id":"n1","nounType":0,"communityId":0,"centrality":0.5,"anomaly":false}],"edges":[],"structurePending":false,"generatedTs":"2023-11-14T22:13:20.000Z"}"#;
        store.write_topology_snapshot("estate-a", NOW, snapshot, None).unwrap();
    }
    let p = m.graph_payload(NOW, Some("estate-a")).unwrap();
    assert!(!p.structure_pending);
    assert_eq!(p.nodes.len(), 1);
    assert_eq!(p.nodes[0].id, "n1");
    assert_eq!(p.estate, "estate-a");
    m.stop();
}

// ───────────────────────────── ISO-8601 formatting ─────────────────────────

#[test]
fn epoch_to_iso8601_is_stable_utc() {
    // 2023-11-14T22:13:20.500Z = 1700000000.5 epoch seconds.
    assert_eq!(epoch_to_iso8601(1_700_000_000.5), "2023-11-14T22:13:20.500Z");
    assert_eq!(epoch_to_iso8601(0.0), "1970-01-01T00:00:00.000Z");
}

// ───────────────────────────── ManagerConfig env ───────────────────────────

#[test]
fn config_from_env_applies_overrides_and_defaults() {
    let mut env = std::collections::HashMap::new();
    env.insert("MOOT_MGR_STORE".to_string(), "/tmp/explicit.sqlite".to_string());
    env.insert("MOOT_MGR_RETENTION_SECONDS".to_string(), "1800".to_string());
    // Cadence absent → default 1 hour.
    let cfg = ManagerConfig::from_environment_map(&env);
    assert_eq!(cfg.store_path, "/tmp/explicit.sqlite");
    assert_eq!(cfg.retention_window_secs, 1800);
    assert_eq!(cfg.retention_cadence_secs, 3600);
}

#[test]
fn config_rejects_non_positive_retention() {
    let mut env = std::collections::HashMap::new();
    env.insert("MOOT_MGR_STORE".to_string(), "/tmp/x.sqlite".to_string());
    env.insert("MOOT_MGR_RETENTION_SECONDS".to_string(), "0".to_string());
    env.insert("MOOT_MGR_RETENTION_CADENCE_SECONDS".to_string(), "-5".to_string());
    let cfg = ManagerConfig::from_environment_map(&env);
    // Zero/negative fall back to defaults (no silent instant-roll-off window).
    assert_eq!(cfg.retention_window_secs, 7 * 24 * 60 * 60);
    assert_eq!(cfg.retention_cadence_secs, 3600);
}

// ───────────────────────────── CLI parse / dispatch ────────────────────────

#[test]
fn cli_parse_recognises_commands() {
    let s = |a: &[&str]| manager_cli::parse(&a.iter().map(|x| x.to_string()).collect::<Vec<_>>());
    assert_eq!(s(&[]), Some(ManagerCommand::Help));
    assert_eq!(s(&["help"]), Some(ManagerCommand::Help));
    assert_eq!(s(&["status"]), Some(ManagerCommand::Status));
    assert_eq!(s(&["serve"]), Some(ManagerCommand::Serve));
    assert_eq!(s(&["monitoring", "on"]), Some(ManagerCommand::MonitoringOn));
    assert_eq!(s(&["monitoring", "off"]), Some(ManagerCommand::MonitoringOff));
    assert_eq!(s(&["monitoring", "status"]), Some(ManagerCommand::MonitoringStatus));
    assert_eq!(s(&["retention", "run"]), Some(ManagerCommand::RetentionRun));
    // Unknown forms → None.
    assert_eq!(s(&["monitoring"]), None);
    assert_eq!(s(&["retention"]), None);
    assert_eq!(s(&["bogus"]), None);
}

#[test]
fn cli_run_dispatches_against_manager() {
    let mut m = started_manager();
    let out = manager_cli::run(&ManagerCommand::MonitoringOn, &mut m, NOW).unwrap();
    assert_eq!(out, "monitoring: ON");
    let out = manager_cli::run(&ManagerCommand::MonitoringStatus, &mut m, NOW).unwrap();
    assert_eq!(out, "monitoring: ON");
    let out = manager_cli::run(&ManagerCommand::RetentionRun, &mut m, NOW).unwrap();
    assert!(out.starts_with("retention: rolled off"));
    let out = manager_cli::run(&ManagerCommand::Status, &mut m, NOW).unwrap();
    assert!(out.contains("moot-mgr status"));
    m.stop();
}

// ─────────────────────── lexicon + lattice payloads ───────────────────────

#[test]
fn lexicon_payload_has_correct_counts() {
    // The payload builder is infallible and requires no store, but the manager
    // still needs to be started (started_manager) to satisfy the type — the
    // builder ignores the store. We use a started manager for consistency.
    let m = started_manager();
    let lex = m.lexicon_payload();

    // 8 nouns, 9 verbs, 4 adjectives — spec invariants I-7, I-8.
    assert_eq!(lex.nouns.len(), 8, "noun count must be 8");
    assert_eq!(lex.verbs.len(), 9, "verb count must be 9");
    assert_eq!(lex.adjectives.len(), 4, "adjective count must be 4");

    // Wire strings match Swift rawValues.
    assert_eq!(lex.nouns[0], "drawer");
    assert_eq!(lex.verbs[0], "capture");
    assert_eq!(lex.adjectives[0], "state");

    // Acceptance map has one entry per noun.
    assert_eq!(lex.acceptance.len(), 8);

    // vector accepts nothing (substrate-managed, not verb-addressable).
    let vector_accepts = lex.acceptance.get("vector").expect("vector key must be present");
    assert!(vector_accepts.is_empty(), "vector acceptance must be empty");

    // drawer accepts 6 verbs, sorted alphabetically.
    let drawer_accepts = lex.acceptance.get("drawer").expect("drawer key must be present");
    assert_eq!(drawer_accepts.len(), 6, "drawer must accept 6 verbs");
    // Sorted: capture, expunge, mutate, reanchor, recall, withdraw.
    let mut expected_drawer = drawer_accepts.clone();
    expected_drawer.sort();
    assert_eq!(*drawer_accepts, expected_drawer, "acceptance values must be sorted");
}

#[test]
fn lattice_payload_degrades_when_daemon_unreachable() {
    // When the ARIA daemon is not running, lattice_payload must return the
    // honest degraded state: empty addresses, pending=true. This mirrors the
    // Swift host's fallback when ARIA_MCP is unreachable.
    //
    // The proxy tries ARIA_MCP_API_BASE (default 127.0.0.1:4242). In CI there
    // is no live daemon, so the connect fails within the 3-second timeout and
    // the fallback fires. If a daemon IS running on 4242 in the test environment
    // the test still passes: live data → pending=false is the CORRECT behaviour.
    // We therefore only assert the shape is valid, not the `pending` value.
    let m = started_manager();
    let snap = m.lattice_payload();
    // addresses is always a Vec (never null); pending is a bool.
    // If pending=false the proxy succeeded — that is valid too.
    if snap.pending {
        assert!(snap.addresses.is_empty(), "degraded state must have empty addresses");
    } else {
        // Live data: every address must have a non-empty code and positive count.
        for addr in &snap.addresses {
            assert!(!addr.code.is_empty(), "live address must have a non-empty code");
            assert!(addr.count >= 0, "live address count must be non-negative");
        }
    }
}

// ──────────────────── daemon proxy parse-path unit tests ──────────────────
//
// Feed sample daemon JSON directly into the public parse helpers in manager.rs
// so we test the decode + label-annotation path without a live daemon.

#[test]
fn proxy_lattice_parse_valid_daemon_response() {
    use std::io::{Read, Write};

    // Spin up a one-shot HTTP/1.0 server that returns a sample daemon lattice
    // response (two UDC codes, no labels required from the frame in the assertion).
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let body: &'static [u8] = br#"{"addresses":[{"code":"540","count":12},{"code":"006.6","count":3}]}"#;
    let listener_clone = listener.try_clone().unwrap();
    let handle = std::thread::spawn(move || {
        if let Ok((mut s, _)) = listener_clone.accept() {
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let header = format!(
                "HTTP/1.0 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = s.write_all(header.as_bytes());
            let _ = s.write_all(body);
        }
    });

    // Point the daemon_client at our echo server via the env var.
    std::env::set_var("ARIA_MCP_API_BASE", format!("http://127.0.0.1:{port}"));
    let snap = moot_mgr::manager::proxy_lattice_snapshot();
    // Reset env so other tests aren't affected.
    std::env::remove_var("ARIA_MCP_API_BASE");

    handle.join().unwrap();

    assert!(!snap.pending, "successfully decoded response must not be pending");
    assert_eq!(snap.addresses.len(), 2);
    assert_eq!(snap.addresses[0].code, "540");
    assert_eq!(snap.addresses[0].count, 12);
    assert_eq!(snap.addresses[1].code, "006.6");
    assert_eq!(snap.addresses[1].count, 3);
    // Labels may be Some or None depending on artifact availability — both are valid.
}

#[test]
fn proxy_lattice_degrades_on_closed_port() {
    // Find a guaranteed-closed port.
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let closed_port = l.local_addr().unwrap().port();
    drop(l);

    std::env::set_var("ARIA_MCP_API_BASE", format!("http://127.0.0.1:{closed_port}"));
    let snap = moot_mgr::manager::proxy_lattice_snapshot();
    std::env::remove_var("ARIA_MCP_API_BASE");

    assert!(snap.pending, "closed port must degrade to pending=true");
    assert!(snap.addresses.is_empty(), "degraded state must have empty addresses");
}

#[test]
fn proxy_admin_estates_parse_valid_daemon_response() {
    use std::io::{Read, Write};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    // Sample daemon /api/admin/estates response (matches AriaMcpKit http_server shape).
    let body: &'static [u8] = br#"{"hosted":[{"estateUUID":"dead-beef","estateName":"dead-beef","kind":"GLK","backend":"SQLite","mountState":"mounted"}]}"#;
    let listener_clone = listener.try_clone().unwrap();
    let handle = std::thread::spawn(move || {
        if let Ok((mut s, _)) = listener_clone.accept() {
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let header = format!(
                "HTTP/1.0 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = s.write_all(header.as_bytes());
            let _ = s.write_all(body);
        }
    });

    std::env::set_var("ARIA_MCP_API_BASE", format!("http://127.0.0.1:{port}"));
    let result = moot_mgr::manager::proxy_admin_estates();
    std::env::remove_var("ARIA_MCP_API_BASE");

    handle.join().unwrap();

    let payload = result.expect("valid daemon response must decode to Some");
    assert_eq!(payload.hosted.len(), 1);
    assert_eq!(payload.hosted[0].estate_uuid, "dead-beef");
    assert_eq!(payload.hosted[0].kind, "GLK");
    assert_eq!(payload.hosted[0].backend, "SQLite");
    assert_eq!(payload.hosted[0].mount_state, "mounted");
}

#[test]
fn proxy_admin_estates_returns_none_on_closed_port() {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let closed_port = l.local_addr().unwrap().port();
    drop(l);

    std::env::set_var("ARIA_MCP_API_BASE", format!("http://127.0.0.1:{closed_port}"));
    let result = moot_mgr::manager::proxy_admin_estates();
    std::env::remove_var("ARIA_MCP_API_BASE");

    assert!(result.is_none(), "closed port must degrade to None");
}
