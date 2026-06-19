//! CROSS-LANGUAGE REDUCTION CONFORMANCE (Rust leg). Reads the SHARED fixture
//!
//!   packages/kits/NeuronKit/Tests/NeuronKitTests/Fixtures/reduction_vectors.json
//!
//! and asserts that `neuron_kit::reduce` produces the RANK-IDENTICAL ordered id
//! list for each composition case. The Swift `ReductionConformanceTests` reads
//! the SAME file and asserts the SAME ordering — so a divergence in the
//! reduction fold (signal math, weighting, tie-breaks) fails in BOTH languages.
//!
//! The reduction fold is deterministic. For content/structural compositions
//! (`text`, `text+temporal`) the per-candidate scores are bit-identical across
//! languages; for `dense-fused` the float `dense` column participates but the
//! emitted ORDER is what is asserted (rank-identical, the mission's bar where a
//! float lane participates).

use std::path::PathBuf;

use serde::Deserialize;

use genius_locus_kit::recall::RecallScoreVector;
use neuron_kit::{named_composition, reduce, ReductionCandidate, ReductionQuery};

#[derive(Debug, Deserialize)]
struct Fixture {
    candidates: Vec<CandidateSpec>,
    cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
struct CandidateSpec {
    id: String,
    content: String,
    room: String,
    udc_code: String,
    dense: f32,
    vector: f32,
    co_occurrence: f32,
    bm25: f32,
    is_currently_believed: bool,
    coarse_rank: usize,
}

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    composition: String,
    query: String,
    limit: usize,
    expected_order: Vec<String>,
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/NeuronKitTests/Fixtures/reduction_vectors.json")
}

fn load_fixture() -> Fixture {
    let path = fixture_path();
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reduction_vectors.json missing at {}: {e}", path.display()));
    serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("reduction_vectors.json malformed at {}: {e}", path.display()))
}

/// Build a `ReductionCandidate` directly from the fixture spec — the same
/// fields the Swift test sets on its candidate. The `vector` column carries the
/// normalized Hamming similarity `(256 - distance) / 256`, from which the
/// integer-distance `hamming` signal is recovered exactly.
fn candidate(spec: &CandidateSpec) -> ReductionCandidate {
    let score = RecallScoreVector {
        locus: 0.0,
        bm25: spec.bm25,
        vector: spec.vector,
        field_fit: 0.0,
        co_occurrence: spec.co_occurrence,
        temporal: 0.0,
        graph: 0.0,
        preference: 0.0,
        redundancy_penalty: 0.0,
        final_score: spec.vector,
        dense: spec.dense,
    };
    ReductionCandidate {
        id: spec.id.clone(),
        content: spec.content.clone(),
        room: spec.room.clone(),
        score,
        udc_code: spec.udc_code.clone(),
        udc_facets: None,
        coarse_rank: spec.coarse_rank,
        event_time: None,
        is_currently_believed: spec.is_currently_believed,
        // precision_score is populated by the composition fold; 0 here because
        // this builds pre-fold candidates for the conformance harness.
        precision_score: 0.0,
    }
}

#[test]
fn reduction_is_rank_identical_to_swift() {
    let fixture = load_fixture();
    let candidates: Vec<ReductionCandidate> = fixture.candidates.iter().map(candidate).collect();

    for case in &fixture.cases {
        let comp = named_composition(Some(&case.composition));
        let query = ReductionQuery::new(case.query.clone());
        let ranked = reduce(&comp, &query, &candidates, case.limit);
        let order: Vec<String> = ranked.into_iter().map(|c| c.id).collect();
        assert_eq!(
            order, case.expected_order,
            "composition '{}' (case '{}') produced rank order {:?}, expected {:?} — Swift/Rust reduction divergence",
            case.composition, case.name, order, case.expected_order
        );
    }
}
