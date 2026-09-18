//! Typed v2 transcript recall only.  The in-memory estate has no activated
//! strict model, so this proves the required-rerank refusal without loading a
//! native model.


use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCRequest, JsonValue},
    v2::{
        operation::V2OperationEffect,
        render::V2ResultMeta,
        transcript_recall::{project_success, V2TranscriptRecallRequest},
    },
};
use cognition_kit::PreciseMatch;
use genius_locus_kit::cross_encoder_stage::StrictTranscriptEvidence;
use serde_json::json;
use uuid::Uuid;

fn dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA", "test", "test-build", None)
}

#[test]
fn request_validation_preserves_original_classifier_query() {
    let query = "  decision with caller spacing\n";
    let request = V2TranscriptRecallRequest::decode(&JsonValue::Object(
        [("query".to_owned(), JsonValue::String(query.to_owned()))]
            .into_iter()
            .collect(),
    )).unwrap();
    assert_eq!(request.query, query);
}

fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc":"2.0",
        "id":1,
        "method":"tools/call",
        "params":{"name":tool,"arguments":arguments},
    }))
    .expect("valid JSON-RPC request");
    serde_json::to_value(dispatcher.handle(&request))
        .expect("serializable response")
}

#[test]
fn transcript_decoder_is_strict_and_catalog_advertises_only_the_callable_handler() {
    let dispatcher = dispatcher();
    let tools_request = JSONRPCRequest::decode(&json!({
        "jsonrpc":"2.0", "id":1, "method":"tools/list",
    }))
    .expect("valid tools/list request");
    let tools = serde_json::to_value(dispatcher.handle(&tools_request)).expect("serializable response");
    assert!(tools["result"]["tools"].as_array().unwrap().iter().any(|tool| tool["name"] == "moot_memory_recall_transcript"));
    let error = call(&dispatcher, "moot_memory_recall_transcript", json!({"query":"x","legacy":true}));
    assert_eq!(error["error"]["code"], -32602, "unknown argument must be rejected by typed v2 decoder");
}

#[test]
fn unavailable_required_rerank_is_never_projected_as_generic_success() {
    let response = call(&dispatcher(), "moot_memory_recall_transcript", json!({"query":"meeting decision"}));
    assert_eq!(response["result"]["isError"], true);
    assert_eq!(response["result"]["structuredContent"]["tool"], "moot_memory_recall_transcript");
    assert_eq!(response["result"]["structuredContent"]["error"]["code"], "rerank_unavailable");
}

#[test]
fn typed_projection_preserves_drawer_uuid_fetch_reference_and_strict_evidence() {
    let memory_id = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();
    let response = project_success(
        vec![PreciseMatch {
            id: memory_id.to_string(),
            room: "ignored-at-v2-boundary".to_owned(),
            content: "transcript content".to_owned(),
            score: 0.75,
        }],
        StrictTranscriptEvidence {
            available: true,
            reason: None,
            active_model_id: Some("arctic-embed-s-w60".to_owned()),
            active_model_version: Some("e596f507467533e48a2e17c007f0e1dacc837b33".to_owned()),
            query_dimension: Some(384),
            fresh_head_candidates: 1,
            scored_head_candidates: 1,
            classifier_profile_id: Some("ms-marco-minilm-l6-cross-v1".to_owned()),
            classifier_model_revision: Some("233902d25c440f23af6f7d6e94d2946bac0bee0a".to_owned()),
            validated_pool_limit: Some(50),
            validated_head_limit: Some(30),
            validated_spans_limit: Some(3),
            validated_rrf_k: Some(60),
            serving_generation: Some(7),
            freshness_verified: true,
        },
        &V2ResultMeta::incomplete("test-build", "", V2OperationEffect::Read),
    )
    .expect("typed projection");
    assert_eq!(response["isError"], false);
    assert_eq!(response["structuredContent"]["data"]["matches"][0]["memory_id"], memory_id.to_string());
    assert_eq!(response["structuredContent"]["data"]["matches"][0]["excerpt"], "transcript content");
    assert_eq!(response["structuredContent"]["data"]["matches"][0]["fetch"]["tool"], "moot_memory_get");
    assert_eq!(response["structuredContent"]["data"]["matches"][0]["fetch"]["arguments"]["memory_id"], memory_id.to_string());
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["status"], "applied");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["policy_version"], "transcript_strict_v1");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["fresh_head_candidates"], 1);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["encoder_model_id"], "arctic-embed-s-w60");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["encoder_model_version"], "e596f507467533e48a2e17c007f0e1dacc837b33");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["classifier_profile"], "ms-marco-minilm-l6-cross-v1");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["classifier_model_revision"], "233902d25c440f23af6f7d6e94d2946bac0bee0a");
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["pool"], 50);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["head"], 30);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["spans"], 3);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["rrf_k"], 60);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["serving_generation"], 7);
    assert_eq!(response["structuredContent"]["data"]["strict_rerank"]["freshness_verified"], true);
}
