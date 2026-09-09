#[path = "../src/jsonrpc.rs"]
mod jsonrpc;

#[path = "../src/v2/codec.rs"]
mod codec;

#[path = "../src/v2/contradictions.rs"]
mod contradictions;

use contradictions::{
    candidate_evidence_from_drawers, coordinator_candidate_evidence, execute_hunt, V2ReadOnlyContradictionHuntSource,
    V2ContradictionAnalysisBinding, V2ContradictionAnalysisCache,
    V2ContradictionCacheError, V2ContradictionCandidate, V2ContradictionFinding, V2ContradictionHuntRequest, V2ContradictionProposalRequest,
    V2ContradictionProposalStatus, ANALYSIS_REFERENCE_TTL_MS, MAX_CANDIDATES_PER_ANALYSIS,
    MAX_LIVE_ANALYSES_PER_CONTEXT,
};
use jsonrpc::JsonValue;
use std::cell::Cell;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

fn object(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn binding() -> V2ContradictionAnalysisBinding {
    V2ContradictionAnalysisBinding {
        estate_id: Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap(),
        authorization_context: "caller-1-policy-7".to_owned(),
        analysis_revision: "revision-1".to_owned(),
    }
}

fn finding() -> V2ContradictionFinding {
    V2ContradictionFinding {
        source_memory_id: "00000000-0000-0000-0000-000000000001".to_owned(),
        target_memory_id: "00000000-0000-0000-0000-000000000002".to_owned(),
        tier: 2,
        rule_or_cue_version: "negation_asymmetry@1".to_owned(),
        renewal_identity: "tier2:negation_asymmetry@1".to_owned(),
        source_digest: "source-digest".to_owned(),
        evidence_digest: "evidence-digest".to_owned(),
    }
}

#[test]
fn proposal_request_is_strict_and_accepts_opaque_non_uuid_candidate_ids() {
    let request = V2ContradictionProposalRequest::decode(&object([
        ("analysis_ref", JsonValue::String("analysis:opaque".to_owned())),
        (
            "candidate_ids",
            JsonValue::Array(vec![JsonValue::String("candidate:opaque".to_owned())]),
        ),
    ]))
    .unwrap();
    assert_eq!(request.candidate_ids, ["candidate:opaque"]);

    let duplicate = V2ContradictionProposalRequest::decode(&object([
        ("analysis_ref", JsonValue::String("analysis".to_owned())),
        (
            "candidate_ids",
            JsonValue::Array(vec![
                JsonValue::String("same".to_owned()),
                JsonValue::String("same".to_owned()),
            ]),
        ),
    ]))
    .unwrap_err();
    assert_eq!(duplicate.path, "$.candidate_ids[1]");

    let unknown = V2ContradictionProposalRequest::decode(&object([
        ("analysis_ref", JsonValue::String("analysis".to_owned())),
        ("candidate_ids", JsonValue::Array(vec![JsonValue::String("one".to_owned())])),
        ("tunnel_id", JsonValue::String("must-not-be-accepted".to_owned())),
    ]))
    .unwrap_err();
    assert_eq!(unknown.path, "$.tunnel_id");
}

#[test]
fn hunt_request_has_a_bounded_optional_limit() {
    let request = V2ContradictionHuntRequest::decode(&object([(
        "limit", JsonValue::Integer(7),
    )])).unwrap();
    assert_eq!(request.limit, Some(7));
    assert_eq!(request.estate_id, None);

    let rejected = V2ContradictionHuntRequest::decode(&object([(
        "limit", JsonValue::Integer(MAX_CANDIDATES_PER_ANALYSIS as i64 + 1),
    )])).unwrap_err();
    assert_eq!(rejected.path, "$.limit");
}

#[test]
fn candidate_limit_is_a_hard_error() {
    let mut cache = V2ContradictionAnalysisCache::new();
    let findings = std::iter::repeat_with(finding)
        .take(MAX_CANDIDATES_PER_ANALYSIS + 1)
        .collect();
    let ids = (0..=MAX_CANDIDATES_PER_ANALYSIS)
        .map(|index| format!("candidate-{index}"))
        .collect();
    assert_eq!(
        cache.store_hunt("analysis".to_owned(), ids, binding(), findings, 10),
        Err(V2ContradictionCacheError::CandidateLimitExceeded)
    );
}

#[test]
fn reference_expiry_is_absolute_even_after_a_successful_lookup() {
    let mut cache = V2ContradictionAnalysisCache::new();
    let result = cache
        .store_hunt(
            "analysis".to_owned(),
            vec!["candidate".to_owned()],
            binding(),
            vec![finding()],
            100,
        )
        .unwrap();
    assert_eq!(result.expires_at_ms, 100 + ANALYSIS_REFERENCE_TTL_MS);

    let request = V2ContradictionProposalRequest {
        analysis_ref: "analysis".to_owned(),
        candidate_ids: vec!["candidate".to_owned()],
        estate_id: None,
    };
    cache.resolve_proposal(&request, &binding(), 101).unwrap();
    let refusal = cache
        .resolve_proposal(&request, &binding(), 100 + ANALYSIS_REFERENCE_TTL_MS)
        .unwrap_err();
    assert_eq!(refusal.code, "proposal_expired");
    assert!(refusal.retryable);
}

#[test]
fn proposal_never_reruns_hunt_and_requires_the_bound_context_and_revision() {
    let mut cache = V2ContradictionAnalysisCache::new();
    cache
        .store_hunt(
            "analysis".to_owned(),
            vec!["candidate".to_owned()],
            binding(),
            vec![finding()],
            100,
        )
        .unwrap();
    let request = V2ContradictionProposalRequest {
        analysis_ref: "analysis".to_owned(),
        candidate_ids: vec!["candidate".to_owned()],
        estate_id: None,
    };
    let mut changed = binding();
    changed.analysis_revision = "revision-2".to_owned();
    assert_eq!(
        cache.resolve_proposal(&request, &changed, 101).unwrap_err().code,
        "proposal_stale"
    );
    let mut other_caller = binding();
    other_caller.authorization_context = "caller-2-policy-7".to_owned();
    assert_eq!(
        cache.resolve_proposal(&request, &other_caller, 101).unwrap_err().code,
        "proposal_context_mismatch"
    );
}

struct CountingSource {
    calls: Cell<usize>,
}

impl V2ReadOnlyContradictionHuntSource for CountingSource {
    fn hunt(
        &self,
        _binding: &V2ContradictionAnalysisBinding,
    ) -> Result<Vec<V2ContradictionFinding>, String> {
        self.calls.set(self.calls.get() + 1);
        Ok(vec![finding()])
    }
}

#[test]
fn proposal_resolves_the_recorded_hunt_without_another_source_call() {
    let source = CountingSource { calls: Cell::new(0) };
    let mut cache = V2ContradictionAnalysisCache::new();
    execute_hunt(
        &source,
        &mut cache,
        "analysis".to_owned(),
        vec!["candidate".to_owned()],
        binding(),
        100,
    )
    .unwrap();
    let request = V2ContradictionProposalRequest {
        analysis_ref: "analysis".to_owned(),
        candidate_ids: vec!["candidate".to_owned()],
        estate_id: None,
    };
    cache.resolve_proposal(&request, &binding(), 101).unwrap();
    assert_eq!(source.calls.get(), 1);
}

#[test]
fn selected_unknown_candidate_is_rejected_without_substitution() {
    let mut cache = V2ContradictionAnalysisCache::new();
    cache
        .store_hunt(
            "analysis".to_owned(),
            vec!["candidate".to_owned()],
            binding(),
            vec![finding()],
            100,
        )
        .unwrap();
    let request = V2ContradictionProposalRequest {
        analysis_ref: "analysis".to_owned(),
        candidate_ids: vec!["different-candidate".to_owned()],
        estate_id: None,
    };
    assert_eq!(
        cache.resolve_proposal(&request, &binding(), 101).unwrap_err().code,
        "proposal_candidate_unavailable"
    );
}

#[test]
fn context_capacity_evicts_the_least_recent_reference_and_requires_restart() {
    let mut cache = V2ContradictionAnalysisCache::new();
    for index in 0..=MAX_LIVE_ANALYSES_PER_CONTEXT {
        cache
            .store_hunt(
                format!("analysis-{index:02}"),
                vec![format!("candidate-{index}")],
                binding(),
                vec![finding()],
                index as i64,
            )
            .unwrap();
    }
    assert_eq!(cache.live_reference_count(), MAX_LIVE_ANALYSES_PER_CONTEXT);
    let evicted = V2ContradictionProposalRequest {
        analysis_ref: "analysis-00".to_owned(),
        candidate_ids: vec!["candidate-0".to_owned()],
        estate_id: None,
    };
    assert_eq!(
        cache.resolve_proposal(&evicted, &binding(), 40).unwrap_err().code,
        "proposal_expired"
    );
}

#[test]
fn proposal_status_serialization_keeps_created_existing_and_settled_distinct() {
    assert_eq!(
        serde_json::to_value(V2ContradictionProposalStatus::Created {
            tunnel_id: "tunnel-1".to_owned(),
            lifecycle: "proposed".to_owned(),
        })
        .unwrap(),
        serde_json::json!({
            "status": "created",
            "tunnel_id": "tunnel-1",
            "lifecycle": "proposed",
        })
    );
    assert_eq!(
        serde_json::to_value(V2ContradictionProposalStatus::Settled).unwrap(),
        serde_json::json!({ "status": "settled" })
    );
}

#[test]
fn public_candidate_evidence_is_bounded_fresh_and_never_bypasses_provenance() {
    use locus_kit::{
        drawer::Drawer,
        drawer_store::conflict_proposal_digests,
    };

    let source_id = "aaaaaaaa-0000-4000-8000-000000000001";
    let target_id = "bbbbbbbb-0000-4000-8000-000000000002";
    let source = Drawer::new(source_id, "é".repeat(513), "room", "test", 1, "model");
    let target = Drawer::new(target_id, "The launch window is Tuesday.", "room", "test", 2, "model");
    let renewal = "tier2:negation_asymmetry@1";
    let (source_digest, evidence_digest) = conflict_proposal_digests(&source, &target, 2, renewal);
    let candidate = V2ContradictionCandidate {
        candidate_id: "candidate_opaque".to_owned(),
        source_memory_id: source_id.to_owned(),
        target_memory_id: target_id.to_owned(),
        tier: 2,
        rule_or_cue_version: "negation_asymmetry@1".to_owned(),
        renewal_identity: renewal.to_owned(),
        source_digest,
        evidence_digest,
    };

    let evidence = candidate_evidence_from_drawers(
        std::slice::from_ref(&candidate),
        &[source.clone(), target.clone()],
    )
    .unwrap();
    assert_eq!(evidence[0].candidate_id, "candidate_opaque");
    assert_eq!(evidence[0].source_memory_id, source_id);
    assert_eq!(evidence[0].source_excerpt.chars().count(), 512);
    assert_eq!(evidence[0].target_excerpt, "The launch window is Tuesday.");

    let duplicate = Drawer::new(source_id.to_uppercase(), "duplicate", "room", "test", 1, "model");
    assert!(candidate_evidence_from_drawers(
        std::slice::from_ref(&candidate),
        &[source.clone(), duplicate, target.clone()],
    )
    .is_err());

    let mut changed = source.clone();
    changed.content.push_str(" changed");
    assert!(candidate_evidence_from_drawers(
        std::slice::from_ref(&candidate),
        &[changed, target.clone()],
    )
    .is_err());

    let mut restricted = source;
    restricted.provenance = 63 << 30;
    assert!(candidate_evidence_from_drawers(&[candidate], &[restricted, target]).is_err());
}

#[test]
fn coordinator_hydration_resolves_uppercase_storage_spelling() {
    use genius_locus_kit::coordinator::EstateCoordinator;
    use locus_kit::{
        drawer::Drawer,
        drawer_store::{conflict_proposal_digests, DrawerStore},
        drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::OwnerCredentials,
    };

    let source_id = "aaaaaaaa-0000-4000-8000-000000000001";
    let target_id = "bbbbbbbb-0000-4000-8000-000000000002";
    let source = Drawer::new(source_id.to_uppercase(), "original source", "room", "test", 1, "model");
    let target = Drawer::new(target_id, "target", "room", "test", 2, "model");
    let renewal = "tier2:negation_asymmetry@1";
    let (source_digest, evidence_digest) = conflict_proposal_digests(&source, &target, 2, renewal);
    let candidate = V2ContradictionCandidate {
        candidate_id: "candidate_opaque".to_owned(),
        source_memory_id: source_id.to_owned(),
        target_memory_id: target_id.to_owned(),
        tier: 2,
        rule_or_cue_version: "negation_asymmetry@1".to_owned(),
        renewal_identity: renewal.to_owned(),
        source_digest,
        evidence_digest,
    };
    let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
    store.add_drawer(&source, 1).unwrap();
    store.add_drawer(&target, 2).unwrap();
    let coordinator = Arc::new(Mutex::new(EstateCoordinator::new()));
    let handle = coordinator
        .lock()
        .unwrap()
        .open(store.clone(), OwnerCredentials::new("owner"), 0, 100)
        .unwrap();

    let evidence = coordinator_candidate_evidence(
        &coordinator,
        &handle,
        std::slice::from_ref(&candidate),
    )
    .unwrap();
    assert_eq!(evidence[0].source_memory_id, source_id);
    assert_eq!(evidence[0].source_excerpt, "original source");

    let row_store = store.storage().expect("in-memory storage must be exposed").row_store();
    let mut duplicate = row_store
        .query("drawers", None, &[], None, None)
        .unwrap()
        .into_iter()
        .find(|row| row.get("id") == Some(&persistence_kit::types::TypedValue::Text(source_id.to_uppercase())))
        .expect("uppercase source row");
    duplicate.values.insert(
        "id".to_owned(),
        persistence_kit::types::TypedValue::Text(source_id.to_owned()),
    );
    assert!(row_store.insert("drawers", duplicate.values).is_err());
}


#[test]
fn v2_hunt_finds_older_contradiction_beyond_fifty_recent_probes() {
    let fixture_cue = substrate_ml::conflict_cue::evaluate(
        "North warehouse opening time is 08:00.",
        "North warehouse opening time is 09:00.");
    assert!(fixture_cue.kind.contradiction_tier().is_some(), "fixture has no supported lexical cue: {fixture_cue:?}");
    use genius_locus_kit::coordinator::EstateCoordinator;
    use locus_kit::{drawer_store_inmemory::InMemoryDrawerStore,
        estate_types::{OwnerCredentials, LatticeAnchor}, frames::CaptureFrame,
        drawer_operational::CaptureChannel};
    use persistence_kit::{Storage, inmemory::InMemoryStorage};
    use synapsekit::vector_store::VectorStore;
    use substrate_types::fingerprint256::Fingerprint256;
    let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
    let mut coordinator = EstateCoordinator::new();
    let handle = coordinator.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
    let vector_storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    vector_storage.open(&VectorStore::schema_declaration()).unwrap();
    let vectors = Arc::new(VectorStore::new(vector_storage, None));
    coordinator.register_vector_store(&handle, vectors.clone());
    let near = Fingerprint256::new(0, 0, 0, 0);
    let far = Fingerprint256::new(u64::MAX, u64::MAX, u64::MAX, u64::MAX);
    let mut claim_ids = Vec::new();
    for index in 0..53 {
        let content = match index {
            0 => "North warehouse opening time is 08:00.",
            1 => "North warehouse opening time is 09:00.",
            _ => "Unrelated archive shelf inventory.",
        };
        let frame = CaptureFrame::new(content, CaptureChannel::Typed, "Qualification",
            LatticeAnchor::new("004", None, None, None), "test", "minilm-v6");
        let drawer = coordinator.capture(&handle, frame, 1_700_000_000_000 + index).unwrap();
        vectors.add_vector(&drawer.id, if index < 2 { &near } else { &far },
            "minilm-v6", "1.0", 1_700_000_000_000 + index).unwrap();
        if index < 2 { claim_ids.push(drawer.id); }
    }
    let legacy = coordinator.tiered_contradiction_search(&handle, None, 50, "minilm-v6", 50, 1_700_000_100_000).unwrap();
    assert!(legacy.tier1.is_empty() && legacy.tier2.is_empty() && legacy.tier3.is_empty(), "control must exclude the old pair");
    let context = V2ContradictionAnalysisBinding { estate_id: Uuid::from_bytes(handle.estate_uuid), ..binding() };
    let findings = contradictions::hunt_from_coordinator(&Arc::new(Mutex::new(coordinator)),
        &handle, &context, 1, 1_700_000_100_000).unwrap();
    assert_eq!(findings.len(), 1, "v2 must discover the older pair while honoring result limit");
    let actual: std::collections::BTreeSet<_> = [findings[0].source_memory_id.clone(), findings[0].target_memory_id.clone()].into_iter().collect();
    assert_eq!(actual, claim_ids.into_iter().collect());
}
