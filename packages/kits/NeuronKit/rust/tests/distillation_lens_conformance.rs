//! Distillation lens conformance tests — Rust half of the cross-language gate.
//!
//! Drives the same cluster_5 fixture as the Swift leg
//! (DistillationLensConformanceTests.swift) through `distill_cluster` and
//! asserts the same field values, establishing Swift-Rust parity.
//!
//! cluster_5: Alice+CERN appear in 4/5 memories (df=0.8 > τ_maj for M=5),
//! M5 has no features. The capitalization-heuristic default_extractor produces
//! succeeded=true and confidence >= 0.7 on this fixture.
//!
//! Cross-language contract:
//!   - drawer_content starts with "[DIST|" (both legs assert this)
//!   - confidence matches the pipeline output (pass-through)
//!   - injection_depth == FactoidOnly for confidence >= 0.7 (both legs assert this)

use neuron_kit::{distill_cluster, InjectionDepth};
use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};

// cluster_5 fixture: identical contents to the Swift leg.
// Cluster ID "test-cluster-dp2" avoids collision with existing pipeline tests.
fn cluster_5() -> DistillationInput {
    DistillationInput::new(
        vec![
            "Research by Alice at CERN on particle physics".to_string(),
            "The lab where Alice works is CERN facility".to_string(),
            "Studies conducted by Alice show CERN advances science".to_string(),
            "Data from CERN shows Alice leading breakthrough research".to_string(),
            "Maintenance was completed on schedule today".to_string(),
        ],
        None,
        "test-cluster-dp2",
        (0..5).map(|i| format!("src-{i}")).collect(),
    )
}

// drawer_content starts with "[DIST|" — DIST header format per DISTILLATION_DESIGN.md §1.
// Mirrors the Swift "cluster_5: drawerContent starts with [DIST| marker" test.
#[test]
fn cluster_5_drawer_content_starts_with_dist_marker() {
    let input = cluster_5();
    let result = distill_cluster(&input, Some(DistillationPipeline::default_extractor));
    assert!(
        result.succeeded,
        "pipeline should succeed for cluster_5; failure_reason={:?}",
        result.failure_reason
    );
    assert!(
        result.drawer_content.starts_with("[DIST|"),
        "drawer_content must start with [DIST|, got: {}",
        result.drawer_content
    );
}

// confidence is passed through from DistillationOutput unchanged.
// Running the pipeline directly and through the lens must yield identical confidence.
// Mirrors the Swift "cluster_5: confidence equals pipeline output (pass-through)" test.
#[test]
fn cluster_5_confidence_pass_through() {
    let input = cluster_5();
    let pipeline_output = DistillationPipeline::run(&input, DistillationPipeline::default_extractor, false);
    let lens_result = distill_cluster(&input, Some(DistillationPipeline::default_extractor));
    assert!(
        (lens_result.confidence - pipeline_output.confidence).abs() < 1e-6,
        "lens confidence must match pipeline confidence: lens={} pipeline={}",
        lens_result.confidence,
        pipeline_output.confidence
    );
}

// injection_depth == FactoidOnly for cluster_5.
// cluster_5 produces confidence >= 0.7 with default_extractor, placing it in
// the FactoidOnly range (conf >= 0.7) per InjectionDepth thresholds.
// Mirrors the Swift "cluster_5: injectionDepth is .factoidOnly (conf >= 0.7)" test.
#[test]
fn cluster_5_injection_depth_factoid_only() {
    let input = cluster_5();
    let result = distill_cluster(&input, Some(DistillationPipeline::default_extractor));
    assert!(
        result.confidence >= 0.7,
        "expected confidence >= 0.7 for cluster_5, got {}",
        result.confidence
    );
    assert_eq!(
        result.injection_depth,
        InjectionDepth::FactoidOnly,
        "expected FactoidOnly for confidence >= 0.7"
    );
}
