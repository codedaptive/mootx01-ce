//! Estate-selection integration tests: charter-seeding gate.
//!
//! These tests verify that `EstateRegistry::new_sqlite_with` with
//! `EstateOpening::REGISTERED` seeds seven `AI_Charter_Hint` room drawers
//! (one per default wing) and that `EstateOpening::TRANSIENT` seeds none.
//! They test through `moot_estate_map` — the full dispatch stack — so a
//! mutation to the `seed_charters` gate inside `EstateRegistry::new_sqlite_with`
//! is caught at the surface level.
//!
//! `is_registered_opening` is `pub(crate)` in the bin crate; integration tests
//! link against the lib, not the bin, so they cannot reach that helper.
//! The test that catches `is_registered_opening` mutations is
//! `in_memory_always_transient_whatever_the_record_kind` in `src/main.rs`.
//!
//! Swift twin: `CharterSeedingTests.swift` in `Tests/aria-mcpTests/`.
//! Lower-level Rust twin: `transient_charter_gate_tests.rs` in AriaMcpKit.

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::{EstateRegistry, EstateOpening},
    jsonrpc::JSONRPCRequest,
};

/// Invoke the public selected-v2 dispatcher path used by MCP clients.
fn selected_v2_call(dispatcher: &Dispatcher, name: &str) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": name, "arguments": {} },
    }))
    .expect("tools/call request must decode");
    serde_json::to_value(dispatcher.handle(&request))
        .expect("selected-v2 dispatcher response must serialize")["result"].clone()
}

fn charter_room_count(result: &serde_json::Value) -> usize {
    result["structuredContent"]["data"]["wings"]
        .as_array()
        .expect("selected-v2 estate map must expose wings")
        .iter()
        .flat_map(|wing| wing["rooms"].as_array().into_iter().flatten())
        .filter(|room| room["name"] == "AI_Charter_Hint")
        .count()
}

/// A unique scratch SQLite path under the system temp directory.
fn scratch_sqlite_path(label: &str) -> String {
    let unique = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    std::env::temp_dir()
        .join(format!("aria-sel-{label}-{unique}.sqlite"))
        .to_string_lossy()
        .into_owned()
}

/// A registered opening seeds exactly seven `AI_Charter_Hint` drawers — one per
/// default wing — visible through `moot_estate_map`. A mutation that removes the
/// `if opening.seed_charters` gate in `EstateRegistry::new_sqlite_with` makes this
/// test vacuous (zero lines), and a mutation that removes the gate entirely seeds
/// transient estates too (caught by `transient_opening_seeds_no_charter_drawers`).
#[test]
fn registered_opening_seeds_seven_charter_drawers() {
    let path = scratch_sqlite_path("registered");
    let registry =
        EstateRegistry::new_sqlite_with(&path, "estate-sel-owner", EstateOpening::REGISTERED)
            .expect("scratch SQLite estate with REGISTERED opening must open");

    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);
    let result = selected_v2_call(&dispatcher, "moot_estate_map");

    let charter_line_count = charter_room_count(&result);
    // Seven default wings each contribute one AI_Charter_Hint room line.
    assert_eq!(
        charter_line_count, 7,
        "registered opening must seed exactly 7 AI_Charter_Hint room lines in moot_estate_map; \
         got {charter_line_count} in: {result:?}"
    );

    drop(dispatcher);
    let _ = std::fs::remove_file(&path);
}

/// A transient opening does NOT call the charter seeding gate — the estate
/// remains empty of `AI_Charter_Hint` drawers. A mutation that seeds on every
/// open regardless of `EstateOpening::seed_charters` must fail this test.
#[test]
fn transient_opening_seeds_no_charter_drawers() {
    let path = scratch_sqlite_path("transient");
    let registry =
        EstateRegistry::new_sqlite_with(&path, "estate-sel-owner", EstateOpening::TRANSIENT)
            .expect("scratch SQLite estate with TRANSIENT opening must open");

    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);
    let result = selected_v2_call(&dispatcher, "moot_estate_map");

    let charter_line_count = charter_room_count(&result);
    assert_eq!(
        charter_line_count, 0,
        "transient opening must seed zero AI_Charter_Hint room lines in moot_estate_map; \
         got {charter_line_count} in: {result:?}"
    );

    drop(dispatcher);
    let _ = std::fs::remove_file(&path);
}
