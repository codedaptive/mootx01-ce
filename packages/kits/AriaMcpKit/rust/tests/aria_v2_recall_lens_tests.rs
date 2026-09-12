
use std::{collections::BTreeMap, sync::{Arc, Mutex}};

use aria_mcp::{jsonrpc::JsonValue, v2::recall_lens::*};
use genius_locus_kit::{coordinator::EstateCoordinator, EstateHandle};
use locus_kit::{
    drawer::Drawer,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
    provenance::Sensitivity,
};
use uuid::Uuid;

const ESTATE: &str = "11111111-1111-4111-8111-111111111111";
const MEMORY: &str = "22222222-2222-4222-8222-222222222222";

fn uuid(value: &str) -> Uuid {
    Uuid::parse_str(value).unwrap()
}
fn arguments(entries: impl IntoIterator<Item = (&'static str, JsonValue)>) -> JsonValue {
    JsonValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

#[derive(Default)]
struct Authority {
    calls: Mutex<Vec<V2RecallLensOperation>>,
    reject_release: bool,
}
impl V2RecallLensAuthority for Authority {
    fn admit(
        &self,
        operation: V2RecallLensOperation,
        requested: Option<Uuid>,
    ) -> Result<V2RecallLensAdmission, ()> {
        assert!(requested.is_none() || requested == Some(uuid(ESTATE)));
        self.calls.lock().unwrap().push(operation);
        Ok(V2RecallLensAdmission {
            estate_id: uuid(ESTATE),
            estate_handle: EstateHandle::new([8; 16], 0, 0).unwrap(),
            caller_binding: "caller".to_owned(),
            authorization_generation: "g1".to_owned(),
            now_millis: 100,
        })
    }
    fn revalidate(&self, _: &V2RecallLensAdmission) -> Result<(), ()> {
        if self.reject_release {
            Err(())
        } else {
            Ok(())
        }
    }
}

struct Lower;
impl V2RecallLensLower for Lower {
    fn execute(
        &self,
        _: &V2RecallLensAdmission,
        request: &V2RecallLensRequest,
    ) -> Result<V2RecallLensResult, V2RecallLensError> {
        Ok(V2RecallLensResult {
            operation: request.operation,
            rows: vec![],
        })
    }
}

#[test]
fn frozen_recall_and_lens_grammars_preserve_exact_keys_and_types() {
    let precise = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallPrecise,
        &arguments([
            ("query", JsonValue::String("exact evidence".to_owned())),
            ("limit", JsonValue::Integer(5)),
            ("composition", JsonValue::String("text".to_owned())),
            ("estate_id", JsonValue::String(ESTATE.to_owned())),
        ]),
    )
    .unwrap();
    assert_eq!(
        precise.values.get("limit"),
        Some(&V2RecallLensValue::Integer(5))
    );

    let association = V2RecallLensRequest::decode(
        V2RecallLensOperation::LensFreeAssociation,
        &arguments([
            ("wing", JsonValue::String("Memory".to_owned())),
            ("seed_memory_id", JsonValue::String(MEMORY.to_owned())),
            ("walkLength", JsonValue::String("10000".to_owned())),
        ]),
    )
    .unwrap();
    assert_eq!(
        association.values.get("seed_memory_id"),
        Some(&V2RecallLensValue::Uuid(uuid(MEMORY)))
    );

    let unknown = V2RecallLensRequest::decode(
        V2RecallLensOperation::LensFreeAssociation,
        &arguments([
            ("wing", JsonValue::String("Memory".to_owned())),
            ("seedDrawerID", JsonValue::String(MEMORY.to_owned())),
        ]),
    )
    .unwrap_err();
    assert_eq!(unknown.path, "$.seedDrawerID");

    let non_positive = V2RecallLensRequest::decode(
        V2RecallLensOperation::LensConcepts,
        &arguments([("limit", JsonValue::Integer(0))]),
    )
    .unwrap_err();
    assert_eq!(non_positive.path, "$.limit");
}

#[test]
fn every_target_identity_is_read_only_and_never_routes_to_a_v1_name() {
    let operations = [
        V2RecallLensOperation::ListLenses,
        V2RecallLensOperation::ListRecipes,
        V2RecallLensOperation::RecallPrecise,
        V2RecallLensOperation::RecallTemporal,
        V2RecallLensOperation::RecallConnected,
        V2RecallLensOperation::RecallShaped,
        V2RecallLensOperation::RecallDistilled,
        V2RecallLensOperation::RecallVague,
        V2RecallLensOperation::RecallWalk,
        V2RecallLensOperation::LensKeystones,
        V2RecallLensOperation::LensConstellation,
        V2RecallLensOperation::LensFreeAssociation,
        V2RecallLensOperation::LensThemeWeather,
        V2RecallLensOperation::LensLatentThemes,
        V2RecallLensOperation::LensBias,
        V2RecallLensOperation::LensDrift,
        V2RecallLensOperation::LensNodeMotion,
        V2RecallLensOperation::LensCohesion,
        V2RecallLensOperation::LensContradiction,
        V2RecallLensOperation::LensTrustSynthesis,
        V2RecallLensOperation::LensPartialCue,
        V2RecallLensOperation::LensAnticipate,
        V2RecallLensOperation::LensSuccessors,
        V2RecallLensOperation::LensOverlap,
        V2RecallLensOperation::LensDivergence,
        V2RecallLensOperation::LensAssociations,
        V2RecallLensOperation::LensConcepts,
        V2RecallLensOperation::LensApriori,
        V2RecallLensOperation::LensMoment,
        V2RecallLensOperation::LensRhythm,
        V2RecallLensOperation::LensPrecedence,
        V2RecallLensOperation::LensComplexity,
    ];
    assert_eq!(operations.len(), 32);
    assert!(operations
        .iter()
        .all(|operation| operation.effect_is_read()));
    assert!(operations
        .iter()
        .all(|operation| operation.tool_name().starts_with("moot_")));
}

#[test]
fn typed_service_revalidates_before_releasing_a_result() {
    let request = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallVague,
        &arguments([("query", JsonValue::String("uncertain topic".to_owned()))]),
    )
    .unwrap();
    let success = V2RecallLensService::new(Authority::default(), Lower)
        .execute(request.clone())
        .unwrap();
    assert_eq!(success.operation, V2RecallLensOperation::RecallVague);

    let failure = V2RecallLensService::new(
        Authority {
            reject_release: true,
            ..Authority::default()
        },
        Lower,
    )
    .execute(request);
    assert_eq!(
        failure,
        Err(V2RecallLensError::OutcomeUnverified(
            V2RecallLensOperation::RecallVague
        ))
    );
}

#[test]
fn six_direct_recipe_adapters_keep_the_frozen_argument_grammar() {
    for operation in [
        V2RecallLensOperation::RecallTemporal,
        V2RecallLensOperation::RecallConnected,
        V2RecallLensOperation::RecallShaped,
        V2RecallLensOperation::RecallDistilled,
        V2RecallLensOperation::RecallVague,
        V2RecallLensOperation::RecallWalk,
    ] {
        let request = V2RecallLensRequest::decode(
            operation,
            &arguments([
                ("query", JsonValue::String("typed direct recall".to_owned())),
                ("limit", JsonValue::Integer(3)),
            ]),
        )
        .unwrap();
        assert_eq!(request.operation, operation);
        assert_eq!(
            request.values.get("limit"),
            Some(&V2RecallLensValue::Integer(3))
        );
    }

    let temporal_unknown = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallTemporal,
        &arguments([
            ("query", JsonValue::String("q".to_owned())),
            ("legacy", JsonValue::Bool(true)),
        ]),
    )
    .unwrap_err();
    assert_eq!(temporal_unknown.path, "$.legacy");
}

#[test]
fn direct_recipe_projection_has_no_legacy_rendered_payload_field() {
    let projection = V2RecipeRecallData {
        results: vec![serde_json::json!({"id": MEMORY, "retrievalSource": "walk"})],
        metadata: Some(
            serde_json::json!({"walk": {"stage": "stage1_session_hybrid", "stoppedEarly": true}}),
        ),
    };
    let value = serde_json::to_value(projection).unwrap();
    assert!(value["results"].is_array());
    assert_eq!(value["capabilities"]["walk"]["stoppedEarly"], true);
    assert!(value.get("metadata").is_none());
    assert!(value.get("text").is_none());
    assert!(value.get("content").is_none());
}

#[test]
fn recipe_projection_uses_swift_canonical_temporal_capability_shape() {
    let projection = V2RecipeRecallData {
        results: vec![serde_json::json!({"id": MEMORY, "eventTime": "2026-03-15T10:00:00Z"})],
        metadata: Some(serde_json::json!({"temporal": {
            "mode": "tight", "source": "explicit", "grab": "dated",
            "from": "2026-03-01T00:00:00Z", "to": "2026-03-31T23:59:59Z", "widenedDays": 2
        }})),
    };
    let value = serde_json::to_value(projection).unwrap();
    assert_eq!(value["capabilities"]["temporal"]["source"], "explicit");
    assert_eq!(value["capabilities"]["temporal"]["widenedDays"], 2);
    assert!(value["results"][0].get("inWindow").is_none());
    assert!(value["results"][0].get("padDays").is_none());
}

#[test]
fn recipe_projection_nests_discrimination_under_capabilities() {
    let value = serde_json::to_value(V2RecipeRecallData {
        results: vec![],
        metadata: Some(serde_json::json!({"discrimination": "medium"})),
    })
    .unwrap();
    assert_eq!(value["capabilities"]["discrimination"], "medium");
    assert!(value.get("metadata").is_none());
}

#[test]
fn v2_projection_fails_closed_on_raw_provenance_sensitivity() {
    fn drawer(raw: i64) -> Drawer {
        let mut drawer = Drawer::new("row", "private body", "room", "test", 0, "test");
        drawer.provenance = raw << 30;
        drawer.subject = Some("private subject".to_owned());
        drawer.ssc_facts = Some("private facts".to_owned());
        drawer
    }
    for raw in [0, 16] {
        let row = v2_candidate_from_drawer(&drawer(raw));
        assert_eq!(row.subject.as_deref(), Some("private subject"));
        assert_eq!(row.best_span.as_deref(), Some("private body"));
    }
    for (raw, marker) in [
        (32, "[sensitivity: restricted — content redacted]"),
        (48, "[sensitivity: secret — content access requires explicit grant]"),
    ] {
        let row = v2_candidate_from_drawer(&drawer(raw));
        assert_eq!(row.subject.as_deref(), Some(marker));
        assert!(row.best_span.is_none() && row.ssc_facts.is_none() && row.distilled.is_none() && row.representation.is_none());
        assert!(row.content.is_none() && row.extents.is_none() && row.exemplars.is_none());
    }
    let unknown = v2_candidate_from_drawer(&drawer(63));
    assert!(unknown.subject.is_none());
    assert!(unknown.best_span.is_none() && unknown.ssc_facts.is_none() && unknown.distilled.is_none() && unknown.representation.is_none());
    assert!(unknown.content.is_none() && unknown.extents.is_none() && unknown.exemplars.is_none());
}

#[test]
fn execute_distilled_recall_does_not_restore_filtered_raw_body() {
    const NOW: i64 = 1_700_000_000;
    let mut coordinator = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coordinator
        .open(store, OwnerCredentials::new("v2-recall-lens-test"), 0, i64::MAX)
        .expect("open estate");
    coordinator.seed_default_wings(&handle, NOW).expect("seed wings");
    let mut frame = CaptureFrame::new(
        "private-distilled-probe body must not be returned",
        CaptureChannel::Typed,
        "notes",
        LatticeAnchor::udc("0"),
        "v2-recall-lens-test",
        "test-v1",
    );
    frame.provenance_sensitivity = Sensitivity::Restricted;
    let id = coordinator.capture(&handle, frame, NOW).expect("capture").id;
    let request = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallDistilled,
        &arguments([("query", JsonValue::String("private-distilled-probe".to_owned()))]),
    )
    .expect("request");

    let data = execute_distilled_recall(&coordinator, &handle, &request, NOW + 1)
        .expect("distilled recall");
    let row = data.results.iter()
        .find(|row| row["id"].as_str() == Some(id.as_str()))
        .expect("restricted row");
    assert_eq!(row["subject"].as_str(), Some("[sensitivity: restricted — content redacted]"));
    assert!(row.get("distilled").is_none(), "result leaked distilled body: {row}");
    assert!(row.get("representation").is_none(), "result leaked representation: {row}");
}

fn call(dispatcher: &aria_mcp::dispatcher::Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = aria_mcp::jsonrpc::JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": tool, "arguments": arguments}
    }))
    .unwrap();
    serde_json::to_value(dispatcher.handle(&request)).unwrap()
}

/// Five distinct bodies on the registry's default estate; the fourth carries
/// secret provenance, so the v2 projection withholds its body and it must
/// count on neither side of the savings figure. Charters are not seeded, so
/// every row the probe query returns is one of these captured records.
fn savings_probe_estate() -> (aria_mcp::estate_registry::EstateRegistry, BTreeMap<String, &'static str>, String) {
    const NOW: i64 = 1_700_000_000;
    let registry = aria_mcp::estate_registry::EstateRegistry::new_inmemory_with(
        aria_mcp::estate_registry::EstateOpening { federate: false, seed_charters: false },
    );
    let bodies = [
        "savings-probe alpha: the reactor schedule moved to March and Sarah approved the reactor plan.",
        "savings-probe beta: vendor contracts were renewed in Geneva and every term held.",
        "savings-probe gamma: travel policy updates landed and flights now require approval.",
        "savings-probe delta: this secret body must never reach either token sum.",
        "savings-probe epsilon: the quarterly forecast covers revenue targets and team velocity.",
    ];
    let mut body_by_id = BTreeMap::new();
    let mut secret_id = String::new();
    {
        let coordinator = registry.default.coord.lock().unwrap();
        for (index, body) in bodies.iter().enumerate() {
            let mut frame = CaptureFrame::new(
                *body, CaptureChannel::Typed, "notes", LatticeAnchor::udc("0"),
                "v2-recall-lens-test", "test-v1",
            );
            if index == 3 {
                frame.provenance_sensitivity = Sensitivity::Secret;
            }
            let id = coordinator.capture(&registry.default.handle, frame, NOW).expect("capture").id;
            if index == 3 {
                secret_id = id.clone();
            }
            body_by_id.insert(id, *body);
        }
    }
    (registry, body_by_id, secret_id)
}

#[test]
fn execute_distilled_recall_reports_savings_over_emitted_rows_only() {
    use genius_locus_kit::hydration_representation::estimated_token_count;
    let (registry, body_by_id, secret_id) = savings_probe_estate();
    let request = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallDistilled,
        &arguments([
            ("query", JsonValue::String("savings-probe".to_owned())),
            ("limit", JsonValue::Integer(100)),
        ]),
    )
    .expect("request");
    let data = {
        let coordinator = registry.default.coord.lock().unwrap();
        execute_distilled_recall(&coordinator, &registry.default.handle, &request, 1_700_000_001)
            .expect("distilled recall")
    };
    let value = serde_json::to_value(&data).unwrap();
    let distillation = &value["capabilities"]["distillation"];
    assert!(distillation.is_object(), "distillation missing: {value}");

    // Expected sums: the estimator over the emitted distilled strings and over
    // the captured bodies of those same rows, joined by id.
    let mut expected_returned: i64 = 0;
    let mut expected_original: i64 = 0;
    let mut secret_row_seen = false;
    for row in &data.results {
        let id = row["id"].as_str().expect("row id");
        if id == secret_id {
            secret_row_seen = true;
            assert!(row.get("distilled").is_none(), "the secret row must carry no distilled body: {row}");
            continue;
        }
        let Some(distilled) = row["distilled"].as_str() else { continue };
        let body = body_by_id.get(id).expect("every emitted distilled row is a captured record");
        expected_returned += estimated_token_count(distilled);
        expected_original += estimated_token_count(body);
    }
    assert!(secret_row_seen, "the secret row is present in results: {value}");
    assert!(expected_returned > 0, "the probe query must return distilled bodies: {value}");
    assert_eq!(distillation["returnedTokens"], serde_json::json!(expected_returned), "{distillation}");
    assert_eq!(distillation["originalTokens"], serde_json::json!(expected_original), "{distillation}");
    assert_eq!(distillation["estimated"], serde_json::json!(true));
    assert_eq!(distillation["estimator"], serde_json::json!(cognition_kit::ESTIMATOR_NAME));
    assert!(distillation.get("skim").is_none(), "skim must be absent: {distillation}");
    let display = distillation["display"].as_str().expect("display").to_owned();
    assert!(display.starts_with("\u{1F331} Distilled: ~"), "{display}");

    // The selected surface appends the display line to the compact text.
    let dispatcher = aria_mcp::dispatcher::Dispatcher::new(registry, "test", "test", "test", None);
    let response = call(&dispatcher, "moot_recall_distilled", serde_json::json!({"query": "savings-probe", "limit": 100}));
    assert_eq!(response["result"]["isError"], false, "{response}");
    let text = response["result"]["content"][0]["text"].as_str().expect("compact text");
    assert!(text.ends_with(&format!("\n{display}")), "compact text must end with the display line: {text}");
    assert_eq!(response["result"]["structuredContent"]["data"]["capabilities"]["distillation"]["display"], serde_json::json!(display));
}

#[test]
fn execute_distilled_recall_with_no_rows_still_reports_the_zero_distillation_object() {
    let registry = aria_mcp::estate_registry::EstateRegistry::new_inmemory_with(
        aria_mcp::estate_registry::EstateOpening { federate: false, seed_charters: false },
    );
    let request = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallDistilled,
        &arguments([("query", JsonValue::String("savings-probe".to_owned()))]),
    )
    .expect("request");
    let data = {
        let coordinator = registry.default.coord.lock().unwrap();
        execute_distilled_recall(&coordinator, &registry.default.handle, &request, 1_700_000_001)
            .expect("distilled recall")
    };
    assert!(data.results.is_empty(), "an estate with no drawers returns no rows");
    let value = serde_json::to_value(&data).unwrap();
    let zero = "\u{1F331} Distilled: ~0 tokens returned vs ~0 original \u{00B7} ~0 saved (0%)";
    assert_eq!(value["capabilities"]["distillation"]["returnedTokens"], serde_json::json!(0));
    assert_eq!(value["capabilities"]["distillation"]["originalTokens"], serde_json::json!(0));
    assert_eq!(value["capabilities"]["distillation"]["display"], serde_json::json!(zero));
    let dispatcher = aria_mcp::dispatcher::Dispatcher::new(registry, "test", "test", "test", None);
    let response = call(&dispatcher, "moot_recall_distilled", serde_json::json!({"query": "savings-probe"}));
    assert_eq!(response["result"]["isError"], false, "{response}");
    // The selected surface appends the coaching hint for a zero-result lens
    // after the distillation display line, so the compact text is checked as
    // a prefix and the remainder must be that hint line or nothing.
    let text = response["result"]["content"][0]["text"].as_str().expect("compact text");
    let expected = format!("Returned 0 typed recall result(s).\n{zero}");
    let rest = text.strip_prefix(&expected).unwrap_or_else(|| panic!("compact text: {text}"));
    assert!(rest.is_empty() || rest.starts_with("\nhint: "), "unexpected tail: {rest}");
}

#[test]
fn execute_precise_recall_carries_no_distillation() {
    let (registry, _, _) = savings_probe_estate();
    let request = V2RecallLensRequest::decode(
        V2RecallLensOperation::RecallPrecise,
        &arguments([("query", JsonValue::String("savings-probe".to_owned()))]),
    )
    .expect("request");
    let data = {
        let coordinator = registry.default.coord.lock().unwrap();
        execute_precise_recall(&coordinator, &registry.default.handle, &request, 1_700_000_001)
            .expect("precise recall")
    };
    let value = serde_json::to_value(&data).unwrap();
    assert!(value["capabilities"].get("distillation").is_none(), "{value}");
    let dispatcher = aria_mcp::dispatcher::Dispatcher::new(registry, "test", "test", "test", None);
    let response = call(&dispatcher, "moot_recall_precise", serde_json::json!({"query": "savings-probe"}));
    assert_eq!(response["result"]["isError"], false, "{response}");
    let text = response["result"]["content"][0]["text"].as_str().expect("compact text");
    assert!(!text.contains('\u{1F331}'), "{text}");
}
