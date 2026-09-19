//! lme_spec_corpus.rs — Spec-compliant LongMemEval corpus loader (Rust twin of
//! `LMESpecCorpus.swift`).
//!
//! Dataset: xiaowu0162/LongMemEval (ICLR 2025, arXiv 2410.10813).
//! Schema verified 2026-08-18 against `longmemeval_m_cleaned.json` (500 instances).
//!
//! # Key differences from `longmemeval_corpus.rs`
//!
//! Per `LONGMEMEVAL_OFFICIAL_PROTOCOL.md` §6 row 2:
//!
//! 1. **All 500 instances are loaded** — no abstention filtering at load time.
//!    §1 states abstention questions "ARE evaluated for QA accuracy (with the
//!    abstention prompt). They are skipped only in retrieval metrics."
//!
//! 2. **`is_abstention` uses the §2 selector**: `'_abs' in question_id`.
//!    In `longmemeval_m_cleaned.json`, abstention markers appear only in
//!    `question_id`; `question_type` never ends in `"_abs"` in the real data.
//!
//! 3. **`base_question_type` strips any trailing `"_abs"` from `question_type`**,
//!    mapping onto the fixed six-type list in §4:
//!    `["single-session-user", "single-session-preference",
//!      "single-session-assistant", "multi-session",
//!      "temporal-reasoning", "knowledge-update"]`
//!
//! # Verified counts on `longmemeval_m_cleaned.json` (2026-08-18)
//!
//! - Total:                      500
//! - Abstention (`qid` has `_abs`): 30  (`is_abstention() == true`)
//! - Non-abstention:             470
//! - Per base type (abstentions aggregate under their base type):
//!   - `knowledge-update`:          78
//!   - `multi-session`:            133
//!   - `single-session-assistant`:  56
//!   - `single-session-preference`: 30
//!   - `single-session-user`:       70
//!   - `temporal-reasoning`:       133

use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

// ─── Fixed type list ──────────────────────────────────────────────────────────

/// The fixed six question-type labels from §4 of LONGMEMEVAL_OFFICIAL_PROTOCOL.md,
/// in the order they appear in the official aggregator.
pub const LME_SPEC_BASE_TYPES: &[&str] = &[
    "single-session-user",
    "single-session-preference",
    "single-session-assistant",
    "multi-session",
    "temporal-reasoning",
    "knowledge-update",
];

// ─── Public types ─────────────────────────────────────────────────────────────

/// One turn in a haystack session.
///
/// Parallel to `LmeTurn` in `longmemeval_corpus.rs`; redeclared to avoid a
/// cross-module dependency while keeping identical semantics and JSON shape.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct LmeSpecTurn {
    /// Speaker role: `"user"` or `"assistant"`.
    pub role: String,
    /// Turn content.
    pub content: String,
    /// True when this turn contains evidence for the answer.
    /// Present in the fetched cleaned fixtures (and in hand-authored
    /// synthetic fixtures) — defaults to `false` when missing.
    #[serde(rename = "has_answer", default)]
    pub has_answer: bool,
}

/// One question from the LongMemEval dataset, loaded in spec-compliant mode.
///
/// All stored fields are identical to `LmeQuestion` in `longmemeval_corpus.rs`.
/// The spec-specific additions are [`is_abstention`] and [`base_question_type`].
#[derive(Debug, Clone)]
pub struct LmeSpecQuestion {
    /// Unique question identifier (e.g. `"gpt4_2655b836"` or `"gpt4_ab12_abs"`).
    pub question_id: String,
    /// Raw `question_type` from JSON (e.g. `"multi-session"`).
    /// In `longmemeval_m_cleaned.json` this is never suffixed with `"_abs"`.
    pub question_type: String,
    /// The question text.
    pub question: String,
    /// Reference answer string.
    /// For `single-session-preference`: the rubric for desired personalised response.
    /// For abstention questions: the explanation of unanswerability.
    /// Normalised to `String` (numeric oracle-variant answers are coerced).
    pub answer: String,
    /// Question date string (dataset format: `"2023/04/10 (Mon) 23:07"`).
    pub question_date: String,
    /// One date string per haystack session, parallel to `haystack_session_ids`.
    pub haystack_dates: Vec<String>,
    /// Session IDs in haystack order, parallel to `haystack_sessions`.
    pub haystack_session_ids: Vec<String>,
    /// Haystack sessions. `haystack_sessions[i]` is the turn list for session i.
    pub haystack_sessions: Vec<Vec<LmeSpecTurn>>,
    /// Session IDs containing evidence for the answer.
    /// Empty for abstention questions (no ground-truth location).
    pub answer_session_ids: Vec<String>,
}

impl LmeSpecQuestion {
    /// True when `"_abs"` appears anywhere in `question_id`.
    ///
    /// Per LONGMEMEVAL_OFFICIAL_PROTOCOL.md §2:
    /// `abstention = '_abs' in question_id`.
    ///
    /// Abstention instances:
    /// - Are judged with the abstention prompt (§2 abstention block).
    /// - Are counted separately in §4 aggregation (abstention accuracy).
    /// - Are excluded from retrieval metrics (§5).
    /// - Are NOT excluded from QA accuracy scoring (§1, §6 row 2 fix).
    pub fn is_abstention(&self) -> bool {
        self.question_id.contains("_abs")
    }

    /// `question_type` with any trailing `"_abs"` suffix stripped.
    ///
    /// Maps onto the fixed six-type list from §4 (`LME_SPEC_BASE_TYPES`).
    ///
    /// In `longmemeval_m_cleaned.json`, `question_type` never carries `"_abs"`,
    /// so `base_question_type()` equals `question_type` for all 500 real instances.
    /// The strip exists for forward compatibility with dataset variants (and the
    /// synthetic test fixture) that carry `"_abs"` in `question_type`.
    pub fn base_question_type(&self) -> &str {
        let qt = self.question_type.as_str();
        qt.strip_suffix("_abs").unwrap_or(qt)
    }
}

/// The result of loading the LongMemEval dataset in spec-compliant mode.
///
/// All instances are in `questions` — abstention and non-abstention combined.
/// No filtering occurs at load time. Use `is_abstention()` on each question to
/// identify abstention instances for judge-prompt selection (§2) and
/// retrieval-metric exclusion (§5).
#[derive(Debug)]
pub struct LmeSpecCorpus {
    /// All questions in dataset order, abstention and non-abstention combined.
    pub questions: Vec<LmeSpecQuestion>,
}

impl LmeSpecCorpus {
    /// Count of questions where `is_abstention() == true`.
    /// In `longmemeval_m_cleaned.json`: 30 out of 500.
    pub fn abstention_count(&self) -> usize {
        self.questions.iter().filter(|q| q.is_abstention()).count()
    }

    /// Total question count. Always equals `questions.len()` (no filtering).
    pub fn total_count(&self) -> usize {
        self.questions.len()
    }

    /// Counts per `base_question_type()` across all instances.
    ///
    /// Abstention instances aggregate under their base type, matching the
    /// §4 aggregation rule. For `longmemeval_m_cleaned.json` the expected map:
    /// `{ "knowledge-update": 78, "multi-session": 133,
    ///    "single-session-assistant": 56, "single-session-preference": 30,
    ///    "single-session-user": 70, "temporal-reasoning": 133 }`
    pub fn counts_by_base_type(&self) -> HashMap<&str, usize> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for q in &self.questions {
            *counts.entry(q.base_question_type()).or_insert(0) += 1;
        }
        counts
    }
}

/// A load error with a message naming the missing/mistyped field and the
/// zero-based question index. Parallel to [`crate::longmemeval_corpus::LmeLoadError`].
#[derive(Debug)]
pub struct LmeSpecLoadError(pub String);

impl std::fmt::Display for LmeSpecLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LmeSpecLoadError: {}", self.0)
    }
}

impl std::error::Error for LmeSpecLoadError {}

// ─── Internal decoder type ────────────────────────────────────────────────────

/// Raw JSON codec for one question entry.
///
/// Identical in schema to `LmeQuestionRaw` in `longmemeval_corpus.rs`. It is
/// redeclared here to keep modules independent. `answer` uses
/// `serde_json::Value` to handle String | Number | absent/null and is coerced
/// to `String` after decode — matching the Swift loader's coercion logic.
#[derive(Debug, Deserialize)]
struct LmeSpecQuestionRaw {
    question_id: String,
    question_type: String,
    question: String,
    /// Flexible type: String | Number | absent/null in the oracle variant.
    /// Coerced to String after decode; not used in retrieval scoring.
    #[serde(default)]
    answer: Option<Value>,
    question_date: String,
    haystack_dates: Vec<String>,
    haystack_session_ids: Vec<String>,
    haystack_sessions: Vec<Vec<LmeSpecTurn>>,
    answer_session_ids: Vec<String>,
}

impl LmeSpecQuestionRaw {
    /// Coerce `answer` (String | Number | null | absent) to an owned String.
    ///
    /// Matches the coercion in `LMESpecQuestionRaw.init(from:)` in Swift:
    /// numeric answers from the oracle variant become their decimal representation;
    /// absent or null becomes an empty string.
    fn answer_string(&self) -> String {
        match &self.answer {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Number(n)) => n.to_string(),
            Some(Value::Null) | None => String::new(),
            Some(other) => other.to_string(),
        }
    }
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Loads a LongMemEval variant JSON in spec-compliant mode: ALL instances,
/// including abstention questions (`question_id` contains `"_abs"`).
///
/// Per LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1 and §6 row 2:
///
/// Abstention questions ARE scored with the abstention judge prompt (§2).
/// They ARE included in overall and per-type QA accuracy (§4).
/// They are only excluded from retrieval metrics (§5).
///
/// This function fixes the deviation in `load_corpus` (`longmemeval_corpus.rs`),
/// which excluded `"_abs"` instances by checking `question_type.ends_with("_abs")`.
/// The correct spec selector is `"_abs" in question_id` (via `is_abstention()`).
///
/// # Errors
///
/// Returns [`LmeSpecLoadError`] naming the missing/mistyped field and the
/// zero-based question index if validation fails. Parallel error style to
/// `load_corpus` in `longmemeval_corpus.rs` and `load_locomo_spec_corpus` in
/// `LoCoMoSpecCorpus.swift`.
pub fn load_spec_corpus(path: &Path) -> Result<LmeSpecCorpus, LmeSpecLoadError> {
    let data = fs::read(path).map_err(|e| {
        LmeSpecLoadError(format!("LMESpec: failed to read {:?}: {}", path, e))
    })?;

    let raw_questions: Vec<LmeSpecQuestionRaw> = serde_json::from_slice(&data).map_err(|e| {
        LmeSpecLoadError(format!("LMESpec JSON decode failed at top level: {}", e))
    })?;

    let mut questions: Vec<LmeSpecQuestion> = Vec::with_capacity(raw_questions.len());

    for (index, raw) in raw_questions.into_iter().enumerate() {
        // Validate required non-empty fields (parallel to load_corpus validation).
        if raw.question_id.is_empty() {
            return Err(LmeSpecLoadError(format!(
                "question[{index}]: missing/empty 'question_id'"
            )));
        }
        if raw.question_type.is_empty() {
            return Err(LmeSpecLoadError(format!(
                "question[{index}]: missing/empty 'question_type'"
            )));
        }
        if raw.question.is_empty() {
            return Err(LmeSpecLoadError(format!(
                "question[{index}] id='{}': missing/empty 'question'",
                raw.question_id
            )));
        }
        // Validate parallel array lengths.
        if raw.haystack_session_ids.len() != raw.haystack_sessions.len() {
            return Err(LmeSpecLoadError(format!(
                "question[{index}] id='{}': 'haystack_session_ids' count ({}) \
                 != 'haystack_sessions' count ({})",
                raw.question_id,
                raw.haystack_session_ids.len(),
                raw.haystack_sessions.len()
            )));
        }
        if raw.haystack_dates.len() != raw.haystack_session_ids.len() {
            return Err(LmeSpecLoadError(format!(
                "question[{index}] id='{}': 'haystack_dates' count ({}) \
                 != 'haystack_session_ids' count ({})",
                raw.question_id,
                raw.haystack_dates.len(),
                raw.haystack_session_ids.len()
            )));
        }

        // ALL instances are appended — no abstention filtering.
        // is_abstention() and base_question_type() are methods, not stored state.
        // answer_string() borrows raw.answer; resolve it before any field moves.
        let answer = raw.answer_string();
        questions.push(LmeSpecQuestion {
            question_id:         raw.question_id,
            question_type:       raw.question_type,
            question:            raw.question,
            answer,
            question_date:       raw.question_date,
            haystack_dates:      raw.haystack_dates,
            haystack_session_ids: raw.haystack_session_ids,
            haystack_sessions:   raw.haystack_sessions,
            answer_session_ids:  raw.answer_session_ids,
        });
    }

    Ok(LmeSpecCorpus { questions })
}

// ─── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    /// Resolve `benchmarks/Tests/mcp-benchmarkerTests/<filename>` relative to
    /// CARGO_MANIFEST_DIR (`benchmarks/rust/`). The fixture is shared with the
    /// Swift test suite.
    fn spec_fixture_path(filename: &str) -> PathBuf {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        // CARGO_MANIFEST_DIR = benchmarks/rust/
        // parent() → benchmarks/
        manifest_dir
            .parent()
            .expect("benchmarks/ parent must exist")
            .join("Tests")
            .join("mcp-benchmarkerTests")
            .join(filename)
    }

    /// Write bytes to a temp file and return its path. The caller is responsible
    /// for deleting the file after use (or relying on OS cleanup).
    fn write_temp(name: &str, content: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(name);
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content).unwrap();
        path
    }

    // ── Happy path ────────────────────────────────────────────────────────────

    #[test]
    fn loads_all_instances_from_spec_fixture() {
        // Per §1 and §6 row 2: all 3 questions are loaded (no filtering).
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        assert_eq!(corpus.total_count(), 3, "expected 3 questions, got {}", corpus.total_count());
        assert_eq!(corpus.questions.len(), 3);
    }

    #[test]
    fn abstention_count_uses_question_id_selector() {
        // spec_002_abs has '_abs' in question_id → 1 abstention.
        // spec_001 and spec_003 do not → not abstention, even though
        // spec_003 has '_abs' in question_type.
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        assert_eq!(
            corpus.abstention_count(), 1,
            "abstention_count should be 1, got {}",
            corpus.abstention_count()
        );
    }

    #[test]
    fn spec_001_is_non_abstention() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        let q = corpus.questions.iter().find(|q| q.question_id == "spec_001")
            .expect("spec_001 must be present");

        assert_eq!(q.question_type, "single-session-user");
        assert_eq!(q.answer, "Blue");
        // §2 selector: '_abs' not in question_id "spec_001".
        assert!(!q.is_abstention(), "spec_001 should not be abstention");
        // No suffix to strip.
        assert_eq!(q.base_question_type(), "single-session-user");
    }

    #[test]
    fn spec_002_abs_is_abstention_via_question_id() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        let q = corpus.questions.iter().find(|q| q.question_id == "spec_002_abs")
            .expect("spec_002_abs must be present");

        // question_type is the base type (real dataset has no '_abs' in question_type).
        assert_eq!(q.question_type, "multi-session");
        // §2: '_abs' in question_id "spec_002_abs" → abstention.
        assert!(q.is_abstention(), "spec_002_abs should be abstention");
        // No suffix to strip from question_type.
        assert_eq!(q.base_question_type(), "multi-session");
    }

    #[test]
    fn spec_003_not_abstention_despite_question_type_suffix() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        let q = corpus.questions.iter().find(|q| q.question_id == "spec_003")
            .expect("spec_003 must be present");

        assert_eq!(q.question_type, "temporal-reasoning_abs");
        // §2 selector uses question_id "spec_003" — no '_abs' → NOT abstention.
        assert!(!q.is_abstention(), "spec_003 should not be abstention (qid has no '_abs')");
        // base_question_type strips the suffix from question_type.
        assert_eq!(q.base_question_type(), "temporal-reasoning");
    }

    #[test]
    fn base_types_are_in_fixed_list() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        for q in &corpus.questions {
            assert!(
                LME_SPEC_BASE_TYPES.contains(&q.base_question_type()),
                "base_question_type '{}' for qid '{}' is not in the §4 fixed type list",
                q.base_question_type(), q.question_id
            );
        }
    }

    #[test]
    fn counts_by_base_type_sums_all_questions() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        let counts = corpus.counts_by_base_type();
        // spec_001 → single-session-user
        assert_eq!(counts.get("single-session-user").copied().unwrap_or(0), 1);
        // spec_002_abs → multi-session (abstention aggregates under base type per §4)
        assert_eq!(counts.get("multi-session").copied().unwrap_or(0), 1);
        // spec_003 → temporal-reasoning (suffix stripped from question_type)
        assert_eq!(counts.get("temporal-reasoning").copied().unwrap_or(0), 1);
        // Total must equal question count.
        let total: usize = counts.values().sum();
        assert_eq!(total, corpus.total_count());
    }

    #[test]
    fn haystack_parallel_arrays_decode_correctly() {
        let path = spec_fixture_path("lme_spec_sample.json");
        let corpus = load_spec_corpus(&path).expect("spec fixture should load");
        let q = corpus.questions.iter().find(|q| q.question_id == "spec_001")
            .expect("spec_001 must be present");

        assert_eq!(q.haystack_session_ids.len(), q.haystack_sessions.len());
        assert_eq!(q.haystack_dates.len(), q.haystack_session_ids.len());
        assert_eq!(q.haystack_session_ids, vec!["sess_001"]);

        let session = q.haystack_sessions.first().expect("session_0 must exist");
        assert_eq!(session.len(), 2);
        assert_eq!(session[0].role, "user");
        assert!(session[0].has_answer);
        assert_eq!(session[1].role, "assistant");
        assert!(!session[1].has_answer);
    }

    #[test]
    fn nonexistent_path_returns_error() {
        let path = std::path::Path::new("/nonexistent/lme_spec_missing.json");
        let result = load_spec_corpus(path);
        assert!(result.is_err(), "expected error for nonexistent path");
    }

    // ── Schema validation ─────────────────────────────────────────────────────

    #[test]
    fn missing_question_id_returns_error_naming_field_and_index() {
        let json = br#"[{"question_id": "", "question_type": "single-session-user",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": [], "haystack_session_ids": [],
          "haystack_sessions": [], "answer_session_ids": []}]"#;
        let path = write_temp("lme_spec_bad_id_rs.json", json);
        let err = load_spec_corpus(&path).expect_err("should fail for empty question_id");
        let msg = err.0;
        assert!(msg.contains("question_id"), "error should name 'question_id': {msg}");
        assert!(msg.contains("question[0]"), "error should name index 0: {msg}");
    }

    #[test]
    fn parallel_array_mismatch_returns_error() {
        let json = br#"[{"question_id": "x1", "question_type": "multi-session",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": ["2024/01/01 (Mon) 00:00"],
          "haystack_session_ids": ["sess1"],
          "haystack_sessions": [],
          "answer_session_ids": []}]"#;
        let path = write_temp("lme_spec_bad_parallel_rs.json", json);
        let err = load_spec_corpus(&path).expect_err("should fail for parallel-array mismatch");
        let msg = err.0;
        assert!(msg.contains("haystack_session_ids"), "error should name field: {msg}");
        assert!(msg.contains("question[0]"), "error should name index 0: {msg}");
    }

    #[test]
    fn all_abstention_qids_all_loaded() {
        // Spec fix: original loader excluded '_abs' types; spec corpus includes all.
        let json = br#"[
          {"question_id": "abs_q1_abs", "question_type": "multi-session",
           "question": "Did X happen?", "answer": "No evidence.",
           "question_date": "2024/01/01 (Mon) 00:00",
           "haystack_dates": [], "haystack_session_ids": [],
           "haystack_sessions": [], "answer_session_ids": []},
          {"question_id": "abs_q2_abs", "question_type": "knowledge-update",
           "question": "What is Y?", "answer": "Not mentioned.",
           "question_date": "2024/01/02 (Tue) 00:00",
           "haystack_dates": [], "haystack_session_ids": [],
           "haystack_sessions": [], "answer_session_ids": []}
        ]"#;
        let path = write_temp("lme_spec_all_abs_rs.json", json);
        let corpus = load_spec_corpus(&path).expect("all-abstention file should load");
        assert_eq!(corpus.questions.len(), 2, "both questions should be loaded");
        assert_eq!(corpus.abstention_count(), 2);
        assert_eq!(corpus.total_count(), 2);
    }

    #[test]
    fn empty_array_yields_empty_corpus() {
        let json = b"[]";
        let path = write_temp("lme_spec_empty_rs.json", json);
        let corpus = load_spec_corpus(&path).expect("empty array should load");
        assert_eq!(corpus.questions.len(), 0);
        assert_eq!(corpus.abstention_count(), 0);
        assert_eq!(corpus.total_count(), 0);
    }
}
