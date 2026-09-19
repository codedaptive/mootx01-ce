//! lme_spec_grader.rs — Official LongMemEval "anscheck" QA grader.
//!
//! Rust twin of `LMESpecGrader.swift`. Implements the QA accuracy evaluation
//! protocol verbatim from LONGMEMEVAL_OFFICIAL_PROTOCOL.md §2–§4, extracted from
//! xiaowu0162/LongMemEval evaluate_qa.py and print_qa_metrics.py.
//!
//! Role: pure logic; no subprocess, no I/O, no system-clock calls.
//!
//! Seam discipline: [`anscheck_prompt`] produces the filled prompt string.
//! [`lme_spec_judge_request`] wraps it with the §3 call parameters.
//! The subprocess/HTTP seam lives in the runner; this module owns prompt
//! construction, verdict parsing, and aggregation math only.

// ─────────────────────────────────────────────────────────────────────────────
// Verbatim prompt templates (§2)
//
// Five templates stored as `const` string slices. The Rust `\n` escape in a
// raw string constant is a real newline character (U+000A), matching the spec's
// "The \n sequences in the spec doc are real newlines" note.
//
// Trailing-space differences before the first \n\n are verbatim from the spec:
// templates 1 (standard) and 2 (temporal) have a trailing space; 3–5 do not.
// ─────────────────────────────────────────────────────────────────────────────

/// §2 standard template: single-session-user / single-session-assistant / multi-session.
/// Trailing space before \n\n is verbatim from the spec.
const TEMPLATE_STANDARD: &str = "\
I will give you a question, a correct answer, and a response from a model. \
Please answer yes if the response contains the correct answer. Otherwise, answer no. \
If the response is equivalent to the correct answer or contains all the intermediate \
steps to get the correct answer, you should also answer yes. \
If the response only contains a subset of the information required by the answer, answer no. \
\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n\
Is the model response correct? Answer yes or no only.";

/// §2 temporal-reasoning template.
/// Off-by-one grace clause appended; trailing space before \n\n verbatim from spec.
const TEMPLATE_TEMPORAL: &str = "\
I will give you a question, a correct answer, and a response from a model. \
Please answer yes if the response contains the correct answer. Otherwise, answer no. \
If the response is equivalent to the correct answer or contains all the intermediate \
steps to get the correct answer, you should also answer yes. \
If the response only contains a subset of the information required by the answer, answer no. \
In addition, do not penalize off-by-one errors for the number of days. \
If the question asks for the number of days/weeks/months, etc., and the model makes \
off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's \
response is still correct. \
\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n\
Is the model response correct? Answer yes or no only.";

/// §2 knowledge-update template.
/// No trailing space before the first \n\n (verbatim from spec).
const TEMPLATE_KNOWLEDGE_UPDATE: &str = "\
I will give you a question, a correct answer, and a response from a model. \
Please answer yes if the response contains the correct answer. Otherwise, answer no. \
If the response contains some previous information along with an updated answer, \
the response should be considered as correct as long as the updated answer is the required answer.\
\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n\
Is the model response correct? Answer yes or no only.";

/// §2 single-session-preference template.
/// Uses "Rubric" label for slot 2. No trailing space before \n\n (verbatim).
const TEMPLATE_PREFERENCE: &str = "\
I will give you a question, a rubric for desired personalized response, \
and a response from a model. \
Please answer yes if the response satisfies the desired response. Otherwise, answer no. \
The model does not need to reflect all the points in the rubric. \
The response is correct as long as it recalls and utilizes the user's personal information correctly.\
\n\nQuestion: {}\n\nRubric: {}\n\nModel Response: {}\n\n\
Is the model response correct? Answer yes or no only.";

/// §2 abstention template (selected when '_abs' in question_id).
/// Uses "Explanation" label and a different closing question. No trailing space.
const TEMPLATE_ABSTENTION: &str = "\
I will give you an unanswerable question, an explanation, and a response from a model. \
Please answer yes if the model correctly identifies the question as unanswerable. \
The model could say that the information is incomplete, \
or some other information is given but the asked information is not.\
\n\nQuestion: {}\n\nExplanation: {}\n\nModel Response: {}\n\n\
Does the model correctly identify the question as unanswerable? Answer yes or no only.";

/// Fixed six-type list per §4. Order is fixed; matches print_qa_metrics.py.
pub const FIXED_TYPE_LIST: [&str; 6] = [
    "single-session-user",
    "single-session-preference",
    "single-session-assistant",
    "multi-session",
    "temporal-reasoning",
    "knowledge-update",
];

// ─────────────────────────────────────────────────────────────────────────────
// Template slot filling
// ─────────────────────────────────────────────────────────────────────────────

/// Replaces the three `{}` placeholders in a template with values, in order.
///
/// Mirrors Python `prompt_template.format(question, answer, hypothesis)`:
/// first `{}` → `question`, second → `answer` (gold/rubric/explanation),
/// third → `hypothesis`.
fn fill_anscheck_slots(template: &str, question: &str, answer: &str, hypothesis: &str) -> String {
    // Replace occurrences one at a time to avoid confusing replacen counts with
    // templates that might have identical slot content.
    let after_q = template.replacen("{}", question, 1);
    let after_a = after_q.replacen("{}", answer, 1);
    after_a.replacen("{}", hypothesis, 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// Prompt construction (§2)
// ─────────────────────────────────────────────────────────────────────────────

/// Constructs the byte-exact "anscheck" judge prompt for one QA instance.
///
/// Template selection (§2):
/// 1. If `question_id` contains `'_abs'` → abstention template (regardless of type).
/// 2. Otherwise route by `question_type`:
///    - `"single-session-user"` | `"single-session-assistant"` | `"multi-session"` → standard
///    - `"temporal-reasoning"` → temporal template
///    - `"knowledge-update"` → knowledge-update template
///    - `"single-session-preference"` → preference template
///    - Anything else → `Err(String)` mirroring Python's `NotImplementedError` (§2).
///
/// Slot fill order (§2): question → answer → hypothesis.
///
/// # Errors
/// Returns `Err` when `question_type` is not in the six-type list and `question_id`
/// does not contain `'_abs'`.
pub fn anscheck_prompt(
    question_type: &str,
    question_id: &str,
    question: &str,
    answer: &str,
    hypothesis: &str,
) -> Result<String, String> {
    // §2: abstention branch keyed on question_id, not question_type.
    if question_id.contains("_abs") {
        return Ok(fill_anscheck_slots(
            TEMPLATE_ABSTENTION,
            question,
            answer,
            hypothesis,
        ));
    }

    // §2: non-abstention routing by question_type.
    let template = match question_type {
        "single-session-user" | "single-session-assistant" | "multi-session" => TEMPLATE_STANDARD,
        "temporal-reasoning" => TEMPLATE_TEMPORAL,
        "knowledge-update" => TEMPLATE_KNOWLEDGE_UPDATE,
        "single-session-preference" => TEMPLATE_PREFERENCE,
        other => {
            // §2: unknown type mirrors Python NotImplementedError.
            return Err(format!(
                "LMESpecGrader: unknown non-abstention question_type '{}' — \
                expected one of: single-session-user, single-session-preference, \
                single-session-assistant, multi-session, temporal-reasoning, knowledge-update",
                other
            ));
        }
    };

    Ok(fill_anscheck_slots(template, question, answer, hypothesis))
}

// ─────────────────────────────────────────────────────────────────────────────
// Judge request descriptor (§3)
// ─────────────────────────────────────────────────────────────────────────────

/// The parameters for one anscheck judge call, per §3.
///
/// The external judge seam (subprocess or HTTP) reads this struct to dispatch
/// the request. This module only defines the descriptor; the runner owns dispatch.
///
/// §3 parameters verbatim:
///   `{'model': metric_model, 'messages': [{"role": "user", "content": prompt}],`
///   ` 'n': 1, 'temperature': 0, 'max_tokens': 10}`
#[derive(Debug, Clone)]
pub struct LmeSpecJudgeRequest {
    /// The judge model identifier (e.g. `"gpt-4o-2024-08-06"`).
    pub model: String,
    /// The filled anscheck prompt, content of the single user message.
    pub user_message: String,
    /// §3 literal: n = 1.
    pub n: u32,
    /// §3 literal: temperature = 0.
    pub temperature: f64,
    /// §3 literal: max_tokens = 10.
    pub max_tokens: u32,
}

/// Constructs a §3-compliant judge request descriptor.
///
/// Wraps the filled anscheck prompt with the fixed §3 parameters.
/// Callers obtain the prompt from [`anscheck_prompt`] and pass it here.
pub fn lme_spec_judge_request(model: &str, prompt: &str) -> LmeSpecJudgeRequest {
    LmeSpecJudgeRequest {
        model: model.to_owned(),
        user_message: prompt.to_owned(),
        n: 1,
        temperature: 0.0,
        max_tokens: 10,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verdict parsing (§3)
// ─────────────────────────────────────────────────────────────────────────────

/// The outcome of one anscheck judge call, carrying model identity and label.
///
/// Model identity is stored so the aggregator can surface which judge model was
/// used and flag mixed-model runs.
#[derive(Debug, Clone)]
pub struct LmeSpecVerdict {
    /// The judge model that produced this verdict.
    pub judge_model: String,
    /// True when the judge replied "yes"; false for "no".
    pub label: bool,
}

/// Parses the judge model's text reply into a verdict label per §3.
///
/// §3 verdict algorithm verbatim:
///   `label = 'yes' in eval_response.lower()`
/// after `.strip()`. Strip leading/trailing whitespace, lowercase, then check
/// substring membership of "yes". A judge that says "YES it is" → true;
/// "no" → false; " yes" (leading space) → true.
pub fn lme_spec_verdict(eval_response: &str, judge_model: &str) -> LmeSpecVerdict {
    let stripped = eval_response.trim();
    let lower = stripped.to_lowercase();
    LmeSpecVerdict {
        judge_model: judge_model.to_owned(),
        label: lower.contains("yes"),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregation types (§4)
// ─────────────────────────────────────────────────────────────────────────────

/// Per-question-type accuracy result for §4 aggregation.
#[derive(Debug, Clone)]
pub struct LmeSpecPerTypeResult {
    /// One of the six fixed question types.
    pub question_type: String,
    /// Mean label over instances of this type, rounded to 4 decimal places.
    /// 0.0 when count is 0.
    pub accuracy: f64,
    /// Number of instances of this type in the evaluated set.
    pub count: usize,
}

/// Complete §4 aggregate result for one evaluation run.
#[derive(Debug, Clone)]
pub struct LmeSpecAggregateResult {
    /// Per-type accuracy in fixed order (FIXED_TYPE_LIST). Always six entries.
    pub per_type: Vec<LmeSpecPerTypeResult>,
    /// §4 task-averaged accuracy: unweighted mean of six raw per-type accuracies, rounded 4dp.
    pub task_averaged_accuracy: f64,
    /// §4 overall accuracy: mean label over all instances, rounded 4dp.
    pub overall_accuracy: f64,
    /// §4 abstention accuracy: mean label over instances with '_abs' in question_id, rounded 4dp.
    pub abstention_accuracy: f64,
    /// Number of abstention instances.
    pub abstention_count: usize,
    /// Unique judge model identifiers seen across all verdicts (sorted for determinism).
    pub judge_models: Vec<String>,
}

/// One input record for the aggregator.
#[derive(Debug, Clone)]
pub struct LmeSpecVerdictRecord {
    /// The dataset's question_id; determines abstention membership ('_abs' in id).
    pub question_id: String,
    /// Base question type (question_type without '_abs' suffix, e.g. "multi-session").
    /// Abstention instances aggregate under this base type for per-type accuracy.
    pub base_question_type: String,
    /// The verdict produced by [`lme_spec_verdict`] for this instance.
    pub verdict: LmeSpecVerdict,
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregation engine (§4)
// ─────────────────────────────────────────────────────────────────────────────

/// Rounds an f64 to 4 decimal places (round-half-to-even, matching Python's round()).
///
/// For accuracy values produced here (rationals with denominators ≤ 500) this is
/// identical to simple round-half-up; both are provided for conformance with
/// print_qa_metrics.py.
fn round4(x: f64) -> f64 {
    (x * 10000.0).round() / 10000.0
}

/// Computes §4 aggregate QA accuracy metrics over a set of verdict records.
///
/// Per-type accuracy: mean of binary labels for each of the six fixed types, rounded 4dp.
/// Types with zero instances contribute accuracy 0.0, count 0.
///
/// Task-averaged accuracy (§4): unweighted mean of the six raw per-type accuracies
/// (before per-type rounding), rounded 4dp. Matches print_qa_metrics.py.
///
/// Overall accuracy (§4): mean label over all instances, rounded 4dp.
///
/// Abstention accuracy (§4): mean label over instances with '_abs' in question_id, rounded 4dp.
///
/// Judge model identity: unique judge model identifiers across all verdicts, sorted.
pub fn lme_spec_aggregate(records: &[LmeSpecVerdictRecord]) -> LmeSpecAggregateResult {
    // Bucket labels by base question type. Pre-populate with the fixed six types.
    let mut type_labels: std::collections::HashMap<&str, Vec<bool>> =
        FIXED_TYPE_LIST.iter().map(|&t| (t, Vec::new())).collect();

    let mut all_labels: Vec<bool> = Vec::new();
    let mut abstention_labels: Vec<bool> = Vec::new();
    let mut judge_model_set: std::collections::BTreeSet<String> = Default::default();

    for record in records {
        let label = record.verdict.label;
        all_labels.push(label);
        judge_model_set.insert(record.verdict.judge_model.clone());

        // §4: abstention membership keyed on question_id.
        if record.question_id.contains("_abs") {
            abstention_labels.push(label);
        }

        // §4: aggregate under base type. Types outside the fixed six are ignored.
        if let Some(bucket) = type_labels.get_mut(record.base_question_type.as_str()) {
            bucket.push(label);
        }
    }

    // Compute raw per-type accuracies for task-averaged mean (before rounding).
    let mut raw_type_accuracies: Vec<f64> = Vec::with_capacity(6);
    let per_type: Vec<LmeSpecPerTypeResult> = FIXED_TYPE_LIST
        .iter()
        .map(|&type_name| {
            let labels = type_labels.get(type_name).map_or(&[] as &[bool], |v| v.as_slice());
            let raw_accuracy = if labels.is_empty() {
                0.0
            } else {
                labels.iter().filter(|&&b| b).count() as f64 / labels.len() as f64
            };
            raw_type_accuracies.push(raw_accuracy);
            LmeSpecPerTypeResult {
                question_type: type_name.to_owned(),
                accuracy: round4(raw_accuracy),
                count: labels.len(),
            }
        })
        .collect();

    // §4 task-averaged: mean of the six raw per-type accuracies, then round.
    let task_averaged = if raw_type_accuracies.is_empty() {
        0.0
    } else {
        round4(raw_type_accuracies.iter().sum::<f64>() / raw_type_accuracies.len() as f64)
    };

    // §4 overall: mean over all instances.
    let overall = if all_labels.is_empty() {
        0.0
    } else {
        round4(all_labels.iter().filter(|&&b| b).count() as f64 / all_labels.len() as f64)
    };

    // §4 abstention: mean over _abs instances.
    let abstention_accuracy = if abstention_labels.is_empty() {
        0.0
    } else {
        round4(
            abstention_labels.iter().filter(|&&b| b).count() as f64
                / abstention_labels.len() as f64,
        )
    };

    LmeSpecAggregateResult {
        per_type,
        task_averaged_accuracy: task_averaged,
        overall_accuracy: overall,
        abstention_accuracy,
        abstention_count: abstention_labels.len(),
        judge_models: judge_model_set.into_iter().collect(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Template routing ──────────────────────────────────────────────────────

    #[test]
    fn abstention_branch_keyed_on_question_id_not_type() {
        // Even with a non-abstention type, '_abs' in question_id routes to
        // the abstention template (§2 first branch).
        let prompt = anscheck_prompt(
            "single-session-user",
            "q1_abs",
            "Q", "A", "H",
        ).expect("should not error");
        assert!(
            prompt.starts_with("I will give you an unanswerable question"),
            "expected abstention template, got: {:.80}", prompt
        );
    }

    #[test]
    fn standard_template_single_session_user() {
        let prompt = anscheck_prompt("single-session-user", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(prompt.contains("Correct Answer: A"), "expected standard template");
        assert!(!prompt.contains("Rubric"), "should not be preference template");
        assert!(!prompt.contains("unanswerable"), "should not be abstention template");
    }

    #[test]
    fn standard_template_single_session_assistant() {
        let prompt = anscheck_prompt("single-session-assistant", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(prompt.contains("Correct Answer: A"));
    }

    #[test]
    fn standard_template_multi_session() {
        let prompt = anscheck_prompt("multi-session", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(prompt.contains("Correct Answer: A"));
    }

    #[test]
    fn temporal_template_contains_off_by_one_clause() {
        let prompt = anscheck_prompt("temporal-reasoning", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(
            prompt.contains("off-by-one errors for the number of days"),
            "expected temporal template"
        );
    }

    #[test]
    fn knowledge_update_template() {
        let prompt = anscheck_prompt("knowledge-update", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(
            prompt.contains("updated answer is the required answer"),
            "expected knowledge-update template"
        );
    }

    #[test]
    fn preference_template_uses_rubric_label() {
        let prompt = anscheck_prompt("single-session-preference", "q1", "Q", "A", "H")
            .expect("should not error");
        assert!(prompt.contains("Rubric: A"), "expected Rubric label with answer in slot 2");
    }

    #[test]
    fn unknown_type_returns_error() {
        let result = anscheck_prompt("made-up-type", "q1", "Q", "A", "H");
        assert!(result.is_err(), "expected Err for unknown type");
        let msg = result.unwrap_err();
        assert!(msg.contains("made-up-type"), "error should name the bad type");
    }

    // ── Slot fill order ───────────────────────────────────────────────────────

    #[test]
    fn slots_fill_in_order_question_answer_hypothesis() {
        let prompt = anscheck_prompt(
            "single-session-user",
            "q1",
            "What color?",
            "blue",
            "The sky is blue.",
        ).expect("should not error");
        // Verify order: Question: <q>, Correct Answer: <a>, Model Response: <h>
        let q_pos = prompt.find("What color?").expect("question missing");
        let a_pos = prompt.find("blue").expect("answer missing");
        let h_pos = prompt.find("The sky is blue.").expect("hypothesis missing");
        // 'blue' appears in both answer and hypothesis but hypothesis has full sentence
        // so find("blue") gives the answer occurrence. Verify ordering.
        assert!(q_pos < a_pos, "question must precede answer");
        // h_pos is at "The sky is blue." which starts after the answer 'blue'
        assert!(a_pos < h_pos, "answer must precede hypothesis");
    }

    // ── Verdict parsing ───────────────────────────────────────────────────────

    #[test]
    fn verdict_yes_with_period() {
        // "Yes." stripped → "Yes." lower → "yes." → contains "yes" → true
        assert!(lme_spec_verdict("Yes.", "m").label);
    }

    #[test]
    fn verdict_no() {
        assert!(!lme_spec_verdict("no", "m").label);
    }

    #[test]
    fn verdict_yes_it_is() {
        // "YES it is" → lower "yes it is" → contains "yes" → true
        assert!(lme_spec_verdict("YES it is", "m").label);
    }

    #[test]
    fn verdict_leading_space_yes() {
        // " yes" → strip "yes" → lower "yes" → true
        assert!(lme_spec_verdict(" yes", "m").label);
    }

    #[test]
    fn verdict_carries_judge_model() {
        let v = lme_spec_verdict("yes", "gpt-4o-2024-08-06");
        assert_eq!(v.judge_model, "gpt-4o-2024-08-06");
    }

    // ── Judge request descriptor ──────────────────────────────────────────────

    #[test]
    fn judge_request_has_correct_fixed_params() {
        let req = lme_spec_judge_request("gpt-4o-2024-08-06", "some prompt");
        assert_eq!(req.n, 1);
        assert_eq!(req.temperature, 0.0);
        assert_eq!(req.max_tokens, 10);
        assert_eq!(req.user_message, "some prompt");
        assert_eq!(req.model, "gpt-4o-2024-08-06");
    }

    // ── Aggregation ───────────────────────────────────────────────────────────

    fn make_record(question_id: &str, base_type: &str, label: bool) -> LmeSpecVerdictRecord {
        LmeSpecVerdictRecord {
            question_id: question_id.to_owned(),
            base_question_type: base_type.to_owned(),
            verdict: LmeSpecVerdict {
                judge_model: "m".to_owned(),
                label,
            },
        }
    }

    #[test]
    fn aggregation_eight_instance_case() {
        // Hand-computed case from grader_vectors.json:
        // q1 ssu true, q2 ssu false → ssu: 1/2 = 0.5
        // q3_abs ssp true → ssp: 1/1 = 1.0; abs: [true]
        // q4_abs ssa false → ssa: 0/1 = 0.0; abs: [true, false]
        // q5 ms true, q6 ms false → ms: 1/2 = 0.5
        // q7 tr true → tr: 1/1 = 1.0
        // q8 ku true → ku: 1/1 = 1.0
        // task-avg = (0.5+1.0+0.0+0.5+1.0+1.0)/6 = 4.0/6 = 0.6667
        // overall = 5/8 = 0.6250
        // abstention = 1/2 = 0.5000
        let records = vec![
            make_record("q1",    "single-session-user",        true),
            make_record("q2",    "single-session-user",        false),
            make_record("q3_abs","single-session-preference",  true),
            make_record("q4_abs","single-session-assistant",   false),
            make_record("q5",    "multi-session",              true),
            make_record("q6",    "multi-session",              false),
            make_record("q7",    "temporal-reasoning",         true),
            make_record("q8",    "knowledge-update",           true),
        ];
        let result = lme_spec_aggregate(&records);

        // per-type
        let type_map: std::collections::HashMap<_, _> = result.per_type.iter()
            .map(|r| (r.question_type.as_str(), (r.accuracy, r.count)))
            .collect();
        assert_eq!(type_map["single-session-user"],        (0.5, 2));
        assert_eq!(type_map["single-session-preference"],  (1.0, 1));
        assert_eq!(type_map["single-session-assistant"],   (0.0, 1));
        assert_eq!(type_map["multi-session"],              (0.5, 2));
        assert_eq!(type_map["temporal-reasoning"],         (1.0, 1));
        assert_eq!(type_map["knowledge-update"],           (1.0, 1));

        assert_eq!(result.task_averaged_accuracy, 0.6667);
        assert_eq!(result.overall_accuracy,       0.625);
        assert_eq!(result.abstention_accuracy,    0.5);
        assert_eq!(result.abstention_count,       2);
        assert_eq!(result.judge_models,           vec!["m".to_owned()]);
    }

    #[test]
    fn empty_records_produce_zero_accuracies() {
        let result = lme_spec_aggregate(&[]);
        assert_eq!(result.task_averaged_accuracy, 0.0);
        assert_eq!(result.overall_accuracy, 0.0);
        assert_eq!(result.abstention_accuracy, 0.0);
        assert_eq!(result.abstention_count, 0);
        assert_eq!(result.per_type.len(), 6);
        assert!(result.per_type.iter().all(|r| r.accuracy == 0.0 && r.count == 0));
    }

    // ── Template trailing-space fidelity ──────────────────────────────────────

    #[test]
    fn standard_template_has_trailing_space_before_double_newline() {
        // §2 spec: "answer no. \n\nQuestion:" — space before the \n\n.
        assert!(
            TEMPLATE_STANDARD.contains("answer no. \n\nQuestion:"),
            "standard template must have trailing space before \\n\\n"
        );
    }

    #[test]
    fn temporal_template_has_trailing_space_before_double_newline() {
        // §2 spec: "is still correct. \n\nQuestion:" — space before the \n\n.
        assert!(
            TEMPLATE_TEMPORAL.contains("is still correct. \n\nQuestion:"),
            "temporal template must have trailing space before \\n\\n"
        );
    }

    #[test]
    fn knowledge_update_no_trailing_space() {
        // §2 spec: "required answer.\n\nQuestion:" — NO space before \n\n.
        assert!(
            TEMPLATE_KNOWLEDGE_UPDATE.contains("required answer.\n\nQuestion:"),
            "knowledge-update template must NOT have trailing space before \\n\\n"
        );
    }

    #[test]
    fn preference_no_trailing_space() {
        assert!(
            TEMPLATE_PREFERENCE.contains("correctly.\n\nQuestion:"),
            "preference template must NOT have trailing space before \\n\\n"
        );
    }

    #[test]
    fn abstention_no_trailing_space() {
        assert!(
            TEMPLATE_ABSTENTION.contains("asked information is not.\n\nQuestion:"),
            "abstention template must NOT have trailing space before \\n\\n"
        );
    }
}
