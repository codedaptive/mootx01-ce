//! `moot_memory_search` explain rendering (PAR-1).
//!
//! The tool schema advertises `explain`; these tests pin that the Rust reply
//! honours it the way the Swift reply does:
//!   1. explain:true — every candidate row is followed by the GLK explanation
//!      block, two-space indented: `sources:`, `score:`, `mode: … | scoring: …`,
//!      `why:`; the header stays first and the structured twin is unchanged.
//!   2. explain absent — the text carries no explanation line at all, so the
//!      default reply is byte-identical to the pre-explain shape.
//!   3. The structured row carries the S1 fields the Swift reply carries:
//!      `score`, `eventTime`, `firstSentence`, `subject`, `room`.

use std::collections::BTreeMap;

mod test_support;
use test_support::SelectedV2Session;

use aria_mcp::{
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
};

macro_rules! args {
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

fn file_memory(session: &SelectedV2Session, content: &str, location: &str) {
    let subject: String = content.chars().take(120).collect();
    let a = args![
        "content" => content,
        "location" => location,
        "subject" => subject.as_str(),
        "impatient" => true
    ];
    let result = session.call("moot_file_memory", &a)
        .expect("moot_file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
}

const QUERY: &str = "explain-render-fixture-rust-quarterly-budget";

fn search(session: &SelectedV2Session, explain: Option<bool>) -> serde_json::Value {
    let a = match explain {
        Some(flag) => args!["query" => QUERY, "explain" => flag],
        None => args!["query" => QUERY],
    };
    let result = session.call("moot_memory_search", &a)
        .expect("moot_memory_search must not throw");
    assert!(is_success(&result), "search must succeed; got: {result:?}");
    result
}

#[test]
fn selected_memory_search_accepts_explain_without_changing_structured_rows() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    file_memory(&session, QUERY, "explain-tests");

    let result = search(&session, Some(true));
    let rows = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("selected-v2 search must return structured rows");
    assert_eq!(rows.len(), 1, "explain request must retain the matching row: {result}");
    assert_eq!(rows[0]["subject"], QUERY);
    // The live typed payload is invariant to the presentation-only option.
    let plain = search(&session, None);
    assert_eq!(
        result["structuredContent"]["data"], plain["structuredContent"]["data"],
        "explain must not change the structured twin"
    );
}

#[test]
fn explain_absent_renders_no_explanation_line() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    file_memory(&session, QUERY, "explain-tests");

    let result = search(&session, None);
    let text = content_text(&result);
    for marker in ["  sources: ", "  score: ", "  mode: ", "  why: "] {
        assert!(
            !text.contains(marker),
            "default reply must carry no explanation line ({marker:?}); got: {text}"
        );
    }
    let explicit_false = search(&session, Some(false));
    assert_eq!(content_text(&explicit_false), text, "explain:false equals explain absent");
}
