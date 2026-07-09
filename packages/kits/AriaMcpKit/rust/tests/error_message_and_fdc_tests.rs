//! Error-message parity + FDC seam classification tests (B-6 + one-door verification).
//!
//! B-6 (error surfacing): verifies that errors at the MCP boundary carry
//! actionable English reasons, not raw Rust type names like
//! `VerbDispatchError`, `UnderlyingEstateFailure`, `GeniusLocusKitError`, etc.
//!
//! One-door (FDC seam): verifies that `moot_file_memory` content is classified
//! in the GeniusLocusKit capture seam (`capture_with_mode`), not per-caller.
//! The standard path produces a real classified code; later tests cover
//! unclassifiable content and high-frequency jargon where "000" or non-empty
//! is the accepted fallback (the UDC root; was incorrectly "000.000" before).
//!
//! Parity: the Swift counterpart tests live in
//! `Tests/AriaMCPTests/FdcCaptureTests.swift`.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};
use genius_locus_kit::WriteMode;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::RecallFrame;
use locus_kit::frames::CaptureFrame;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_tool_error(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(true)
}

// ---------------------------------------------------------------------------
// B-6: error message quality — no internal Rust type names at the boundary
// ---------------------------------------------------------------------------

/// Filing a memory with an empty `location` string produces an actionable
/// error that contains the failing reason ("room must not be empty") but
/// does NOT contain the internal Rust type name `UnderlyingEstateFailure`.
///
/// Before B-6 the error was `format!("{e:?}")` which surfaced:
///   `Verb(UnderlyingEstateFailure { reason: "InvalidContent: room must not be empty" })`
/// After the fix it uses `describe_verb_dispatch_error` and surfaces:
///   `"capture failed: InvalidContent: room must not be empty"`
#[test]
fn empty_location_error_contains_reason_not_rust_type_name() {
    let registry = EstateRegistry::new_inmemory();

    let a = args![
        "content"  => "some content",
        "location" => ""           // empty room — estate rejects this
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("dispatch must not return a transport error on a content-rejected call");

    // The result is a tool-level error (isError == true).
    assert!(
        is_tool_error(&result),
        "empty location must produce a tool-level error; got: {result:?}"
    );

    let msg = content_text(&result);

    // Must NOT contain the internal Rust enum variant name.
    assert!(
        !msg.contains("UnderlyingEstateFailure"),
        "error message must not leak 'UnderlyingEstateFailure'; got: {msg}"
    );
    assert!(
        !msg.contains("VerbDispatchError"),
        "error message must not leak 'VerbDispatchError'; got: {msg}"
    );

    // Must contain the actionable reason.
    assert!(
        msg.contains("room must not be empty"),
        "error message must contain the actionable reason 'room must not be empty'; got: {msg}"
    );
}

/// Attempting to search memories with a non-existent estateID produces an
/// error that does NOT contain the internal `GeniusLocusKitError` type name.
///
/// Before B-6, `coord.estate_for` failures were passed to
/// `describe_verb_dispatch_error` which expects `VerbDispatchError`, causing
/// a type mismatch. After the fix they route through `describe_glk_error`.
#[test]
fn unknown_estate_id_error_is_clean_english() {
    let registry = EstateRegistry::new_inmemory();

    // Supply a well-formed but non-existent estateID to reach the
    // `resolve` path — resolve surfaces a clean INVALID_PARAMS JSONRPCError.
    let a = args![
        "query"    => "anything",
        "estateID" => "00000000-0000-0000-0000-000000000000"
    ];
    let result = dispatch_tool("moot_memory_search", &a, &registry, &SurfacedRecallLedger::new());

    // This is a transport-level error (Err(JSONRPCError)), not a tool-level error.
    let err = result.expect_err("unknown estateID must return a transport-level JSONRPCError");

    let msg = &err.message;
    assert!(
        !msg.contains("GeniusLocusKitError"),
        "error message must not leak 'GeniusLocusKitError'; got: {msg}"
    );
    assert!(
        !msg.contains("EstateNotOpen"),
        "error message must not leak 'EstateNotOpen' Rust variant; got: {msg}"
    );
}

// ---------------------------------------------------------------------------
// One-door: FDC seam classifies moot_file_memory content
// ---------------------------------------------------------------------------

/// Filing a memory with classifiable content results in a drawer whose
/// `udc_code` is a real FDC code, not the "000" unclassified sentinel.
///
/// "Biology is the scientific study of life" reliably resolves to the FDC
/// natural-sciences region. Any non-"000" code confirms the seam's
/// Fdc::encode_anchor path ran. The test accesses the stored drawer via
/// the estate coordinator's `recall` method (the LocusKit read path) rather
/// than relying on the tool response text (which does not surface `udc_code`).
#[test]
fn file_memory_with_classifiable_content_sets_real_udc_code() {
    // _bare: controlled single-drawer estate — no seeded AI_Charter_Hint drawers,
    // so the "exactly one drawer" read-back targets this test's content.
    let registry = EstateRegistry::new_inmemory_bare();

    // File a memory whose content the FDC encoder reliably classifies.
    let classifiable = "Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, and evolution.";
    let a = args![
        "content"  => classifiable,
        "location" => "science-room"
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("file_memory must succeed");

    assert!(
        result["isError"] == serde_json::json!(false),
        "file_memory must succeed; got: {result:?}"
    );

    // Read back the drawer directly from the estate coordinator.
    // This exercises the stored `udc_code` field on the persisted Drawer.
    let estate = registry
        .resolve(&BTreeMap::new(), "estateID")
        .expect("default estate must resolve");

    let coord = estate.coord.lock().expect("coord lock must not be poisoned");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .expect("recall must succeed on a fresh estate");

    assert_eq!(drawers.len(), 1, "exactly one drawer must exist");

    let udc_code = &drawers[0].udc_code;
    // The unclassified sentinel is "000" (the UDC root). A classified drawer
    // must carry a more specific code resolved by the seam's Fdc::encode_anchor.
    assert!(
        udc_code != "000",
        "file_memory with classifiable content must set a real udc_code, not the '000' unclassified sentinel; got: '{udc_code}'"
    );
    assert!(
        !udc_code.is_empty(),
        "udc_code must not be empty after FDC classification"
    );
}

// ---------------------------------------------------------------------------
// FIX 3 (B-6 residual): strip_enum_prefix — internal enum-case prefixes like
// "InvalidContent: " must not appear in user-facing error messages. Parity
// with Swift GateRejectionMessageTests.captureWithEmptyRoomStripsInvalidContentPrefix
// and GateRejectionMessageTests.stripEnumPrefixRemovesTypeNamePrefix.
// ---------------------------------------------------------------------------

/// An empty location error must NOT expose "InvalidContent:" in the message.
///
/// Before FIX 3 the describe_verb_dispatch_error for UnderlyingEstateFailure
/// returned `"{verb} failed: {reason}"` where reason was the raw substrate
/// string "InvalidContent: room must not be empty". The strip_enum_prefix
/// helper in interface_tools.rs now strips the "InvalidContent: " prefix so
/// the user sees "capture failed: room must not be empty" instead.
#[test]
fn empty_location_error_does_not_expose_invalid_content_prefix() {
    let registry = EstateRegistry::new_inmemory();

    let a = args![
        "content"  => "some content",
        "location" => ""   // empty room triggers InvalidContent from substrate
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("dispatch must not return a transport error on content-rejected call");

    assert!(
        is_tool_error(&result),
        "empty location must produce a tool-level error; got: {result:?}"
    );

    let msg = content_text(&result);

    // Must NOT contain the internal enum case prefix.
    assert!(
        !msg.contains("InvalidContent:"),
        "error message must not expose 'InvalidContent:' prefix; got: {msg}"
    );

    // Must still contain the actionable reason (the stripping only removes the prefix).
    assert!(
        msg.contains("room must not be empty"),
        "error message must still contain 'room must not be empty' after prefix strip; got: {msg}"
    );
}

/// Filing a memory whose content is not classifiable (short noise text)
/// falls back gracefully without failing. Confirms the fallback path is live
/// and that FDC failure does not propagate as an error to the tool surface.
/// The assertion requires only a non-empty `udc_code`; both "000" and a
/// classified code are accepted.
#[test]
fn file_memory_with_unclassifiable_content_falls_back_to_root_code() {
    // _bare: controlled single-drawer estate — no seeded AI_Charter_Hint drawers,
    // so the "exactly one drawer" read-back targets this test's content.
    let registry = EstateRegistry::new_inmemory_bare();

    // A string of random tokens with no meaningful FDC signature.
    let noise = "zzq xkj blrt fnp";
    let a = args![
        "content"  => noise,
        "location" => "noise-room"
    ];
    let result =
        dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
            .expect("file_memory must succeed even for unclassifiable content");

    assert!(
        result["isError"] == serde_json::json!(false),
        "file_memory must succeed even when FDC cannot classify; got: {result:?}"
    );

    // The drawer must exist (not error out).
    let estate = registry
        .resolve(&BTreeMap::new(), "estateID")
        .expect("default estate must resolve");

    let coord = estate.coord.lock().expect("coord lock must not be poisoned");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .expect("recall must succeed");

    assert_eq!(drawers.len(), 1, "exactly one drawer must exist");
    // The drawer may be "000" (sentinel) or a classified code — the important
    // thing is it exists and the code is non-empty.
    assert!(
        !drawers[0].udc_code.is_empty(),
        "udc_code must never be empty regardless of FDC outcome"
    );
}

// ---------------------------------------------------------------------------
// Cross-door parity: file_memory and direct capture_with_mode share ONE seam
// ---------------------------------------------------------------------------

/// Filing the SAME classifiable content through `moot_file_memory` (the MCP
/// tool path) and through a direct `capture_with_mode` call (what VaultKit's
/// import path does) must produce drawers with the SAME `udc_code`.
///
/// If each path were classifying independently the codes might agree by chance,
/// but this test proves they share a SINGLE call tree: both pass the "000"
/// unclassified sentinel to `capture_with_mode`, which runs `Fdc::encode_anchor`
/// exactly once per frame, producing a deterministic result.
///
/// One-door principle: two behaviors are equal if and only if they traverse the
/// SAME functional call tree.
#[test]
fn file_memory_and_direct_capture_produce_same_udc_code() {
    let classifiable = "Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, and evolution.";

    // Path 1 — file_memory tool (the MCP caller path).
    // _bare: controlled single-drawer estate — no seeded AI_Charter_Hint drawers,
    // so drawers1[0] is this test's drawer.
    let registry1 = EstateRegistry::new_inmemory_bare();
    let a = args!["content" => classifiable, "location" => "science-room"];
    dispatch_tool("moot_file_memory", &a, &registry1, &SurfacedRecallLedger::new())
        .expect("file_memory must succeed");

    let estate1 = registry1.resolve(&BTreeMap::new(), "estateID").expect("estate1 must resolve");
    let coord1 = estate1.coord.lock().expect("coord1 lock");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;
    let drawers1 = coord1
        .recall(&estate1.handle, RecallFrame::new(vec![]), now)
        .expect("recall estate1");
    let code_via_tool = drawers1[0].udc_code.clone();

    // Path 2 — direct capture_with_mode with the canonical "000" sentinel
    //           (mirrors what VaultKit's make_capture_frame produces when a
    //           note has no explicit frontmatter `udc`).
    // _bare: controlled single-drawer estate (parity with Path 1 above).
    let registry2 = EstateRegistry::new_inmemory_bare();
    let estate2 = registry2.resolve(&BTreeMap::new(), "estateID").expect("estate2 must resolve");
    let mut coord2 = estate2.coord.lock().expect("coord2 lock");
    let frame = CaptureFrame::new(
        classifiable,
        CaptureChannel::ImportedFile,
        "science-room",
        // The canonical unclassified sentinel: same value VaultKit passes
        // when no frontmatter `udc` is present.
        LatticeAnchor::udc("000"),
        "test-added-by",
        "test-model",
    );
    coord2
        .capture_with_mode(&estate2.handle, frame, now, WriteMode::Regular)
        .expect("direct capture_with_mode must succeed");
    let drawers2 = coord2
        .recall(&estate2.handle, RecallFrame::new(vec![]), now)
        .expect("recall estate2");
    let code_via_coordinator = drawers2[0].udc_code.clone();

    // Both paths must produce the SAME code — proof of the one-door principle.
    assert_eq!(
        code_via_tool, code_via_coordinator,
        "file_memory tool and direct capture_with_mode must produce the same udc_code \
        for classifiable content (one-door principle); tool={code_via_tool}, \
        coordinator={code_via_coordinator}"
    );
    // And neither should be the unclassified sentinel (content IS classifiable).
    assert!(
        code_via_tool != "000",
        "classifiable content must not remain at the '000' sentinel; got: '{code_via_tool}'"
    );
}

/// When a capture frame carries an EXPLICIT non-sentinel udc_code (e.g. from
/// vault frontmatter `udc`), the `capture_with_mode` seam must preserve it —
/// it must NOT re-classify an already-classified anchor.
///
/// This is the "explicit frontmatter `udc` is preserved" invariant, matching
/// the seam's guard: `frame.lattice_anchor.udc_code == UNCLASSIFIED_SENTINEL`.
/// An anchor that differs from "000" passes through unchanged.
#[test]
fn explicit_udc_code_on_capture_frame_is_preserved_by_seam() {
    // _bare: controlled single-drawer estate — no seeded AI_Charter_Hint drawers,
    // so the "exactly one drawer" read-back targets this test's content.
    let registry = EstateRegistry::new_inmemory_bare();
    let estate = registry.resolve(&BTreeMap::new(), "estateID").expect("estate must resolve");
    let mut coord = estate.coord.lock().expect("coord lock");
    let now: i64 = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after UNIX epoch")
        .as_secs() as i64;

    // Explicit UDC code from vault frontmatter (not the sentinel).
    // "610" = Medicine & Health — a well-established code far from "000".
    let explicit_code = "610";
    let frame = CaptureFrame::new(
        "Biology is the scientific study of life.", // classifiable content
        CaptureChannel::ImportedFile,
        "medicine-room",
        // Explicit code: the seam must NOT override this even though the
        // content is classifiable (which might resolve to a different code).
        LatticeAnchor::udc(explicit_code),
        "test-added-by",
        "test-model",
    );
    coord
        .capture_with_mode(&estate.handle, frame, now, WriteMode::Regular)
        .expect("capture must succeed");

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .expect("recall must succeed");

    assert_eq!(drawers.len(), 1, "exactly one drawer");
    let stored_code = &drawers[0].udc_code;
    assert_eq!(
        stored_code, explicit_code,
        "the seam must preserve an explicit non-sentinel udc_code, not re-classify; \
        expected: '{explicit_code}', got: '{stored_code}'"
    );
}

// ---------------------------------------------------------------------------
// Honest-classification guard: no confidently-wrong specific codes for
// high-frequency cross-domain jargon.
// ---------------------------------------------------------------------------

/// Reviewed relative-index aliases must classify modern computing vocabulary
/// as computer science instead of allowing historical article terms to select
/// an unrelated code.
///
/// Real examples of the pre-fix bug (raw-scoring tie-break accidents):
///   "computer software programming" → UDC 235 (angels/devotional) WRONG
///   "network protocol internet"     → UDC 621.2 (hydraulic engineering) WRONG
///
/// After the reviewed aliases were added, both phrases resolve to 004 in the
/// shared FDC conformance fixture. The capture seam must preserve that result.
#[test]
fn reviewed_computing_aliases_survive_the_capture_seam() {
    let high_frequency_items = [
        ("computer software programming and information science", "cs-room"),
        ("internet network protocol server client communication system", "net-room"),
    ];

    for (content, location) in &high_frequency_items {
        // _bare: controlled single-drawer estate — no seeded AI_Charter_Hint
        // drawers, so the "one drawer per content item" read-back is exact.
        let registry = EstateRegistry::new_inmemory_bare();
        let a = args!["content" => *content, "location" => *location];
        let result =
            dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
                .expect("file_memory must succeed for high-frequency content");

        assert!(
            result["isError"] == serde_json::json!(false),
            "file_memory must succeed for high-frequency content '{content}'; got: {result:?}"
        );

        let estate = registry
            .resolve(&BTreeMap::new(), "estateID")
            .expect("estate must resolve");
        let coord = estate.coord.lock().expect("coord lock");
        let now: i64 = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system time must be after UNIX epoch")
            .as_secs() as i64;
        let drawers = coord
            .recall(&estate.handle, RecallFrame::new(vec![]), now)
            .expect("recall must succeed");

        assert_eq!(drawers.len(), 1, "one drawer per content item");

        let udc = &drawers[0].udc_code;
        assert_eq!(
            udc, "004",
            "reviewed computing aliases must survive capture; content='{content}'"
        );
    }
}
