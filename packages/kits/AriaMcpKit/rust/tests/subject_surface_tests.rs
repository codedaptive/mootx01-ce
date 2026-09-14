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
mod test_support;
use test_support::SelectedV2Session;

use aria_mcp::{
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCError, JsonValue},
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

fn error_detail(error: &JSONRPCError) -> String {
    error.data.as_ref()
        .and_then(|data| serde_json::to_value(data).ok())
        .and_then(|data| data["message"].as_str().map(str::to_owned))
        .unwrap_or_else(|| error.message.clone())
}

fn error_path(error: &JSONRPCError) -> String {
    error.data.as_ref()
        .and_then(|data| data["path"].as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// Capture a subject-less drawer through the direct GLK seam — the
/// intake-verb shape (frame without subject → born as debt). Returns id.
fn capture_without_subject(session: &SelectedV2Session, content: &str, room: &str) -> String {
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
    let coord = session.coord.lock().unwrap();
    let drawer = coord
        .capture(&session.default.handle, frame, now)
        .expect("direct capture must succeed");
    drawer.id
}

// ---------------------------------------------------------------------------
// 1. Boundary requirement
// ---------------------------------------------------------------------------

#[test]
fn file_memory_without_subject_is_rejected_instructively() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let err = session.call(
        "moot_file_memory",
        &args!["content" => "content without a subject", "location" => "subject-tests"],
    )
    .expect_err("missing subject must be rejected");
    assert!(
        error_path(&err).contains("subject") && error_detail(&err).contains("required"),
        "got: {err:?}"
    );
}

#[test]
fn file_memory_oversize_subject_returns_contract_error() {
    // Subject contract violations are typed invalid-argument JSON-RPC faults.
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize: String = "x".repeat(n);
    let err = session.call(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => oversize.as_str(),
               "location" => "subject-tests"],
    )
    .expect_err("oversize subject must be rejected by selected v2");
    assert_eq!(err.code, -32602, "got: {err:?}");
    assert_eq!(error_path(&err), "$.subject", "got: {err:?}");
}

/// The 120 of the subject contract is 120 Unicode SCALARS, the unit this port
/// has always counted and the unit both moot-bridge ports now cut on. A
/// non-ASCII case is what tells the rules apart: 70 clusters of "e" + U+0301
/// is 70 grapheme clusters — under the limit by that count — and 140 scalars,
/// over it. Twin of the Swift `subjectLengthCountsScalarsNotGraphemes`.
#[test]
fn subject_length_counts_scalars_not_graphemes() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let clusters = 70;
    let combining = "e\u{0301}".repeat(clusters);
    assert_eq!(combining.chars().count(), clusters * 2, "140 Unicode scalars");
    let err = session.call(
        "moot_file_memory",
        &args!["content" => "some content",
               "subject" => combining.as_str(),
               "location" => "subject-tests"],
    )
    .expect_err("a 140-scalar subject must be rejected by selected v2");
    // The reported length is the scalar count, so the model is told how much
    // to cut in the unit the contract measures.
    assert!(
        error_detail(&err).contains(&(clusters * 2).to_string()) || error_detail(&err).contains("subject"),
        "the refusal must identify the subject contract, got: {err:?}"
    );
}

#[test]
fn set_subject_oversize_returns_contract_error() {
    // set_subject contract violations remain typed invalid-argument faults.
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let id = capture_without_subject(&session, "needs a subject", "subject-tests");
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize: String = "y".repeat(n);
    let err = session.call(
        "moot_update_memory",
        &args!["memory_id" => id.as_str(),
               "mutation" => "set_subject",
               "subject" => oversize.as_str()],
    )
    .expect_err("oversize set_subject must be rejected by selected v2");
    assert_eq!(err.code, -32602, "got: {err:?}");
    assert_eq!(error_path(&err), "$.subject", "got: {err:?}");
}

#[test]
fn file_memory_with_subject_succeeds() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let result = session.call(
        "moot_file_memory",
        &args!["content" => "The quarterly planning meeting moved to Thursday.",
               "subject" => "Quarterly planning moved to Thursday.",
               "location" => "subject-tests"],
    )
    .expect("file_memory with subject must succeed");
    assert!(is_success(&result), "got: {result:?}");
    assert!(result["structuredContent"]["data"]["memory_id"].is_string());
}

// ---------------------------------------------------------------------------
// 2 + 3. Debt enumeration and setSubject round-trip
// ---------------------------------------------------------------------------

#[test]
fn missing_subject_filter_lists_exactly_the_debt_rows_and_set_subject_clears_them() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());

    // One drawer WITH a subject (through the boundary) …
    let filed = session.call(
        "moot_file_memory",
        &args!["content" => "Filed with a subject.",
               "subject" => "Row filed with a subject at capture.",
               "location" => "subject-tests"],
    )
    .expect("file_memory must succeed");
    assert!(is_success(&filed));

    // … and one WITHOUT (direct seam — the intake shape).
    let debt_id = capture_without_subject(&session, "Imported without a subject.", "subject-tests");

    // The debt enumerator lists exactly the subject-less row, id-only.
    let listed = session.call(
        "moot_memory_list",
        &args!["wing" => locus_kit::default_wings::DEFAULT_WING_NAME,
               "filter" => "missing_subject"],
    )
    .expect("memory_list must succeed");
    let list_text = content_text(&listed);
    let listed_rows = listed["structuredContent"]["data"]["memories"]
        .as_array().expect("v2 list must return structured memories");
    assert_eq!(listed_rows.len(), 1, "exactly one debt row expected: {listed:?}");
    assert!(listed_rows.iter().any(|row| row["memory_id"] == debt_id));
    assert!(
        !list_text.contains("Imported without a subject"),
        "debt rows are id-only — no content preview: {list_text}"
    );

    // setSubject round-trip: backfill the debt row …
    let updated = session.call(
        "moot_update_memory",
        &args!["memory_id" => debt_id.as_str(),
               "mutation" => "set_subject",
               "subject" => "Imported row: subject backfilled interactively."],
    )
    .expect("setSubject must succeed");
    assert!(is_success(&updated), "got: {updated:?}");

    // … and the debt list is now empty.
    let relisted = session.call(
        "moot_memory_list",
        &args!["wing" => locus_kit::default_wings::DEFAULT_WING_NAME,
               "filter" => "missing_subject"],
    )
    .expect("memory_list must succeed");
    assert!(
        relisted["structuredContent"]["data"]["memories"]
            .as_array().is_some_and(Vec::is_empty),
        "debt must be cleared after set_subject: {relisted:?}"
    );
}

#[test]
fn set_subject_without_subject_arg_is_rejected() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let id = capture_without_subject(&session, "needs a subject", "subject-tests");
    let err = session.call(
        "moot_update_memory",
        &args!["memory_id" => id.as_str(), "mutation" => "set_subject"],
    )
    .expect_err("setSubject without subject arg must be rejected");
    assert!(
        error_path(&err).contains("subject") && error_detail(&err).contains("required"),
        "got: {err:?}"
    );
}

// ---------------------------------------------------------------------------
// 4. Note propagation (MXE-SK — the boundary must not discard the caller's
//    audit annotation). Regression tests for the defect where both
//    `coord.mutate` call sites passed `None` as the payload: these fail
//    against pre-fix code because the note never reached the audit row.
// ---------------------------------------------------------------------------

#[test]
fn update_memory_note_is_generic_not_set_subject_special_cased() {
    // The note-drop was not set_subject-specific: EVERY Rust mutation
    // discarded its annotation. Prove the fixed boundary forwards the
    // note for an ordinary bitmap mutation too: `contest`, whose arm
    // consumes the payload as its audit reason.
    //
    // (The other boundary call site, moot_confirm_memory, also forwards
    // the note now — but BOTH ports' Confirm ARMS hardcode their reason
    // and drop the forwarded payload, an out-of-scope arm defect recorded
    // in the MXE-SK completion report's Discoveries. End-to-end confirm
    // note delivery is asserted when that arm is fixed.)
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let id = capture_without_subject(&session, "Row contested with a note.", "subject-tests");

    let contested = session.call(
        "moot_update_memory",
        &args!["memory_id" => id.as_str(),
               "mutation" => "contest",
               "note" => "disputed by a later meeting recording"],
    )
    .expect("contest with note must succeed");
    assert!(is_success(&contested), "got: {contested:?}");

    let coord = session.coord.lock().unwrap();
    let estate = coord
        .estate_for(&session.default.handle)
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

#[test]
fn set_subject_preserves_custody_actor_verb_note_and_absent_note_reason() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let noted_id = capture_without_subject(&session, "Noted subject backfill.", "subject-tests");
    let plain_id = capture_without_subject(&session, "Plain subject backfill.", "subject-tests");

    for (id, subject, note) in [
        (noted_id.as_str(), "Noted subject.", Some("backfilled during custody verification")),
        (plain_id.as_str(), "Plain subject.", None),
    ] {
        let mut request = args![
            "memory_id" => id,
            "mutation" => "set_subject",
            "subject" => subject,
        ];
        if let Some(note) = note {
            request.insert("note".to_owned(), JsonValue::from(serde_json::json!(note)));
        }
        let result = session.call("moot_update_memory", &request)
            .expect("selected-v2 set_subject must return a result");
        assert!(is_success(&result), "set_subject must succeed: {result:?}");
    }

    let coord = session.coord.lock().unwrap();
    let estate = coord.estate_for(&session.default.handle).unwrap();
    let noted: Vec<_> = estate.audit_trail(&noted_id).unwrap().into_iter()
        .filter(|event| event.verb == "setSubject").collect();
    assert_eq!(noted.len(), 1, "exactly one setSubject custody event is required");
    assert_eq!(noted[0].actor, "estate", "selected-v2 custody actor must remain stable");
    assert_eq!(noted[0].reason.as_deref(), Some("backfilled during custody verification"));

    let plain: Vec<_> = estate.audit_trail(&plain_id).unwrap().into_iter()
        .filter(|event| event.verb == "setSubject").collect();
    assert_eq!(plain.len(), 1, "an absent note still seals exactly one custody event");
    assert_eq!(plain[0].actor, "estate", "selected-v2 custody actor must remain stable");
    assert_eq!(plain[0].reason, None, "an omitted note must remain an absent audit reason");
}

// ---------------------------------------------------------------------------
// 5. moot_file_fact subject contract (ARIA-MSG-2)
// ---------------------------------------------------------------------------

#[test]
fn file_fact_oversize_subject_returns_contract_error() {
    // Subject contract violation on moot_file_fact remains a typed
    // invalid-argument fault. Mirrors the Swift contract test.
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let n = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT + 1;
    let oversize: String = "x".repeat(n);
    let err = session.call(
        "moot_file_fact",
        &args!["subject" => oversize.as_str(),
               "predicate" => "worksAt",
               "object" => "Acme"],
    )
    .expect_err("oversize fact subject must be rejected by selected v2");
    assert_eq!(err.code, -32602, "got: {err:?}");
    assert_eq!(error_path(&err), "$.subject", "got: {err:?}");
}
