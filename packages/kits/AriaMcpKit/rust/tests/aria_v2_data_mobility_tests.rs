
use std::{collections::BTreeMap, sync::Mutex};

use aria_mcp::v2::data_mobility::*;
use genius_locus_kit::EstateHandle;
use aria_mcp::jsonrpc::JsonValue;
use uuid::Uuid;

const ESTATE: &str = "11111111-1111-4111-8111-111111111111";
const DATASET: &str = "22222222-2222-4222-8222-222222222222";
const JOB: &str = "33333333-3333-4333-8333-333333333333";

fn uuid(value: &str) -> Uuid { Uuid::parse_str(value).unwrap() }
fn arguments(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(entries.into_iter().map(|(key, value)| (key.to_owned(), value)).collect::<BTreeMap<_, _>>())
}

#[derive(Default)]
struct Authority { calls: Mutex<Vec<V2DataMobilityOperation>>, fail_revalidate: bool }
impl V2DataMobilityAuthority for Authority {
    fn admit(&self, operation: V2DataMobilityOperation, requested: Option<Uuid>) -> Result<V2DataMobilityAdmission, ()> {
        assert!(requested.is_none() || requested == Some(uuid(ESTATE)));
        self.calls.lock().unwrap().push(operation);
        Ok(V2DataMobilityAdmission {
            estate_id: uuid(ESTATE), estate_handle: EstateHandle::new([7; 16], 0, 0).unwrap(),
            caller_binding: "selected-caller".to_owned(), authorization_generation: "generation-1".to_owned(), now_millis: 100,
        })
    }
    fn revalidate(&self, _: &V2DataMobilityAdmission) -> Result<(), ()> { if self.fail_revalidate { Err(()) } else { Ok(()) } }
}

struct Lower { deny_job: bool }
impl Lower { fn new() -> Self { Self { deny_job: false } } }
impl V2DataMobilityLower for Lower {
    fn reindex(&self, _: &V2DataMobilityAdmission, _: &V2ReindexRequest) -> Result<V2ReindexState, ()> { Ok(V2ReindexState::Running) }
    fn reclassify_fdc(&self, _: &V2DataMobilityAdmission, _: &V2ReclassifyFdcRequest) -> Result<V2ReclassifyFdcReport, ()> { Ok(V2ReclassifyFdcReport { applied: false, mode: "suspectOnly".to_owned(), estate_id: uuid(ESTATE), estate_name: "test-estate".to_owned(), fdc_data_version: "v1".to_owned(), fdc_recalculation_version: "r1".to_owned(), limit: None, scanned: 1, unchanged: 1, empty_content: 0, candidates: 0, updated: 0, would_update: 0, unclassified_after: 0, skipped_non_candidate_changes: 0, floor_stamp: "dry-run".to_owned(), estate_recalced_data_version_before: None, estate_recalced_data_version_after: None, changes: vec![], changes_omitted: 0 }) }
    fn palace_import(&self, _: &V2DataMobilityAdmission, _: &V2PalaceImportRequest) -> Result<V2PalaceImportReport, ()> { Ok(V2PalaceImportReport { drawers_written: 0, drawers_updated: 0, drawers_skipped_unchanged: 0, drawers_skipped_tombstoned: 0, drawers_skipped_partial_write: 0, tunnels_created: 0, items_skipped: 0, fdc_classified: 0, fdc_unclassified: 0, fields_dropped: BTreeMap::new(), enqueued_for_encode: 0 }) }
    fn json_import(&self, _: &V2DataMobilityAdmission, _: &V2JsonImportRequest) -> Result<V2JsonImportReport, ()> { Ok(V2JsonImportReport { seed_name: "seed".to_owned(), drawers_written: 0, facts_written: 0, tunnels_created: 0, enqueued_for_encode: 0, subjects_provided: 0, subjects_debt: 0, seed_sha256: "0".repeat(64), id_map: None }) }
    fn file_dataset(&self, _: &V2DataMobilityAdmission, _: &V2FileDatasetRequest) -> Result<V2DatasetFiled, ()> { Ok(V2DatasetFiled { dataset_id: uuid(DATASET), handle_memory_id: uuid(DATASET), name: "dataset".to_owned(), location: "room".to_owned(), wing: None, columns: 0, rows: 0, source: "inline_rows".to_owned(), sensitivity: "normal".to_owned(), signatures: "unavailable".to_owned() }) }
    fn dataset_query(&self, _: &V2DataMobilityAdmission, _: &V2DatasetQueryRequest) -> Result<V2DatasetQueryResult, ()> { Ok(V2DatasetQueryResult { dataset_id: uuid(DATASET), handle_memory_id: uuid(DATASET), state: "active".to_owned(), sensitivity: "normal".to_owned(), rows_returned: 0, limit: 1, rows: vec![], columns: None, handle_row_count: None }) }
    fn dataset_stats(&self, _: &V2DataMobilityAdmission, _: &V2DatasetStatsRequest) -> Result<V2DatasetStatsResult, ()> { Ok(V2DatasetStatsResult { dataset_id: uuid(DATASET), handle_memory_id: uuid(DATASET), stats: BTreeMap::new() }) }
    fn vault_export(&self, _: &V2DataMobilityAdmission, _: &V2VaultExportRequest) -> Result<V2VaultExportResult, ()> { Ok(V2VaultExportResult { job_id: uuid(JOB), vault: "vault".to_owned(), scope: "exportable".to_owned(), datasets_exported: None, warnings: None }) }
    fn vault_import(&self, _: &V2DataMobilityAdmission, _: &V2VaultImportRequest) -> Result<V2VaultImportResult, ()> { Ok(V2VaultImportResult { job_id: uuid(JOB), vault: "vault".to_owned(), note_count: 0, status: "complete".to_owned(), drawers_written: None, drawers_updated: None, items_skipped: None, tunnels_created: None, fdc_classified: None, fdc_unclassified: None, datasets_imported: None, warnings: None }) }
    fn vault_status(&self, _: &V2DataMobilityAdmission, _: &V2VaultStatusRequest) -> Result<V2VaultStatusResult, ()> { Ok(V2VaultStatusResult { manifest_present: false, path: "vault".to_owned(), last_export: None, note_count: None }) }
    fn vault_reconcile(&self, _: &V2DataMobilityAdmission, _: &V2VaultReconcileRequest) -> Result<V2VaultReconcileResult, ()> { Ok(V2VaultReconcileResult { added: vec![], modified: vec![], deleted: vec![], missing: vec![], import_set_count: 0, candidate_count: 0, missing_count: 0, applied: false, candidates: None }) }
    fn vault_job(&self, _: &V2DataMobilityAdmission, _: &V2VaultJobRequest) -> Result<V2VaultJobResult, ()> { if self.deny_job { Err(()) } else { Ok(V2VaultJobResult { job_id: uuid(JOB), kind: "export".to_owned(), vault: "vault".to_owned(), status: "complete".to_owned(), elapsed_millis: 0, terminal: Some(V2VaultJobTerminal::Exported { note_count: 3, exported_at: "2026-09-08T00:00:00Z".to_owned() }) }) } }
}

#[test]
fn frozen_mission02_requests_are_strict_and_preserve_argument_spelling() {
    let palace = V2PalaceImportRequest::decode(&arguments([
        ("palace_path", JsonValue::String("/tmp/palace".to_owned())),
        ("mode", JsonValue::String("background".to_owned())),
        ("estate_id", JsonValue::String(ESTATE.to_owned())),
    ])).unwrap();
    assert_eq!(palace.mode, Some(V2ImportMode::Background));

    let dataset = V2FileDatasetRequest::decode(&arguments([
        ("name", JsonValue::String("events".to_owned())), ("location", JsonValue::String("lab".to_owned())),
        ("columns", JsonValue::Array(vec![])), ("rows", JsonValue::Array(vec![])),
        ("sensitivity", JsonValue::String("restricted".to_owned())),
    ])).unwrap();
    assert_eq!(dataset.sensitivity, Some(V2DatasetSensitivity::Restricted));
    for invalid in [
        arguments([
            ("name", JsonValue::String("events".to_owned())),
            ("location", JsonValue::String("lab".to_owned())),
        ]),
        arguments([
            ("name", JsonValue::String("events".to_owned())),
            ("location", JsonValue::String("lab".to_owned())),
            ("rows", JsonValue::Array(vec![])),
            ("csv_path", JsonValue::String("/tmp/events.csv".to_owned())),
        ]),
    ] {
        assert_eq!(V2FileDatasetRequest::decode(&invalid).unwrap_err().path, "$");
    }

    let invalid_limit = V2DatasetQueryRequest::decode(&arguments([
        ("dataset_id", JsonValue::String(DATASET.to_owned())), ("limit", JsonValue::Integer(0)),
    ])).unwrap_err();
    assert_eq!(invalid_limit.path, "$.limit");

    let unknown = V2VaultStatusRequest::decode(&arguments([
        ("vaultPath", JsonValue::String("/tmp/vault".to_owned())), ("estate_id", JsonValue::String(ESTATE.to_owned())),
    ])).unwrap_err();
    assert_eq!(unknown.path, "$.estate_id");

    let job = V2VaultJobRequest::decode(&arguments([("job_id", JsonValue::String(JOB.to_uppercase()))])).unwrap();
    assert_eq!(job.job_id, uuid(JOB));
}

#[test]
fn dataset_predicates_and_ordering_enforce_the_bounded_v2_grammar() {
    fn nested(depth: usize) -> JsonValue {
        if depth == 1 {
            serde_json::json!({"col":"count","op":"gte","val":1}).into()
        } else {
            serde_json::json!({"and":[serde_json::to_value(nested(depth - 1)).unwrap()]}).into()
        }
    }
    fn request(predicate: JsonValue) -> JsonValue {
        arguments([
            ("dataset_id", JsonValue::String(DATASET.to_owned())),
            ("where", predicate),
        ])
    }

    let mut valid = request(nested(8));
    if let JsonValue::Object(arguments) = &mut valid {
        arguments.insert(
            "order_by".to_owned(),
            serde_json::json!([{"col":"count","dir":"desc"}]).into(),
        );
    }
    V2DatasetQueryRequest::decode(&valid).unwrap();
    V2DatasetQueryRequest::decode(&request(
        serde_json::json!({"col":"active","op":"eq","val":true}).into(),
    )).unwrap();

    let invalid = [
        serde_json::json!({"col":"count","op":"eq","val":null}).into(),
        serde_json::json!({"col":"active","op":"gt","val":true}).into(),
        serde_json::json!({"col":"count","op":"is_null","val":1}).into(),
        serde_json::json!({"and":[]}).into(),
        serde_json::json!({"and":[{"col":"x","op":"eq","val":1}],"or":[{"col":"x","op":"eq","val":1}]}).into(),
        nested(9),
        JsonValue::Object(BTreeMap::from([(
            "and".to_owned(),
            JsonValue::Array((0..128).map(|_| nested(1)).collect()),
        )])),
    ];
    for predicate in invalid {
        assert!(V2DatasetQueryRequest::decode(&request(predicate)).is_err());
    }

    assert!(V2DatasetQueryRequest::decode(&arguments([
        ("dataset_id", JsonValue::String(DATASET.to_owned())),
        ("order_by", serde_json::json!([{"col":"count","dir":"ascending"}]).into()),
    ])).is_err());
    assert!(V2DatasetQueryRequest::decode(&arguments([
        ("dataset_id", JsonValue::String(DATASET.to_owned())),
        ("limit", JsonValue::Integer(1_001)),
        ("columns", JsonValue::Array(vec![JsonValue::Integer(1)])),
    ])).is_err());
}

#[test]
fn typed_service_uses_stable_identity_and_revalidates_before_release() {
    let service = V2DataMobilityService::new(Authority::default(), Lower::new());
    let result = service.reindex(V2ReindexRequest { estate_id: Some(uuid(ESTATE)) }).unwrap();
    assert_eq!(result, V2DataMobilityResult::Reindex(V2ReindexState::Running));
    assert_eq!(V2DataMobilityOperation::Reindex.tool_name(), REINDEX_TOOL);

    let failed = V2DataMobilityService::new(Authority { fail_revalidate: true, ..Authority::default() }, Lower::new())
        .vault_export(V2VaultExportRequest { vault_path: "/tmp/vault".to_owned(), scope: None, estate_id: None });
    assert_eq!(failed, Err(V2DataMobilityError::OutcomeUnverified(V2DataMobilityOperation::VaultExport)));
}

#[test]
fn unknown_vault_job_is_an_operational_refusal_not_an_existence_oracle() {
    let service = V2DataMobilityService::new(Authority::default(), Lower { deny_job: true });
    let result = service.vault_job(V2VaultJobRequest { job_id: uuid(JOB) });
    assert_eq!(result, Err(V2DataMobilityError::Unavailable));
}

#[test]
fn vault_terminal_receipt_keeps_the_minted_job_uuid_and_export_evidence() {
    let service = V2DataMobilityService::new(Authority::default(), Lower::new());
    let result = service.vault_job(V2VaultJobRequest { job_id: uuid(JOB) }).unwrap();
    let V2DataMobilityResult::VaultJob(job) = result else { panic!("expected vault job") };
    assert_eq!(job.job_id, uuid(JOB));
    assert_eq!(job.status, "complete");
    assert_eq!(job.terminal, Some(V2VaultJobTerminal::Exported {
        note_count: 3,
        exported_at: "2026-09-08T00:00:00Z".to_owned(),
    }));
}

// ---------------------------------------------------------------------------
// ITEM 1: mode case-insensitivity — reclassify_fdc and palace_import
// ---------------------------------------------------------------------------

#[test]
fn reclassify_fdc_mode_is_case_insensitive() {
    // "ALL" must decode to All without error; fails if the decoder doesn't
    // call to_lowercase() before the enum match.
    let upper = V2ReclassifyFdcRequest::decode(&arguments([
        ("mode", JsonValue::String("ALL".to_owned())),
    ])).unwrap();
    assert_eq!(upper.mode, V2FdcReclassifyMode::All,
        "uppercase ALL must decode to All; got {:?}", upper.mode);

    // "SuspectOnly" (mixed case) must decode to SuspectOnly.
    let mixed = V2ReclassifyFdcRequest::decode(&arguments([
        ("mode", JsonValue::String("SuspectOnly".to_owned())),
    ])).unwrap();
    assert_eq!(mixed.mode, V2FdcReclassifyMode::SuspectOnly,
        "mixed-case SuspectOnly must decode to SuspectOnly; got {:?}", mixed.mode);
}

#[test]
fn palace_import_mode_is_case_insensitive() {
    // "BACKGROUND" must decode to Background without error; fails if the
    // decoder doesn't call to_lowercase() before the enum match.
    let upper = V2PalaceImportRequest::decode(&arguments([
        ("palace_path", JsonValue::String("/tmp/palace".to_owned())),
        ("mode", JsonValue::String("BACKGROUND".to_owned())),
    ])).unwrap();
    assert_eq!(upper.mode, Some(V2ImportMode::Background),
        "uppercase BACKGROUND must decode to Background; got {:?}", upper.mode);

    // "Foreground" (title case) must decode to Foreground.
    let title = V2PalaceImportRequest::decode(&arguments([
        ("palace_path", JsonValue::String("/tmp/palace".to_owned())),
        ("mode", JsonValue::String("Foreground".to_owned())),
    ])).unwrap();
    assert_eq!(title.mode, Some(V2ImportMode::Foreground),
        "title-case Foreground must decode to Foreground; got {:?}", title.mode);
}

// ---------------------------------------------------------------------------
// ITEM 2: return_id_map — decoder must accept the key without rejection
// ---------------------------------------------------------------------------

#[test]
fn json_import_accepts_return_id_map() {
    // return_id_map:true must decode without error; fails if the key is not
    // in the strict_object allow-list, which would produce a V2DecodeError.
    let with_map = V2JsonImportRequest::decode(&arguments([
        ("path", JsonValue::String("/tmp/seed.json".to_owned())),
        ("return_id_map", JsonValue::Bool(true)),
    ])).expect("return_id_map:true must be accepted");
    assert!(with_map.return_id_map, "return_id_map:true must set return_id_map to true");

    // return_id_map:false must also be accepted.
    let without_map = V2JsonImportRequest::decode(&arguments([
        ("path", JsonValue::String("/tmp/seed.json".to_owned())),
        ("return_id_map", JsonValue::Bool(false)),
    ])).expect("return_id_map:false must be accepted");
    assert!(!without_map.return_id_map, "return_id_map:false must set return_id_map to false");

    // Absent return_id_map must default to false.
    let absent = V2JsonImportRequest::decode(&arguments([
        ("path", JsonValue::String("/tmp/seed.json".to_owned())),
    ])).expect("absent return_id_map must default cleanly");
    assert!(!absent.return_id_map, "absent return_id_map must default to false");
}

// ---------------------------------------------------------------------------
// Mode whitespace trim — reclassify_fdc and palace_import
// ---------------------------------------------------------------------------

#[test]
fn reclassify_fdc_mode_trims_whitespace() {
    // "ALL " (trailing space) must decode without error and produce All after
    // trim + lowercase. Fails if the decoder lowercases before trimming —
    // "all " would not match any variant and would error.
    let with_trailing = V2ReclassifyFdcRequest::decode(&arguments([
        ("mode", JsonValue::String("ALL ".to_owned())),
    ])).expect("\"ALL \" with trailing space must be accepted");
    assert_eq!(with_trailing.mode, V2FdcReclassifyMode::All,
        "\"ALL \" must trim and decode to All; got {:?}", with_trailing.mode);

    // " SuspectOnly" (leading space) must also trim and decode cleanly.
    let with_leading = V2ReclassifyFdcRequest::decode(&arguments([
        ("mode", JsonValue::String(" SuspectOnly".to_owned())),
    ])).expect("\" SuspectOnly\" with leading space must be accepted");
    assert_eq!(with_leading.mode, V2FdcReclassifyMode::SuspectOnly,
        "\" SuspectOnly\" must trim and decode to SuspectOnly; got {:?}", with_leading.mode);
}

#[test]
fn palace_import_mode_trims_whitespace() {
    // "BACKGROUND " (trailing space) must decode to Background after trim + lowercase.
    let with_trailing = V2PalaceImportRequest::decode(&arguments([
        ("palace_path", JsonValue::String("/tmp/palace".to_owned())),
        ("mode", JsonValue::String("BACKGROUND ".to_owned())),
    ])).expect("\"BACKGROUND \" with trailing space must be accepted");
    assert_eq!(with_trailing.mode, Some(V2ImportMode::Background),
        "\"BACKGROUND \" must trim and decode to Background; got {:?}", with_trailing.mode);

    // " Foreground" (leading space) must also trim and decode cleanly.
    let with_leading = V2PalaceImportRequest::decode(&arguments([
        ("palace_path", JsonValue::String("/tmp/palace".to_owned())),
        ("mode", JsonValue::String(" Foreground".to_owned())),
    ])).expect("\" Foreground\" with leading space must be accepted");
    assert_eq!(with_leading.mode, Some(V2ImportMode::Foreground),
        "\" Foreground\" must trim and decode to Foreground; got {:?}", with_leading.mode);
}
