//! Wire parity gate — four Rust-port divergences from Swift.
//!
//! A1 — sensitivity_ceiling() defaults to Normal; must default to Elevated.
//! A2 — tunnels key absent at depth:full when no tunnels linked; must be [].
//! A3 — TunnelKind wire strings use Debug format instead of camelCase.
//! A4 — refused_sibling_memory_ids absent from partial-erase JSON.
//!
//! Every test drives the full v2 route:
//!   Dispatcher::handle → surface::execute → lower
//!
//! Tests FAIL against unmodified code and PASS after the corresponding fix.

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};
use locus_kit::{
    adjectives::Trust,
    drawer_operational::CaptureChannel,
    estate_types::LatticeAnchor,
    frames::{CaptureFrame, MutationKind},
};
use serde_json::json;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn call(dispatcher: &Dispatcher, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": tool, "arguments": arguments }
    })).expect("test request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

fn data(result: &serde_json::Value) -> &serde_json::Value {
    &result["result"]["structuredContent"]["data"]
}

fn is_success(result: &serde_json::Value) -> bool {
    result["result"]["isError"] == serde_json::json!(false)
}

fn file_api(dispatcher: &Dispatcher, content: &str, sensitivity: Option<&str>) -> String {
    let mut args = json!({ "content": content, "subject": content, "location": "wire-parity-tests" });
    if let Some(s) = sensitivity {
        args["sensitivity"] = json!(s);
    }
    let result = call(dispatcher, "moot_file_memory", args);
    assert!(is_success(&result), "file_memory must succeed: {result}");
    data(&result)["memory_id"].as_str().expect("memory_id").to_owned()
}

fn link_api(dispatcher: &Dispatcher, from: &str, to: &str, relationship: &str) {
    let result = call(dispatcher, "moot_link_memories", json!({
        "from_id": from, "to_id": to, "relationship": relationship,
    }));
    assert!(is_success(&result), "link must succeed for {relationship}: {result}");
}

fn get_full(dispatcher: &Dispatcher, memory_id: &str) -> serde_json::Value {
    let result = call(dispatcher, "moot_memory_get", json!({
        "memory_id": memory_id, "depth": "full",
    }));
    assert!(is_success(&result), "memory_get must succeed: {result}");
    data(&result)["memories"][0].clone()
}

fn get_depth(dispatcher: &Dispatcher, memory_id: &str, depth: &str) -> serde_json::Value {
    let result = call(dispatcher, "moot_memory_get", json!({
        "memory_id": memory_id, "depth": depth,
    }));
    assert!(is_success(&result), "memory_get at {depth} must succeed: {result}");
    data(&result)["memories"][0].clone()
}

fn seed_normal(registry: &EstateRegistry, content: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    coord.capture(
        &registry.default.handle,
        CaptureFrame::new(
            content, CaptureChannel::Typed, "wire-parity-tests",
            LatticeAnchor::udc("000"), "test", "test-model",
        ),
        1_700_000_000_000,
    ).expect("capture").id
}

// ---------------------------------------------------------------------------
// A1 — sensitivity_ceiling() must default to Elevated, not Normal.
//
// load_tunnels() filters out Elevated-endpoint tunnels when the ceiling is
// Normal (raw 0 < raw 16). Swift defaults ceiling to .elevated (raw 16) so
// Elevated endpoints pass. The Rust code defaults to Normal — the bug.
//
// Without the fix: Elevated endpoint tunnel is filtered → tunnels empty →
// length assertion fails.
// ---------------------------------------------------------------------------

#[test]
fn sensitivity_ceiling_defaults_to_elevated_so_elevated_endpoint_tunnels_appear() {
    // Seed the Normal-sensitivity source before handing the registry to the
    // Dispatcher (the source id is needed for the get_full call later).
    let registry = EstateRegistry::new_inmemory();
    let source_id = seed_normal(&registry, "Source — Normal sensitivity.");
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let target_id = file_api(&dispatcher, "Target — Elevated sensitivity.", Some("elevated"));
    link_api(&dispatcher, &source_id, &target_id, "references");

    let mem = get_full(&dispatcher, &source_id);
    let tunnels = mem["tunnels"].as_array()
        .expect("tunnels key must be present at depth:full");
    assert_eq!(
        tunnels.len(), 1,
        "Elevated-endpoint tunnel must appear when ceiling defaults to Elevated; \
         got tunnels = {:?}", mem["tunnels"]
    );
}

// ---------------------------------------------------------------------------
// A2 — depth:full must emit "tunnels": [] when no tunnels are linked.
//
// Current: Vec<V2TunnelRow> + skip_serializing_if = "Vec::is_empty" silently
// drops the key. Fix: Option<Vec<…>> + skip_serializing_if = "Option::is_none"
// so depth:full with no tunnels emits Some([]) → "tunnels": [].
// ---------------------------------------------------------------------------

#[test]
fn depth_full_always_emits_tunnels_key_even_when_no_tunnels_linked() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let id = file_api(&dispatcher, "Isolated — no tunnels.", None);
    let mem = get_full(&dispatcher, &id);

    assert_eq!(
        mem["tunnels"], json!([]),
        "depth:full must emit 'tunnels': [] when no tunnels linked; got: {:?}", mem["tunnels"]
    );
}

#[test]
fn depth_full_emits_tunnels_key_when_tunnels_are_linked() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let a = file_api(&dispatcher, "A with tunnel.", None);
    let b = file_api(&dispatcher, "B with tunnel.", None);
    link_api(&dispatcher, &a, &b, "references");
    let mem = get_full(&dispatcher, &a);
    assert_eq!(
        mem["tunnels"].as_array().map(|v| v.len()),
        Some(1),
        "depth:full with one tunnel must emit one-element array; got: {:?}", mem["tunnels"]
    );
}

#[test]
fn depth_subject_carries_no_tunnels_key() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let a = file_api(&dispatcher, "A subject test.", None);
    let b = file_api(&dispatcher, "B subject test.", None);
    link_api(&dispatcher, &a, &b, "references");
    let mem = get_depth(&dispatcher, &a, "subject");
    assert!(
        mem.get("tunnels").is_none(),
        "depth:subject must carry no tunnels key; got: {:?}", mem.get("tunnels")
    );
}

#[test]
fn depth_distilled_carries_no_tunnels_key() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let a = file_api(&dispatcher, "A distilled test.", None);
    let b = file_api(&dispatcher, "B distilled test.", None);
    link_api(&dispatcher, &a, &b, "references");
    let mem = get_depth(&dispatcher, &a, "distilled");
    assert!(
        mem.get("tunnels").is_none(),
        "depth:distilled must carry no tunnels key; got: {:?}", mem.get("tunnels")
    );
}

// ---------------------------------------------------------------------------
// A3 — TunnelKind wire strings must be camelCase in both wire paths.
//
// estate_memory.rs bug: format!("{:?}", t.kind).to_lowercase()
//   → "derivesfrom", "respondsto" (hump-flattened)
// knowledge_journal.rs bug: format!("{:?}", t.kind)
//   → "References", "DerivesFrom" (Pascal case, not lowercased)
//
// Canonical wire set (Swift String(describing:)):
//   supersedes references blocks validates contradicts
//   derivesFrom covers elaborates respondsTo
//
// Tested on both paths:
//   1. moot_memory_get depth:full → estate_memory.rs → tunnels[].kind
//   2. moot_connection_search     → knowledge_journal.rs → edges[].kind
// ---------------------------------------------------------------------------

/// (relationship input, expected wire value)
const RELATIONSHIP_KINDS: &[(&str, &str)] = &[
    ("supersedes",   "supersedes"),
    ("references",   "references"),
    ("blocks",       "blocks"),
    ("validates",    "validates"),
    ("contradicts",  "contradicts"),
    ("derives_from", "derivesFrom"),
    ("covers",       "covers"),
    ("elaborates",   "elaborates"),
    ("responds_to",  "respondsTo"),
];

#[test]
fn tunnel_kind_wire_strings_in_memory_get_are_camelcase() {
    for (relationship, expected) in RELATIONSHIP_KINDS {
        let registry = EstateRegistry::new_inmemory();
        let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
        let a = file_api(&dispatcher, &format!("A-get-{}", relationship), None);
        let b = file_api(&dispatcher, &format!("B-get-{}", relationship), None);
        link_api(&dispatcher, &a, &b, relationship);

        let mem = get_full(&dispatcher, &a);
        let tunnels = mem["tunnels"].as_array()
            .unwrap_or_else(|| panic!("tunnels key must be present for {}", relationship));
        assert_eq!(tunnels.len(), 1, "expected one tunnel for {}", relationship);
        let actual = tunnels[0]["kind"].as_str()
            .unwrap_or_else(|| panic!("kind must be string for {}", relationship));
        assert_eq!(
            actual, *expected,
            "memory_get tunnel kind for '{}' must be '{}' got '{}'",
            relationship, expected, actual
        );
    }
}

#[test]
fn tunnel_kind_wire_strings_in_connection_search_are_camelcase() {
    for (relationship, expected) in RELATIONSHIP_KINDS {
        let registry = EstateRegistry::new_inmemory();
        let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
        let a = file_api(&dispatcher, &format!("A-cs-{}", relationship), None);
        let b = file_api(&dispatcher, &format!("B-cs-{}", relationship), None);
        link_api(&dispatcher, &a, &b, relationship);

        let result = call(&dispatcher, "moot_connection_search", json!({
            "memory_id": a, "direction": "outgoing", "limit": 10,
        }));
        assert!(is_success(&result), "connection_search must succeed for {}: {result}", relationship);
        let edges = data(&result)["edges"].as_array()
            .unwrap_or_else(|| panic!("edges must be present for {}", relationship));
        assert_eq!(edges.len(), 1, "expected one edge for {}", relationship);
        let actual = edges[0]["kind"].as_str()
            .unwrap_or_else(|| panic!("kind must be string in edge for {}", relationship));
        assert_eq!(
            actual, *expected,
            "connection_search edge kind for '{}' must be '{}' got '{}'",
            relationship, expected, actual
        );
    }
}

// ---------------------------------------------------------------------------
// A4 — refused_sibling_memory_ids must appear in erase JSON.
//
// Bug: surface.rs None branch (lines 684-689) omits the key. Swift emits it
// unconditionally (AriaV2MemoryMutations.swift:347) — [] on full erase,
// populated on partial erase.
// ---------------------------------------------------------------------------

#[test]
fn full_erase_emits_refused_sibling_ids_as_empty_array() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let id = file_api(&dispatcher, "Full-erase target — no siblings.", None);
    let result = call(&dispatcher, "moot_erase_memory", json!({
        "memory_id": id, "confirmation": true,
    }));
    assert!(is_success(&result), "full erase must not be isError; got: {result}");

    let d = data(&result);
    let refused = d["refused_sibling_memory_ids"].as_array()
        .unwrap_or_else(|| panic!(
            "refused_sibling_memory_ids must be present in full-erase JSON; got data = {d}"
        ));
    assert!(refused.is_empty(), "full erase must emit []; got: {:?}", refused);
}

#[test]
fn partial_erase_emits_refused_sibling_ids_with_refused_id() {
    let registry = EstateRegistry::new_inmemory();
    let now: i64 = 1_700_000_000_000;

    // Seed D1 (accepted) and D2 (active draft, same lineage) before Dispatcher
    // takes ownership of the registry.
    let (d1_id, d2_id) = {
        let coord = registry.coord.lock().expect("coord lock");

        let d1 = coord.capture(
            &registry.default.handle,
            CaptureFrame::new(
                "D1 — accepted sibling (refused on partial erase).",
                CaptureChannel::Typed, "wire-parity-tests",
                LatticeAnchor::udc("000"), "test", "test-model",
            ),
            now,
        ).expect("capture D1");

        coord.mutate(
            &registry.default.handle, &d1.id,
            MutationKind::CorrectTrust(Trust::Canonical), None,
        ).expect("correct trust");
        coord.mutate(
            &registry.default.handle, &d1.id,
            MutationKind::Accept, None,
        ).expect("accept D1");

        let mut d2_frame = CaptureFrame::new(
            "D2 — active draft, same lineage (erase target).",
            CaptureChannel::Typed, "wire-parity-tests",
            LatticeAnchor::udc("000"), "test", "test-model",
        );
        d2_frame.lineage_id = Some(d1.lineage_id);
        let d2 = coord.capture(&registry.default.handle, d2_frame, now + 100)
            .expect("capture D2");

        (d1.id, d2.id)
    };

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

    let result = call(&dispatcher, "moot_erase_memory", json!({
        "memory_id": d2_id, "confirmation": true,
        "reason": "wire-parity-partial-erase-test",
    }));
    assert!(is_success(&result), "partial erase must not be isError; got: {result}");

    let d = data(&result);
    assert_eq!(
        d["outcome"].as_str().unwrap_or(""),
        "erased_partially",
        "outcome must be erased_partially; got: {:?}", d["outcome"]
    );

    let refused = d["refused_sibling_memory_ids"].as_array()
        .unwrap_or_else(|| panic!(
            "refused_sibling_memory_ids must be present in partial-erase JSON; got data = {d}"
        ));
    assert!(!refused.is_empty(), "refused list must be non-empty; got: {:?}", refused);
    assert!(
        refused.iter().any(|v| v.as_str().map_or(false, |s| s.to_lowercase() == d1_id.to_lowercase())),
        "refused list must contain D1 id ({d1_id}); got: {:?}", refused
    );
}
