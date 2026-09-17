//! Public selected-v2 JSON-import durability contracts.

use std::{collections::BTreeMap, fs, path::PathBuf};

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};

#[path = "test_support.rs"]
mod test_support;

use test_support::SelectedV2Session;

fn args(entries: Vec<(&str, serde_json::Value)>) -> BTreeMap<String, JsonValue> {
    entries
        .into_iter()
        .map(|(key, value)| (key.to_owned(), JsonValue::from(value)))
        .collect()
}

fn temp_seed(name: &str, body: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "aria-v2-json-import-{name}-{}-{}.json",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    fs::write(&path, body).expect("test seed must be writable");
    path
}

#[test]
fn selected_json_import_rejects_a_malformed_seed_without_any_durable_write() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let before = session
        .coord
        .lock()
        .unwrap()
        .all_drawers(&session.default.handle)
        .expect("baseline drawer read must succeed");
    let path = temp_seed("invalid", "{ this is not valid JSON }");

    let result = session
        .call(
            "moot_json_import",
            &args(vec![("path", serde_json::json!(path.display().to_string()))]),
        )
        .expect("selected-v2 JSON import must render a tool envelope");
    fs::remove_file(&path).expect("test seed must be removable");

    assert_eq!(result["isError"], serde_json::json!(true), "{result:?}");
    let after = session
        .coord
        .lock()
        .unwrap()
        .all_drawers(&session.default.handle)
        .expect("post-refusal drawer read must succeed");
    assert_eq!(after.len(), before.len(), "a malformed selected-v2 import must write zero drawers");
}

#[test]
fn selected_json_import_persists_records_and_returns_the_opted_in_id_map() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let path = temp_seed("durable", r#"{
        "format_version": 1,
        "name": "selected-v2-durable",
        "records": [
            {"id":"source-a","content":"selected v2 JSON durable alpha","event_time":"2026-09-09T00:00:00Z","room":"handoff/room"},
            {"id":"source-b","content":"selected v2 JSON durable beta","event_time":"2026-09-09T00:01:00Z","room":"handoff/room"}
        ]
    }"#);

    let result = session.call(
        "moot_json_import",
        &args(vec![
            ("path", serde_json::json!(path.display().to_string())),
            ("return_id_map", serde_json::json!(true)),
        ]),
    ).expect("selected-v2 JSON import must render a receipt");
    fs::remove_file(&path).expect("test seed must be removable");

    assert_eq!(result["isError"], false, "valid import must succeed: {result}");
    let data = &result["structuredContent"]["data"];
    assert_eq!(data["drawers_written"], 2, "both seed records must be imported: {result}");
    let map = data["id_map"].as_object().expect("structured id map");
    assert_eq!(map.len(), 2);
    for source_id in ["source-a", "source-b"] {
        let drawer_id = map[source_id].as_str().expect("source record maps to drawer UUID");
        uuid::Uuid::parse_str(drawer_id).expect("mapped drawer id is canonical UUID");
    }
    assert_eq!(result["content"].as_array().map(Vec::len), Some(2),
        "return_id_map:true must append a text receipt block");

    let drawers = session.coord.lock().unwrap()
        .all_drawers(&session.default.handle).expect("durable drawer read");
    for content in ["selected v2 JSON durable alpha", "selected v2 JSON durable beta"] {
        assert!(drawers.iter().any(|drawer| drawer.content == content),
            "selected-v2 import must durably persist {content:?}");
    }
}

/// A record missing `event_time` is a decode failure of the caller's file: an
/// `invalid_argument` refusal carrying the bridge's message, which names the
/// record (ruling 2026-09-17). Nothing is written.
#[test]
fn selected_json_import_missing_event_time_is_an_invalid_argument_refusal() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let path = temp_seed("missing-event-time", r#"{
        "format_version": 1,
        "name": "missing-event-time",
        "records": [{"id":"r1","content":"no event time","room":"handoff/room"}]
    }"#);
    let result = session
        .call("moot_json_import", &args(vec![("path", serde_json::json!(path.display().to_string()))]))
        .expect("a seed decode failure is an operational refusal, not a transport fault");
    fs::remove_file(&path).expect("test seed must be removable");

    assert_eq!(result["isError"], serde_json::json!(true), "{result:?}");
    let error = &result["structuredContent"]["error"];
    assert_eq!(error["code"], "invalid_argument", "{result:?}");
    assert_eq!(error["retryable"], serde_json::json!(false), "{result:?}");
    let message = error["message"].as_str().expect("the refusal carries the bridge message");
    for fragment in ["record[0]", "\"r1\"", "event_time is missing"] {
        assert!(message.contains(fragment), "message must name the record and field; got: {message}");
    }
    let after = session.coord.lock().unwrap().all_drawers(&session.default.handle).expect("drawer read");
    assert!(after.is_empty(), "a refused import must write zero drawers");
}

/// A path that does not resolve stays the availability refusal: the no-oracle
/// rule for paths is unchanged by the decode-class ruling.
#[test]
fn selected_json_import_nonexistent_path_stays_mobility_unavailable() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let path = std::env::temp_dir().join(format!("aria-v2-json-import-absent-{}.json", uuid::Uuid::new_v4()));
    let result = session
        .call("moot_json_import", &args(vec![("path", serde_json::json!(path.display().to_string()))]))
        .expect("an absent seed is an operational refusal, not a transport fault");
    assert_eq!(result["isError"], serde_json::json!(true), "{result:?}");
    let error = &result["structuredContent"]["error"];
    assert_eq!(error["code"], "mobility_unavailable", "{result:?}");
    assert_eq!(error["message"], "The requested data-mobility operation is unavailable in the selected estate.", "{result:?}");
}
