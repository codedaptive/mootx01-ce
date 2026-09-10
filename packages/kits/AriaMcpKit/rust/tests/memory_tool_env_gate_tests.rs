//! Integration gate for the `MOOTX01_MEMORY_TOOL` production path.
//!
//! # What this gates
//!
//! `Dispatcher::new` reads `MOOTX01_MEMORY_TOOL` from the process environment
//! once at construction and appends the `memory` schema to `tools` when the
//! var equals `"1"`. That append is the production path every client sees.
//!
//! The lib-test `catalog_sync_tests::dispatcher_catalog_includes_memory_tool_when_enabled_and_excludes_it_when_disabled`
//! exercises the same counts and names, but it calls `with_memory_tool_enabled`
//! — a builder override that bypasses the env-var read in `Dispatcher::new`.
//! That test therefore PASSES even when the `Dispatcher::new` append is
//! deleted, leaving the production regression invisible.
//!
//! This file compiles to its own test binary (a `tests/` integration test) so
//! process-level env mutations here do not race with any other binary. Within
//! this binary the two tests are serialized via `ENV_LOCK` because Cargo's
//! test harness runs tests on multiple threads by default and `set_var` is
//! process-wide mutable state.
//!
//! # Why `set_var` is sound here
//!
//! `std::env::set_var` is safe in Rust edition 2021 (this crate's edition).
//! Edition 2024 is expected to mark it `unsafe` because concurrent env
//! mutation from multiple threads can cause UB in C code that reads the
//! environment. That concern is ruled out here: this binary's only purpose
//! is exercising `MOOTX01_MEMORY_TOOL`, and `ENV_LOCK` ensures the two tests
//! never mutate the variable concurrently.

use std::sync::Mutex;

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};

/// Serializes env-var mutations within this binary.
///
/// `set_var` writes process-wide state. Cargo's test harness runs tests in
/// parallel threads; without this lock the enabled and disabled tests would
/// race on `MOOTX01_MEMORY_TOOL`, producing non-deterministic pass/fail.
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Issue `tools/list` through `dispatcher` and return the tools array.
///
/// Drives the same JSON-RPC wire path a real MCP client uses — not an
/// internal field read. The response is what the client sees.
fn tools_list(dispatcher: &Dispatcher) -> Vec<serde_json::Value> {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {}
    });
    let request = JSONRPCRequest::decode(&raw).expect("tools/list request must decode");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("tools/list response must serialize");
    response["result"]["tools"]
        .as_array()
        .expect("tools/list result must contain a `tools` array")
        .clone()
}

fn has_memory(tools: &[serde_json::Value]) -> bool {
    tools
        .iter()
        .any(|t| t.get("name").and_then(|n| n.as_str()) == Some("memory"))
}

/// Asserts that `Dispatcher::new` includes `memory` in `tools/list` when
/// `MOOTX01_MEMORY_TOOL=1` is set in the process environment.
///
/// The test calls `Dispatcher::new` directly — no `with_memory_tool_enabled`
/// call — so the only path that can put `memory` in the catalog is the
/// env-var read inside `Dispatcher::new`. If that append is removed, this
/// test fails; the lib-level `catalog_sync_tests` test continues to pass
/// because it uses the builder override. That contrast is the discrimination
/// this file exists to provide.
#[test]
fn memory_tool_present_when_env_var_enabled() {
    let _guard = ENV_LOCK.lock().expect("ENV_LOCK poisoned");

    // Safety: see module-level comment. This binary's only tests concern
    // MOOTX01_MEMORY_TOOL; ENV_LOCK prevents concurrent mutation.
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");

    let dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory(),
        "ARIA_MCP_Rust",
        "test",
        "test-serial",
        None,
    );
    // Restore before returning so the disabled test never sees "1".
    std::env::set_var("MOOTX01_MEMORY_TOOL", "0");

    let tools = tools_list(&dispatcher);

    assert_eq!(
        tools.len(),
        85,
        "MOOTX01_MEMORY_TOOL=1: tools/list must have 85 entries; got {}",
        tools.len(),
    );
    assert!(
        has_memory(&tools),
        "MOOTX01_MEMORY_TOOL=1: tools/list must contain a tool named `memory`",
    );
}

/// Asserts that `Dispatcher::new` excludes `memory` from `tools/list` when
/// `MOOTX01_MEMORY_TOOL` is absent or `"0"`.
///
/// Same direct-construction discipline as the enabled test: no
/// `with_memory_tool_enabled` call. Ordered after the enabled test via
/// `ENV_LOCK`.
#[test]
fn memory_tool_absent_when_env_var_disabled() {
    let _guard = ENV_LOCK.lock().expect("ENV_LOCK poisoned");

    // Explicitly set to "0"; the default (absent) would also disable the
    // tool, but an explicit value makes the test intent unambiguous.
    // Safety: same rationale as the enabled test above.
    std::env::set_var("MOOTX01_MEMORY_TOOL", "0");

    let dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory(),
        "ARIA_MCP_Rust",
        "test",
        "test-serial",
        None,
    );

    let tools = tools_list(&dispatcher);

    assert_eq!(
        tools.len(),
        84,
        "MOOTX01_MEMORY_TOOL=0: tools/list must have 84 entries; got {}",
        tools.len(),
    );
    assert!(
        !has_memory(&tools),
        "MOOTX01_MEMORY_TOOL=0: tools/list must NOT contain a tool named `memory`",
    );
}
