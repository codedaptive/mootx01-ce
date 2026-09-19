//! conformance.rs — shared-vector conformance tests for the Rust leg.
//!
//! Drives the three modules against the shared JSON vectors in
//! `benchmarks/conformance/`. Same inputs → identical outputs
//! on the Rust leg as on the Swift leg is the correctness definition
//! (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//!
//! The conformance/ directory is resolved relative to this file's location:
//!   tests/conformance.rs → benchmarks/rust/ → benchmarks/ →
//!   benchmarks/conformance/
//!
//! All expected values are pre-computed in the JSON vectors. If a test fails,
//! the Rust impl diverges from the Swift reference and the vector needs
//! investigation before either side is amended.

use mcp_benchmarker_rs::degeneracy_guard::DegeneracyGuard;
use mcp_benchmarker_rs::divergence::{jaccard_divergence, rank_divergence};
use mcp_benchmarker_rs::lmeb_scorer::{lmeb_ap, lmeb_mrr, lmeb_ndcg, lmeb_ranked_docs_audited, lmeb_recall};
use mcp_benchmarker_rs::locomo_corpus::load_locomo_corpus;
use mcp_benchmarker_rs::locomo_scorer::{locomo_manifest_as_lme, LoCoMoManifestEntry};
use mcp_benchmarker_rs::longmemeval_corpus::load_corpus;
use mcp_benchmarker_rs::longmemeval_scorer::{
    lme_ranked_sessions, lme_recall_all, lme_recall_any, lme_session_mrr, LmeManifestEntry,
};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve the path to `benchmarks/conformance/<filename>`.
/// This file lives at `benchmarks/rust/tests/conformance.rs`.
///
/// The crate lives at benchmarks/rust/. CARGO_MANIFEST_DIR points at
/// benchmarks/rust/; one parent() reaches benchmarks/,
/// which is where conformance/ and manifests/ live.
fn conformance_path(filename: &str) -> PathBuf {
    // __file__ is not stable in Rust integration tests; use CARGO_MANIFEST_DIR
    // (set by cargo for integration tests) which points to the crate root.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // manifest_dir = benchmarks/rust/
    // parent() → benchmarks/
    manifest_dir
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join(filename)
}

/// Resolve the path to the hand-authored synthetic LongMemEval test sample.
/// The sample lives beside the Swift test files at
/// `benchmarks/Tests/mcp-benchmarkerTests/longmemeval_sample.json`.
fn lme_sample_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // manifest_dir = benchmarks/rust/
    // parent() → benchmarks/
    manifest_dir
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("Tests")
        .join("mcp-benchmarkerTests")
        .join("longmemeval_sample.json")
}

/// Resolve the path to the hand-authored synthetic LoCoMo test sample.
/// The sample lives beside the Swift test files at
/// `benchmarks/Tests/mcp-benchmarkerTests/locomo_sample.json`.
fn locomo_sample_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("Tests")
        .join("mcp-benchmarkerTests")
        .join("locomo_sample.json")
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
//   benchmarks/Tests/mcp-benchmarkerTests/longmemeval_sample.json
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

// ─────────────────────────────────────────────────────────────────────────────
// Part 5 — LongMemEval scorer conformance vectors
//
// Driven by `benchmarks/conformance/longmemeval_vectors.json`.
// Same vectors drive both Swift (LongMemEvalScorerTests.swift) and Rust legs.
// Expected values are pre-computed; tolerance for float comparison is 1e-9.
// ─────────────────────────────────────────────────────────────────────────────

/// Loads `longmemeval_vectors.json` as a parsed JSON value.
fn load_lme_vectors() -> Value {
    let path = conformance_path("longmemeval_vectors.json");
    load_json(&path)
}

#[test]
fn lme_scorer_recall_vectors() {
    let json = load_lme_vectors();
    let cases = json["recall_cases"]
        .as_array()
        .expect("longmemeval_vectors.json must have recall_cases");

    for case in cases {
        let id = case["id"].as_str().unwrap();

        let ranked: Vec<String> = case["ranked_session_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        let answer_vec: Vec<String> = case["answer_session_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let answer_set: HashSet<String> = answer_vec.into_iter().collect();

        let exp_ra1  = case["recall_any_at_1"].as_f64().unwrap();
        let exp_ra5  = case["recall_any_at_5"].as_f64().unwrap();
        let exp_ra10 = case["recall_any_at_10"].as_f64().unwrap();
        let exp_rl1  = case["recall_all_at_1"].as_f64().unwrap();
        let exp_rl5  = case["recall_all_at_5"].as_f64().unwrap();
        let exp_rl10 = case["recall_all_at_10"].as_f64().unwrap();
        let exp_mrr  = case["mrr"].as_f64().unwrap();

        let tol = 1e-9;

        let got_ra1  = lme_recall_any(&ranked, &answer_set, 1);
        let got_ra5  = lme_recall_any(&ranked, &answer_set, 5);
        let got_ra10 = lme_recall_any(&ranked, &answer_set, 10);
        let got_rl1  = lme_recall_all(&ranked, &answer_set, 1);
        let got_rl5  = lme_recall_all(&ranked, &answer_set, 5);
        let got_rl10 = lme_recall_all(&ranked, &answer_set, 10);
        let got_mrr  = lme_session_mrr(&ranked, &answer_set);

        assert!((got_ra1  - exp_ra1).abs()  < tol, "'{id}' recall_any_at_1:  exp {exp_ra1}, got {got_ra1}");
        assert!((got_ra5  - exp_ra5).abs()  < tol, "'{id}' recall_any_at_5:  exp {exp_ra5}, got {got_ra5}");
        assert!((got_ra10 - exp_ra10).abs() < tol, "'{id}' recall_any_at_10: exp {exp_ra10}, got {got_ra10}");
        assert!((got_rl1  - exp_rl1).abs()  < tol, "'{id}' recall_all_at_1:  exp {exp_rl1}, got {got_rl1}");
        assert!((got_rl5  - exp_rl5).abs()  < tol, "'{id}' recall_all_at_5:  exp {exp_rl5}, got {got_rl5}");
        assert!((got_rl10 - exp_rl10).abs() < tol, "'{id}' recall_all_at_10: exp {exp_rl10}, got {got_rl10}");
        assert!((got_mrr  - exp_mrr).abs()  < tol, "'{id}' mrr:              exp {exp_mrr}, got {got_mrr}");
    }
}

#[test]
fn lme_scorer_uuid_mapping_vectors() {
    let json = load_lme_vectors();
    let cases = json["uuid_mapping_cases"]
        .as_array()
        .expect("longmemeval_vectors.json must have uuid_mapping_cases");

    for case in cases {
        let id = case["id"].as_str().unwrap();

        let retrieved_uuids: Vec<String> = case["retrieved_uuids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        let manifest: Vec<LmeManifestEntry> = case["manifest"]
            .as_array().unwrap()
            .iter()
            .map(|entry| LmeManifestEntry {
                uuid: entry["uuid"].as_str().unwrap().to_string(),
                session_id: entry["session_id"].as_str().unwrap().to_string(),
                // turn_index/session_index/role are not in the minimal mapping
                // vectors; use stable dummy values.
                turn_index: 0,
                session_index: 0,
                role: "user".to_string(),
            })
            .collect();

        let expected: Vec<String> = case["expected_ranked_session_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        let got = lme_ranked_sessions(&retrieved_uuids, &manifest);

        assert_eq!(
            got, expected,
            "uuid_mapping vector '{id}': expected {expected:?}, got {got:?}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 1 — LoCoMo corpus loader tests
//
// All tests run against the hand-authored synthetic sample shared with Swift:
//   benchmarks/Tests/mcp-benchmarkerTests/locomo_sample.json
//
// Synthetic sample: 1 conversation, 2 sessions (5+4 turns), 5 QAs.
// 4 scoreable (categories 1-4), 1 adversarial (category 5) excluded.
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn locomo_corpus_loads_synthetic_sample() {
    let path = locomo_sample_path();
    let corpus = load_locomo_corpus(&path)
        .unwrap_or_else(|e| panic!("load_locomo_corpus failed: {e}"));
    assert_eq!(corpus.conversations.len(), 1, "expected 1 conversation");
    assert_eq!(corpus.questions.len(), 4, "expected 4 scoreable questions");
    assert_eq!(corpus.adversarial_count, 1, "expected 1 adversarial excluded");
    assert_eq!(corpus.total_count(), 5, "expected 5 total QAs");
}

#[test]
fn locomo_corpus_conversation_fields() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let conv = &corpus.conversations[0];

    assert_eq!(conv.sample_id, "test-conv-01");
    assert_eq!(conv.speaker_a, "Alice");
    assert_eq!(conv.speaker_b, "Bob");
    assert_eq!(conv.sessions.len(), 2, "expected 2 sessions");
}

#[test]
fn locomo_corpus_sessions_in_order() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let conv = &corpus.conversations[0];

    assert_eq!(conv.sessions[0].session_number, 1);
    assert_eq!(conv.sessions[1].session_number, 2);
    assert_eq!(conv.sessions[0].date_time, "3:00 pm on 1 Jan, 2024");
    assert_eq!(conv.sessions[1].date_time, "2:00 pm on 15 Jan, 2024");
}

#[test]
fn locomo_corpus_turn_counts() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let conv = &corpus.conversations[0];

    assert_eq!(conv.sessions[0].turns.len(), 5, "session 1 must have 5 turns");
    assert_eq!(conv.sessions[1].turns.len(), 4, "session 2 must have 4 turns");
}

#[test]
fn locomo_corpus_dia_ids() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let conv = &corpus.conversations[0];

    let s1_dia_ids: Vec<&str> = conv.sessions[0].turns.iter().map(|t| t.dia_id.as_str()).collect();
    assert_eq!(s1_dia_ids, vec!["D1:1", "D1:2", "D1:3", "D1:4", "D1:5"]);

    let s2_dia_ids: Vec<&str> = conv.sessions[1].turns.iter().map(|t| t.dia_id.as_str()).collect();
    assert_eq!(s2_dia_ids, vec!["D2:1", "D2:2", "D2:3", "D2:4"]);
}

#[test]
fn locomo_corpus_all_turns_flattened() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let conv = &corpus.conversations[0];
    let all = conv.all_turns();

    assert_eq!(all.len(), 9, "5+4 = 9 total turns");
    assert_eq!(all[0].0, 1, "first turn is in session 1");
    assert_eq!(all[0].1.dia_id, "D1:1");
    assert_eq!(all[5].0, 2, "sixth turn is in session 2");
    assert_eq!(all[5].1.dia_id, "D2:1");
}

#[test]
fn locomo_corpus_question_categories() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    let categories: std::collections::HashSet<u8> =
        corpus.questions.iter().map(|q| q.category).collect();
    assert_eq!(categories, std::collections::HashSet::from([1u8, 2, 3, 4]));
}

#[test]
fn locomo_corpus_category_labels() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    for q in &corpus.questions {
        let expected = match q.category {
            1 => "single_hop",
            2 => "temporal",
            3 => "multi_hop",
            4 => "open_domain",
            _ => "unknown",
        };
        assert_eq!(q.category_label(), expected,
            "category {} must map to '{}'", q.category, expected);
    }
}

#[test]
fn locomo_corpus_question_ids_unique_and_prefixed() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    for q in &corpus.questions {
        assert!(q.question_id.starts_with("test-conv-01"),
            "question_id must start with sample_id: {}", q.question_id);
    }
    let ids: std::collections::HashSet<&str> =
        corpus.questions.iter().map(|q| q.question_id.as_str()).collect();
    assert_eq!(ids.len(), corpus.questions.len(), "question_ids must be unique");
}

#[test]
fn locomo_corpus_evidence_field() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");

    let cat1 = corpus.questions.iter().find(|q| q.category == 1)
        .expect("must have category 1 question");
    assert_eq!(cat1.evidence, vec!["D1:3"], "category 1 evidence = D1:3");

    let cat3 = corpus.questions.iter().find(|q| q.category == 3)
        .expect("must have category 3 question");
    assert_eq!(cat3.evidence.len(), 2, "category 3 has 2 evidence items");
    assert!(cat3.evidence.contains(&"D2:2".to_string()), "category 3 evidence contains D2:2");
    assert!(cat3.evidence.contains(&"D2:4".to_string()), "category 3 evidence contains D2:4");
}

#[test]
fn locomo_corpus_category5_excluded() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    for q in &corpus.questions {
        assert_ne!(q.category, 5, "category 5 must be excluded from questions");
    }
    assert_eq!(corpus.adversarial_count, 1, "adversarial_count must be 1");
}

#[test]
fn locomo_corpus_conversation_index() {
    let corpus = load_locomo_corpus(&locomo_sample_path())
        .expect("load_locomo_corpus failed");
    for q in &corpus.questions {
        assert_eq!(q.conversation_index, 0,
            "question {} must reference conversation 0", q.question_id);
    }
}

#[test]
fn locomo_corpus_nonexistent_file_errors() {
    let path = PathBuf::from("/nonexistent/path/locomo_does_not_exist.json");
    assert!(load_locomo_corpus(&path).is_err(), "expected error for nonexistent file");
}

#[test]
fn locomo_corpus_error_empty_sample_id() {
    let bad_json = r#"[{"sample_id": "",
        "conversation": {"speaker_a": "A", "speaker_b": "B",
          "session_1_date_time": "noon",
          "session_1": [{"speaker": "A", "dia_id": "D1:1", "text": "hi"}]},
        "qa": [], "event_summary": {}, "observation": {}, "session_summary": {}}]"#;
    let tmp = std::env::temp_dir().join("locomo_bad_id_rs.json");
    std::fs::write(&tmp, bad_json).expect("write tmp failed");
    let err = load_locomo_corpus(&tmp)
        .expect_err("expected error for empty sample_id");
    assert!(err.0.contains("sample_id"),
        "error should name 'sample_id': {}", err.0);
    let _ = std::fs::remove_file(&tmp);
}

#[test]
fn locomo_corpus_error_no_sessions() {
    let bad_json = r#"[{"sample_id": "conv-test",
        "conversation": {"speaker_a": "A", "speaker_b": "B"},
        "qa": [], "event_summary": {}, "observation": {}, "session_summary": {}}]"#;
    let tmp = std::env::temp_dir().join("locomo_no_sessions_rs.json");
    std::fs::write(&tmp, bad_json).expect("write tmp failed");
    let err = load_locomo_corpus(&tmp)
        .expect_err("expected error for no sessions");
    assert!(err.0.to_lowercase().contains("session"),
        "error should mention 'session': {}", err.0);
    let _ = std::fs::remove_file(&tmp);
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 4 — LoCoMo scorer conformance vectors
//
// Driven by `benchmarks/conformance/locomo_vectors.json`.
// Same vectors drive both Swift (LoCoMoScorerTests.swift) and Rust legs.
// Expected values are pre-computed; float tolerance is 1e-9.
//
// recall_cases:     verify the string-agnostic LME math works with dia_id format
//                   strings ("D1:3"). Uses lme_recall_any/all/session_mrr directly.
// uuid_mapping_cases: verify locomo_manifest_as_lme + lme_ranked_sessions bridges
//                   UUIDs correctly to dia_ids.
// ─────────────────────────────────────────────────────────────────────────────

/// Loads `locomo_vectors.json` as a parsed JSON value.
fn load_locomo_vectors() -> Value {
    let path = conformance_path("locomo_vectors.json");
    load_json(&path)
}

/// Recall conformance: verify the LME scoring math (string-agnostic) works
/// correctly when given dia_id format strings ("D1:3") as the ranked list and
/// evidence set. Pins all 7 metrics to hand-computed expected values.
#[test]
fn locomo_scorer_recall_vectors() {
    let json = load_locomo_vectors();
    let cases = json["recall_cases"]
        .as_array()
        .expect("locomo_vectors.json must have recall_cases");

    for case in cases {
        let id = case["id"].as_str().unwrap();

        // ranked_dia_ids is the pre-computed dia_id ranking (the string-agnostic
        // math operates directly on these, matching Swift scoreLoCoMoQuestion).
        let ranked: Vec<String> = case["ranked_dia_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        let evidence_vec: Vec<String> = case["evidence_dia_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let evidence_set: HashSet<String> = evidence_vec.into_iter().collect();

        let exp_ra1  = case["recall_any_at_1"].as_f64().unwrap();
        let exp_ra5  = case["recall_any_at_5"].as_f64().unwrap();
        let exp_ra10 = case["recall_any_at_10"].as_f64().unwrap();
        let exp_rl1  = case["recall_all_at_1"].as_f64().unwrap();
        let exp_rl5  = case["recall_all_at_5"].as_f64().unwrap();
        let exp_rl10 = case["recall_all_at_10"].as_f64().unwrap();
        let exp_mrr  = case["mrr"].as_f64().unwrap();

        let tol = 1e-9;

        let got_ra1  = lme_recall_any(&ranked, &evidence_set, 1);
        let got_ra5  = lme_recall_any(&ranked, &evidence_set, 5);
        let got_ra10 = lme_recall_any(&ranked, &evidence_set, 10);
        let got_rl1  = lme_recall_all(&ranked, &evidence_set, 1);
        let got_rl5  = lme_recall_all(&ranked, &evidence_set, 5);
        let got_rl10 = lme_recall_all(&ranked, &evidence_set, 10);
        let got_mrr  = lme_session_mrr(&ranked, &evidence_set);

        assert!((got_ra1  - exp_ra1).abs()  < tol, "locomo '{id}' recall_any_at_1:  exp {exp_ra1}, got {got_ra1}");
        assert!((got_ra5  - exp_ra5).abs()  < tol, "locomo '{id}' recall_any_at_5:  exp {exp_ra5}, got {got_ra5}");
        assert!((got_ra10 - exp_ra10).abs() < tol, "locomo '{id}' recall_any_at_10: exp {exp_ra10}, got {got_ra10}");
        assert!((got_rl1  - exp_rl1).abs()  < tol, "locomo '{id}' recall_all_at_1:  exp {exp_rl1}, got {got_rl1}");
        assert!((got_rl5  - exp_rl5).abs()  < tol, "locomo '{id}' recall_all_at_5:  exp {exp_rl5}, got {got_rl5}");
        assert!((got_rl10 - exp_rl10).abs() < tol, "locomo '{id}' recall_all_at_10: exp {exp_rl10}, got {got_rl10}");
        assert!((got_mrr  - exp_mrr).abs()  < tol, "locomo '{id}' mrr:              exp {exp_mrr}, got {got_mrr}");
    }
}

/// UUID-mapping conformance: verify `locomo_manifest_as_lme` + `lme_ranked_sessions`
/// correctly bridges UUIDs → dia_ids, including deduplication and order preservation.
#[test]
fn locomo_scorer_uuid_mapping_vectors() {
    let json = load_locomo_vectors();
    let cases = json["uuid_mapping_cases"]
        .as_array()
        .expect("locomo_vectors.json must have uuid_mapping_cases");

    for case in cases {
        let id = case["id"].as_str().unwrap();

        let retrieved_uuids: Vec<String> = case["retrieved_uuids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        // Build LoCoMoManifestEntry list from the "manifest" array.
        // Each entry has "uuid" and "dia_id" fields.
        let locomo_manifest: Vec<LoCoMoManifestEntry> = case["manifest"]
            .as_array().unwrap()
            .iter()
            .enumerate()
            .map(|(i, entry)| LoCoMoManifestEntry {
                uuid:           entry["uuid"].as_str().unwrap().to_string(),
                dia_id:         entry["dia_id"].as_str().unwrap().to_string(),
                session_number: 1,     // unused in mapping math; stable dummy
                turn_index:     i,     // unused in mapping math; stable dummy
                speaker:        "A".to_string(), // unused in mapping math
            })
            .collect();

        // Bridge to LmeManifestEntry (dia_id → session_id slot) and rank.
        let lme_manifest = locomo_manifest_as_lme(&locomo_manifest);
        let got = lme_ranked_sessions(&retrieved_uuids, &lme_manifest);

        let expected: Vec<String> = case["expected_ranked_dia_ids"]
            .as_array().unwrap()
            .iter().map(|v| v.as_str().unwrap().to_string()).collect();

        assert_eq!(
            got, expected,
            "locomo uuid_mapping '{id}': expected {expected:?}, got {got:?}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LMEB conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Loads `lmeb_vectors.json` from the conformance directory.
fn load_lmeb_vectors() -> Value {
    let path = conformance_path("lmeb_vectors.json");
    load_json(&path)
}

/// Converts a JSON array of strings to `Vec<String>`.
fn json_string_vec(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

/// Converts a JSON array of strings to `HashSet<String>`.
fn json_string_set(v: &Value) -> HashSet<String> {
    json_string_vec(v).into_iter().collect()
}

/// LMEB nDCG@k conformance — must reproduce every expected value within 1e-9.
#[test]
fn lmeb_scorer_ndcg_vectors() {
    let json = load_lmeb_vectors();
    let cases = json["ndcg_cases"]
        .as_array()
        .expect("lmeb_vectors.json must have ndcg_cases");

    for case in cases {
        let id       = case["id"].as_str().unwrap();
        let ranked   = json_string_vec(&case["ranked_doc_ids"]);
        let rel      = json_string_set(&case["relevant_doc_ids"]);
        let k        = case["k"].as_u64().unwrap() as usize;
        let expected = case["ndcg"].as_f64().unwrap();

        let got = lmeb_ndcg(&ranked, &rel, k);
        assert!(
            (got - expected).abs() < 1e-9,
            "LMEB nDCG case '{id}': expected {expected:.15}, got {got:.15}"
        );
    }
}

/// LMEB document-level MRR conformance — must reproduce every expected value within 1e-9.
#[test]
fn lmeb_scorer_mrr_vectors() {
    let json = load_lmeb_vectors();
    let cases = json["mrr_cases"]
        .as_array()
        .expect("lmeb_vectors.json must have mrr_cases");

    for case in cases {
        let id       = case["id"].as_str().unwrap();
        let ranked   = json_string_vec(&case["ranked_doc_ids"]);
        let rel      = json_string_set(&case["relevant_doc_ids"]);
        let expected = case["mrr"].as_f64().unwrap();

        let got = lmeb_mrr(&ranked, &rel);
        assert!(
            (got - expected).abs() < 1e-9,
            "LMEB MRR case '{id}': expected {expected:.15}, got {got:.15}"
        );
    }
}

/// LMEB Recall@k conformance — tests recall@1, @5, @10 for every case.
#[test]
fn lmeb_scorer_recall_vectors() {
    let json = load_lmeb_vectors();
    let cases = json["recall_cases"]
        .as_array()
        .expect("lmeb_vectors.json must have recall_cases");

    for case in cases {
        let id     = case["id"].as_str().unwrap();
        let ranked = json_string_vec(&case["ranked_doc_ids"]);
        let rel    = json_string_set(&case["relevant_doc_ids"]);

        let exp_r1  = case["recall_at_1"].as_f64().unwrap();
        let exp_r5  = case["recall_at_5"].as_f64().unwrap();
        let exp_r10 = case["recall_at_10"].as_f64().unwrap();

        let got_r1  = lmeb_recall(&ranked, &rel, 1);
        let got_r5  = lmeb_recall(&ranked, &rel, 5);
        let got_r10 = lmeb_recall(&ranked, &rel, 10);

        let tol = 1e-9;
        assert!((got_r1  - exp_r1).abs()  < tol,
            "LMEB recall case '{id}' @1:  exp {exp_r1}, got {got_r1}");
        assert!((got_r5  - exp_r5).abs()  < tol,
            "LMEB recall case '{id}' @5:  exp {exp_r5}, got {got_r5}");
        assert!((got_r10 - exp_r10).abs() < tol,
            "LMEB recall case '{id}' @10: exp {exp_r10}, got {got_r10}");
    }
}

/// LMEB AP@k conformance — must reproduce every expected value within 1e-9.
#[test]
fn lmeb_scorer_ap_vectors() {
    let json = load_lmeb_vectors();
    let cases = json["ap_cases"]
        .as_array()
        .expect("lmeb_vectors.json must have ap_cases");

    for case in cases {
        let id       = case["id"].as_str().unwrap();
        let ranked   = json_string_vec(&case["ranked_doc_ids"]);
        let rel      = json_string_set(&case["relevant_doc_ids"]);
        let k        = case["k"].as_u64().unwrap() as usize;
        let expected = case["ap"].as_f64().unwrap();

        let got = lmeb_ap(&ranked, &rel, k);
        assert!(
            (got - expected).abs() < 1e-9,
            "LMEB AP case '{id}': expected {expected:.15}, got {got:.15}"
        );
    }
}

/// LMEB UUID → doc ID mapping — pins that unmapped UUIDs keep their rank slot.
///
/// Mirrors the Swift `LMEBRankedDocsConformanceTests` in `LMEBScorerTests.swift`.
/// Both legs read `conformance/lmeb_vectors.json`, section `ranked_doc_cases`.
#[test]
fn lmeb_ranked_docs_audited_vectors() {
    use std::collections::HashMap;

    let json = load_lmeb_vectors();
    let cases = json["ranked_doc_cases"]
        .as_array()
        .expect("lmeb_vectors.json must have ranked_doc_cases");

    for case in cases {
        let id = case["id"].as_str().unwrap_or("(unknown)");
        let retrieved_uuids: Vec<String> = case["retrieved_uuids"]
            .as_array()
            .expect("ranked_doc_cases entry must have retrieved_uuids")
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        let uuid_to_doc_id: HashMap<String, String> = case["manifest"]
            .as_array()
            .expect("ranked_doc_cases entry must have manifest")
            .iter()
            .map(|e| {
                (
                    e["uuid"].as_str().unwrap().to_string(),
                    e["doc_id"].as_str().unwrap().to_string(),
                )
            })
            .collect();
        let expected: Vec<String> = case["expected_ranked_doc_ids"]
            .as_array()
            .expect("ranked_doc_cases entry must have expected_ranked_doc_ids")
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();

        let (got, _) = lmeb_ranked_docs_audited(&retrieved_uuids, &uuid_to_doc_id);
        assert_eq!(
            got, expected,
            "lmeb ranked_doc_cases '{id}': expected {expected:?}, got {got:?}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 3 — Supersession corpus conformance
// ─────────────────────────────────────────────────────────────────────────────

/// The committed supersession vector corpus (seed 20260725, 6 entities,
/// 3 versions, 4 contradictions) must regenerate EXACTLY on this leg. The
/// Swift leg runs the same check against the same file — a benchmark whose
/// corpus drifts between legs cannot support a claim.
#[test]
fn supersession_corpus_vectors() {
    use mcp_benchmarker_rs::supersession_corpus::{
        generate_supersession_corpus, SupersessionCorpus,
    };
    let path = conformance_path("supersession_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let expected: SupersessionCorpus =
        serde_json::from_str(&data).expect("supersession_vectors.json must decode");
    let generated = generate_supersession_corpus(20260725, 6, 3, 4);
    assert_eq!(generated, expected);
}

// ─────────────────────────────────────────────────────────────────────────────
// Part 4 — Journey corpus conformance
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Part 5 — Journey metrics conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Three hand-computed cases (empty, single terminal, three-step mixed) drive
/// the metrics computation on this leg. Same vector file as the Swift leg.
#[test]
fn journey_metrics_vectors() {
    use mcp_benchmarker_rs::journey_metrics::{
        compute_journey_metrics, JourneyMetricsVectors,
    };
    let path = conformance_path("journey_metrics_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let vectors: JourneyMetricsVectors =
        serde_json::from_str(&data).expect("journey_metrics_vectors.json must decode");
    for case in &vectors.cases {
        let computed = compute_journey_metrics(&case.steps);
        assert_eq!(
            computed, case.expected,
            "case '{}': computed {:?} != expected {:?}",
            case.description, computed, case.expected
        );
    }
}

/// The committed journey vector corpus (seed 20260725, 4 precise-miss
/// scenarios, 3 clusters × 4 members) must regenerate EXACTLY on this leg.
/// The Swift leg runs the same check against the same file.
#[test]
fn journey_corpus_vectors() {
    use mcp_benchmarker_rs::journey_corpus::{generate_journey_corpus, JourneyCorpus};
    let path = conformance_path("journey_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let expected: JourneyCorpus =
        serde_json::from_str(&data).expect("journey_vectors.json must decode");
    let generated = generate_journey_corpus(20260725, 4, 3, 4);
    assert_eq!(generated, expected);
}
