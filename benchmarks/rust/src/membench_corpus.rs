//! membench_corpus.rs — MemBench JSON loader (Rust twin of `MemBenchCorpus.swift`).
//!
//! Dataset: MemBench (arXiv 2506.21605, ACL Findings 2025)
//! Paper: "MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents"
//! Repo: <https://github.com/import-myself/Membench>
//! License: see repo (no explicit license found as of 2026-08-06; internal diagnostic use only)
//!
//! # File layout
//!
//! `MemData/{FirstAgent,ThirdAgent}/<category>.json`
//!
//! # Top-level structure
//!
//! JSON object with one or more topic keys (typically one key: `"roles"`) →
//! array of items `{ tid, message_list, QA }`.
//!
//! # Per-item fields
//!
//! - `tid`:          Integer — unique item index within the file/topic
//! - `message_list`: `[[Turn]]` — array of sessions, each session is an array of turns
//! - `QA`:           Object — single question-answer pair
//!
//! # Turn fields (verified 2026-08-06)
//!
//! - `sid`:               Integer — GLOBAL sequential turn ID across all sessions in the item.
//!                                  Sessions sids are globally sequential (session 0: sids 0-19,
//!                                  session 1: sids 20-40, etc.)
//! - `user_message`:      String  — user's utterance
//! - `assistant_message`: String  — assistant's response
//! - `time`:              String  — timestamp of the exchange
//! - `place`:             String  — location context
//!
//! # QA fields (verified 2026-08-06)
//!
//! - `qid`:             Integer       — question ID within the item
//! - `question`:        String        — question text
//! - `answer`:          String        — verbatim answer text
//! - `target_step_id`:  `[[Int, Int]]` — each pair is `[global_sid, session_idx]`.
//!                                       `global_sid` uniquely identifies the evidence turn.
//!                                       `session_idx` is 0-based (redundant, for verification).
//!                                       Verified for tid=0: sid=119 is in session 5,
//!                                       target_step_id = [[119, 5]].
//! - `choices`:         Object        — A/B/C/D answer choices
//! - `ground_truth`:    String        — correct answer letter (A, B, C, or D)
//! - `time`:            String        — timestamp associated with the question
//!
//! # Categories (FirstAgent)
//!
//! LowLevel:  simple, comparative, aggregative, conditional, knowledge_update,
//!            post_processing, noisy
//! HighLevel: highlevel, highlevel_rec, lowlevel_rec, RecMultiSession

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

// ─── Public types ─────────────────────────────────────────────────────────────

/// One conversational exchange in a MemBench session.
///
/// Twin of Swift `MemBenchTurn`.
#[derive(Debug, Clone, PartialEq)]
pub struct MemBenchTurn {
    /// Global sequential ID for this turn (unique within the item's message_list).
    pub sid: i64,
    /// The user's message text.
    pub user_message: String,
    /// The assistant's response text.
    pub assistant_message: String,
    /// Timestamp string for this exchange.
    pub time: String,
    /// Location context for this exchange.
    pub place: String,
}

/// One session within a MemBench item's conversation.
///
/// Twin of Swift `MemBenchSession`.
#[derive(Debug, Clone)]
pub struct MemBenchSession {
    /// 0-based index of this session within the item's message_list.
    pub session_index: usize,
    /// Turns in this session, in chronological order.
    pub turns: Vec<MemBenchTurn>,
}

/// Evidence pointer: one (global_sid, session_idx) pair from target_step_id.
///
/// Twin of the tuple `(globalSid: Int, sessionIdx: Int)` in Swift `MemBenchQA`.
#[derive(Debug, Clone)]
pub struct TargetStep {
    /// Global sid identifying the evidence turn (matches the turn's `sid` field).
    pub global_sid: i64,
    /// 0-based session index the evidence turn belongs to (redundant with global_sid).
    pub session_idx: usize,
}

/// A multiple-choice question from the MemBench dataset.
///
/// Twin of Swift `MemBenchQA`.
#[derive(Debug, Clone)]
pub struct MemBenchQA {
    /// Question ID within the item.
    pub qid: i64,
    /// Question text.
    pub question: String,
    /// Verbatim answer text.
    pub answer: String,
    /// Evidence turns. Each entry is a (global_sid, session_idx) pair.
    pub target_step_id: Vec<TargetStep>,
    /// Multiple-choice options (keys: "A", "B", "C", "D").
    pub choices: HashMap<String, String>,
    /// Correct answer letter (A, B, C, or D).
    pub ground_truth: String,
    /// Timestamp string associated with the question.
    pub time: String,
}

/// One scored item from the MemBench dataset.
///
/// Twin of Swift `MemBenchItem`.
#[derive(Debug, Clone)]
pub struct MemBenchItem {
    /// Synthetic item identifier: `"<agent>/<category>/<topicKey>/<tid>"`.
    pub item_id: String,
    /// Category label (e.g. "simple", "noisy", "highlevel").
    pub category: String,
    /// Agent perspective ("FirstAgent" or "ThirdAgent").
    pub agent: String,
    /// Topic key within the file (e.g. "roles").
    pub topic_key: String,
    /// 0-based item index within the topic.
    pub tid: usize,
    /// Sessions in the conversation, in order.
    pub sessions: Vec<MemBenchSession>,
    /// The single QA pair for this item.
    pub qa: MemBenchQA,
}

impl MemBenchItem {
    /// Flat list of all turns across all sessions, in session order.
    pub fn all_turns(&self) -> Vec<&MemBenchTurn> {
        self.sessions.iter().flat_map(|s| s.turns.iter()).collect()
    }

    /// Set of global sids that contain evidence for the question.
    /// These are the turn IDs the retrieval scorer checks against (as strings,
    /// matching the manifest's `sid` field format).
    pub fn evidence_sids(&self) -> Vec<String> {
        self.qa
            .target_step_id
            .iter()
            .map(|t| t.global_sid.to_string())
            .collect()
    }
}

/// The result of loading one or more MemBench category files.
///
/// Twin of Swift `MemBenchCorpus`.
#[derive(Debug)]
pub struct MemBenchCorpus {
    /// All items loaded, in file order.
    pub items: Vec<MemBenchItem>,
    /// Number of items skipped (missing QA, empty sessions, etc.).
    pub skipped_count: usize,
}

impl MemBenchCorpus {
    /// Total items in the source files (items + skipped).
    pub fn total_count(&self) -> usize {
        self.items.len() + self.skipped_count
    }
}

// ─── Raw decode types ─────────────────────────────────────────────────────────

/// Raw Serde decode for one turn object.
#[derive(Debug, Deserialize)]
struct RawTurn {
    sid: i64,
    user_message: String,
    assistant_message: String,
    time: Option<String>,
    place: Option<String>,
}

/// Raw decode for a ThirdAgent record.
///
/// ThirdAgent is a DIFFERENT TASK SHAPE, not another view of FirstAgent. There
/// is no assistant: each record is one observed assertion about a third party,
/// carrying the relation/attribute/value triple the statement encodes, and the
/// records sit in a FLAT array rather than nested sessions.
///
///   FirstAgent turn:   sid, user_message, assistant_message, time, place
///   ThirdAgent record: mid, message, time, place, rel, attr, value
///
/// Mapped onto the same turn model below so ingest, seeding and scoring are
/// untouched. `rel`/`attr`/`value` are deliberately NOT ingested with the
/// statement text: handing over the answer structure would measure parsing
/// rather than recall. Twin of Swift `MemBenchRecordRaw`.
///
/// `mid` is a JSON number in some categories and a quoted string in others,
/// and `message` is null on a handful of rows; both are decoded leniently
/// because a strict decode discards a whole 13,137-item perspective over a few
/// records. A null message keeps its record — evidence is addressed by mid, so
/// dropping the row would make the referenced mid unresolvable.
#[derive(Debug, Deserialize)]
struct RawRecord {
    #[serde(deserialize_with = "de_flexible_i64")]
    mid: i64,
    #[serde(default)]
    message: Option<String>,
    time: Option<String>,
    place: Option<String>,
}

/// message_list is nested sessions in FirstAgent and a flat record array in
/// ThirdAgent. Twin of Swift `MemBenchMessageList`.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawMessageList {
    Sessions(Vec<Vec<RawTurn>>),
    Records(Vec<RawRecord>),
}

impl RawMessageList {
    fn is_empty(&self) -> bool {
        match self {
            RawMessageList::Sessions(v) => v.is_empty(),
            RawMessageList::Records(v) => v.is_empty(),
        }
    }
}

/// target_step_id is [[global_sid, session_idx]] in FirstAgent and a flat
/// [mid] in ThirdAgent. Twin of Swift `MemBenchTargetSteps`.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RawTargetSteps {
    Pairs(Vec<Vec<i64>>),
    Flat(Vec<i64>),
}

impl RawTargetSteps {
    /// Evidence turns as (global_sid, session_idx). The flat form carries
    /// session 0, the only session a ThirdAgent item has.
    fn resolved(&self) -> Vec<TargetStep> {
        match self {
            RawTargetSteps::Pairs(pairs) => pairs
                .iter()
                .filter(|p| p.len() >= 2)
                .map(|p| TargetStep { global_sid: p[0], session_idx: p[1] as usize })
                .collect(),
            RawTargetSteps::Flat(mids) => mids
                .iter()
                .map(|m| TargetStep { global_sid: *m, session_idx: 0 })
                .collect(),
        }
    }
}

/// Accepts an integer or a numeric string for `mid`.
fn de_flexible_i64<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum NumOrStr {
        Num(i64),
        Str(String),
    }
    match NumOrStr::deserialize(deserializer)? {
        NumOrStr::Num(n) => Ok(n),
        NumOrStr::Str(s) => s.parse::<i64>().map_err(serde::de::Error::custom),
    }
}

/// Raw Serde decode for the QA object.
#[derive(Debug, Deserialize)]
struct RawQA {
    qid: Option<i64>,
    #[serde(default)]
    question: Option<String>,
    #[serde(default)]
    answer: Option<String>,
    /// Pairs in FirstAgent, a flat mid list in ThirdAgent.
    target_step_id: RawTargetSteps,
    /// A null option is DROPPED rather than emptied: an empty choice would be
    /// offered to a judge as a real option to pick.
    #[serde(default)]
    choices: HashMap<String, Option<String>>,
    #[serde(default)]
    ground_truth: Option<String>,
    time: Option<String>,
}

/// Raw Serde decode for one item inside a topic array.
#[derive(Debug, Deserialize)]
struct RawItem {
    tid: Option<usize>,
    message_list: RawMessageList,
    #[serde(rename = "QA")]
    qa: Option<RawQA>,
}

// ─── Loader ───────────────────────────────────────────────────────────────────

/// The default LowLevel category set (the paper's main evaluation set).
pub const DEFAULT_CATEGORIES: &[&str] = &[
    "simple",
    "comparative",
    "aggregative",
    "conditional",
    "knowledge_update",
    "post_processing",
    "noisy",
];

/// Loads MemBench items from the directory tree at `data_dir`.
///
/// File layout: `<data_dir>/<agent>/<category>.json`
///
/// # Parameters
///
/// - `data_dir`: Root MemData directory (contains `FirstAgent/` and `ThirdAgent/`).
/// - `agent`: Which agent perspective to load (`"FirstAgent"` or `"ThirdAgent"`).
/// - `categories`: Category names to include. `None` = all `DEFAULT_CATEGORIES`.
/// - `limit`: Optional item count cap applied after loading (for quick runs).
///
/// # Returns
///
/// A `MemBenchCorpus` with all valid items.
///
/// # Errors
///
/// Returns a descriptive `String` on missing directory or unreadable / malformed files.
pub fn load_membench_corpus(
    data_dir: &Path,
    agent: &str,
    categories: Option<&[&str]>,
    limit: Option<usize>,
) -> Result<MemBenchCorpus, String> {
    let effective_categories: Vec<&str> = match categories {
        Some(cats) => cats.to_vec(),
        None => DEFAULT_CATEGORIES.to_vec(),
    };

    let agent_dir = data_dir.join(agent);
    if !agent_dir.exists() {
        return Err(format!(
            "MemBench: agent directory not found at '{}'",
            agent_dir.display()
        ));
    }

    let mut all_items: Vec<MemBenchItem> = Vec::new();
    let mut skipped = 0usize;

    for category in &effective_categories {
        let file_path = agent_dir.join(format!("{}.json", category));
        if !file_path.exists() {
            // Missing category file is not an error — some agents lack some categories.
            continue;
        }

        let raw_bytes = fs::read(&file_path).map_err(|e| {
            format!(
                "MemBench: could not read '{}': {}",
                file_path.display(),
                e
            )
        })?;

        // Top-level: object with topic keys → arrays of items.
        let top_level: HashMap<String, Vec<RawItem>> =
            serde_json::from_slice(&raw_bytes).map_err(|e| {
                format!(
                    "MemBench: JSON decode failed for '{}': {}",
                    file_path.display(),
                    e
                )
            })?;

        // Iterate over all topic groups in the file, in SORTED key order.
        //
        // HashMap iteration order is unspecified and varies between runs, so
        // iterating `top_level` directly makes item order differ between two
        // runs of the same command. Files with more than one topic group
        // (noisy.json has several) then hand `--limit N` a different slice each
        // launch, and an artifact built for one item cannot satisfy a
        // measurement run that asks for another. Sorted keys make the corpus
        // order a function of its contents alone.
        // Twin of Swift `loadMemBenchCorpus`.
        let mut topic_keys: Vec<&String> = top_level.keys().collect();
        topic_keys.sort();
        for topic_key in topic_keys {
            let raw_items = &top_level[topic_key];
            for (raw_index, raw) in raw_items.iter().enumerate() {
                let Some(qa) = &raw.qa else {
                    // Items without a QA field are skipped.
                    skipped += 1;
                    continue;
                };
                if qa.question.as_deref().unwrap_or("").is_empty() {
                    skipped += 1;
                    continue;
                }
                if raw.message_list.is_empty() {
                    skipped += 1;
                    continue;
                }

                let tid = raw.tid.unwrap_or(raw_index);

                // Build sessions from message_list. ThirdAgent's flat record
                // array becomes ONE session of single-statement turns: it has
                // no session structure to preserve, and collapsing it keeps
                // every downstream consumer on one code path.
                let sessions: Vec<MemBenchSession> = match &raw.message_list {
                    RawMessageList::Sessions(raw_sessions) => raw_sessions
                        .iter()
                        .enumerate()
                        .map(|(si, raw_turns)| MemBenchSession {
                            session_index: si,
                            turns: raw_turns
                                .iter()
                                .map(|t| MemBenchTurn {
                                    sid: t.sid,
                                    user_message: t.user_message.clone(),
                                    assistant_message: t.assistant_message.clone(),
                                    time: t.time.clone().unwrap_or_default(),
                                    place: t.place.clone().unwrap_or_default(),
                                })
                                .collect(),
                        })
                        .collect(),
                    RawMessageList::Records(records) => vec![MemBenchSession {
                        session_index: 0,
                        turns: records
                            .iter()
                            .map(|r| MemBenchTurn {
                                sid: r.mid,
                                user_message: r.message.clone().unwrap_or_default(),
                                assistant_message: String::new(),
                                time: r.time.clone().unwrap_or_default(),
                                place: r.place.clone().unwrap_or_default(),
                            })
                            .collect(),
                    }],
                };

                let target_step_id: Vec<TargetStep> = qa.target_step_id.resolved();

                let qa_item = MemBenchQA {
                    qid: qa.qid.unwrap_or(0),
                    question: qa.question.clone().unwrap_or_default(),
                    answer: qa.answer.clone().unwrap_or_default(),
                    target_step_id,
                    choices: qa
                        .choices
                        .iter()
                        .filter_map(|(k, v)| v.clone().map(|v| (k.clone(), v)))
                        .collect(),
                    ground_truth: qa.ground_truth.clone().unwrap_or_default(),
                    time: qa.time.clone().unwrap_or_default(),
                };

                all_items.push(MemBenchItem {
                    item_id: format!("{}/{}/{}/{}", agent, category, topic_key, tid),
                    category: category.to_string(),
                    agent: agent.to_string(),
                    topic_key: topic_key.clone(),
                    tid,
                    sessions,
                    qa: qa_item,
                });
            }
        }
    }

    // Apply limit after loading (consistent with how other lanes handle --limit).
    if let Some(lim) = limit {
        all_items.truncate(lim);
    }

    Ok(MemBenchCorpus {
        items: all_items,
        skipped_count: skipped,
    })
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    // Atomic counter for unique temp directory names across parallel test runs.
    // Avoids tempfile crate dependency per Cargo.toml "no external test deps" constraint.
    static TEST_DIR_COUNTER: AtomicU32 = AtomicU32::new(0);

    /// Creates a unique temp directory under `std::env::temp_dir()`.
    /// Caller is responsible for cleanup via `std::fs::remove_dir_all`.
    fn make_test_dir() -> std::path::PathBuf {
        let pid = std::process::id();
        let seq = TEST_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("mcp_bench_membench_{pid}_{seq}"));
        std::fs::create_dir_all(&dir).expect("create test temp dir");
        dir
    }

    fn write_fixture(dir: &std::path::Path, category: &str, content: &str) {
        let agent_dir = dir.join("FirstAgent");
        std::fs::create_dir_all(&agent_dir).unwrap();
        std::fs::write(agent_dir.join(format!("{category}.json")), content).unwrap();
    }

    fn sample_json() -> &'static str {
        r#"{
          "roles": [
            {
              "tid": 0,
              "message_list": [
                [
                  {"sid": 0, "user_message": "I bought a red bike.",
                   "assistant_message": "Nice!", "time": "2024-01-01T00:00:00Z", "place": "home"},
                  {"sid": 1, "user_message": "I ride daily.",
                   "assistant_message": "Great habit.", "time": "2024-01-01T00:05:00Z", "place": "home"}
                ],
                [
                  {"sid": 2, "user_message": "Flat tire today.",
                   "assistant_message": "Frustrating!", "time": "2024-02-01T00:00:00Z", "place": "park"}
                ]
              ],
              "QA": {
                "qid": 0,
                "question": "What color is the bike?",
                "answer": "red",
                "target_step_id": [[0, 0]],
                "choices": {"A": "red", "B": "blue", "C": "green", "D": "yellow"},
                "ground_truth": "A",
                "time": "2024-03-01T00:00:00Z"
              }
            }
          ]
        }"#
    }

    #[test]
    fn test_loads_synthetic_fixture() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None)
            .expect("should load");
        assert_eq!(corpus.items.len(), 1, "expected 1 item");
        assert_eq!(corpus.skipped_count, 0);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_item_fields() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        let item = &corpus.items[0];
        assert_eq!(item.category, "simple");
        assert_eq!(item.agent, "FirstAgent");
        assert_eq!(item.topic_key, "roles");
        assert_eq!(item.tid, 0);
        assert!(item.item_id.contains("simple"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_session_and_turn_counts() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        let item = &corpus.items[0];
        assert_eq!(item.sessions.len(), 2, "should have 2 sessions");
        assert_eq!(item.sessions[0].turns.len(), 2, "session 0 should have 2 turns");
        assert_eq!(item.sessions[1].turns.len(), 1, "session 1 should have 1 turn");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_global_sids_sequential() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        let item = &corpus.items[0];
        // Sids: session 0 → [0, 1], session 1 → [2]
        let s0_sids: Vec<i64> = item.sessions[0].turns.iter().map(|t| t.sid).collect();
        assert_eq!(s0_sids, vec![0, 1]);
        let s1_sids: Vec<i64> = item.sessions[1].turns.iter().map(|t| t.sid).collect();
        assert_eq!(s1_sids, vec![2]);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_evidence_sids() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        let evidence = corpus.items[0].evidence_sids();
        assert_eq!(evidence, vec!["0".to_string()]);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_target_step_id_parsed() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", sample_json());
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        let steps = &corpus.items[0].qa.target_step_id;
        assert_eq!(steps.len(), 1);
        assert_eq!(steps[0].global_sid, 0);
        assert_eq!(steps[0].session_idx, 0);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_limit_applied() {
        let json = r#"{"roles": [
            {"tid":0,"message_list":[[{"sid":0,"user_message":"a","assistant_message":"b","time":"","place":""}]],
             "QA":{"qid":0,"question":"q","answer":"a","target_step_id":[[0,0]],"choices":{"A":"a"},"ground_truth":"A","time":""}},
            {"tid":1,"message_list":[[{"sid":0,"user_message":"c","assistant_message":"d","time":"","place":""}]],
             "QA":{"qid":0,"question":"q2","answer":"b","target_step_id":[[0,0]],"choices":{"A":"b"},"ground_truth":"A","time":""}}
        ]}"#;
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", json);
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), Some(1)).unwrap();
        assert_eq!(corpus.items.len(), 1);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_missing_category_file_skipped() {
        let tmp = make_test_dir();
        // Create agent dir but no category file.
        std::fs::create_dir_all(tmp.join("FirstAgent")).unwrap();
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["noisy"]), None).unwrap();
        assert_eq!(corpus.items.len(), 0);
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_missing_agent_dir_returns_error() {
        let tmp = make_test_dir();
        // Empty dir — no FirstAgent subdir.
        let result = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None);
        assert!(result.is_err(), "missing agent dir should return error");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_malformed_json_returns_error() {
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", "not valid json {{{{");
        let result = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None);
        assert!(result.is_err(), "malformed JSON should return error");
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn test_item_without_qa_skipped() {
        let json = r#"{"roles": [
            {"tid":0,"message_list":[[{"sid":0,"user_message":"hi","assistant_message":"ho","time":"","place":""}]]}
        ]}"#;
        let tmp = make_test_dir();
        write_fixture(&tmp, "simple", json);
        let corpus = load_membench_corpus(&tmp, "FirstAgent", Some(&["simple"]), None).unwrap();
        assert_eq!(corpus.items.len(), 0);
        assert_eq!(corpus.skipped_count, 1);
        std::fs::remove_dir_all(&tmp).ok();
    }
}
