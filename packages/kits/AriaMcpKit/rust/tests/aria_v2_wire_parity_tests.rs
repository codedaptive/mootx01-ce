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

// ---------------------------------------------------------------------------
// B1-B4 — Dense-field presence and security gate for moot_lens_keystones
//         and moot_lens_trust_synthesis via Dispatcher::handle.
//
// D1 established (commit c8e2c74): changing `if ids.is_empty()` to `if true`
// at lens_lower.rs structured_drawers_by_id makes every row carry no dense
// fields, yet the Rust suite was 951/0. These tests close that gap.
//
// B1: keystones admissible row carries subject + bestSpan + eventTime.
// B2: trust_synthesis admissible row carries subject + bestSpan + eventTime.
// B3: keystones restricted row carries only id + centrality.
// B4: trust_synthesis restricted row carries only id.
// B5: value parity for no-subject drawer and multiline content.
//     Both ports assert the SAME literals — "(no subject)" and "line one line two".
// ---------------------------------------------------------------------------

/// Seed a drawer directly (bypassing moot_file_memory which requires subject)
/// so that the drawer has no stored subject — subject debt.
/// Seed a drawer with no subject into the given wing.
/// CaptureFrame::new() sets wing: None (defaults to "Agentic Memory"), so
/// we set frame.wing explicitly so the drawer lands in the named wing and is
/// visible to moot_lens_keystones queries scoped to that wing.
fn seed_no_subject(registry: &EstateRegistry, content: &str, wing_name: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    let mut frame = locus_kit::frames::CaptureFrame::new(
        content, locus_kit::drawer_operational::CaptureChannel::Typed, "r",
        locus_kit::estate_types::LatticeAnchor::udc("000"), "test", "test-model",
    );
    frame.wing = Some(wing_name.to_owned());
    coord.capture(
        &registry.default.handle,
        frame,
        1_700_000_000_000,
    ).expect("capture no-subject").id
}

/// Seed a restricted-sensitivity drawer.
fn seed_restricted(registry: &EstateRegistry, content: &str, location: &str) -> String {
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::frames::MutationKind;
    let id = seed_no_subject(registry, content, location);
    {
        let coord = registry.coord.lock().unwrap();
        coord.mutate(
            &registry.default.handle, &id,
            MutationKind::CorrectSensitivity(AdjectiveSensitivity::Restricted), None,
        ).expect("correct sensitivity to Restricted");
    }
    id
}

// B1 — moot_lens_keystones admissible rows carry dense fields.
#[test]
fn lens_keystones_dense_fields_present_for_admissible_row() {
    // TRANSIENT: no charter drawers, so the node-topology provider has no
    // tree edges. recall_tunnels returns only stored tunnels, keeping the
    // keystones graph deterministic and containing only the drawers we seed.
    use aria_mcp::estate_registry::EstateOpening;
    let registry = EstateRegistry::new_inmemory_with(EstateOpening::TRANSIENT);
    // Seed two drawers into the same wing so hub has outbound tunnel degree.
    let hub_id = seed_no_subject(&registry, "hub-dense-b1", "b1-wing");
    let spoke_id = seed_no_subject(&registry, "spoke-dense-b1", "b1-wing");
    // Link hub → spoke so hub becomes a keystone.
    {
        use locus_kit::frames::TunnelCaptureFrame;
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        let mut frame = TunnelCaptureFrame::new(
            "b1-wing", "r", "b1-wing", "r", "relates", "test");
        frame.source_drawer_id = Some(hub_id.clone());
        frame.target_drawer_id = Some(spoke_id.clone());
        estate.capture_tunnel(frame, 1_700_000_000_000)
            .expect("tunnel capture");
    }

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let result = call(&dispatcher, "moot_lens_keystones", json!({ "wing": "b1-wing" }));
    assert!(is_success(&result), "keystones must succeed: {result}");

    let keystones = data(&result)["keystones"]
        .as_array()
        .expect("keystones array must be present");
    assert!(!keystones.is_empty(), "at least one keystone must be returned");

    // The hub is the only connected node — it must be the top keystone.
    let hub_row = keystones
        .iter()
        .find(|k| k["id"].as_str().map_or(false, |s| s.to_lowercase() == hub_id.to_lowercase()))
        .unwrap_or_else(|| panic!("hub must appear in keystones; got: {keystones:?}"));

    assert!(
        hub_row.get("subject").is_some(),
        "admissible keystone row must carry 'subject'; got: {hub_row}"
    );
    assert!(
        hub_row.get("bestSpan").is_some(),
        "admissible keystone row must carry 'bestSpan'; got: {hub_row}"
    );
    assert!(
        hub_row.get("eventTime").is_some(),
        "admissible keystone row must carry 'eventTime'; got: {hub_row}"
    );
}

// B2 — moot_lens_trust_synthesis admissible rows carry dense fields.
#[test]
fn lens_trust_synthesis_dense_fields_present_for_admissible_row() {
    let registry = EstateRegistry::new_inmemory();
    let id = seed_normal(&registry, "trust-dense-b2");

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let result = call(&dispatcher, "moot_lens_trust_synthesis", json!({}));
    assert!(is_success(&result), "trust_synthesis must succeed: {result}");

    let ranked = data(&result)["rankedIDs"]
        .as_array()
        .expect("rankedIDs array must be present");

    let row = ranked
        .iter()
        .find(|r| r["id"].as_str().map_or(false, |s| s.to_lowercase() == id.to_lowercase()))
        .unwrap_or_else(|| panic!("seeded drawer must appear in rankedIDs; got: {ranked:?}"));

    assert!(
        row.get("subject").is_some(),
        "admissible ranked row must carry 'subject'; got: {row}"
    );
    assert!(
        row.get("bestSpan").is_some(),
        "admissible ranked row must carry 'bestSpan'; got: {row}"
    );
    assert!(
        row.get("eventTime").is_some(),
        "admissible ranked row must carry 'eventTime'; got: {row}"
    );
}

// B3 — moot_lens_keystones restricted row carries only id + centrality.
#[test]
fn lens_keystones_restricted_row_has_no_dense_fields() {
    let registry = EstateRegistry::new_inmemory();
    let restricted_id = seed_restricted(&registry, "restricted-hub-b3", "b3-wing");
    let s1 = seed_no_subject(&registry, "spoke-b3-a", "b3-wing");
    let s2 = seed_no_subject(&registry, "spoke-b3-b", "b3-wing");
    // Link restricted hub → spokes so it becomes a keystone.
    {
        use locus_kit::frames::TunnelCaptureFrame;
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        for spoke_id in &[&s1, &s2] {
            let mut frame = TunnelCaptureFrame::new(
                "b3-wing", "r", "b3-wing", "r", "relates", "test");
            frame.source_drawer_id = Some(restricted_id.clone());
            frame.target_drawer_id = Some(spoke_id.to_string());
            estate.capture_tunnel(frame, 1_700_000_000_000)
                .expect("tunnel capture");
        }
    }

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let result = call(&dispatcher, "moot_lens_keystones", json!({ "wing": "b3-wing" }));
    assert!(is_success(&result), "keystones must succeed: {result}");

    let keystones = data(&result)["keystones"]
        .as_array()
        .expect("keystones array must be present");

    // The restricted hub may or may not appear in the ranked list. When it does,
    // it MUST carry only id and centrality — no dense fields (indistinguishability rule).
    for k in keystones {
        if k["id"].as_str().map_or(false, |s| s.to_lowercase() == restricted_id.to_lowercase()) {
            assert!(
                k.get("subject").is_none(),
                "restricted keystone must not expose 'subject'; got: {k}"
            );
            assert!(
                k.get("bestSpan").is_none(),
                "restricted keystone must not expose 'bestSpan'; got: {k}"
            );
            assert!(
                k.get("eventTime").is_none(),
                "restricted keystone must not expose 'eventTime'; got: {k}"
            );
            assert!(
                k.get("id").is_some(),
                "restricted keystone must still carry 'id'; got: {k}"
            );
            assert!(
                k.get("centrality").is_some(),
                "restricted keystone must still carry 'centrality'; got: {k}"
            );
        }
    }
}

// B4 — moot_lens_trust_synthesis restricted row carries only id.
#[test]
fn lens_trust_synthesis_restricted_row_has_no_dense_fields() {
    let registry = EstateRegistry::new_inmemory();
    let restricted_id = seed_restricted(&registry, "restricted-b4", "b4-wing");

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let result = call(&dispatcher, "moot_lens_trust_synthesis", json!({}));
    assert!(is_success(&result), "trust_synthesis must succeed: {result}");

    let ranked = data(&result)["rankedIDs"]
        .as_array()
        .expect("rankedIDs array must be present");

    // When the restricted row appears, it must carry only id.
    for r in ranked {
        if r["id"].as_str().map_or(false, |s| s.to_lowercase() == restricted_id.to_lowercase()) {
            assert!(
                r.get("subject").is_none(),
                "restricted ranked row must not expose 'subject'; got: {r}"
            );
            assert!(
                r.get("bestSpan").is_none(),
                "restricted ranked row must not expose 'bestSpan'; got: {r}"
            );
            assert!(
                r.get("eventTime").is_none(),
                "restricted ranked row must not expose 'eventTime'; got: {r}"
            );
            assert!(
                r.get("id").is_some(),
                "restricted ranked row must still carry 'id'; got: {r}"
            );
        }
    }
}

// B5 — Wire parity: no-subject drawer with multiline content.
//
// The exact literals here must match the Swift gate
// `parityNoSubjectAndMultilineContent` in LensToolsTests.swift.
// If either port changes these values, BOTH gates must be updated — the
// shared assertion is what makes this a parity test rather than two
// independent tests that happen to pass.
//
// subject: "(no subject)"     — NO_SUBJECT_MARKER (result_composer.rs:82)
// bestSpan: "line one line two" — normalize_value("line one\nline two")
#[test]
fn lens_parity_no_subject_and_multiline_content() {
    // TRANSIENT: same rationale as B1 — empty node tree keeps keystones
    // graph isolated to the drawers we explicitly seed.
    use aria_mcp::estate_registry::EstateOpening;
    let registry = EstateRegistry::new_inmemory_with(EstateOpening::TRANSIENT);
    // Content has an embedded newline. subject is None (CaptureFrame::new
    // sets subject: None), so candidate_from_drawer returns NO_SUBJECT_MARKER.
    let hub_id = seed_no_subject(&registry, "line one\nline two", "b5-wing");
    // Spokes are seeded into the same wing so hub has outbound tunnel degree.
    let s1 = seed_no_subject(&registry, "spoke-b5-a", "b5-wing");
    let s2 = seed_no_subject(&registry, "spoke-b5-b", "b5-wing");
    {
        // Add tunnels so hub accumulates centrality and is classified as a keystone.
        use locus_kit::frames::TunnelCaptureFrame;
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        for spoke_id in &[&s1, &s2] {
            let mut frame = TunnelCaptureFrame::new(
                "b5-wing", "r", "b5-wing", "r", "relates", "test");
            frame.source_drawer_id = Some(hub_id.clone());
            frame.target_drawer_id = Some(spoke_id.to_string());
            estate.capture_tunnel(frame, 1_700_000_000_000)
                .expect("tunnel b5");
        }
    }

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let result = call(&dispatcher, "moot_lens_keystones", json!({ "wing": "b5-wing" }));
    assert!(is_success(&result), "keystones must succeed: {result}");

    let keystones = data(&result)["keystones"]
        .as_array()
        .expect("keystones array");

    let hub_row = keystones
        .iter()
        .find(|k| k["id"].as_str().map_or(false, |s| s.to_lowercase() == hub_id.to_lowercase()))
        .unwrap_or_else(|| panic!("hub must appear in keystones; got: {keystones:?}"));

    // These exact literals must match the Swift gate. Change both or neither.
    assert_eq!(
        hub_row["subject"].as_str().unwrap_or(""),
        "(no subject)",
        "no-subject drawer must emit \"(no subject)\", not \"-\"; got: {:?}", hub_row["subject"]
    );
    assert_eq!(
        hub_row["bestSpan"].as_str().unwrap_or(""),
        "line one line two",
        "multiline content must normalize to a single line; got: {:?}", hub_row["bestSpan"]
    );
}
