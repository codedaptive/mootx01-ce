//! Durable reconcile coverage through the selected-v2 public dispatcher.
//!
//! The vault and manifest are test fixtures. Every operation under test enters
//! through `moot_vault_reconcile`, whose live path is the selected catalog,
//! `v2::data_mobility_lower`, and `vault_reconcile_snapshot`.

use std::{collections::{BTreeMap, HashSet}, fs, path::{Path, PathBuf}, time::{SystemTime, UNIX_EPOCH}};

mod test_support;

use aria_mcp::{
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCErrorCode, JsonValue},
    vault_tools::{build_manifest, read_manifest, write_manifest, ExportManifest},
};
use test_support::SelectedV2Session;

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut values = BTreeMap::new();
        $( values.insert($k.to_owned(), JsonValue::from(serde_json::json!($v))); )+
        values
    }};
}

fn vault() -> PathBuf {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let path = std::env::temp_dir().join(format!("aria-v2-reconcile-{nonce}"));
    fs::create_dir_all(&path).unwrap();
    path
}

fn write_note(vault: &Path, path: &str, body: &str) {
    let target = vault.join(path);
    if let Some(parent) = target.parent() { fs::create_dir_all(parent).unwrap(); }
    fs::write(target, format!("# {path}\n\n{body}\n")).unwrap();
}

fn certified_manifest(vault: &Path, paths: &[&str]) -> ExportManifest {
    let paths = paths.iter().map(|path| (*path).to_owned()).collect::<Vec<_>>();
    let manifest = build_manifest(vault, &paths, 0).unwrap();
    write_manifest(&manifest, vault).unwrap();
    manifest
}

fn empty_certified_manifest(vault: &Path) {
    write_manifest(&ExportManifest {
        version: Some(aria_mcp::vault_tools::MANIFEST_SCHEMA_VERSION),
        exported_at: "1970-01-01T00:00:00Z".to_owned(),
        note_count: 0,
        files: BTreeMap::new(),
    }, vault).unwrap();
}

fn reconcile(session: &SelectedV2Session, vault: &Path, apply: bool) -> serde_json::Value {
    session.call("moot_vault_reconcile", &args![
        "vaultPath" => vault.to_str().unwrap(),
        "apply" => apply,
    ]).expect("selected-v2 vault reconcile must return an envelope")
}

fn reconcile_default(session: &SelectedV2Session, vault: &Path) -> serde_json::Value {
    session.call("moot_vault_reconcile", &args![
        "vaultPath" => vault.to_str().unwrap(),
    ]).expect("selected-v2 vault reconcile must return an envelope")
}

fn data(result: &serde_json::Value) -> &serde_json::Value {
    assert_eq!(result["isError"], serde_json::json!(false), "reconcile must succeed: {result:?}");
    &result["structuredContent"]["data"]
}

fn paths(result: &serde_json::Value, field: &str) -> HashSet<String> {
    data(result)[field].as_array().unwrap().iter()
        .map(|path| path.as_str().unwrap().to_owned()).collect()
}

fn only(path: &str) -> HashSet<String> {
    HashSet::from([path.to_owned()])
}

fn drawer_contents(session: &SelectedV2Session) -> Vec<String> {
    let coord = session.coord.lock().unwrap();
    coord.all_drawers(&session.default.handle).unwrap().into_iter().map(|drawer| drawer.content).collect()
}

fn file_memory(session: &SelectedV2Session, content: &str) {
    let result = session.call("moot_file_memory", &args![
        "content" => content,
        "subject" => "vault lifecycle receipt",
        "location" => "vault/lifecycle",
    ]).expect("selected-v2 filing must succeed");
    assert_eq!(result["isError"], serde_json::json!(false), "{result:?}");
}

#[test]
fn selected_vault_status_reports_an_empty_unstamped_vault() {
    let vault = vault();
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let result = session.call("moot_vault_status", &args!["vaultPath" => vault.to_str().unwrap()])
        .expect("selected-v2 vault status must return an envelope");
    assert_eq!(result["isError"], serde_json::json!(false), "{result:?}");
    assert_eq!(result["structuredContent"]["data"]["manifest_present"], serde_json::json!(false));
    assert!(result["structuredContent"]["data"]["note_count"].is_null(),
        "an unstamped vault has no note count: {result:?}");
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn selected_vault_reconcile_without_manifest_returns_error_result() {
    let vault = vault();
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let result = reconcile(&session, &vault, false);
    assert_eq!(result["isError"], serde_json::json!(true), "{result:?}");
    assert_eq!(result["structuredContent"]["error"]["code"], "mobility_unavailable", "{result:?}");
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn selected_vault_reconcile_missing_vault_path_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let error = session.call("moot_vault_reconcile", &args!())
        .expect_err("omitted vaultPath must be invalid params");
    assert_eq!(error.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn reconcile_omitted_apply_is_a_dry_run_with_no_estate_write() {
    let vault = vault();
    empty_certified_manifest(&vault);
    write_note(&vault, "DryRun.md", "default apply must not import this note");
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let result = reconcile_default(&session, &vault);
    assert_eq!(data(&result)["applied"], serde_json::json!(false));
    assert_eq!(paths(&result, "added"), only("DryRun.md"));
    assert_eq!(data(&result)["import_set_count"], serde_json::json!(1));
    assert!(!drawer_contents(&session).iter().any(|content| content.contains("default apply must not import this note")));
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn reconcile_rejects_a_malformed_selected_estate_before_vault_io() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let malformed = session.call(
        "moot_vault_reconcile",
        &args!["vaultPath" => "/does/not/matter", "estate_id" => "not-a-uuid"],
    ).expect_err("a malformed estate selector must be invalid params before vault access");
    assert_eq!(malformed.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn selected_vault_export_import_jobs_keep_terminal_and_skip_receipts() {
    let vault = vault();
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    file_memory(&session, "vault export must create a durable terminal receipt");

    let exported = session.call("moot_vault_export", &args![
        "vaultPath" => vault.to_str().unwrap(),
        "scope" => "believed",
    ]).expect("selected-v2 vault export must dispatch");
    assert_eq!(exported["isError"], serde_json::json!(false), "{exported:?}");
    let export_job_id = exported["structuredContent"]["data"]["job_id"].as_str()
        .expect("export must return its job id").to_owned();
    let export_job = session.call("moot_vault_job", &args!["job_id" => export_job_id])
        .expect("selected-v2 export job must dispatch");
    let export_data = &export_job["structuredContent"]["data"];
    assert_eq!(export_data["kind"], serde_json::json!("export"));
    assert_eq!(export_data["status"], serde_json::json!("complete"));
    assert!(export_data["export"]["note_count"].as_u64().is_some(), "{export_job:?}");

    let imported = session.call("moot_vault_import", &args![
        "vaultPath" => vault.to_str().unwrap(),
        "mode" => "foreground",
    ]).expect("selected-v2 vault import must dispatch");
    assert_eq!(imported["isError"], serde_json::json!(false), "{imported:?}");
    let import_job_id = imported["structuredContent"]["data"]["job_id"].as_str()
        .expect("import must return its job id").to_owned();
    let import_job = session.call("moot_vault_job", &args!["job_id" => import_job_id])
        .expect("selected-v2 import job must dispatch");
    let import_data = &import_job["structuredContent"]["data"];
    assert_eq!(import_data["kind"], serde_json::json!("import"));
    assert_eq!(import_data["status"], serde_json::json!("complete"));
    assert!(import_data["import"]["drawers_skipped_unchanged"].as_u64().is_some(),
        "the terminal import receipt must expose unchanged skips: {import_job:?}");
    assert!(import_data["import"]["drawers_skipped_tombstoned"].as_u64().is_some(),
        "the terminal import receipt must expose tombstoned skips: {import_job:?}");
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn reconcile_apply_never_expunges_after_an_exported_file_is_deleted() {
    let vault = vault();
    write_note(&vault, "Deleted.md", "this file disappears but estate state survives");
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    empty_certified_manifest(&vault);
    let imported = reconcile(&session, &vault, true);
    assert_eq!(paths(&imported, "added"), only("Deleted.md"));
    assert!(drawer_contents(&session).iter().any(|content|
        content.contains("this file disappears but estate state survives")),
        "the initial selected-v2 import must create the real drawer that deletion must not expunge");

    fs::remove_file(vault.join("Deleted.md")).unwrap();
    let result = reconcile(&session, &vault, true);
    assert_eq!(paths(&result, "deleted"), only("Deleted.md"));
    assert!(drawer_contents(&session).iter().any(|content|
        content.contains("this file disappears but estate state survives")),
        "a deleted exported path must never expunge its already-imported drawer");
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn reconcile_cross_estate_imports_only_the_surfaced_missing_set_and_converges() {
    let vault = vault();
    write_note(&vault, "Shared.md", "cross estate import payload");
    let source_manifest = certified_manifest(&vault, &["Shared.md"]);

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let dry = reconcile(&session, &vault, false);
    assert_eq!(paths(&dry, "added"), HashSet::new());
    assert_eq!(paths(&dry, "modified"), HashSet::new());
    assert_eq!(paths(&dry, "deleted"), HashSet::new());
    assert_eq!(paths(&dry, "missing"), only("Shared.md"));
    assert_eq!(data(&dry)["candidate_count"], serde_json::json!(0));
    assert_eq!(data(&dry)["import_set_count"], serde_json::json!(1));
    assert_eq!(data(&dry)["missing_count"], serde_json::json!(1));
    assert_eq!(data(&dry)["candidates"], serde_json::json!([]));

    let applied = reconcile(&session, &vault, true);
    assert_eq!(data(&applied)["applied"], serde_json::json!(true));
    assert_eq!(paths(&applied, "added"), HashSet::new());
    assert_eq!(paths(&applied, "modified"), HashSet::new());
    assert_eq!(paths(&applied, "deleted"), HashSet::new());
    assert_eq!(paths(&applied, "missing"), only("Shared.md"));
    assert_eq!(data(&applied)["candidate_count"], serde_json::json!(0));
    assert_eq!(data(&applied)["import_set_count"], serde_json::json!(1));
    assert_eq!(data(&applied)["missing_count"], serde_json::json!(1));
    assert!(drawer_contents(&session).iter().any(|content| content.contains("cross estate import payload")));
    let restamped = read_manifest(&vault).unwrap().unwrap();
    assert_eq!(restamped.files["Shared.md"].sha256, source_manifest.files["Shared.md"].sha256,
        "apply must re-stamp the imported path with the current vault hash");

    let converged = reconcile(&session, &vault, false);
    assert_eq!(paths(&converged, "added"), HashSet::new());
    assert_eq!(paths(&converged, "modified"), HashSet::new());
    assert_eq!(paths(&converged, "deleted"), HashSet::new());
    assert_eq!(paths(&converged, "missing"), HashSet::new());
    assert_eq!(data(&converged)["candidate_count"], serde_json::json!(0));
    assert_eq!(data(&converged)["missing_count"], serde_json::json!(0));
    assert_eq!(data(&converged)["import_set_count"], serde_json::json!(0));
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn reconcile_apply_ingests_a_fresh_foreign_note() {
    let vault = vault();
    empty_certified_manifest(&vault);
    write_note(&vault, "Foreign.md", "foreign vault note must be ingested");
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let applied = reconcile(&session, &vault, true);
    assert!(paths(&applied, "added").contains("Foreign.md"));
    assert!(drawer_contents(&session).iter().any(|content| content.contains("foreign vault note")));
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn reconcile_apply_imports_the_modified_note_only() {
    let vault = vault();
    write_note(&vault, "Changed.md", "original changed note");
    write_note(&vault, "Unchanged.md", "unchanged control note");
    empty_certified_manifest(&vault);
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let seeded = reconcile(&session, &vault, true);
    assert_eq!(paths(&seeded, "added"), HashSet::from([
        "Changed.md".to_owned(), "Unchanged.md".to_owned(),
    ]));
    assert!(drawer_contents(&session).iter().any(|content| content.contains("unchanged control note")));

    fs::write(vault.join("Changed.md"), "# Changed\n\nmodified-only payload\n").unwrap();
    let dry = reconcile(&session, &vault, false);
    assert_eq!(paths(&dry, "modified"), only("Changed.md"));
    assert_eq!(paths(&dry, "added"), HashSet::new());
    assert_eq!(paths(&dry, "deleted"), HashSet::new());
    assert_eq!(data(&dry)["candidate_count"], serde_json::json!(1));
    assert_eq!(data(&dry)["import_set_count"], serde_json::json!(1));
    let applied = reconcile(&session, &vault, true);
    assert_eq!(paths(&applied, "modified"), only("Changed.md"));
    assert_eq!(data(&applied)["candidate_count"], serde_json::json!(1));
    assert_eq!(data(&applied)["import_set_count"], serde_json::json!(1));
    assert!(drawer_contents(&session).iter().any(|content| content.contains("modified-only payload")));
    assert_eq!(drawer_contents(&session).iter().filter(|content|
        content.contains("unchanged control note")).count(), 1,
        "the unchanged imported drawer must remain exactly once and unchanged");
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn legacy_manifest_surfaces_notes_for_review() {
    let vault = vault();
    write_note(&vault, "Legacy.md", "legacy manifest note");
    let mut legacy = build_manifest(&vault, &["Legacy.md".to_owned()], 0).unwrap();
    legacy.version = None;
    write_manifest(&legacy, &vault).unwrap();
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let dry = reconcile(&session, &vault, false);
    assert_eq!(data(&dry)["candidate_count"], serde_json::json!(1));
    assert!(data(&dry)["candidates"].as_array().unwrap().iter().any(|candidate|
        candidate["vault_path"] == serde_json::json!("Legacy.md")));
    fs::remove_dir_all(vault).unwrap();
}

#[test]
fn missing_manifest_hash_is_classified_as_added() {
    let vault = vault();
    empty_certified_manifest(&vault);
    write_note(&vault, "Unstamped.md", "this note has no manifest hash");
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let dry = reconcile(&session, &vault, false);
    assert!(paths(&dry, "added").contains("Unstamped.md"));
    assert_eq!(data(&dry)["candidate_count"], serde_json::json!(1));
    fs::remove_dir_all(vault).unwrap();
}
