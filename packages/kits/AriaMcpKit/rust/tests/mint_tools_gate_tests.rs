//! Dark mint tools — launch-time gate (codex finding 16, 2026-09-02).
//!
//! `moot_register_adornment_minter` and `moot_run_adornment_pass` dispatch
//! ONLY when the serving process was launched with `MOOTX01_MINT_TOOLS=1`.
//! Hiding them from tools/list is not authorization; without the variable
//! both names are unknown tools. The gate is read once per process, so
//! these tests inject it through `is_recipe_tool_with` / `dispatch_with`
//! rather than mutating the environment. Mirrors Swift
//! `MintToolsGateTests`.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCErrorCode, JsonValue},
    recipe_tools::{
        dispatch_with, is_recipe_tool, is_recipe_tool_with, mint_tools_enabled,
        mint_tools_enabled_from, MINT_TOOLS_ENV_VAR,
    },
    surfaced_recall_ledger::SurfacedRecallLedger,
};

const RUN_PASS: &str = "moot_run_adornment_pass";
const REGISTER_MINTER: &str = "moot_register_adornment_minter";

fn pass_args() -> BTreeMap<String, JsonValue> {
    let mut m = BTreeMap::new();
    m.insert(
        "now".to_string(),
        JsonValue::from(serde_json::json!("2026-09-02T00:00:00Z")),
    );
    m.insert(
        "batch_size".to_string(),
        JsonValue::from(serde_json::json!("999999")),
    );
    m
}

fn text_of(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// Exactly the literal "1" enables; every other value leaves the gate off.
#[test]
fn gate_value_is_exactly_one() {
    assert_eq!(MINT_TOOLS_ENV_VAR, "MOOTX01_MINT_TOOLS");
    assert!(!mint_tools_enabled_from(None));
    assert!(!mint_tools_enabled_from(Some("")));
    assert!(!mint_tools_enabled_from(Some("0")));
    assert!(!mint_tools_enabled_from(Some("true")));
    assert!(!mint_tools_enabled_from(Some("1 ")));
    assert!(mint_tools_enabled_from(Some("1")));
}

/// Gate off: both dark names are outside the recipe routing set and a
/// direct dispatch returns the same METHOD_NOT_FOUND "Unknown tool" error
/// the dispatcher returns for any unregistered name.
#[test]
fn dark_tools_are_unknown_when_gate_off() {
    assert!(!is_recipe_tool_with(RUN_PASS, false));
    assert!(!is_recipe_tool_with(REGISTER_MINTER, false));
    // The gate never touches the listed recipe tools.
    assert!(is_recipe_tool_with("moot_recall_precise", false));

    let registry = EstateRegistry::new_inmemory();
    for name in [RUN_PASS, REGISTER_MINTER] {
        let err = dispatch_with(name, &pass_args(), &registry, false)
            .expect_err("gated dark tool must be an unknown tool");
        assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
        assert_eq!(err.message, format!("Unknown tool: {name}"));
    }
}

/// Gate on: both names route, and a pass call with batch_size 999999 reaches
/// the handler — the value is clamped, never rejected — and completes.
#[test]
fn dark_tools_dispatch_when_gate_on() {
    assert!(is_recipe_tool_with(RUN_PASS, true));
    assert!(is_recipe_tool_with(REGISTER_MINTER, true));

    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_with(RUN_PASS, &pass_args(), &registry, true)
        .expect("gate on: the pass handler must run");
    assert_eq!(result["isError"], serde_json::json!(false));
    assert!(
        text_of(&result).starts_with("moot_run_adornment_pass: pass complete"),
        "handler must be reached; got: {}",
        text_of(&result)
    );
}

/// The production entry points (`is_recipe_tool`, `dispatch_tool`) follow
/// the once-per-process gate: whichever way this test process was launched,
/// routing and dispatch agree with `mint_tools_enabled()`.
#[test]
fn process_gate_drives_production_dispatch() {
    let enabled = mint_tools_enabled();
    assert_eq!(is_recipe_tool(RUN_PASS), enabled);
    assert_eq!(is_recipe_tool(REGISTER_MINTER), enabled);

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let routed = dispatch_tool(RUN_PASS, &pass_args(), &registry, &ledger);
    if enabled {
        let result = routed.expect("gate on: the pass handler must run");
        assert!(text_of(&result).starts_with("moot_run_adornment_pass: pass complete"));
    } else {
        let err = routed.expect_err("gate off: the dark name must be unknown");
        assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
        assert_eq!(err.message, format!("Unknown tool: {RUN_PASS}"));
    }
}
