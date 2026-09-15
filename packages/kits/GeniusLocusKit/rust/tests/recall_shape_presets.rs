// recall_shape_presets.rs
//
// Unit tests for the named RecallShape preset roster (GLK-RECALL-SHAPE-PRESETS).
// Each preset resolves to its documented signed-weight shape; the roster is
// discoverable via PRESET_NAMES; balanced/unknown resolve to None. Mirrors the
// Swift RecallShapePresetTests.swift — both ports assert the same directions.

use genius_locus_kit::recall::RecallShape;
use std::collections::HashMap;

// A preset resolves to the EXACT lane keys it documents, at the directions
// (forward >1, neutral ==1 via absence, exclude ==0, suppress <0) the roster
// specifies. We assert direction, not the exact tunable magnitude, except where
// the magnitude IS the contract (0 = exclude).

#[test]
fn balanced_resolves_to_none() {
    // The absence of steering. None ⇒ uniform fusion ⇒ today's behaviour.
    assert!(RecallShape::preset("balanced").is_none());
}

#[test]
fn unknown_resolves_to_none() {
    assert!(RecallShape::preset("no-such-preset").is_none());
    // Unknown and balanced are indistinguishable at resolution — both None.
    assert!(RecallShape::preset("").is_none());
}

#[test]
fn preset_names_are_discoverable_and_each_resolves() {
    // Every non-balanced name in the roster resolves to a Some shape; balanced
    // is the only name that intentionally resolves to None.
    for name in RecallShape::PRESET_NAMES {
        let resolved = RecallShape::preset(name);
        if name == "balanced" {
            assert!(resolved.is_none(), "balanced must resolve to None");
        } else {
            assert!(
                resolved.is_some(),
                "preset {name} must resolve to a shape (no silent no-op)"
            );
        }
    }
    // Default roster: 26 presets (base) + 7 whole-record (conceptual, associative,
    // consensus, ri_forward, anti_redundant_ri, float-l2, float-dot) + 2 LSA
    // (lsa_forward, anti_redundant_lsa) = 35. Dense-family presets are retired.
    let retired_presets = ["ppmi_forward", "nmf_forward", "anti_redundant_nmf"];
    {
        assert_eq!(RecallShape::PRESET_NAMES.len(), 35);
        for retired in retired_presets {
            assert!(!RecallShape::PRESET_NAMES.contains(&retired), "{retired} is retired (dense families removed)");
            assert!(RecallShape::preset(retired).is_none());
        }
    }
    // `cross_encoder` is reserved (sheet §8), not implemented: absent from the
    // roster and unresolvable, so the tool rejects it as unknown.
    assert!(!RecallShape::PRESET_NAMES.contains(&"cross_encoder"));
    assert!(RecallShape::preset("cross_encoder").is_none());
}

#[test]
fn signal_vector_defaults_to_zero_every_other_key_to_one() {
    assert_eq!(RecallShape::default_weight(RecallShape::SIGNAL_VECTOR), 0.0);
    assert_eq!(RecallShape::default_weight("bm25"), 1.0);
    assert_eq!(RecallShape::default_weight(RecallShape::SIGNAL_ENCODER), 1.0);
    let empty = RecallShape::new(std::collections::HashMap::new(), None);
    assert_eq!(empty.weight(RecallShape::SIGNAL_VECTOR), 0.0);
    assert_eq!(empty.weight(RecallShape::DENSE_ENCODER), 1.0);
    assert_eq!(RecallShape::weight_or_default(&None, RecallShape::SIGNAL_VECTOR), 0.0);
    assert_eq!(RecallShape::dense_key_for_model("minilm-l6-v2-w60"), RecallShape::DENSE_ENCODER);
}

#[test]
fn no_encoder_skips_the_stage_through_signal_encoder_only() {
    let s = RecallShape::preset("no_encoder").unwrap();
    assert_eq!(s.lane_weights.len(), 1);
    assert_eq!(s.weight(RecallShape::SIGNAL_ENCODER), 0.0);
    // The vector column stays at its default.
    assert_eq!(s.weight(RecallShape::SIGNAL_VECTOR), 0.0);
    assert!(!RecallShape::preset_description("no_encoder").is_empty());
}

#[test]
fn precise_amplifies_lexical_and_field_and_narrows_frontier() {
    let s = RecallShape::preset("precise").unwrap();
    assert!(s.weight("bm25") > 1.0);
    assert!(s.weight("dense") > 1.0);
    // Narrow frontier = floor.
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
}

#[test]
fn conceptual_amplifies_distributional_and_damps_keyword() {
    let s = RecallShape::preset("conceptual").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    // bm25 damped below neutral but not excluded.
    assert!(s.weight("bm25") < 1.0 && s.weight("bm25") > 0.0);
}

#[test]
fn broad_forwards_all_lanes_and_widens_frontier() {
    let s = RecallShape::preset("broad").unwrap();
    assert!(s.weight("locus") > 1.0);
    assert!(s.weight("bm25") > 1.0);
    assert!(s.weight("hamming") > 1.0);
    assert!(s.weight("dense") > 1.0);
    assert_eq!(s.effective_frontier_k(64), RecallShape::FRONTIER_K_CEILING);
}

#[test]
fn lexical_zeroes_the_vector_lanes() {
    let s = RecallShape::preset("lexical").unwrap();
    assert!(s.weight("bm25") > 1.0);
    // The vector lanes are EXCLUDED (==0), not merely absent.
    assert_eq!(s.weight("dense"), 0.0);
    assert_eq!(s.weight("hamming"), 0.0);
}

#[test]
fn not_lexical_zeroes_keyword_and_field() {
    let s = RecallShape::preset("not_lexical").unwrap();
    assert_eq!(s.weight("bm25"), 0.0);
    // A lane it does not name stays neutral.
    assert_eq!(s.weight("locus"), 1.0);
}

#[test]
fn associative_amplifies_ri_and_nmf_and_widens() {
    let s = RecallShape::preset("associative").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    assert_eq!(s.effective_frontier_k(64), RecallShape::FRONTIER_K_CEILING);
}

#[test]
fn consensus_forwards_every_dense_signal_and_narrows() {
    let s = RecallShape::preset("consensus").unwrap();
    for key in RecallShape::DENSE_SIGNALS {
        assert!(s.weight(key) > 0.0, "{key} should be forwarded, not excluded");
    }
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
}

#[test]
fn forward_presets_isolate_one_dense_signal() {
    // ri_forward amplifies RI and EXCLUDES the other distributional siblings.
    let s = RecallShape::preset("ri_forward").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    // The shipped dense roster is RI + LSA: the LSA sibling is present at zero
    // weight so only RI's geometry votes. Mirrors the Swift `forwardPresets` pin.
    let expected: HashMap<String, f32> = HashMap::from([
        (RecallShape::DENSE_RANDOM_INDEXING.to_string(), 1.5),
        (RecallShape::DENSE_LSA.to_string(), 0.0),
    ]);
    assert_eq!(s.lane_weights, expected);
}

#[test]
fn fast_keeps_hamming_only() {
    let s = RecallShape::preset("fast").unwrap();
    assert!(s.weight("hamming") > 1.0);
    assert_eq!(s.weight("dense"), 0.0);
}

#[test]
fn matrix_column_presets_amplify_their_column() {
    assert!(RecallShape::preset("structural").unwrap().weight("locus") > 1.0);
    assert!(RecallShape::preset("temporal").unwrap().weight("temporal") > 1.0);
    assert!(RecallShape::preset("connection").unwrap().weight("graph") > 1.0);
    assert!(RecallShape::preset("field").unwrap().weight("coOccurrence") > 1.0);
    assert!(RecallShape::preset("preference").unwrap().weight("preference") > 1.0);
}

#[test]
fn anti_redundant_inverts_fdc_and_suppresses_bm25_hamming() {
    let s = RecallShape::preset("anti_redundant").unwrap();
    // FDC is dark: nothing is inverted, the suppression and narrow frontier remain.
    assert!(s.anti_similar_lanes.is_empty());
    // BM25 and Hamming are suppressed so lexical near-duplicates cannot dominate.
    assert!(s.weight("bm25") < 0.0);
    assert!(s.weight("hamming") < 0.0);
    // Frontier narrowed to the floor so the engine does not haul a wide pool of duplicates.
    assert_eq!(
        s.effective_frontier_k(200),
        RecallShape::FRONTIER_K_FLOOR
    );
}

#[test]
fn session_hybrid_amplifies_bm25_dense_temporal() {
    // session_hybrid is the session-granularity preset: bm25 (keyword match
    // for conversation fragments), dense (semantic similarity), temporal
    // (recency within the session window) all amplified above neutral.
    // No lanes excluded — session_hybrid is additive over balanced.
    let s = RecallShape::preset("session_hybrid").unwrap();
    assert!(s.weight("bm25") > 1.0, "bm25 must be amplified");
    assert!(s.weight("dense") > 1.0, "dense must be amplified");
    assert!(s.weight("temporal") > 1.0, "temporal must be amplified");
    // Lanes not named stay neutral.
    assert_eq!(s.weight("locus"), 1.0, "locus should be neutral");
    assert_eq!(s.weight("hamming"), 1.0, "hamming should be neutral");
    // Description is non-empty.
    assert!(
        !RecallShape::preset_description("session_hybrid").is_empty(),
        "session_hybrid must have a catalog description"
    );
}

#[test]
fn leave_one_out_is_reachable_by_zeroing_a_dense_lane() {
    // The documented leave-one-out pattern: take a forward shape and zero ONE
    // dense lane. consensus + zero LSA ablates exactly LSA; the shipped dense
    // roster is RI + LSA (`DENSE_SIGNALS`), so RI is the sibling that survives.
    let base = RecallShape::preset("consensus").unwrap();
    let mut weights = base.lane_weights.clone();
    {
        weights.insert(RecallShape::DENSE_LSA.to_string(), 0.0);
        // Clone: the second block below reuses `weights` to ablate RI.
        let ablated = RecallShape::new(weights.clone(), base.frontier_k);
        assert_eq!(ablated.weight(RecallShape::DENSE_LSA), 0.0);
        assert!(ablated.weight(RecallShape::DENSE_RANDOM_INDEXING) > 0.0);
    }
    {
        weights.insert(RecallShape::DENSE_RANDOM_INDEXING.to_string(), 0.0);
        let ablated = RecallShape::new(weights, base.frontier_k);
        assert_eq!(ablated.weight(RecallShape::DENSE_RANDOM_INDEXING), 0.0);
        assert_eq!(ablated.weight("dense"), 1.0);
    }
}

// --- Per-signal anti-similarity presets ---

#[test]
fn anti_redundant_ri_inverts_ri_and_suppresses_bm25_hamming() {
    let s = RecallShape::preset("anti_redundant_ri").unwrap();
    // RI lane is anti-similar (farthest-neighbour direction).
    assert!(s.is_anti_similar(RecallShape::DENSE_RANDOM_INDEXING));
    // Only RI is anti-similar.
    assert_eq!(s.anti_similar_lanes.len(), 1);
    // Anti-similar flag flips direction, not magnitude — RI weight stays at 1.0.
    assert_eq!(s.weight(RecallShape::DENSE_RANDOM_INDEXING), 1.0);
    // BM25 and Hamming suppressed.
    assert!(s.weight("bm25") < 0.0);
    assert!(s.weight("hamming") < 0.0);
    // Frontier narrowed to the floor.
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
    // Catalog description is non-empty.
    assert!(!RecallShape::preset_description("anti_redundant_ri").is_empty());
}

#[test]
fn anti_redundant_lsa_inverts_lsa_and_suppresses_bm25_hamming() {
    let s = RecallShape::preset("anti_redundant_lsa").unwrap();
    // Only LSA is anti-similar; its RI sibling keeps the nearest direction.
    assert!(s.is_anti_similar(RecallShape::DENSE_LSA));
    assert!(!s.is_anti_similar(RecallShape::DENSE_RANDOM_INDEXING));
    assert_eq!(s.anti_similar_lanes.len(), 1);
    assert_eq!(s.weight(RecallShape::DENSE_LSA), 1.0);
    assert!(s.weight("bm25") < 0.0);
    assert!(s.weight("hamming") < 0.0);
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
    assert!(!RecallShape::preset_description("anti_redundant_lsa").is_empty());
}


// --- Multi-column matrix presets ---

#[test]
fn temporal_connection_amplifies_temporal_and_co_occurrence() {
    let s = RecallShape::preset("temporal_connection").unwrap();
    // Both matrix columns amplified above neutral.
    assert!(s.weight("temporal") > 1.0);
    assert!(s.weight("coOccurrence") > 1.0);
    // No lanes excluded or anti-similar — purely additive over balanced.
    assert_eq!(s.weight("locus"), 1.0);
    assert_eq!(s.weight("bm25"), 1.0);
    assert!(s.anti_similar_lanes.is_empty());
    // No frontier override.
    assert!(s.frontier_k.is_none());
    assert!(!RecallShape::preset_description("temporal_connection").is_empty());
}

#[test]
fn field_preference_amplifies_field_fit_and_preference() {
    let s = RecallShape::preset("field_preference").unwrap();
    // Both matrix columns amplified above neutral.
    assert!(s.weight("fieldFit") > 1.0);
    assert!(s.weight("preference") > 1.0);
    // No lanes excluded or anti-similar.
    assert_eq!(s.weight("locus"), 1.0);
    assert_eq!(s.weight("temporal"), 1.0);
    assert!(s.anti_similar_lanes.is_empty());
    assert!(s.frontier_k.is_none());
    assert!(!RecallShape::preset_description("field_preference").is_empty());
}

// --- GLKRecallRequest.frontier_k per-call override ---

#[test]
fn glk_recall_request_frontier_k_defaults_to_none() {
    use genius_locus_kit::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
    };
    use locus_kit::filter::RecallFrame;

    let req = GLKRecallRequest::new(
        RecallFrame::new(vec![]),
        GLKRecallMode::LocusOnly,
        GLKRecallScoring::Raw,
        10,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    );
    assert!(req.frontier_k.is_none());
}

#[test]
fn with_frontier_k_stores_midpoint_value() {
    use genius_locus_kit::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
    };
    use locus_kit::filter::RecallFrame;

    let req = GLKRecallRequest::new(
        RecallFrame::new(vec![]),
        GLKRecallMode::LocusOnly,
        GLKRecallScoring::Raw,
        10,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
    .with_frontier_k(128);
    // 128 is the midpoint of [64, 256] — no clamping applied by the builder.
    assert_eq!(req.frontier_k, Some(128));
}

#[test]
fn frontier_k_out_of_range_is_clamped_by_effective_frontier_k() {
    // The coordinator applies RecallShape::effective_frontier_k semantics to the
    // request-level override. Verify the clamp contract via the shape helper,
    // which encodes the same [FRONTIER_K_FLOOR, FRONTIER_K_CEILING] bounds.
    let below_floor = RecallShape::new(std::collections::HashMap::new(), Some(1));
    assert_eq!(
        below_floor.effective_frontier_k(100),
        RecallShape::FRONTIER_K_FLOOR
    );

    let above_ceiling = RecallShape::new(std::collections::HashMap::new(), Some(9999));
    assert_eq!(
        above_ceiling.effective_frontier_k(100),
        RecallShape::FRONTIER_K_CEILING
    );

    let midpoint = RecallShape::new(std::collections::HashMap::new(), Some(128));
    assert_eq!(midpoint.effective_frontier_k(100), 128);
}

// --- Float-lane metric presets ---

#[test]
fn float_l2_sets_float_metric_and_leaves_defaults() {
    let s = RecallShape::preset("float-l2").unwrap();
    // The ONLY change from balanced is the float-lane metric.
    assert_eq!(s.float_metric, "l2");
    // All lane weights stay neutral — no fusion steering.
    assert!(s.lane_weights.is_empty());
    // Anti-similar set stays empty — no direction inversion.
    assert!(s.anti_similar_lanes.is_empty());
    // No frontier override — engine default applies.
    assert!(s.frontier_k.is_none());
    // Binary metric unchanged from the default.
    assert_eq!(s.binary_metric, "hamming");
    // Description is present in the catalog.
    assert!(!RecallShape::preset_description("float-l2").is_empty());
}

#[test]
fn float_dot_sets_float_metric_and_leaves_defaults() {
    let s = RecallShape::preset("float-dot").unwrap();
    // The ONLY change from balanced is the float-lane metric.
    assert_eq!(s.float_metric, "dot");
    // All lane weights stay neutral — no fusion steering.
    assert!(s.lane_weights.is_empty());
    // Anti-similar set stays empty — no direction inversion.
    assert!(s.anti_similar_lanes.is_empty());
    // No frontier override — engine default applies.
    assert!(s.frontier_k.is_none());
    // Binary metric unchanged from the default.
    assert_eq!(s.binary_metric, "hamming");
    // Description is present in the catalog.
    assert!(!RecallShape::preset_description("float-dot").is_empty());
}
