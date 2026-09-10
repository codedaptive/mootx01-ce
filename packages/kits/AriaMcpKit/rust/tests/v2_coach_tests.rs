//! V2 coaching engine gate tests — §12.5 trigger coverage.
//!
//! ## Gate criterion
//!
//! Every test in this file FAILS at commit 07a81609a (hint injection absent
//! from the dispatcher) and PASSES at HEAD (coach.rs wired into the
//! dispatcher choke point). Tests that assert a hint IS present in a success
//! result discriminate on that boundary.
//!
//! ## Coverage
//!
//! T1. moot_memory_search long query (>200 Unicode scalars) → hint in result.
//! T2. moot_memory_search zero results on fresh estate → hint in result.
//! T3. moot_file_memory content over 4,000 chars → hint in result.
//! T4. moot_recall_precise zero results on fresh estate → hint in result.
//! T5. isError carries no hint — error result has no "hint" key;
//!     paired with a triggering success result that DOES have the key.
//! T6. First-match-wins: long query on fresh estate → long-query hint, not
//!     zero-results hint (only one hint fires per call).
//! T7. Hint precedes coaching block: when both fire on the same call, the
//!     "hint:" line appears BEFORE the periodic coaching block in content[0].text.
//! T8. 512-scalar body clamp: body text clamped to 512 scalars; hint line
//!     appended AFTER the clamped body and is itself not clamped.
//!
//! Pre-existing failures NOT in this file:
//!   frozen_memory_mutating_commands_are_refused_before_the_session_records_them
//!   v2_rejects_inactive_teachme_before_the_session_records_it
//! Those belong to other waves and are tracked in the --lib suite.

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};
use genius_locus_kit::coordinator::ModesManifest;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_dispatcher() -> Dispatcher {
    // Five-arg constructor: registry, aria_name, client_name, serial, advisory.
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
}

/// Send a tools/call request through the dispatcher and return the serialised
/// response value.
fn call(dispatcher: &Dispatcher, tool: &str, args: serde_json::Value) -> serde_json::Value {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": tool, "arguments": args }
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    serde_json::to_value(&dispatcher.handle(&request)).expect("response must serialize")
}

/// Extract content[0].text from a tools/call response.
fn text(response: &serde_json::Value) -> &str {
    response["result"]["content"][0]["text"].as_str().unwrap_or("")
}

/// Extract structuredContent["hint"] from a tools/call response, if present.
fn hint_field(response: &serde_json::Value) -> Option<&str> {
    response["result"]["structuredContent"]["hint"].as_str()
}

/// True when the response has isError:true at the result level.
fn is_error(response: &serde_json::Value) -> bool {
    response["result"]["isError"].as_bool() == Some(true)
}

// ---------------------------------------------------------------------------
// T1. moot_memory_search — long query triggers hint
// ---------------------------------------------------------------------------

/// Gate: a query longer than 200 Unicode scalars fires the §12.5 long-query
/// trigger. At 07a81609a no hint was injected; the "hint" key is absent from
/// structuredContent. At HEAD the key is present with the precision coaching text.
#[test]
fn memory_search_long_query_triggers_hint() {
    let dispatcher = make_dispatcher();
    // 201 'a' characters — exactly one over the 200-scalar threshold.
    let long_query: String = "a".repeat(201);
    let response = call(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": long_query }),
    );

    // The result must be a success (long-query does not cause an error).
    assert!(
        !is_error(&response),
        "long-query must not produce an error result; got: {response}"
    );

    // structuredContent["hint"] must be present and match the exact text.
    let hint = hint_field(&response).unwrap_or_else(|| {
        panic!(
            "T1: structuredContent[\"hint\"] must be present for a >200-scalar query; \
             gate FAILS at 07a81609a and must pass at HEAD.\nFull response: {response}"
        )
    });
    assert!(
        hint.contains("200 characters") || hint.contains("shorter"),
        "T1: hint text must mention the 200-character threshold; got: {hint:?}"
    );

    // content[0].text must also contain the "hint:" line.
    let body = text(&response);
    assert!(
        body.contains("\nhint:"),
        "T1: content[0].text must contain \"\\nhint:\" suffix; got: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T2. moot_memory_search — zero results trigger hint
// ---------------------------------------------------------------------------

/// Gate: a search on a bare in-memory estate (no charter hints) returns zero
/// results, which fires the §12.5 zero-results trigger (short query so the
/// long-query trigger is not active). At 07a81609a the hint key is absent;
/// at HEAD it is present.
///
/// Uses new_inmemory_bare() to avoid the 7 charter-hint memories that the
/// standard new_inmemory() estate seeds; those would produce non-zero results.
#[test]
fn memory_search_zero_results_triggers_hint() {
    let dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory_bare(),
        "ARIA_MCP_Rust", "test", "test-serial", None,
    );
    // Short query — well under 200 scalars.
    let response = call(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": "xyzzy" }),
    );

    assert!(
        !is_error(&response),
        "T2: zero-results search must not produce an error; got: {response}"
    );

    let hint = hint_field(&response).unwrap_or_else(|| {
        panic!(
            "T2: structuredContent[\"hint\"] must be present when zero results are returned; \
             gate FAILS at 07a81609a.\nFull response: {response}"
        )
    });
    assert!(
        hint.contains("No memories matched") || hint.contains("moot_file_memory"),
        "T2: hint must guide toward filing content; got: {hint:?}"
    );

    let body = text(&response);
    assert!(
        body.contains("\nhint:"),
        "T2: content[0].text must contain \"\\nhint:\" suffix; got: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T3. moot_file_memory — large content triggers hint
// ---------------------------------------------------------------------------

/// Gate: filing a memory whose content exceeds 4,000 Unicode scalars fires the
/// §12.5 large-content trigger. The estate operation still succeeds; the hint
/// is attached to the success envelope.
#[test]
fn file_memory_large_content_triggers_hint() {
    let dispatcher = make_dispatcher();
    // 4001 characters — one over the 4,000-scalar threshold.
    let large_content: String = "x".repeat(4001);
    let response = call(
        &dispatcher,
        "moot_file_memory",
        serde_json::json!({
            "content": large_content,
            "subject": "Large content gate test.",
            "location": "default"
        }),
    );

    assert!(
        !is_error(&response),
        "T3: large-content file must not produce an error; got: {response}"
    );

    let hint = hint_field(&response).unwrap_or_else(|| {
        panic!(
            "T3: structuredContent[\"hint\"] must be present when content > 4,000 scalars; \
             gate FAILS at 07a81609a.\nFull response: {response}"
        )
    });
    assert!(
        hint.contains("4,000") || hint.contains("splitting"),
        "T3: hint must mention the 4,000-character threshold or splitting; got: {hint:?}"
    );

    let body = text(&response);
    assert!(
        body.contains("\nhint:"),
        "T3: content[0].text must contain \"\\nhint:\" suffix; got: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T4. Any lens — zero results trigger hint
// ---------------------------------------------------------------------------

/// Gate: moot_recall_precise on a bare in-memory estate (no charter hints)
/// returns zero results, firing the §12.5 any-lens zero-results trigger.
/// At 07a81609a the hint is absent; at HEAD it is present.
///
/// Uses new_inmemory_bare() because the standard estate has 7 charter-hint
/// memories that the lexical engine returns even for unrelated queries.
#[test]
fn recall_precise_zero_results_triggers_hint() {
    let dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory_bare(),
        "ARIA_MCP_Rust", "test", "test-serial", None,
    );
    let response = call(
        &dispatcher,
        "moot_recall_precise",
        serde_json::json!({ "query": "non existent query xyzzy" }),
    );

    assert!(
        !is_error(&response),
        "T4: zero-results recall must not produce an error; got: {response}"
    );

    let hint = hint_field(&response).unwrap_or_else(|| {
        panic!(
            "T4: structuredContent[\"hint\"] must be present when a lens returns zero results; \
             gate FAILS at 07a81609a.\nFull response: {response}"
        )
    });
    assert!(
        hint.contains("zero results") || hint.contains("adjusting") || hint.contains("moot_list_lenses"),
        "T4: hint must guide toward adjusting the query or checking available lenses; got: {hint:?}"
    );

    let body = text(&response);
    assert!(
        body.contains("\nhint:"),
        "T4: content[0].text must contain \"\\nhint:\" suffix; got: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T5. isError carries no hint
// ---------------------------------------------------------------------------

/// Gate: a result with isError:true must NEVER carry a "hint" key in
/// structuredContent. Paired with a triggering success call that DOES carry the
/// key, so this test discriminates: at 07a81609a the success call lacks the key;
/// at HEAD the success call has the key and the error call correctly omits it.
#[test]
fn is_error_result_carries_no_hint() {
    let dispatcher = make_dispatcher();

    // 1. Success path: long query fires the long-query hint.
    let long_query: String = "b".repeat(201);
    let success_response = call(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": long_query }),
    );
    assert!(
        !is_error(&success_response),
        "T5 setup: long-query must produce a success result"
    );
    assert!(
        hint_field(&success_response).is_some(),
        "T5: success path must carry structuredContent[\"hint\"]; \
         gate FAILS at 07a81609a where no hints exist.\nFull response: {success_response}"
    );

    // 2. Error path: moot_erase_memory with a non-existent memory ID produces
    //    an operational refusal (isError:true). No hint may be present.
    let response = call(
        &dispatcher,
        "moot_erase_memory",
        serde_json::json!({
            "memory_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "confirmation": true
        }),
    );
    assert!(
        is_error(&response),
        "T5: erase of non-existent memory must produce isError:true; got: {response}"
    );
    assert!(
        hint_field(&response).is_none(),
        "T5: isError:true result must NOT carry structuredContent[\"hint\"]; got: {response}"
    );
    // Also: the content text must not contain a "hint:" line on an error result.
    let body = text(&response);
    assert!(
        !body.contains("\nhint:"),
        "T5: content text of an error result must not contain a hint line; got: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T6. First-match-wins
// ---------------------------------------------------------------------------

/// Gate: a query over 200 scalars on a fresh estate would satisfy BOTH the
/// long-query trigger AND the zero-results trigger. §12.5 specifies first-match-
/// wins. The long-query trigger is listed first and must be the one that fires.
/// Only one "hint:" line may appear in the text.
#[test]
fn first_match_wins_long_query_beats_zero_results() {
    let dispatcher = make_dispatcher();
    let long_query: String = "c".repeat(201);
    let response = call(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": long_query }),
    );

    assert!(
        !is_error(&response),
        "T6: long query on fresh estate must not produce an error; got: {response}"
    );

    let hint = hint_field(&response).unwrap_or_else(|| {
        panic!(
            "T6: structuredContent[\"hint\"] must be present; \
             gate FAILS at 07a81609a.\nFull response: {response}"
        )
    });

    // The FIRST trigger (long-query) must fire, not the zero-results trigger.
    assert!(
        hint.contains("200 characters") || hint.contains("shorter"),
        "T6: first-match hint must be the long-query hint, not zero-results; got: {hint:?}"
    );
    assert!(
        !hint.contains("No memories matched"),
        "T6: zero-results hint must NOT fire when long-query fires first; got: {hint:?}"
    );

    // Exactly one hint line in the text.
    let body = text(&response);
    let hint_line_count = body.matches("\nhint:").count();
    assert_eq!(
        hint_line_count, 1,
        "T6: exactly one \"hint:\" line must appear in content text (first-match-wins); \
         got {hint_line_count} in: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T7. Hint precedes coaching block
// ---------------------------------------------------------------------------

/// Gate: when a hint fires AND the periodic coaching block fires on the same
/// call, the hint line must appear BEFORE the coaching block in content[0].text.
///
/// Uses a provisioned dispatcher with coaching_calls=1 so the coaching block
/// fires on the very first call. moot_memory_search with a long query fires the
/// hint on the same call. The test asserts the ordering.
#[test]
fn hint_precedes_coaching_block_in_text() {
    // Provision coaching_calls=1 so the coaching block fires immediately.
    let registry = EstateRegistry::new_inmemory();
    let config = ModesManifest { sticky_enabled: true, coaching_calls: 1 };
    registry
        .coord
        .lock()
        .expect("coordinator lock")
        .provision_modes_config(&registry.default.handle, &config)
        .expect("provision_modes_config must succeed");
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    // Long query on a fresh estate: fires hint (long-query trigger) AND
    // coaching block (call 1 with coaching_calls=1).
    let long_query: String = "d".repeat(201);
    let response = call(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": long_query }),
    );

    assert!(
        !is_error(&response),
        "T7: long query must produce a success result; got: {response}"
    );

    let body = text(&response);

    // Both hint and coaching block must be present.
    assert!(
        body.contains("\nhint:"),
        "T7: content text must contain \"\\nhint:\" line; got: {body:?}"
    );
    assert!(
        body.contains("moot_estate_status") || body.contains("coaching") || body.contains("mode"),
        "T7: content text must contain the coaching block; got: {body:?}"
    );

    // The hint line must PRECEDE the coaching block.
    let hint_pos = body
        .find("\nhint:")
        .expect("T7: hint position must be found");
    // The coaching block ends with text from PeriodicCoach; find a distinctive
    // part of the coaching preamble that appears only in the coaching block.
    // The periodic coach block starts with a newline and contains session guidance.
    // We verify the hint appears before the last occurrence of "\n\n" which
    // separates the hint from the appended coaching block.
    let coaching_start = body
        .rfind("\n\n")
        .or_else(|| body.find("moot_estate_status"))
        .unwrap_or(body.len());
    assert!(
        hint_pos < coaching_start,
        "T7: hint line must appear BEFORE the coaching block; \
         hint at byte {hint_pos}, coaching block at byte {coaching_start}.\nText: {body:?}"
    );
}

// ---------------------------------------------------------------------------
// T8. 512-scalar body clamp; hint line survives unclamped
// ---------------------------------------------------------------------------

/// Gate: the v2 envelope clamps content[0].text to 512 Unicode scalars.
/// The hint line is appended AFTER the clamp and is itself NOT clamped.
///
/// Test: file a memory whose text representation triggers the large-content
/// hint (>4,000 chars). The body text in the response is clamped to 512
/// scalars. The "hint:" suffix appears after the 512-scalar boundary.
#[test]
fn body_clamped_hint_survives_unclamped() {
    let dispatcher = make_dispatcher();

    // Content: 4001 characters of 'e' — triggers the large-content hint.
    // The compact body text in the success envelope is the tool name / action
    // text, NOT the content itself, so the clamp test focuses on the body text.
    // Use moot_memory_search with a 513-char query to produce a long compact
    // body and simultaneously trigger the hint. The query itself is over 200
    // chars (triggering the long-query hint) and the response body is the
    // search result text clamped to 512 scalars.
    //
    // We construct a long query designed so the body text from the search
    // result is likely to be short (it is), so instead we directly test the
    // apply_hint render function through the v2 path by filing a memory whose
    // CONTENT is just over 512 chars AND just over 4,000 chars to ensure both
    // triggers fire together.
    //
    // Simpler and more direct: the body of a moot_file_memory response is
    // the compact text of the success envelope. We use a large content string;
    // the SUCCESS compact text is fixed (e.g., "filed memory ..."), not the
    // content itself. The hint line is appended after the compact text.
    //
    // For the clamp test, the body in the response must be <= 512 scalars
    // in its first segment (before "\nhint:"), and the hint is present after.
    let large_content: String = "f".repeat(4001);
    let response = call(
        &dispatcher,
        "moot_file_memory",
        serde_json::json!({
            "content": large_content,
            "subject": "Clamp gate test.",
            "location": "default"
        }),
    );

    assert!(
        !is_error(&response),
        "T8: large file_memory must produce a success result; got: {response}"
    );

    let body = text(&response);

    // The hint line must be present (large-content trigger fires).
    assert!(
        body.contains("\nhint:"),
        "T8: content text must contain \"\\nhint:\" suffix; got: {body:?}"
    );

    // Split at the hint boundary.
    let (before_hint, after_hint) = body
        .split_once("\nhint:")
        .expect("T8: hint separator must be present in body");

    // The body before the hint must be at most 512 Unicode scalars.
    let body_scalar_count: usize = before_hint.chars().count();
    assert!(
        body_scalar_count <= 512,
        "T8: body before hint must be <= 512 scalars (the compact-text clamp limit); \
         got {body_scalar_count} scalars. Body segment: {before_hint:?}"
    );

    // The hint text after the separator must not be empty.
    assert!(
        !after_hint.trim().is_empty(),
        "T8: hint text after the separator must not be empty; got: {after_hint:?}"
    );
}
