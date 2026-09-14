//! Live selected-v2 coverage for the lens operations whose former v1 tests
//! exercised real captured drawers.  The fixture is filed through the public
//! door; each assertion therefore proves the selected dispatcher admits the
//! request, reaches the typed lower runner, and projects that runner's receipt.

use std::collections::BTreeMap;

mod test_support;

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};
use test_support::SelectedV2Session;

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $key:expr => $value:expr ),+ $(,)? ) => {{
        let mut values = BTreeMap::new();
        $( values.insert($key.to_owned(), JsonValue::from(serde_json::json!($value))); )+
        values
    }};
}

fn file(session: &SelectedV2Session, content: &str) -> String {
    let filed = session
        .call(
            "moot_file_memory",
            &args![
                "content" => content,
                "subject" => content,
                "location" => "lens-live-room",
            ],
        )
        .expect("selected-v2 file_memory must dispatch");
    assert_eq!(filed["isError"], serde_json::json!(false), "{filed:?}");
    filed["structuredContent"]["data"]["memory_id"]
        .as_str()
        .expect("file receipt must expose memory_id")
        .to_owned()
}

fn selected_data<'a>(result: &'a serde_json::Value, tool: &str) -> &'a serde_json::Value {
    assert_eq!(result["isError"], serde_json::json!(false), "{tool}: {result:?}");
    assert_eq!(result["structuredContent"]["surface_version"], "v2", "{result:?}");
    assert_eq!(result["structuredContent"]["tool"], tool, "{result:?}");
    let data = &result["structuredContent"]["data"];
    assert!(data.is_object(), "{tool} must return typed data: {result:?}");
    data
}

/// Replaces the former v1 analytics happy paths with one public fixture.  The
/// checks are intentionally receipt-specific: an empty success, decoder-only
/// test, or old text renderer cannot satisfy them.
#[test]
fn selected_lens_analytics_execute_over_publicly_filed_drawers() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    for content in [
        "lens live alpha knowledge",
        "lens live beta knowledge",
        "lens live gamma knowledge",
    ] {
        file(&session, content);
    }

    let associations = session
        .call("moot_lens_associations", &args![])
        .expect("associations must dispatch");
    let associations = selected_data(&associations, "moot_lens_associations");
    assert!(associations["rules"].is_array(), "{associations:?}");
    assert!(associations["drawerCount"].as_u64().unwrap_or_default() >= 3, "{associations:?}");

    let concepts = session
        .call("moot_lens_concepts", &args!["limit" => 20])
        .expect("concepts must dispatch");
    let concepts = selected_data(&concepts, "moot_lens_concepts");
    assert!(concepts["concepts"].is_array(), "{concepts:?}");
    assert!(concepts["drawerCount"].as_u64().unwrap_or_default() >= 3, "{concepts:?}");
    assert!(concepts["coverDeltas"].is_array(), "{concepts:?}");

    let apriori = session
        .call("moot_lens_apriori", &args!["limit" => 20])
        .expect("apriori must dispatch");
    let apriori = selected_data(&apriori, "moot_lens_apriori");
    assert!(apriori["rules"].is_array(), "{apriori:?}");

    let complexity = session
        .call("moot_lens_complexity", &args!["fieldA" => "room"])
        .expect("complexity must dispatch");
    let complexity = selected_data(&complexity, "moot_lens_complexity");
    assert!(complexity["totalCount"].as_u64().unwrap_or_default() >= 3, "{complexity:?}");
    assert!(complexity["result"]["entropyA"].is_number(), "{complexity:?}");
}

/// The temporal and seeded-graph lenses retain their own required arguments.
/// Their public receipts prove those inputs reach the selected lower runner.
#[test]
fn selected_lens_temporal_and_seeded_operations_preserve_typed_receipts() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let seed = file(&session, "lens temporal seeded evidence");
    file(&session, "lens temporal companion evidence");

    let free_association = session
        .call(
            "moot_lens_free_association",
            &args!["wing" => "lens-live-room", "seed_memory_id" => seed, "k" => "8"],
        )
        .expect("free association must dispatch");
    let free_association = selected_data(&free_association, "moot_lens_free_association");
    assert!(free_association["associations"].is_array(), "{free_association:?}");

    let moment = session
        .call(
            "moot_lens_moment",
            &args![
                "windowStart" => "2025-01-01T00:00:00Z",
                "windowEnd" => "2027-12-31T23:59:59Z",
            ],
        )
        .expect("moment must dispatch");
    let moment = selected_data(&moment, "moot_lens_moment");
    assert!(moment["windowCount"].is_number(), "{moment:?}");
    assert!(moment["ranking"].is_array(), "{moment:?}");

    let precedence = session
        .call(
            "moot_lens_precedence",
            &args![
                "windowStart" => "2025-01-01T00:00:00Z",
                "windowEnd" => "2027-12-31T23:59:59Z",
                "targetField" => "room",
                "targetValue" => "string:lens-live-room",
            ],
        )
        .expect("precedence must dispatch");
    let precedence = selected_data(&precedence, "moot_lens_precedence");
    assert!(precedence["entryCount"].is_number(), "{precedence:?}");
    assert!(precedence["antecedents"].is_array(), "{precedence:?}");

    let rhythm = session
        .call(
            "moot_lens_rhythm",
            &args![
                "bit" => "0",
                "bucketSeconds" => "86400",
                "bucketCount" => "32",
                "endingAt" => "2027-12-31T23:59:59Z",
            ],
        )
        .expect("rhythm must dispatch");
    let rhythm = selected_data(&rhythm, "moot_lens_rhythm");
    assert_eq!(rhythm["bucketCount"], 32, "{rhythm:?}");
    assert!(rhythm["periods"].is_array(), "{rhythm:?}");
}

/// The selected door rejects malformed public lens arguments before a lower
/// runner can observe them.  This preserves the old range/window protections
/// without reintroducing their retired v1 argument spellings.
#[test]
fn selected_lens_rejects_invalid_ranges_and_limits() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    for (tool, arguments) in [
        (
            "moot_lens_associations",
            args!["limit" => -1],
        ),
        (
            "moot_lens_concepts",
            args!["limit" => -1],
        ),
    ] {
        assert!(
            session.call(tool, &arguments).is_err(),
            "{tool} malformed public arguments must be an invalid-params fault"
        );
    }

    for (tool, arguments) in [
        (
            "moot_lens_moment",
            args!["windowStart" => "2027-01-02T00:00:00Z", "windowEnd" => "2027-01-01T00:00:00Z"],
        ),
        (
            "moot_lens_precedence",
            args![
                "windowStart" => "2027-01-02T00:00:00Z",
                "windowEnd" => "2027-01-01T00:00:00Z",
                "targetField" => "room",
                "targetValue" => "string:lens-live-room",
            ],
        ),
    ] {
        let refusal = session
            .call(tool, &arguments)
            .expect("a semantic window rejection is an operational refusal");
        assert_eq!(refusal["isError"], serde_json::json!(true), "{tool}: {refusal:?}");
        assert_eq!(refusal["structuredContent"]["error"]["code"], "lens_unavailable", "{tool}: {refusal:?}");
    }
}

#[test]
fn selected_lens_unknown_estate_is_an_estate_unavailable_refusal() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let result = session.call(
        "moot_lens_keystones",
        &args![
            "wing" => "Agentic Memory",
            "estate_id" => "ffffffff-ffff-ffff-ffff-ffffffffffff",
        ],
    ).expect("unknown selected estate must render a public refusal");
    assert_eq!(result["isError"], serde_json::json!(true), "{result:?}");
    assert_eq!(result["structuredContent"]["error"]["code"], "estate_unavailable", "{result:?}");
}
