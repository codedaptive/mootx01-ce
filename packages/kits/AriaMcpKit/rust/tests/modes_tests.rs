//! Modes dispatch tests and golden-pin coaching fixture test.
//!
//! ## Coverage
//!
//!   A. Unknown mode name: fail-open (no Err, hint appended)
//!   B. Unknown variant: fail-open (no Err, hint appended)
//!   C. ModeDeclaration parser: recognized names, variants, and unknowns
//!   D. Golden-pin: PeriodicCoach::render_block produces byte-identical output
//!      to the Swift port for the shared fixture snapshot
//!   E. Coaching cadence: should_coach fires at multiples of coaching_calls_x
//!   F. Sticky Recall=Auto sets answer override for moot_memory_search
//!   G. mode: arg appears in every tool's inputSchema
//!
//!   H. Dispatcher wire-text: exactly one "hint:" for unknown mode (double-prefix gate)
//!   I. Sticky recall e2e: Recall=Auto on call 1 → moot_memory_search call 2 inherits auto
//!
//!   P. Provisioned modes config dispatched from estate manifest:
//!      P1: sticky_enabled=false → declaration accepted, no sticky state stored.
//!      P2: coaching_calls=0 → should_coach never fires across 30 calls.
//!      P3: coaching_calls=2 → should_coach fires at call 2 but not call 1
//!          (discriminating: fails if hardcoded constant 25 is still in effect).
//!
//! Parity: mirrors Swift ModesDispatchTests.swift and PeriodicCoachTests.swift.

use std::fs;
use std::path::Path;

use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
    mode_registry::{ModeDeclaration, MootMode, RecallVariant},
    mode_session_state::{CoachingSnapshot, ModeSessionState},
    periodic_coach::render_block,
    tool_list::build_tool_list,
};
use genius_locus_kit::coordinator::ModesManifest;

fn make_dispatcher() -> Dispatcher {
    // OBSTACLE 3: build_advisory (6th arg) was removed in v2A; pass 5 args only.
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
}

/// Build a `Dispatcher` with a provisioned `ModesManifest` applied to the default
/// estate BEFORE the dispatcher is constructed. This exercises the full wiring path:
/// `Dispatcher::tools_call` reads `provisioned_modes_config` on the first call
/// and applies it via `ModeSessionState::apply_preferences`.
///
/// Mirrors Swift's `ProvisionedModesConfigDispatchTests.makeProvisionedDispatcher`.
fn make_provisioned_dispatcher(sticky_enabled: bool, coaching_calls: usize) -> Dispatcher {
    let registry = EstateRegistry::new_inmemory();
    let config = ModesManifest { sticky_enabled, coaching_calls };
    registry
        .coord
        .lock()
        .expect("coordinator lock")
        .provision_modes_config(&registry.default.handle, &config)
        .expect("provision_modes_config must succeed on in-memory estate");
    // OBSTACLE 3: build_advisory (6th arg) was removed in v2A; pass 5 args only.
    Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None)
}

fn tools_call_response(dispatcher: &Dispatcher, tool_name: &str, args_json: serde_json::Value) -> serde_json::Value {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": args_json
        }
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    let response = dispatcher.handle(&request);
    serde_json::to_value(&response).expect("response must serialize")
}

fn response_text(response: &serde_json::Value) -> &str {
    response["result"]["content"][0]["text"].as_str().unwrap_or("")
}

// MARK: - A. Unknown mode name: fail-open

#[test]
fn unknown_mode_name_is_fail_open() {
    // Modes are handled at the Dispatcher level (not in dispatch_tool).
    // Here we test ModeDeclaration directly.
    let decl = ModeDeclaration::parse("Quantum");
    assert!(decl.recognized_mode().is_none(), "Unknown mode should not be recognized");
    let hint = decl.unknown_hint();
    assert!(hint.is_some(), "Unknown mode should produce a hint");
    let hint_text = hint.unwrap();
    assert!(hint_text.contains("Quantum"), "Hint should mention the unknown mode name");
    // The bare message must NOT contain a "hint:" prefix — the dispatcher's
    // append_hint_to_result adds the prefix when embedding in wire text.
    // Embedding a pre-prefixed string causes double "hint: hint: …" on the wire.
    assert!(!hint_text.starts_with("hint:"), "unknown_hint must return bare text, not 'hint:'-prefixed text");
}

// MARK: - B. Unknown variant: fail-open

#[test]
fn unknown_variant_is_fail_open() {
    let decl = ModeDeclaration::parse("Recall=Telepathy");
    assert_eq!(decl.recognized_mode(), Some(MootMode::Recall), "Recall should be recognized");
    assert!(decl.recognized_recall_variant().is_none(), "Unknown variant should not be recognized");
    let hint = decl.unknown_hint();
    assert!(hint.is_some(), "Unknown variant should produce a hint");
    assert!(hint.unwrap().contains("Telepathy"), "Hint should mention the unknown variant");
}

// MARK: - C. ModeDeclaration parsing

#[test]
fn mode_declaration_parse_bare_name() {
    let decl = ModeDeclaration::parse("Recall");
    assert_eq!(decl.mode_name, "Recall");
    assert!(decl.variant.is_none());
    assert_eq!(decl.recognized_mode(), Some(MootMode::Recall));
    assert!(decl.recognized_recall_variant().is_none(), "Bare name clears variant");
    assert!(decl.unknown_hint().is_none(), "Bare recognized name produces no hint");
}

#[test]
fn mode_declaration_parse_recall_auto() {
    let decl = ModeDeclaration::parse("Recall=Auto");
    assert_eq!(decl.mode_name, "Recall");
    assert_eq!(decl.variant.as_deref(), Some("Auto"));
    assert_eq!(decl.recognized_recall_variant(), Some(RecallVariant::Auto));
    assert!(decl.unknown_hint().is_none(), "Recognized variant produces no hint");
}

#[test]
fn mode_declaration_parse_recall_rows() {
    let decl = ModeDeclaration::parse("Recall=Rows");
    assert_eq!(decl.recognized_recall_variant(), Some(RecallVariant::Rows));
    assert_eq!(decl.recognized_recall_variant().unwrap().answer_mode_raw_value(), "never");
}

#[test]
fn mode_declaration_parse_recall_answer() {
    let decl = ModeDeclaration::parse("Recall=Answer");
    assert_eq!(decl.recognized_recall_variant(), Some(RecallVariant::Answer));
    assert_eq!(decl.recognized_recall_variant().unwrap().answer_mode_raw_value(), "always");
}

#[test]
fn all_five_modes_recognized() {
    for (raw, expected) in &[
        ("Recall", MootMode::Recall),
        ("Filing", MootMode::Filing),
        ("Lenses", MootMode::Lenses),
        ("Vault", MootMode::Vault),
        ("Curator", MootMode::Curator),
    ] {
        let decl = ModeDeclaration::parse(raw);
        assert_eq!(decl.recognized_mode().as_ref(), Some(expected),
                   "Mode {} should be recognized", raw);
    }
}

// MARK: - D. Golden-pin (shared with Swift)

#[test]
fn golden_pin_coaching_fixture() {
    // Resolve the fixture path relative to this source file's location.
    // #file in Rust tests returns something like:
    //   /path/to/AriaMcpKit/rust/tests/modes_tests.rs
    // The fixture is at:
    //   /path/to/AriaMcpKit/Tests/Conformance/modes_coaching_fixture.json
    // Walk up to find the AriaMcpKit/ directory by looking for the rust/ component.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    // CARGO_MANIFEST_DIR = .../AriaMcpKit/rust
    let fixture_path = Path::new(&manifest_dir)
        .parent()   // AriaMcpKit/
        .unwrap()
        .join("Tests/Conformance/modes_coaching_fixture.json");

    let data = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Failed to read fixture at {}: {}", fixture_path.display(), e));

    let parsed: serde_json::Value = serde_json::from_str(&data)
        .expect("Fixture JSON must be valid");

    let snap_json = parsed.get("snapshot").expect("Fixture must have 'snapshot'");
    let expected_block = parsed.get("expected_block")
        .and_then(|v| v.as_str())
        .expect("Fixture must have 'expected_block'");

    // Build the CoachingSnapshot from the fixture's JSON.
    let total_calls = snap_json["totalCalls"].as_u64().unwrap() as usize;

    let tool_counts: std::collections::HashMap<String, usize> = snap_json["toolCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let bigram_counts: std::collections::HashMap<String, usize> = snap_json["bigramCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let mode_attribution_counts: std::collections::HashMap<String, usize> =
        snap_json["modeAttributionCounts"]
            .as_object()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
            .unwrap_or_default();

    let snapshot = CoachingSnapshot {
        total_calls,
        tool_counts,
        bigram_counts,
        mode_attribution_counts,
    };

    let actual = render_block(&snapshot);

    assert_eq!(
        actual, expected_block,
        "Golden-pin mismatch.\nExpected:\n{}\n\nActual:\n{}",
        expected_block, actual
    );
}

// MARK: - E. Coaching cadence

#[test]
fn should_coach_fires_at_cadence() {
    let state = ModeSessionState::new();
    state.set_coaching_calls_x(5);

    // Fire 4 calls — no coaching.
    for _ in 0..4 {
        state.record_call("moot_estate_status", None);
        assert!(!state.should_coach(), "should_coach must be false before cadence");
    }

    // 5th call triggers coaching.
    state.record_call("moot_estate_status", None);
    assert!(state.should_coach(), "should_coach must be true at cadence");
}

#[test]
fn should_coach_false_when_disabled() {
    let state = ModeSessionState::new();
    state.set_coaching_calls_x(0); // 0 = off
    for _ in 0..50 {
        state.record_call("moot_estate_status", None);
    }
    assert!(!state.should_coach(), "Coaching must be off when coaching_calls_x == 0");
}

/// Gate (W1): the coaching block must stay within a ~80-token budget.
///
/// Token estimation: LLM tokenizers average ~4-6 bytes/token for English prose.
/// 80 tokens * 6 bytes = 480 bytes; we use 500 bytes as the limit. Mirrors
/// Swift test `coachingBlockUnderTokenCap`.
///
/// How it fails if reverted: a template expansion producing multi-paragraph output
/// or a very long Modes line would exceed 500 bytes and the assert fires before
/// the regression ships.
#[test]
fn coaching_block_under_token_cap() {
    let mut tool_counts = std::collections::HashMap::new();
    tool_counts.insert("moot_memory_search".to_string(), 40);
    tool_counts.insert("moot_memory_get".to_string(), 20);
    tool_counts.insert("moot_file_memory".to_string(), 15);
    tool_counts.insert("moot_confirm_memory".to_string(), 8);
    tool_counts.insert("moot_file_fact".to_string(), 7);
    tool_counts.insert("moot_estate_status".to_string(), 5);
    tool_counts.insert("moot_list_lenses".to_string(), 5);
    let mut bigram_counts = std::collections::HashMap::new();
    bigram_counts.insert("moot_memory_search→moot_memory_get".to_string(), 18);
    let mut mode_attr = std::collections::HashMap::new();
    mode_attr.insert("Recall".to_string(), 60);
    mode_attr.insert("Filing".to_string(), 25);
    mode_attr.insert("Lenses".to_string(), 10);
    mode_attr.insert("Vault".to_string(), 5);
    let snapshot = CoachingSnapshot {
        total_calls: 100,
        tool_counts,
        bigram_counts,
        mode_attribution_counts: mode_attr,
    };
    let block = render_block(&snapshot);
    let byte_len = block.len();
    assert!(
        byte_len <= 500,
        "Coaching block must stay ≤ 500 bytes (~80 tokens); got {} bytes:\n{}",
        byte_len, block
    );
}

// MARK: - F. Sticky Recall=Auto sets answer override

#[test]
fn sticky_recall_auto_sets_answer_override() {
    let state = ModeSessionState::new();
    let decl = ModeDeclaration::parse("Recall=Auto");
    state.record_call("moot_estate_status", Some(&decl));

    let answer = state.sticky_recall_answer_mode();
    assert_eq!(answer, Some("auto"), "Recall=Auto sticky should map to answer:auto");
}

#[test]
fn sticky_recall_rows_sets_answer_never() {
    let state = ModeSessionState::new();
    let decl = ModeDeclaration::parse("Recall=Rows");
    state.record_call("moot_estate_status", Some(&decl));
    assert_eq!(state.sticky_recall_answer_mode(), Some("never"));
}

#[test]
fn sticky_bare_recall_clears_variant() {
    let state = ModeSessionState::new();
    // Set variant first.
    let decl_variant = ModeDeclaration::parse("Recall=Answer");
    state.record_call("moot_estate_status", Some(&decl_variant));
    assert_eq!(state.sticky_recall_answer_mode(), Some("always"));

    // Bare Recall clears variant.
    let decl_bare = ModeDeclaration::parse("Recall");
    state.record_call("moot_estate_status", Some(&decl_bare));
    assert_eq!(state.sticky_recall_answer_mode(), None, "Bare Recall must clear variant");
}

#[test]
fn non_recall_mode_produces_no_answer_override() {
    let state = ModeSessionState::new();
    let decl = ModeDeclaration::parse("Filing");
    state.record_call("moot_estate_status", Some(&decl));
    assert_eq!(state.sticky_recall_answer_mode(), None,
               "Non-Recall mode must not set an answer override");
}

// MARK: - G. mode: arg in every tool's inputSchema

#[test]
#[ignore = "BLOCKED: v2 tool schemas do not inject the mode argument; build_tool_list returns v2 schemas without mode. This is v1-only behavior. Awaiting catalog decision. Do not delete; do not weaken to pass."]
fn mode_arg_in_every_tool_schema() {
    let tools = build_tool_list();
    let tools_arr = tools.as_array().expect("build_tool_list must return an array");
    let missing: Vec<&str> = tools_arr
        .iter()
        .filter(|tool| {
            tool.get("inputSchema")
                .and_then(|s| s.get("properties"))
                .and_then(|p| p.as_object())
                .map(|props| !props.contains_key("mode"))
                .unwrap_or(true)
        })
        .filter_map(|tool| tool.get("name").and_then(|n| n.as_str()))
        .collect();

    assert!(
        missing.is_empty(),
        "Tools missing 'mode' in schema: {}",
        missing.join(", ")
    );
}

// MARK: - W4. Unrecognized mode must not clobber valid sticky state

/// Gate (W4 ruling): an unrecognized mode declaration is IGNORED ENTIRELY —
/// it must NOT replace a prior valid sticky declaration.
///
/// How it fails if reverted: record_call sets sticky_declaration for any recognized
/// or unrecognized mode, so "QuantumUnknown" would overwrite "Recall=Auto" and
/// the assertion fires.
#[test]
fn unknown_mode_does_not_clobber_sticky_state() {
    let state = ModeSessionState::new();

    // Declare a valid mode first.
    let valid_decl = ModeDeclaration::parse("Recall=Auto");
    state.record_call("moot_estate_status", Some(&valid_decl));
    assert_eq!(state.sticky_recall_answer_mode(), Some("auto"),
               "Valid Recall=Auto must be set as sticky");

    // Declare an unrecognized mode — must NOT overwrite the valid sticky state.
    let unknown_decl = ModeDeclaration::parse("QuantumUnknown");
    state.record_call("moot_estate_status", Some(&unknown_decl));
    assert_eq!(
        state.sticky_recall_answer_mode(), Some("auto"),
        "Valid sticky must survive an unrecognized mode declaration; \
         unrecognized modes must be IGNORED ENTIRELY (ruling W4)"
    );
}

// MARK: - D2. Golden-pin tiebreak (shared with Swift)

/// Gate: when two modes have equal attribution count, the sort is ascending by
/// mode name (Filing < Recall). Without the tiebreak, HashMap iteration order
/// is non-deterministic and the modes line order would vary between runs.
#[test]
fn golden_pin_tie_fixture() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .unwrap()
        .join("Tests/Conformance/modes_coaching_tie_fixture.json");

    let data = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Failed to read tie fixture at {}: {}", fixture_path.display(), e));

    let parsed: serde_json::Value = serde_json::from_str(&data)
        .expect("Tie fixture JSON must be valid");

    let snap_json = parsed.get("snapshot").expect("Tie fixture must have 'snapshot'");
    let expected_block = parsed.get("expected_block")
        .and_then(|v| v.as_str())
        .expect("Tie fixture must have 'expected_block'");

    let total_calls = snap_json["totalCalls"].as_u64().unwrap() as usize;

    let tool_counts: std::collections::HashMap<String, usize> = snap_json["toolCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let bigram_counts: std::collections::HashMap<String, usize> = snap_json["bigramCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let mode_attribution_counts: std::collections::HashMap<String, usize> =
        snap_json["modeAttributionCounts"]
            .as_object()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
            .unwrap_or_default();

    let snapshot = CoachingSnapshot {
        total_calls,
        tool_counts,
        bigram_counts,
        mode_attribution_counts,
    };

    let actual = render_block(&snapshot);

    assert_eq!(
        actual, expected_block,
        "Tiebreak golden-pin mismatch.\nExpected:\n{}\n\nActual:\n{}",
        expected_block, actual
    );
}

/// Golden-pin: template-5 with a genuine two-mode tie (Filing=3, Recall=3).
///
/// Verifies the name-ascending tiebreak in `top_mode` selects Filing over Recall
/// (F < R), producing "Focused Filing session" in the block. Without the tiebreak
/// fix `HashMap::iter().max_by_key()` is non-deterministic and could emit either
/// mode, causing intermittent cross-port parity failures.
///
/// Both Swift and Rust ports assert against the same
/// `modes_coaching_template5_tie_fixture.json` fixture.
///
/// Mirrors Swift test `goldenPinTemplate5TieFixtureBlock`.
#[test]
fn golden_pin_template5_tie_fixture() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .unwrap()
        .join("Tests/Conformance/modes_coaching_template5_tie_fixture.json");

    let data = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Failed to read template-5 tie fixture at {}: {}", fixture_path.display(), e));

    let parsed: serde_json::Value = serde_json::from_str(&data)
        .expect("Template-5 tie fixture JSON must be valid");

    let snap_json = parsed.get("snapshot").expect("Fixture must have 'snapshot'");
    let expected_block = parsed.get("expected_block")
        .and_then(|v| v.as_str())
        .expect("Fixture must have 'expected_block'");

    let total_calls = snap_json["totalCalls"].as_u64().unwrap() as usize;

    let tool_counts: std::collections::HashMap<String, usize> = snap_json["toolCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let bigram_counts: std::collections::HashMap<String, usize> = snap_json["bigramCounts"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
        .unwrap_or_default();

    let mode_attribution_counts: std::collections::HashMap<String, usize> =
        snap_json["modeAttributionCounts"]
            .as_object()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_u64().unwrap() as usize)).collect())
            .unwrap_or_default();

    let snapshot = CoachingSnapshot {
        total_calls,
        tool_counts,
        bigram_counts,
        mode_attribution_counts,
    };

    let actual = render_block(&snapshot);

    assert_eq!(
        actual, expected_block,
        "Template-5 tie golden-pin mismatch — Filing must win over Recall (name-ascending tiebreak).\nExpected:\n{}\n\nActual:\n{}",
        expected_block, actual
    );
}

// MARK: - H. Dispatcher wire-text: exactly one "hint:" for unknown mode

/// Gate: unknown mode → wire text must NOT contain "hint: hint:" double prefix.
///
/// Before the fix, Rust's unknown_hint() embedded "hint: " in the returned
/// string AND append_hint_to_result prepended "hint: " again, producing
/// "hint: hint: mode ..." on the wire. This test fails if that regression
/// is re-introduced.
///
/// Note: the static ARIA protocol block itself contains "hint:" in the line
///   "— Watch for hint: lines in responses …"
/// so the total count of "hint:" in the response is 2 when the fix is correct
/// (1 from the protocol block + 1 from the unknown-mode hint line). The double-
/// prefix bug produces 3 (protocol block + "hint: hint: …"). The test asserts
/// absence of the double prefix rather than a fixed count.
///
/// How it fails if reverted: unknown_hint() returns "hint: …", dispatcher wraps
/// it as "hint: hint: …" — the double prefix appears and contains() returns true.
#[test]
#[ignore = "BLOCKED: v2 decode rejects the mode argument (v2/codec.rs reject_unknown_fields). Awaiting a catalog decision. Do not delete; do not weaken to pass."]
fn unknown_mode_wire_text_has_no_double_hint_prefix() {
    let dispatcher = make_dispatcher();
    // Use moot_estate_status with an unknown mode arg — the cheapest call that
    // goes through the full dispatcher (mode decode → dispatch → hint append).
    let response = tools_call_response(
        &dispatcher,
        "moot_estate_status",
        serde_json::json!({ "mode": "QuantumNonExistentMode" }),
    );
    let text = response_text(&response);
    // The response must contain at least one "hint:" (from the appended unknown-mode line).
    assert!(text.contains("hint:"), "wire text must contain a hint for unknown mode; got: {text}");
    // The double-prefix bug produces "hint: hint: …" — assert it is absent.
    assert!(
        !text.contains("hint: hint:"),
        "wire text must NOT contain double 'hint: hint:' prefix — \
         unknown_hint() must return bare text, not 'hint:'-prefixed text. \
         wire text:\n{text}"
    );
    // The hint must mention the unknown mode name so we know a hint was actually appended.
    assert!(
        text.contains("QuantumNonExistentMode"),
        "wire text must mention the unknown mode name in the appended hint; got: {text}"
    );
}

// MARK: - I0. answer:never with no mode declared: same shape as pre-modes default

/// Mirrors Swift `ModesDispatchTests.answerNeverWithNoModeIsUnchanged` (lines 86-109).
///
/// Gate: explicit `answer:"never"` and no-arg call both produce a response that
/// contains "found" or "memories" in the text (the row-listing path) and does NOT
/// contain an "answer:" synthesis block header. This ensures the answer:never fast
/// path is stable and that the default (no sticky mode set) behaves identically.
///
/// How it fails if reverted: if the no-arg call path accidentally synthesises
/// (returning an "answer: ..." block), the second assertion fires.
#[test]
#[ignore = "BLOCKED: Rust v2 accepts answer: as allowed field but Swift v2 rejects it (not available in incomplete v2 memory service); response header is v2-format, not v1 found-N-candidate-memories. Parity gap with Swift; awaiting catalog decision. Do not delete."]
fn answer_never_with_no_mode_is_unchanged() {
    let dispatcher = make_dispatcher();

    // Call with explicit answer:"never" — no mode arg.
    let response_explicit = tools_call_response(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": "test query", "answer": "never" }),
    );
    let text_explicit = response_text(&response_explicit);

    // Call with no answer arg and no mode — same "never" default applies.
    let response_default = tools_call_response(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": "test query" }),
    );
    let text_default = response_text(&response_default);

    // Both should contain the row-listing header (not an answer: synthesis block).
    assert!(
        text_explicit.contains("found") || text_explicit.contains("memories"),
        "answer:never explicit call must return row-listing header; got: {text_explicit}"
    );
    assert!(
        text_default.contains("found") || text_default.contains("memories"),
        "no-arg call must return row-listing header; got: {text_default}"
    );
    // Neither should contain an "answer:" synthesis block header.
    assert!(
        !text_explicit.contains("answer:"),
        "answer:never must NOT produce an answer: synthesis block; got: {text_explicit}"
    );
    assert!(
        !text_default.contains("answer:"),
        "no-arg default must NOT produce an answer: synthesis block; got: {text_default}"
    );
}

// MARK: - I. Sticky recall e2e: Recall=Auto on call 1 → moot_memory_search call 2 inherits auto

/// Gate: Call 1 declares mode:"Recall=Auto"; call 2 is moot_memory_search with
/// NO mode/answer arg; the sticky auto path must reach the packager and emit
/// the `signals:` line (which the never fast path never produces).
///
/// Fixture: the twin of Swift `ModesDispatchTests.makeDispatcher` — a BARE
/// estate (`new_inmemory_bare`: no charter hints, no Corpus, no VectorStore),
/// one memory filed with the required `location` argument. With 1 hit:
/// m1=1.0, m3=1.0 → confidence >= INTERMEDIATE → answer_block is Some →
/// `signals:` line is emitted. The never fast path skips gate computation
/// entirely — no `signals:`.
///
/// Discrimination: the seed reply is asserted (`filed memory`), so a seed that
/// does not land (a missing `location` returns a JSON-RPC error and an empty
/// estate, which yields 0 hits and no `signals:` on every path) fails here
/// and not as a vacuous packager verdict. The served-style registry
/// (`new_inmemory`) is not used on purpose: its seven charter hints join the
/// result at a flat score with the dense lane dark, and the gate reads WEAK
/// in both ports on that shape (m3 = 0).
///
/// Mirrors Swift test D2 `recallAutoE2eDispatcherPath`.
#[test]
#[ignore = "BLOCKED: v2 decode rejects the mode argument (v2/codec.rs reject_unknown_fields). Awaiting a catalog decision. Do not delete; do not weaken to pass."]
fn sticky_recall_auto_e2e_dispatcher() {
    // OBSTACLE 3: build_advisory (6th arg) was removed in v2A; pass 5 args only.
    let dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory_bare(),
        "ARIA_MCP_Rust",
        "test",
        "test-serial",
        None,
    );

    // Seed one memory so the estate is non-empty — the same three arguments
    // the Swift twin passes. Required for the packager to compute confidence
    // and emit the signals: line on the auto path.
    let seed = tools_call_response(
        &dispatcher,
        "moot_file_memory",
        serde_json::json!({
            "content": "sticky recall auto test memory — alpha bravo charlie",
            "subject": "sticky e2e seed",
            "location": "default"
        }),
    );
    let seed_text = response_text(&seed);
    assert!(
        seed_text.contains("filed memory"),
        "the seed must land before the search is meaningful; got: {seed:?}"
    );

    // Call 1: declare Recall=Auto via moot_estate_status (side-effect free).
    let _call1 = tools_call_response(
        &dispatcher,
        "moot_estate_status",
        serde_json::json!({ "mode": "Recall=Auto" }),
    );

    // Verify sticky state is set correctly after the mode declaration.
    assert_eq!(
        dispatcher.sticky_recall_answer_mode_for_test(),
        Some("auto"),
        "Recall=Auto on call 1 must set sticky answer mode to 'auto'"
    );

    // Call 2: moot_memory_search with NO mode/answer arg, the Swift twin's
    // query. The dispatcher injects answer:"auto" from sticky state before
    // dispatching; the packager's gate fires on the 1-hit result and appends
    // a signals: line.
    let response2 = tools_call_response(
        &dispatcher,
        "moot_memory_search",
        serde_json::json!({ "query": "sticky e2e dispatch test" }),
    );
    let text2 = response_text(&response2);
    // The signals: line is produced by the auto/always gate path only.
    // Its presence proves the sticky injection reached the packager.
    assert!(
        text2.contains("signals:"),
        "moot_memory_search with sticky Recall=Auto must emit signals: \
         (packager gate path — fails if sticky injection is reverted or \
         the seed memory is removed); got: {text2}"
    );
    // The line shape is Swift `runMemorySearch`'s, byte for byte on this
    // fixture: one hit gives margin 1.0, lane agreement from the union
    // profile, dense spread 1.0 (single-hit rule) and containment false
    // (the Rust port composes no answer text).
    assert!(
        text2.contains("signals: margin=1.0 lane_agreement=") && text2.contains(" dense_spread=1.0 containment=false"),
        "signals line must carry the Swift field names and shortest-form doubles; got: {text2}"
    );
    assert!(
        text2.contains("confidence: intermediate"),
        "confidence line must carry the level name (Swift rawValue); got: {text2}"
    );
}

// MARK: - J. Byte-identity: modesStatusSection surface (shared fixture)

/// Gate: `modes_status_section()` must produce the byte-identical string
/// that Swift's `SessionProtocol.modesStatusSection` computed property produces.
///
/// The expected value is pinned in a shared conformance fixture (JSON) that
/// both ports read. If either port's rendering diverges (different separator,
/// missing mode, wrong contract text), this test catches it in the same run
/// that catches the Swift equivalent.
///
/// How it fails if reverted: changing the `status_line()` format string or
/// the mode contract text without updating the fixture → assert fires;
/// also fails if the Rust output diverges from the fixture (which the Swift
/// test also pins), surfacing a parity break.
#[test]
fn modes_status_section_byte_identity() {
    use aria_mcp::session_protocol::modes_status_section;

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .unwrap()
        .join("Tests/Conformance/modes_status_section_fixture.json");

    let data = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("Failed to read modes_status_section fixture at {}: {}", fixture_path.display(), e));

    let parsed: serde_json::Value = serde_json::from_str(&data)
        .expect("Modes status section fixture JSON must be valid");

    let expected = parsed.get("expected")
        .and_then(|v| v.as_str())
        .expect("Fixture must have 'expected' string field");

    let actual = modes_status_section();

    assert_eq!(
        actual, expected,
        "modes_status_section() must be byte-identical to fixture.\nExpected:\n{}\n\nActual:\n{}",
        expected, actual
    );
}

// MARK: - P. Provisioned modes config (estate manifest → dispatcher)

/// Gate (P1): provisioned `sticky_enabled=false` → a mode declaration is accepted
/// and a response is returned (fail-open), but `sticky_recall_answer_mode` stays
/// None because the sticky code path is bypassed.
///
/// How it fails if reverted: if `sticky_enabled` is still true (the default),
/// the Recall=Auto declaration would be sticky-stored and
/// `sticky_recall_answer_mode()` would return `Some("auto")`, failing the assertion.
///
/// Mirrors Swift test P1 (`provisionedStickyDisabledDeclarationNotSticky`).
#[test]
fn provisioned_sticky_disabled_declaration_not_sticky() {
    let dispatcher = make_provisioned_dispatcher(false, 25);

    // The first tool call triggers apply_preferences (sticky_enabled=false).
    // Declare Recall=Auto — declaration must be accepted (fail-open) but NOT sticky.
    let response = tools_call_response(
        &dispatcher,
        "moot_estate_status",
        serde_json::json!({ "mode": "Recall=Auto" }),
    );
    // Response must not be an error (fail-open).
    assert!(
        !response["result"]["isError"].as_bool().unwrap_or(false),
        "Response must not be an error when sticky is disabled; got: {:?}", response
    );

    // Sticky state must remain None because sticky_enabled=false.
    assert_eq!(
        dispatcher.sticky_recall_answer_mode_for_test(),
        None,
        "Sticky state must stay None when provisioned sticky_enabled=false (P1)"
    );
}

/// Gate (P2): provisioned `coaching_calls=0` → coaching never fires across 30
/// calls. `should_coach()` must return false on every call.
///
/// How it fails if reverted: if the default `coaching_calls_x=25` is still in
/// effect, `should_coach()` fires at call 25 and the assertion fails.
///
/// Mirrors Swift test P2 (`provisionedCoachingCallsZeroNeverCoaches`).
#[test]
fn provisioned_coaching_calls_zero_never_coaches() {
    let dispatcher = make_provisioned_dispatcher(true, 0);

    // 30 calls through the dispatcher — coaching must never fire.
    for _ in 0..30 {
        let response = tools_call_response(
            &dispatcher,
            "moot_estate_status",
            serde_json::json!({}),
        );
        let text = response_text(&response);
        // The coaching block header is "[Moot coaching · call N]" — assert it is absent.
        assert!(
            !text.contains("[Moot coaching"),
            "Coaching block must not appear when coaching_calls=0 (P2); \
             got coaching block at some call. wire text:\n{text}"
        );
    }
}

/// Gate (P3): provisioned `coaching_calls=2` → coaching ABSENT at call 1,
/// PRESENT at call 2.
///
/// This is the discriminating test: if the hardcoded constant 25 is still in
/// effect instead of the provisioned value 2, coaching does NOT fire at call 2
/// and the assertion on call 2 fails.
///
/// Mirrors Swift test P3 (`provisionedCoachingCallsTwoFiresOnCallTwo`).
#[test]
fn provisioned_coaching_calls_two_fires_on_call_two() {
    let dispatcher = make_provisioned_dispatcher(true, 2);

    // Call 1 — coaching must NOT fire (total = 1, not a multiple of 2).
    let response1 = tools_call_response(
        &dispatcher,
        "moot_estate_status",
        serde_json::json!({}),
    );
    let text1 = response_text(&response1);
    assert!(
        !text1.contains("[Moot coaching"),
        "Coaching must NOT fire on call 1 when coaching_calls=2 (P3 call 1); \
         wire text:\n{text1}"
    );

    // Call 2 — coaching MUST fire (total = 2, multiple of 2).
    // The coaching block header is "[Moot coaching · call N]".
    let response2 = tools_call_response(
        &dispatcher,
        "moot_estate_status",
        serde_json::json!({}),
    );
    let text2 = response_text(&response2);
    assert!(
        text2.contains("[Moot coaching"),
        "Coaching MUST fire on call 2 when coaching_calls=2 (P3 call 2 — \
         discriminating gate: fails if hardcoded constant 25 is still active); \
         wire text:\n{text2}"
    );
}

/// BLOCKED: `aria_mcp::teachme_guides` is a v1-only surface with no v2 equivalent.
/// `moot_help` is the v2 discovery surface but does not expose a static guide string
/// to assert byte-identity against; it returns dynamic content.
///
/// Original intent: verify `modes_teachme_guide()` is byte-identical to
/// `Tests/Conformance/modes_teachme_guide_fixture.json`.
///
/// Converted from `#[cfg(any())]` to `#[ignore]` so the test is COMPILED, VISIBLE,
/// and COUNTED as ignored rather than silently absent from every count.
/// Body uses `todo!()` because `aria_mcp::teachme_guides` does not exist in v2 and
/// the test body cannot compile against it. `todo!()` is never reached; `#[ignore]`
/// prevents execution. When a v2 guide surface with a stable byte output is added,
/// restore the fixture assertion against its output.
/// Do NOT delete this test; do NOT weaken to pass.
#[test]
#[ignore = "BLOCKED: teachme_guides is a v1-only module with no v2 equivalent; moot_help is the v2 discovery surface but exposes no static guide string."]
fn modes_teachme_guide_byte_identity() {
    // aria_mcp::teachme_guides::modes_teachme_guide() — v1-only, absent from v2.
    // moot_help was investigated; it exposes no static guide string to assert on.
    // Fixture: Tests/Conformance/modes_teachme_guide_fixture.json
    // Restore against a v2 guide surface when one exists.
    todo!("V2 has no teachme_guides equivalent; moot_help exposes no static guide string.");
}
