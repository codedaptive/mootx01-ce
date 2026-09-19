//! membench_spec.rs — JSON-vector conformance tests for the membench-spec Rust leg.
//!
//! Drives all membench-spec public functions against the shared JSON vectors at
//! `benchmarks/conformance/membench-spec/`. Both ports (Swift + Rust) must agree
//! to within 1e-9 on floating-point comparisons.
//!
//! Also covers: golden pins for FirstAgent/ThirdAgent prompt renders,
//! step↔sid round-trip, `MemBenchSpecRunMode::as_str()`, and
//! `MemBenchSpecReport` serde round-trip.

use mcp_benchmarker_rs::membench_spec_protocol::{
    answer_prompt, membench_count_tokens, parse_answer_choice, recall_query,
    step_id_from_storage_line, storage_line_dict, storage_line_string,
    MemBenchPerspective, StorageLineParseError, INITIAL_INSTRUACTION,
};
use mcp_benchmarker_rs::membench_spec_runner::{MemBenchSpecReport, MemBenchSpecRunMode};
use mcp_benchmarker_rs::membench_spec_scorer::{
    membench_spec_aggregate, membench_spec_answer_correct,
    membench_spec_efficiency_stats, membench_spec_get_recall, MemBenchSpecItemScore,
};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

fn membench_spec_conformance_path(filename: &str) -> PathBuf {
    // CARGO_MANIFEST_DIR = benchmarks/rust/
    // parent() → benchmarks/
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join("membench-spec")
        .join(filename)
}

fn load_protocol_vectors() -> Value {
    let path = membench_spec_conformance_path("protocol_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read protocol_vectors.json at {}: {e}", path.display()));
    serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("protocol_vectors.json parse error: {e}"))
}

fn load_scorer_vectors() -> Value {
    let path = membench_spec_conformance_path("scorer_vectors.json");
    let data = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read scorer_vectors.json at {}: {e}", path.display()));
    serde_json::from_str(&data)
        .unwrap_or_else(|e| panic!("scorer_vectors.json parse error: {e}"))
}

/// Builds a minimal report JSON string, then deserializes it.
///
/// `CapacitySampleWire` is a private bridge type in membench_spec_runner.rs
/// and cannot be named from external test code. Deserialization via serde_json
/// is the only way to construct a `MemBenchSpecReport` that carries
/// `capacity_samples: None` from outside the module.
fn make_minimal_report(run_mode: &str, answered_count: usize) -> MemBenchSpecReport {
    let json = serde_json::json!({
        "run_label": "test",
        "port": "rust",
        "agent": "FirstAgent",
        "seed": 42,
        "estate_mode": "per-item-spec",
        "encode_barrier": "drain",
        "shape": "disk",
        "run_mode": run_mode,
        "overall": { "label": "overall", "count": 0, "accuracy": 0.0, "mean_recall": 0.0 },
        "by_category": [],
        "by_perspective": [],
        "answered_count": answered_count,
        "write_efficiency": { "count": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0 },
        "read_efficiency": { "count": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0 },
        "capacity_samples": null,
        "capacity_buckets": null,
        "item_count": 0
    });
    serde_json::from_value(json).expect("make_minimal_report: JSON must be valid")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 INITIAL_INSTRUACTION constant
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_initial_instruaction_matches_vector() {
    let v = load_protocol_vectors();
    let expected = v["initial_instruaction"]["expected"]
        .as_str()
        .expect("initial_instruaction.expected must be a string");
    assert_eq!(INITIAL_INSTRUACTION, expected,
        "INITIAL_INSTRUACTION must match vector byte-for-byte");
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 storage_line_string cases
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_storage_line_string_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["storage_line_string_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let step = case["step"].as_u64().expect("step must be int") as usize;
        let message = case["message"].as_str().expect("message must be string");
        let expected = case["expected"].as_str().expect("expected must be string");
        let actual = storage_line_string(step, message);
        assert_eq!(actual, expected, "storage_line_string case '{}' mismatch", id);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 storage_line_dict cases
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_storage_line_dict_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["storage_line_dict_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let step = case["step"].as_u64().expect("step must be int") as usize;
        let user = case["user"].as_str().expect("user must be string");
        let agent = case["agent"].as_str().expect("agent must be string");
        let expected = case["expected"].as_str().expect("expected must be string");
        let actual = storage_line_dict(step, user, agent);
        assert_eq!(actual, expected, "storage_line_dict case '{}' mismatch", id);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 step_id_from_storage_line cases
// ─────────────────────────────────────────────────────────────────────────────

/// Extension trait so we can write `unwrap_err_or_else` on Result.
trait UnwrapErrOrElse<T, E> {
    fn unwrap_err_or_else<F: FnOnce(T) -> E>(self, f: F) -> E;
}
impl<T, E> UnwrapErrOrElse<T, E> for Result<T, E> {
    fn unwrap_err_or_else<F: FnOnce(T) -> E>(self, f: F) -> E {
        match self {
            Ok(v)  => f(v),
            Err(e) => e,
        }
    }
}

#[test]
fn membench_spec_step_id_parse_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["step_id_parse_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let input = case["input"].as_str().expect("input must be string");
        let expected_step = &case["expected_step_id"];
        let expected_error = &case["expected_error"];

        let result = step_id_from_storage_line(input);
        match (expected_step.is_null(), expected_error.is_null()) {
            (false, true) => {
                let expected_id = expected_step.as_i64().expect("expected_step_id must be i64");
                let actual = result.unwrap_or_else(|e| {
                    panic!("step_id_parse case '{}': expected Ok({}) but got Err({:?})", id, expected_id, e)
                });
                assert_eq!(actual, expected_id, "step_id_parse case '{}' id mismatch", id);
            }
            (true, false) => {
                let expected_err_str = expected_error.as_str().expect("expected_error must be string");
                let err = result.unwrap_err_or_else(|v| {
                    panic!("step_id_parse case '{}': expected Err({}) but got Ok({})", id, expected_err_str, v)
                });
                let expected_variant = match expected_err_str {
                    "missing_delimiter" => StorageLineParseError::MissingDelimiter,
                    "invalid_step_id"   => StorageLineParseError::InvalidStepId,
                    other => panic!("unknown expected_error '{}' in case '{}'", other, id),
                };
                assert_eq!(err, expected_variant, "step_id_parse case '{}' error variant mismatch", id);
            }
            _ => panic!("case '{}': exactly one of expected_step_id / expected_error must be non-null", id),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3–4 recall_query cases
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_recall_query_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["recall_query_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let question = case["question"].as_str().expect("question must be string");
        let time = case["time"].as_str().expect("time must be string");
        let expected = case["expected"].as_str().expect("expected must be string");
        let actual = recall_query(question, time);
        assert_eq!(actual, expected, "recall_query case '{}' mismatch", id);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 answer_prompt cases — byte-exact golden pins
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_answer_prompt_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["answer_prompt_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let perspective_str = case["perspective"].as_str().expect("perspective must be string");
        let memory = case["memory"].as_str().expect("memory must be string");
        let question = case["question"].as_str().expect("question must be string");
        let time = case["time"].as_str().expect("time must be string");
        let choices_val = case["choices"].as_object().expect("choices must be object");
        let expected = case["expected"].as_str().expect("expected must be string");

        let perspective = match perspective_str {
            "FirstAgent" => MemBenchPerspective::FirstAgent,
            "ThirdAgent" => MemBenchPerspective::ThirdAgent,
            other => panic!("unknown perspective '{}' in case '{}'", other, id),
        };
        let mut choices: HashMap<String, String> = HashMap::new();
        for (k, v) in choices_val {
            choices.insert(k.clone(), v.as_str().expect("choice must be string").to_string());
        }
        let actual = answer_prompt(&perspective, memory, question, time, &choices);
        assert_eq!(actual, expected, "answer_prompt case '{}' mismatch", id);
    }
}

// Golden pin: FirstAgent typo 'your'conversation' is in the rendered output.
#[test]
fn membench_spec_first_agent_prompt_contains_official_typo() {
    let mut choices = HashMap::new();
    for (k, v) in [("A", "Paris"), ("B", "London"), ("C", "Berlin"), ("D", "Tokyo")] {
        choices.insert(k.to_string(), v.to_string());
    }
    let prompt = answer_prompt(
        &MemBenchPerspective::FirstAgent,
        "The user went to Paris.",
        "Where did the user go?",
        "2024-01-15",
        &choices,
    );
    assert!(prompt.contains("your'conversation with the user"),
        "FirstAgent prompt must contain the official typo \"your'conversation with the user\"");
}

// Golden pin: ThirdAgent uses "the user's messages" third-person framing.
#[test]
fn membench_spec_third_agent_prompt_uses_third_person_framing() {
    let mut choices = HashMap::new();
    for (k, v) in [("A", "Swimming"), ("B", "Hiking"), ("C", "Cycling"), ("D", "Running")] {
        choices.insert(k.to_string(), v.to_string());
    }
    let prompt = answer_prompt(
        &MemBenchPerspective::ThirdAgent,
        "Alice mentioned she loves hiking.",
        "What does Alice love?",
        "2024-02-20",
        &choices,
    );
    assert!(prompt.contains("the user's messages"),
        "ThirdAgent prompt must contain \"the user's messages\"");
}

// Golden pin: both prompts end with 'Example: D' and no trailing newline.
#[test]
fn membench_spec_all_prompts_end_with_example_d_no_trailing_newline() {
    let mut choices = HashMap::new();
    for letter in ["A", "B", "C", "D"] {
        choices.insert(letter.to_string(), format!("Option {letter}"));
    }
    for perspective in [MemBenchPerspective::FirstAgent, MemBenchPerspective::ThirdAgent] {
        let prompt = answer_prompt(&perspective, "memory", "question?", "2024-01-01", &choices);
        assert!(prompt.ends_with("Example: D"),
            "{:?} prompt must end with 'Example: D'", perspective);
    }
}

// Golden pin: prompt has exactly 9 newlines (10 lines).
#[test]
fn membench_spec_prompt_has_exactly_nine_newlines() {
    let mut choices = HashMap::new();
    for letter in ["A", "B", "C", "D"] {
        choices.insert(letter.to_string(), format!("Option {letter}"));
    }
    let prompt = answer_prompt(
        &MemBenchPerspective::FirstAgent,
        "some memory",
        "some question?",
        "2024-01-01",
        &choices,
    );
    let newline_count = prompt.chars().filter(|&c| c == '\n').count();
    assert_eq!(newline_count, 9,
        "prompt must have exactly 9 '\\n' characters (10 lines), got {}", newline_count);
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 parse_answer_choice cases
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_parse_answer_choice_cases_match_vectors() {
    let v = load_protocol_vectors();
    let cases = v["parse_answer_choice_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let input = case["input"].as_str().expect("input must be string");
        let expected_val = &case["expected"];
        let expected: Option<&str> = if expected_val.is_null() {
            None
        } else {
            Some(expected_val.as_str().expect("expected must be string"))
        };
        let actual = parse_answer_choice(input);
        let actual_ref: Option<&str> = actual.as_deref();
        assert_eq!(actual_ref, expected,
            "parse_answer_choice case '{}' mismatch: input='{}' expected={:?} got={:?}",
            id, input, expected, actual_ref);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6 / §7 row 6 RESOLVED: membench_count_tokens counts with the vendored
// cl100k_base tokenizer (byte-exact tiktoken). The seam fails loud when the
// artifact is absent, so these tests skip on machines that have not run
// `make fetch-cl100k`.
// ─────────────────────────────────────────────────────────────────────────────

/// True when the vendored cl100k artifact is on disk.
fn cl100k_fixture_present() -> bool {
    std::path::Path::new(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../fixtures/cl100k/cl100k_base.tiktoken"
    ))
    .exists()
}

#[test]
fn membench_spec_membench_count_tokens_empty_string_is_zero() {
    if !cl100k_fixture_present() {
        eprintln!("skipping: cl100k fixture absent — run `make fetch-cl100k`");
        return;
    }
    assert_eq!(membench_count_tokens(""), 0);
}

#[test]
fn membench_spec_membench_count_tokens_cl100k_golden_pins() {
    if !cl100k_fixture_present() {
        eprintln!("skipping: cl100k fixture absent — run `make fetch-cl100k`");
        return;
    }
    // Values pinned by conformance/cl100k/vectors.json (tiktoken 0.14.0 oracle):
    // "Hello world" → [9906, 1917]; "The quick brown fox" → 4 tokens.
    assert_eq!(membench_count_tokens("Hello world"), 2);
    assert_eq!(membench_count_tokens("The quick brown fox"), 4);
}

// ─────────────────────────────────────────────────────────────────────────────
// step↔sid round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_step_sid_round_trip_via_storage_line_string() {
    // Simulates the runner's mapping: store with sid as step, then parse back.
    // Stored step id == corpus sid == target global sid (§2 comment in runner).
    let sid: i64 = 42;
    let line = storage_line_string(sid as usize, "hello world");
    let recovered = step_id_from_storage_line(&line).expect("round-trip must succeed");
    assert_eq!(recovered, sid);
}

#[test]
fn membench_spec_step_sid_round_trip_via_storage_line_dict() {
    let sid: i64 = 117;
    let line = storage_line_dict(sid as usize, "What's the plan?", "Let me explain.");
    let recovered = step_id_from_storage_line(&line).expect("round-trip must succeed");
    assert_eq!(recovered, sid);
}

#[test]
fn membench_spec_step_sid_zero_round_trips() {
    let line = storage_line_string(0, "First turn");
    let recovered = step_id_from_storage_line(&line).expect("round-trip must succeed");
    assert_eq!(recovered, 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Scorer: §4 get_recall conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_get_recall_cases_match_vectors() {
    let v = load_scorer_vectors();
    let cases = v["get_recall_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let expected_recall = case["expected_recall"].as_f64().expect("expected_recall must be f64");
        let target_ids: Vec<i64> = case["target_step_ids"]
            .as_array().expect("target_step_ids must be array")
            .iter()
            .map(|v| v.as_i64().expect("target id must be i64"))
            .collect();
        let retrieved: Option<Vec<i64>> = if case["retrieved_step_ids"].is_null() {
            None
        } else {
            Some(case["retrieved_step_ids"]
                .as_array().expect("retrieved_step_ids must be array")
                .iter()
                .map(|v| v.as_i64().expect("retrieved id must be i64"))
                .collect())
        };
        let actual = membench_spec_get_recall(retrieved.as_deref(), &target_ids);
        assert!(
            (actual - expected_recall).abs() < 1e-9,
            "get_recall case '{}': expected {:.9} got {:.9}", id, expected_recall, actual
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scorer: §3 answer_correct conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_answer_equality_cases_match_vectors() {
    let v = load_scorer_vectors();
    let cases = v["answer_equality_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let response = case["response"].as_str().expect("response must be string");
        let ground_truth = case["ground_truth"].as_str().expect("ground_truth must be string");
        let expected_correct = case["expected_correct"].as_bool().expect("expected_correct must be bool");
        let actual = membench_spec_answer_correct(response, ground_truth);
        assert_eq!(actual, expected_correct,
            "answer_equality case '{}': response='{}' ground_truth='{}'", id, response, ground_truth);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scorer: aggregation conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_aggregation_cases_match_vectors() {
    let v = load_scorer_vectors();
    let cases = v["aggregation_cases"].as_array().expect("array");
    for case in cases {
        let id = case["id"].as_str().unwrap_or("?");
        let expected_acc    = case["expected_overall_accuracy"].as_f64().expect("expected_overall_accuracy");
        let expected_recall = case["expected_overall_mean_recall"].as_f64().expect("expected_overall_mean_recall");
        let items_val = case["items"].as_array().expect("items must be array");
        let scores: Vec<MemBenchSpecItemScore> = items_val.iter().map(|item| {
            MemBenchSpecItemScore {
                category: item["category"].as_str().expect("category").to_string(),
                agent:    item["agent"].as_str().expect("agent").to_string(),
                correct:  item["correct"].as_bool().expect("correct"),
                recall:   item["recall"].as_f64().expect("recall"),
            }
        }).collect();

        let agg = membench_spec_aggregate(&scores);
        assert!(
            (agg.overall.accuracy - expected_acc).abs() < 1e-9,
            "aggregation case '{}': overall accuracy expected {:.9} got {:.9}",
            id, expected_acc, agg.overall.accuracy
        );
        assert!(
            (agg.overall.mean_recall - expected_recall).abs() < 1e-9,
            "aggregation case '{}': overall mean_recall expected {:.9} got {:.9}",
            id, expected_recall, agg.overall.mean_recall
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MemBenchSpecRunMode::as_str()
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_run_mode_as_str_standard() {
    assert_eq!(MemBenchSpecRunMode::Standard.as_str(), "standard");
}

#[test]
fn membench_spec_run_mode_as_str_step_cap() {
    assert_eq!(MemBenchSpecRunMode::StepCap.as_str(), "step_cap");
}

// ─────────────────────────────────────────────────────────────────────────────
// MemBenchSpecReport serde round-trip
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_report_serde_round_trip_standard_mode() {
    let report = make_minimal_report("standard", 0);
    let json = serde_json::to_string(&report).expect("serialize must succeed");
    let decoded: MemBenchSpecReport = serde_json::from_str(&json).expect("deserialize must succeed");
    assert_eq!(decoded.run_label, "test");
    assert_eq!(decoded.port, "rust");
    assert_eq!(decoded.agent, "FirstAgent");
    assert_eq!(decoded.seed, 42);
    assert_eq!(decoded.answered_count, 0);
    assert_eq!(decoded.item_count, 0);
    // capacity_samples uses a private bridge type — verify via JSON string.
    assert!(json.contains("\"capacity_samples\":null"),
        "capacity_samples must serialize as null; json={}", json);
    assert!(decoded.capacity_buckets.is_none());
}

#[test]
fn membench_spec_report_serde_run_mode_labels_preserved() {
    let standard = make_minimal_report("standard", 0);
    let json = serde_json::to_string(&standard).unwrap();
    assert!(json.contains("\"run_mode\":\"standard\""),
        "run_mode must be 'standard' in JSON; got: {}", json);

    let step_cap = make_minimal_report("step_cap", 0);
    let json2 = serde_json::to_string(&step_cap).unwrap();
    assert!(json2.contains("\"run_mode\":\"step_cap\""),
        "run_mode must be 'step_cap' in JSON; got: {}", json2);
}

#[test]
fn membench_spec_report_serde_answered_count_zero_round_trips() {
    let report = make_minimal_report("standard", 0);
    let json = serde_json::to_string(&report).unwrap();
    let decoded: MemBenchSpecReport = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.answered_count, 0);
}

#[test]
fn membench_spec_report_serde_answered_count_nonzero_round_trips() {
    let report = make_minimal_report("standard", 7);
    let json = serde_json::to_string(&report).unwrap();
    let decoded: MemBenchSpecReport = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.answered_count, 7);
}

#[test]
fn membench_spec_report_serde_by_category_preserved() {
    // Use JSON deserialization to avoid naming the private CapacitySampleWire type.
    let json_val = serde_json::json!({
        "run_label": "cat-test", "port": "rust", "agent": "FirstAgent",
        "seed": 1, "estate_mode": "per-item-spec", "encode_barrier": "drain",
        "shape": "disk", "run_mode": "standard",
        "overall": { "label": "overall", "count": 2, "accuracy": 0.5, "mean_recall": 0.7 },
        "by_category": [
            { "label": "simple", "count": 1, "accuracy": 1.0, "mean_recall": 1.0 },
            { "label": "noisy",  "count": 1, "accuracy": 0.0, "mean_recall": 0.4 }
        ],
        "by_perspective": [], "answered_count": 2,
        "write_efficiency": { "count": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0 },
        "read_efficiency":  { "count": 0, "mean": 0.0, "p50": 0.0, "p95": 0.0 },
        "capacity_samples": null, "capacity_buckets": null, "item_count": 2
    });
    let json = serde_json::to_string(&json_val).unwrap();
    let decoded: MemBenchSpecReport = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.by_category.len(), 2);
    assert_eq!(decoded.by_category[0].label, "simple");
    assert_eq!(decoded.by_category[1].label, "noisy");
    assert!((decoded.by_category[1].mean_recall - 0.4).abs() < 1e-9);
}

#[test]
fn membench_spec_report_serde_efficiency_stats_preserved() {
    let json_val = serde_json::json!({
        "run_label": "eff-test", "port": "rust", "agent": "FirstAgent",
        "seed": 0, "estate_mode": "per-item-spec", "encode_barrier": "drain",
        "shape": "disk", "run_mode": "standard",
        "overall": { "label": "overall", "count": 0, "accuracy": 0.0, "mean_recall": 0.0 },
        "by_category": [], "by_perspective": [], "answered_count": 0,
        "write_efficiency": { "count": 10, "mean": 0.333, "p50": 0.310, "p95": 0.550 },
        "read_efficiency":  { "count": 10, "mean": 0.111, "p50": 0.100, "p95": 0.220 },
        "capacity_samples": null, "capacity_buckets": null, "item_count": 10
    });
    let json = serde_json::to_string(&json_val).unwrap();
    let decoded: MemBenchSpecReport = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded.write_efficiency.count, 10);
    assert!((decoded.write_efficiency.mean  - 0.333).abs() < 1e-9);
    assert!((decoded.write_efficiency.p50   - 0.310).abs() < 1e-9);
    assert!((decoded.write_efficiency.p95   - 0.550).abs() < 1e-9);
    assert_eq!(decoded.read_efficiency.count, 10);
    assert!((decoded.read_efficiency.mean   - 0.111).abs() < 1e-9);
}

// ─────────────────────────────────────────────────────────────────────────────
// §5 efficiency stats shape (Rust scorer)
// ─────────────────────────────────────────────────────────────────────────────

#[test]
fn membench_spec_efficiency_stats_empty_is_all_zero() {
    let stats = membench_spec_efficiency_stats(&[]);
    assert_eq!(stats.count, 0);
    assert_eq!(stats.mean, 0.0);
    assert_eq!(stats.p50, 0.0);
    assert_eq!(stats.p95, 0.0);
}

#[test]
fn membench_spec_efficiency_stats_four_samples_shape() {
    // 4 samples: 0.1, 0.2, 0.3, 0.4
    // mean = 0.25; p50: ceil(0.5×4)=2 → sorted[1]=0.2; p95: ceil(0.95×4)=4 → sorted[3]=0.4
    let stats = membench_spec_efficiency_stats(&[0.1, 0.2, 0.3, 0.4]);
    assert_eq!(stats.count, 4);
    assert!((stats.mean - 0.25).abs() < 1e-9);
    assert!((stats.p50  - 0.2 ).abs() < 1e-9);
    assert!((stats.p95  - 0.4 ).abs() < 1e-9);
}

#[test]
fn membench_spec_efficiency_stats_single_sample_all_equal() {
    let stats = membench_spec_efficiency_stats(&[0.777]);
    assert_eq!(stats.count, 1);
    assert!((stats.mean - 0.777).abs() < 1e-9);
    assert!((stats.p50  - 0.777).abs() < 1e-9);
    assert!((stats.p95  - 0.777).abs() < 1e-9);
}
