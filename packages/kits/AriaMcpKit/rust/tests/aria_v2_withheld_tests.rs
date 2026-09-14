use aria_mcp::{dispatcher::Dispatcher, estate_posture::EstatePosture, estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCRequest, JsonValue}};
use locus_kit::{adjectives::AdjectiveSensitivity, drawer_operational::CaptureChannel,
    estate_types::LatticeAnchor, frames::{CaptureFrame, MutationKind}, filter::{RecallFrame, Filter, HydrationLevel},
    tunnel::Tunnel};
use serde_json::{json, Value};
use std::sync::Arc;
use corpus_kit::encoder::{SpanEncoder, EncoderModelSpec, EncoderError, PairScorer, CrossEncoderProfile};

struct WithheldSpanEncoder(EncoderModelSpec);
impl SpanEncoder for WithheldSpanEncoder {
    fn spec(&self) -> &EncoderModelSpec { &self.0 }
    fn encode_query(&self, _: &str) -> Result<Vec<f32>, EncoderError> { Ok(vec![1.0 / 384_f32.sqrt(); 384]) }
    fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError> {
        Ok(spans.iter().map(|_| vec![1.0 / 384_f32.sqrt(); 384]).collect())
    }
}
struct WithheldPairScorer(CrossEncoderProfile);
impl PairScorer for WithheldPairScorer {
    fn profile(&self) -> &CrossEncoderProfile { &self.0 }
    fn backend(&self) -> &str { "withheld-test" }
    fn score(&self, _: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> { Ok(vec![1.0; spans.len()]) }
}
// This fixture measures the explicit five-drawer graph, not the registry's
// automatically appended synthetic containment endpoints.
struct WithheldNoTopology;
impl genius_locus_kit::node_topology::NodeTopologyProvider for WithheldNoTopology {
    fn parent_id(&self, _: &str) -> Option<String> { None }
    fn child_ids(&self, _: &str) -> Vec<String> { vec![] }
    fn tree_edges(&self, _: Option<&[String]>) -> Vec<(String, String)> { vec![] }
}

fn call(dispatcher: &Dispatcher, name: &str, arguments: Value) -> Value {
    let request = JSONRPCRequest::decode(&json!({"jsonrpc":"2.0", "id":1,
        "method":"tools/call", "params":{"name":name,"arguments":arguments}})).unwrap();
    let response = serde_json::to_value(dispatcher.handle(&request)).unwrap();
    assert!(response.get("error").is_none(), "{name}: {response}");
    response["result"].clone()
}
fn check(dispatcher: &Dispatcher, name: &str, args: Value, expected: u64) {
    let off = call(dispatcher, name, args.clone());
    let mut args = args;
    args["report_withheld"] = json!(true);
    let on = call(dispatcher, name, args.clone());
    assert_eq!(on["isError"], false, "{name}: {on}");
    assert!(off["structuredContent"]["meta"].get("withheldBySensitivity").is_none());
    assert_eq!(on["structuredContent"]["meta"]["withheldBySensitivity"], expected, "{name}: {on}");
    assert_eq!(on["structuredContent"]["data"], off["structuredContent"]["data"], "{name}");
    args["report_withheld"] = json!(false);
    let explicit_off = call(dispatcher, name, args);
    assert!(explicit_off["structuredContent"]["meta"].get("withheldBySensitivity").is_none());
    assert_eq!(explicit_off["structuredContent"]["data"], off["structuredContent"]["data"]);
}

#[test]
fn report_withheld_shipping_v2() {
    const NOW: i64 = 1_780_000_000_000;
    let mut registry = EstateRegistry::new_inmemory();
    let handle = registry.default.handle.clone();
    let shared = registry.coord.clone();
    shared.lock().unwrap().register_node_topology(&handle, Arc::new(WithheldNoTopology));
    let mut ids = Vec::new();
    {
        let coordinator = shared.lock().unwrap();
        for index in 0..5 {
            let drawer = coordinator.capture(&handle, CaptureFrame::new(
                format!("withheld probe document {index} has distinct useful evidence"),
                CaptureChannel::Typed, "r", LatticeAnchor::udc("004"), "withheld-v2", "test-v1"), NOW + index).unwrap();
            ids.push(drawer.id);
        }
        let estate = coordinator.estate_for(&handle).unwrap();
        for (index, leaf) in ids.iter().enumerate().skip(1) {
            let mut tunnel = Tunnel::new(format!("edge-{index}"), "withheld-graph".into(), "r".into(),
                "withheld-graph".into(), "r".into(), "relates".into(), "withheld-v2".into(), NOW);
            tunnel.source_drawer_id = Some(ids[0].clone());
            tunnel.target_drawer_id = Some(leaf.clone());
            estate.add_tunnel(&tunnel).unwrap();
        }
        estate.mutate(&ids[0], MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted), None).unwrap();
        estate.mutate(&ids[1], MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted), None).unwrap();
    }
    let peer_id = registry.register_inmemory("withheld-peer");
    let peer = registry.resolve(&std::collections::BTreeMap::from([
        ("estateID".to_owned(), JsonValue::String(peer_id.to_string()))]), "estateID").unwrap().handle.clone();
    {
        use genius_locus_kit::{GrantOptions, GrantScope, CustodyMode, GrantLifetime, ReSharePermission};
        let mut coordinator = shared.lock().unwrap();
        let issued = coordinator.issue_grant(&peer, GrantOptions {
            grantee_estate_id: uuid::Uuid::from_bytes(handle.estate_uuid),
            scope: GrantScope::WholeEstate, custody_mode: CustodyMode::HandedOver,
            lifetime: GrantLifetime::Permanent, content_level: 48, re_share_permission: ReSharePermission::None,
        }, &[0xD1; 32], NOW as f64 / 1000.0).unwrap();
        coordinator.grant_store_mut(&peer).unwrap().set_budget(issued.grant.id, 1.0).unwrap();
        let mut capture = CaptureFrame::new("peer restricted probe", CaptureChannel::Typed,
            "r", LatticeAnchor::udc("004"), "withheld-v2", "test-v1");
        capture.sensitivity = AdjectiveSensitivity::Restricted;
        coordinator.capture(&peer, capture, NOW).unwrap();
    }
    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None)
        .with_posture(EstatePosture::Live);
    let ranked = call(&dispatcher, "moot_lens_keystones", json!({"wing":"withheld-graph","topK":"1"}));
    assert_eq!(ranked["structuredContent"]["data"]["keystones"][0]["id"], ids[0], "fixture must rank its restricted hub first");
    {
        let coordinator = shared.lock().unwrap();
        let frame = RecallFrame::new(vec![]);
        assert_eq!(coordinator.hydrate_with_sensitivity_count(&handle, &ids[..1], &frame).unwrap().withheld_by_sensitivity, 1);
    }
    let cases = [
        ("moot_recall_precise", json!({"query":"withheld probe"}), 2),
        ("moot_recall_shaped", json!({"query":"withheld probe"}), 2),
        ("moot_recall_connected", json!({"query":"withheld probe"}), 2),
        ("moot_recall_distilled", json!({"query":"withheld probe"}), 2),
        ("moot_recall_vague", json!({"query":"withheld probe"}), 0),
        ("moot_lens_partial_cue", json!({"anchor_memory_id":ids[2]}), 2),
        ("moot_lens_trust_synthesis", json!({}), 2),
        ("moot_lens_keystones", json!({"wing":"withheld-graph","topK":"1"}), 1),
        ("moot_lens_keystones", json!({"wing":"withheld-graph","topK":"5"}), 2),
        ("moot_federated_recall", json!({"filter":"unconfirmed","hydration_level":"full"}), 1),
    ];
    for (name, args, expected) in cases { check(&dispatcher, name, args, expected); }
    {
        let coordinator = shared.lock().unwrap();
        coordinator.withdraw(&handle, &ids[0], Some("obsolete"), NOW + 10).unwrap();
        let mut frame = RecallFrame::new(vec![]); frame.hydration_level = HydrationLevel::Full;
        let result = coordinator.hydrate_with_sensitivity_count(&handle, &ids, &frame).unwrap();
        assert_eq!(result.withheld_by_sensitivity, 1);
        assert!(!result.drawers.iter().any(|d| d.id == ids[0] || d.id == ids[1]));
        frame.filter_chain = vec![Filter::SensitivityAtMost(AdjectiveSensitivity::Secret)];
        assert_eq!(coordinator.hydrate_with_sensitivity_count(&handle, &ids, &frame).unwrap().withheld_by_sensitivity, 0);
    }
    check(&dispatcher, "moot_lens_keystones", json!({"wing":"withheld-graph","topK":"1"}), 0);
    let transcript = call(&dispatcher, "moot_memory_recall_transcript", json!({"query":"withheld probe","report_withheld":true}));
    assert_eq!(transcript["isError"], true);
    assert!(transcript["structuredContent"]["meta"].get("withheldBySensitivity").is_none());
    // Use real Synapse serving receipts; only inference is deterministic.
    {
        use genius_locus_kit::coordinator::EstateCoordinator;
        use genius_locus_kit::span_rerank::{encoder_spec_from_row, SpanEncoderQuerySeam, SynapseSpanVectorReader};
        use persistence_kit::inmemory::InMemoryStorage;
        use synapsekit::vector_store::{VectorStore, SpanVectorInput};
        let mut coordinator = shared.lock().unwrap();
        let content = "User: withheld transcript probe alpha beta gamma delta\nAssistant: retained evidence epsilon zeta eta theta";
        let drawer = coordinator.capture(&handle, CaptureFrame::new(content, CaptureChannel::Typed,
            "r", LatticeAnchor::udc("004"), "withheld-v2", "test-v1"), NOW + 20).unwrap();
        let corpus = Arc::new(corpus_kit::CorpusContentEngine::standalone_on(
            Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4())),
            vec![corpus_kit::EmbeddingModelConfig::Deterministic]).unwrap());
        corpus.ingest(content, &drawer.id, NOW).unwrap();
        coordinator.register_corpus(&handle, corpus);
        let vectors = Arc::new(VectorStore::open(Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()))).unwrap());
        let record = EstateCoordinator::default_encoder_model_row(true);
        let encoder: Arc<dyn SpanEncoder> = Arc::new(WithheldSpanEncoder(encoder_spec_from_row(&record)));
        coordinator.seed_default_encoder_model_if_absent(&handle).unwrap();
        coordinator.register_span_encoder(&handle, encoder.clone());
        coordinator.register_span_rerank(&handle, Arc::new(SpanEncoderQuerySeam(encoder)),
            Arc::new(SynapseSpanVectorReader(vectors.clone())), 30);
        coordinator.register_pair_scorer(&handle, Arc::new(WithheldPairScorer(CrossEncoderProfile::minilm_l6())));
        vectors.write_span_vectors(&drawer.id, &record.model_id, &record.model_version,
            &(0..3).map(|index| SpanVectorInput { index, int8: vec![1; 384], scale: 0.01,
                start_word: index as usize * 4, end_word: (index as usize + 1) * 4,
                content_version: genius_locus_kit::span_content_version::span_content_version(content),
            }).collect::<Vec<_>>(), NOW).unwrap();
    }
    // Like Swift, transcript supplies an explicit caller ceiling. The default-
    // ceiling-only count is zero even with the restricted candidate present.
    check(&dispatcher, "moot_memory_recall_transcript", json!({"query":"withheld transcript probe"}), 0);
    let help = call(&dispatcher, "moot_help", json!({"report_withheld":true}));
    assert!(help["structuredContent"]["meta"].get("withheldBySensitivity").is_none());
    let tools = aria_mcp::v2::catalog::selected_tools();
    assert!(tools.as_array().unwrap().iter().all(|op| op["inputSchema"]["properties"].get("report_withheld").is_none()));
    let artifact: Value = serde_json::from_str(include_str!("../../Registry/aria-v2-selected-release.json")).unwrap();
    assert_eq!(artifact["catalogIdentity"], aria_mcp::v2::catalog::selected_capability_digest());
    let fixture: Value = serde_json::from_str(include_str!("../../Tests/Conformance/global_modifiers_help_fixture.json")).unwrap();
    assert_eq!(fixture["expected"], aria_mcp::v2::help::GLOBAL_MODIFIERS_HELP_TEXT);

    // An otherwise-matching restricted candidate outside the requested wing
    // contributes zero; adding one inside that wing increments the count.
    let wing_arguments = json!({"query":"connected wing probe", "wing":"Withheld A"});
    {
        let coordinator = shared.lock().unwrap();
        for (wing, sensitivity) in [("Withheld A", AdjectiveSensitivity::Normal), ("Withheld B", AdjectiveSensitivity::Restricted)] {
            let mut capture = CaptureFrame::new("connected wing probe evidence", CaptureChannel::Typed,
                "r", LatticeAnchor::udc("004"), "withheld-v2", "test-v1");
            capture.wing = Some(wing.to_owned());
            capture.sensitivity = sensitivity;
            coordinator.capture(&handle, capture, NOW + 30).unwrap();
        }
    }
    check(&dispatcher, "moot_recall_connected", wing_arguments.clone(), 0);
    {
        let coordinator = shared.lock().unwrap();
        let mut capture = CaptureFrame::new("connected wing probe evidence", CaptureChannel::Typed,
            "r", LatticeAnchor::udc("004"), "withheld-v2", "test-v1");
        capture.wing = Some("Withheld A".to_owned());
        capture.sensitivity = AdjectiveSensitivity::Restricted;
        coordinator.capture(&handle, capture, NOW + 31).unwrap();
    }
    check(&dispatcher, "moot_recall_connected", wing_arguments, 1);
}
