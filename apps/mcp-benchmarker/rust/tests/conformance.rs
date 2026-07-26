//! conformance.rs — shared-vector conformance tests for the Rust leg.
//!
//! Drives the three modules against the shared JSON vectors in
//! `tools/mcp-benchmarker/conformance/`. Same inputs → identical outputs
//! on the Rust leg as on the Swift leg is the correctness definition
//! (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//!
//! The conformance/ directory is resolved relative to this file's location:
//!   tests/conformance.rs → tools/mcp-benchmarker/rust-bench/ → tools/ →
//!   tools/mcp-benchmarker/conformance/
//!
//! All expected values are pre-computed in the JSON vectors. If a test fails,
//! the Rust impl diverges from the Swift reference and the vector needs
//! investigation before either side is amended.

use mcp_benchmarker_rs::degeneracy_guard::DegeneracyGuard;
use mcp_benchmarker_rs::divergence::{jaccard_divergence, rank_divergence};
use mcp_benchmarker_rs::longmemeval_corpus::load_corpus;
use mcp_benchmarker_rs::manifest::{CapabilityManifest, ManifestValidationError};
use serde_json::Value;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve the path to `apps/mcp-benchmarker/conformance/<filename>`.
/// This file lives at `apps/mcp-benchmarker/rust/tests/conformance.rs`.
///
/// CE path note: the crate lives at apps/mcp-benchmarker/rust/ (flat layout,
/// no rust-bench/ subdir as in EE). CARGO_MANIFEST_DIR points at
/// apps/mcp-benchmarker/rust/; one parent() reaches apps/mcp-benchmarker/,
/// which is where conformance/ and manifests/ live.
fn conformance_path(filename: &str) -> PathBuf {
    // __file__ is not stable in Rust integration tests; use CARGO_MANIFEST_DIR
    // (set by cargo for integration tests) which points to the crate root.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // manifest_dir = apps/mcp-benchmarker/rust/
    // parent() → apps/mcp-benchmarker/
    manifest_dir
        .parent()
        .expect("apps/mcp-benchmarker/ parent must exist")
        .join("conformance")
        .join(filename)
}

/// Resolve the path to the hand-authored synthetic LongMemEval test sample.
/// The sample lives beside the Swift test files at
/// `apps/mcp-benchmarker/Tests/mcp-benchmarkerTests/longmemeval_sample.json`.
fn lme_sample_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // manifest_dir = apps/mcp-benchmarker/rust/
    // parent() → apps/mcp-benchmarker/
    manifest_dir
        .parent()
        .expect("apps/mcp-benchmarker/ parent must exist")
        .join("Tests")
        .join("mcp-benchmarkerTests")
        .join("longmemeval_sample.json")
}

/// Resolve the path to a shipped manifest: `apps/mcp-benchmarker/manifests/<filename>`.
fn manifest_path(filename: &str) -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .expect("apps/mcp-benchmarker/ parent must exist")
        .join("manifests")
        .join(filename)
}

fn load_json(path: &PathBuf) -> Value {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|e| panic!("Failed to parse {}: {e}", path.display()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 1 — Divergence conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn divergence_jaccard_vectors() {
    let path = conformance_path("divergence_vectors.json");
    let json = load_json(&path);

    let cases = json["jaccard"].as_array()
        .expect("divergence_vectors.json must have a 'jaccard' array");

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let expected_strs: Vec<String> = case["expected"].as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let got_strs: Vec<String> = case["got"].as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let expected_result = case["result"].as_f64().unwrap();

        let expected_refs: Vec<&str> = expected_strs.iter().map(|s| s.as_str()).collect();
        let got_refs: Vec<&str> = got_strs.iter().map(|s| s.as_str()).collect();
        let actual = jaccard_divergence(&expected_refs, &got_refs);

        assert!(
            (actual - expected_result).abs() < 1e-9,
            "jaccard vector '{id}': expected {expected_result}, got {actual}"
        );
    }
}

#[test]
fn divergence_rank_vectors() {
    let path = conformance_path("divergence_vectors.json");
    let json = load_json(&path);

    let cases = json["rank"].as_array()
        .expect("divergence_vectors.json must have a 'rank' array");

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let expected_strs: Vec<String> = case["expected"].as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let got_strs: Vec<String> = case["got"].as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let expected_result = case["result"].as_f64().unwrap();

        let expected_refs: Vec<&str> = expected_strs.iter().map(|s| s.as_str()).collect();
        let got_refs: Vec<&str> = got_strs.iter().map(|s| s.as_str()).collect();
        let actual = rank_divergence(&expected_refs, &got_refs);

        assert!(
            (actual - expected_result).abs() < 1e-9,
            "rank vector '{id}': expected {expected_result}, got {actual}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 2 — CapabilityManifest conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn manifest_shipped_mempalace() {
    let path = manifest_path("mempalace.json");
    let data = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let manifest = CapabilityManifest::decode(&data)
        .expect("mempalace.json must decode without error");

    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.product.id, "mempalace");
    assert_eq!(manifest.product.provenance.as_str(), "ground-truth-ours");
    assert_eq!(manifest.calls.len(), 4, "mempalace must have 4 call entries");

    let write = manifest.calls.get("write").expect("write entry must exist");
    assert_eq!(write.tool, "mempalace_add_drawer");
    assert_eq!(write.technique, vec!["embedding"]);
    assert!(!write.unmatched);
    assert_eq!(write.constant_args.get("wing").map(|s| s.as_str()), Some("benchmark"));
    assert_eq!(write.constant_args.get("room").map(|s| s.as_str()), Some("import"));

    let query = manifest.calls.get("query").expect("query entry must exist");
    assert_eq!(query.tool, "mempalace_search");
    assert!(query.technique.contains(&"bm25".to_string()));
    assert!(query.technique.contains(&"vector_cosine".to_string()));
    assert!(query.constant_args.is_empty());

    let list = manifest.calls.get("list").expect("list entry must exist");
    assert_eq!(list.tool, "mempalace_list_drawers");
    assert_eq!(list.technique, vec!["none"]);
    assert!(list.pagination.is_some());

    let fetch = manifest.calls.get("fetch").expect("fetch entry must exist");
    assert_eq!(fetch.tool, "mempalace_get_drawer");

    // Dispatch table.
    let table = manifest.resolve_dispatch_table();
    let d_query = table.get("query").expect("dispatch query entry must exist");
    assert_eq!(d_query.tool_name, "mempalace_search");
    assert_eq!(d_query.provenance.as_str(), "ground-truth-ours");
}

#[test]
fn manifest_shipped_mem0() {
    let path = manifest_path("mem0.json");
    let data = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let manifest = CapabilityManifest::decode(&data)
        .expect("mem0.json must decode without error");

    assert_eq!(manifest.product.id, "mem0");
    assert_eq!(manifest.product.provenance.as_str(), "authored-from-public-docs");
    assert_eq!(manifest.calls.len(), 4);

    let write = manifest.calls.get("write").expect("write entry must exist");
    assert!(write.technique.contains(&"llm_extraction".to_string()));
    assert!(write.technique.contains(&"embedding".to_string()));

    let query = manifest.calls.get("query").expect("query entry must exist");
    assert_eq!(query.tool, "search_memories");
    assert_eq!(query.technique, vec!["vector_cosine"]);
}

#[test]
fn manifest_shipped_gbrain() {
    let path = manifest_path("gbrain.json");
    let data = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let manifest = CapabilityManifest::decode(&data)
        .expect("gbrain.json must decode without error");

    assert_eq!(manifest.product.id, "gbrain");
    assert_eq!(manifest.product.provenance.as_str(), "authored-from-public-docs");
    assert_eq!(manifest.calls.len(), 3);

    let query = manifest.calls.get("query").expect("query entry must exist");
    assert!(query.technique.contains(&"vector_hnsw".to_string()));
    assert!(query.technique.contains(&"bm25".to_string()));
    assert!(query.technique.contains(&"rrf".to_string()));

    let think = manifest.calls.get("think").expect("think entry must exist");
    assert!(think.unmatched, "think must be marked unmatched");
    assert!(think.technique.contains(&"graph_traversal".to_string()));

    // Transport with space in command.
    match &manifest.transport {
        mcp_benchmarker_rs::manifest::Transport::Stdio { command } => {
            assert_eq!(command, "gbrain mcp");
        }
        other => panic!("Expected stdio transport, got {other:?}"),
    }
}

#[test]
fn manifest_error_unknown_schema_version() {
    let path = conformance_path("manifest_vectors.json");
    let json = load_json(&path);
    let cases = json["error_cases"].as_array().expect("error_cases must be array");

    let case = cases.iter().find(|c| c["id"] == "unknown-schema-version")
        .expect("unknown-schema-version case must exist");
    let raw_json = case["json"].as_str().unwrap();
    let err = CapabilityManifest::decode(raw_json.as_bytes())
        .expect_err("must fail with unknownSchemaVersion");
    assert!(matches!(err, ManifestValidationError::UnknownSchemaVersion(_)),
        "expected UnknownSchemaVersion, got {err:?}");
}

#[test]
fn manifest_error_unknown_provenance() {
    let path = conformance_path("manifest_vectors.json");
    let json = load_json(&path);
    let cases = json["error_cases"].as_array().unwrap();

    let case = cases.iter().find(|c| c["id"] == "unknown-provenance").unwrap();
    let raw_json = case["json"].as_str().unwrap();
    let err = CapabilityManifest::decode(raw_json.as_bytes())
        .expect_err("must fail with unknownProvenance");
    assert!(matches!(err, ManifestValidationError::UnknownProvenance(_)),
        "expected UnknownProvenance, got {err:?}");
}

#[test]
fn manifest_error_unknown_technique() {
    let path = conformance_path("manifest_vectors.json");
    let json = load_json(&path);
    let cases = json["error_cases"].as_array().unwrap();

    let case = cases.iter().find(|c| c["id"] == "unknown-technique").unwrap();
    let raw_json = case["json"].as_str().unwrap();
    let err = CapabilityManifest::decode(raw_json.as_bytes())
        .expect_err("must fail with unknownTechnique");
    assert!(matches!(err, ManifestValidationError::UnknownTechnique(_)),
        "expected UnknownTechnique, got {err:?}");
}

#[test]
fn manifest_error_empty_technique() {
    let path = conformance_path("manifest_vectors.json");
    let json = load_json(&path);
    let cases = json["error_cases"].as_array().unwrap();

    let case = cases.iter().find(|c| c["id"] == "empty-technique-list").unwrap();
    let raw_json = case["json"].as_str().unwrap();
    let err = CapabilityManifest::decode(raw_json.as_bytes())
        .expect_err("must fail with emptyTechniqueList");
    assert!(matches!(err, ManifestValidationError::EmptyTechniqueList { .. }),
        "expected EmptyTechniqueList, got {err:?}");
}

#[test]
fn manifest_error_missing_write() {
    let path = conformance_path("manifest_vectors.json");
    let json = load_json(&path);
    let cases = json["error_cases"].as_array().unwrap();

    let case = cases.iter().find(|c| c["id"] == "missing-calls-write").unwrap();
    let raw_json = case["json"].as_str().unwrap();
    let err = CapabilityManifest::decode(raw_json.as_bytes())
        .expect_err("must fail with requiredFieldMissing");
    assert!(matches!(err, ManifestValidationError::RequiredFieldMissing(_)),
        "expected RequiredFieldMissing, got {err:?}");
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 3 — DegeneracyGuard conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn guard_classify_vectors() {
    let path = conformance_path("guard_vectors.json");
    let json = load_json(&path);

    let cases = json["classify_cases"].as_array()
        .expect("guard_vectors.json must have classify_cases");

    let guard = DegeneracyGuard::new();

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let expected_verdict = case["expected_verdict"].as_str().unwrap();

        let probe_rankings: Vec<Vec<String>> = case["probe_rankings"]
            .as_array().unwrap()
            .iter()
            .map(|ranking| {
                ranking.as_array().unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_string())
                    .collect()
            })
            .collect();

        let verdict = guard.classify(&probe_rankings);
        assert_eq!(
            verdict.discriminant(),
            expected_verdict,
            "classify vector '{id}': expected verdict '{expected_verdict}', got '{}'",
            verdict.discriminant()
        );
    }
}

#[test]
fn guard_fallback_vectors() {
    let path = conformance_path("guard_vectors.json");
    let json = load_json(&path);

    let cases = json["fallback_cases"].as_array()
        .expect("guard_vectors.json must have fallback_cases");

    let guard = DegeneracyGuard::new();

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let expected = case["expected"].as_bool().unwrap();

        let text_blocks: Vec<&str> = case["text_blocks"]
            .as_array().unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();

        let actual = guard.check_fallback(&text_blocks);
        assert_eq!(
            actual, expected,
            "fallback vector '{id}': expected {expected}, got {actual}"
        );
    }
}

#[test]
fn guard_confirmation_vectors() {
    let path = conformance_path("guard_vectors.json");
    let json = load_json(&path);

    let cases = json["confirmation_cases"].as_array()
        .expect("guard_vectors.json must have confirmation_cases");

    let guard = DegeneracyGuard::new();

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let expected = case["expected"].as_bool().unwrap();
        let confirmed_count = case["confirmed_count"].as_u64().unwrap() as usize;
        let total = case["total"].as_u64().unwrap() as usize;
        let recall = case["recall"].as_f64().unwrap();

        let actual = guard.check_confirmation(confirmed_count, total, recall);
        assert_eq!(
            actual, expected,
            "confirmation vector '{id}': expected {expected}, got {actual}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 3 — LongMemEval corpus loader tests
//
// All tests run against the hand-authored synthetic sample shared with Swift:
//   apps/mcp-benchmarker/Tests/mcp-benchmarkerTests/longmemeval_sample.json
//
// synthetic_001: question_type "single-session-user"  → scored (non-abstention)
// synthetic_002: question_type "single-session-user_abs" → excluded (abstention)
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn lme_corpus_loads_synthetic_sample() {
    let path = lme_sample_path();
    let corpus = load_corpus(&path)
        .unwrap_or_else(|e| panic!("load_corpus failed: {e}"));
    assert_eq!(corpus.questions.len(), 1, "expected 1 non-abstention question");
    assert_eq!(corpus.abstention_count, 1, "expected 1 abstention excluded");
    assert_eq!(corpus.total_count(), 2, "expected 2 total questions");
}

#[test]
fn lme_corpus_question_fields() {
    let corpus = load_corpus(&lme_sample_path()).expect("load_corpus failed");
    let q = corpus.questions.first().expect("must have one question");

    assert_eq!(q.question_id, "synthetic_001");
    assert_eq!(q.question_type, "single-session-user");
    assert_eq!(q.question, "What color was the apple Alice mentioned on Monday?");
    assert_eq!(q.answer, "Red");
    assert_eq!(q.question_date, "2024/01/15 (Mon) 10:00");
    assert_eq!(q.answer_session_ids, vec!["session_abc"]);
}

#[test]
fn lme_corpus_haystack_parallel_arrays() {
    let corpus = load_corpus(&lme_sample_path()).expect("load_corpus failed");
    let q = corpus.questions.first().expect("must have one question");

    assert_eq!(q.haystack_session_ids.len(), q.haystack_sessions.len(),
        "haystack_session_ids and haystack_sessions must be parallel");
    assert_eq!(q.haystack_dates.len(), q.haystack_session_ids.len(),
        "haystack_dates and haystack_session_ids must be parallel");
    assert_eq!(q.haystack_session_ids, vec!["session_abc"]);
    assert_eq!(q.haystack_dates, vec!["2024/01/14 (Sun) 09:00"]);
}

#[test]
fn lme_corpus_turn_decoding() {
    let corpus = load_corpus(&lme_sample_path()).expect("load_corpus failed");
    let q = corpus.questions.first().expect("must have one question");
    let session = q.haystack_sessions.first().expect("must have one session");

    assert_eq!(session.len(), 2, "session must have 2 turns");
    assert_eq!(session[0].role, "user");
    assert_eq!(session[0].content, "I saw a red apple at the market.");
    assert!(session[0].has_answer, "turn 0 has_answer must be true");
    assert_eq!(session[1].role, "assistant");
    assert!(!session[1].has_answer, "turn 1 has_answer must be false");
}

#[test]
fn lme_corpus_abstention_excluded_from_questions() {
    let corpus = load_corpus(&lme_sample_path()).expect("load_corpus failed");
    for q in &corpus.questions {
        assert!(!q.question_type.ends_with("_abs"),
            "abstention question '{}' should not appear in corpus.questions", q.question_id);
    }
}

#[test]
fn lme_corpus_error_empty_question_id() {
    let bad_json = r#"[{
        "question_id": "", "question_type": "single-session-user",
        "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
        "haystack_dates": [], "haystack_session_ids": [],
        "haystack_sessions": [], "answer_session_ids": []
    }]"#;
    let tmp = std::env::temp_dir().join("lme_bad_id_rs.json");
    std::fs::write(&tmp, bad_json).expect("write tmp failed");
    let err = load_corpus(&tmp).expect_err("expected error for empty question_id");
    assert!(err.0.contains("question_id"),
        "error should name 'question_id': {}", err.0);
    assert!(err.0.contains("question[0]"),
        "error should name index 0: {}", err.0);
    let _ = std::fs::remove_file(&tmp);
}

#[test]
fn lme_corpus_error_parallel_array_mismatch() {
    // haystack_session_ids has 1 entry; haystack_sessions has 0.
    let bad_json = r#"[{
        "question_id": "x1", "question_type": "single-session-user",
        "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
        "haystack_dates": ["2024/01/01 (Mon) 00:00"],
        "haystack_session_ids": ["sess1"],
        "haystack_sessions": [],
        "answer_session_ids": []
    }]"#;
    let tmp = std::env::temp_dir().join("lme_bad_parallel_rs.json");
    std::fs::write(&tmp, bad_json).expect("write tmp failed");
    let err = load_corpus(&tmp).expect_err("expected error for parallel-array mismatch");
    assert!(err.0.contains("haystack_session_ids"),
        "error should name the mismatched field: {}", err.0);
    assert!(err.0.contains("question[0]"),
        "error should name index 0: {}", err.0);
    let _ = std::fs::remove_file(&tmp);
}

#[test]
fn lme_corpus_nonexistent_file_errors() {
    let path = PathBuf::from("/nonexistent/path/lme_does_not_exist.json");
    assert!(load_corpus(&path).is_err(), "expected error for nonexistent file");
}
