// recall_shape_presets.rs
//
// Unit tests for the named RecallShape preset roster (GLK-RECALL-SHAPE-PRESETS).
// Each preset resolves to its documented signed-weight shape; the roster is
// discoverable via PRESET_NAMES; balanced/unknown resolve to None. Mirrors the
// Swift RecallShapePresetTests.swift — both ports assert the same directions.

use genius_locus_kit::recall::RecallShape;

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
    assert_eq!(RecallShape::PRESET_NAMES.len(), 19);
}

#[test]
fn precise_amplifies_lexical_and_field_and_narrows_frontier() {
    let s = RecallShape::preset("precise").unwrap();
    assert!(s.weight("bm25") > 1.0);
    assert!(s.weight(RecallShape::DENSE_FDC) > 1.0);
    assert!(s.weight("dense") > 1.0);
    // Narrow frontier = floor.
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
}

#[test]
fn conceptual_amplifies_distributional_and_damps_keyword() {
    let s = RecallShape::preset("conceptual").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    assert!(s.weight(RecallShape::DENSE_PPMI) > 1.0);
    assert!(s.weight(RecallShape::DENSE_LSA) > 1.0);
    assert!(s.weight(RecallShape::DENSE_NMF) > 1.0);
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
    assert!(s.weight(RecallShape::DENSE_FDC) > 1.0);
    // The vector lanes are EXCLUDED (==0), not merely absent.
    assert_eq!(s.weight("dense"), 0.0);
    assert_eq!(s.weight("hamming"), 0.0);
}

#[test]
fn not_lexical_zeroes_keyword_and_field() {
    let s = RecallShape::preset("not_lexical").unwrap();
    assert_eq!(s.weight("bm25"), 0.0);
    assert_eq!(s.weight(RecallShape::DENSE_FDC), 0.0);
    // A lane it does not name stays neutral.
    assert_eq!(s.weight("locus"), 1.0);
}

#[test]
fn associative_amplifies_ri_and_nmf_and_widens() {
    let s = RecallShape::preset("associative").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    assert!(s.weight(RecallShape::DENSE_NMF) > 1.0);
    assert_eq!(s.effective_frontier_k(64), RecallShape::FRONTIER_K_CEILING);
}

#[test]
fn consensus_forwards_every_dense_signal_and_narrows() {
    let s = RecallShape::preset("consensus").unwrap();
    for key in RecallShape::DENSE_SIGNALS {
        assert!(s.weight(key) > 0.0, "{key} should be forwarded, not excluded");
    }
    assert!(s.weight(RecallShape::DENSE_FDC) > 0.0);
    assert_eq!(s.effective_frontier_k(200), RecallShape::FRONTIER_K_FLOOR);
}

#[test]
fn forward_presets_isolate_one_dense_signal() {
    // ri_forward amplifies RI and EXCLUDES the other three distributional siblings.
    let s = RecallShape::preset("ri_forward").unwrap();
    assert!(s.weight(RecallShape::DENSE_RANDOM_INDEXING) > 1.0);
    assert_eq!(s.weight(RecallShape::DENSE_PPMI), 0.0);
    assert_eq!(s.weight(RecallShape::DENSE_LSA), 0.0);
    assert_eq!(s.weight(RecallShape::DENSE_NMF), 0.0);

    // lsa_forward isolates LSA.
    let s = RecallShape::preset("lsa_forward").unwrap();
    assert!(s.weight(RecallShape::DENSE_LSA) > 1.0);
    assert_eq!(s.weight(RecallShape::DENSE_RANDOM_INDEXING), 0.0);
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
fn anti_redundant_inverts_the_fdc_lane() {
    let s = RecallShape::preset("anti_redundant").unwrap();
    // The FDC dense lane is anti-similar (farthest), and no lane weights are set.
    assert!(s.is_anti_similar(RecallShape::DENSE_FDC));
    assert!(!s.is_anti_similar(RecallShape::DENSE_LSA));
    // It does not also suppress — distinct from a negative weight.
    assert_eq!(s.weight(RecallShape::DENSE_FDC), 1.0);
}

#[test]
fn leave_one_out_is_reachable_by_zeroing_a_dense_lane() {
    // The documented leave-one-out pattern: take a forward shape and zero ONE
    // dense lane. consensus + zero LSA ablates exactly LSA.
    let base = RecallShape::preset("consensus").unwrap();
    let mut weights = base.lane_weights.clone();
    weights.insert(RecallShape::DENSE_LSA.to_string(), 0.0);
    let ablated = RecallShape::new(weights, base.frontier_k);
    assert_eq!(ablated.weight(RecallShape::DENSE_LSA), 0.0);
    assert!(ablated.weight(RecallShape::DENSE_PPMI) > 0.0);
}
