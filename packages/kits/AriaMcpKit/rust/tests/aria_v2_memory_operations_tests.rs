//! Dormant qualification for the typed ARIA v2 core-memory slice.
//!
//! The selected-surface owner exposes `aria_mcp::v2` and enables this test with
//! `aria-v2`; this file must not wire the module or advertise the operations.

mod test_support;

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
    fn search_memories(&self, _: &V2MemoryOperationContext, request: &V2MemorySearchRequest) -> Result<V2MemorySearchResult, V2MemoryFailure> { self.searches.lock().unwrap().push(request.clone()); Ok(V2MemorySearchResult { rows: (0..3).map(|_| V2CompactMemory { memory_id: Uuid::parse_str("A0B1C2D3-E4F5-4678-9012-3456789ABCDE").unwrap(), subject: Some("abcdefghijklmnopqrstuvwxyz".repeat(23) + "ab"), score: Some(0.8), provenance: None, context: Some("😀".repeat(513)), excerpt: Some("🦀".repeat(513)), fetch: V2FetchReference { tool: MEMORY_GET_TOOL, arguments: V2FetchArguments { memory_id: "ignored".into() } } }).collect(), answer_block: None, degraded: false, span_rerank_registered: true }) }
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

/// Calls `run_memory_search` directly with a `Fake` whose `search_memories`
/// returns rows carrying a 600-char subject and a 513-emoji context, then
/// asserts that the serialization loop in `execute_memory_search` caps both at
/// 512 scalars.  The loop added `compact_text` to the subject branch to match
/// the already-present context branch; this test goes RED before that addition.
///
/// The context fixture is emoji so the cap is also shown to count Unicode
/// scalars rather than UTF-8 bytes.  Subject and context therefore carry
/// different text here, and this test does not assert they are identical: the
/// synthesis twin and both Swift tests cover that invariant.
///
/// Uses the `Fake` service directly rather than the production filing door so
/// the test bypasses `DrawerStore.subjectLengthContract` (120 chars), which
/// would otherwise reject any subject longer than 120 chars.
#[test]
fn compact_row_subject_and_context_are_both_capped_at_512_scalars() {
    use aria_mcp::v2::render;

    let base = "abcdefghijklmnopqrstuvwxyz";
    let long_subject: String = base.repeat(23) + "ab"; // 23 × 26 + 2 = 600 chars
    assert_eq!(long_subject.chars().count(), 600, "precondition: subject is 600 chars");

    // Fake.search_memories returns rows with a 600-char subject (and emoji context).
    // run_memory_search passes them through the serialization loop which must apply
    // compact_text to subject (and already did so for context).
    let fake = Fake::default();
    let result = run_memory_search(
        &arguments(json!({"query": "compact-512-form", "limit": 1})),
        &dependencies(&fake),
    ).unwrap();

    let rows = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("search must return a results array");
    assert!(!rows.is_empty(), "serialization loop must return at least one row");

    let subject = rows[0]["subject"].as_str()
        .expect("compact search row must carry a subject field");
    let context = rows[0]["context"].as_str()
        .expect("compact search row must carry a context field");
    let compact = render::compact_text(&long_subject);

    assert_eq!(subject.chars().count(), 512,
        "subject must be truncated to 512 scalars by the serialization loop");
    assert_eq!(subject, compact.as_str(),
        "subject must equal the 512-scalar compact form of the 600-char input");
    // context carries emoji so the strings differ, but both must be capped at 512.
    assert_eq!(context.chars().count(), 512,
        "context must be truncated to 512 scalars by the serialization loop");
}

#[test]
fn search_row_context_carries_the_filed_subject() {
    use std::collections::BTreeMap;
    use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};
    use test_support::SelectedV2Session;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let subject = "the drawer subject that context must carry";

    // File the memory through the production door so the real search path is
    // exercised end-to-end, including record(for:) which wires the context field.
    let mut file_args = BTreeMap::new();
    file_args.insert("content".to_owned(), JsonValue::String(subject.to_owned()));
    file_args.insert("subject".to_owned(), JsonValue::String(subject.to_owned()));
    file_args.insert("location".to_owned(), JsonValue::String("context-field-tests".to_owned()));
    let filed = session.call("moot_file_memory", &file_args)
        .expect("filing through the production door must succeed");
    assert_eq!(filed["isError"], serde_json::json!(false), "file: {filed:?}");

    let mut search_args = BTreeMap::new();
    search_args.insert("query".to_owned(), JsonValue::String(subject.to_owned()));
    let result = session.call("moot_memory_search", &search_args)
        .expect("search must dispatch");
    assert_eq!(result["isError"], serde_json::json!(false), "search: {result:?}");

    let rows = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("search must return a results array");
    assert!(!rows.is_empty(), "search must return at least one row for the filed subject");
    assert_eq!(
        rows[0]["context"].as_str(),
        Some(subject),
        "compact search row must carry the drawer subject in the context field; got: {:?}",
        rows[0]["context"],
    );
}
