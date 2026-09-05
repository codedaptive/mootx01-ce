//! Cross-port pin for the RecallExplainer lines.
//!
//! Reads Tests/Conformance/recall_explainer_fixture.json (also asserted by
//! RecallExplainerCrossPortFixtureTests.swift) and checks that
//! `recall_explainer::explain` renders each case's lines verbatim. These are
//! the lines `moot_memory_search` explain:true prints under each candidate
//! row, so both ports must agree byte for byte.

use std::path::PathBuf;

use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallScoring, RecallEvidencePath, RecallHit, RecallPlan, RecallScoreVector,
    RecallWeights,
};
use genius_locus_kit::recall_explainer;

fn evidence_path(raw: &str) -> RecallEvidencePath {
    match raw {
        "locusBitmap" => RecallEvidencePath::LocusBitmap,
        "locusGraph" => RecallEvidencePath::LocusGraph,
        "corpusBM25" => RecallEvidencePath::CorpusBm25,
        "vectorHamming" => RecallEvidencePath::VectorHamming,
        "vectorDense" => RecallEvidencePath::VectorDense,
        other => panic!("fixture names an unknown evidence path: {other}"),
    }
}

fn mode(raw: &str) -> GLKRecallMode {
    match raw {
        "unionBest" => GLKRecallMode::UnionBest,
        "hybrid" => GLKRecallMode::Hybrid,
        "corpusOnly" => GLKRecallMode::CorpusOnly,
        "locusOnly" => GLKRecallMode::LocusOnly,
        other => panic!("fixture names an unknown mode: {other}"),
    }
}

fn scoring(raw: &str) -> GLKRecallScoring {
    match raw {
        "matrixAware" => GLKRecallScoring::MatrixAware,
        "rrf" => GLKRecallScoring::Rrf,
        "raw" => GLKRecallScoring::Raw,
        "discriminative" => GLKRecallScoring::Discriminative,
        other => panic!("fixture names an unknown scoring: {other}"),
    }
}

fn f(v: &serde_json::Value, key: &str) -> f32 {
    v[key].as_f64().unwrap_or_else(|| panic!("score.{key} must be a number")) as f32
}

#[test]
fn fixture_cases_render_verbatim() {
    // CARGO_MANIFEST_DIR is GeniusLocusKit/rust/; the fixture is shared with
    // the Swift twin under Tests/Conformance/.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Conformance/recall_explainer_fixture.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let fixture: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");
    let cases = fixture["cases"].as_array().expect("cases array");
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().unwrap_or("?");
        let sources: Vec<RecallEvidencePath> = case["sources"]
            .as_array()
            .expect("sources array")
            .iter()
            .map(|s| evidence_path(s.as_str().expect("source string")))
            .collect();
        let s = &case["score"];
        let score = RecallScoreVector {
            locus: f(s, "locus"),
            bm25: f(s, "bm25"),
            vector: f(s, "vector"),
            field_fit: f(s, "fieldFit"),
            co_occurrence: f(s, "coOccurrence"),
            temporal: f(s, "temporal"),
            graph: f(s, "graph"),
            preference: f(s, "preference"),
            redundancy_penalty: 0.0,
            final_score: f(s, "final"),
            dense: f(s, "dense"),
        };
        let hit = RecallHit {
            id: "fixture".to_string(),
            drawer: None,
            sources,
            score,
            explanation: vec![],
        };
        let plan = RecallPlan {
            effective_mode: mode(case["mode"].as_str().expect("mode")),
            frontier_k: 64,
            weights: RecallWeights::UNIFORM,
        };
        let has_query_text = case["hasQueryText"].as_bool().expect("hasQueryText");
        let lines = recall_explainer::explain(
            &hit,
            has_query_text,
            &plan,
            scoring(case["scoring"].as_str().expect("scoring")),
        );
        let expected: Vec<String> = case["expected"]
            .as_array()
            .expect("expected array")
            .iter()
            .map(|l| l.as_str().expect("line").to_string())
            .collect();
        assert_eq!(lines, expected, "case '{name}'");
    }
}
