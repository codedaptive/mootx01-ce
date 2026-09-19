//! locomo_spec_corpus.rs — Spec-compliant LoCoMo corpus loader (Rust twin of
//! `LoCoMoSpecCorpus.swift`).
//!
//! Dataset: snap-research/locomo (ACL 2024, arXiv 2402.17753).
//! Schema verified 2026-08-18 against locomo10.json.
//! License: CC BY-NC 4.0 (NonCommercial) — internal diagnostic use only.
//!
//! # Key differences from `locomo_corpus.rs`
//!
//! 1. **All 1,986 questions included** — category 5 (adversarial) and non-cat5 questions
//!    with empty evidence lists are NOT excluded. The locomo-spec lane scores all categories
//!    per §3 of LOCOMO_OFFICIAL_PROTOCOL.md.
//!
//! 2. **Image captions preserved** — turns with a `blip_caption` field have their
//!    caption in `image_caption: Option<String>`. The §6 context-formatting function
//!    appends `" and shared [caption]"` for such turns.
//!
//! 3. **Context-formatting helpers** — free functions implementing the §6 format
//!    verbatim. Output is byte-identical to the Swift port for the same conversation.
//!
//! # Expected totals (locomo10.json, verified 2026-08-18)
//!
//! - Total QAs:   1,986
//! - Category 1:    282  (single_hop)
//! - Category 2:    321  (temporal)
//! - Category 3:     96  (multi_hop)
//! - Category 4:    841  (open_domain)
//! - Category 5:    446  (adversarial — no gold answer, scored by abstention per §3)
//! - Non-cat5 QAs with empty evidence: 4 (included; recall appends 1 per §4)

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

// ─── Public types ─────────────────────────────────────────────────────────────

/// One turn in a LoCoMo conversation session, with optional image caption.
///
/// The `image_caption` field is populated from the JSON `blip_caption` key.
/// Per §6 context formatting: '[speaker] said, "[text]"' with
/// ' and shared [caption]' appended when `image_caption` is Some.
#[derive(Debug, Clone, PartialEq)]
pub struct LoCoMoSpecTurn {
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    pub speaker: String,
    /// Unique turn identifier: format "D<session>:<dialog>" (e.g. "D1:3").
    pub dia_id: String,
    /// Turn text content.
    pub text: String,
    /// BLIP-generated image caption. None when the turn contains no image.
    /// Source field: `blip_caption` in the JSON.
    pub image_caption: Option<String>,
}

/// One session within a LoCoMo conversation.
#[derive(Debug, Clone)]
pub struct LoCoMoSpecSession {
    /// 1-based session number extracted from the `session_N` key.
    pub session_number: usize,
    /// Timestamp string (e.g. "1:56 pm on 8 May, 2023"). Empty if absent.
    pub date_time: String,
    /// Turns in chronological order within this session.
    pub turns: Vec<LoCoMoSpecTurn>,
}

/// One conversation from the LoCoMo dataset: speakers, sessions, and a
/// convenience all-turns view.
#[derive(Debug, Clone)]
pub struct LoCoMoSpecConversation {
    /// Unique conversation identifier (e.g. "conv-26").
    pub sample_id: String,
    /// Name of speaker A.
    pub speaker_a: String,
    /// Name of speaker B.
    pub speaker_b: String,
    /// Sessions sorted by session number (chronological).
    pub sessions: Vec<LoCoMoSpecSession>,
}

impl LoCoMoSpecConversation {
    /// Flat list of (session_number, &turn) across all sessions, in session order.
    pub fn all_turns(&self) -> Vec<(usize, &LoCoMoSpecTurn)> {
        self.sessions
            .iter()
            .flat_map(|s| s.turns.iter().map(move |t| (s.session_number, t)))
            .collect()
    }
}

/// One question from the LoCoMo dataset — ALL categories 1–5 included.
///
/// Category 5 (adversarial) questions have `answer = None` and
/// `adversarial_answer = Some(...)`. Categories 1–4 always have a gold answer.
/// Questions with empty `evidence` are included (4 exist in the full dataset;
/// evidence recall appends 1 per §4 when evidence is empty).
#[derive(Debug, Clone)]
pub struct LoCoMoSpecQuestion {
    /// Synthetic identifier: "<sample_id>_q<qa_index>" (generated on load).
    pub question_id: String,
    /// Question text.
    pub question: String,
    /// Gold answer. None only for category 5 (absent from JSON).
    /// For category 3 the scorer truncates at the first ';' per §3 at scoring time;
    /// the raw answer is stored here verbatim.
    pub answer: Option<String>,
    /// Plausible-but-wrong answer. Some only for category 5.
    pub adversarial_answer: Option<String>,
    /// dia_id strings containing answer evidence. May be empty for 4 non-cat5 questions.
    pub evidence: Vec<String>,
    /// Question type: 1=single_hop, 2=temporal, 3=multi_hop, 4=open_domain,
    /// 5=adversarial.
    pub category: u8,
    /// Index into the parent `LoCoMoSpecCorpus.conversations` vec.
    pub conversation_index: usize,
    /// Sample ID of the parent conversation (for logging).
    pub sample_id: String,
}

impl LoCoMoSpecQuestion {
    /// Human-readable category label for report breakdowns.
    pub fn category_label(&self) -> &'static str {
        match self.category {
            1 => "single_hop",
            2 => "temporal",
            3 => "multi_hop",
            4 => "open_domain",
            5 => "adversarial",
            _ => "unknown",
        }
    }
}

/// The result of loading the LoCoMo dataset in spec-compliant mode.
///
/// All 1,986 questions are present in `questions`; nothing is excluded.
/// `category_counts` is keyed 1–5 and gives the raw count per category.
#[derive(Debug)]
pub struct LoCoMoSpecCorpus {
    /// All conversations loaded from the file (10 in the standard dataset).
    pub conversations: Vec<LoCoMoSpecConversation>,
    /// All questions from the file — categories 1–5, empty-evidence included.
    pub questions: Vec<LoCoMoSpecQuestion>,
    /// Questions per category (key = category 1–5, value = count).
    /// Verified against the official dataset: {1:282, 2:321, 3:96, 4:841, 5:446}.
    pub category_counts: HashMap<u8, usize>,
}

impl LoCoMoSpecCorpus {
    /// Total questions in the corpus (`questions.len()`).
    pub fn total_count(&self) -> usize {
        self.questions.len()
    }
}

/// A load error with a message naming the missing/mistyped field and context.
/// Parallel to `LoCoMoSpecLoadError` in Swift.
#[derive(Debug)]
pub struct LoCoMoSpecLoadError(pub String);

impl std::fmt::Display for LoCoMoSpecLoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "LoCoMoSpecLoadError: {}", self.0)
    }
}

impl std::error::Error for LoCoMoSpecLoadError {}

// ─── Internal (Deserialize) types ─────────────────────────────────────────────

/// Raw codec for a single turn. Captures `blip_caption` for §6 context formatting.
#[derive(Debug, Deserialize)]
struct TurnSpecRaw {
    speaker: String,
    dia_id: String,
    text: String,
    /// Optional BLIP-generated image caption (blip_caption JSON field).
    #[serde(default)]
    blip_caption: Option<String>,
    // img_url, query — optional, not used
}

/// Raw codec for one QA pair. `answer` can be String, Number, or absent (cat 5).
/// `adversarial_answer` is present only for category 5.
#[derive(Debug, Deserialize)]
struct QASpecRaw {
    question: String,
    /// Absent for category 5 or when null. Use Value to handle String/Number/absent.
    #[serde(default)]
    answer: Option<Value>,
    evidence: Vec<String>,
    category: u8,
    /// Plausible-but-wrong answer, present only for category 5.
    #[serde(default)]
    adversarial_answer: Option<String>,
}

/// Raw top-level sample. `conversation` is decoded as flat Value (dynamic session keys).
#[derive(Debug, Deserialize)]
struct SampleSpecRaw {
    sample_id: String,
    conversation: Value,
    qa: Vec<QASpecRaw>,
    // event_summary, observation, session_summary — present, not used
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Loads a LoCoMo dataset JSON file in spec-compliant mode: ALL questions included,
/// image captions preserved, no category or evidence exclusions.
///
/// Per LOCOMO_OFFICIAL_PROTOCOL.md §3 and §7 deviation note #2:
/// category 5 is scored (not excluded); 4 non-cat5 questions with empty evidence
/// are included (evidence recall appends 1 per §4 when evidence is empty).
///
/// # Errors
///
/// Returns [`LoCoMoSpecLoadError`] naming the missing/mistyped field and sample
/// context if validation fails.
pub fn load_locomo_spec_corpus(path: &Path) -> Result<LoCoMoSpecCorpus, LoCoMoSpecLoadError> {
    let data = fs::read(path).map_err(|e| {
        LoCoMoSpecLoadError(format!("failed to read {:?}: {}", path, e))
    })?;

    let raw_samples: Vec<SampleSpecRaw> = serde_json::from_slice(&data).map_err(|e| {
        LoCoMoSpecLoadError(format!("LoCoMoSpec JSON decode failed at top level: {}", e))
    })?;

    let mut conversations: Vec<LoCoMoSpecConversation> = Vec::with_capacity(raw_samples.len());
    let mut questions: Vec<LoCoMoSpecQuestion> = Vec::new();
    let mut category_counts: HashMap<u8, usize> = HashMap::new();

    for (sample_index, raw) in raw_samples.into_iter().enumerate() {
        if raw.sample_id.is_empty() {
            return Err(LoCoMoSpecLoadError(format!(
                "sample[{sample_index}]: missing/empty 'sample_id'"
            )));
        }

        let conv_val = &raw.conversation;
        let conv_obj = conv_val.as_object().ok_or_else(|| {
            LoCoMoSpecLoadError(format!(
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
            return Err(LoCoMoSpecLoadError(format!(
                "sample[{sample_index}] id='{}': missing/empty 'speaker_a'",
                raw.sample_id
            )));
        }
        if speaker_b.is_empty() {
            return Err(LoCoMoSpecLoadError(format!(
                "sample[{sample_index}] id='{}': missing/empty 'speaker_b'",
                raw.sample_id
            )));
        }

        // Extract sessions: keys matching "session_N" (numeric suffix only).
        // BTreeMap ensures sessions are sorted by number ascending (chronological).
        let mut sessions_map: BTreeMap<usize, LoCoMoSpecSession> = BTreeMap::new();

        for (key, value) in conv_obj {
            if !key.starts_with("session_") {
                continue;
            }
            let suffix = &key["session_".len()..];
            // Only process keys whose entire remaining string is a plain integer
            // (skips session_N_date_time, session_N_observation, session_N_summary).
            let n: usize = match suffix.parse() {
                Ok(n) => n,
                Err(_) => continue,
            };

            // Decode the turns array for this session, capturing blip_caption.
            let turns_raw: Vec<TurnSpecRaw> =
                serde_json::from_value(value.clone()).map_err(|e| {
                    LoCoMoSpecLoadError(format!(
                        "sample[{sample_index}] id='{}' {key}: decode error: {e}",
                        raw.sample_id
                    ))
                })?;

            let turns: Vec<LoCoMoSpecTurn> = turns_raw
                .into_iter()
                .map(|t| LoCoMoSpecTurn {
                    speaker: t.speaker,
                    dia_id: t.dia_id,
                    text: t.text,
                    image_caption: t.blip_caption,
                })
                .collect();

            let dt_key = format!("session_{n}_date_time");
            let date_time = conv_obj
                .get(&dt_key)
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            sessions_map.insert(
                n,
                LoCoMoSpecSession {
                    session_number: n,
                    date_time,
                    turns,
                },
            );
        }

        if sessions_map.is_empty() {
            return Err(LoCoMoSpecLoadError(format!(
                "sample[{sample_index}] id='{}': 'conversation' has no sessions \
                 (expected session_1 at minimum)",
                raw.sample_id
            )));
        }

        let sessions: Vec<LoCoMoSpecSession> = sessions_map.into_values().collect();
        let conversation_index = conversations.len();
        conversations.push(LoCoMoSpecConversation {
            sample_id: raw.sample_id.clone(),
            speaker_a,
            speaker_b,
            sessions,
        });

        // Include ALL QA pairs — no exclusion for category 5 or empty evidence.
        for (qa_index, qa) in raw.qa.into_iter().enumerate() {
            if qa.question.is_empty() {
                return Err(LoCoMoSpecLoadError(format!(
                    "sample[{sample_index}] id='{}' qa[{qa_index}]: missing/empty 'question'",
                    raw.sample_id
                )));
            }
            if qa.category < 1 || qa.category > 5 {
                return Err(LoCoMoSpecLoadError(format!(
                    "sample[{sample_index}] id='{}' qa[{qa_index}]: \
                     unexpected 'category' {} (expected 1-5)",
                    raw.sample_id, qa.category
                )));
            }

            // Normalise answer: String | Number | absent → String | None.
            let answer_str = match qa.answer {
                Some(Value::String(s)) => Some(s),
                Some(Value::Number(n)) => Some(n.to_string()),
                Some(Value::Null) | None => None,
                Some(other) => Some(other.to_string()),
            };

            let question_id = format!("{}_q{qa_index}", raw.sample_id);
            questions.push(LoCoMoSpecQuestion {
                question_id,
                question: qa.question,
                answer: answer_str,
                adversarial_answer: qa.adversarial_answer,
                evidence: qa.evidence,
                category: qa.category,
                conversation_index,
                sample_id: raw.sample_id.clone(),
            });
            *category_counts.entry(qa.category).or_insert(0) += 1;
        }
    }

    Ok(LoCoMoSpecCorpus {
        conversations,
        questions,
        category_counts,
    })
}

// ─── Context Formatting (§6) ──────────────────────────────────────────────────
//
// Official prompt context per LOCOMO_OFFICIAL_PROTOCOL.md §6.
// Output is byte-identical to the Swift `loCoMoFormatContext` for the same input.

/// Returns the official conversation preamble with speaker names substituted.
///
/// Verbatim from §6 (including the official typo 'wriiten'):
/// "Below is a conversation between two people: {A} and {B}. The conversation
///  takes place over multiple days and the date of each conversation is wriiten
///  at the beginning of the conversation."
///
/// No trailing newline is included.
pub fn locomo_conversation_preamble(speaker_a: &str, speaker_b: &str) -> String {
    // §6 preamble — 'wriiten' typo is in the official prompt; reproduce verbatim.
    format!(
        "Below is a conversation between two people: {} and {}. \
         The conversation takes place over multiple days and the date of each \
         conversation is wriiten at the beginning of the conversation.",
        speaker_a, speaker_b
    )
}

/// Returns the session header line per §6 format.
///
/// Format: `"DATE: [dateTime] CONVERSATION:"`  (no trailing newline).
pub fn locomo_session_header(date_time: &str) -> String {
    format!("DATE: {} CONVERSATION:", date_time)
}

/// Returns the formatted turn line per §6 format.
///
/// Format: `'[speaker] said, "[text]"'` with `' and shared [caption]'` appended
/// when the turn has an image_caption (blip_caption in JSON).  No trailing newline.
pub fn locomo_format_turn(turn: &LoCoMoSpecTurn) -> String {
    let mut line = format!("{} said, \"{}\"", turn.speaker, turn.text);
    // §6: append ' and shared [caption]' for image turns.
    if let Some(ref caption) = turn.image_caption {
        line.push_str(" and shared ");
        line.push_str(caption);
    }
    line
}

/// Returns the full formatted context for a conversation per §6.
///
/// Structure:
/// ```text
/// {preamble}\n
/// DATE: [session1_datetime] CONVERSATION:\n
/// [turn]\n
/// ...\n
/// DATE: [session2_datetime] CONVERSATION:\n
/// ...
/// ```
///
/// Sessions are in chronological (ascending session-number) order, matching the
/// sorted order in `LoCoMoSpecConversation.sessions`. The string ends with a
/// trailing newline after the last turn.
///
/// Output is byte-identical to the Swift `loCoMoFormatContext` for the same input.
pub fn locomo_format_context(conversation: &LoCoMoSpecConversation) -> String {
    let mut out = locomo_conversation_preamble(&conversation.speaker_a, &conversation.speaker_b);
    out.push('\n');
    for session in &conversation.sessions {
        out.push_str(&locomo_session_header(&session.date_time));
        out.push('\n');
        for turn in &session.turns {
            out.push_str(&locomo_format_turn(turn));
            out.push('\n');
        }
    }
    out
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    // Path to the shared synthetic fixture used by both Swift and Rust tests.
    // Relative to this source file: ../../Tests/mcp-benchmarkerTests/locomo_spec_sample.json
    fn sample_path() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/mcp-benchmarkerTests/locomo_spec_sample.json")
    }

    fn load_sample() -> LoCoMoSpecCorpus {
        load_locomo_spec_corpus(&sample_path())
            .expect("locomo_spec_sample.json must load without error")
    }

    // ── Load — all questions included ──────────────────────────────────────

    #[test]
    fn test_loads_all_questions() {
        let corpus = load_sample();
        // Fixture has 4 QAs: cat1, cat4, cat2-empty-evidence, cat5 — all included.
        assert_eq!(corpus.questions.len(), 4, "spec loader includes all questions");
        assert_eq!(corpus.total_count(), 4);
    }

    #[test]
    fn test_category_5_included() {
        let corpus = load_sample();
        let cat5: Vec<_> = corpus.questions.iter().filter(|q| q.category == 5).collect();
        assert_eq!(cat5.len(), 1, "category 5 must be included in spec loader");
    }

    #[test]
    fn test_empty_evidence_question_included() {
        let corpus = load_sample();
        // The cat2 QA in the fixture has an empty evidence list.
        let empty_ev: Vec<_> = corpus
            .questions
            .iter()
            .filter(|q| q.evidence.is_empty())
            .collect();
        assert_eq!(empty_ev.len(), 1, "empty-evidence question must be included");
    }

    // ── Category counts ────────────────────────────────────────────────────

    #[test]
    fn test_category_counts() {
        let corpus = load_sample();
        assert_eq!(corpus.category_counts.get(&1), Some(&1));
        assert_eq!(corpus.category_counts.get(&2), Some(&1));
        assert_eq!(corpus.category_counts.get(&3), None); // no cat3 in fixture
        assert_eq!(corpus.category_counts.get(&4), Some(&1));
        assert_eq!(corpus.category_counts.get(&5), Some(&1));
    }

    // ── Category 5 structure ───────────────────────────────────────────────

    #[test]
    fn test_cat5_has_adversarial_answer() {
        let corpus = load_sample();
        let cat5 = corpus
            .questions
            .iter()
            .find(|q| q.category == 5)
            .expect("fixture must have a category 5 question");
        assert!(cat5.answer.is_none(), "cat5 must have no gold answer");
        assert_eq!(
            cat5.adversarial_answer.as_deref(),
            Some("Yes, she hated it."),
            "cat5 must have adversarial_answer"
        );
    }

    #[test]
    fn test_cat5_category_label() {
        let corpus = load_sample();
        let cat5 = corpus.questions.iter().find(|q| q.category == 5).unwrap();
        assert_eq!(cat5.category_label(), "adversarial");
    }

    // ── Image captions ─────────────────────────────────────────────────────

    #[test]
    fn test_image_caption_preserved() {
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        // Session 1, turn D1:2 has blip_caption in the fixture.
        let s1 = &conv.sessions[0];
        assert_eq!(s1.turns.len(), 3);
        let turn_with_caption = &s1.turns[1]; // D1:2
        assert_eq!(turn_with_caption.dia_id, "D1:2");
        assert_eq!(
            turn_with_caption.image_caption.as_deref(),
            Some("a painting of a sunset over the ocean"),
            "blip_caption must be preserved as image_caption"
        );
    }

    #[test]
    fn test_turns_without_caption_have_none() {
        let corpus = load_sample();
        let s1 = &corpus.conversations[0].sessions[0];
        assert!(s1.turns[0].image_caption.is_none(), "D1:1 has no image");
        assert!(s1.turns[2].image_caption.is_none(), "D1:3 has no image");
    }

    // ── Conversation structure ─────────────────────────────────────────────

    #[test]
    fn test_conversation_speakers() {
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        assert_eq!(conv.speaker_a, "Alice");
        assert_eq!(conv.speaker_b, "Bob");
        assert_eq!(conv.sample_id, "spec-conv-01");
    }

    #[test]
    fn test_sessions_chronological_order() {
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        assert_eq!(conv.sessions.len(), 2);
        assert_eq!(conv.sessions[0].session_number, 1);
        assert_eq!(conv.sessions[1].session_number, 2);
        assert_eq!(conv.sessions[0].date_time, "3:00 pm on 1 Jan, 2024");
        assert_eq!(conv.sessions[1].date_time, "2:00 pm on 10 Jan, 2024");
    }

    #[test]
    fn test_all_turns_flattened() {
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        let flat = conv.all_turns();
        // 3 (session1) + 2 (session2) = 5
        assert_eq!(flat.len(), 5);
        assert_eq!(flat[0].0, 1);
        assert_eq!(flat[0].1.dia_id, "D1:1");
        assert_eq!(flat[3].0, 2);
        assert_eq!(flat[3].1.dia_id, "D2:1");
    }

    // ── §6 Context formatting ──────────────────────────────────────────────

    /// Preamble must reproduce the official text verbatim, including typo 'wriiten'.
    /// LOCOMO_OFFICIAL_PROTOCOL.md §6.
    #[test]
    fn test_preamble_contains_official_typo() {
        let p = locomo_conversation_preamble("Alice", "Bob");
        assert!(
            p.contains("wriiten"),
            "preamble must contain official typo 'wriiten' (§6): {p}"
        );
        assert!(
            p.starts_with("Below is a conversation between two people: Alice and Bob."),
            "preamble must start with speaker names: {p}"
        );
    }

    #[test]
    fn test_session_header_format() {
        let h = locomo_session_header("1:56 pm on 8 May, 2023");
        assert_eq!(
            h,
            "DATE: 1:56 pm on 8 May, 2023 CONVERSATION:",
            "session header must match §6 format exactly"
        );
    }

    #[test]
    fn test_format_turn_no_caption() {
        let turn = LoCoMoSpecTurn {
            speaker: "Alice".to_string(),
            dia_id: "D1:1".to_string(),
            text: "Hey Bob! I visited the art museum today.".to_string(),
            image_caption: None,
        };
        let line = locomo_format_turn(&turn);
        assert_eq!(
            line,
            r#"Alice said, "Hey Bob! I visited the art museum today.""#,
            "turn without caption must match §6 format"
        );
    }

    #[test]
    fn test_format_turn_with_caption() {
        // §6: append ' and shared [caption]' for image turns.
        let turn = LoCoMoSpecTurn {
            speaker: "Bob".to_string(),
            dia_id: "D1:2".to_string(),
            text: "That sounds wonderful! Which exhibit?".to_string(),
            image_caption: Some("a painting of a sunset over the ocean".to_string()),
        };
        let line = locomo_format_turn(&turn);
        assert_eq!(
            line,
            r#"Bob said, "That sounds wonderful! Which exhibit?" and shared a painting of a sunset over the ocean"#,
            "turn with caption must append ' and shared [caption]' per §6"
        );
    }

    #[test]
    fn test_format_context_structure() {
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        let ctx = locomo_format_context(conv);

        // Preamble.
        assert!(
            ctx.starts_with("Below is a conversation between two people: Alice and Bob."),
            "context must start with preamble"
        );
        assert!(ctx.contains("wriiten"), "context must include official typo");

        // Session headers.
        assert!(
            ctx.contains("DATE: 3:00 pm on 1 Jan, 2024 CONVERSATION:"),
            "context must contain session 1 header"
        );
        assert!(
            ctx.contains("DATE: 2:00 pm on 10 Jan, 2024 CONVERSATION:"),
            "context must contain session 2 header"
        );

        // Non-image turn.
        assert!(
            ctx.contains(r#"Alice said, "Hey Bob! I visited the art museum today.""#),
            "non-image turn must appear in §6 format"
        );

        // Image turn — caption appended.
        assert!(
            ctx.contains(
                r#"Bob said, "That sounds wonderful! Which exhibit?" and shared a painting of a sunset over the ocean"#
            ),
            "image turn must include caption"
        );

        // Trailing newline.
        assert!(ctx.ends_with('\n'), "context must end with a newline");

        // Session 1 header appears before session 2 header (chronological).
        let s1_pos = ctx.find("1 Jan, 2024").expect("session 1 must appear");
        let s2_pos = ctx.find("10 Jan, 2024").expect("session 2 must appear");
        assert!(s1_pos < s2_pos, "session 1 must precede session 2");
    }

    #[test]
    fn test_format_context_byte_identical_to_swift_spec() {
        // Construct the expected context by hand using the same primitives.
        // This is not a round-trip test; it verifies that the composition of the
        // formatting helpers matches what the Swift port would produce, line by line.
        let corpus = load_sample();
        let conv = &corpus.conversations[0];
        let ctx = locomo_format_context(conv);
        let lines: Vec<&str> = ctx.split('\n').collect();

        // Line 0: preamble.
        assert!(lines[0].contains("wriiten"), "line 0 must be preamble");
        // Line 1: session 1 header.
        assert_eq!(
            lines[1],
            "DATE: 3:00 pm on 1 Jan, 2024 CONVERSATION:",
            "line 1 must be session 1 header"
        );
        // Line 2: first turn (no caption).
        assert_eq!(
            lines[2],
            r#"Alice said, "Hey Bob! I visited the art museum today.""#,
            "line 2 must be first turn"
        );
        // Line 3: second turn (with caption).
        assert_eq!(
            lines[3],
            r#"Bob said, "That sounds wonderful! Which exhibit?" and shared a painting of a sunset over the ocean"#,
            "line 3 must be image turn with caption"
        );
    }

    // ── Error cases ────────────────────────────────────────────────────────

    #[test]
    fn test_load_nonexistent_path_returns_err() {
        let result = load_locomo_spec_corpus(Path::new("/tmp/no_such_file_spec_locomo.json"));
        assert!(result.is_err(), "nonexistent path must return Err");
    }

    #[test]
    fn test_load_malformed_json_returns_err() {
        use std::io::Write;
        let tmp = std::env::temp_dir().join("locomo_spec_bad.json");
        let mut f = std::fs::File::create(&tmp).unwrap();
        f.write_all(b"not valid json [[[").unwrap();
        let result = load_locomo_spec_corpus(&tmp);
        let _ = std::fs::remove_file(&tmp);
        assert!(result.is_err(), "malformed JSON must return Err");
    }
}
