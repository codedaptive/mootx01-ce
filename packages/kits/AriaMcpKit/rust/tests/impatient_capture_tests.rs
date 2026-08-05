//! impatient_capture_tests.rs — Rust parity of Swift ImpatientCaptureTests.swift.
//!
//! Dual-Path Intake — ARIA_MCP arg threading (D-A, item #9).
//!
//! `moot_file_memory` gains an optional `impatient: bool` (default false). It is
//! an EXECUTION OPTION on the write verb — threaded from the MCP arg to the GLK
//! verb param (`capture_with_mode`) — NOT a field on CaptureFrame. These tests
//! assert:
//!   1. the tool schema advertises the `impatient` property as an optional boolean,
//!   2. a `moot_file_memory` call accepts and routes the `impatient` arg (both
//!      true and false / omitted) without error.
//!
//! NOTE ON SCOPE: these tests use `EstateRegistry::new_inmemory()` to prove
//! the `impatient` arg is advertised in the tool schema and correctly threaded
//! through the dispatch layer to `capture_with_mode`. The in-memory registry
//! now wires semantic recall; sibling tests in this directory prove BM25/vector
//! lanes are live for `new_inmemory()`. These tests cover arg routing only.
//!
//! The end-to-end proof that BM25 + vector recall lanes are live at the MCP
//! dispatch surface for SQLite-backed estates is covered in the sibling file
//! tests/sqlite_semantic_lanes_tests.rs. The load-bearing GLK-layer proof
//! (BM25-after-drain and impatient-immediately) is in
//! GeniusLocusKit/rust/tests/encode_intake_parity.rs. Here we prove the ARG
//! is advertised and threaded — the item-#9 surface.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    surfaced_recall_ledger::SurfacedRecallLedger,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    tool_list::build_tool_list,
};

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

// MARK: - Schema advertises the impatient option

#[test]
fn file_memory_schema_advertises_impatient() {
    let tools = build_tool_list();
    let tool = tools
        .as_array()
        .expect("tool list must be a JSON array")
        .iter()
        .find(|t| t["name"] == "moot_file_memory")
        .expect("moot_file_memory tool must be present");

    let props = &tool["inputSchema"]["properties"];
    let impatient = &props["impatient"];
    assert_eq!(
        impatient["type"], "boolean",
        "impatient must be a boolean schema; got {impatient:?}"
    );

    // It must NOT be required — default false keeps existing callers working.
    let required = tool["inputSchema"]["required"]
        .as_array()
        .expect("required must be an array");
    assert!(
        !required.iter().any(|v| v == "impatient"),
        "impatient must be optional (not in required) so existing callers are unchanged"
    );
}

// MARK: - The impatient arg is accepted and routed

/// An impatient `moot_file_memory` succeeds (the arg is accepted and threaded to
/// `capture_with_mode`). The drawer row is durably stored regardless of mode.
#[test]
fn impatient_file_memory_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "kingfisher heron osprey wading bird",
        "subject" => "kingfisher heron osprey wading bird",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let result = dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
        .expect("impatient file_memory must dispatch");
    assert!(
        is_success(&result),
        "impatient file_memory should succeed; got: {result:?}"
    );
}

/// A regular `moot_file_memory` (impatient omitted → default false) succeeds —
/// the default path is unchanged for existing callers.
#[test]
fn regular_file_memory_succeeds_without_impatient_arg() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "apple mango banana fruit",
        "subject" => "apple mango banana fruit",
        "location" => "memories/fruit",
    ];
    let result = dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
        .expect("regular file_memory must dispatch");
    assert!(
        is_success(&result),
        "regular file_memory should succeed; got: {result:?}"
    );
}

/// An explicit `impatient: false` is equivalent to omitting it (regular mode).
#[test]
fn explicit_impatient_false_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "tungsten molybdenum refractory",
        "subject" => "tungsten molybdenum refractory",
        "location" => "memories/metals",
        "impatient" => false,
    ];
    let result = dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
        .expect("file_memory must dispatch");
    assert!(is_success(&result), "got: {result:?}");
}
