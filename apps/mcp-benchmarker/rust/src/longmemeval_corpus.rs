//! longmemeval_corpus.rs — LongMemEval JSON loader (Rust twin of `LongMemEvalCorpus.swift`).
//!
//! Schema verified 2026-07-25 against xiaowu0162/longmemeval-cleaned on HuggingFace.
//!
//! # Field layout (per-question JSON object)
//!
//! - `question_id`:          String   — unique ID (e.g. `"gpt4_2655b836"`)
//! - `question_type`:        String   — one of: `"knowledge-update"`, `"multi-session"`,
//!   `"single-session-assistant"`, `"single-session-preference"`,
//!   `"single-session-user"`, `"temporal-reasoning"`.
//!   Abstention variants end in `"_abs"` (e.g. `"multi-session_abs"`).
//! - `question`:             String   — question text
//! - `answer`:               String   — reference answer (for LLM-judge QA)
//! - `question_date`:        String   — date/time string (e.g. `"2023/04/10 (Mon) 23:07"`)
//! - `haystack_dates`:       `[String]` — one date string per haystack session
//! - `haystack_session_ids`: `[String]` — session IDs in haystack order
//! - `haystack_sessions`:    `[[Turn]]` — list of sessions, each session a list of turns
//! - `answer_session_ids`:   `[String]` — session IDs containing evidence
//!
//! # Abstention exclusion
//!
//! Questions with `question_type` ending `"_abs"` are excluded from retrieval
//! scoring per upstream methodology.  [`load_corpus`] returns only non-abstention
//! questions; the exclusion count is in [`LmeCorpus::abstention_count`].

use serde::Deserialize;
use std::fs;
use std::path::Path;

// ─── Public types ────────────────────────────────────────────────────────────

/// One turn in a haystack session.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct LmeTurn {
    /// Speaker role: `"user"` or `"assistant"`.
    pub role: String,
    /// Turn content.
    pub content: String,
    /// True when this turn contains evidence for the answer.
    #[serde(rename = "has_answer")]
    pub has_answer: bool,
}

/// One question from the LongMemEval dataset.
#[derive(Debug, Clone)]
pub struct LmeQuestion {
    /// Unique question identifier.
    pub question_id: String,
    /// Question type. Abstention types end in `"_abs"` (excluded from scoring).
    pub question_type: String,
    /// The question text.
    pub question: String,
    /// Reference answer (for LLM-judge QA).
    pub answer: String,
    /// Question date string (dataset format: `"2023/04/10 (Mon) 23:07"`).
    pub question_date: String,
    /// One date string per haystack session, parallel to `haystack_session_ids`.
    pub haystack_dates: Vec<String>,
    /// Session IDs in haystack order, parallel to `haystack_sessions`.
    pub haystack_session_ids: Vec<String>,
    /// Haystack sessions. `haystack_sessions[i]` is a list of turns for session i.
    pub haystack_sessions: Vec<Vec<LmeTurn>>,
    /// Session IDs that contain evidence for the answer (ground truth for recall scoring).
    pub answer_session_ids: Vec<String>,
}

/// The result of a successful load: non-abstention questions and counts.
#[derive(Debug)]
pub struct LmeCorpus {
    /// Non-abstention questions, in dataset order.
    pub questions: Vec<LmeQuestion>,
    /// Number of abstention questions excluded from this corpus.
    pub abstention_count: usize,
}

impl LmeCorpus {
    /// Total questions in the source JSON (`questions.len() + abstention_count`).
    pub fn total_count(&self) -> usize {
        self.questions.len() + self.abstention_count
    }
}

/// A load error with a message naming the missing/mistyped field and the
/// zero-based question index (parallel to [`crate::LMELoadError`] in Swift).
#[derive(Debug)]
pub struct LmeLoadError(pub String);

impl std::fmt::Display for LmeLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LmeLoadError: {}", self.0)
    }
}

impl std::error::Error for LmeLoadError {}

// ─── Internal (Deserialize) type ─────────────────────────────────────────────

/// Codec for the raw per-question JSON. Separate from `LmeQuestion` so that
/// `Deserialize` machinery handles the snake_case mapping and we validate
/// afterwards (matching the Swift loader's post-decode validation pattern).
#[derive(Debug, Deserialize)]
struct LmeQuestionRaw {
    question_id: String,
    question_type: String,
    question: String,
    answer: String,
    question_date: String,
    haystack_dates: Vec<String>,
    haystack_session_ids: Vec<String>,
    haystack_sessions: Vec<Vec<LmeTurn>>,
    answer_session_ids: Vec<String>,
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Loads a LongMemEval variant JSON file, validates the schema, and returns
/// the non-abstention questions plus statistics.
///
/// # Errors
///
/// Returns [`LmeLoadError`] naming the missing/mistyped field and the
/// zero-based question index if validation fails, matching the style of the
/// Swift `loadLMECorpus(from:)` function.
pub fn load_corpus(path: &Path) -> Result<LmeCorpus, LmeLoadError> {
    let data = fs::read(path).map_err(|e| {
        LmeLoadError(format!("failed to read {:?}: {}", path, e))
    })?;

    let raw_questions: Vec<LmeQuestionRaw> = serde_json::from_slice(&data).map_err(|e| {
        LmeLoadError(format!(
            "LongMemEval JSON decode failed at top level: {}",
            e
        ))
    })?;

    let mut questions: Vec<LmeQuestion> = Vec::with_capacity(raw_questions.len());
    let mut abstention_count: usize = 0;

    for (index, raw) in raw_questions.into_iter().enumerate() {
        // Validate required non-empty fields.
        if raw.question_id.is_empty() {
            return Err(LmeLoadError(format!(
                "question[{index}]: missing/empty 'question_id'"
            )));
        }
        if raw.question_type.is_empty() {
            return Err(LmeLoadError(format!(
                "question[{index}]: missing/empty 'question_type'"
            )));
        }
        if raw.question.is_empty() {
            return Err(LmeLoadError(format!(
                "question[{index}] id='{}': missing/empty 'question'",
                raw.question_id
            )));
        }
        // Validate parallel arrays: haystack_session_ids and haystack_sessions
        // must have the same length.
        if raw.haystack_session_ids.len() != raw.haystack_sessions.len() {
            return Err(LmeLoadError(format!(
                "question[{index}] id='{}': 'haystack_session_ids' count ({}) \
                 != 'haystack_sessions' count ({})",
                raw.question_id,
                raw.haystack_session_ids.len(),
                raw.haystack_sessions.len()
            )));
        }
        // Validate parallel arrays: haystack_dates must equal haystack_session_ids.
        if raw.haystack_dates.len() != raw.haystack_session_ids.len() {
            return Err(LmeLoadError(format!(
                "question[{index}] id='{}': 'haystack_dates' count ({}) \
                 != 'haystack_session_ids' count ({})",
                raw.question_id,
                raw.haystack_dates.len(),
                raw.haystack_session_ids.len()
            )));
        }

        // Exclude abstention questions per upstream methodology.
        if raw.question_type.ends_with("_abs") {
            abstention_count += 1;
            continue;
        }

        questions.push(LmeQuestion {
            question_id: raw.question_id,
            question_type: raw.question_type,
            question: raw.question,
            answer: raw.answer,
            question_date: raw.question_date,
            haystack_dates: raw.haystack_dates,
            haystack_session_ids: raw.haystack_session_ids,
            haystack_sessions: raw.haystack_sessions,
            answer_session_ids: raw.answer_session_ids,
        });
    }

    Ok(LmeCorpus {
        questions,
        abstention_count,
    })
}
