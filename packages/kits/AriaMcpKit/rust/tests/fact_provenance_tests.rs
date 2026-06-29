//! fact_provenance_tests.rs — Rust parallel tests for two fact-surface fixes.
//!
//! # Bug C — Host identity injected into EstateRegistry
//!
//! Every `moot_file_fact` call (with no explicit `source_id`) stamps
//! `source=<server_identity>` from the registry field. The constant
//! `SERVER_ADDED_BY = "aria-mcp-server"` is gone; the correct identity is
//! injected at registry construction time and overrideable before the first
//! tool call. Tests verify:
//!
//! 1. A registry with `server_identity = "mootx01"` stamps `source=mootx01`.
//! 2. A registry with the default identity stamps `source=aria-mcp-server`.
//! 3. When the caller supplies an explicit `source_id`, that value wins over
//!    the registry identity.
//!
//! # Bug D — Dark-lane hint in moot_fact_search
//!
//! When the dense lane is dark (no corpus registered) and a query is supplied,
//! `moot_fact_search` appends a `recall_provenance:` line so AI callers can
//! distinguish "no lexical match" from "semantic search was not consulted".
//! Tests verify:
//!
//! 4. A bare estate (no corpus) + a query → `recall_provenance:` and
//!    `dense_lane:` tokens are present in the response.
//! 5. A bare estate (no corpus) with no query → `recall_provenance:` is
//!    absent (list-all path has no semantic query to misinterpret).
//!
//! Mirrors Swift `FactProvenanceTests.swift` in AriaMCPTests.

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

// ---------------------------------------------------------------------------
// Bug C: Host identity stamped on facts
// ---------------------------------------------------------------------------

/// A registry with server_identity = "mootx01" must stamp facts with
/// source=mootx01 when no explicit source_id is supplied.
///
/// Mirrors Swift test: factFiledWithMootx01IdentityGetsMootx01Source.
#[test]
fn fact_filed_with_mootx01_identity_gets_mootx01_source() {
    // Bare estate — no corpus needed for provenance tests.
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = "mootx01".to_owned();
    let ledger = SurfacedRecallLedger::new();

    let file_args = args![
        "subject" => "Paris",
        "predicate" => "is_capital_of",
        "object" => "France",
    ];
    let file_result = dispatch_tool("moot_file_fact", &file_args, &registry, &ledger)
        .expect("moot_file_fact must not error");
    assert!(
        is_success(&file_result),
        "moot_file_fact must succeed; got: {file_result:?}"
    );

    // Retrieve via moot_fact_search and inspect the source= stamp.
    let search_args = args!["query" => "Paris"];
    let search_result = dispatch_tool("moot_fact_search", &search_args, &registry, &ledger)
        .expect("moot_fact_search must not error");
    let text = content_text(&search_result);
    assert!(
        text.contains("source=mootx01"),
        "fact filed via identity 'mootx01' must carry source=mootx01; got: {text}"
    );
    assert!(
        !text.contains("source=aria-mcp-server"),
        "mootx01-hosted registry must NOT stamp 'aria-mcp-server'; got: {text}"
    );
}

/// A registry with the default server_identity ("aria-mcp-server") must stamp
/// facts with source=aria-mcp-server.
///
/// Mirrors Swift test: factFiledWithAriaMcpIdentityGetsAriaMcpSource.
#[test]
fn fact_filed_with_aria_mcp_identity_gets_aria_mcp_source() {
    // Set the host identity explicitly (mirrors Swift openBareEstate(identity:
    // "aria-mcp-server")). The bare registry defaults to "mootx01" (the product
    // identity), so this test — which verifies the aria-mcp-server identity path
    // — sets it rather than relying on a default.
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = "aria-mcp-server".to_owned();
    let ledger = SurfacedRecallLedger::new();

    let file_args = args![
        "subject" => "Berlin",
        "predicate" => "is_capital_of",
        "object" => "Germany",
    ];
    dispatch_tool("moot_file_fact", &file_args, &registry, &ledger)
        .expect("moot_file_fact must not error");

    let search_args = args!["query" => "Berlin"];
    let search_result = dispatch_tool("moot_fact_search", &search_args, &registry, &ledger)
        .expect("moot_fact_search must not error");
    let text = content_text(&search_result);
    assert!(
        text.contains("source=aria-mcp-server"),
        "fact filed via identity 'aria-mcp-server' must carry source=aria-mcp-server; got: {text}"
    );
}

/// When the caller explicitly supplies a source_id, that value wins over the
/// registry's server_identity — explicit source is honoured.
///
/// Mirrors Swift test: explicitSourceIdOverridesServerIdentity.
#[test]
fn explicit_source_id_overrides_server_identity() {
    let mut registry = EstateRegistry::new_inmemory_bare();
    registry.server_identity = "mootx01".to_owned();
    let ledger = SurfacedRecallLedger::new();

    let file_args = args![
        "subject" => "Tokyo",
        "predicate" => "is_capital_of",
        "object" => "Japan",
        "source_id" => "external-agent",
    ];
    dispatch_tool("moot_file_fact", &file_args, &registry, &ledger)
        .expect("moot_file_fact must not error");

    let search_args = args!["query" => "Tokyo"];
    let search_result = dispatch_tool("moot_fact_search", &search_args, &registry, &ledger)
        .expect("moot_fact_search must not error");
    let text = content_text(&search_result);
    assert!(
        text.contains("source=external-agent"),
        "explicit source_id must override server identity; got: {text}"
    );
    assert!(
        !text.contains("source=mootx01"),
        "server identity must NOT appear when explicit source_id is supplied; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Bug D: Dark-lane hint in moot_fact_search
// ---------------------------------------------------------------------------

/// When the dense lane is dark (no corpus registered) and a query is supplied,
/// moot_fact_search must append a recall_provenance line so the caller knows
/// the match was lexical-only.
///
/// Mirrors Swift test: factSearchAppendsProvenance_whenQueryAndDenseLaneDark.
#[test]
fn fact_search_appends_provenance_when_query_and_dense_lane_dark() {
    // Bare estate — no corpus registered, dense lane is dark by design.
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    // File a fact so the estate is non-empty (proves the hint is about
    // lane state, not about the estate being empty).
    let file_args = args![
        "subject" => "Swift",
        "predicate" => "created_by",
        "object" => "Apple",
    ];
    dispatch_tool("moot_file_fact", &file_args, &registry, &ledger)
        .expect("moot_file_fact must not error");

    // Search with a query — dense lane is dark so a recall_provenance line
    // must appear.
    let search_args = args!["query" => "Swift"];
    let search_result = dispatch_tool("moot_fact_search", &search_args, &registry, &ledger)
        .expect("moot_fact_search must not error");
    let text = content_text(&search_result);
    assert!(
        text.contains("recall_provenance:"),
        "moot_fact_search with a query on a dark-dense-lane estate must emit recall_provenance:; got: {text}"
    );
    assert!(
        text.contains("dense_lane:"),
        "recall_provenance line must include a dense_lane: token; got: {text}"
    );
}

/// When no query is supplied (list-all path), no recall_provenance hint is
/// emitted — there is no semantic query to misinterpret.
///
/// Mirrors Swift test: factSearchNoProvenanceHint_whenNoQuery.
#[test]
fn fact_search_no_provenance_hint_when_no_query() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    let file_args = args![
        "subject" => "Rust",
        "predicate" => "created_by",
        "object" => "Graydon Hoare",
    ];
    dispatch_tool("moot_file_fact", &file_args, &registry, &ledger)
        .expect("moot_file_fact must not error");

    // No query → list-all path → no provenance hint.
    let search_args = args![];
    let search_result = dispatch_tool("moot_fact_search", &search_args, &registry, &ledger)
        .expect("moot_fact_search must not error");
    let text = content_text(&search_result);
    assert!(
        !text.contains("recall_provenance:"),
        "moot_fact_search without a query must NOT emit recall_provenance:; got: {text}"
    );
}
