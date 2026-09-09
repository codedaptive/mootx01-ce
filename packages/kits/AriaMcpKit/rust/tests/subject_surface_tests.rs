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
fn file_memory_oversize_subject_returns_contract_error() {
    // Subject contract violation surfaces as isError:true so the model sees
    // the message instead of a bare "Tool execution failed" from JSON-RPC
    // error rendering (ARIA-MSG-1 fix).
    let registry = EstateRegistry::new_inmemory();
    let oversize: String =
        "x".repeat(locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1);
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => oversize.as_str(),
               "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("oversize subject must return Ok(isError), not Err");
    assert_eq!(result["isError"], serde_json::json!(true), "must be isError:true");
    let text = content_text(&result);
    assert!(
        text.contains(&format!("subject must be 1–{} characters", locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT)),
        "error text must contain the contract message, got: {text}"
    );
    assert!(
        text.contains(&n.to_string()),
        "error text must contain the offending length ({n}), got: {text}"
    );
}

/// The 120 of the subject contract is 120 Unicode SCALARS, the unit this port
/// has always counted and the unit both moot-bridge ports now cut on. A
/// non-ASCII case is what tells the rules apart: 70 clusters of "e" + U+0301
/// is 70 grapheme clusters — under the limit by that count — and 140 scalars,
/// over it. Twin of the Swift `subjectLengthCountsScalarsNotGraphemes`.
#[test]
fn subject_length_counts_scalars_not_graphemes() {
    let registry = EstateRegistry::new_inmemory();
    let clusters = 70;
    let combining = "e\u{0301}".repeat(clusters);
    assert_eq!(combining.chars().count(), clusters * 2, "140 Unicode scalars");
    let result = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => combining.as_str(),
               "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("a 140-scalar subject must return Ok(isError), not Err");
    assert_eq!(result["isError"], serde_json::json!(true), "must be isError:true");
    let text = content_text(&result);
    // The reported length is the scalar count, so the model is told how much
    // to cut in the unit the contract measures.
    assert!(
        text.contains(&format!("(got {})", clusters * 2)),
        "the refusal must report the scalar count, got: {text}"
    );
}

#[test]
fn set_subject_oversize_returns_contract_error() {
    // setSubject contract violation also surfaces as isError:true (ARIA-MSG-1).
    let registry = EstateRegistry::new_inmemory();
    let id = capture_without_subject(&registry, "needs a subject", "subject-tests");
    let oversize: String =
        "y".repeat(locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1);
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let result = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(),
               "mutation" => "setSubject",
               "subject" => oversize.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("oversize setSubject must return Ok(isError), not Err");
    assert_eq!(result["isError"], serde_json::json!(true), "must be isError:true");
    let text = content_text(&result);
    assert!(
        text.contains(&format!("subject must be 1–{} characters", locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT)),
        "error text must contain the contract message, got: {text}"
    );
    assert!(
        text.contains(&n.to_string()),
        "error text must contain the offending length ({n}), got: {text}"
    );
}

/// Cross-port parity: the error message strings for file_memory and
/// update_memory (setSubject) must be identical between Swift and Rust.
/// This test encodes the exact strings to catch divergence if either
/// port is edited without updating the other.
#[test]
fn subject_contract_message_matches_swift_port() {
    // moot_file_memory oversize message (parity with Swift runFileMemory).
    let registry = EstateRegistry::new_inmemory();
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize_file: String = "x".repeat(n);
    let result_file = dispatch_tool(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => oversize_file.as_str(),
               "location" => "subject-tests"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("must return Ok(isError)");
    let file_text = content_text(&result_file);
    let expected_file = format!(
        "subject must be 1\u{2013}{} characters (got {}). One telegraphic sentence in the AI-facing register \u{2014} compress, don't truncate.",
        locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT,
        n
    );
    assert_eq!(file_text, expected_file,
        "file_memory message must match Swift port verbatim");

    // moot_update_memory setSubject oversize message (parity with Swift runUpdateMemory).
    let id = capture_without_subject(&registry, "needs a subject", "subject-tests");
    let oversize_set: String = "y".repeat(n);
    let result_set = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(),
               "mutation" => "setSubject",
               "subject" => oversize_set.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("must return Ok(isError)");
    let set_text = content_text(&result_set);
    let expected_set = format!(
        "subject must be 1\u{2013}{} characters (got {}). Compress, don't truncate.",
        locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT,
        n
    );
    assert_eq!(set_text, expected_set,
        "setSubject message must match Swift port verbatim");
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

// ---------------------------------------------------------------------------
// 4. Note propagation (MXE-SK — the boundary must not discard the caller's
//    audit annotation). Regression tests for the defect where both
//    `coord.mutate` call sites passed `None` as the payload: these fail
//    against pre-fix code because the note never reached the audit row.
// ---------------------------------------------------------------------------

#[test]
fn update_memory_note_reaches_the_set_subject_custody_audit_row() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let id = capture_without_subject(&registry, "Row whose subject gets a noted backfill.", "subject-tests");

    let updated = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(),
               "mutation" => "setSubject",
               "subject" => "Subject set with an audit note.",
               "note" => "backfilled during MXE-SK verification"],
        &registry,
        &ledger,
    )
    .expect("setSubject with note must succeed");
    assert!(is_success(&updated), "got: {updated:?}");

    // The custody audit row must carry the caller's note as its reason.
    let coord = registry.coord.lock().unwrap();
    let estate = coord
        .estate_for(&registry.default.handle)
        .expect("estate_for");
    let trail = estate.audit_trail(&id).expect("audit trail");
    let custody: Vec<_> = trail.iter().filter(|e| e.verb == "setSubject").collect();
    assert_eq!(custody.len(), 1, "exactly one setSubject custody event");
    assert_eq!(
        custody[0].reason.as_deref(),
        Some("backfilled during MXE-SK verification"),
        "the note argument must reach the audit row's reason"
    );
    assert!(!custody[0].actor.is_empty(), "custody row records an actor");
}

#[test]
fn update_memory_without_note_seals_custody_row_with_absent_reason() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let id = capture_without_subject(&registry, "Row backfilled without a note.", "subject-tests");

    let updated = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(),
               "mutation" => "setSubject",
               "subject" => "Subject set without an audit note."],
        &registry,
        &ledger,
    )
    .expect("setSubject without note must succeed");
    assert!(is_success(&updated), "got: {updated:?}");

    let coord = registry.coord.lock().unwrap();
    let estate = coord
        .estate_for(&registry.default.handle)
        .expect("estate_for");
    let trail = estate.audit_trail(&id).expect("audit trail");
    let custody: Vec<_> = trail.iter().filter(|e| e.verb == "setSubject").collect();
    assert_eq!(
        custody.len(),
        1,
        "an absent note is not an absent row: the custody event still seals"
    );
    assert_eq!(custody[0].reason, None, "no note ⇒ absent reason");
}

#[test]
fn update_memory_note_is_generic_not_set_subject_special_cased() {
    // The note-drop was not setSubject-specific: EVERY Rust mutation
    // discarded its annotation. Prove the fixed boundary forwards the
    // note for an ordinary bitmap mutation too: `contest`, whose arm
    // consumes the payload as its audit reason.
    //
    // (The other boundary call site, moot_confirm_memory, also forwards
    // the note now — but BOTH ports' Confirm ARMS hardcode their reason
    // and drop the forwarded payload, an out-of-scope arm defect recorded
    // in the MXE-SK completion report's Discoveries. End-to-end confirm
    // note delivery is asserted when that arm is fixed.)
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let id = capture_without_subject(&registry, "Row contested with a note.", "subject-tests");

    let contested = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(),
               "mutation" => "contest",
               "note" => "disputed by a later meeting recording"],
        &registry,
        &ledger,
    )
    .expect("contest with note must succeed");
    assert!(is_success(&contested), "got: {contested:?}");

    let coord = registry.coord.lock().unwrap();
    let estate = coord
        .estate_for(&registry.default.handle)
        .expect("estate_for");
    let trail = estate.audit_trail(&id).expect("audit trail");
    assert!(
        trail
            .iter()
            .any(|e| e.reason.as_deref() == Some("disputed by a later meeting recording")),
        "the note must reach the contest audit row's reason; trail reasons: {:?}",
        trail.iter().map(|e| e.reason.clone()).collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------
// 5. moot_file_fact subject contract (ARIA-MSG-2)
// ---------------------------------------------------------------------------

#[test]
fn file_fact_oversize_subject_returns_contract_error() {
    // Subject contract violation on moot_file_fact surfaces as isError:true
    // so the model sees the message instead of a bare "Tool execution failed"
    // from the generic catch wrapper (ARIA-MSG-2 fix). Mirrors Swift
    // fileFactOversizeSubjectReturnsContractError in SubjectSurfaceTests.swift.
    let registry = EstateRegistry::new_inmemory();
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize: String = "x".repeat(n);
    let result = dispatch_tool(
        "moot_file_fact",
        &args!["subject" => oversize.as_str(),
               "predicate" => "worksAt",
               "object" => "Acme"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("oversize fact subject must return Ok(isError), not Err");
    assert_eq!(result["isError"], serde_json::json!(true), "must be isError:true");
    let text = content_text(&result);
    assert!(
        text.contains(&format!("subject must be 1\u{2013}{} characters", locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT)),
        "error text must contain the contract message, got: {text}"
    );
    assert!(
        text.contains(&n.to_string()),
        "error text must contain the offending length ({n}), got: {text}"
    );
}

#[test]
fn file_fact_oversize_subject_message_matches_swift_port() {
    // Cross-port parity: the wire error text for moot_file_fact with an oversize
    // subject must be byte-identical in Swift and Rust. The Swift twin is
    // fileFactOversizeSubjectMessageMatchesRustPort in SubjectSurfaceTests.swift.
    let registry = EstateRegistry::new_inmemory();
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize: String = "x".repeat(n);
    let result = dispatch_tool(
        "moot_file_fact",
        &args!["subject" => oversize.as_str(),
               "predicate" => "worksAt",
               "object" => "Acme"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("must return Ok(isError)");
    let text = content_text(&result);
    let expected = format!(
        "subject must be 1\u{2013}{} characters (got {}). One telegraphic sentence in the AI-facing register \u{2014} compress, don't truncate.",
        locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT,
        n
    );
    assert_eq!(text, expected,
        "file_fact error text must match Swift port verbatim");
}
