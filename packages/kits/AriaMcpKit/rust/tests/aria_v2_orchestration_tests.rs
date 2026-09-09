
#[path = "../src/jsonrpc.rs"] mod jsonrpc;
#[path = "../src/v2/codec.rs"] mod codec;
#[path = "../src/v2/orchestration.rs"] mod orchestration;

use std::{collections::BTreeMap, sync::Mutex};
use jsonrpc::JsonValue;
use orchestration::*;
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
