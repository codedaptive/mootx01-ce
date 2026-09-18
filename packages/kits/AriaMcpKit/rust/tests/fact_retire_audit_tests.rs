//! fact_retire_audit_tests.rs — Gate tests that prove `moot_retire_fact`
//! wires `changedBy` and `reason` into the `_storagekit_audit` row.
//!
//! Every test drives the SHIPPED path:
//!   Dispatcher::handle(tools/call "moot_retire_fact" ...) →
//!   surface.decode → SelectedKnowledgeJournalAuthority.admit →
//!   surface::execute → execute_knowledge_journal →
//!   CoordinatorKnowledgeJournalLower::retire_fact →
//!   coordinator.withdraw_kg_fact → _storagekit_audit row.
//!
//! `admit()` at rust/src/surface.rs:2337-2354 (NOT rust/src/v2/surface.rs)
//! populates `caller_binding` from
//! `registry.server_identity`; `retire_fact` at v2/knowledge_journal.rs:180
//! passes `&a.caller_binding` and `r.reason.as_deref()` to `withdraw_kg_fact`.
//! Both are what the tests assert.
//!
//! The fact_id is extracted from the v2 structured result:
//!   result["result"]["structuredContent"]["data"]["fact_id"]
//!
//! Mirrors Swift `FactRetireAuditTests.swift` in AriaMCPTests.

use aria_mcp::{dispatcher::Dispatcher, estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Drive tools/call through the full Dispatcher::handle path — the shipped
/// server route — and return the outer JSONRPC response.
fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": tool, "arguments": arguments }
    })).expect("test JSONRPC request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

/// Extract the v2 structuredContent.data block from a tools/call result.
fn data(result: &serde_json::Value) -> &serde_json::Value {
    &result["result"]["structuredContent"]["data"]
}

fn is_success(result: &serde_json::Value) -> bool {
    result["result"]["isError"] == serde_json::json!(false)
}

// ---------------------------------------------------------------------------
// Test 1: reason forwarded
// ---------------------------------------------------------------------------

/// Retire a fact with reason="audit-reason-a". The audit row must carry
/// that exact reason. Before the fix, reason was always None.
#[test]
fn retire_fact_audit_row_carries_reason() {
    const SERVER_ID: &str = "aria-mcp-server";
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = SERVER_ID.to_owned();
    // Clone the store Arc before the registry is moved into the dispatcher so
    // audit rows can be read after the call completes.
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    // File a fact to get a fact_id.
    let file_result = call(&dispatcher, "moot_file_fact", serde_json::json!({
        "subject":   "Galileo",
        "predicate": "discovered",
        "object":    "Jupiter's moons",
    }));
    assert!(is_success(&file_result), "moot_file_fact must succeed; got: {file_result}");
    let fact_id_str = data(&file_result)["fact_id"]
        .as_str()
        .expect("moot_file_fact must return fact_id in structuredContent.data")
        .to_owned();

    // Retire with an explicit reason.
    let retire_result = call(&dispatcher, "moot_retire_fact", serde_json::json!({
        "fact_id": fact_id_str,
        "reason":  "audit-reason-a",
    }));
    assert!(
        is_success(&retire_result),
        "moot_retire_fact must return isError:false; got: {retire_result}"
    );
    assert_eq!(
        data(&retire_result)["fact_id"].as_str().unwrap_or(""),
        fact_id_str.as_str(),
        "moot_retire_fact must echo the fact_id in structuredContent.data; got: {retire_result}"
    );

    // Inspect the audit row.
    let events = store
        .audit_events_for_row(&fact_id_str)
        .expect("audit read must not fail");
    assert_eq!(events.len(), 1, "exactly one audit event for a single retirement");
    let ev = &events[0];
    assert_eq!(ev.verb, "retract", "audit verb must be 'retract'");
    assert_eq!(
        ev.reason.as_deref(),
        Some("audit-reason-a"),
        "audit reason must match the caller-supplied value; got {:?}",
        ev.reason
    );
}

// ---------------------------------------------------------------------------
// Test 2: actor is server identity, not the old constant
// ---------------------------------------------------------------------------

/// The audit actor must equal the server_identity injected at registry
/// construction, not the old hard-coded constant "aria-v2-retire-fact".
#[test]
fn retire_fact_audit_actor_equals_server_identity() {
    const SERVER_ID: &str = "test-mootx01-host";
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = SERVER_ID.to_owned();
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let file_result = call(&dispatcher, "moot_file_fact", serde_json::json!({
        "subject":   "Copernicus",
        "predicate": "proposed",
        "object":    "heliocentrism",
    }));
    assert!(is_success(&file_result), "moot_file_fact must succeed; got: {file_result}");
    let fact_id_str = data(&file_result)["fact_id"]
        .as_str()
        .expect("moot_file_fact must return fact_id")
        .to_owned();

    call(&dispatcher, "moot_retire_fact", serde_json::json!({
        "fact_id": fact_id_str,
        "reason":  "audit-reason-b",
    }));

    let events = store
        .audit_events_for_row(&fact_id_str)
        .expect("audit read must not fail");
    assert_eq!(events.len(), 1);
    let ev = &events[0];
    assert_eq!(
        ev.actor, SERVER_ID,
        "audit actor must be server_identity '{}'; got '{}'",
        SERVER_ID, ev.actor
    );
    assert_ne!(
        ev.actor, "aria-v2-retire-fact",
        "old hard-coded constant must NOT appear as audit actor"
    );
}

// ---------------------------------------------------------------------------
// Test 3: nil reason when no reason is supplied
// ---------------------------------------------------------------------------

/// When the caller omits reason, the audit row reason must be None.
#[test]
fn retire_fact_audit_reason_is_none_when_omitted() {
    const SERVER_ID: &str = "aria-mcp-server";
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = SERVER_ID.to_owned();
    let store = registry.default.store.clone();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let file_result = call(&dispatcher, "moot_file_fact", serde_json::json!({
        "subject":   "Newton",
        "predicate": "formulated",
        "object":    "gravity",
    }));
    assert!(is_success(&file_result), "moot_file_fact must succeed; got: {file_result}");
    let fact_id_str = data(&file_result)["fact_id"]
        .as_str()
        .expect("moot_file_fact must return fact_id")
        .to_owned();

    // Retire without a reason.
    call(&dispatcher, "moot_retire_fact", serde_json::json!({
        "fact_id": fact_id_str,
    }));

    let events = store
        .audit_events_for_row(&fact_id_str)
        .expect("audit read must not fail");
    assert_eq!(events.len(), 1);
    let ev = &events[0];
    assert_eq!(ev.verb, "retract");
    assert_eq!(
        ev.reason, None,
        "audit reason must be None when no reason is supplied; got {:?}",
        ev.reason
    );
}
