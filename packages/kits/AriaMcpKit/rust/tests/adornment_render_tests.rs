//! Adornment render-surface tests (ADORN-STORE-02 Part C):
//! adornment text appearing in moot_memory_search payloads when provisioned
//! via the normalized adornments store, and zero-active-minters as the
//! suppression arm.
//!
//! Cross-port conformance: reads the SAME physical fixture as the Swift tests
//! at `Tests/Conformance/adornment_render_fixture.json`. Neither port hardcodes
//! the adornment text — changing the fixture simultaneously breaks both ports.
//!
//! Provisioning path (ADORN-STORE-02): `register_adornment_minter` +
//! `put_adornment` via `DrawerStore` trait on the registry's store. The retired
//! `set_adornment` + `MOOT_SUPPRESS_ADORNMENT` seam is gone; zero-active-minters
//! is now the suppression arm (no active minters → no adornment line in the
//! search payload).

use std::collections::BTreeMap;
use std::path::Path;

use adornment_lib::{AdornmentMinterDescriptor, StoredAdornment};
use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
    tool_list::build_tool_list_with_flags,
};
use locus_kit::drawer_store::DrawerStore;

// ---------------------------------------------------------------------------
// Fixture + test helpers
// ---------------------------------------------------------------------------

/// Read the shared `adornment_render_fixture.json` and return `adornment_text`.
///
/// CARGO_MANIFEST_DIR resolves to `packages/kits/AriaMcpKit/rust/`.
/// The fixture lives at `packages/kits/AriaMcpKit/Tests/Conformance/`, i.e.,
/// one level up from `rust/` then into `Tests/Conformance/`.
fn fixture_adornment_text() -> String {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()   // AriaMcpKit/
        .expect("parent of rust/ must exist")
        .join("Tests/Conformance/adornment_render_fixture.json");

    let data = std::fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| {
            panic!("Failed to read fixture at {}: {}", fixture_path.display(), e)
        });

    let parsed: serde_json::Value = serde_json::from_str(&data)
        .expect("adornment_render_fixture.json must be valid JSON");

    parsed
        .get("adornment_text")
        .and_then(|v| v.as_str())
        .expect("adornment_render_fixture.json must have an 'adornment_text' string field")
        .to_owned()
}

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

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

/// File a drawer with content + subject and return its ID.
fn file_memory(registry: &EstateRegistry, content: &str, location: &str) -> String {
    let subject: String = content.chars().take(120).collect();
    let a = args![
        "content" => content,
        "location" => location,
        "subject" => subject.as_str(),
        "impatient" => true
    ];
    let result = dispatch_tool(
        "moot_file_memory",
        &a,
        registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
    let text = content_text(&result);
    // Result line: "filed memory <id>\nroom: ..."
    text.lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .unwrap_or("")
        .to_owned()
}

/// Register a test minter and write one adornment row for `drawer_id` via the
/// normalized adornments store (ADORN-STORE-02). Returns the minter ID so the
/// caller can deactivate it to test the zero-active-minters suppression arm.
fn register_minter_and_write_adornment(
    registry: &EstateRegistry,
    minter_id: &str,
    drawer_id: &str,
    text: &str,
) {
    // is_active = true: active_adornments() returns this row in the search path.
    let minter = AdornmentMinterDescriptor::new(
        minter_id,
        "Test Minter",
        "test",
        "test-model-v1",
        "2026",
        "test-prompt-digest",
        BTreeMap::new(),
        true,
    );
    registry
        .default
        .store
        .register_adornment_minter(&minter)
        .unwrap_or_else(|e| panic!("register_adornment_minter must succeed: {e}"));

    let adornment = StoredAdornment::new(drawer_id, minter_id, text);
    registry
        .default
        .store
        .put_adornment(&adornment)
        .unwrap_or_else(|e| panic!("put_adornment must succeed: {e}"));
}

// ---------------------------------------------------------------------------
// Test 1: adornment appears in search payload when active minter is present
// ---------------------------------------------------------------------------

/// Active minter + adornment row → the adornment text surfaces as column 5 of
/// the S1 row in the search payload. Provisioned via the normalized adornments
/// store (ADORN-STORE-02).
///
/// Failure mode: the adornment text absent from the payload — `active_adornments`
/// batch read missing from the search render loop, or minter not active.
#[test]
fn adornment_appears_in_search_payload() {
    let adornment_text = fixture_adornment_text();
    let fixture_query = "adornment-render-fixture-store-rust";

    let registry = EstateRegistry::new_inmemory_bare();
    let drawer_id =
        file_memory(&registry, fixture_query, "adornment-tests");
    register_minter_and_write_adornment(
        &registry,
        "test-minter-active-render",
        &drawer_id,
        &adornment_text,
    );

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => fixture_query],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_memory_search must not throw");

    assert!(is_success(&result), "search must succeed; got: {result:?}");
    let body = content_text(&result);
    // S1 row format: id · subject · firstSentence · SSC · <adornmentText> · eventTime · score
    // The adornment text is column 5 (no label prefix) per ARIA_MCP_INTERFACE.md §11.2,
    // the same assertion AdornmentRenderTests.swift makes.
    let expected_column = format!(" · {} · ", adornment_text);
    assert!(
        body.contains(&expected_column),
        "adorned drawer must surface adornment text as column 5 of the S1 row;\n\
         expected column: {expected_column}\n\
         got: {body}"
    );
}

// ---------------------------------------------------------------------------
// Test 2: zero active minters → adornment line absent (suppression arm)
// ---------------------------------------------------------------------------

/// No active minters → adornment line absent from the search payload.
/// Zero-active-minters IS the suppression arm (replaces retired MOOT_SUPPRESS_ADORNMENT).
///
/// Failure mode: the adornment text still appears — active_adornments batch read
/// not filtering by active minter, or old d.adornment path still live.
#[test]
fn zero_active_minters_suppresses_adornment_line() {
    let adornment_text = fixture_adornment_text();
    let fixture_query = "adornment-render-zero-minters-rust";

    let registry = EstateRegistry::new_inmemory_bare();
    // File the memory but do NOT register any active minters or write any adornment rows.
    // The search result must have no "adornment:" line.
    let _drawer_id = file_memory(&registry, fixture_query, "adornment-tests");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => fixture_query],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_memory_search must not throw");

    assert!(is_success(&result), "search must succeed; got: {result:?}");
    let body = content_text(&result);
    // No adornment rows in the store → column 5 renders '-' and the text is absent.
    assert!(
        !body.contains(&adornment_text),
        "no active minters → adornment text must be absent from payload;\n\
         got: {body}\n\
         (fixture adornment_text was: {adornment_text})"
    );
}

// ---------------------------------------------------------------------------
// Test 3: tool schema JSON does not mention MOOT_SUPPRESS_ADORNMENT
// ---------------------------------------------------------------------------

/// The retired MOOT_SUPPRESS_ADORNMENT seam must not appear in any tool
/// description or inputSchema JSON — it is a benchmark-internal identifier
/// and must never be exposed to AI clients via the tool catalog.
///
/// Failure mode: "MOOT_SUPPRESS_ADORNMENT" appears in a tool description or
/// inputSchema — the old env-var name leaked into public-facing schema text.
#[test]
fn tool_schemas_do_not_mention_suppress_var() {
    // vault_on=true, memory_on=false: full tool surface without the opt-in
    // memory-adapter tier; gives the widest tool list to check.
    let tools_json = build_tool_list_with_flags(true, false);
    let tools_str = tools_json.to_string();

    assert!(
        !tools_str.contains("MOOT_SUPPRESS_ADORNMENT"),
        "tool list JSON must not mention MOOT_SUPPRESS_ADORNMENT — \
         seam is retired (ADORN-STORE-02); found in tool list: {}",
        if tools_str.contains("MOOT_SUPPRESS_ADORNMENT") { "yes" } else { "no" }
    );
}
