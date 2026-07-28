//! Regression suite for the unknown-arg hint (FIX-MCP Part A).
//!
//! Mirrors Swift `UnknownArgHintTests.swift`.
//!
//! Before FIX-MCP, unrecognized argument keys were silently dropped. This bit
//! us twice in two days:
//!   - "location" constant arg sent to moot_memory_search was silently dropped.
//!   - Benchmark runner sent "n" (meant to be "impatient") to moot_file_memory;
//!     capture ran without the flag, invalidating a full benchmark comparison.
//!
//! After the fix: non-error results get a trailing hint line, and the key is
//! logged to stderr. Error results are not augmented.
//!
//! Part B additions (echo_query schema parity tests) are added in the Part B commit.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

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

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn dispatch(name: &str, args: &BTreeMap<String, JsonValue>) -> serde_json::Value {
    let registry = EstateRegistry::new_inmemory_bare();
    dispatch_tool(name, args, &registry, &SurfacedRecallLedger::new())
        .expect("dispatch must not throw for this call")
}

// ---------------------------------------------------------------------------
// Baseline: known-good call produces no hint
// ---------------------------------------------------------------------------

#[test]
fn known_good_call_produces_no_hint() {
    // A call with only declared argument keys must NOT trigger the hint.
    let result = dispatch(
        "moot_file_memory",
        &args!["content" => "baseline test memory", "location" => "unk-arg-tests"],
    );
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        !text.contains("hint: unrecognized argument(s) ignored"),
        "a call with only declared args must NOT produce an unrecognized-arg hint; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Bogus arg produces hint, tool still succeeds
// ---------------------------------------------------------------------------

#[test]
fn bogus_arg_produces_hint_and_tool_succeeds() {
    let result = dispatch(
        "moot_file_memory",
        &args![
            "content" => "bogus arg test",
            "location" => "unk-arg-tests",
            "totally_fake_arg" => "flagged"
        ],
    );
    assert!(
        is_success(&result),
        "unrecognized arg must NOT cause the tool call to fail"
    );
    let text = content_text(&result);
    assert!(
        text.contains("hint: unrecognized argument(s) ignored: totally_fake_arg"),
        "result must contain the hint line naming the unrecognized key; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Regression: "n" sent to moot_file_memory instead of "impatient"
// ---------------------------------------------------------------------------

#[test]
fn regression_n_arg_to_file_memory_should_hint() {
    // The benchmark runner sent "n" (short for "impatient") for an entire run.
    // The arg was silently dropped. This test pins the correct behavior.
    let result = dispatch(
        "moot_file_memory",
        &args![
            "content" => "impatient regression test",
            "location" => "unk-arg-tests",
            "n" => true          // wrong key — should have been "impatient"
        ],
    );
    assert!(
        is_success(&result),
        "wrong key must NOT cause the call to fail — loose clients must keep working"
    );
    let text = content_text(&result);
    assert!(
        text.contains("hint: unrecognized argument(s) ignored: n"),
        "result must hint that 'n' is not a recognized arg (caller meant 'impatient'); got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Regression: "location" sent to moot_memory_search
// ---------------------------------------------------------------------------

#[test]
fn regression_location_arg_to_memory_search_should_hint() {
    // "location" constant arg was sent to moot_memory_search expecting to
    // restrict the search scope. It was silently dropped. This pins the fix.
    let result = dispatch(
        "moot_memory_search",
        &args![
            "query" => "regression test query",
            "location" => "unk-arg-tests"   // not a declared arg on moot_memory_search
        ],
    );
    assert!(
        is_success(&result),
        "wrong key must NOT cause the call to fail"
    );
    let text = content_text(&result);
    assert!(
        text.contains("hint: unrecognized argument(s) ignored: location"),
        "result must hint that 'location' is not a recognized arg; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Multiple unrecognized keys are sorted in hint
// ---------------------------------------------------------------------------

#[test]
fn multiple_unrecognized_keys_are_sorted_in_hint() {
    let result = dispatch(
        "moot_file_memory",
        &args![
            "content" => "multi-unrecognized test",
            "location" => "unk-arg-tests",
            "zzz_last" => "z",
            "aaa_first" => "a"
        ],
    );
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("hint: unrecognized argument(s) ignored: aaa_first, zzz_last"),
        "multiple unrecognized keys must be listed sorted alphabetically; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Part B — echo_query schema parity tests
// ---------------------------------------------------------------------------
//
// Note: testing the header FORMAT requires a populated distillation tier, which
// the in-memory test estate does not have. The Rust bare estate returns an error
// result (isError:true) when the distillation lane is absent — a pre-existing
// behavior difference from Swift (which catches the error and returns
// "found 0 distilled factoid(s)" as a success result).
//
// We test what IS testable without a full estate:
//   1. `accepted_arg_keys` includes "echo_query" — proves the schema was updated.
//   2. echo_query:true does NOT produce the unrecognized-arg hint.
//   3. Error results are not augmented with hint text.
//
// The header format behavior (default off / opt-in on) is covered by the Swift
// RecipeToolsTests.swift end-to-end tests.

use aria_mcp::tool_list::accepted_arg_keys;

#[test]
fn recall_distilled_echo_query_is_in_accepted_keys() {
    // echo_query must be declared in the moot_recall_distilled inputSchema.
    // This proves the schema was updated — not just the handler.
    let keys = accepted_arg_keys("moot_recall_distilled")
        .expect("moot_recall_distilled must be a known tool");
    assert!(
        keys.contains("echo_query"),
        "echo_query must be a declared arg on moot_recall_distilled; got: {:?}", keys
    );
}

#[test]
fn recall_distilled_echo_query_true_does_not_trigger_unrecognized_hint() {
    // Calling moot_recall_distilled with echo_query:true must NOT produce the
    // "hint: unrecognized argument(s) ignored" line — echo_query is declared.
    // The call itself may return isError:true (missing distillation lane — pre-existing
    // Rust behavior on bare test estates); the hint mechanism checks the schema,
    // not the result content.
    let result = dispatch(
        "moot_recall_distilled",
        &args!["query" => "test echo query", "echo_query" => true],
    );
    // Whether success or error, no unrecognized-arg hint must appear.
    let text = content_text(&result);
    assert!(
        !text.contains("hint: unrecognized argument(s) ignored"),
        "echo_query is a declared arg — must NOT trigger unrecognized-arg hint; got: {text}"
    );
}

#[test]
fn recall_distilled_error_result_is_not_augmented_with_hint() {
    // Error results (isError:true) must NOT have hint text appended — they carry
    // their own message and the hint check is not meaningful there.
    // On a bare test estate, moot_recall_distilled returns isError:true (missing
    // distillation lane). A bogus arg key produces a stderr log but no text augmentation.
    let result = dispatch(
        "moot_recall_distilled",
        &args!["query" => "test", "totally_bogus" => "value"],
    );
    if result["isError"] == serde_json::json!(true) {
        let text = content_text(&result);
        assert!(
            !text.contains("hint: unrecognized argument(s) ignored"),
            "error results must NOT be augmented with hint text; got: {text}"
        );
    }
}
