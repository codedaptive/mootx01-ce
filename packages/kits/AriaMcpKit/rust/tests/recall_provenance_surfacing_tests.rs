//! recall_provenance_surfacing_tests.rs — force-tests that the Rust
//! `moot_memory_search` dispatch always surfaces a `recall_provenance:` status
//! line in the tool response, and that the dense-lane token correctly reflects
//! retrieval quality.
//!
//! # What these tests prove (PR-03 deviation-only contract)
//!
//! The recall_provenance line is DEVIATION-ONLY: it appears when the dense
//! lane is dark or stages degraded, and its ABSENCE means nominal.
//!
//! 1. `provenance_line_absent_on_nominal_recall` — a search over an estate
//!    wired with the deterministic provider (Lane D live, nothing degraded)
//!    emits NO recall_provenance: line. Absence IS the nominal signal.
//!
//! 2. `dense_lane_active_when_corpus_wired_and_ingested` — when a corpus
//!    with the deterministic provider is registered and a document has been
//!    impatient-captured (float rows written), Lane D is live and the line
//!    is absent — proving dense_lane_status None maps to silence.
//!
//! 3. `degraded_stages_none_on_happy_path` — a successful recall with no
//!    pipeline failures surfaces "degraded_stages:none". This proves the
//!    `degraded_stages` field round-trips through the response correctly.
//!
//! 4. `provenance_line_present_on_zero_results` — when the estate is empty
//!    (zero hits), the recall_provenance: line is still emitted. Provenance is
//!    not conditional on hit count.
//!
//! These tests mirror the Swift RecallProvenanceSurfacingTests.swift and
//! confirm parity of the recall provenance surfacing feature across both ports.
//!
//! Rationale: selectable embedding providers requires the ARIA
//! surface to let callers distinguish "real semantic space" from
//! "deterministic/structural fallback". The kit computes dense_lane_status and
//! degraded_stages but they were silently dropped at the Rust ARIA boundary
//! before this mission. These tests close the gap and prevent regression.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    recall_discrimination::{classify, result_line_with_dense_dark, DiscriminationLevel},
    surfaced_recall_ledger::SurfacedRecallLedger,
};

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

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

// ---------------------------------------------------------------------------
// 1. Provenance line always present (deterministic provider)
// ---------------------------------------------------------------------------

/// Prove that moot_memory_search always appends a recall_provenance: status
/// line in the response, regardless of hit count. Uses the full semantic
/// recall stack (corpus + vector store, deterministic provider).
///
/// Mirrors Swift test A: provenanceLineAlwaysPresentDeterministicProvider.
#[test]
fn provenance_line_absent_on_nominal_recall() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Impatient capture so content is immediately in BM25/vector lanes.
    let capture_args = args![
        "content" => "peregrine falcon stoop dive speed aerial predator",
        "subject" => "peregrine falcon stoop dive speed aerial predator",
        "location" => "birds/falcons",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory must not fail");
    assert!(
        is_success(&capture_result),
        "impatient moot_file_memory should succeed; got: {capture_result:?}"
    );

    let search_args = args![
        "query" => "peregrine falcon speed",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search must not fail");
    assert!(
        is_success(&search_result),
        "moot_memory_search should succeed; got: {search_result:?}"
    );

    let text = content_text(&search_result);
    // PR-03 deviation-only contract: nominal recall (Lane D live, nothing
    // degraded) emits NO provenance line — absence IS the signal.
    assert!(
        !text.contains("recall_provenance:"),
        "nominal recall must NOT include a recall_provenance: line (deviation-only); got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 2. Dense lane active when corpus is wired and docs are ingested
// ---------------------------------------------------------------------------

/// Prove that "dense_lane:active" appears in the provenance line when
/// the deterministic provider is registered and float rows are present.
///
/// The deterministic provider implements embed_float and stores Lane D rows
/// at ingest time. A search after impatient capture therefore has Lane D live,
/// which means GLKRecallResult.dense_lane_status is None → "dense_lane:active".
///
/// Mirrors Swift test C: denseLaneActiveWhenCorpusWiredAndIngested.
#[test]
fn dense_lane_active_when_corpus_wired_and_ingested() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Impatient capture writes directly into the Corpus (BM25 + float rows).
    let capture_args = args![
        "content" => "merlin small falcon moorland heather hunting pipits",
        "subject" => "merlin small falcon moorland heather hunting pipits",
        "location" => "birds/falcons",
        "impatient" => true,
    ];
    dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory must not fail");

    let search_args = args![
        "query" => "merlin moorland hunting",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search must not fail");
    assert!(is_success(&search_result), "search must succeed; got: {search_result:?}");

    let text = content_text(&search_result);
    // When the corpus is wired with the deterministic provider and documents
    // are ingested, Lane D is live (dense_lane_status None) — under the
    // PR-03 deviation-only contract that means NO provenance line at all.
    assert!(
        !text.contains("recall_provenance:"),
        "Lane D live must render as ABSENCE of the provenance line; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 3. Degraded stages "none" on happy path
// ---------------------------------------------------------------------------

/// Prove that "degraded_stages:none" appears in the provenance line when
/// the recall pipeline completes without errors. A successful impatient
/// capture + search against the in-memory estate has no degraded stages.
///
/// Mirrors Swift test A's secondary assertion on degraded_stages.
#[test]
fn degraded_stages_none_on_happy_path() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let capture_args = args![
        "content" => "hobby falcon aerial insect hunting speed agility summer visitor",
        "subject" => "hobby falcon aerial insect hunting speed agility summer visitor",
        "location" => "birds/falcons",
        "impatient" => true,
    ];
    dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory must not fail");

    let search_args = args![
        "query" => "hobby falcon agility",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search must not fail");
    assert!(is_success(&search_result));

    let text = content_text(&search_result);
    // Happy path: every pipeline stage succeeded and Lane D is live — under
    // the PR-03 deviation-only contract the provenance line is absent.
    assert!(
        !text.contains("recall_provenance:"),
        "Happy-path recall must omit the provenance line entirely; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 4. Provenance line present even on zero results
// ---------------------------------------------------------------------------

/// Prove that the recall_provenance: line is emitted even when the query
/// returns zero hits. The field must never be conditionally omitted.
///
/// Mirrors Swift test D: provenanceLinePresentOnZeroResults.
#[test]
fn provenance_line_present_on_zero_results() {
    // Fresh registry with no captures — estate is empty. _bare: no seeded
    // AI_Charter_Hint wing drawers, so a no-match query returns "found 0".
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    let search_args = args![
        "query" => "osprey fish plunge-diving",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search must not fail");
    assert!(is_success(&search_result));

    let text = content_text(&search_result);

    assert!(
        text.starts_with("found 0"),
        "Empty estate should return 0 results; got: {text}"
    );
    assert!(
        text.contains("recall_provenance:"),
        "recall_provenance: must be present even on zero-result queries; got: {text}"
    );
    // The provenance line must still carry both tokens even with 0 hits.
    let provenance_line = text
        .lines()
        .find(|l| l.starts_with("recall_provenance:"))
        .unwrap_or("");
    assert!(
        provenance_line.contains("dense_lane:"),
        "provenance line must carry dense_lane: token even with 0 hits; got: {provenance_line}"
    );
    assert!(
        provenance_line.contains("degraded_stages:"),
        "provenance line must carry degraded_stages: token even with 0 hits; got: {provenance_line}"
    );
}

// ---------------------------------------------------------------------------
// FIX 1: dense-lane-dark cap — discrimination must NOT claim "high" when the
// semantic vector lane was dark (dense_lane_status is Some(_)). Parity with
// Swift RecallDiscriminationTests.highDiscriminationIsNotClaimedWhenDenseLaneIsDark.
// ---------------------------------------------------------------------------

/// Unit test: result_line_with_dense_dark caps High → Medium when dark.
///
/// This mirrors Swift `highDiscriminationIsNotClaimedWhenDenseLaneIsDark`.
/// Scores [1.0, 0.5, 0.3] produce a topGap of 0.5 ≥ HIGH_MARGIN (0.25),
/// so classify() returns High. With dense_lane_dark=true the surface line
/// must NOT claim "high — clear top result" because the ranking is
/// lexical-only and cannot be trusted as semantically ranked.
#[test]
fn high_discrimination_is_not_claimed_when_dense_lane_is_dark() {
    let level = classify(&[1.0, 0.5, 0.3]);
    assert_eq!(
        level,
        DiscriminationLevel::High,
        "classify([1.0, 0.5, 0.3]) must return High; got: {level:?}"
    );

    // With dense_lane_dark=true the result line must cap to medium.
    let line = result_line_with_dense_dark(level, true);
    assert!(
        !line.contains("discrimination: high"),
        "dark lane must cap 'high' to 'medium'; got: {line}"
    );
    assert!(
        line.contains("discrimination: medium"),
        "dark lane cap must produce 'medium' signal; got: {line}"
    );
    assert!(
        line.contains("semantic lane dark"),
        "dark lane cap line must name the reason; got: {line}"
    );
    assert!(
        line.contains("moot_recall_precise"),
        "dark lane cap line must direct to precise recall; got: {line}"
    );
}

/// Unit test: result_line_with_dense_dark does NOT cap High when lane is active.
///
/// When dense_lane_dark=false the high signal is unchanged.
/// Parity with Swift `denseLaneDarkFalseDoesNotCapHigh`.
#[test]
fn dense_lane_dark_false_does_not_cap_high() {
    let level = classify(&[1.0, 0.5, 0.3]);
    let line = result_line_with_dense_dark(level, false);
    assert!(
        line.contains("discrimination: high"),
        "active lane must not cap high; got: {line}"
    );
    assert!(
        !line.contains("semantic lane dark"),
        "active lane must not add dark-lane caveat; got: {line}"
    );
}

/// Unit test: dense-lane-dark cap does NOT affect Medium or Low.
///
/// Only High is capped; Medium and Low are emitted as-is.
/// Parity with Swift `denseLaneDarkDoesNotCapMediumOrLow`.
#[test]
fn dense_lane_dark_does_not_cap_medium_or_low() {
    let medium_line = result_line_with_dense_dark(DiscriminationLevel::Medium, true);
    assert!(
        medium_line.contains("discrimination: medium"),
        "medium must pass through dark cap unchanged; got: {medium_line}"
    );
    assert!(
        !medium_line.contains("semantic lane dark"),
        "dark cap caveat must not appear on medium; got: {medium_line}"
    );

    let low_line = result_line_with_dense_dark(DiscriminationLevel::Low, true);
    assert!(
        low_line.contains("discrimination: low"),
        "low must pass through dark cap unchanged; got: {low_line}"
    );
    assert!(
        !low_line.contains("semantic lane dark"),
        "dark cap caveat must not appear on low; got: {low_line}"
    );
}
