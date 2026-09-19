//! locomo_corpus.rs — LoCoMo JSON loader (Rust twin of `LoCoMoCorpus.swift`).
//!
//! Dataset: snap-research/locomo (ACL 2024).
//! Schema verified 2026-07-26 against locomo10.json from GitHub.
//! URL: <https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json>
//! License: CC BY-NC 4.0 (NonCommercial) — internal diagnostic use only.
//!
//! # Top-level structure
//!
//! JSON array of 10 conversation objects. Per-conversation fields:
//!
//! - `sample_id`:         String  — unique conversation identifier (e.g. `"conv-26"`)
//! - `conversation`:      Object  — heterogeneous dict with dynamic `session_N` / `session_N_date_time` keys
//! - `qa`:                \[Object\] — question-answer annotation list
//! - `event_summary`:     Object  — not used
//! - `observation`:       Object  — not used
//! - `session_summary`:   Object  — not used
//!
//! # `conversation` dict keys
//!
//! - `speaker_a`:               String — name of speaker A
//! - `speaker_b`:               String — name of speaker B
//! - `session_N`:               \[Turn\] — turns for session N (1-based integer)
//! - `session_N_date_time`:      String — timestamp for session N
//!
//! # Turn fields
//!
//! - `speaker`:  String — speaker name
//! - `dia_id`:   String — format "D<session>:<dialog>" (e.g. `"D1:3"`)
//! - `text`:     String — turn content
//! - Optional:  `img_url`, `blip_caption`, `query` — not used
//!
//! # QA fields
//!
//! - `question`:           String  — question text
//! - `answer`:             String/Number/absent — absent for category 5 (adversarial)
//! - `evidence`:           \[String\] — dia_id strings containing the answer
//! - `category`:           Int 1-5
//! - `adversarial_answer`: String  — only in category 5 (not used)
//!
//! # Category exclusion
//!
//! Category 5 (adversarial — no ground-truth answer) is excluded from `questions`,
//! counted in `adversarial_count`. QAs with empty evidence are also excluded.
//! Total statistics (verified 2026-07-26): 1,986 total QAs; 1,542 scoreable; 444 adversarial.

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

// ─── Public types ─────────────────────────────────────────────────────────────

/// One turn in a LoCoMo conversation session.
#[derive(Debug, Clone, PartialEq)]
pub struct LoCoMoTurn {
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    pub speaker: String,
    /// Unique turn identifier: format "D<session>:<dialog>" (e.g. "D1:3").
    pub dia_id: String,
    /// Turn text content.
    pub text: String,
}

/// One session within a LoCoMo conversation.
#[derive(Debug, Clone)]
pub struct LoCoMoSession {
    /// 1-based session number extracted from the `session_N` key.
    pub session_number: usize,
    /// Timestamp string (e.g. "1:56 pm on 8 May, 2023"). May be empty if absent.
    pub date_time: String,
    /// Turns in chronological order within this session.
    pub turns: Vec<LoCoMoTurn>,
}

/// One conversation from the LoCoMo dataset.
#[derive(Debug, Clone)]
pub struct LoCoMoConversation {
    /// Unique conversation identifier (e.g. "conv-26").
    pub sample_id: String,
    /// Name of speaker A.
    pub speaker_a: String,
    /// Name of speaker B.
    pub speaker_b: String,
    /// Sessions sorted by session number.
    pub sessions: Vec<LoCoMoSession>,
}

impl LoCoMoConversation {
    /// Flat list of (session_number, turn) pairs across all sessions, in session order.
    pub fn all_turns(&self) -> Vec<(usize, &LoCoMoTurn)> {
        self.sessions
            .iter()
            .flat_map(|s| s.turns.iter().map(move |t| (s.session_number, t)))
            .collect()
    }
}

/// One scored question from the LoCoMo dataset.
/// Category 5 (adversarial) questions are excluded before reaching this type.
#[derive(Debug, Clone)]
pub struct LoCoMoQuestion {
    /// Synthetic question identifier: "<sample_id>_q<index>" (generated on load).
    pub question_id: String,
    /// Question text.
    pub question: String,
    /// Reference answer (may be a string representation of a number; empty for category 5).
    pub answer: String,
    /// dia_id strings that contain evidence for this answer.
    pub evidence: Vec<String>,
    /// Category: 1=single_hop, 2=temporal, 3=multi_hop, 4=open_domain.
    pub category: u8,
    /// Index into the parent `LoCoMoCorpus.conversations` vec.
    pub conversation_index: usize,
    /// Sample ID for logging (same as the conversation's sample_id).
    pub sample_id: String,
}

impl LoCoMoQuestion {
    /// Human-readable category label for report breakdowns.
    pub fn category_label(&self) -> &'static str {
        match self.category {
            1 => "single_hop",
            2 => "temporal",
            3 => "multi_hop",
            4 => "open_domain",
            _ => "unknown",
        }
    }
}

/// The result of loading the LoCoMo dataset.
#[derive(Debug)]
pub struct LoCoMoCorpus {
    /// All conversations loaded from the file.
    pub conversations: Vec<LoCoMoConversation>,
    /// Non-adversarial questions (categories 1-4), in file order.
    pub questions: Vec<LoCoMoQuestion>,
    /// Number of adversarial questions excluded (category 5 + empty-evidence).
    pub adversarial_count: usize,
}

impl LoCoMoCorpus {
    /// Total questions in the source JSON (`questions.len() + adversarial_count`).
    pub fn total_count(&self) -> usize {
        self.questions.len() + self.adversarial_count
    }
}

/// A load error with a message naming the missing/mistyped field and the context.
/// Parallel to `LoCoMoLoadError` in Swift.
#[derive(Debug)]
pub struct LoCoMoLoadError(pub String);

impl std::fmt::Display for LoCoMoLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LoCoMoLoadError: {}", self.0)
    }
}

impl std::error::Error for LoCoMoLoadError {}

// ─── Internal (Deserialize) types ─────────────────────────────────────────────

/// Raw codec for a single turn. Optional image fields are ignored.
#[derive(Debug, Deserialize)]
struct TurnRaw {
    speaker: String,
    dia_id: String,
    text: String,
    // img_url, blip_caption, query — optional, not used
}

/// Raw codec for one QA pair. The `answer` field can be String, Number, or absent.
#[derive(Debug, Deserialize)]
struct QARaw {
    question: String,
    /// Absent for category 5 (adversarial). We use Value to handle String/Number/absent.
    #[serde(default)]
    answer: Option<Value>,
    evidence: Vec<String>,
    category: u8,
    // adversarial_answer — only in category 5, not used
}

/// Raw top-level sample. The `conversation` field is decoded as a flat JSON Value
/// because it has dynamic `session_N` / `session_N_date_time` keys that serde
/// cannot map to a fixed struct without custom logic.
#[derive(Debug, Deserialize)]
struct SampleRaw {
    sample_id: String,
    conversation: Value,
    qa: Vec<QARaw>,
    // event_summary, observation, session_summary — present, not used
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Loads a LoCoMo dataset JSON file, validates the schema, and returns all
/// conversations and the flat list of scoreable questions.
///
/// # Errors
///
/// Returns [`LoCoMoLoadError`] naming the missing/mistyped field and sample context
/// if validation fails, matching the style of `load_corpus` for LongMemEval.
pub fn load_locomo_corpus(path: &Path) -> Result<LoCoMoCorpus, LoCoMoLoadError> {
    let data = fs::read(path).map_err(|e| {
        LoCoMoLoadError(format!("failed to read {:?}: {}", path, e))
    })?;

    let raw_samples: Vec<SampleRaw> = serde_json::from_slice(&data).map_err(|e| {
        LoCoMoLoadError(format!("LoCoMo JSON decode failed at top level: {}", e))
    })?;

    let mut conversations: Vec<LoCoMoConversation> = Vec::with_capacity(raw_samples.len());
    let mut questions: Vec<LoCoMoQuestion> = Vec::new();
    let mut adversarial_count: usize = 0;

    for (sample_index, raw) in raw_samples.into_iter().enumerate() {
        if raw.sample_id.is_empty() {
            return Err(LoCoMoLoadError(format!(
                "sample[{sample_index}]: missing/empty 'sample_id'"
            )));
        }

        // Decode the conversation dict from Value.
        let conv_val = &raw.conversation;
        let conv_obj = conv_val.as_object().ok_or_else(|| {
            LoCoMoLoadError(format!(
                "sample[{sample_index}] id='{}': 'conversation' is not a JSON object",
                raw.sample_id
            ))
        })?;

        let speaker_a = conv_obj
            .get("speaker_a")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let speaker_b = conv_obj
            .get("speaker_b")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if speaker_a.is_empty() {
            return Err(LoCoMoLoadError(format!(
                "sample[{sample_index}] id='{}': missing/empty 'speaker_a'",
                raw.sample_id
            )));
        }
        if speaker_b.is_empty() {
            return Err(LoCoMoLoadError(format!(
                "sample[{sample_index}] id='{}': missing/empty 'speaker_b'",
                raw.sample_id
            )));
        }

        // Extract sessions: keys matching "session_N" where N is a positive integer.
        // Use BTreeMap keyed by session number to sort ascending.
        let mut sessions_map: BTreeMap<usize, LoCoMoSession> = BTreeMap::new();

        for (key, value) in conv_obj {
            // Skip non-session keys and timestamp/observation/summary variants.
            if !key.starts_with("session_") {
                continue;
            }
            // Skip date_time, observation, summary keys (they end with suffixes after N).
            let suffix = &key["session_".len()..];
            // Check if the entire remaining string is a number.
            let n: usize = match suffix.parse() {
                Ok(n) => n,
                Err(_) => continue, // "session_1_date_time", "session_1_observation", etc.
            };

            // Decode the turns array.
            let turns_raw: Vec<TurnRaw> =
                serde_json::from_value(value.clone()).map_err(|e| {
                    LoCoMoLoadError(format!(
                        "sample[{sample_index}] id='{}' {key}: decode error: {e}",
                        raw.sample_id
                    ))
                })?;

            let turns: Vec<LoCoMoTurn> = turns_raw
                .into_iter()
                .map(|t| LoCoMoTurn {
                    speaker: t.speaker,
                    dia_id: t.dia_id,
                    text: t.text,
                })
                .collect();

            // Look up the date_time for this session number.
            let dt_key = format!("session_{n}_date_time");
            let date_time = conv_obj
                .get(&dt_key)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            sessions_map.insert(
                n,
                LoCoMoSession {
                    session_number: n,
                    date_time,
                    turns,
                },
            );
        }

        if sessions_map.is_empty() {
            return Err(LoCoMoLoadError(format!(
                "sample[{sample_index}] id='{}': 'conversation' has no sessions \
                 (expected session_1 at minimum)",
                raw.sample_id
            )));
        }

        let sessions: Vec<LoCoMoSession> = sessions_map.into_values().collect();
        let conversation_index = conversations.len();
        conversations.push(LoCoMoConversation {
            sample_id: raw.sample_id.clone(),
            speaker_a,
            speaker_b,
            sessions,
        });

        // Parse QA pairs: exclude adversarial (category 5) and empty-evidence.
        for (qa_index, qa) in raw.qa.into_iter().enumerate() {
            if qa.question.is_empty() {
                return Err(LoCoMoLoadError(format!(
                    "sample[{sample_index}] id='{}' qa[{qa_index}]: missing/empty 'question'",
                    raw.sample_id
                )));
            }
            if qa.category < 1 || qa.category > 5 {
                return Err(LoCoMoLoadError(format!(
                    "sample[{sample_index}] id='{}' qa[{qa_index}]: \
                     unexpected 'category' {} (expected 1-5)",
                    raw.sample_id, qa.category
                )));
            }

            if qa.category == 5 {
                adversarial_count += 1;
                continue;
            }
            if qa.evidence.is_empty() {
                // Empty evidence — cannot be scored, count as adversarial-equivalent.
                adversarial_count += 1;
                continue;
            }

            // Normalise answer: String | Number | absent → String.
            let answer_str = match qa.answer {
                Some(Value::String(s)) => s,
                Some(Value::Number(n)) => n.to_string(),
                Some(Value::Null) | None => String::new(),
                Some(other) => other.to_string(),
            };

            let question_id = format!("{}_q{qa_index}", raw.sample_id);
            questions.push(LoCoMoQuestion {
                question_id,
                question: qa.question,
                answer: answer_str,
                evidence: qa.evidence,
                category: qa.category,
                conversation_index,
                sample_id: raw.sample_id.clone(),
            });
        }
    }

    Ok(LoCoMoCorpus {
        conversations,
        questions,
        adversarial_count,
    })
}
