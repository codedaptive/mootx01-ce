//! membench_spec_protocol.rs — §2–§3 string surfaces for the membench-spec lane.
//!
//! Rust twin of `MemBenchSpecProtocol.swift`. Every function produces byte-identical
//! output to the Swift counterpart for the same inputs — pinned by
//! `conformance/membench-spec/protocol_vectors.json`.
//!
//! All functions are pure string constructors: no I/O, no clock reads. `serde_json`
//! is the only crate call (already a crate dependency) and only in
//! `parse_answer_choice` for the JSON primary path.
//!
//! § references point to section numbers in MEMBENCH_OFFICIAL_PROTOCOL.md.

use std::collections::HashMap;

// ─────────────────────────────────────────────────────────────────────────────
// Official initial instruction constant (§2)
// ─────────────────────────────────────────────────────────────────────────────

/// The official initial instruction constant from the MemBench interaction protocol.
///
/// The constant name `INITIAL_INSTRUACTION` is official — the typo (`INSTRUACTION`)
/// is reproduced verbatim from `benchmarks/env/Membenenv.py` (§2, arXiv 2506.21605).
/// Do not rename or correct this constant.
///
/// Twin of Swift `INITIAL_INSTRUACTION`.
pub const INITIAL_INSTRUACTION: &str =
    "Please help me record the following information. If there are any questions within the information, please help me answer them.";

// ─────────────────────────────────────────────────────────────────────────────
// Storage line construction (§2)
// ─────────────────────────────────────────────────────────────────────────────

/// Formats a string-form memory storage line per §2.
///
/// Official format: `"{step}[|]{message}"`
/// Used when the `message_list` entry is a plain string message.
///
/// Twin of Swift `storageLine(step:message:)`.
pub fn storage_line_string(step: usize, message: &str) -> String {
    // §2: string message form: "{step}[|]{message}"
    format!("{step}[|]{message}")
}

/// Formats a dict-form memory storage line per §2.
///
/// Official format: `"{step}[|]'user': {user}; 'agent': {agent}"`
/// Used when the `message_list` entry carries `user_message` and
/// `assistant_message` fields.
///
/// Twin of Swift `storageLine(step:user:agent:)`.
pub fn storage_line_dict(step: usize, user: &str, agent: &str) -> String {
    // §2: dict message form: "{step}[|]'user': {user}; 'agent': {agent}"
    format!("{step}[|]'user': {user}; 'agent': {agent}")
}

// ─────────────────────────────────────────────────────────────────────────────
// Step-id parse (§4)
// ─────────────────────────────────────────────────────────────────────────────

/// Errors produced by parsing a storage line for its step id.
///
/// Twin of Swift `StorageLineParseError`.
#[derive(Debug, PartialEq, Eq)]
pub enum StorageLineParseError {
    /// The `[|]` separator is absent — the line is not a valid storage line.
    MissingDelimiter,
    /// The prefix before `[|]` is not a decimal integer.
    InvalidStepId,
}

/// Parses the step id from a storage line produced by the §2 storage protocol.
///
/// Algorithm verbatim from §4: `int(text.split('[|]')[0])` — split on the
/// literal delimiter `[|]`, take element 0, parse as int.
///
/// Twin of Swift `stepID(fromStorageLine:)`.
pub fn step_id_from_storage_line(line: &str) -> Result<i64, StorageLineParseError> {
    // §4: int(text.split('[|]')[0]) — fail loudly when the delimiter is absent.
    if !line.contains("[|]") {
        return Err(StorageLineParseError::MissingDelimiter);
    }
    // Take everything before the first "[|]" (matching Python's split('[|]')[0]).
    let prefix = line.splitn(2, "[|]").next().unwrap_or("");
    prefix
        .parse::<i64>()
        .map_err(|_| StorageLineParseError::InvalidStepId)
}

// ─────────────────────────────────────────────────────────────────────────────
// Recall / retrieval query (§3–4)
// ─────────────────────────────────────────────────────────────────────────────

/// Formats the memory recall and retrieval query string per §3–4.
///
/// Official format (§3): `memory.recall('%s (%s)' % (question, time))`
/// Expands to: `"question (time)"`
///
/// Identical format used for both `memory.recall(...)` (§3) and
/// `memory.retri(...)` (§4 recall metric).
///
/// Twin of Swift `recallQuery(question:time:)`.
pub fn recall_query(question: &str, time: &str) -> String {
    // §3: '%s (%s)' % (question, time)
    format!("{question} ({time})")
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent perspective (§3)
// ─────────────────────────────────────────────────────────────────────────────

/// Agent perspective, selecting the §3 answer-prompt template.
///
/// `FirstAgent` → Participation framing: `your'conversation with the user`.
/// `ThirdAgent` → Observation framing: `the user's messages`.
///
/// Twin of Swift `MemBenchPerspective`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemBenchPerspective {
    FirstAgent,
    ThirdAgent,
}

// ─────────────────────────────────────────────────────────────────────────────
// Answer prompt construction (§3)
// ─────────────────────────────────────────────────────────────────────────────

/// Constructs the §3 answer prompt for the given perspective, byte-exact.
///
/// The two templates differ only in their opening line:
/// - `FirstAgent`: `"...your'conversation with the user."` — official typo (§3).
/// - `ThirdAgent`: `"...the user's messages."` — third-person observation framing.
///
/// Produces a 10-line string joined by `\n` with no trailing newline, matching
/// the Python template output.
///
/// Twin of Swift `answerPrompt(perspective:memory:question:time:choices:)`.
pub fn answer_prompt(
    perspective: &MemBenchPerspective,
    memory: &str,
    question: &str,
    time: &str,
    choices: &HashMap<String, String>,
) -> String {
    // §3 FirstAgent: "your'conversation" typo is OFFICIAL — preserve verbatim.
    // §3 ThirdAgent: "the user's messages" — third-person observation framing.
    let perspective_line = match perspective {
        MemBenchPerspective::FirstAgent =>
            "Please answer the following question based on past memories of your'conversation with the user.",
        MemBenchPerspective::ThirdAgent =>
            "Please answer the following question based on past memories of the user's messages.",
    };
    let empty = String::new();
    let choice_a = choices.get("A").unwrap_or(&empty);
    let choice_b = choices.get("B").unwrap_or(&empty);
    let choice_c = choices.get("C").unwrap_or(&empty);
    let choice_d = choices.get("D").unwrap_or(&empty);
    // Single format! call produces byte-exact `\n` separators (§3 template).
    // No trailing newline — matches the Python f-string / template output.
    format!(
        "{perspective_line}\nPast memory: {memory}\nQuestion: (current time is {time}) {question}\nChoices:\nA. {choice_a}\nB. {choice_b}\nC. {choice_c}\nD. {choice_d}\nPlease output the correct option for the question, only one corresponding letter, without any other messages.\nExample: D"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Answer constraint descriptor (§3)
// ─────────────────────────────────────────────────────────────────────────────

/// JSON Schema object enforcing the single-letter output constraint (§3, strict).
///
/// Schema:
/// `{"type":"object","properties":{"choice":{"type":"string",
///  "enum":["A","B","C","D"]}},"required":["choice"],"additionalProperties":false}`
///
/// Twin of Swift `MemBenchAnswerConstraint.jsonSchema`.
pub const ANSWER_CONSTRAINT_JSON_SCHEMA: &str =
    r#"{"type":"object","properties":{"choice":{"type":"string","enum":["A","B","C","D"]}},"required":["choice"],"additionalProperties":false}"#;

/// Parses the answering model's JSON response and returns the choice letter.
///
/// Primary path (§3): `json.loads(res)['choice']` — decode JSON, extract `"choice"`.
/// Fallback path (§3): strip all spaces and newlines; treat the result as the
/// letter if it is one of A/B/C/D.
///
/// Returns `None` when neither path yields a valid `A`/`B`/`C`/`D` letter.
///
/// Twin of Swift `MemBenchAnswerConstraint.parseAnswerChoice(from:)`.
pub fn parse_answer_choice(json_string: &str) -> Option<String> {
    // §3 primary: json.loads(res)['choice']
    if let Ok(obj) = serde_json::from_str::<serde_json::Value>(json_string) {
        if let Some(choice) = obj.get("choice").and_then(|v| v.as_str()) {
            if is_valid_letter(choice) {
                return Some(choice.to_string());
            }
        }
    }
    // §3 fallback: s.replace(" ", "").replace("\n", "")
    let stripped = json_string.replace(' ', "").replace('\n', "");
    if is_valid_letter(&stripped) {
        Some(stripped)
    } else {
        None
    }
}

// Returns true for the four valid answer letters (§3: enum ["A","B","C","D"]).
fn is_valid_letter(s: &str) -> bool {
    matches!(s, "A" | "B" | "C" | "D")
}

// ─────────────────────────────────────────────────────────────────────────────
// TokenCounter seam (§6 / §7 row 6)
// ─────────────────────────────────────────────────────────────────────────────

/// Shared tokenizer backing `membench_count_tokens` (§6 capacity token axis).
///
/// Loaded once per process from the cl100k_base vocabulary at the
/// `MOOT_BENCH_CL100K` path exported by the Makefile. `None` when the external
/// artifact is absent — `membench_count_tokens` fails loud in that case,
/// because a §6 capacity figure counted with any other tokenizer is not the
/// documented measurement.
fn membench_cl100k_tokenizer() -> Option<&'static crate::cl100k_tokenizer::Cl100kTokenizer> {
    use std::sync::OnceLock;
    static TOKENIZER: OnceLock<Option<crate::cl100k_tokenizer::Cl100kTokenizer>> =
        OnceLock::new();
    TOKENIZER
        .get_or_init(|| {
            let path = std::env::var("MOOT_BENCH_CL100K").ok()?;
            crate::cl100k_tokenizer::Cl100kTokenizer::load(&path).ok()
        })
        .as_ref()
}

/// Token-counting seam for the §6 capacity measurement (step_cap variant).
///
/// §6 specifies `cl100k_base` (tiktoken) as the official tokenizer. §7 row 6
/// RESOLVED ( operator ruling 2026-08-18): the vocabulary artifact is vendored via
/// `scripts/fetch-cl100k.sh` and counts come from `Cl100kTokenizer` — byte-exact
/// tiktoken `cl100k_base`, oracle-verified against tiktoken 0.14.0 by
/// `conformance/cl100k/vectors.json`.
///
/// The §6 capacity runner calls `membench_count_tokens` rather than the
/// tokenizer directly so the loading policy lives in exactly one place.
///
/// Twin of Swift `memBenchCountTokens(_:)`.
pub fn membench_count_tokens(text: &str) -> usize {
    membench_cl100k_tokenizer()
        .unwrap_or_else(|| {
            // Fail loud: §6 defines the token axis as cl100k_base; substituting a
            // different counter silently would misstate the capacity measurement.
            panic!(
                "cl100k_base vocabulary artifact missing — run \
                 benchmarks/scripts/fetch-cl100k.sh (or set MOOT_BENCH_CL100K to \
                 the .tiktoken file). The §6 capacity axis requires the exact \
                 tokenizer."
            )
        })
        .count_tokens(text)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── INITIAL_INSTRUACTION (§2) ────────────────────────────────────────────

    #[test]
    fn initial_instruaction_matches_spec() {
        // §2: official constant verbatim — name typo and string content.
        assert_eq!(
            INITIAL_INSTRUACTION,
            "Please help me record the following information. If there are any questions within the information, please help me answer them."
        );
    }

    // ── storage_line_string (§2) ─────────────────────────────────────────────

    #[test]
    fn storage_line_string_step_1_hello() {
        assert_eq!(storage_line_string(1, "hello world"), "1[|]hello world");
    }

    #[test]
    fn storage_line_string_step_42() {
        assert_eq!(
            storage_line_string(42, "Please help me record this."),
            "42[|]Please help me record this."
        );
    }

    #[test]
    fn storage_line_string_empty_message() {
        // §2: empty message is valid — delimiter still present.
        assert_eq!(storage_line_string(0, ""), "0[|]");
    }

    // ── storage_line_dict (§2) ───────────────────────────────────────────────

    #[test]
    fn storage_line_dict_basic() {
        assert_eq!(
            storage_line_dict(3, "Hi there", "Hello!"),
            "3[|]'user': Hi there; 'agent': Hello!"
        );
    }

    #[test]
    fn storage_line_dict_step_5() {
        assert_eq!(
            storage_line_dict(5, "Good morning", "Good morning to you too!"),
            "5[|]'user': Good morning; 'agent': Good morning to you too!"
        );
    }

    // ── step_id_from_storage_line (§4) ───────────────────────────────────────

    #[test]
    fn step_id_string_form() {
        assert_eq!(step_id_from_storage_line("1[|]hello world"), Ok(1));
    }

    #[test]
    fn step_id_large() {
        assert_eq!(step_id_from_storage_line("42[|]some message"), Ok(42));
    }

    #[test]
    fn step_id_zero() {
        // §4: step 0 is a valid step id (edge case: first turn in 0-based mode).
        assert_eq!(step_id_from_storage_line("0[|]"), Ok(0));
    }

    #[test]
    fn step_id_dict_form() {
        assert_eq!(
            step_id_from_storage_line("5[|]'user': Hi; 'agent': Bye"),
            Ok(5)
        );
    }

    #[test]
    fn step_id_missing_delimiter() {
        // §4: no "[|]" separator → MissingDelimiter error.
        assert_eq!(
            step_id_from_storage_line("malformed line"),
            Err(StorageLineParseError::MissingDelimiter)
        );
    }

    #[test]
    fn step_id_invalid_prefix() {
        // §4: non-integer prefix → InvalidStepId error.
        assert_eq!(
            step_id_from_storage_line("abc[|]message"),
            Err(StorageLineParseError::InvalidStepId)
        );
    }

    // ── recall_query (§3–4) ─────────────────────────────────────────────────

    #[test]
    fn recall_query_basic() {
        assert_eq!(
            recall_query("Where did the user go on vacation?", "2024-01-15 10:00"),
            "Where did the user go on vacation? (2024-01-15 10:00)"
        );
    }

    #[test]
    fn recall_query_simple() {
        assert_eq!(
            recall_query("What did Alice say?", "last Tuesday"),
            "What did Alice say? (last Tuesday)"
        );
    }

    // ── answer_prompt (§3) ──────────────────────────────────────────────────

    fn choices_paris() -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("A".to_string(), "Paris".to_string());
        m.insert("B".to_string(), "London".to_string());
        m.insert("C".to_string(), "Berlin".to_string());
        m.insert("D".to_string(), "Tokyo".to_string());
        m
    }

    fn choices_hiking() -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("A".to_string(), "Swimming".to_string());
        m.insert("B".to_string(), "Hiking".to_string());
        m.insert("C".to_string(), "Cycling".to_string());
        m.insert("D".to_string(), "Running".to_string());
        m
    }

    #[test]
    fn answer_prompt_first_agent_contains_official_typo() {
        // §3: official typo "your'conversation" must appear verbatim in FirstAgent.
        let prompt = answer_prompt(
            &MemBenchPerspective::FirstAgent,
            "The user went to Paris.",
            "Where did the user go?",
            "2024-01-15",
            &choices_paris(),
        );
        assert!(
            prompt.starts_with("Please answer the following question based on past memories of your'conversation with the user."),
            "FirstAgent prompt must contain official typo 'your'conversation'"
        );
    }

    #[test]
    fn answer_prompt_third_agent_first_line() {
        let prompt = answer_prompt(
            &MemBenchPerspective::ThirdAgent,
            "Alice mentioned she loves hiking.",
            "What does Alice love?",
            "2024-02-20",
            &choices_hiking(),
        );
        assert!(
            prompt.starts_with("Please answer the following question based on past memories of the user's messages."),
            "ThirdAgent prompt must use third-person framing"
        );
    }

    #[test]
    fn answer_prompt_first_agent_full_vector() {
        // §3: full byte-exact render for the FirstAgent template.
        let prompt = answer_prompt(
            &MemBenchPerspective::FirstAgent,
            "The user went to Paris.",
            "Where did the user go?",
            "2024-01-15",
            &choices_paris(),
        );
        let expected = concat!(
            "Please answer the following question based on past memories of your'conversation with the user.\n",
            "Past memory: The user went to Paris.\n",
            "Question: (current time is 2024-01-15) Where did the user go?\n",
            "Choices:\n",
            "A. Paris\n",
            "B. London\n",
            "C. Berlin\n",
            "D. Tokyo\n",
            "Please output the correct option for the question, only one corresponding letter, without any other messages.\n",
            "Example: D"
        );
        assert_eq!(prompt, expected);
    }

    #[test]
    fn answer_prompt_third_agent_full_vector() {
        // §3: full byte-exact render for the ThirdAgent template.
        let prompt = answer_prompt(
            &MemBenchPerspective::ThirdAgent,
            "Alice mentioned she loves hiking.",
            "What does Alice love?",
            "2024-02-20",
            &choices_hiking(),
        );
        let expected = concat!(
            "Please answer the following question based on past memories of the user's messages.\n",
            "Past memory: Alice mentioned she loves hiking.\n",
            "Question: (current time is 2024-02-20) What does Alice love?\n",
            "Choices:\n",
            "A. Swimming\n",
            "B. Hiking\n",
            "C. Cycling\n",
            "D. Running\n",
            "Please output the correct option for the question, only one corresponding letter, without any other messages.\n",
            "Example: D"
        );
        assert_eq!(prompt, expected);
    }

    #[test]
    fn answer_prompt_no_trailing_newline() {
        // No trailing newline — matches Python template output (§3).
        let prompt = answer_prompt(
            &MemBenchPerspective::FirstAgent,
            "memory",
            "question",
            "time",
            &HashMap::new(),
        );
        assert!(!prompt.ends_with('\n'), "prompt must not end with a trailing newline");
    }

    // ── parse_answer_choice (§3) ─────────────────────────────────────────────

    #[test]
    fn parse_choice_json_a() {
        assert_eq!(parse_answer_choice(r#"{"choice": "A"}"#), Some("A".to_string()));
    }

    #[test]
    fn parse_choice_json_d() {
        assert_eq!(parse_answer_choice(r#"{"choice": "D"}"#), Some("D".to_string()));
    }

    #[test]
    fn parse_choice_fallback_single_letter() {
        // §3 fallback: bare single letter (no JSON wrapper).
        assert_eq!(parse_answer_choice("B"), Some("B".to_string()));
    }

    #[test]
    fn parse_choice_fallback_whitespace_stripped() {
        // §3 fallback: letter with surrounding space stripped.
        assert_eq!(parse_answer_choice("C "), Some("C".to_string()));
    }

    #[test]
    fn parse_choice_invalid_letter_returns_none() {
        // §3: "E" is not in enum ["A","B","C","D"] → None.
        assert_eq!(parse_answer_choice(r#"{"choice": "E"}"#), None);
    }

    #[test]
    fn parse_choice_garbage_returns_none() {
        assert_eq!(parse_answer_choice("invalid json and not a letter"), None);
    }

    // ── membench_count_tokens (§6 / §7 row 6) ───────────────────────────────

    /// True when the vendored cl100k artifact is on disk. The seam fails loud
    /// without it, so these tests skip on machines that have not run
    /// scripts/fetch-cl100k.sh.
    fn cl100k_fixture_present() -> bool {
        std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../fixtures/cl100k/cl100k_base.tiktoken"
        ))
        .exists()
    }

    #[test]
    fn token_seam_counts_with_cl100k() {
        // §7 row 6 RESOLVED: seam counts with the vendored cl100k_base tokenizer.
        if !cl100k_fixture_present() {
            eprintln!("skipping: cl100k fixture absent — run scripts/fetch-cl100k.sh");
            return;
        }
        // Values pinned by the cl100k conformance vectors (tiktoken 0.14.0 oracle):
        // "Hello world" → [9906, 1917]; "The quick brown fox" → 4 tokens.
        assert_eq!(membench_count_tokens("Hello world"), 2);
        assert_eq!(membench_count_tokens("The quick brown fox"), 4);
    }

    #[test]
    fn token_seam_empty_string() {
        if !cl100k_fixture_present() {
            eprintln!("skipping: cl100k fixture absent — run scripts/fetch-cl100k.sh");
            return;
        }
        assert_eq!(membench_count_tokens(""), 0);
    }
}
