
mod test_support;

use std::{collections::BTreeMap, sync::Mutex};
use aria_mcp::jsonrpc::JsonValue;
use aria_mcp::v2::orchestration::*;
use uuid::Uuid;

const ESTATE: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const BRANCH: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const LOSER: &str = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const MEMORY: &str = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

fn id(value: &str) -> Uuid { Uuid::parse_str(value).unwrap() }
fn args(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(entries.into_iter().map(|(key, value)| (key.to_owned(), value)).collect::<BTreeMap<_, _>>())
}

#[derive(Default)]
struct Provider { calls: Mutex<Vec<V2OrchestrationOperation>> }
impl V2OrchestrationProvider for Provider {
    fn synthesize(&self, _: V2SynthesizeRequest, _: Uuid) -> Result<V2SynthesisData, V2OrchestrationFailure> {
        self.calls.lock().unwrap().push(V2OrchestrationOperation::Synthesize);
        Ok(V2SynthesisData { summary: "grounded".to_owned(), cues: Some(vec!["grounded".to_owned()]), results: vec![V2CompactMemory { memory_id: id(MEMORY), subject: None, score: None, provenance: None, context: None, excerpt: Some("grounded excerpt".to_owned()) }] })
    }
    fn run_migration(&self, _: V2RunMigrationRequest, _: Uuid) -> Result<V2MigrationData, V2OrchestrationFailure> {
        self.calls.lock().unwrap().push(V2OrchestrationOperation::RunMigration);
        Ok(V2MigrationData { reports: vec![], winner_branch_id: Some(id(BRANCH)), winner_plan_name: Some("flat".to_owned()), rankings: vec![], disqualified: vec![] })
    }
    fn confirm_migration(&self, request: V2ConfirmMigrationRequest, _: Uuid) -> Result<V2MigrationConfirmationData, V2OrchestrationFailure> {
        self.calls.lock().unwrap().push(V2OrchestrationOperation::ConfirmMigration);
        Ok(V2MigrationConfirmationData { promoted_branch_id: request.winner_branch_id, discarded_branch_ids: request.discard_branch_ids.clone(), discard_outcomes: request.discard_branch_ids.into_iter().map(|branch_id| V2DiscardOutcome { branch_id, status: V2DiscardOutcomeStatus::Discarded }).collect() })
    }
    fn federated_search(&self, _: V2FederatedSearchRequest, selected: Uuid) -> Result<V2FederatedSearchData, V2OrchestrationFailure> {
        self.calls.lock().unwrap().push(V2OrchestrationOperation::FederatedSearch);
        Ok(V2FederatedSearchData { source_estate_id: id("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"), requester_estate_id: selected, grant_id: id("ffffffff-ffff-4fff-8fff-ffffffffffff"), results: vec![V2CompactMemory { memory_id: id(MEMORY), subject: None, score: None, provenance: None, context: None, excerpt: Some("federated excerpt".to_owned()) }] })
    }
}

#[test]
fn requests_are_strict_and_use_frozen_v2_spellings() {
    let request = V2ConfirmMigrationRequest::decode(&args([
        ("winner_branch_id", JsonValue::String(BRANCH.to_owned())),
        ("discard_branch_ids", JsonValue::Array(vec![JsonValue::String(LOSER.to_owned())])),
    ])).unwrap();
    assert_eq!(request.winner_branch_id, id(BRANCH));
    assert_eq!(request.discard_branch_ids, vec![id(LOSER)]);
    let error = V2ConfirmMigrationRequest::decode(&args([("winnerBranchID", JsonValue::String(BRANCH.to_owned()))])).unwrap_err();
    assert_eq!(error.path, "$.winnerBranchID");
}

#[test]
fn migration_run_never_auto_confirms_and_keeps_branch_identity() {
    let provider = Provider::default();
    let service = V2OrchestrationService::new(id(ESTATE), provider);
    let request = V2RunMigrationRequest::decode(&args([
        ("corpusName", JsonValue::String("fixture".to_owned())),
        ("entries", JsonValue::Array(vec![args([("id", JsonValue::String("one".to_owned())), ("content", JsonValue::String("fixture".to_owned()))])])),
        ("plans", JsonValue::Array(vec![args([("name", JsonValue::String("flat".to_owned())), ("room", JsonValue::String("Planning".to_owned())), ("latticeCode", JsonValue::String("001".to_owned())), ("embeddingModelID", JsonValue::String("fixture".to_owned()))])])),
    ])).unwrap();
    let output = service.run_migration(request).unwrap();
    assert_eq!(output.winner_branch_id, Some(id(BRANCH)));
    assert_eq!(*service.provider().calls.lock().unwrap(), vec![V2OrchestrationOperation::RunMigration]);
}

#[test]
fn confirmation_exposes_only_verified_cleanup_outcomes() {
    let service = V2OrchestrationService::new(id(ESTATE), Provider::default());
    let output = service.confirm_migration(V2ConfirmMigrationRequest { winner_branch_id: id(BRANCH), discard_branch_ids: vec![id(LOSER)], estate_id: None }).unwrap();
    assert_eq!(output.promoted_branch_id, id(BRANCH));
    assert_eq!(output.discarded_branch_ids, vec![id(LOSER)]);
    assert_eq!(output.discard_outcomes[0].status, V2DiscardOutcomeStatus::Discarded);

    let invalid = V2MigrationConfirmationData { promoted_branch_id: id(BRANCH), discarded_branch_ids: vec![id(LOSER)], discard_outcomes: vec![V2DiscardOutcome { branch_id: id(LOSER), status: V2DiscardOutcomeStatus::Failed }] };
    assert_eq!(invalid.verify(), Err(V2OrchestrationFailure::UnverifiedCleanup));
}

#[test]
fn federation_binds_requester_to_selected_estate() {
    let service = V2OrchestrationService::new(id(ESTATE), Provider::default());
    let output = service.federated_search(V2FederatedSearchRequest { requester_estate_id: Some(id(ESTATE)), filter: None, limit: None, ordering: None, hydration_level: None }).unwrap();
    assert_eq!(output.requester_estate_id, id(ESTATE));
    assert_eq!(output.results[0].memory_id, id(MEMORY));
    assert_eq!(service.federated_search(V2FederatedSearchRequest { requester_estate_id: Some(id("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")), filter: None, limit: None, ordering: None, hydration_level: None }), Err(V2OrchestrationFailure::EstateUnavailable));
}

/// Drives `moot_synthesize` end-to-end and asserts that `subject` and `context`
/// in the compact synthesis row are truncated to exactly the 512-scalar compact
/// form and that they are identical.
///
/// The ARIA argument decoder rejects subjects longer than 120 grapheme clusters, so a
/// 600-char subject cannot be filed through `moot_file_memory`.  Instead a seed
/// memory is filed through the production door to create the node tree, and then
/// a drawer with the long subject is injected directly into the store via
/// `store.add_drawer` — the same approach as the SEARCH gate.  `add_drawer` does
/// not check subject length, so the injection succeeds.
///
/// Synthesis without a query uses `coord.recall()` (time-ordered scan), which
/// finds the injected drawer.  `provenance=0` passes the `public_capture_provenance`
/// gate inside `compact_memory`.
///
/// The injected row is selected by `memory_id` (the drawer's UUID, lowercase
/// hyphenated in both the test variable and the serialised JSON field), so the
/// row lookup is independent of what `compact_memory` did to the subject.
/// This makes all three assertions load-bearing:
///   - `subject == context`: goes RED if `compact_memory` stops copying subject
///     into the context field.
///   - `subject == compact`: goes RED if `compact_memory` returns a different
///     truncation of the 600-char input.
///   - `subject.chars().count() == 512`: goes RED if `compact_memory` removes
///     subject truncation entirely (row subject would be 600 chars instead of 512).
///
/// Injection route: seed filed through `moot_file_memory`; long-subject drawer
/// injected directly via `store.add_drawer`, bypassing the ARIA argument decoder.
#[test]
fn compact_row_subject_and_context_share_the_512_scalar_form() {
    use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue as JV, v2::render};
    use locus_kit::drawer::Drawer;
    use locus_kit::drawer_store::DrawerStore;
    use test_support::SelectedV2Session;
    use std::time::{SystemTime, UNIX_EPOCH};

    // 600-char subject cycling through the alphabet so a wrong truncation slice
    // produces a visibly wrong character rather than a silent length mismatch.
    let base = "abcdefghijklmnopqrstuvwxyz";
    let long_subject: String = base.repeat(23) + "ab"; // 23×26 + 2 = 600 chars
    assert_eq!(long_subject.chars().count(), 600,
        "precondition: long_subject must be exactly 600 chars");

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    // File a seed memory through the production door to create the node tree.
    // We extract its drawer to obtain a valid parent_node_id for injection.
    let mut seed_args = BTreeMap::new();
    seed_args.insert("content".to_owned(), JV::String("seed content for node tree".to_owned()));
    seed_args.insert("subject".to_owned(), JV::String("seed subject".to_owned()));
    seed_args.insert("location".to_owned(), JV::String("compact-512-form-tests".to_owned()));
    let seed_filed = session.call("moot_file_memory", &seed_args)
        .expect("seed filing must succeed");
    assert_eq!(seed_filed["isError"], serde_json::json!(false), "seed file: {seed_filed:?}");
    let seed_id = seed_filed["structuredContent"]["data"]["memory_id"]
        .as_str()
        .expect("seed memory_id must be present in structuredContent.data")
        .to_owned();

    let store = &session.default.store;
    let seed_drawer = store.get_drawer(&seed_id)
        .expect("get_drawer must not fail")
        .expect("seed drawer must exist in the store");
    let parent_node_id = seed_drawer.parent_node_id.clone();

    // Inject a drawer with the 600-char subject directly into the store.
    // This bypasses the ARIA argument decoder's 120-char (scalar) subject gate.
    // provenance=0: (0>>30)&0x3f = 0, which passes public_capture_provenance.
    let now_millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64 + 1_000; // +1s so it sorts after the seed
    let drawer_id = uuid::Uuid::new_v4().to_string();
    let mut long_drawer = Drawer::new(
        &drawer_id,
        "compact-synthesis-test-content",
        &parent_node_id,
        "test-injector",
        now_millis,
        "test-v1",
    );
    long_drawer.subject = Some(long_subject.clone());
    long_drawer.udc_code = "001".to_string();
    store.add_drawer(&long_drawer, now_millis)
        .expect("injecting long-subject drawer must succeed");

    // Synthesis without a query uses coord.recall() (time-ordered scan) which
    // finds the injected drawer.
    let mut synth_args = BTreeMap::new();
    synth_args.insert("filter".to_owned(), JV::String("unconfirmed".to_owned()));
    let result = session.call("moot_synthesize", &synth_args)
        .expect("moot_synthesize must dispatch");
    assert_eq!(result["isError"], serde_json::json!(false), "synthesize: {result:?}");

    let rows = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("moot_synthesize must return a results array");

    // compact_text truncates to 512 scalars; for plain ASCII chars().count() == scalar count.
    let compact = render::compact_text(&long_subject);
    assert_eq!(compact.chars().count(), 512,
        "compact_text must produce exactly 512 scalars from a 600-char input");

    // Find the injected row by its identity, not by what compact_memory did to the subject.
    // drawer_id is lowercase hyphenated (uuid::Uuid::to_string() Display form).
    // The serialised memory_id field is also lowercase hyphenated (Uuid via serde Serialize).
    // Both sides are in the same form; no normalisation is needed.
    let row = rows.iter()
        .find(|r| r["memory_id"].as_str() == Some(drawer_id.as_str()))
        .unwrap_or_else(|| panic!(
            "synthesis results must include the injected row with memory_id {}; \
             available memory ids: {:?}",
            drawer_id,
            rows.iter().map(|r| r["memory_id"].as_str()).collect::<Vec<_>>()
        ));

    let row_subject = row["subject"].as_str().expect("row must carry a subject field");
    let row_context = row["context"].as_str().expect("row must carry a context field");

    // All three assertions hold together: parity, compact form, exact 512 scalars.
    // Removing compact_memory's subject truncation turns the last assertion red
    // (row subject would be 600 chars, not 512).
    assert_eq!(row_subject, row_context,
        "subject and context must be identical in the compact synthesis row");
    assert_eq!(row_subject, compact.as_str(),
        "subject must equal render::compact_text of the 600-char input");
    assert_eq!(row_subject.chars().count(), 512,
        "compact form must be exactly 512 scalars; got {}", row_subject.chars().count());
}

#[test]
fn synthesis_row_context_carries_the_filed_subject() {
    use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue as JV};
    use test_support::SelectedV2Session;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let subject = "the drawer subject that context must carry";

    // File through the production door so the synthesis path exercises the real
    // orchestration lower that was fixed to wire context from drawer.subject.
    let mut file_args = BTreeMap::new();
    file_args.insert("content".to_owned(), JV::String(subject.to_owned()));
    file_args.insert("subject".to_owned(), JV::String(subject.to_owned()));
    file_args.insert("location".to_owned(), JV::String("context-field-tests".to_owned()));
    let filed = session.call("moot_file_memory", &file_args)
        .expect("filing through the production door must succeed");
    assert_eq!(filed["isError"], serde_json::json!(false), "file: {filed:?}");

    let mut synth_args = BTreeMap::new();
    synth_args.insert("filter".to_owned(), JV::String("unconfirmed".to_owned()));
    let result = session.call("moot_synthesize", &synth_args)
        .expect("moot_synthesize must dispatch");
    assert_eq!(result["isError"], serde_json::json!(false), "synthesize: {result:?}");

    let rows = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("moot_synthesize must return a results array");
    assert!(!rows.is_empty(), "synthesis must return at least one row for the filed subject");
    assert_eq!(
        rows[0]["context"].as_str(),
        Some(subject),
        "synthesis compact row must carry the drawer subject in the context field; got: {:?}",
        rows[0]["context"],
    );
}
