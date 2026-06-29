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

// ---------------------------------------------------------------------------
// FIX 2: believed-only active count — estate_status "memories: N active"
// must count only cluster-A (believed) drawers, not rejected ones.
// Parity with Swift EstateStatusSyncTests.rejectedMemoryNotCountedAsActive.
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

/// A rejected drawer must NOT appear in the "memories: N active" count in
/// estate_status. Before this fix, `recall()` active count included rejected
/// drawers because the filtering was `tombstoned_at.is_none()` which is true
/// for rejected rows (only tombstoned rows have a tombstone timestamp).
///
/// The fix changes the active count to use `recall()` (which applies the
/// cluster-A filter in LocusKit/GeniusLocusKit) so only cluster-A believed
/// drawers count. Rejected drawers are cluster C and must not appear.
///
/// The "(N total)" count still includes the rejected drawer (cluster C,
/// not tombstoned), so total = 1 and active = 0.
#[test]
fn rejected_memory_not_counted_as_active() {
    // _bare: controlled estate — estate_status counts ALL non-erased drawers
    // (it does not exclude seeded wing hints the way recall does), so a full
    // provision's 7 AI_Charter_Hint drawers would inflate the active/total
    // counts this test asserts (0 active, 1 total after reject).
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    // File a memory — lands in cluster A (active state).
    let file_result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "believed-count test fixture", "location" => "test/room"],
        &registry,
        &ledger,
    )
    .expect("moot_file_memory must not throw");
    assert!(
        file_result["isError"] == serde_json::json!(false),
        "file_memory must succeed; got: {file_result:?}"
    );

    // Extract drawer id from the first line "filed memory <id>".
    let file_text = content_text(&file_result);
    let drawer_id = file_text
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .expect("file_memory response must start with 'filed memory <id>'")
        .trim()
        .to_owned();
    assert!(!drawer_id.is_empty(), "drawer id must not be empty");

    // Move to Contested (Active → Contested is legal).
    // Active → Reject is NOT legal per the gate automaton; contest must come first.
    let contest = dispatch_tool(
        "moot_update_memory",
        &args!["id" => drawer_id.as_str(), "mutation" => "contest"],
        &registry,
        &ledger,
    )
    .expect("contest dispatch must not throw");
    assert!(
        contest["isError"] == serde_json::json!(false),
        "contest must succeed on active row; got: {contest:?}"
    );

    // Reject the memory (Contested → Rejected is legal) — moves it to cluster C.
    let reject = dispatch_tool(
        "moot_update_memory",
        &args!["id" => drawer_id.as_str(), "mutation" => "reject"],
        &registry,
        &ledger,
    )
    .expect("reject dispatch must not throw");
    assert!(
        reject["isError"] == serde_json::json!(false),
        "reject must succeed on contested row; got: {reject:?}"
    );

    // estate_status active count must be 0 (rejected drawer is not believed).
    let status = dispatch_tool(
        "moot_estate_status",
        &empty_args(),
        &registry,
        &ledger,
    )
    .expect("estate_status must not throw");
    let body = content_text(&status);

    assert!(
        body.contains("memories: 0 active"),
        "Rejected drawer must not count as active; got:\n{body}"
    );
    // The total count must still be 1 (the row exists but is not believed).
    assert!(
        body.contains("(1 total)"),
        "Total non-erased count must be 1; got:\n{body}"
    );
}

// ---------------------------------------------------------------------------
// Part 3 parity gate: Syncing direction tokens use camelCase rawValue format.
//
// Regression guard for the {direction:?} → {direction} fix in coordinator.rs.
// Before the fix, Rust used Debug format (PascalCase: "Bidirectional") while
// Swift used SyncDirection.rawValue (camelCase: "bidirectional"). The canonical
// vocabulary in SyncEngineAPI.swift calls for camelCase — these tests lock it.
//
// Parity: Swift syncStateDescription(state: .syncing(direction: .bidirectional), …)
//         → "<backend> (syncing, direction: bidirectional)"
// ---------------------------------------------------------------------------

/// Syncing direction tokens must be camelCase rawValues, not PascalCase Debug.
/// Mirrors the canonical vocabulary in SyncEngineAPI.swift §Vocabulary contract.
#[test]
fn syncing_direction_tokens_are_camelcase_matching_swift_rawvalue() {
    use convergence_kit::types::SyncDirection;

    // bidirectional — was "Bidirectional" before fix, must be "bidirectional"
    assert_eq!(
        format_sync_state_token(&SyncState::Syncing { direction: SyncDirection::Bidirectional }, "cloudkit"),
        "cloudkit (syncing, direction: bidirectional)",
        "Bidirectional must use camelCase rawValue to match Swift SyncDirection.rawValue"
    );

    // pushOnly — was "PushOnly" before fix
    assert_eq!(
        format_sync_state_token(&SyncState::Syncing { direction: SyncDirection::PushOnly }, "cloudkit"),
        "cloudkit (syncing, direction: pushOnly)",
        "PushOnly must use camelCase rawValue to match Swift SyncDirection.rawValue"
    );

    // pullOnly — was "PullOnly" before fix
    assert_eq!(
        format_sync_state_token(&SyncState::Syncing { direction: SyncDirection::PullOnly }, "cloudkit"),
        "cloudkit (syncing, direction: pullOnly)",
        "PullOnly must use camelCase rawValue to match Swift SyncDirection.rawValue"
    );

    // Guard: PascalCase Debug format must NOT appear in any syncing token
    let directions = [SyncDirection::Bidirectional, SyncDirection::PushOnly, SyncDirection::PullOnly];
    let bad_forms = ["Bidirectional", "PushOnly", "PullOnly"];
    for dir in &directions {
        let token = format_sync_state_token(&SyncState::Syncing { direction: *dir }, "cloudkit");
        for bad in &bad_forms {
            assert!(
                !token.contains(bad),
                "PascalCase Debug form '{bad}' must not appear in sync token; got: {token}"
            );
        }
    }
}
