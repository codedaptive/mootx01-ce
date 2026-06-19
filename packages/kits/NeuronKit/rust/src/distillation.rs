// distillation.rs
//
// Thin NeuronKit lens wrapper over SubstrateML.DistillationPipeline.
//
// Responsibilities:
//   1. Define the NeuronKit lens result shape (DistillationLensResult + InjectionDepth).
//   2. Provide distill_cluster() which calls DistillationPipeline::run() and
//      projects DistillationOutput → DistillationLensResult.
//
// No pipeline logic in this file. See SubstrateML/distillation_pipeline.rs.
// Layer discipline: no I/O, no state, no estate access. Pure function.
//
// Swift port pending (Dn1). Will mirror NeuronKit/Lenses/Distillation.swift once Dn1 lands.
// InjectionDepth thresholds must stay in lockstep with the Swift port.

use substrate_ml::delta_feature_extractor::DeltaType;
use substrate_ml::distillation_pipeline::{
    DistillationInput, DistillationOutput, DistillationPipeline, FeatureExtractor,
};

/// NeuronKit-layer result shape. Carries the SubstrateML output plus
/// InjectionDepth, which is computed here from confidence for recipe convenience.
///
/// Mirrors Swift DistillationLensResult in Distillation.swift (Dn1).
#[derive(Debug, Clone, PartialEq)]
pub struct DistillationLensResult {
    /// Pass-through from DistillationOutput.drawer_content.
    pub drawer_content: String,
    /// Confidence score conf(F*) ∈ [0, 1].
    pub confidence: f32,
    /// True when conf ∈ [0.4, 0.7): signal to inject with additional provenance.
    pub uncertain: bool,
    /// Cluster SNR at distillation time.
    pub snr: f32,
    /// DeltaType of the dominant feature, if non-static.
    pub delta_type: Option<DeltaType>,
    /// True when a factoid was successfully produced.
    pub succeeded: bool,
    /// Human-readable failure reason when succeeded == false.
    pub failure_reason: Option<String>,
    /// Governs how much provenance context the ARIA layer appends alongside prose.
    pub injection_depth: InjectionDepth,
}

/// Controls how much provenance context is injected alongside a factoid in
/// ARIA responses. Thresholds must match Swift InjectionDepth in Distillation.swift.
///
/// conf >= 0.7  → FactoidOnly          (prose only, high confidence)
/// conf ∈ [0.4, 0.7) → FactoidWithMeta      (prose + distillation metadata)
/// conf < 0.4   → FactoidWithProvenance (prose + metadata + source drawer IDs)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectionDepth {
    /// conf >= 0.7: prose only.
    FactoidOnly,
    /// conf ∈ [0.4, 0.7): prose + [distilled from N memories, conf=X].
    FactoidWithMeta,
    /// conf < 0.4: prose + [distilled, conf=X, sources: drawer_id].
    FactoidWithProvenance,
}

impl InjectionDepth {
    /// Derive injection depth from a confidence score.
    /// Thresholds are identical to Swift InjectionDepth (Dn1).
    fn from_confidence(confidence: f32) -> InjectionDepth {
        if confidence >= 0.7 {
            InjectionDepth::FactoidOnly
        } else if confidence >= 0.4 {
            InjectionDepth::FactoidWithMeta
        } else {
            InjectionDepth::FactoidWithProvenance
        }
    }
}

/// Thin wrapper: calls DistillationPipeline::run() and projects the result.
///
/// `extract_features` is the feature extraction seam. Pass `None` to use
/// a no-op stub (returns no features for every memory — suitable for tests
/// that verify the pass-through fields without exercising the pipeline math).
///
/// Production callers supply the EideticLib HMM tagger; test callers supply
/// a stub or None. Mirrors Swift NeuronKit.distillCluster in Distillation.swift.
pub fn distill_cluster(
    input: &DistillationInput,
    extract_features: Option<FeatureExtractor>,
) -> DistillationLensResult {
    // Use the provided extractor or fall back to a no-op stub for testing.
    // The no-op returns empty feature lists, which causes the pipeline to
    // produce a failure output — suitable for pass-through field tests.
    let extractor: FeatureExtractor = extract_features.unwrap_or(stub_extractor);
    let output: DistillationOutput = DistillationPipeline::run(input, extractor);

    let injection_depth = InjectionDepth::from_confidence(output.confidence);

    DistillationLensResult {
        drawer_content: output.drawer_content,
        confidence: output.confidence,
        uncertain: output.uncertain,
        snr: output.snr,
        delta_type: output.delta_type,
        succeeded: output.succeeded,
        failure_reason: output.failure_reason,
        injection_depth,
    }
}

/// No-op feature extractor stub. Returns an empty feature list for every
/// (memory, feature_type) pair. Used when no extractor is supplied to
/// distill_cluster — allows pass-through field assertions without pulling
/// in the full EideticLib dependency path.
fn stub_extractor(
    _memory: &str,
    _feature_type: substrate_ml::typed_decay_weighting::DistillationFeatureType,
) -> Vec<substrate_ml::distillation_scorer::ExtractedFeature> {
    vec![]
}

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_ml::distillation_pipeline::DistillationInput;

    fn make_input(contents: Vec<&str>) -> DistillationInput {
        DistillationInput::new(
            contents.into_iter().map(|s| s.to_string()).collect(),
            None,
            "test-cluster-id",
            vec!["src-1".to_string(), "src-2".to_string()],
        )
    }

    // pass-through: drawer_content from output reaches lens result unchanged.
    // With the stub extractor the pipeline fails (no features), so
    // drawer_content will be empty and succeeded = false — we assert both.
    #[test]
    fn stub_pass_through_fields() {
        let input = make_input(vec!["memory one", "memory two", "memory three"]);
        let result = distill_cluster(&input, None);
        // Stub extractor produces no features → pipeline fails.
        assert!(!result.succeeded);
        assert_eq!(result.drawer_content, "");
        assert_eq!(result.confidence, 0.0);
    }

    // InjectionDepth threshold: conf=0.85 → FactoidOnly
    #[test]
    fn injection_depth_factoid_only() {
        assert_eq!(
            InjectionDepth::from_confidence(0.85),
            InjectionDepth::FactoidOnly
        );
        // Boundary: exactly 0.7
        assert_eq!(
            InjectionDepth::from_confidence(0.7),
            InjectionDepth::FactoidOnly
        );
    }

    // InjectionDepth threshold: conf=0.55 → FactoidWithMeta
    #[test]
    fn injection_depth_factoid_with_meta() {
        assert_eq!(
            InjectionDepth::from_confidence(0.55),
            InjectionDepth::FactoidWithMeta
        );
        // Boundary: exactly 0.4
        assert_eq!(
            InjectionDepth::from_confidence(0.4),
            InjectionDepth::FactoidWithMeta
        );
    }

    // InjectionDepth threshold: conf=0.30 → FactoidWithProvenance
    #[test]
    fn injection_depth_factoid_with_provenance() {
        assert_eq!(
            InjectionDepth::from_confidence(0.30),
            InjectionDepth::FactoidWithProvenance
        );
        // Boundary: just below 0.4
        assert_eq!(
            InjectionDepth::from_confidence(0.3999),
            InjectionDepth::FactoidWithProvenance
        );
    }

    // distill_cluster returns DistillationLensResult (not a raw DistillationOutput).
    // Verify the lens wraps correctly by inspecting type presence.
    #[test]
    fn result_type_is_lens_result() {
        let input = make_input(vec!["a", "b", "c"]);
        let _result: DistillationLensResult = distill_cluster(&input, None);
    }

    // injection_depth field is present on the result struct.
    #[test]
    fn result_has_injection_depth_field() {
        let input = make_input(vec!["a", "b", "c"]);
        let result = distill_cluster(&input, None);
        // With confidence 0.0 (stub failure), expect FactoidWithProvenance.
        assert_eq!(result.injection_depth, InjectionDepth::FactoidWithProvenance);
    }
}
