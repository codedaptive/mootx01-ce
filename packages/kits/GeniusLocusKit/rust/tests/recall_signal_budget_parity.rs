// recall_signal_budget_parity.rs
//
// Conformance vectors for `RecallSignalBudget::resolve` (COL-1). The same
// seven vectors are pinned, with the same literal f32 expectations, in the
// Swift RecallSignalBudgetTests.swift — the two files ARE the shared vector.
// Inputs are the un-normalised adaptive base weights (locus 0.2, bm25 0.3,
// vector 0.3, matrix 0.1, fieldFit 0.1, diversity 0.1, graph 0.1): total
// budget 1.2 (preference draws the graph slice a second time). `redistribution`
// is the factor ρ the MMR similarity term is scaled by (COL-2).

use std::collections::{HashMap, HashSet};

use genius_locus_kit::recall::{RecallShape, RecallWeights};
use genius_locus_kit::recall_signal_budget::{RecallSignalBudget, SignalColumn};

fn weights() -> RecallWeights {
    RecallWeights {
        locus: 0.2,
        bm25: 0.3,
        vector: 0.3,
        matrix: 0.1,
        field_fit: 0.1,
        diversity: 0.1,
        graph: 0.1,
    }
}

fn resolve(keys: &[(&str, f32)], absent: &[SignalColumn]) -> RecallSignalBudget {
    let map: HashMap<String, f32> = keys.iter().map(|(k, v)| ((*k).to_string(), *v)).collect();
    let absent: HashSet<SignalColumn> = absent.iter().copied().collect();
    RecallSignalBudget::resolve(&weights(), |k| map.get(k).copied().unwrap_or(1.0), &absent)
}

fn near(a: f32, b: f32) -> bool {
    (a - b).abs() <= 1e-6
}

#[test]
fn v1_neutral_is_byte_identical_to_weights() {
    let w = weights();
    let b = resolve(&[], &[]);
    assert_eq!(b.redistribution, 1.0);
    assert_eq!(b.locus, w.locus);
    assert_eq!(b.bm25, w.bm25);
    assert_eq!(b.vector, w.vector);
    assert_eq!(b.field_fit, w.field_fit);
    assert_eq!(b.matrix, w.matrix);
    assert_eq!(b.graph, w.graph);
    assert_eq!(b.preference, w.graph);
    assert_eq!(b.agreement, 1.0);
    assert!(b.excluded.is_empty());
}

#[test]
fn v2_exclude_matrix_redistributes_1_2_over_1_1() {
    let b = resolve(&[(RecallShape::SIGNAL_MATRIX, 0.0)], &[]);
    assert!(near(b.redistribution, 1.0909091));
    assert!(near(b.locus, 0.21818183));
    assert!(near(b.bm25, 0.32727274));
    assert!(near(b.vector, 0.32727274));
    assert!(near(b.field_fit, 0.10909092));
    assert_eq!(b.matrix, 0.0);
    assert!(near(b.graph, 0.10909092));
    assert!(near(b.preference, 0.10909092));
    assert_eq!(b.agreement, 1.0);
    assert_eq!(b.excluded, HashSet::from([SignalColumn::Matrix]));
}

#[test]
fn v3_absent_columns_redistribute_1_2_over_0_9() {
    let b = resolve(&[], &[SignalColumn::FieldFit, SignalColumn::Graph, SignalColumn::Preference]);
    assert!(near(b.redistribution, 1.3333334));
    assert!(near(b.locus, 0.26666668));
    assert!(near(b.bm25, 0.40000004));
    assert!(near(b.vector, 0.40000004));
    assert_eq!(b.field_fit, 0.0);
    assert!(near(b.matrix, 0.13333334));
    assert_eq!(b.graph, 0.0);
    assert_eq!(b.preference, 0.0);
    assert_eq!(
        b.excluded,
        HashSet::from([SignalColumn::FieldFit, SignalColumn::Graph, SignalColumn::Preference])
    );
}

#[test]
fn v4_exclude_agreement_drops_bonus_only() {
    let w = weights();
    let b = resolve(&[(RecallShape::SIGNAL_AGREEMENT, 0.0)], &[]);
    assert_eq!(b.agreement, 0.0);
    assert_eq!(b.locus, w.locus);
    assert_eq!(b.bm25, w.bm25);
    assert_eq!(b.matrix, w.matrix);
    assert_eq!(b.excluded, HashSet::from([SignalColumn::Agreement]));
}

#[test]
fn v5_suppress_graph_without_redistribution() {
    let w = weights();
    let b = resolve(&[(RecallShape::SIGNAL_GRAPH, -1.0)], &[]);
    assert!(near(b.graph, -0.1));
    assert_eq!(b.locus, w.locus);
    assert_eq!(b.preference, w.graph);
    assert!(b.excluded.is_empty());
}

#[test]
fn v6_scale_bm25_without_redistribution() {
    let w = weights();
    let b = resolve(&[(RecallShape::SIGNAL_BM25, 2.0)], &[]);
    assert!(near(b.bm25, 0.6));
    assert_eq!(b.locus, w.locus);
    assert_eq!(b.vector, w.vector);
    assert!(b.excluded.is_empty());
}

#[test]
fn v7_all_budgeted_excluded_is_all_zero_without_div_by_zero() {
    let keys: Vec<(&str, f32)> = SignalColumn::BUDGETED.iter().map(|c| (c.lane_key(), 0.0)).collect();
    let b = resolve(&keys, &[]);
    assert!(b.locus == 0.0 && b.bm25 == 0.0 && b.vector == 0.0 && b.field_fit == 0.0);
    assert!(b.matrix == 0.0 && b.graph == 0.0 && b.preference == 0.0);
    assert_eq!(b.agreement, 1.0);
    assert_eq!(b.redistribution, 1.0);
    assert_eq!(b.excluded.len(), 7);
}

#[test]
fn signal_key_constants_match_column_keys() {
    assert_eq!(RecallShape::SIGNAL_LOCUS, SignalColumn::Locus.lane_key());
    assert_eq!(RecallShape::SIGNAL_BM25, SignalColumn::Bm25.lane_key());
    assert_eq!(RecallShape::SIGNAL_VECTOR, SignalColumn::Vector.lane_key());
    assert_eq!(RecallShape::SIGNAL_FIELD_FIT, SignalColumn::FieldFit.lane_key());
    assert_eq!(RecallShape::SIGNAL_MATRIX, SignalColumn::Matrix.lane_key());
    assert_eq!(RecallShape::SIGNAL_GRAPH, SignalColumn::Graph.lane_key());
    assert_eq!(RecallShape::SIGNAL_PREFERENCE, SignalColumn::Preference.lane_key());
    assert_eq!(RecallShape::SIGNAL_AGREEMENT, SignalColumn::Agreement.lane_key());
    assert_eq!(SignalColumn::Matrix.name(), "matrix");
}
