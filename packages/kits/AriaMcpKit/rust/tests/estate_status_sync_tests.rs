//! estate_status_sync_tests.rs
//!
//! Force-tests for the moot_estate_status sync field (OP-1 honesty fix).
//!
//! Verifies:
//!   1. Estate with no sync engine → body contains "sync: local-only".
//!   2. Estate with no sync engine → body does NOT contain "status: connected"
//!      (the fabricated literal removed by OP-1).
//!   3. Estate with NoSyncEngine (disabled) → body contains "sync: none (idle)".
//!   4. Estate with NoSyncEngine (enabled) → body contains
//!      "sync: none (enabled, zone: test.zone.op1)".
//!   5. The "sync:" field key is present (not the old "status:" key).
//!   6. Vocabulary parity: format_sync_state_token matches dispatch output.
//!
//! These tests exercise the full dispatch path through `dispatch_tool` so
//! the assertion covers both the coordinator accessor and the
//! interface_tools.rs formatting layer.

use std::collections::BTreeMap;
use std::sync::Arc;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};
use convergence_kit::engine::SyncEngine;
use convergence_kit::types::SyncState;
use convergence_kit::{NoSyncEngine, SyncManifest};
use genius_locus_kit::format_sync_state_token;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn empty_args() -> BTreeMap<String, JsonValue> {
    BTreeMap::new()
}

// ---------------------------------------------------------------------------
// Test 1: no sync engine → "sync: local-only"
// ---------------------------------------------------------------------------

/// An estate with no sync engine registered must report "sync: local-only".
/// This is the production default for all ARIA_MCP v1.0 deployments.
#[test]
fn no_sync_engine_reports_local_only() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_estate_status", &empty_args(), &registry, &SurfacedRecallLedger::new())
            .expect("estate_status must not throw");
    assert!(is_success(&result), "estate_status must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("sync: local-only"),
        "Expected 'sync: local-only' when no engine is registered; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Test 2: fabricated "connected" literal is gone
// ---------------------------------------------------------------------------

/// The hardcoded "status: connected" literal must never appear in estate_status.
/// This was the fabrication removed by OP-1.
#[test]
fn fabricated_connected_literal_is_absent() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_estate_status", &empty_args(), &registry, &SurfacedRecallLedger::new())
            .expect("estate_status must not throw");
    let text = content_text(&result);
    assert!(
        !text.contains("status: connected"),
        "Fabricated 'status: connected' must not appear in estate_status; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Test 3: NoSyncEngine disabled → "sync: none (idle)"
// ---------------------------------------------------------------------------

/// An estate with a NoSyncEngine that has not been enabled must report
/// "sync: none (idle)".
#[test]
fn no_sync_engine_disabled_reports_none_idle() {
    // `registry` is immutable — coord is accessed via the Arc inside.
    let registry = EstateRegistry::new_inmemory();
    // Register a disabled NoSyncEngine against the default estate handle.
    {
        let handle = registry.default.handle;
        let mut coord = registry.coord.lock().unwrap();
        coord
            .register_sync_engine(&handle, Box::new(NoSyncEngine::new()), "none")
            .expect("register_sync_engine must succeed for an open estate");
    }

    let result =
        dispatch_tool("moot_estate_status", &empty_args(), &registry, &SurfacedRecallLedger::new())
            .expect("estate_status must not throw");
    assert!(is_success(&result), "estate_status must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("sync: none (idle)"),
        "Expected 'sync: none (idle)' for disabled NoSyncEngine; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Test 4: NoSyncEngine enabled → "sync: none (enabled, zone: …)"
// ---------------------------------------------------------------------------

/// An estate with a NoSyncEngine that has been enabled must report
/// "sync: none (enabled, zone: <zone>)".
#[test]
fn no_sync_engine_enabled_reports_none_enabled() {
    let registry = EstateRegistry::new_inmemory();

    // Build a NoSyncEngine and enable it with a test manifest.
    let mut engine = NoSyncEngine::new();
    let manifest = SyncManifest::new("test-kit", 1, "test.zone.op1", vec![]);
    let engine_storage: Arc<dyn persistence_kit::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    engine.enable(manifest, engine_storage).expect("NoSyncEngine enable must succeed");

    // Register the enabled engine against the default estate handle.
    {
        let handle = registry.default.handle;
        let mut coord = registry.coord.lock().unwrap();
        coord
            .register_sync_engine(&handle, Box::new(engine), "none")
            .expect("register_sync_engine must succeed for an open estate");
    }

    let result =
        dispatch_tool("moot_estate_status", &empty_args(), &registry, &SurfacedRecallLedger::new())
            .expect("estate_status must not throw");
    assert!(is_success(&result), "estate_status must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("sync: none (enabled, zone: test.zone.op1)"),
        "Expected 'sync: none (enabled, zone: test.zone.op1)' for enabled NoSyncEngine; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Test 5: sync field always present (correct key, not "status:")
// ---------------------------------------------------------------------------

/// The "sync:" field must always be present in the estate_status output.
/// The old "status:" key (the fabricated literal) must not appear.
#[test]
fn sync_field_key_is_sync_not_status() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_estate_status", &empty_args(), &registry, &SurfacedRecallLedger::new())
            .expect("estate_status must not throw");
    let text = content_text(&result);
    assert!(
        text.contains("sync: "),
        "estate_status must contain 'sync:' field; got:\n{text}"
    );
    // Must NOT have the old "status:" key as a line start.
    let has_old_status_line = text.lines().any(|l| l.starts_with("status:"));
    assert!(
        !has_old_status_line,
        "estate_status must not use the old 'status:' key; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Test 6: vocabulary parity — format_sync_state_token matches dispatch output
// ---------------------------------------------------------------------------

/// The `format_sync_state_token` function that backs dispatch must produce the
/// correct tokens for the canonical states. This is a unit-level parity check
/// that the vocabulary table is implemented correctly in the Rust port.
#[test]
fn format_sync_state_token_vocabulary_parity() {
    // None backend, disabled.
    assert_eq!(
        format_sync_state_token(&SyncState::Disabled, "none"),
        "none (idle)",
        "Disabled NoSyncEngine must produce 'none (idle)'"
    );

    // None backend, enabled.
    assert_eq!(
        format_sync_state_token(
            &SyncState::Enabled {
                zone: "test.zone".to_string(),
                last_push_secs: None,
                last_pull_secs: None,
            },
            "none"
        ),
        "none (enabled, zone: test.zone)",
        "Enabled NoSyncEngine must produce 'none (enabled, zone: test.zone)'"
    );

    // Federation enabled — must say "in-process" not "enabled".
    assert_eq!(
        format_sync_state_token(
            &SyncState::Enabled {
                zone: "federation.zone".to_string(),
                last_push_secs: None,
                last_pull_secs: None,
            },
            "federation"
        ),
        "federation (in-process, zone: federation.zone)",
        "Enabled Federation must produce 'federation (in-process, zone: …)'"
    );

    // The token "connected" must never appear for any input.
    let tokens = [
        format_sync_state_token(&SyncState::Disabled, "none"),
        format_sync_state_token(&SyncState::Disabled, "cloudkit"),
        format_sync_state_token(&SyncState::Disabled, "federation"),
        format_sync_state_token(
            &SyncState::Enabled {
                zone: "z".to_string(),
                last_push_secs: None,
                last_pull_secs: None,
            },
            "none",
        ),
        format_sync_state_token(
            &SyncState::Enabled {
                zone: "z".to_string(),
                last_push_secs: None,
                last_pull_secs: None,
            },
            "cloudkit",
        ),
        format_sync_state_token(
            &SyncState::Enabled {
                zone: "z".to_string(),
                last_push_secs: None,
                last_pull_secs: None,
            },
            "federation",
        ),
    ];
    for token in &tokens {
        assert!(
            !token.contains("connected"),
            "Token 'connected' must never appear in sync vocabulary; got: {token}"
        );
    }
}
