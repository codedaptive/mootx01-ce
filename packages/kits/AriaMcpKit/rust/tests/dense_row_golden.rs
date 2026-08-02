//! PR-03 golden suite for the dense row — Rust leg of the cross-port
//! fixture. The hardcoded golden strings here are byte-identical to
//! `DenseRowGoldenTests.swift`; the two ports cannot silently diverge in
//! separator, marker, field order, or date rendering.
//!
//! Also pins the harness-parser prefix of the deviation-only
//! discrimination line ("discrimination: low"), which the benchmarker
//! keys on.

use aria_mcp::dense_row;
use locus_kit::drawer::Drawer;

/// Fixed instant for the goldens: 2023-11-14T22:13:20Z (epoch seconds —
/// the flex renderer normalises either unit; the Swift twin uses the
/// same instant as a Date).
const GOLDEN_EPOCH: i64 = 1_700_000_000;

fn drawer(
    id: &str,
    subject: Option<&str>,
    udc_code: &str,
    qid: Option<&str>,
    provenance_sensitivity_raw: i64,
) -> Drawer {
    let mut d = Drawer::new(
        id,
        "golden fixture content — never shown in a dense row",
        "00000000-0000-4000-8000-0000000000aa",
        "golden",
        GOLDEN_EPOCH,
        "test-model-v1",
    );
    // Provenance sensitivity lives in bits 30–35 (cookbook §2.5); a
    // shifted raw value is the whole bitmap for a fresh fixture.
    d.provenance = provenance_sensitivity_raw << 30;
    d.udc_code = udc_code.to_string();
    d.wikidata_qid = qid.map(str::to_string);
    d.subject = subject.map(str::to_string);
    d.subject_pipeline_version = subject.map(|_| "ai-v1".to_string());
    d.subject_at = subject.map(|_| GOLDEN_EPOCH);
    d
}

#[test]
fn golden_full_row() {
    let d = drawer(
        "00000000-0000-4000-8000-000000000001",
        Some("Quarterly planning moved to Thursday; Sarah sends invites Monday."),
        "005.1",
        Some("Q937"),
        0,
    );
    assert_eq!(
        dense_row::render(&d),
        "00000000-0000-4000-8000-000000000001 · Quarterly planning moved to Thursday; Sarah sends invites Monday. · fdc:005.1 · qid:Q937 · 2023-11-14T22:13:20Z"
    );
}

#[test]
fn golden_subject_debt_row() {
    let d = drawer("00000000-0000-4000-8000-000000000002", None, "000", None, 0);
    assert_eq!(
        dense_row::render(&d),
        "00000000-0000-4000-8000-000000000002 · (no subject) · fdc:000 · qid:- · 2023-11-14T22:13:20Z"
    );
}

#[test]
fn golden_redacted_row_restricted() {
    // Redaction replaces the subject even when one is stored — the body's
    // access control must not leak through its summary. Restricted raw 32.
    let d = drawer(
        "00000000-0000-4000-8000-000000000003",
        Some("This stored subject must NOT appear."),
        "343",
        Some("Q7188"),
        32,
    );
    assert_eq!(
        dense_row::render(&d),
        "00000000-0000-4000-8000-000000000003 · [sensitivity: restricted — content redacted] · fdc:343 · qid:Q7188 · 2023-11-14T22:13:20Z"
    );
}

#[test]
fn golden_unhydrated_row() {
    assert_eq!(
        dense_row::render_unhydrated("00000000-0000-4000-8000-000000000004"),
        "00000000-0000-4000-8000-000000000004 · (no subject) · fdc:- · qid:- · -"
    );
}

#[test]
fn golden_empty_udc_renders_absent_marker() {
    let d = drawer(
        "00000000-0000-4000-8000-000000000005",
        Some("Empty lattice code renders the absent marker."),
        "",
        Some(""),
        0,
    );
    assert_eq!(
        dense_row::render(&d),
        "00000000-0000-4000-8000-000000000005 · Empty lattice code renders the absent marker. · fdc:- · qid:- · 2023-11-14T22:13:20Z"
    );
}

#[test]
fn golden_millisecond_epoch_normalises_to_same_instant() {
    // The Rust Drawer carries bare i64 instants in BOTH live conventions
    // (the documented unit trap, KI-003); the flex renderer must print the
    // same instant for ms input.
    let mut d = drawer(
        "00000000-0000-4000-8000-000000000006",
        Some("Millisecond-stamped row renders the same instant."),
        "004",
        None,
        0,
    );
    d.event_time = GOLDEN_EPOCH * 1000;
    assert_eq!(
        dense_row::render(&d),
        "00000000-0000-4000-8000-000000000006 · Millisecond-stamped row renders the same instant. · fdc:004 · qid:- · 2023-11-14T22:13:20Z"
    );
}

#[test]
fn discrimination_low_line_keeps_its_parser_prefix() {
    // The benchmarker keys on this prefix; PR-03 made the line
    // deviation-only but must not change its spelling.
    let line = aria_mcp::recall_discrimination::result_line(
        aria_mcp::recall_discrimination::DiscriminationLevel::Low,
    );
    assert!(
        line.starts_with("discrimination: low"),
        "harness parser contract: got {line}"
    );
}

// ---------------------------------------------------------------------------
// near: pivot and depth tiers (PR-03 functional verify) — mirrors the Swift
// nearPivot/depthTiers tests in DenseRowGoldenTests.swift.
// ---------------------------------------------------------------------------

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

fn file_memory(
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    content: &str,
    subject: &str,
) -> String {
    let r = dispatch_tool(
        "moot_file_memory",
        &args!["content" => content, "subject" => subject,
               "location" => "near-tests", "impatient" => true],
        registry,
        ledger,
    )
    .expect("file_memory must succeed");
    content_text(&r)
        .lines()
        .next()
        .unwrap_or("")
        .trim_start_matches("filed memory ")
        .to_string()
}

#[test]
fn near_pivot_returns_anchored_neighbors_excluding_anchor() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let anchor_id = file_memory(
        &registry, &ledger,
        "kestrel hovers over motorway verges hunting voles",
        "kestrel hovers over verges hunting voles");
    let _near = file_memory(
        &registry, &ledger,
        "kestrel hunting strategy: hover then drop on voles",
        "kestrel hover-and-drop hunting strategy");
    let _far = file_memory(
        &registry, &ledger,
        "unrelated pasta recipe with garlic and olive oil",
        "pasta recipe: garlic and olive oil");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["near" => anchor_id.as_str()],
        &registry,
        &ledger,
    )
    .expect("near pivot must succeed");
    let body = content_text(&result);
    assert!(!body.contains(&anchor_id),
        "the anchor must be excluded from its own neighbors: {body}");
    assert!(body.contains("kestrel hover-and-drop hunting strategy"),
        "the semantically-nearest row must surface: {body}");

    // Mutual exclusion is enforced.
    let err = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "x", "near" => anchor_id.as_str()],
        &registry,
        &ledger,
    )
    .expect_err("query+near must be rejected");
    assert!(err.message.contains("mutually exclusive"), "got: {}", err.message);
}

#[test]
fn depth_tiers_return_subject_distilled_full() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let content = "The staging deploy gate now requires two approvals before merge.";
    let id = file_memory(
        &registry, &ledger, content,
        "Staging deploy gate requires two approvals.");

    let body = |a: &BTreeMap<String, JsonValue>| -> String {
        let r = dispatch_tool("moot_memory_get", a, &registry, &ledger)
            .expect("memory_get must succeed");
        content_text(&r).to_string()
    };

    // subject tier: dense row only, no content.
    let subject_body = body(&args!["ids" => [id.as_str()], "depth" => "subject"]);
    assert!(subject_body.contains("Staging deploy gate requires two approvals."));
    assert!(!subject_body.contains(content),
        "subject tier must not haul content: {subject_body}");
    // distilled tier: fresh row owes a distillate → fallback marker + content.
    let distilled_body = body(&args!["ids" => [id.as_str()], "depth" => "distilled"]);
    assert!(distilled_body.contains("source: content (not yet distilled)"));
    assert!(distilled_body.contains(content));
    // full tier (single id, default): the original record shape.
    let full_body = body(&args!["id" => id.as_str()]);
    assert!(full_body.contains(&format!("memory {id}")));
    assert!(full_body.contains("content:"));
    assert!(full_body.contains(content));
    assert!(full_body.contains("subject: Staging deploy gate requires two approvals."));
}
