// packager_parity.rs
//
// Cross-port conformance test for GLKResultsPackager (Adams Finding 7).
//
// Reads ONE shared JSON fixture at
//   Tests/Conformance/packager_golden_pins.json
// and asserts identical level/confidence/has_answer_block/row_count per
// gate branch — the golden-pin-twin discipline: one fixture, two ports,
// same assertions.
//
// The Swift twin is
//   Tests/GeniusLocusKitTests/GLKResultsPackagerParityTests.swift
// and must pass on the same fixture with the same expected values.
//
// Pins covered:
//   pin-A: never mode → rowsOnly, all hits, no cliff cutoff
//   pin-B: CONFIDENT gate (m1≥t1, m2≥t2, m4=true) → l0AnswerOnly
//   pin-C: INTERMEDIATE gate (m2<t2) → l1Full with answer block
//   pin-D: WEAK gate (m1<t1') → rowsOnly, no answer block (spec §5)

use std::path::PathBuf;

use genius_locus_kit::packager::{
    GLKResultsPackager, PackagerAnswerMode, PackagerConfidenceLevel, PackagerThresholds,
};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, RecallEvidencePath, RecallFallbackPolicy,
    RecallHit, RecallOrigin, RecallPlan, RecallScoreVector, RecallUnionProfile, RecallWeights,
};
use locus_kit::drawer::Drawer;
use locus_kit::filter::RecallFrame;

// ---------------------------------------------------------------------------
// Fixture parsing
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct Fixture {
    pins: Vec<Pin>,
    thresholds: ThresholdFixture,
}

#[derive(serde::Deserialize)]
struct ThresholdFixture {
    t1: f64,
    t2: f64,
    t1_prime: f64,
    t3_prime: f64,
    c: f64,
    k_min: usize,
    k_max: usize,
}

#[derive(serde::Deserialize)]
struct Pin {
    id: String,
    mode: String,
    composed_answer: Option<String>,
    signal_agreement: f32,
    hits: Vec<HitFixture>,
    expected: ExpectedFixture,
}

#[derive(serde::Deserialize)]
struct HitFixture {
    id: String,
    final_score: f32,
    dense_score: f32,
    drawer_content: Option<String>,
}

#[derive(serde::Deserialize)]
struct ExpectedFixture {
    level: String,
    confidence: Option<String>,
    has_answer_block: bool,
    row_count: usize,
    total_count: usize,
}

// ---------------------------------------------------------------------------
// Helpers that mirror GLKResultsPackagerTests.swift fixture helpers
// ---------------------------------------------------------------------------

/// Minimal GLKRecallRequest for fixture use (same defaults as Swift).
fn fixture_request() -> GLKRecallRequest {
    GLKRecallRequest::new(
        RecallFrame::new(vec![]),
        GLKRecallMode::LocusOnly,
        genius_locus_kit::recall::GLKRecallScoring::Raw,
        20,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
}

/// Minimal RecallPlan for fixture use.
fn fixture_plan() -> RecallPlan {
    RecallPlan {
        effective_mode: GLKRecallMode::LocusOnly,
        frontier_k: 64,
        weights: RecallWeights::UNIFORM,
    }
}

/// Build a RecallHit from fixture values.
fn make_hit(hf: &HitFixture) -> RecallHit {
    let drawer = hf.drawer_content.as_deref().map(|content| {
        Drawer::new(&hf.id, content, "test-wing-id", "packager-parity-test", 0, "test-model-v1")
    });
    RecallHit {
        id: hf.id.clone(),
        drawer,
        sources: vec![RecallEvidencePath::LocusBitmap],
        score: RecallScoreVector {
            locus: hf.final_score,
            bm25: 0.0,
            vector: 0.0,
            field_fit: 0.0,
            co_occurrence: 0.0,
            temporal: 0.0,
            graph: 0.0,
            preference: 0.0,
            redundancy_penalty: 0.0,
            final_score: hf.final_score,
            dense: hf.dense_score,
        },
        explanation: vec![],
        span_hit: None,
    }
}

/// Build a GLKRecallResult from fixture hits and signal_agreement.
fn make_result(hits: Vec<RecallHit>, signal_agreement: f32) -> GLKRecallResult {
    let union_profile = if signal_agreement > 0.0 {
        Some(RecallUnionProfile {
            locus_sharpness: 0.5,
            bm25_sharpness: 0.0,
            vector_sharpness: 0.0,
            signal_agreement,
            redundancy: 0.0,
            matrix_coherence: 0.0,
        })
    } else {
        None
    };
    GLKRecallResult {
        request: fixture_request(),
        plan: fixture_plan(),
        union_profile,
        hits,
        dense_lane_status: None,
        degraded_stages: vec![],
        lane_ranks: std::collections::HashMap::new(),
        query_lattice_anchor: None,
    }
}

/// Map mode string from fixture JSON to PackagerAnswerMode.
fn parse_mode(s: &str) -> PackagerAnswerMode {
    match s {
        "never" => PackagerAnswerMode::Never,
        "always" => PackagerAnswerMode::Always,
        "auto" => PackagerAnswerMode::Auto,
        other => panic!("unknown mode in fixture: {other}"),
    }
}

/// Map expected level string to a comparable tag for assertions.
fn level_tag(packaged: &genius_locus_kit::packager::GLKPackagedResult) -> &'static str {
    match packaged.level {
        genius_locus_kit::packager::GLKResponseLevel::L0AnswerOnly => "l0AnswerOnly",
        genius_locus_kit::packager::GLKResponseLevel::L1Full => "l1Full",
        genius_locus_kit::packager::GLKResponseLevel::RowsOnly => "rowsOnly",
    }
}

/// Map confidence to a string for assertion.
fn confidence_tag(c: PackagerConfidenceLevel) -> &'static str {
    match c {
        PackagerConfidenceLevel::Confident => "confident",
        PackagerConfidenceLevel::Intermediate => "intermediate",
        PackagerConfidenceLevel::Weak => "weak",
    }
}

// ---------------------------------------------------------------------------
// Parity test — reads the shared fixture and asserts all pins
// ---------------------------------------------------------------------------

#[test]
fn packager_golden_pins_match_swift_twin() {
    // Resolve the shared fixture path relative to this crate's Cargo.toml.
    // CARGO_MANIFEST_DIR is the absolute path to the crate root (the rust/ dir).
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_path = manifest_dir.join("../Tests/Conformance/packager_golden_pins.json");

    let raw = std::fs::read_to_string(&fixture_path).unwrap_or_else(|e| {
        panic!(
            "Could not read packager fixture at {}: {e}",
            fixture_path.display()
        )
    });

    let fixture: Fixture = serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("Could not parse packager fixture: {e}"));

    let thresholds = PackagerThresholds {
        t1: fixture.thresholds.t1,
        t2: fixture.thresholds.t2,
        t1_prime: fixture.thresholds.t1_prime,
        t3_prime: fixture.thresholds.t3_prime,
        c: fixture.thresholds.c,
        k_min: fixture.thresholds.k_min,
        k_max: fixture.thresholds.k_max,
    };

    let packager = GLKResultsPackager::new();

    for pin in &fixture.pins {
        let hits: Vec<RecallHit> = pin.hits.iter().map(make_hit).collect();
        let result = make_result(hits, pin.signal_agreement);
        let mode = parse_mode(&pin.mode);
        let composed = pin.composed_answer.as_deref();

        let packaged = packager.package(&result, mode, composed, thresholds);

        // Assert level matches fixture.
        let actual_level = level_tag(&packaged);
        assert_eq!(
            actual_level, pin.expected.level,
            "[{}] level mismatch: expected '{}', got '{}'",
            pin.id, pin.expected.level, actual_level
        );

        // Assert has_answer_block matches fixture.
        let has_block = packaged.answer_block.is_some();
        assert_eq!(
            has_block, pin.expected.has_answer_block,
            "[{}] has_answer_block mismatch: expected {}, got {}",
            pin.id, pin.expected.has_answer_block, has_block
        );

        // Assert confidence matches fixture when expected.
        if let Some(ref expected_conf) = pin.expected.confidence {
            let block = packaged.answer_block.as_ref().unwrap_or_else(|| {
                panic!("[{}] expected answer block with confidence '{}', got None", pin.id, expected_conf)
            });
            let actual_conf = confidence_tag(block.confidence_level);
            assert_eq!(
                actual_conf, expected_conf.as_str(),
                "[{}] confidence mismatch: expected '{}', got '{}'",
                pin.id, expected_conf, actual_conf
            );
        } else {
            assert!(
                packaged.answer_block.is_none(),
                "[{}] expected no answer block but got Some (spec §5: WEAK must not carry answer)",
                pin.id
            );
        }

        // Assert row_count matches fixture.
        assert_eq!(
            packaged.rows.len(), pin.expected.row_count,
            "[{}] row_count mismatch: expected {}, got {}",
            pin.id, pin.expected.row_count, packaged.rows.len()
        );

        // Assert total_count matches fixture.
        assert_eq!(
            packaged.total_count, pin.expected.total_count,
            "[{}] total_count mismatch: expected {}, got {}",
            pin.id, pin.expected.total_count, packaged.total_count
        );
    }
}
