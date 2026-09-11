
#[path = "../src/jsonrpc.rs"]
mod jsonrpc;
#[path = "../src/v2/codec.rs"]
mod codec;
#[path = "../src/v2/memory_mutations.rs"]
mod memory_mutations;

use std::{collections::BTreeMap, sync::{Arc, Mutex}};

use genius_locus_kit::EstateHandle;
use jsonrpc::JsonValue;
use memory_mutations::*;
use uuid::Uuid;

const ESTATE: &str = "11111111-1111-4111-8111-111111111111";
const MEMORY: &str = "22222222-2222-4222-8222-222222222222";
const TUNNEL: &str = "33333333-3333-4333-8333-333333333333";

fn uuid(value: &str) -> Uuid { Uuid::parse_str(value).unwrap() }
fn arguments(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(entries.into_iter().map(|(key, value)| (key.to_owned(), value)).collect::<BTreeMap<_, _>>())
}

#[derive(Default)]
struct Authority { calls: Mutex<Vec<V2MemoryMutationOperation>>, fail_revalidate: bool }
impl V2MemoryMutationAuthority for Authority {
    fn admit(&self, operation: V2MemoryMutationOperation, requested: Option<Uuid>) -> Result<V2MemoryMutationAdmission, ()> {
        assert!(requested.is_none() || requested == Some(uuid(ESTATE)));
        self.calls.lock().unwrap().push(operation);
        Ok(V2MemoryMutationAdmission {
            estate_id: uuid(ESTATE), estate_handle: EstateHandle::new([1; 16], 0, 0).unwrap(),
            caller_binding: "caller-a".to_owned(), now_millis: 100, authorization_generation: "g1".to_owned(),
        })
    }
    fn revalidate(&self, _: &V2MemoryMutationAdmission) -> Result<(), ()> { if self.fail_revalidate { Err(()) } else { Ok(()) } }
}

struct Lower {
    calls: Arc<Mutex<Vec<&'static str>>>,
    updates: Arc<Mutex<Vec<(V2UpdateMutation, Option<String>)>>>,
    partial_erase: bool,
}
impl Default for Lower {
    fn default() -> Self { Self { calls: Arc::new(Mutex::new(Vec::new())), updates: Arc::new(Mutex::new(Vec::new())), partial_erase: false } }
}
impl V2MemoryMutationLower for Lower {
    fn mutate(&self, _: &V2MemoryMutationAdmission, _: Uuid, mutation: &V2UpdateMutation, note: Option<&str>) -> Result<(), ()> {
        self.calls.lock().unwrap().push("mutate");
        self.updates.lock().unwrap().push((mutation.clone(), note.map(str::to_owned)));
        Ok(())
    }
    fn withdraw(&self, _: &V2MemoryMutationAdmission, _: Uuid, _: Option<&str>) -> Result<(), ()> { self.calls.lock().unwrap().push("withdraw"); Ok(()) }
    fn erase(&self, _: &V2MemoryMutationAdmission, _: Uuid, _: bool, _: Option<&str>) -> Result<bool, ()> { self.calls.lock().unwrap().push("erase"); Ok(self.partial_erase) }
    fn move_memory(&self, _: &V2MemoryMutationAdmission, _: Uuid, _: &str, _: &str) -> Result<(), ()> { self.calls.lock().unwrap().push("move"); Ok(()) }
    fn link(&self, _: &V2MemoryMutationAdmission, _: &V2LinkMemoriesRequest) -> Result<Uuid, ()> { self.calls.lock().unwrap().push("link"); Ok(uuid(TUNNEL)) }
    fn review(&self, _: &V2MemoryMutationAdmission, _: Uuid, decision: V2TunnelDecision, _: Option<&str>, _: &str) -> Result<V2TunnelReviewReceipt, ()> {
        self.calls.lock().unwrap().push("review");
        Ok(match decision {
            V2TunnelDecision::Endorse => V2TunnelReviewReceipt::Endorsed {
                new_endorser: true, distinct_endorsers: 1, contested: false,
            },
            V2TunnelDecision::Accept | V2TunnelDecision::Reject => V2TunnelReviewReceipt::Settled {
                withdrawn: matches!(decision, V2TunnelDecision::Reject), contested: false,
            },
        })
    }
}

#[test]
fn every_advertised_update_mutation_reaches_its_matching_lower_kind() {
    let lower = Lower::default();
    let updates = Arc::clone(&lower.updates);
    let service = V2MemoryMutationService::new(Authority::default(), lower);
    let requests = [
        ("confirm", None, None, None, None, V2UpdateMutation::Confirm),
        ("reject", None, None, None, None, V2UpdateMutation::Reject),
        ("contest", None, None, None, Some("audit note"), V2UpdateMutation::Contest),
        ("resolve", None, None, None, None, V2UpdateMutation::Resolve),
        ("supersede", None, None, None, None, V2UpdateMutation::Supersede),
        ("revive", None, None, None, None, V2UpdateMutation::Revive),
        ("accept", None, None, None, None, V2UpdateMutation::Accept),
        ("set_subject", Some("  Typed subject  "), None, None, None, V2UpdateMutation::SetSubject("Typed subject".to_owned())),
        ("correct_sensitivity", None, Some("restricted"), None, None, V2UpdateMutation::CorrectSensitivity(locus_kit::adjectives::AdjectiveSensitivity::Restricted)),
        ("correct_exportability", None, None, Some("public"), None, V2UpdateMutation::CorrectExportability(locus_kit::adjectives::AdjectiveExportability::Public)),
    ];

    for (mutation, subject, sensitivity, exportability, note, expected) in requests {
        let mut values = vec![
            ("memory_id", JsonValue::String(MEMORY.to_owned())),
            ("mutation", JsonValue::String(mutation.to_owned())),
        ];
        if let Some(subject) = subject { values.push(("subject", JsonValue::String(subject.to_owned()))); }
        if let Some(sensitivity) = sensitivity { values.push(("sensitivity", JsonValue::String(sensitivity.to_owned()))); }
        if let Some(exportability) = exportability { values.push(("exportability", JsonValue::String(exportability.to_owned()))); }
        if let Some(note) = note { values.push(("note", JsonValue::String(note.to_owned()))); }
        let request = V2UpdateMemoryRequest::decode(&arguments(values)).unwrap();
        assert_eq!(request.mutation, expected);
        service.update(request).unwrap();
    }

    assert_eq!(
        *updates.lock().unwrap(),
        vec![
            (V2UpdateMutation::Confirm, None),
            (V2UpdateMutation::Reject, None),
            (V2UpdateMutation::Contest, Some("audit note".to_owned())),
            (V2UpdateMutation::Resolve, None),
            (V2UpdateMutation::Supersede, None),
            (V2UpdateMutation::Revive, None),
            (V2UpdateMutation::Accept, None),
            (V2UpdateMutation::SetSubject("Typed subject".to_owned()), None),
            (V2UpdateMutation::CorrectSensitivity(locus_kit::adjectives::AdjectiveSensitivity::Restricted), None),
            (V2UpdateMutation::CorrectExportability(locus_kit::adjectives::AdjectiveExportability::Public), None),
        ]
    );
}

#[test]
fn inapplicable_or_missing_update_payloads_are_rejected_before_lower() {
    let lower = Lower::default();
    let calls = Arc::clone(&lower.calls);
    let _service = V2MemoryMutationService::new(Authority::default(), lower);
    for value in [
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String(" confirm ".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("subject", JsonValue::String("inapplicable".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("sensitivity", JsonValue::String("normal".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("exportability", JsonValue::String("private".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("note", JsonValue::String("ignored".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_subject".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_subject".to_owned())), ("subject", JsonValue::String("x".repeat(121)))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_subject".to_owned())), ("subject", JsonValue::String("e\u{301}".repeat(120)))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_subject".to_owned())), ("subject", JsonValue::String(format!(" {}", "x".repeat(120))))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("correct_sensitivity".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("correct_exportability".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_sensitivity".to_owned())), ("sensitivity", JsonValue::String("normal".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("content", JsonValue::String("unsupported".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("location", JsonValue::String("unsupported".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("wing", JsonValue::String("unsupported".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("confirm".to_owned())), ("event_time", JsonValue::String("2026-09-08T00:00:00Z".to_owned()))]),
    ] {
        assert!(V2UpdateMemoryRequest::decode(&value).is_err());
    }
    assert!(calls.lock().unwrap().is_empty(), "invalid update payload reached lower mutate");
}

#[test]
fn requests_match_the_frozen_operation_keys_and_reject_unknowns() {
    let update = V2UpdateMemoryRequest::decode(&arguments([
        ("memory_id", JsonValue::String(MEMORY.to_owned())), ("mutation", JsonValue::String("set_subject".to_owned())),
        ("subject", JsonValue::String("A compact subject".to_owned())),
    ])).unwrap();
    assert_eq!(update.memory_id, uuid(MEMORY));

    let link = V2LinkMemoriesRequest::decode(&arguments([
        ("from_id", JsonValue::String(MEMORY.to_owned())), ("to_id", JsonValue::String(TUNNEL.to_owned())),
        ("relationship", JsonValue::String("contradicts".to_owned())), ("confidence", JsonValue::String("high".to_owned())),
    ])).unwrap();
    assert_eq!(link.relationship, "contradicts");

    let unknown = V2ReviewTunnelRequest::decode(&arguments([
        ("tunnel_id", JsonValue::String(TUNNEL.to_owned())), ("decision", JsonValue::String("accept".to_owned())),
        ("reviewed_by", JsonValue::String("must-not-cross-v1".to_owned())),
    ])).unwrap_err();
    assert_eq!(unknown.path, "$.reviewed_by");
}

#[test]
fn typed_service_has_stable_operation_identity_and_outcomes() {
    let authority = Authority::default();
    let lower = Lower { partial_erase: true, ..Lower::default() };
    let calls = Arc::clone(&lower.calls);
    let service = V2MemoryMutationService::new(authority, lower);
    let erased = service.erase(V2EraseMemoryRequest {
        memory_id: uuid(MEMORY), confirmation: true, reason: Some("owner-approved".to_owned()), estate_id: None,
    }).unwrap();
    assert_eq!(erased.operation.tool_name(), ERASE_MEMORY_TOOL);
    assert_eq!(erased.outcome, V2MemoryMutationOutcome::ErasedPartially);
    assert_eq!(erased.memory_id, Some(uuid(MEMORY)));

    let linked = service.link(V2LinkMemoriesRequest { from_id: uuid(MEMORY), to_id: uuid(TUNNEL), relationship: "contradicts".to_owned(), confidence: None, evidence: None, estate_id: None }).unwrap();
    assert_eq!(linked.operation.tool_name(), LINK_MEMORIES_TOOL);
    assert_eq!(linked.outcome, V2MemoryMutationOutcome::Linked);
    assert_eq!(linked.tunnel_id, Some(uuid(TUNNEL)));
    assert_eq!(*calls.lock().unwrap(), ["erase", "link"]);
}

#[test]
fn endorse_decodes_and_returns_the_typed_review_receipt() {
    let lower = Lower::default();
    let calls = Arc::clone(&lower.calls);
    let service = V2MemoryMutationService::new(Authority::default(), lower);
    let request = V2ReviewTunnelRequest::decode(&arguments([
        ("tunnel_id", JsonValue::String(TUNNEL.to_owned())),
        ("decision", JsonValue::String("endorse".to_owned())),
    ])).unwrap();
    assert_eq!(request.decision, V2TunnelDecision::Endorse);

    let reviewed = service.review(request).unwrap();
    assert_eq!(reviewed.outcome, V2MemoryMutationOutcome::TunnelEndorsed);
    assert_eq!(reviewed.tunnel_id, Some(uuid(TUNNEL)));
    assert_eq!(reviewed.tunnel_review, Some(V2TunnelReviewReceipt::Endorsed {
        new_endorser: true, distinct_endorsers: 1, contested: false,
    }));
    assert_eq!(*calls.lock().unwrap(), ["review"]);
}

#[test]
fn erase_confirmation_rejections_do_not_call_lower() {
    let lower = Lower::default();
    let calls = Arc::clone(&lower.calls);
    let _service = V2MemoryMutationService::new(Authority::default(), lower);

    for arguments in [
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("confirmation", JsonValue::Bool(false))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("confirmation", JsonValue::String("no".to_owned()))]),
        arguments([("memory_id", JsonValue::String(MEMORY.to_owned())), ("confirmation", JsonValue::Array(Vec::new()))]),
    ] {
        let error = V2EraseMemoryRequest::decode(&arguments).unwrap_err();
        assert_eq!(error.path, "$.confirmation");
        assert!(calls.lock().unwrap().is_empty(), "invalid confirmation reached lower erase");
    }
}

#[test]
fn revalidation_failure_never_claims_a_confirmed_outcome() {
    let lower = Lower::default();
    let calls = Arc::clone(&lower.calls);
    let service = V2MemoryMutationService::new(Authority { fail_revalidate: true, ..Authority::default() }, lower);
    let result = service.confirm(V2ConfirmMemoryRequest { memory_id: uuid(MEMORY), estate_id: None });
    assert_eq!(result, Err(V2MemoryMutationError::OutcomeUnverified(V2MemoryMutationOperation::ConfirmMemory)));
    assert_eq!(*calls.lock().unwrap(), ["mutate"]);
}
