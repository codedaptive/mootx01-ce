use lattice_lib::{Fdc, FdcSemanticCandidate, FdcSemanticDecision};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    model_sha256: String,
    model_version: String,
    vectors: Vec<Vector>,
}

#[derive(Deserialize)]
struct Vector {
    input: String,
    candidates: Vec<Candidate>,
    decision: Option<Decision>,
    final_code: String,
}

#[derive(Deserialize)]
struct Candidate {
    code: String,
    score: i64,
    matched_features: usize,
}

#[derive(Deserialize)]
struct Decision {
    code: String,
    main_class: String,
    score: i64,
    runner_up_score: i64,
    matched_features: usize,
}

#[test]
fn semantic_top_k_hierarchy_and_final_codes_match_shared_vectors() {
    let fixture: Fixture =
        serde_json::from_slice(include_bytes!("fixtures/fdc_semantic_conformance.json"))
            .expect("semantic fixture must parse");
    assert!(!fixture.vectors.is_empty());
    assert_eq!(Fdc::semantic_model_version(), fixture.model_version);
    assert_eq!(Fdc::semantic_model_sha256(), fixture.model_sha256);

    for vector in fixture.vectors {
        let expected_candidates: Vec<FdcSemanticCandidate> = vector
            .candidates
            .into_iter()
            .map(|candidate| FdcSemanticCandidate {
                code: candidate.code,
                score: candidate.score,
                matched_features: candidate.matched_features,
            })
            .collect();
        assert_eq!(
            Fdc::semantic_candidates(&vector.input, 3),
            expected_candidates,
            "top-k mismatch for {:?}",
            vector.input
        );
        let expected_decision = vector.decision.map(|decision| FdcSemanticDecision {
            code: decision.code,
            main_class: decision.main_class,
            score: decision.score,
            runner_up_score: decision.runner_up_score,
            matched_features: decision.matched_features,
        });
        assert_eq!(
            Fdc::semantic_decision(&vector.input),
            expected_decision,
            "hierarchy mismatch for {:?}",
            vector.input
        );
        assert_eq!(
            Fdc::encode(&vector.input),
            Some(vector.final_code),
            "final-code mismatch for {:?}",
            vector.input
        );
    }
}

#[test]
fn opt_in_semantic_classification_throughput_benchmark() {
    if std::env::var("BENCHMARK_FDC_SEMANTIC").as_deref() != Ok("1") {
        return;
    }
    let fixture: Fixture =
        serde_json::from_slice(include_bytes!("fixtures/fdc_semantic_conformance.json"))
            .expect("semantic fixture must parse");
    let _ = Fdc::encode(&fixture.vectors[0].input);
    let start = std::time::Instant::now();
    let mut checksum = 0usize;
    for index in 0..1_000 {
        checksum += Fdc::encode(&fixture.vectors[index % fixture.vectors.len()].input)
            .map(|code| code.len())
            .unwrap_or(0);
    }
    assert!(checksum > 0);
    println!(
        "FDC semantic Rust release: 1000 classifications in {:?}",
        start.elapsed()
    );
}
