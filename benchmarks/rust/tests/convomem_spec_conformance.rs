//! convomem_spec_conformance.rs — vector-driven conformance tests for the Rust convomem-spec leg.
//!
//! Drives `convomem_spec_protocol` (and by extension the shared `protocol_vectors.json`) to verify
//! byte-identical prompt rendering, identical verdict parsing, and identical §B4 aggregation
//! on the Rust port.
//!
//! Conformance contract (BENCHMARKER_OPTIMIZER_CONTRACT.md §4):
//!   Same inputs → identical outputs on Rust and Swift legs.
//!   `conformance/convomem-spec/protocol_vectors.json` is the single source of expected values;
//!   neither port hardcodes expected values independently (except golden pins).
//!
//! Path resolution:
//!   CARGO_MANIFEST_DIR = benchmarks/rust/
//!   parent()           = benchmarks/
//!   join(...)          = benchmarks/conformance/convomem-spec/protocol_vectors.json
//!
//! Run with:
//!   CARGO_TARGET_DIR=target-lcspec cargo test --offline convomem_spec

use mcp_benchmarker_rs::convomem_spec_protocol::{
    convomem_build_conversation_context, convomem_model_answer_prompt,
    convomem_judge_evaluation_criteria, convomem_memory_based_prompt,
    convomem_default_factual_judge_prompt, convomem_rubric_based_judge_prompt,
    convomem_temporal_judge_prompt, convomem_user_facts_judge_prompt,
    convomem_abstention_judge_prompt, convomem_judge_prompt,
    convomem_verdict, convomem_aggregate,
    ConvoMemMessage, ConvoMemConversation, ConvoMemEvidenceMessage,
    ConvoMemEvidenceType, ConvoMemVerdictOutcome, ConvoMemVerdictRow,
};
use serde_json::Value;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve `benchmarks/conformance/convomem-spec/<filename>` from CARGO_MANIFEST_DIR.
///
/// CARGO_MANIFEST_DIR = `benchmarks/rust/`; one `parent()` → `benchmarks/`.
fn convomem_spec_conformance_path(filename: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join("convomem-spec")
        .join(filename)
}

/// Load and parse a JSON file; panic with a clear message on failure.
fn load_json(path: &PathBuf) -> Value {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|e| panic!("Failed to parse {}: {e}", path.display()))
}

/// Load `protocol_vectors.json` from the conformance directory.
fn load_protocol_vectors() -> Value {
    load_json(&convomem_spec_conformance_path("protocol_vectors.json"))
}

// ─────────────────────────────────────────────────────────────────────────────
// JSON decode helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Decode a `conversations` JSON array to `Vec<ConvoMemConversation>`.
fn decode_conversations(arr: &Value) -> Vec<ConvoMemConversation> {
    arr.as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|conv| {
            let msgs: Vec<ConvoMemMessage> = conv["messages"]
                .as_array()
                .unwrap_or(&vec![])
                .iter()
                .map(|msg| ConvoMemMessage {
                    speaker: msg["speaker"].as_str().unwrap_or("").to_string(),
                    text:    msg["text"].as_str().unwrap_or("").to_string(),
                })
                .collect();
            ConvoMemConversation { messages: msgs }
        })
        .collect()
}

/// Decode an `evidence_messages` JSON array to `Vec<ConvoMemEvidenceMessage>`.
fn decode_evidence_messages(arr: &Value) -> Vec<ConvoMemEvidenceMessage> {
    arr.as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|m| ConvoMemEvidenceMessage {
            text: m["text"].as_str().unwrap_or("").to_string(),
        })
        .collect()
}

/// Map a JSON `outcome` string to `ConvoMemVerdictOutcome`.
fn decode_outcome(s: &str) -> ConvoMemVerdictOutcome {
    match s {
        "correct"   => ConvoMemVerdictOutcome::Correct,
        "incorrect" => ConvoMemVerdictOutcome::Incorrect,
        _           => ConvoMemVerdictOutcome::Invalid,
    }
}

/// Apply every structural check from a `checks` JSON array to `result`.
fn apply_checks(result: &str, checks: &Value, case_id: &str) {
    if let Some(arr) = checks.as_array() {
        for check in arr {
            if let Some(sub) = check["contains"].as_str() {
                assert!(
                    result.contains(sub),
                    "case {case_id}: must contain '{sub}'"
                );
            }
            if let Some(suf) = check["ends_with"].as_str() {
                assert!(
                    result.ends_with(suf),
                    "case {case_id}: must end with '{suf}', got: ...'{}'",
                    result.chars().rev().take(40).collect::<String>().chars().rev().collect::<String>()
                );
            }
            if let Some(pre) = check["starts_with"].as_str() {
                assert!(
                    result.starts_with(pre),
                    "case {case_id}: must start with '{pre}'"
                );
            }
            if let Some(not_sub) = check["not_contains"].as_str() {
                assert!(
                    !result.contains(not_sub),
                    "case {case_id}: must NOT contain '{not_sub}'"
                );
            }
            if check["no_trailing_newline"].as_bool() == Some(true) {
                assert!(
                    !result.ends_with('\n'),
                    "case {case_id}: must not end with newline"
                );
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B1 buildConversationContext conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `build_conversation_context` vector.
///
/// §B1: 1-based numbering, turns joined by "\n", conversations joined by "\n\n".
#[test]
fn convomem_spec_build_conversation_context_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["build_conversation_context"]
        .as_array()
        .expect("build_conversation_context must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let convs    = decode_conversations(&c["input"]["conversations"]);
        let expected = c["expected"].as_str()
            .unwrap_or_else(|| panic!("case {id}: missing 'expected'"));

        let got = convomem_build_conversation_context(&convs);
        assert_eq!(got, expected,
            "case {id}: buildConversationContext mismatch");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B1 modelAnswerPrompt conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `model_answer_prompt` vector.
///
/// §B1: full-context prompt with "Question: …\n\nAnswer:" suffix, no trailing newline.
#[test]
fn convomem_spec_model_answer_prompt_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["model_answer_prompt"]
        .as_array()
        .expect("model_answer_prompt must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let convs    = decode_conversations(&c["input"]["conversations"]);
        let question = c["input"]["question"].as_str().unwrap_or("");
        let expected = c["expected"].as_str()
            .unwrap_or_else(|| panic!("case {id}: missing 'expected'"));

        let got = convomem_model_answer_prompt(&convs, question);
        assert_eq!(got, expected,
            "case {id}: modelAnswerPrompt mismatch");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B1 memoryBasedPrompt conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `memory_based_prompt` vector through structural checks.
///
/// §B1: criteria block + numbered memories + "Answer:", no trailing newline.
#[test]
fn convomem_spec_memory_based_prompt_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["memory_based_prompt"]
        .as_array()
        .expect("memory_based_prompt must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let question = c["input"]["question"].as_str().unwrap_or("");
        let empty_mems = vec![];
        let memories: Vec<&str> = c["input"]["memories"]
            .as_array()
            .unwrap_or(&empty_mems)
            .iter()
            .map(|m| m.as_str().unwrap_or(""))
            .collect();

        let got = convomem_memory_based_prompt(question, &memories);

        // expected_suffix: output must end with this literal string.
        if let Some(suffix) = c["expected_suffix"].as_str() {
            assert!(
                got.ends_with(suffix),
                "case {id}: output must end with expected_suffix"
            );
        }

        // expected_memories_block: numbered memory list must appear verbatim.
        if let Some(block) = c["expected_memories_block"].as_str() {
            assert!(
                got.contains(block),
                "case {id}: expected_memories_block not found in output"
            );
        }

        // expected_ends_with: softer suffix check.
        if let Some(ends) = c["expected_ends_with"].as_str() {
            assert!(
                got.ends_with(ends),
                "case {id}: output must end with '{ends}'"
            );
        }

        // No trailing newline.
        if c["expected_no_trailing_newline"].as_bool() == Some(true) {
            assert!(
                !got.ends_with('\n'),
                "case {id}: output must not end with newline"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B1 judgeEvaluationCriteria conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies the criteria block: verbatim trailing space on items 2 and 5, no trailing newline.
///
/// §B1 (MemoryPromptUtils.getJudgeEvaluationCriteria): items 2 and 5 end with trailing space
/// before the newline — verbatim from the Scala source. Any change breaks byte equality.
#[test]
fn convomem_spec_judge_evaluation_criteria_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["judge_evaluation_criteria"]
        .as_array()
        .expect("judge_evaluation_criteria must be an array");
    let c = cases.first().expect("Expected at least one criteria case");

    let result = convomem_judge_evaluation_criteria();
    apply_checks(&result, &c["checks"], c["id"].as_str().unwrap_or("criteria"));
}

// ─────────────────────────────────────────────────────────────────────────────
// §B2 judge prompt dispatch conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the judge prompt for a given function name and input object.
///
/// Maps the JSON "function" string to the matching Rust builder function.
fn build_prompt_for_function(fn_name: &str, input: &Value) -> Option<String> {
    let question     = input["question"].as_str().unwrap_or("");
    let correct_ans  = input["correct_answer"].as_str().unwrap_or("");
    let model_answer = input["model_answer"].as_str().unwrap_or("");

    match fn_name {
        "default_factual" => Some(convomem_default_factual_judge_prompt(
            question, correct_ans, model_answer,
        )),
        "rubric_based" => {
            // §B2: rubric variant uses "rubric" when present; otherwise falls back to correct_answer.
            let rubric = input["rubric"].as_str().unwrap_or(correct_ans);
            Some(convomem_rubric_based_judge_prompt(question, rubric, model_answer))
        }
        "temporal" => Some(convomem_temporal_judge_prompt(
            question, correct_ans, model_answer,
        )),
        "user_facts" => {
            let evidence_count = input["evidence_count"].as_u64().unwrap_or(1) as usize;
            let msgs = decode_evidence_messages(&input["evidence_messages"]);
            Some(convomem_user_facts_judge_prompt(
                question,
                correct_ans,
                model_answer,
                &msgs,
                evidence_count,
            ))
        }
        "abstention" => Some(convomem_abstention_judge_prompt(question, model_answer)),
        _ => None,
    }
}

/// Drives every `judge_prompts` vector through the matching builder.
#[test]
fn convomem_spec_judge_prompts_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["judge_prompts"]
        .as_array()
        .expect("judge_prompts must be an array");

    for c in cases {
        let id      = c["id"].as_str().unwrap_or("(unknown)");
        let fn_name = c["function"].as_str()
            .unwrap_or_else(|| panic!("case {id}: missing 'function'"));

        let result = build_prompt_for_function(fn_name, &c["input"])
            .unwrap_or_else(|| panic!("case {id}: unknown function '{fn_name}'"));

        apply_checks(&result, &c["checks"], id);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B3 verdict parsing conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Maps `ConvoMemVerdictOutcome` to the JSON string used in the conformance vectors.
fn outcome_label(o: &ConvoMemVerdictOutcome) -> &'static str {
    match o {
        ConvoMemVerdictOutcome::Correct   => "correct",
        ConvoMemVerdictOutcome::Incorrect => "incorrect",
        ConvoMemVerdictOutcome::Invalid   => "invalid",
    }
}

/// Drives every `verdict_parsing` vector through `convomem_verdict`.
///
/// §B3: trim + lowercase → contains("right") / contains("wrong").
/// Both present → ambiguous → Incorrect (NOT Invalid).
/// Neither → Invalid (retry signal).
#[test]
fn convomem_spec_verdict_parsing_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["verdict_parsing"]
        .as_array()
        .expect("verdict_parsing must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let input    = c["input"].as_str()
            .unwrap_or_else(|| panic!("case {id}: missing 'input'"));
        let expected = c["expected"].as_str()
            .unwrap_or_else(|| panic!("case {id}: missing 'expected'"));

        let got = convomem_verdict(input);
        assert_eq!(
            outcome_label(&got), expected,
            "case {id}: got '{}' expected '{}'", outcome_label(&got), expected
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §B4 aggregation conformance
// ─────────────────────────────────────────────────────────────────────────────

/// Drives every `aggregation` vector through `convomem_aggregate`.
///
/// §B4: .Invalid rows excluded from accuracy denominator; accuracy rounded to 4 decimal places.
#[test]
fn convomem_spec_aggregation_conformance() {
    let vectors = load_protocol_vectors();
    let cases = vectors["aggregation"]
        .as_array()
        .expect("aggregation must be an array");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let expected = &c["expected"];
        let rows_json = c["input"]["rows"]
            .as_array()
            .unwrap_or_else(|| panic!("case {id}: missing rows"));

        let rows: Vec<ConvoMemVerdictRow> = rows_json.iter().map(|row| {
            ConvoMemVerdictRow::new(
                row["evidence_type"].as_str().unwrap_or(""),
                row["evidence_count"].as_u64().unwrap_or(1) as usize,
                decode_outcome(row["outcome"].as_str().unwrap_or("invalid")),
            )
        }).collect();

        let result = convomem_aggregate(&rows);

        if let Some(want_acc) = expected["overall_accuracy"].as_f64() {
            assert!(
                (result.overall_accuracy - want_acc).abs() < 1e-4,
                "case {id}: overall_accuracy got {} expected {}",
                result.overall_accuracy, want_acc
            );
        }
        if let Some(want_correct) = expected["overall_correct_count"].as_u64() {
            assert_eq!(
                result.overall_correct_count, want_correct as usize,
                "case {id}: overall_correct_count"
            );
        }
        if let Some(want_scored) = expected["overall_scored_count"].as_u64() {
            assert_eq!(
                result.overall_scored_count, want_scored as usize,
                "case {id}: overall_scored_count"
            );
        }
        if let Some(want_unscored) = expected["overall_unscored_count"].as_u64() {
            assert_eq!(
                result.overall_unscored_count, want_unscored as usize,
                "case {id}: overall_unscored_count"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Golden pins
// ─────────────────────────────────────────────────────────────────────────────

/// §B3 golden pin: "RIGHT and WRONG" → ambiguous → Incorrect, NOT Invalid.
///
/// This is the most critical §B3 rule: when both "right" and "wrong" appear, the
/// verdict is false (Incorrect), not a retry signal (Invalid). The distinction matters:
/// Invalid triggers the bounded-retry loop; Incorrect scores the question as wrong.
#[test]
fn convomem_spec_verdict_ambiguous_both_is_incorrect_not_invalid() {
    let outcome = convomem_verdict("RIGHT and WRONG");
    assert_eq!(outcome, ConvoMemVerdictOutcome::Incorrect,
        "§B3: both 'right' and 'wrong' present → ambiguous → Incorrect");
    assert_ne!(outcome, ConvoMemVerdictOutcome::Invalid,
        "§B3: ambiguous must NOT be Invalid — Invalid triggers retry, not a score");
}

/// §B3 golden pin: verdict case-insensitive, whitespace-trimmed.
///
/// §B3 step 1 (verbatim from EvaluationUtils.scala): response.content.trim.toLowerCase.
#[test]
fn convomem_spec_verdict_case_insensitive_and_trimmed() {
    assert_eq!(convomem_verdict("RIGHT"),       ConvoMemVerdictOutcome::Correct);
    assert_eq!(convomem_verdict("right"),       ConvoMemVerdictOutcome::Correct);
    assert_eq!(convomem_verdict("  RIGHT  "),   ConvoMemVerdictOutcome::Correct);
    assert_eq!(convomem_verdict("WRONG"),       ConvoMemVerdictOutcome::Incorrect);
    assert_eq!(convomem_verdict("wrong"),       ConvoMemVerdictOutcome::Incorrect);
    assert_eq!(convomem_verdict(""),            ConvoMemVerdictOutcome::Invalid);
    assert_eq!(convomem_verdict("maybe"),       ConvoMemVerdictOutcome::Invalid);
}

/// §B4 golden pin: agg_basic — 4-decimal rounding on 2/3 = 0.6667.
///
/// convoMemRound4(2.0/3.0) = round(0.6666... * 10000) / 10000 = 0.6667.
/// §B4: Invalid rows excluded from denominator (unscored, not scored wrong).
#[test]
fn convomem_spec_agg_basic_golden_pin() {
    let rows = vec![
        ConvoMemVerdictRow::new("user_evidence",     1, ConvoMemVerdictOutcome::Correct),
        ConvoMemVerdictRow::new("user_evidence",     1, ConvoMemVerdictOutcome::Incorrect),
        ConvoMemVerdictRow::new("changing_evidence", 2, ConvoMemVerdictOutcome::Correct),
        ConvoMemVerdictRow::new("user_evidence",     1, ConvoMemVerdictOutcome::Invalid),
    ];
    let r = convomem_aggregate(&rows);
    assert_eq!(r.overall_accuracy,       0.6667,
        "overall_accuracy must round to 0.6667 (4-decimal rounding on 2/3)");
    assert_eq!(r.overall_correct_count,  2, "overallCorrectCount");
    assert_eq!(r.overall_scored_count,   3, "overallScoredCount (Invalid excluded)");
    assert_eq!(r.overall_unscored_count, 1, "overallUnscoredCount");
}

/// §B4 golden pin: agg_all_invalid — 0.0 accuracy, no scored rows.
#[test]
fn convomem_spec_agg_all_invalid_golden_pin() {
    let rows = vec![
        ConvoMemVerdictRow::new("abstention_evidence", 1, ConvoMemVerdictOutcome::Invalid),
        ConvoMemVerdictRow::new("abstention_evidence", 1, ConvoMemVerdictOutcome::Invalid),
    ];
    let r = convomem_aggregate(&rows);
    assert_eq!(r.overall_accuracy,       0.0, "all-invalid accuracy must be 0.0");
    assert_eq!(r.overall_scored_count,   0,   "all-invalid scored must be 0");
    assert_eq!(r.overall_unscored_count, 2,   "all-invalid unscored == row count");
}

/// §B1 golden pin: memoryBasedPrompt with one memory ends with "Answer:", no trailing newline.
#[test]
fn convomem_spec_memory_based_prompt_one_memory_golden_pin() {
    let memories = vec!["The user mentioned they love pasta."];
    let prompt = convomem_memory_based_prompt(
        "What is the user's favorite food?",
        &memories,
    );
    assert!(
        prompt.contains("1. The user mentioned they love pasta."),
        "memory block must contain '1. ...' numbered entry"
    );
    assert!(
        prompt.ends_with("Answer:"),
        "memoryBasedPrompt must end with 'Answer:'"
    );
    assert!(
        !prompt.ends_with('\n'),
        "memoryBasedPrompt must not end with newline"
    );
}

/// §B1 golden pin: memoryBasedPrompt with empty memories ends with "Answer:".
///
/// Empty-memories variant embeds "I don't know" fallback and ends with "Answer:".
#[test]
fn convomem_spec_memory_based_prompt_empty_golden_pin() {
    let prompt = convomem_memory_based_prompt(
        "What is the user's favorite food?",
        &[],
    );
    assert!(
        prompt.contains("I don't know"),
        "empty-memories prompt must contain 'I don't know' fallback"
    );
    assert!(
        prompt.ends_with("Answer:"),
        "empty-memories prompt must end with 'Answer:'"
    );
}

/// §B1 golden pin: criteria block has verbatim trailing space on items 2 and 5.
///
/// "2. **Completeness with Transparency**: \n" and "5. **Clarity and Honesty**: \n"
/// — trailing space before the newline is byte-verbatim from MemoryPromptUtils.scala.
#[test]
fn convomem_spec_criteria_trailing_space_golden_pin() {
    let criteria = convomem_judge_evaluation_criteria();
    assert!(
        criteria.contains("2. **Completeness with Transparency**: \n"),
        "criteria item 2 must have trailing space before newline (verbatim Scala)"
    );
    assert!(
        criteria.contains("5. **Clarity and Honesty**: \n"),
        "criteria item 5 must have trailing space before newline (verbatim Scala)"
    );
    assert!(
        !criteria.ends_with('\n'),
        "criteria must not end with newline (§B1 'don't know.' terminal)"
    );
}

/// §B2 golden pin: default factual template — two-space guideline numbering.
///
/// "1.  **Core Information is Key**" has two spaces after the period — verbatim from
/// cm_DefaultFactualJudgePrompt.scala. Any change breaks byte equality with Swift port.
#[test]
fn convomem_spec_default_factual_two_space_golden_pin() {
    let p = convomem_default_factual_judge_prompt(
        "What color is the car?",
        "Blue",
        "The car is blue.",
    );
    assert!(
        p.contains("1.  **Core Information is Key**"),
        "default factual must have two spaces after '1.' (verbatim Scala)"
    );
    assert!(
        p.ends_with("Answer (RIGHT/WRONG):"),
        "default factual must end with 'Answer (RIGHT/WRONG):'"
    );
}

/// §B2 golden pin: userfacts single — trailing space on "**Question Asked:** \n".
///
/// "**Question Asked:** \n" — space before the newline is verbatim from
/// cm_UserFactsAnsweringEvaluation.scala and must survive both ports.
#[test]
fn convomem_spec_userfacts_single_trailing_space_golden_pin() {
    let msgs = vec![ConvoMemEvidenceMessage {
        text: "User: I eat pasta for dinner every night.".to_string(),
    }];
    let p = convomem_user_facts_judge_prompt(
        "What does the user eat?",
        "Pasta",
        "The user eats pasta.",
        &msgs,
        1,
    );
    assert!(
        p.contains("**Question Asked:** \n"),
        "userfacts single must contain '**Question Asked:** \\n' (trailing space)"
    );
    assert!(
        p.contains("**Evidence Message Available to the Model:**"),
        "userfacts single must use singular evidence header"
    );
    assert!(
        p.ends_with("Answer (RIGHT/WRONG):"),
        "userfacts single must end with 'Answer (RIGHT/WRONG):'"
    );
}

/// §B2 golden pin: userfacts multi — numbered evidence messages, plural header.
#[test]
fn convomem_spec_userfacts_multi_numbered_golden_pin() {
    let msgs = vec![
        ConvoMemEvidenceMessage {
            text: "User: I eat pasta for dinner every night.".to_string(),
        },
        ConvoMemEvidenceMessage {
            text: "User: I also love sushi on weekends.".to_string(),
        },
    ];
    let p = convomem_user_facts_judge_prompt(
        "What does the user eat?",
        "Pasta and sushi",
        "The user eats pasta and sushi.",
        &msgs,
        2,
    );
    assert!(
        p.contains("**Evidence Messages Available to the Model:**"),
        "userfacts multi must use plural header"
    );
    assert!(
        p.contains("Evidence Message 1: User: I eat pasta for dinner every night."),
        "userfacts multi must number message 1"
    );
    assert!(
        p.contains("Evidence Message 2: User: I also love sushi on weekends."),
        "userfacts multi must number message 2"
    );
}

/// §B2 golden pin: abstention — "Correct Answer" must not appear.
#[test]
fn convomem_spec_abstention_no_correct_answer_golden_pin() {
    let p = convomem_abstention_judge_prompt(
        "What is the user's phone number?",
        "I don't have that information.",
    );
    assert!(
        p.contains("Abstention is Success"),
        "abstention template must reference abstention success"
    );
    assert!(
        !p.contains("Correct Answer"),
        "abstention template must NOT embed the correct answer"
    );
    assert!(
        p.ends_with("Answer (RIGHT/WRONG):"),
        "abstention template must end with 'Answer (RIGHT/WRONG):'"
    );
}

/// §B2 golden pin: convomem_judge_prompt selector routes all five evidence types.
///
/// §B2 mapping from cm_EvaluationUtils.scala:
///   AssistantFactsEvidence → DefaultAnsweringEvaluation (contains "Core Information is Key")
///   PreferenceEvidence     → RubricBasedAnsweringEvaluation (contains "ALL criteria")
///   ImplicitConnection...  → RubricBasedAnsweringEvaluation
///   ChangingEvidence       → TemporalAnsweringEvaluation (contains "Off-by-one errors")
///   UserEvidence           → UserFactsAnsweringEvaluation (contains "Question Asked")
///   AbstentionEvidence     → AbstentionAnsweringEvaluation (contains "Abstention is Success")
#[test]
fn convomem_spec_judge_prompt_selector_golden_pin() {
    let q  = "What does the user prefer?";
    let ca = "Email";
    let ma = "The user prefers email.";

    let assistant_facts = convomem_judge_prompt(
        &ConvoMemEvidenceType::AssistantFactsEvidence, q, ca, ma, &[], 1);
    assert!(assistant_facts.contains("Core Information is Key"),
        "AssistantFactsEvidence → default factual");

    let preference = convomem_judge_prompt(
        &ConvoMemEvidenceType::PreferenceEvidence, q, ca, ma, &[], 1);
    assert!(preference.contains("ALL criteria"),
        "PreferenceEvidence → rubric-based");

    let implicit = convomem_judge_prompt(
        &ConvoMemEvidenceType::ImplicitConnectionEvidence, q, ca, ma, &[], 1);
    assert!(implicit.contains("ALL criteria"),
        "ImplicitConnectionEvidence → rubric-based");

    let changing = convomem_judge_prompt(
        &ConvoMemEvidenceType::ChangingEvidence, q, ca, ma, &[], 1);
    assert!(changing.contains("Off-by-one errors"),
        "ChangingEvidence → temporal");

    let user = convomem_judge_prompt(
        &ConvoMemEvidenceType::UserEvidence, q, ca, ma, &[], 1);
    assert!(user.contains("Question Asked"),
        "UserEvidence → user-facts");

    let abstention = convomem_judge_prompt(
        &ConvoMemEvidenceType::AbstentionEvidence, q, ca, ma, &[], 1);
    assert!(abstention.contains("Abstention is Success"),
        "AbstentionEvidence → abstention");
}
