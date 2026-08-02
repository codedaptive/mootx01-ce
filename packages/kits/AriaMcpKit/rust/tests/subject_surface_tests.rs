//! PR-02 verification suite for the capture + lifecycle subject surface.
//!
//! Mirrors Swift `SubjectSurfaceTests.swift` case-for-case:
//!
//!   1. `moot_file_memory` REQUIRES `subject` — absence and contract
//!      violations are rejected at the boundary with instructive errors
//!      (the register guidance, not a bare missing-argument line).
//!   2. `moot_update_memory` `mutation=setSubject` round-trips a subject
//!      onto a subject-less drawer (the backfill/correction write path).
//!   3. `moot_memory_list` `filter=missing_subject` enumerates exactly the
//!      subject-debt rows, id-only.
//!
//! Subject-less drawers are minted through the direct GLK capture seam
//! (frame without subject) — the intake-verb shape, which deliberately
//! files NULL subjects (debt by design).

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

macro_rules! args {
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

/// Capture a subject-less drawer through the direct GLK seam — the
/// intake-verb shape (frame without subject → born as debt). Returns id.
fn capture_without_subject(registry: &EstateRegistry, content: &str, room: &str) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::default_wings::DEFAULT_WING_NAME;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Actuator,
        room,
        LatticeAnchor::udc("000"),
        "subject-surface-tests",
        "default",
    );
    frame.wing = Some(DEFAULT_WING_NAME.to_string());
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("direct capture must succeed");
    drawer.id
}

// ---------------------------------------------------------------------------
// 1. Boundary requirement
// ---------------------------------------------------------------------------

#[test]
fn file_memory_without_subject_is_rejected_instructively() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "content without a subject", "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("missing subject must be rejected");
    assert!(err.message.contains("subject"), "got: {}", err.message);
    // Instructive, register-bearing error — not the generic missing-argument line.
    assert!(err.message.contains("NEXT AI"), "the error must teach the register; got: {}", err.message);
}

#[test]
fn file_memory_oversize_subject_is_rejected() {
    let registry = EstateRegistry::new_inmemory();
    let oversize: String =
        "x".repeat(locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1);
    let err = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => oversize.as_str(),
               "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("oversize subject must be rejected");
    assert!(err.message.contains("120"), "got: {}", err.message);
}

#[test]
fn file_memory_with_subject_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "The quarterly planning meeting moved to Thursday.",
               "subject" => "Quarterly planning moved to Thursday.",
               "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("file_memory with subject must succeed");
    assert!(is_success(&result), "got: {result:?}");
    assert!(content_text(&result).contains("filed memory"));
}

// ---------------------------------------------------------------------------
// 2 + 3. Debt enumeration and setSubject round-trip
// ---------------------------------------------------------------------------

#[test]
fn missing_subject_filter_lists_exactly_the_debt_rows_and_set_subject_clears_them() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // One drawer WITH a subject (through the boundary) …
    let filed = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "Filed with a subject.",
               "subject" => "Row filed with a subject at capture.",
               "location" => "subject-tests"],
        &registry,
        &ledger,
    )
    .expect("file_memory must succeed");
    assert!(is_success(&filed));

    // … and one WITHOUT (direct seam — the intake shape).
    let debt_id = capture_without_subject(&registry, "Imported without a subject.", "subject-tests");

    // The debt enumerator lists exactly the subject-less row, id-only.
    let listed = dispatch_tool(
        "moot_memory_list",
        &args!["wing" => locus_kit::default_wings::DEFAULT_WING_NAME,
               "filter" => "missing_subject"],
        &registry,
        &ledger,
    )
    .expect("memory_list must succeed");
    let list_text = content_text(&listed);
    assert!(list_text.contains("1 drawer(s)"), "exactly one debt row expected: {list_text}");
    assert!(list_text.contains(&debt_id));
    assert!(
        !list_text.contains("Imported without a subject"),
        "debt rows are id-only — no content preview: {list_text}"
    );

    // setSubject round-trip: backfill the debt row …
    let updated = dispatch_tool(
        "moot_update_memory",
        &args!["id" => debt_id.as_str(),
               "mutation" => "setSubject",
               "subject" => "Imported row: subject backfilled interactively."],
        &registry,
        &ledger,
    )
    .expect("setSubject must succeed");
    assert!(is_success(&updated), "got: {updated:?}");
    assert!(content_text(&updated).contains("updated memory"));

    // … and the debt list is now empty.
    let relisted = dispatch_tool(
        "moot_memory_list",
        &args!["wing" => locus_kit::default_wings::DEFAULT_WING_NAME,
               "filter" => "missing_subject"],
        &registry,
        &ledger,
    )
    .expect("memory_list must succeed");
    assert!(
        content_text(&relisted).contains("0 drawer(s)"),
        "debt must be cleared after setSubject: {}",
        content_text(&relisted)
    );
}

#[test]
fn set_subject_without_subject_arg_is_rejected() {
    let registry = EstateRegistry::new_inmemory();
    let id = capture_without_subject(&registry, "needs a subject", "subject-tests");
    let err = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(), "mutation" => "setSubject"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("setSubject without subject arg must be rejected");
    assert!(err.message.contains("subject"), "got: {}", err.message);
}

#[test]
fn unknown_filter_is_rejected_naming_the_accepted() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_memory_list",
        &args!["wing" => locus_kit::default_wings::DEFAULT_WING_NAME,
               "filter" => "bogus_filter"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown filter must be rejected");
    assert!(err.message.contains("missing_subject"), "got: {}", err.message);
}
