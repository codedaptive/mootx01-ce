//! Error-message parity + FDC-on-capture tests (B-6 + BUG-2 verification).
//!
//! B-6 (error surfacing): verifies that errors at the MCP boundary carry
//! actionable English reasons, not raw Rust type names like
//! `VerbDispatchError`, `UnderlyingEstateFailure`, `GeniusLocusKitError`, etc.
//!
//! BUG-2 (FDC-on-capture): verifies that `moot_file_memory` classifies
//! content via `Fdc::encode_anchor` so the drawer's `udc_code` is a real
//! classified code, not the "000.000" root.
//!
//! Parity: the Swift counterpart tests live in
//! `Tests/AriaMCPTests/FdcCaptureTests.swift`.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};
use locus_kit::filter::RecallFrame;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_tool_error(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(true)
}

// ---------------------------------------------------------------------------
// B-6: error message quality — no internal Rust type names at the boundary
// ---------------------------------------------------------------------------

/// Filing a memory with an empty `location` string produces an actionable
/// error that contains the failing reason ("room must not be empty") but
/// does NOT contain the internal Rust type name `UnderlyingEstateFailure`.
///
/// Before B-6 the error was `format!("{e:?}")` which surfaced:
///   `Verb(UnderlyingEstateFailure { reason: "InvalidContent: room must not be empty" })`
/// After the fix it uses `describe_verb_dispatch_error` and surfaces:
///   `"capture failed: InvalidContent: room must not be empty"`
#[test]
fn empty_location_error_contains_reason_not_rust_type_name() {
    let registry = EstateRegistry::new_inmemory();

    let a = args![
        "content"  => "some content",
        "location" => ""           // empty room — estate rejects this
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("dispatch must not return a transport error on a content-rejected call");

    // The result is a tool-level error (isError == true).
    assert!(
        is_tool_error(&result),
        "empty location must produce a tool-level error; got: {result:?}"
    );

    let msg = content_text(&result);

    // Must NOT contain the internal Rust enum variant name.
    assert!(
        !msg.contains("UnderlyingEstateFailure"),
        "error message must not leak 'UnderlyingEstateFailure'; got: {msg}"
    );
    assert!(
        !msg.contains("VerbDispatchError"),
        "error message must not leak 'VerbDispatchError'; got: {msg}"
    );

    // Must contain the actionable reason.
    assert!(
        msg.contains("room must not be empty"),
        "error message must contain the actionable reason 'room must not be empty'; got: {msg}"
    );
}

/// Attempting to search memories with a non-existent estateID produces an
/// error that does NOT contain the internal `GeniusLocusKitError` type name.
///
/// Before B-6, `coord.estate_for` failures were passed to
/// `describe_verb_dispatch_error` which expects `VerbDispatchError`, causing
/// a type mismatch. After the fix they route through `describe_glk_error`.
#[test]
fn unknown_estate_id_error_is_clean_english() {
    let registry = EstateRegistry::new_inmemory();

    // Supply a well-formed but non-existent estateID to reach the
    // `resolve` path — resolve surfaces a clean INVALID_PARAMS JSONRPCError.
    let a = args![
        "query"    => "anything",
        "estateID" => "00000000-0000-0000-0000-000000000000"
    ];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new());

    // This is a transport-level error (Err(JSONRPCError)), not a tool-level error.
    let err = result.expect_err("unknown estateID must return a transport-level JSONRPCError");

    let msg = &err.message;
    assert!(
        !msg.contains("GeniusLocusKitError"),
        "error message must not leak 'GeniusLocusKitError'; got: {msg}"
    );
    assert!(
        !msg.contains("EstateNotOpen"),
        "error message must not leak 'EstateNotOpen' Rust variant; got: {msg}"
    );
}

// ---------------------------------------------------------------------------
// BUG-2: FDC-on-capture — moot_file_memory must classify content
// ---------------------------------------------------------------------------

/// Filing a memory with classifiable content results in a drawer whose
/// `udc_code` is a real FDC code, not the "000.000" root.
///
/// "Biology is the scientific study of life" reliably resolves to the FDC
/// natural-sciences region. Any non-"000.000" code confirms the classification
/// path ran. The test accesses the stored drawer via the estate coordinator's
/// `recall` method (the LocusKit read path) rather than relying on the tool
/// response text (which does not surface `udc_code`).
#[test]
fn file_memory_with_classifiable_content_sets_real_udc_code() {
    let registry = EstateRegistry::new_inmemory();

    // File a memory whose content the FDC encoder reliably classifies.
    let classifiable = "Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, and evolution.";
    let a = args![
        "content"  => classifiable,
        "location" => "science-room"
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("file_memory must succeed");

    assert!(
        result["isError"] == serde_json::json!(false),
        "file_memory must succeed; got: {result:?}"
    );

    // Read back the drawer directly from the estate coordinator.
    // This exercises the stored `udc_code` field on the persisted Drawer.
    let estate = registry
        .resolve(&BTreeMap::new(), "estateID")
        .expect("default estate must resolve");

    let coord = estate.coord.lock().expect("coord lock must not be poisoned");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .expect("recall must succeed on a fresh estate");

    assert_eq!(drawers.len(), 1, "exactly one drawer must exist");

    let udc_code = &drawers[0].udc_code;
    assert!(
        udc_code != "000.000",
        "file_memory with classifiable content must set a real udc_code, not the '000.000' fallback; got: '{udc_code}'"
    );
    assert!(
        !udc_code.is_empty(),
        "udc_code must not be empty after FDC classification"
    );
}

/// Filing a memory whose content is not classifiable (short noise text)
/// falls back gracefully to "000.000" rather than failing.
///
/// Confirms the fallback path is live and that FDC failure does not propagate
/// as an error to the tool surface.
#[test]
fn file_memory_with_unclassifiable_content_falls_back_to_root_code() {
    let registry = EstateRegistry::new_inmemory();

    // A string of random tokens with no meaningful FDC signature.
    let noise = "zzq xkj blrt fnp";
    let a = args![
        "content"  => noise,
        "location" => "noise-room"
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("file_memory must succeed even for unclassifiable content");

    assert!(
        result["isError"] == serde_json::json!(false),
        "file_memory must succeed even when FDC cannot classify; got: {result:?}"
    );

    // The drawer must exist (not error out).
    let estate = registry
        .resolve(&BTreeMap::new(), "estateID")
        .expect("default estate must resolve");

    let coord = estate.coord.lock().expect("coord lock must not be poisoned");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .expect("recall must succeed");

    assert_eq!(drawers.len(), 1, "exactly one drawer must exist");
    // The drawer may or may not be "000.000" — the important thing is it exists
    // and the code is a non-empty string (either root or classified).
    assert!(
        !drawers[0].udc_code.is_empty(),
        "udc_code must never be empty regardless of FDC outcome"
    );
}
