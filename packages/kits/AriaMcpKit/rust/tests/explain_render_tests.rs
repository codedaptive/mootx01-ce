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

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
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

fn file_memory(registry: &EstateRegistry, content: &str, location: &str) {
    let subject: String = content.chars().take(120).collect();
    let a = args![
        "content" => content,
        "location" => location,
        "subject" => subject.as_str(),
        "impatient" => true
    ];
    let result = dispatch_tool("moot_file_memory", &a, registry, &SurfacedRecallLedger::new())
        .expect("moot_file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
}

const QUERY: &str = "explain-render-fixture-rust-quarterly-budget";

fn search(registry: &EstateRegistry, explain: Option<bool>) -> serde_json::Value {
    let a = match explain {
        Some(flag) => args!["query" => QUERY, "explain" => flag],
        None => args!["query" => QUERY],
    };
    let result = dispatch_tool("moot_memory_search", &a, registry, &SurfacedRecallLedger::new())
        .expect("moot_memory_search must not throw");
    assert!(is_success(&result), "search must succeed; got: {result:?}");
    result
}

#[test]
fn explain_true_interleaves_the_block_after_each_row() {
    let registry = EstateRegistry::new_inmemory_bare();
    file_memory(&registry, QUERY, "explain-tests");

    let result = search(&registry, Some(true));
    let text = content_text(&result);
    let lines: Vec<&str> = text.lines().collect();
    assert!(
        lines[0].starts_with("found "),
        "header must stay the first line; got: {text}"
    );
    // Row, then its block: the row starts with the drawer UUID and carries the
    // seven S1 columns; the next four lines are the explainer block.
    let row_idx = lines.iter().position(|l| l.contains(" · ")).expect("one S1 row");
    assert!(
        lines[row_idx + 1].starts_with("  sources: "),
        "sources line must follow the row; got: {text}"
    );
    assert!(
        lines[row_idx + 2].starts_with("  score: "),
        "score line must follow sources; got: {text}"
    );
    assert!(
        lines[row_idx + 3].starts_with("  mode: unionBest | scoring: "),
        "mode line must follow score; got: {text}"
    );
    assert!(
        lines[row_idx + 4].starts_with("  why: content query"),
        "why line must follow mode; got: {text}"
    );
    // Structured twin unchanged by explain.
    let plain = search(&registry, None);
    assert_eq!(
        result["structuredContent"], plain["structuredContent"],
        "explain must not change the structured twin"
    );
}

#[test]
fn explain_absent_renders_no_explanation_line() {
    let registry = EstateRegistry::new_inmemory_bare();
    file_memory(&registry, QUERY, "explain-tests");

    let result = search(&registry, None);
    let text = content_text(&result);
    for marker in ["  sources: ", "  score: ", "  mode: ", "  why: "] {
        assert!(
            !text.contains(marker),
            "default reply must carry no explanation line ({marker:?}); got: {text}"
        );
    }
    let explicit_false = search(&registry, Some(false));
    assert_eq!(content_text(&explicit_false), text, "explain:false equals explain absent");
}

#[test]
fn structured_row_carries_the_s1_fields() {
    let registry = EstateRegistry::new_inmemory_bare();
    file_memory(&registry, QUERY, "explain-tests");

    let result = search(&registry, None);
    let row = &result["structuredContent"]["results"][0];
    assert!(row["id"].is_string(), "id; got: {row}");
    assert!(row["score"].is_number(), "score; got: {row}");
    assert!(row["eventTime"].is_string(), "eventTime; got: {row}");
    assert!(row["subject"].is_string(), "subject; got: {row}");
    assert!(row["room"].is_string(), "room; got: {row}");
    // Subject equals content here, so firstSentence is de-duplicated away
    // (§11.1 rule 2) — it must be ABSENT, not null.
    assert!(row.get("firstSentence").is_none(), "firstSentence de-duplicated; got: {row}");
    // `content` is a memory_get depth:full field; the S1 row never carries it.
    assert!(row.get("content").is_none(), "content must not travel in the S1 row; got: {row}");
    // The text row ends with the 4-dp score column, no separate adornment line.
    let text = content_text(&result);
    assert!(!text.contains("\nadornment: "), "no separate adornment line; got: {text}");
    assert!(!text.contains("recall_provenance:"), "no recall_provenance line; got: {text}");
}

/// The reply renders at most 50 rows whatever `limit` asked for, the same
/// display cap Swift runMemorySearch applies (`prefix(50)`); the structured
/// twin covers the same 50 rows.
#[test]
fn shown_rows_are_capped_at_fifty() {
    let registry = EstateRegistry::new_inmemory_bare();
    for i in 0..55 {
        file_memory(&registry, &format!("display-cap-fixture-rust row {i} shared token capfixture"), "cap-tests");
    }
    let a = args!["query" => "capfixture", "limit" => 64];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new())
        .expect("moot_memory_search must not throw");
    assert!(is_success(&result), "search must succeed; got: {result:?}");
    let text = content_text(&result);
    let rows = text.lines().filter(|l| l.contains(" · ")).count();
    assert_eq!(rows, 50, "text rows must be capped at 50; got {rows}:\n{text}");
    assert_eq!(
        result["structuredContent"]["results"].as_array().map(|r| r.len()),
        Some(50),
        "structured rows must be capped at 50"
    );
    assert!(text.starts_with("found 50 candidate memories"), "header counts the shown rows; got: {text}");
}
