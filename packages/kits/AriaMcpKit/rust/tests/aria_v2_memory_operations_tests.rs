//! Dormant qualification for the typed ARIA v2 core-memory slice.
//!
//! The selected-surface owner exposes `aria_mcp::v2` and enables this test with
//! `aria-v2`; this file must not wire the module or advertise the operations.


use std::sync::Mutex;

use aria_mcp::{
    sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger::SurfacedRecallLedger,
    v2::{
        core_memory::{run_file_memory, run_memory_get, run_memory_search, V2CompactMemory, V2CoreMemoryDependencies, V2CoreMemoryOperation, V2CoreMemoryService, V2Exportability, V2FiledMemory, V2FileMemoryRequest, V2FetchArguments, V2FetchReference, V2Memory, V2MemoryAuthorization, V2MemoryFailure, V2MemoryGetRequest, V2MemoryOperationContext, V2MemorySearchRequest, V2MemoryClock, V2MemorySearchResult, V2Placement, FILE_MEMORY_TOOL, MEMORY_GET_TOOL},
        operation::V2OperationEffect,
        render::V2ResultMeta,
    },
};
use serde_json::json;
use uuid::Uuid;

fn arguments(value: serde_json::Value) -> aria_mcp::jsonrpc::JsonValue { value.into() }

struct Clock;
impl V2MemoryClock for Clock { fn now_millis(&self) -> i64 { 1_700_000_000_123 } }
struct Allow;
impl V2MemoryAuthorization for Allow { fn authorize(&self, _: V2CoreMemoryOperation, _: &V2MemoryOperationContext) -> Result<(), V2MemoryFailure> { Ok(()) } }

#[derive(Default)] struct Fake { files: Mutex<Vec<V2FileMemoryRequest>>, searches: Mutex<Vec<V2MemorySearchRequest>>, gets: Mutex<Vec<V2MemoryGetRequest>> }
impl V2CoreMemoryService for Fake {
    fn file_memory(&self, _: &V2MemoryOperationContext, request: &V2FileMemoryRequest) -> Result<V2FiledMemory, V2MemoryFailure> { self.files.lock().unwrap().push(request.clone()); Ok(V2FiledMemory { memory_id: Uuid::parse_str("A0B1C2D3-E4F5-4678-9012-3456789ABCDE").unwrap(), placement: V2Placement { wing: "Agentic Memory".into(), room: request.location.clone() } }) }
    fn search_memories(&self, _: &V2MemoryOperationContext, request: &V2MemorySearchRequest) -> Result<V2MemorySearchResult, V2MemoryFailure> { self.searches.lock().unwrap().push(request.clone()); Ok(V2MemorySearchResult { rows: (0..3).map(|_| V2CompactMemory { memory_id: Uuid::parse_str("A0B1C2D3-E4F5-4678-9012-3456789ABCDE").unwrap(), subject: Some("retrieved".into()), score: Some(0.8), provenance: None, context: Some("😀".repeat(513)), excerpt: Some("🦀".repeat(513)), fetch: V2FetchReference { tool: MEMORY_GET_TOOL, arguments: V2FetchArguments { memory_id: "ignored".into() } } }).collect(), answer_block: None, degraded: false, span_rerank_registered: true }) }
    fn get_memories(&self, _: &V2MemoryOperationContext, request: &V2MemoryGetRequest) -> Result<Vec<V2Memory>, V2MemoryFailure> { self.gets.lock().unwrap().push(request.clone()); Ok(Vec::new()) }
}

fn dependencies<'a>(service: &'a Fake) -> V2CoreMemoryDependencies<'a> { static CLOCK: Clock = Clock; static AUTH: Allow = Allow; static LEDGER: std::sync::LazyLock<SensitivityGrantLedger> = std::sync::LazyLock::new(SensitivityGrantLedger::new); static SURFACED: std::sync::LazyLock<SurfacedRecallLedger> = std::sync::LazyLock::new(SurfacedRecallLedger::new); V2CoreMemoryDependencies { service, authorization: &AUTH, clock: &CLOCK, sensitivity_ledger: &LEDGER, surfaced_recall_ledger: &SURFACED, caller_identity: "test-host", meta: V2ResultMeta::incomplete("test", "digest", V2OperationEffect::Read) } }

#[test]
fn decoders_are_strict_and_preserve_typed_request_fields() {
    let bad = V2FileMemoryRequest::decode(&arguments(json!({"content":"x","subject":"s","location":"r","legacy":true}))).unwrap_err();
    assert_eq!(bad.path, "$.legacy");
    let request = V2FileMemoryRequest::decode(&arguments(json!({"content":"x","subject":"s","location":"r","exportability":"public","impatient":true,"estate_id":"A0B1C2D3-E4F5-4678-9012-3456789ABCDE"}))).unwrap();
    assert_eq!(request.exportability, Some(V2Exportability::Public));
    assert_eq!(request.estate_id.unwrap().to_string(), "a0b1c2d3-e4f5-4678-9012-3456789abcde");
    assert!(V2MemorySearchRequest::decode(&arguments(json!({"query":"x","near":"a0b1c2d3-e4f5-4678-9012-3456789abcde"}))).is_err());
    assert!(V2MemorySearchRequest::decode(&arguments(json!({}))).is_err());
    assert!(V2MemoryGetRequest::decode(&arguments(json!({"memory_id":"a0b1c2d3-e4f5-4678-9012-3456789abcde","memory_ids":["a0b1c2d3-e4f5-4678-9012-3456789abcde"]}))).is_err());
    assert!(V2MemoryGetRequest::decode(&arguments(json!({}))).is_err());
}

#[test]
fn direct_typed_service_calls_project_compact_rows_and_record_surface() {
    let fake = Fake::default();
    let result = run_memory_search(&arguments(json!({"query":"typed search","limit":1})), &dependencies(&fake)).unwrap();
    assert_eq!(fake.searches.lock().unwrap().len(), 1);
    assert_eq!(result["structuredContent"]["data"]["results"].as_array().unwrap().len(), 1);
    assert_eq!(result["structuredContent"]["data"]["results"][0]["memory_id"], "a0b1c2d3-e4f5-4678-9012-3456789abcde");
    assert_eq!(result["structuredContent"]["data"]["results"][0]["fetch"]["tool"], MEMORY_GET_TOOL);
    assert_eq!(result["structuredContent"]["data"]["results"][0]["context"].as_str().unwrap().chars().count(), 512);
    assert_eq!(result["structuredContent"]["data"]["results"][0]["excerpt"].as_str().unwrap().chars().count(), 512);
}

#[test]
fn filing_is_a_typed_call_and_hidden_or_missing_get_refuses_identically() {
    let fake = Fake::default();
    let filed = run_file_memory(&arguments(json!({"content":"durable","subject":"fact","location":"room"})), &dependencies(&fake)).unwrap();
    assert_eq!(fake.files.lock().unwrap().len(), 1);
    assert_eq!(filed["structuredContent"]["tool"], FILE_MEMORY_TOOL);
    let retained_id = filed["structuredContent"]["data"]["memory_id"].as_str().unwrap().to_owned();
    assert_eq!(filed["structuredContent"]["data"]["fetch"]["tool"], MEMORY_GET_TOOL);
    // A later readback refusal is operationally indistinguishable from absent,
    // but the successful filing receipt remains usable and no retry write occurs.
    let readback = run_memory_get(&arguments(json!({"memory_id":retained_id})), &dependencies(&fake)).unwrap();
    assert_eq!(readback["structuredContent"]["error"]["code"], "memory_not_found");
    assert_eq!(fake.files.lock().unwrap().len(), 1);
    let hidden = run_memory_get(&arguments(json!({"memory_id":"a0b1c2d3-e4f5-4678-9012-3456789abcde"})), &dependencies(&fake)).unwrap();
    let missing = run_memory_get(&arguments(json!({"memory_id":"00000000-0000-4000-8000-000000000000"})), &dependencies(&fake)).unwrap();
    assert_eq!(hidden["structuredContent"]["error"], missing["structuredContent"]["error"]);
    assert_eq!(hidden["structuredContent"]["error"]["code"], "memory_not_found");
}

/// Compact text for moot_file_memory must be "filed memory <uuid>" where the
/// UUID is the canonical lowercase representation of the assigned memory id.
/// Mirrors Swift AriaV2MemoryOperations.file() compact text format.
#[test]
fn file_memory_compact_text_carries_uuid() {
    let fake = Fake::default();
    let filed = run_file_memory(
        &arguments(json!({"content":"test-uuid-compact","subject":"s","location":"r"})),
        &dependencies(&fake),
    ).unwrap();
    let text = filed["content"][0]["text"].as_str()
        .expect("filed memory must carry content[0].text");
    let uuid_str = text.strip_prefix("filed memory ")
        .expect("compact text must start with 'filed memory '");
    Uuid::parse_str(uuid_str)
        .expect("compact text after 'filed memory ' must be a valid UUID");
    // Verify lowercase canonical format.
    assert_eq!(uuid_str, uuid_str.to_lowercase(), "UUID in compact text must be lowercase canonical");
}
