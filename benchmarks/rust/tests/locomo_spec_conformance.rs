//! locomo_spec_conformance.rs — Conformance and golden-pin tests for the Rust
//! locomo-spec leg (locomo_spec_scorer + locomo_spec_corpus).
//!
//! Source of truth for expected values:
//!   benchmarks/conformance/locomo-spec/scorer_vectors.json
//!
//! Both this Rust suite and the Swift twin (LoCoMoSpecScorerTests.swift,
//! LoCoMoSpecCorpusCountTests.swift, LoCoMoSpecRunnerTests.swift) load the same
//! JSON file and assert identical results. Golden-pin literals are the SAME
//! values asserted in the Swift twin.
//!
//! Path resolution:
//!   CARGO_MANIFEST_DIR = benchmarks/rust/
//!   parent()           = benchmarks/
//!
//! Run with:
//!   CARGO_TARGET_DIR=target-locospec cargo test --offline locomo_spec

use mcp_benchmarker_rs::locomo_spec_corpus::{
    load_locomo_spec_corpus, locomo_conversation_preamble, locomo_format_turn,
    locomo_session_header, LoCoMoSpecTurn,
};
use mcp_benchmarker_rs::locomo_spec_scorer::{
    evidence_recall, f1_score, locomo_spec_aggregate, multi_answer_f1, normalize_answer,
    porter_stem, score_question,
};
use serde_json::Value;
use std::path::PathBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Path helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Resolve `benchmarks/conformance/locomo-spec/<filename>` from CARGO_MANIFEST_DIR.
fn conformance_path(filename: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("conformance")
        .join("locomo-spec")
        .join(filename)
}

/// Resolve `benchmarks/fixtures/locomo/data/locomo10.json` from CARGO_MANIFEST_DIR.
fn locomo10_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("benchmarks/ parent must exist")
        .join("fixtures")
        .join("locomo")
        .join("data")
        .join("locomo10.json")
}

/// Resolve the sample fixture used by both Swift and Rust tests.
fn sample_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/mcp-benchmarkerTests/locomo_spec_sample.json")
}

/// Load and parse a JSON file; panic with a clear message on failure.
fn load_json(path: &PathBuf) -> Value {
    let data = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {e}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|e| panic!("Failed to parse {}: {e}", path.display()))
}

const TOL: f64 = 1e-9;

// ─────────────────────────────────────────────────────────────────────────────
// §1 normalize_answer — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Every normalize_answer_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_normalize_answer_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["normalize_answer_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'normalize_answer_cases'");

    assert!(!cases.is_empty(), "normalize_answer_cases must not be empty");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let input    = c["input"].as_str().unwrap_or_else(|| panic!("{id}: missing 'input'"));
        let expected = c["expected"].as_str().unwrap_or_else(|| panic!("{id}: missing 'expected'"));
        let got = normalize_answer(input);
        assert_eq!(
            got, expected,
            "normalize_answer '{id}': expected {expected:?}, got {got:?}"
        );
    }
}

// ── Golden pins — §2 requirement ─────────────────────────────────────────────
// Same literals as in LoCoMoSpecScorerTests.swift / goldenPinHelloWorld etc.

/// §1 pipeline: "Hello, World!" → "hello world".
#[test]
fn locomo_spec_normalize_golden_pin_hello_world() {
    assert_eq!(normalize_answer("Hello, World!"), "hello world");
}

/// §1 article removal: "a" and "and" stripped as whole words.
#[test]
fn locomo_spec_normalize_golden_pin_articles() {
    assert_eq!(normalize_answer("a dog and a cat"), "dog cat");
}

/// §1 apostrophe in Python string.punctuation → removed.
#[test]
fn locomo_spec_normalize_golden_pin_apostrophe() {
    assert_eq!(normalize_answer("runner's high"), "runners high");
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 porter_stem — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Every porter_stem_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_porter_stem_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["porter_stem_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'porter_stem_cases'");

    assert!(!cases.is_empty(), "porter_stem_cases must not be empty");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let input    = c["input"].as_str().unwrap_or_else(|| panic!("{id}: missing 'input'"));
        let expected = c["expected"].as_str().unwrap_or_else(|| panic!("{id}: missing 'expected'"));
        let got = porter_stem(input);
        assert_eq!(
            got, expected,
            "porter_stem '{id}': expected {expected:?}, got {got:?}"
        );
    }
}

// ── Golden pins ───────────────────────────────────────────────────────────────

/// Classic Porter 1980 paper example: caresses → caress (Step 1a SSES→SS).
#[test]
fn locomo_spec_stem_golden_pin_caresses() {
    assert_eq!(porter_stem("caresses"), "caress");
}

/// Step 1b ING + double-consonant reduction: running → run.
#[test]
fn locomo_spec_stem_golden_pin_running() {
    assert_eq!(porter_stem("running"), "run");
}

/// Step 1b ING + double-consonant reduction: stemming → stem.
#[test]
fn locomo_spec_stem_golden_pin_stemming() {
    assert_eq!(porter_stem("stemming"), "stem");
}

/// Words of 2 characters are returned unchanged (NLTK convention).
#[test]
fn locomo_spec_stem_golden_pin_two_char() {
    assert_eq!(porter_stem("in"), "in");
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 f1_score — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Every f1_score_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_f1_score_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["f1_score_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'f1_score_cases'");

    for c in cases {
        let id         = c["id"].as_str().unwrap_or("(unknown)");
        let prediction = c["prediction"].as_str().unwrap_or_else(|| panic!("{id}: missing 'prediction'"));
        let gold       = c["gold"].as_str().unwrap_or_else(|| panic!("{id}: missing 'gold'"));
        let expected   = c["expected_f1"].as_f64().unwrap_or_else(|| panic!("{id}: missing 'expected_f1'"));
        let got = f1_score(prediction, gold);
        assert!(
            (got - expected).abs() <= TOL,
            "f1_score '{id}': expected {expected}, got {got}"
        );
    }
}

// ── Golden pins ───────────────────────────────────────────────────────────────

/// Identical strings → F1 = 1.0.
#[test]
fn locomo_spec_f1_golden_pin_identical() {
    assert_eq!(f1_score("cat", "cat"), 1.0);
}

/// Stemming unifies "dogs"→"dog" and "running"→"run" → F1 = 1.0.
#[test]
fn locomo_spec_f1_golden_pin_stem_match() {
    assert_eq!(f1_score("running dogs", "dog run"), 1.0);
}

/// Disjoint token sets → F1 = 0.0.
#[test]
fn locomo_spec_f1_golden_pin_no_overlap() {
    assert_eq!(f1_score("hello", "world"), 0.0);
}

/// Partial overlap: intersection = {world:1}, precision = 1/2, recall = 1/1, F1 = 2/3.
#[test]
fn locomo_spec_f1_golden_pin_partial_overlap() {
    let got = f1_score("hello world", "world");
    let expected = 2.0 / 3.0;
    assert!(
        (got - expected).abs() <= TOL,
        "expected 2/3 ≈ {expected}, got {got}"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 multi_answer_f1 — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Every multi_answer_f1_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_multi_answer_f1_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["multi_answer_f1_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'multi_answer_f1_cases'");

    for c in cases {
        let id         = c["id"].as_str().unwrap_or("(unknown)");
        let prediction = c["prediction"].as_str().unwrap_or_else(|| panic!("{id}: missing 'prediction'"));
        let gold       = c["gold"].as_str().unwrap_or_else(|| panic!("{id}: missing 'gold'"));
        let expected   = c["expected"].as_f64().unwrap_or_else(|| panic!("{id}: missing 'expected'"));
        let got = multi_answer_f1(prediction, gold);
        assert!(
            (got - expected).abs() <= TOL,
            "multi_answer_f1 '{id}': expected {expected}, got {got}"
        );
    }
}

// ── Golden pin ────────────────────────────────────────────────────────────────

/// gold "cat" → max=1.0; gold "feline" → max=0.0; mean = 0.5.
#[test]
fn locomo_spec_multi_answer_f1_golden_pin_partial() {
    let got = multi_answer_f1("cat, dog", "cat, feline");
    assert!(
        (got - 0.5).abs() <= TOL,
        "expected 0.5, got {got}"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 score_question — conformance vectors + cat-5 golden pins
// ─────────────────────────────────────────────────────────────────────────────

/// Every score_question_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_score_question_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["score_question_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'score_question_cases'");

    for c in cases {
        let id         = c["id"].as_str().unwrap_or("(unknown)");
        let category   = c["category"].as_u64().unwrap_or_else(|| panic!("{id}: missing 'category'")) as u8;
        let prediction = c["prediction"].as_str().unwrap_or_else(|| panic!("{id}: missing 'prediction'"));
        let gold       = c["gold"].as_str().unwrap_or_else(|| panic!("{id}: missing 'gold'"));
        let expected   = c["expected"].as_f64().unwrap_or_else(|| panic!("{id}: missing 'expected'"));
        let got = score_question(category, prediction, gold)
            .unwrap_or_else(|e| panic!("{id}: score_question error: {e}"));
        assert!(
            (got - expected).abs() <= TOL,
            "score_question '{id}': expected {expected}, got {got}"
        );
    }
}

// ── Cat-5 binary rule golden pins — same literals as Swift twin ───────────────

/// "no information available" (mixed case) → 1.0.
#[test]
fn locomo_spec_cat5_golden_pin_no_info_available() {
    assert_eq!(
        score_question(5, "No information available here.", "anything").unwrap(),
        1.0
    );
}

/// "not mentioned" → 1.0.
#[test]
fn locomo_spec_cat5_golden_pin_not_mentioned() {
    assert_eq!(
        score_question(5, "This topic is not mentioned in the conversation.", "anything").unwrap(),
        1.0
    );
}

/// Neither phrase present → 0.0.
#[test]
fn locomo_spec_cat5_golden_pin_no_abstain() {
    assert_eq!(
        score_question(5, "The answer is 42.", "anything").unwrap(),
        0.0
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 evidence_recall — conformance vectors + golden pins for both forms
// ─────────────────────────────────────────────────────────────────────────────

/// Every evidence_recall_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_evidence_recall_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["evidence_recall_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'evidence_recall_cases'");

    for c in cases {
        let id       = c["id"].as_str().unwrap_or("(unknown)");
        let expected = c["expected"].as_f64().unwrap_or_else(|| panic!("{id}: missing 'expected'"));
        let evidence: Vec<String> = c["evidence"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();

        // context: null → None; array → Some(vec).
        let context: Option<Vec<String>> = match &c["context"] {
            Value::Null => None,
            Value::Array(arr) => Some(
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect(),
            ),
            other => panic!("{id}: unexpected context shape: {other}"),
        };

        let got = evidence_recall(context.as_deref(), &evidence);
        assert!(
            (got - expected).abs() <= TOL,
            "evidence_recall '{id}': expected {expected}, got {got}"
        );
    }
}

// ── Golden pins for both evidence forms — same literals as Swift twin ─────────

/// No context field → recall 1.0 per §4.
#[test]
fn locomo_spec_recall_golden_pin_no_context() {
    assert_eq!(evidence_recall(None, &["D1:1".to_string()]), 1.0);
}

/// Session form: ["S3","S1"] + evidence ["D3:5","D1:2"] → recall 1.0.
/// §4: ev.split(':')[0][1:] extracts session number.
#[test]
fn locomo_spec_recall_golden_pin_session_form_full() {
    let ctx = vec!["S3".to_string(), "S1".to_string()];
    let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
    assert_eq!(evidence_recall(Some(&ctx), &ev), 1.0);
}

/// Session form: ["S3"] + evidence ["D3:5","D1:2"] → recall 0.5.
#[test]
fn locomo_spec_recall_golden_pin_session_form_half() {
    let ctx = vec!["S3".to_string()];
    let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
    let got = evidence_recall(Some(&ctx), &ev);
    assert!((got - 0.5).abs() <= TOL, "expected 0.5, got {got}");
}

/// Dia form: ["D3:5","D2:1"] + evidence ["D3:5","D1:2"] → recall 0.5.
/// §4: direct membership check when context does not start with 'S'.
#[test]
fn locomo_spec_recall_golden_pin_dia_form_half() {
    let ctx = vec!["D3:5".to_string(), "D2:1".to_string()];
    let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
    let got = evidence_recall(Some(&ctx), &ev);
    assert!((got - 0.5).abs() <= TOL, "expected 0.5, got {got}");
}

/// Dia form: both evidence items present → recall 1.0.
#[test]
fn locomo_spec_recall_golden_pin_dia_form_full() {
    let ctx = vec!["D3:5".to_string(), "D1:2".to_string()];
    let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
    assert_eq!(evidence_recall(Some(&ctx), &ev), 1.0);
}

// ─────────────────────────────────────────────────────────────────────────────
// §5 locomo_spec_aggregate — conformance vectors
// ─────────────────────────────────────────────────────────────────────────────

/// Every aggregate_case in scorer_vectors.json must pass on the Rust leg.
#[test]
fn locomo_spec_aggregate_vectors() {
    let path = conformance_path("scorer_vectors.json");
    let json = load_json(&path);

    let cases = json["aggregate_cases"]
        .as_array()
        .expect("scorer_vectors.json must have 'aggregate_cases'");

    for c in cases {
        let id = c["id"].as_str().unwrap_or("(unknown)");
        let raw_scores = c["scores"].as_array()
            .unwrap_or_else(|| panic!("{id}: missing 'scores'"));
        let expected = &c["expected"];

        let scores: Vec<(u8, f64, f64)> = raw_scores
            .iter()
            .map(|s| {
                let cat    = s["category"].as_u64().unwrap() as u8;
                let score  = s["score"].as_f64().unwrap();
                let recall = s["recall"].as_f64().unwrap();
                (cat, score, recall)
            })
            .collect();

        let result = locomo_spec_aggregate(&scores);

        // Overall accuracy.
        let exp_overall = expected["overall"].as_f64()
            .unwrap_or_else(|| panic!("{id}: missing 'expected.overall'"));
        assert!(
            (result.overall - exp_overall).abs() <= TOL,
            "aggregate '{id}' overall: expected {exp_overall}, got {}", result.overall
        );

        // Total questions.
        let exp_total = expected["total_questions"].as_u64()
            .unwrap_or_else(|| panic!("{id}: missing 'expected.total_questions'")) as usize;
        assert_eq!(
            result.total_questions, exp_total,
            "aggregate '{id}' total_questions: expected {exp_total}, got {}", result.total_questions
        );

        // §5: category order must be [4, 1, 2, 3, 5].
        let got_order: Vec<u8> = result.by_category.iter().map(|c| c.category).collect();
        let exp_order: Vec<u8> = expected["by_category_order"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_u64().unwrap() as u8)
            .collect();
        assert_eq!(got_order, exp_order, "aggregate '{id}' category order");

        // Per-category accuracy.
        let exp_cat_accuracy = &expected["category_accuracy"];
        for cm in &result.by_category {
            let key = cm.category.to_string();
            if let Some(exp_acc) = exp_cat_accuracy.get(&key).and_then(|v| v.as_f64()) {
                assert!(
                    (cm.accuracy - exp_acc).abs() <= TOL,
                    "aggregate '{id}' cat-{} accuracy: expected {exp_acc}, got {}",
                    cm.category, cm.accuracy
                );
            }
        }
    }
}

/// §5: category order in by_category is always [4, 1, 2, 3, 5].
#[test]
fn locomo_spec_aggregate_category_order() {
    let scores = vec![(1u8,1.0,1.0),(2u8,1.0,1.0),(3u8,1.0,1.0),(4u8,1.0,1.0),(5u8,1.0,1.0)];
    let result = locomo_spec_aggregate(&scores);
    let order: Vec<u8> = result.by_category.iter().map(|c| c.category).collect();
    assert_eq!(order, vec![4, 1, 2, 3, 5], "§5 mandates category order [4,1,2,3,5]");
}

/// Empty input → overall 0.0, 5 category buckets, all question counts 0.
#[test]
fn locomo_spec_aggregate_empty_input() {
    let result = locomo_spec_aggregate(&[]);
    assert_eq!(result.overall, 0.0);
    assert_eq!(result.total_questions, 0);
    assert_eq!(result.by_category.len(), 5);
    for cm in &result.by_category {
        assert_eq!(cm.question_count, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6 Context-formatting — golden pin (locomo_spec_corpus)
// ─────────────────────────────────────────────────────────────────────────────
//
// The expected string below is IDENTICAL to the string in LoCoMoSpecCorpusCountTests.swift
// (goldenPinPreambleVerbatim). A divergence between ports fails one of the two tests.

/// §6 preamble verbatim — including the official 'wriiten' typo.
/// Same literal as in LoCoMoSpecCorpusCountTests.swift / goldenPinPreambleVerbatim.
#[test]
fn locomo_spec_preamble_golden_pin_verbatim() {
    // §6 literal — DO NOT fix the 'wriiten' typo; it is in the official spec.
    let expected = "Below is a conversation between two people: Alice and Bob. \
                    The conversation takes place over multiple days and the date of each \
                    conversation is wriiten at the beginning of the conversation.";
    let got = locomo_conversation_preamble("Alice", "Bob");
    assert_eq!(got, expected, "preamble must match §6 verbatim (including 'wriiten' typo)");
}

/// §6 session header format: "DATE: [timestamp] CONVERSATION:".
#[test]
fn locomo_spec_session_header_golden_pin() {
    assert_eq!(
        locomo_session_header("1:56 pm on 8 May, 2023"),
        "DATE: 1:56 pm on 8 May, 2023 CONVERSATION:"
    );
}

/// §6 turn without image: '[speaker] said, "[text]"'.
/// Same literal as Swift goldenPinFormatTurnNoCaption.
#[test]
fn locomo_spec_format_turn_no_caption_golden_pin() {
    let turn = LoCoMoSpecTurn {
        speaker: "Alice".to_string(),
        dia_id:  "D1:1".to_string(),
        text:    "Hey Bob! I visited the art museum today.".to_string(),
        image_caption: None,
    };
    let expected = "Alice said, \"Hey Bob! I visited the art museum today.\"";
    assert_eq!(locomo_format_turn(&turn), expected);
}

/// §6 turn with image: '[speaker] said, "[text]" and shared [caption]'.
/// This is the cross-port golden pin for the image-caption branch.
/// Same literal as Swift goldenPinFormatTurnWithCaption.
#[test]
fn locomo_spec_format_turn_with_caption_golden_pin() {
    let turn = LoCoMoSpecTurn {
        speaker:       "Bob".to_string(),
        dia_id:        "D1:2".to_string(),
        text:          "That sounds wonderful! Which exhibit?".to_string(),
        image_caption: Some("a painting of a sunset over the ocean".to_string()),
    };
    // §6 literal — same string asserted in LoCoMoSpecCorpusCountTests.swift.
    let expected =
        "Bob said, \"That sounds wonderful! Which exhibit?\" \
         and shared a painting of a sunset over the ocean";
    assert_eq!(locomo_format_turn(&turn), expected);
}

// ─────────────────────────────────────────────────────────────────────────────
// Corpus counts — full dataset (locomo10.json)
// ─────────────────────────────────────────────────────────────────────────────

/// Helper: load locomo10.json, returning None when the file is absent.
/// The file lives on the local build machine; CI does not have it.
fn load_full_corpus() -> Option<mcp_benchmarker_rs::locomo_spec_corpus::LoCoMoSpecCorpus> {
    let path = locomo10_path();
    if !path.exists() {
        return None;
    }
    Some(load_locomo_spec_corpus(&path).expect("locomo10.json must load without error"))
}

/// Official dataset total: 1,986 questions across all five categories.
/// §7 deviation #2: category 5 (adversarial) is NOT excluded in the spec lane.
#[test]
fn locomo_spec_total_question_count_1986() {
    let Some(corpus) = load_full_corpus() else { return };
    assert_eq!(
        corpus.total_count(), 1986,
        "spec lane must include all 1,986 questions; got {}", corpus.total_count()
    );
    assert_eq!(corpus.questions.len(), 1986);
}

/// Per-category counts: {1:282, 2:321, 3:96, 4:841, 5:446}.
#[test]
fn locomo_spec_category_counts_match_official() {
    let Some(corpus) = load_full_corpus() else { return };
    let expected: &[(u8, usize)] = &[(1,282),(2,321),(3,96),(4,841),(5,446)];
    for &(cat, exp_count) in expected {
        let got = *corpus.category_counts.get(&cat).unwrap_or(&0);
        assert_eq!(
            got, exp_count,
            "category {cat} count: expected {exp_count}, got {got}"
        );
    }
}

/// Exactly 4 non-cat5 questions with empty evidence lists.
/// §4: evidence recall appends 1 when evidence is empty — these are included, not excluded.
#[test]
fn locomo_spec_empty_evidence_non_adversarial_count() {
    let Some(corpus) = load_full_corpus() else { return };
    let count = corpus.questions.iter()
        .filter(|q| q.category != 5 && q.evidence.is_empty())
        .count();
    assert_eq!(
        count, 4,
        "expected exactly 4 non-cat5 questions with empty evidence; got {count}"
    );
}

/// Category-3 gold answers are stored verbatim at load time.
/// §3: truncation at first ';' happens at scoring time (score_question), not at loading.
#[test]
fn locomo_spec_cat3_gold_answers_preserve_semicolon() {
    let Some(corpus) = load_full_corpus() else { return };
    let cat3: Vec<_> = corpus.questions.iter().filter(|q| q.category == 3).collect();
    assert_eq!(cat3.len(), 96, "expected 96 category-3 questions");
    let with_semi = cat3.iter().filter(|q| {
        q.answer.as_deref().map(|a| a.contains(';')).unwrap_or(false)
    }).count();
    assert!(
        with_semi > 0,
        "at least one cat-3 gold answer must contain ';' — \
         corpus loading must NOT truncate at ';' (scorer does that at scoring time)"
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// §6 Context formatting — sample fixture (always available)
// ─────────────────────────────────────────────────────────────────────────────

/// Load the shared sample fixture; panics if the file is unexpectedly absent
/// (the fixture is committed to the test target directory).
fn load_sample_corpus() -> mcp_benchmarker_rs::locomo_spec_corpus::LoCoMoSpecCorpus {
    let path = sample_path();
    load_locomo_spec_corpus(&path)
        .unwrap_or_else(|e| panic!("locomo_spec_sample.json must load: {e}"))
}

/// loCoMoFormatContext on the sample fixture produces the correct §6 structure.
#[test]
fn locomo_spec_format_context_structure() {
    use mcp_benchmarker_rs::locomo_spec_corpus::locomo_format_context;

    let corpus = load_sample_corpus();
    let conv   = &corpus.conversations[0];
    let ctx    = locomo_format_context(conv);

    // Preamble (official 'wriiten' typo).
    assert!(
        ctx.starts_with("Below is a conversation between two people: Alice and Bob."),
        "context must start with §6 preamble"
    );
    assert!(ctx.contains("wriiten"), "preamble must include the official 'wriiten' typo");

    // Session headers.
    assert!(ctx.contains("DATE: 3:00 pm on 1 Jan, 2024 CONVERSATION:"), "session-1 header");
    assert!(ctx.contains("DATE: 2:00 pm on 10 Jan, 2024 CONVERSATION:"), "session-2 header");

    // Non-image turn.
    assert!(
        ctx.contains("Alice said, \"Hey Bob! I visited the art museum today.\""),
        "non-image turn must use §6 format"
    );

    // Image-caption turn — cross-port golden pin.
    assert!(
        ctx.contains(
            "Bob said, \"That sounds wonderful! Which exhibit?\" \
             and shared a painting of a sunset over the ocean"
        ),
        "image turn must append ' and shared [caption]'"
    );

    // Trailing newline.
    assert!(ctx.ends_with('\n'), "context must end with trailing newline");

    // Chronological order: session-1 header before session-2 header.
    let s1_pos = ctx.find("DATE: 3:00 pm on 1 Jan, 2024").unwrap();
    let s2_pos = ctx.find("DATE: 2:00 pm on 10 Jan, 2024").unwrap();
    assert!(s1_pos < s2_pos, "session-1 must appear before session-2 (chronological order)");
}
