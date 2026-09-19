//! lme_spec_conformance.rs — vector-driven conformance tests for the Rust lme-spec leg.
//!
//! Drives `lme_spec_grader` (and by extension the grader_vectors.json shared with
//! the Swift leg) to verify byte-identical prompt rendering, identical verdict
//! parsing, and identical §4 aggregation on both ports.
//!
//! Conformance contract (BENCHMARKER_OPTIMIZER_CONTRACT.md §4):
//!   Same inputs → identical outputs on both Rust and Swift legs.
//!   grader_vectors.json is the single source of expected values; neither port
//!   hardcodes expected values independently.
//!
//! Path resolution:
//!   CARGO_MANIFEST_DIR = benchmarks/rust/
//!   parent()           = benchmarks/
//!   join(...)          = benchmarks/conformance/lme-spec/grader_vectors.json
//!
//! Run with:
//!   CARGO_TARGET_DIR=target-lmespec cargo test --offline lme_spec

use mcp_benchmarker_rs::lme_spec_grader::{
    anscheck_prompt, lme_spec_aggregate, lme_spec_verdict, LmeSpecVerdictRecord, LmeSpecVerdict,
};
use serde_json::Value;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve `benchmarks/conformance/lme-spec/<filename>` from CARGO_MANIFEST_DIR.
///
/// CARGO_MANIFEST_DIR = `benchmarks/rust/`
/// one `parent()` → `benchmarks/`
fn lme_spec_conformance_path(filename: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join("lme-spec")
        .join(filename)
}

/// Load and parse a JSON file, panicking on failure so test output is clear.
fn load_json(path: &PathBuf) -> Value {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|e| panic!("Failed to parse {}: {e}", path.display()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Template conformance (grader_vectors.json: template_cases)
// ─────────────────────────────────────────────────────────────────────────────

/// Every template_case in grader_vectors.json must produce a byte-identical
/// prompt on the Rust leg as on the Swift leg.
///
/// The vector carries five cases — one per §2 template type:
///   standard (single-session-user), temporal-reasoning, knowledge-update,
///   single-session-preference, and abstention.
///
/// Spec §2: "{}` slots fill in order with (question, answer, hypothesis)."
#[test]
fn lme_spec_template_cases_all_match_vectors() {
    let path = lme_spec_conformance_path("grader_vectors.json");
    let json = load_json(&path);

    let cases = json["template_cases"]
        .as_array()
        .expect("grader_vectors.json must have 'template_cases' array");

    // The spec defines five distinct templates; the vector must cover all five.
    assert_eq!(cases.len(), 5, "expected exactly five template_cases in vector");

    for case_obj in cases {
        let id           = case_obj["id"].as_str().unwrap_or("(unknown)");
        let question_type = case_obj["question_type"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing question_type"));
        let question_id  = case_obj["question_id"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing question_id"));
        let question     = case_obj["question"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing question"));
        let answer       = case_obj["answer"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing answer"));
        let hypothesis   = case_obj["hypothesis"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing hypothesis"));
        let expected     = case_obj["expected_prompt"].as_str()
            .unwrap_or_else(|| panic!("template_case '{id}': missing expected_prompt"));

        let actual = anscheck_prompt(question_type, question_id, question, answer, hypothesis)
            .unwrap_or_else(|e| panic!("template_case '{id}': anscheck_prompt returned Err: {e}"));

        assert_eq!(
            actual, expected,
            "template_case '{id}': rendered prompt does not match vector\n\
             got:      {}\n\
             expected: {}",
            &actual[..actual.len().min(200)],
            &expected[..expected.len().min(200)]
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verdict parse conformance (grader_vectors.json: verdict_cases)
// ─────────────────────────────────────────────────────────────────────────────

/// Every verdict_case in grader_vectors.json must parse to the expected label
/// on the Rust leg.
///
/// Spec §3 verbatim: `label = 'yes' in eval_response.lower()` after `.strip()`.
#[test]
fn lme_spec_verdict_cases_all_match_vectors() {
    let path = lme_spec_conformance_path("grader_vectors.json");
    let json = load_json(&path);

    let cases = json["verdict_cases"]
        .as_array()
        .expect("grader_vectors.json must have 'verdict_cases' array");

    for case_obj in cases {
        let id             = case_obj["id"].as_str().unwrap_or("(unknown)");
        let eval_response  = case_obj["eval_response"].as_str()
            .unwrap_or_else(|| panic!("verdict_case '{id}': missing eval_response"));
        let expected_label = case_obj["expected_label"].as_bool()
            .unwrap_or_else(|| panic!("verdict_case '{id}': missing expected_label"));

        let verdict = lme_spec_verdict(eval_response, "test-model");
        assert_eq!(
            verdict.label, expected_label,
            "verdict_case '{id}': expected label {expected_label}, \
             got {} for eval_response '{eval_response}'",
            verdict.label
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 Aggregation conformance (grader_vectors.json: aggregation_cases)
// ─────────────────────────────────────────────────────────────────────────────

/// The aggregation_cases vector carries the eight-instance case from which
/// task-averaged and overall accuracies are hand-computable and provably differ
/// (unequal type counts). The Rust leg must match every expected value.
///
/// Eight-instance case:
///   ssu: [T,F]=0.5(2)  ssp: [T]=1.0(1)  ssa: [F]=0.0(1)
///   ms:  [T,F]=0.5(2)  tr:  [T]=1.0(1)  ku:  [T]=1.0(1)
///   task-avg  = (0.5+1.0+0.0+0.5+1.0+1.0)/6 = 4.0/6 = 0.6667
///   overall   = 5/8 = 0.6250   (differs from task-avg)
///   abstention = [T,F] = 1/2 = 0.5000
#[test]
fn lme_spec_aggregation_case_matches_vector() {
    let path = lme_spec_conformance_path("grader_vectors.json");
    let json = load_json(&path);

    let cases = json["aggregation_cases"]
        .as_array()
        .expect("grader_vectors.json must have 'aggregation_cases' array");
    assert!(!cases.is_empty(), "aggregation_cases must not be empty");

    let case_obj = &cases[0];
    let records_json = case_obj["records"]
        .as_array()
        .expect("aggregation_case must have 'records' array");
    let expected = &case_obj["expected"];

    // Decode verdict records from the vector JSON.
    let records: Vec<LmeSpecVerdictRecord> = records_json
        .iter()
        .map(|r| {
            let qid        = r["question_id"].as_str().expect("record: missing question_id");
            let base_type  = r["base_question_type"].as_str()
                .expect("record: missing base_question_type");
            let label      = r["label"].as_bool().expect("record: missing label");
            let model      = r["judge_model"].as_str().unwrap_or("test-model");
            LmeSpecVerdictRecord {
                question_id: qid.to_owned(),
                base_question_type: base_type.to_owned(),
                verdict: LmeSpecVerdict { judge_model: model.to_owned(), label },
            }
        })
        .collect();

    let result = lme_spec_aggregate(&records);

    // task_averaged_accuracy.
    let exp_task_avg = expected["task_averaged_accuracy"]
        .as_f64()
        .expect("expected: missing task_averaged_accuracy");
    assert!(
        (result.task_averaged_accuracy - exp_task_avg).abs() < 1e-9,
        "task_averaged_accuracy: expected {exp_task_avg}, got {}",
        result.task_averaged_accuracy
    );

    // overall_accuracy.
    let exp_overall = expected["overall_accuracy"]
        .as_f64()
        .expect("expected: missing overall_accuracy");
    assert!(
        (result.overall_accuracy - exp_overall).abs() < 1e-9,
        "overall_accuracy: expected {exp_overall}, got {}",
        result.overall_accuracy
    );

    // Key §4 property: task-averaged and overall DIFFER (unequal type counts).
    assert!(
        (result.task_averaged_accuracy - result.overall_accuracy).abs() > 1e-6,
        "task_averaged_accuracy ({}) and overall_accuracy ({}) must differ \
         for this vector (unequal type counts is the distinguishing property)",
        result.task_averaged_accuracy,
        result.overall_accuracy
    );

    // abstention_accuracy.
    let exp_abs_acc = expected["abstention_accuracy"]
        .as_f64()
        .expect("expected: missing abstention_accuracy");
    assert!(
        (result.abstention_accuracy - exp_abs_acc).abs() < 1e-9,
        "abstention_accuracy: expected {exp_abs_acc}, got {}",
        result.abstention_accuracy
    );

    // abstention_count.
    let exp_abs_count = expected["abstention_count"]
        .as_u64()
        .expect("expected: missing abstention_count") as usize;
    assert_eq!(
        result.abstention_count, exp_abs_count,
        "abstention_count: expected {exp_abs_count}, got {}",
        result.abstention_count
    );

    // per_type accuracy and count.
    let exp_per_type = expected["per_type"]
        .as_array()
        .expect("expected: missing per_type");
    let result_by_type: std::collections::HashMap<&str, (&f64, usize)> = result
        .per_type
        .iter()
        .map(|r| (r.question_type.as_str(), (&r.accuracy, r.count)))
        .collect();

    for pt_exp in exp_per_type {
        let type_name   = pt_exp["question_type"].as_str().expect("per_type: missing question_type");
        let exp_acc     = pt_exp["accuracy"].as_f64().expect("per_type: missing accuracy");
        let exp_count   = pt_exp["count"].as_u64().expect("per_type: missing count") as usize;

        let (actual_acc, actual_count) = result_by_type
            .get(type_name)
            .unwrap_or_else(|| panic!("per_type: type '{}' not found in result", type_name));

        assert!(
            (*actual_acc - exp_acc).abs() < 1e-9,
            "per_type '{}' accuracy: expected {exp_acc}, got {actual_acc}",
            type_name
        );
        assert_eq!(
            *actual_count, exp_count,
            "per_type '{}' count: expected {exp_count}, got {actual_count}",
            type_name
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline golden pins — one prompt per §2 template (byte-exact)
// ─────────────────────────────────────────────────────────────────────────────

/// Golden pin for the standard template (single-session-user).
///
/// Asserts byte equality including newlines and trailing space before \n\n.
/// Values are sourced from grader_vectors.json; this function verifies the
/// same literal that the vector does, independently confirming the Rust
/// constant strings match the spec.
#[test]
fn lme_spec_golden_pin_standard_template() {
    // Slot values match grader_vectors.json template_cases[0].
    let actual = anscheck_prompt(
        "single-session-user",
        "q_ssu_001",
        "What color is the sky?",
        "blue",
        "The sky is blue.",
    ).expect("standard template must not error");

    // Spec §2: trailing space before first \n\n is verbatim ("answer no. \n\n").
    assert!(
        actual.contains("answer no. \n\nQuestion:"),
        "standard template must have trailing space before \\n\\n"
    );
    assert!(actual.contains("Correct Answer: blue"));
    assert!(actual.contains("Model Response: The sky is blue."));
    assert!(actual.ends_with("Answer yes or no only."),
            "standard template must end with the correct closing sentence");
}

/// Golden pin for the temporal-reasoning template.
///
/// Off-by-one grace clause and trailing space before \n\n are verbatim from §2.
#[test]
fn lme_spec_golden_pin_temporal_template() {
    let actual = anscheck_prompt(
        "temporal-reasoning",
        "q_tr_001",
        "How many days have passed?",
        "18",
        "About 19 days.",
    ).expect("temporal template must not error");

    // Spec §2: trailing space before \n\n: "is still correct. \n\n".
    assert!(
        actual.contains("is still correct. \n\nQuestion:"),
        "temporal template must have trailing space before \\n\\n"
    );
    assert!(actual.contains("off-by-one errors for the number of days"),
            "temporal template must contain off-by-one clause");
}

/// Golden pin for the knowledge-update template (no trailing space before \n\n).
#[test]
fn lme_spec_golden_pin_knowledge_update_template() {
    let actual = anscheck_prompt(
        "knowledge-update",
        "q_ku_001",
        "What is my current job?",
        "nurse",
        "You work as a nurse now.",
    ).expect("knowledge-update template must not error");

    // Spec §2: no trailing space: "required answer.\n\n".
    assert!(
        actual.contains("required answer.\n\nQuestion:"),
        "knowledge-update template must NOT have trailing space before \\n\\n"
    );
    assert!(!actual.contains("required answer. \n\n"),
            "knowledge-update template must NOT have trailing space before \\n\\n");
}

/// Golden pin for the single-session-preference template (Rubric label, no trailing space).
#[test]
fn lme_spec_golden_pin_preference_template() {
    let actual = anscheck_prompt(
        "single-session-preference",
        "q_ssp_001",
        "What food should I order?",
        "User prefers spicy food",
        "I would suggest something spicy.",
    ).expect("preference template must not error");

    // Spec §2: second slot labeled "Rubric:" not "Correct Answer:".
    assert!(actual.contains("Rubric: User prefers spicy food"),
            "preference template must use Rubric label");
    assert!(!actual.contains("Correct Answer"),
            "preference template must NOT use Correct Answer label");
}

/// Golden pin for the abstention template (_abs in question_id, Explanation label).
#[test]
fn lme_spec_golden_pin_abstention_template() {
    // Spec §2: abstention selection is keyed on question_id, not question_type.
    // question_type here is "single-session-user" but the _abs suffix in the ID
    // forces the abstention template.
    let actual = anscheck_prompt(
        "single-session-user",
        "q_ssu_001_abs",
        "What did I do last summer?",
        "The context contains no information about last summer.",
        "I cannot find information about your last summer.",
    ).expect("abstention template must not error");

    assert!(actual.starts_with("I will give you an unanswerable question"),
            "abstention template must start with unanswerable-question preamble");
    assert!(actual.contains("Explanation: The context contains no information about last summer."),
            "abstention template must use Explanation label for slot 2");
    assert!(actual.ends_with("Does the model correctly identify the question as unanswerable? Answer yes or no only."),
            "abstention template must end with the correct unanswerable closing question");
}

// ─────────────────────────────────────────────────────────────────────────────
// _abs selector golden pin — non-abstention type overridden by question_id
// ─────────────────────────────────────────────────────────────────────────────

/// _abs in question_id overrides question_type routing (spec §2 first branch).
///
/// This is the critical selector test: even with question_type="multi-session"
/// (a non-abstention type), the presence of '_abs' in question_id routes to
/// the abstention template.
#[test]
fn lme_spec_abs_selector_overrides_question_type() {
    let actual = anscheck_prompt(
        "multi-session",   // non-abstention type
        "q_ms_001_abs",   // _abs in question_id → abstention branch
        "Q", "A", "H",
    ).expect("abs selector must not error");

    assert!(
        actual.starts_with("I will give you an unanswerable question"),
        "abs selector: _abs in question_id must route to abstention template \
         regardless of question_type"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Unknown type error
// ─────────────────────────────────────────────────────────────────────────────

/// anscheck_prompt returns Err for an unknown, non-abstention question_type.
/// Mirrors Python's NotImplementedError (spec §2 last line).
#[test]
fn lme_spec_unknown_type_returns_error() {
    let result = anscheck_prompt("not-a-real-type", "q1", "Q", "A", "H");
    assert!(result.is_err(), "unknown question_type must return Err");
    let msg = result.unwrap_err();
    assert!(
        msg.contains("not-a-real-type"),
        "error message must name the unknown type, got: {msg}"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Verdict edge cases
// ─────────────────────────────────────────────────────────────────────────────

/// Verdict parsing: empty string → no "yes" → false.
#[test]
fn lme_spec_verdict_empty_is_false() {
    assert!(!lme_spec_verdict("", "m").label);
}

/// Verdict parsing: "No" → false (correct behaviour; "no" does not contain "yes").
#[test]
fn lme_spec_verdict_no_upper_is_false() {
    assert!(!lme_spec_verdict("No", "m").label);
}

/// Verdict parsing: "noyes" contains "yes" → true (substring rule per §3).
#[test]
fn lme_spec_verdict_noyes_is_true() {
    // §3: `'yes' in eval_response.lower()` — substring, not whole-word match.
    assert!(lme_spec_verdict("noyes", "m").label,
            "§3 uses substring containment: 'noyes'.lower() contains 'yes'");
}

/// Verdict parsing: judge model is carried through to the verdict.
#[test]
fn lme_spec_verdict_judge_model_carried_through() {
    let v = lme_spec_verdict("yes", "gpt-4o-2024-08-06");
    assert_eq!(v.judge_model, "gpt-4o-2024-08-06");
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 Aggregation — additional inline cases
// ─────────────────────────────────────────────────────────────────────────────

/// Empty record set produces zero accuracies with six per-type entries.
#[test]
fn lme_spec_aggregate_empty_is_zero() {
    let result = lme_spec_aggregate(&[]);
    assert_eq!(result.task_averaged_accuracy, 0.0);
    assert_eq!(result.overall_accuracy, 0.0);
    assert_eq!(result.abstention_accuracy, 0.0);
    assert_eq!(result.abstention_count, 0);
    assert_eq!(result.per_type.len(), 6, "must always have six per-type entries");
    assert!(result.per_type.iter().all(|r| r.accuracy == 0.0 && r.count == 0));
}

/// per_type order matches FIXED_TYPE_LIST (spec §4 fixed order).
#[test]
fn lme_spec_aggregate_per_type_order_matches_fixed_list() {
    use mcp_benchmarker_rs::lme_spec_grader::FIXED_TYPE_LIST;
    let result = lme_spec_aggregate(&[]);
    let actual_order: Vec<&str> = result.per_type.iter()
        .map(|r| r.question_type.as_str())
        .collect();
    assert_eq!(actual_order, FIXED_TYPE_LIST.to_vec());
}

/// Abstention instances aggregate under their base type for per-type accuracy.
#[test]
fn lme_spec_abstention_aggregates_under_base_type() {
    let records = vec![
        LmeSpecVerdictRecord {
            question_id: "q1_abs".to_owned(),
            base_question_type: "multi-session".to_owned(),
            verdict: LmeSpecVerdict { judge_model: "m".to_owned(), label: true },
        }
    ];
    let result = lme_spec_aggregate(&records);
    let ms = result.per_type.iter()
        .find(|r| r.question_type == "multi-session")
        .expect("multi-session must be in per_type");
    // The abstention instance contributes to the multi-session bucket.
    assert_eq!(ms.count, 1);
    assert_eq!(ms.accuracy, 1.0);
    // It also contributes to abstention accuracy.
    assert_eq!(result.abstention_accuracy, 1.0);
    assert_eq!(result.abstention_count, 1);
}
