//! Dataset path-security coverage through the selected-v2 public dispatcher.

use std::{collections::BTreeMap, fs, path::PathBuf};

mod test_support;

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};
use test_support::SelectedV2Session;

macro_rules! args {
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut values = BTreeMap::new();
        $( values.insert($k.to_owned(), JsonValue::from(serde_json::json!($v))); )+
        values
    }};
}

struct Remove(PathBuf);
impl Drop for Remove {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0).or_else(|_| fs::remove_file(&self.0)); }
}

fn call_csv(session: &SelectedV2Session, path: &str) -> serde_json::Value {
    session.call("moot_file_dataset", &args![
        "name" => "path-security",
        "location" => "lab/path-security",
        "csv_path" => path,
    ]).expect("selected-v2 file_dataset must return an envelope")
}

#[test]
fn selected_dataset_refuses_a_real_file_outside_the_import_root() {
    let csv = std::path::Path::new("/etc/hosts");
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let before = session.coord.lock().unwrap().all_drawers(&session.default.handle)
        .expect("baseline drawers").len();

    let result = call_csv(&session, csv.to_str().unwrap());
    assert_eq!(result["isError"], serde_json::json!(true),
        "outside-root file must be refused by the public v2 door: {result:?}");
    assert_eq!(result["structuredContent"]["error"]["code"], "mobility_unavailable",
        "outside-root refusal must use the selected-v2 mobility error: {result:?}");
    let after = session.coord.lock().unwrap().all_drawers(&session.default.handle)
        .expect("post-refusal drawers").len();
    assert_eq!(after, before,
        "outside-root file refusal must create zero dataset-handle writes: {result:?}");
}

#[test]
fn selected_dataset_discloses_only_the_csv_basename() {
    let root = PathBuf::from("/Users/bob/devlop/builds/mootx01-ee/unit1-bilby4/home");
    fs::create_dir_all(&root).expect("authorized test scratch root");
    let folder = root.join(format!("aria-v2-basename-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&folder).unwrap();
    let _remove = Remove(folder.clone());
    let csv = folder.join("fruits.csv");
    fs::write(&csv, b"name,score\napple,1\nbanana,2\n").unwrap();
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let result = call_csv(&session, csv.to_str().unwrap());
    assert_eq!(result["isError"], serde_json::json!(false), "valid in-root CSV must file: {result:?}");
    let source = result["structuredContent"]["data"]["source"].as_str().unwrap();
    assert_eq!(source, "csv:fruits.csv");
    assert!(!result.to_string().contains(csv.to_str().unwrap()),
        "the public result must not disclose the canonical filesystem path: {result:?}");
}

fn file_inline_fruit_dataset(session: &SelectedV2Session) -> serde_json::Value {
    session.call("moot_file_dataset", &args![
        "name" => "selected-fruit-scores",
        "location" => "selected/dataset-tests",
        "columns" => serde_json::json!([
            {"name":"label", "type":"text"},
            {"name":"score", "type":"int"}
        ]),
        "rows" => serde_json::json!([
            {"label":"apple", "score":95},
            {"label":"banana", "score":80},
            {"label":"cherry", "score":72}
        ])
    ]).expect("selected dataset filing must render a receipt")
}

#[test]
fn selected_dataset_files_queries_stats_and_refuses_a_withdrawn_handle() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let filed = file_inline_fruit_dataset(&session);
    assert_eq!(filed["isError"], false, "dataset filing must succeed: {filed}");
    let data = &filed["structuredContent"]["data"];
    let dataset_id = data["dataset_id"].as_str().expect("dataset id");
    let handle_id = data["handle_memory_id"].as_str().expect("dataset handle id");
    assert_eq!(data["rows"], 3);

    let query = session.call("moot_dataset_query", &args![
        "dataset_id" => dataset_id,
        "where" => serde_json::json!({"col":"score", "op":"gte", "val":80}),
        "order_by" => serde_json::json!([{"col":"score", "dir":"desc"}])
    ]).expect("selected query must render a receipt");
    assert_eq!(query["isError"], false, "dataset query must succeed: {query}");
    assert_eq!(query["structuredContent"]["data"]["rows_returned"], 2);
    assert_eq!(query["structuredContent"]["data"]["rows"][0]["label"], "apple");

    let stats = session.call("moot_dataset_stats", &args!["dataset_id" => dataset_id])
        .expect("selected stats must render a receipt");
    assert_eq!(stats["isError"], false, "dataset stats must succeed: {stats}");
    assert_eq!(stats["structuredContent"]["data"]["stats"]["score"]["count"], 3);

    let withdrawn = session.call("moot_withdraw_memory", &args!["memory_id" => handle_id])
        .expect("selected withdraw must render a receipt");
    assert_eq!(withdrawn["isError"], false, "dataset handle withdraw must succeed: {withdrawn}");
    for tool in ["moot_dataset_query", "moot_dataset_stats"] {
        let refused = session.call(tool, &args!["dataset_id" => dataset_id])
            .expect("withdrawn dataset must render a v2 tool refusal");
        assert_eq!(refused["isError"], true, "withdrawn dataset {tool} must refuse: {refused}");
    }
}

#[test]
fn selected_dataset_rejects_invalid_schema_predicates_and_csv_inputs_without_writes() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let before = session.coord.lock().unwrap().all_drawers(&session.default.handle)
        .expect("baseline drawers").len();
    for column in ["name; DROP TABLE x --", "1bad", "bad-col"] {
        let refused = session.call("moot_file_dataset", &args![
            "name" => "invalid-selected-dataset",
            "location" => "selected/dataset-tests",
            "columns" => serde_json::json!([{"name":column, "type":"text"}]),
            "rows" => serde_json::json!([{"value":"value"}])
        ]).expect("validation refusal must render a tool envelope");
        assert_eq!(refused["isError"], true, "invalid column {column:?} must refuse: {refused}");
    }
    for csv_path in [std::env::temp_dir().display().to_string(),
        std::env::temp_dir().join(format!("missing-selected-{}.csv", uuid::Uuid::new_v4())).display().to_string()] {
        let refused = session.call("moot_file_dataset", &args![
            "name" => "invalid-selected-csv", "location" => "selected/dataset-tests", "csv_path" => csv_path
        ]).expect("csv refusal must render a tool envelope");
        assert_eq!(refused["isError"], true, "directory or missing CSV must refuse: {refused}");
    }
    let after = session.coord.lock().unwrap().all_drawers(&session.default.handle)
        .expect("post-refusal drawers").len();
    assert_eq!(after, before, "refused selected dataset calls must not create handles");

    let filed = file_inline_fruit_dataset(&session);
    let dataset_id = filed["structuredContent"]["data"]["dataset_id"].as_str().expect("dataset id");
    for invalid_arguments in [
        args!["dataset_id" => dataset_id, "where" => serde_json::json!({"col":"score; DROP TABLE x", "op":"eq", "val":1})],
        args!["dataset_id" => dataset_id, "order_by" => serde_json::json!([{"col":"score; DROP TABLE x", "dir":"asc"}])],
    ] {
        let refused = session.call("moot_dataset_query", &invalid_arguments)
            .expect("invalid selected predicate must render a tool envelope");
        assert_eq!(refused["isError"], true, "invalid selected predicate must refuse: {refused}");
    }
}
