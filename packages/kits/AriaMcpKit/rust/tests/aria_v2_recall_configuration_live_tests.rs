//! Public selected-v2 coverage for the precise composition and shaped-preset
//! selectors. These are behavioral contracts, not legacy recipe render tests.

use std::collections::BTreeMap;

mod test_support;

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::{JSONRPCErrorCode, JsonValue}};
use test_support::SelectedV2Session;

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),* $(,)? ) => {{
        let mut values = BTreeMap::new();
        $( values.insert($k.to_owned(), JsonValue::from(serde_json::json!($v))); )*
        values
    }};
}

fn file_memory(session: &SelectedV2Session) {
    let response = session.call(
        "moot_file_memory",
        &args![
            "content" => "Versailles indemnity was forty-six million marks.",
            "location" => "history/versailles",
            "subject" => "Versailles indemnity",
        ],
    ).expect("public v2 filing must succeed");
    assert_ne!(response["isError"], serde_json::json!(true), "{response:?}");
}

fn assert_success_with_results(response: serde_json::Value, tool: &str) {
    assert_ne!(response["isError"], serde_json::json!(true), "{tool}: {response:?}");
    assert!(response["structuredContent"]["data"]["results"].is_array(), "{tool}: {response:?}");
}

#[test]
fn selected_precise_recall_enforces_composition_and_query_contract() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    file_memory(&session);

    assert_success_with_results(
        session.call("moot_recall_precise", &args!["query" => "Versailles indemnity"])
            .expect("default precise recall must dispatch"),
        "default precise",
    );
    assert_success_with_results(
        session.call(
            "moot_recall_precise",
            &args!["query" => "Versailles indemnity", "composition" => "hamming+text"],
        ).expect("known composition must dispatch"),
        "known composition",
    );

    let unknown = session.call(
        "moot_recall_precise",
        &args!["query" => "Versailles indemnity", "composition" => "no-such-composition"],
    ).expect_err("unknown composition must fail closed");
    assert_eq!(unknown.code, JSONRPCErrorCode::INVALID_PARAMS);

    let missing = session.call("moot_recall_precise", &args![])
        .expect_err("precise recall requires a query");
    assert_eq!(missing.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn selected_shaped_recall_enforces_preset_default_roster_and_query_contract() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    file_memory(&session);

    assert_success_with_results(
        session.call("moot_recall_shaped", &args!["query" => "Versailles indemnity"])
            .expect("omitted preset must use balanced"),
        "default shaped preset",
    );
    assert_success_with_results(
        session.call(
            "moot_recall_shaped",
            &args!["query" => "Versailles indemnity", "preset" => "structural"],
        ).expect("known preset must dispatch"),
        "known shaped preset",
    );

    for preset in genius_locus_kit::recall::RecallShape::PRESET_NAMES {
        assert_success_with_results(
            session.call(
                "moot_recall_shaped",
                &args!["query" => "Versailles indemnity", "preset" => preset],
            ).unwrap_or_else(|error| panic!("{preset} must dispatch: {error:?}")),
            preset,
        );
    }

    let unknown = session.call(
        "moot_recall_shaped",
        &args!["query" => "Versailles indemnity", "preset" => "no-such-preset"],
    ).expect_err("unknown preset must fail closed");
    assert_eq!(unknown.code, JSONRPCErrorCode::INVALID_PARAMS);

    let missing = session.call("moot_recall_shaped", &args![])
        .expect_err("shaped recall requires a query");
    assert_eq!(missing.code, JSONRPCErrorCode::INVALID_PARAMS);
}
