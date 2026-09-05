//! preference_window_conformance_tests.rs — PREF-1 conformance vector.
//!
//! Shared 1,200-trace conformance vector for both ports.
//!
//! Design:
//!   oldest 100 traces: drawer-X endorsed (used=true), sorted to front.
//!   next  100 traces:  drawer-Y dismissed (used=false).
//!   newest 1,000 traces: drawer-Y endorsed (used=true).
//!
//! Without window (all 1,200):
//!   X = 100e / 0d → BT ratio (100+1)/(0+1) = 101.
//!   Y = 1,000e / 100d → BT ratio (1,000+1)/(100+1) ≈ 9.9.
//!   → X ranks above Y  (the pre-fix behaviour: mutation control).
//!
//! With PREFERENCE_TRACES_WINDOW_LIMIT = 1,000 (suffix of ascending recalled_at):
//!   Only Y-endorsement traces are in the window; X is absent.
//!   → Y ranks above X (correct; fixed-port behaviour).
//!
//! Pre-fix Rust result (recorded in PREF-1_REPORT.md): X above Y.

use locus_kit::recall_trace_item::RecallTraceItem;
use neuron_kit::autonomic_governor::PREFERENCE_TRACES_WINDOW_LIMIT;
use neuron_kit::preference_producer::{compute_preference_scores, preference_outcomes};

/// Build a synthetic RecallTraceItem for the conformance vector.
/// `recalled_at_iso` must be a zero-padded ISO8601 string so lexicographic
/// order equals chronological order (the storage contract).
fn make_trace(id: &str, target: &str, recalled_at_iso: &str, used: bool) -> RecallTraceItem {
    RecallTraceItem::new(
        id,
        target,
        recalled_at_iso,
        None,  // score: not used by preference_outcomes
        if used { RecallTraceItem::FLAG_USED } else { 0 },
    )
}

/// Format an integer second offset as a zero-padded ISO8601 string.
/// Base epoch: 2023-11-14T22:13:20Z (1_700_000_000 Unix seconds).
/// Offsets 0..1199 fit in the same day.
fn ts(offset_secs: u32) -> String {
    // Base: 2023-11-14T22:13:20Z.  We only need lexicographic ordering to
    // be correct, which zero-padded hour:minute:second fields guarantee.
    // 22:13:20 + up to 1,199 seconds = up to 22:33:19 — still same day.
    let base_secs = 22 * 3600 + 13 * 60 + 20; // 79,400 seconds into the day
    let total_secs = base_secs + offset_secs;
    let h = total_secs / 3600;
    let m = (total_secs % 3600) / 60;
    let s = total_secs % 60;
    format!("2023-11-14T{h:02}:{m:02}:{s:02}Z")
}

#[test]
fn preference_window_1000_trace_conformance_vector() {
    // Build 1,200 traces in ascending recalled_at order.
    let mut traces: Vec<RecallTraceItem> = Vec::with_capacity(1_200);

    // Oldest 100: drawer-X endorsed (seconds 0..99).
    for i in 0_u32..100 {
        traces.push(make_trace(
            &format!("x-end-{i}"),
            "drawer-X",
            &ts(i),
            true, // endorsement
        ));
    }
    // Next 100: drawer-Y dismissed (seconds 100..199).
    for i in 0_u32..100 {
        traces.push(make_trace(
            &format!("y-dis-{i}"),
            "drawer-Y",
            &ts(100 + i),
            false, // dismissal
        ));
    }
    // Newest 1,000: drawer-Y endorsed (seconds 200..1199).
    for i in 0_u32..1_000 {
        traces.push(make_trace(
            &format!("y-end-{i}"),
            "drawer-Y",
            &ts(200 + i),
            true, // endorsement
        ));
    }

    assert_eq!(traces.len(), 1_200, "vector must be exactly 1,200 traces");

    // ── Mutation control: without window, X ranks above Y ────────────────────
    // This is the pre-fix behaviour the PREFERENCE_TRACES_WINDOW_LIMIT corrects.
    let all_records = preference_outcomes(&traces);
    let all_scores = compute_preference_scores(&all_records)
        .expect("BT fit must succeed on well-formed records");
    let x_all = all_scores.get("drawer-X").copied().unwrap_or(0.0f32);
    let y_all = all_scores.get("drawer-Y").copied().unwrap_or(0.0f32);
    assert!(
        x_all > y_all,
        "mutation control: without window, X (100e/0d, BT ratio≈101) must outrank Y (1,000e/100d, BT ratio≈9.9); got X={x_all}, Y={y_all}"
    );

    // ── Windowed result: suffix of 1,000 → Y ranks above X ──────────────────
    // traces is sorted ascending by recalled_at; suffix == most-recent 1,000.
    let start = traces.len().saturating_sub(PREFERENCE_TRACES_WINDOW_LIMIT);
    let windowed = &traces[start..];
    assert_eq!(windowed.len(), 1_000);

    let windowed_records = preference_outcomes(windowed);
    let windowed_scores = compute_preference_scores(&windowed_records)
        .expect("BT fit must succeed on windowed records");
    let x_windowed = windowed_scores.get("drawer-X").copied().unwrap_or(0.0f32);
    let y_windowed = windowed_scores.get("drawer-Y").copied().unwrap_or(0.0f32);
    assert!(
        y_windowed > x_windowed,
        "with 1,000-trace window, Y (1,000e/0d) must rank above absent X (strength 0.0); got X={x_windowed}, Y={y_windowed}"
    );
}

#[test]
fn preference_window_limit_constant_parity() {
    // Verify the constant matches the Swift port value (1,000).
    assert_eq!(
        PREFERENCE_TRACES_WINDOW_LIMIT, 1_000,
        "PREFERENCE_TRACES_WINDOW_LIMIT must equal Swift's preferenceTracesWindowLimit = 1,000"
    );
}
