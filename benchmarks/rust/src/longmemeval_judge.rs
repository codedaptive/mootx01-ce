//! longmemeval_judge.rs — Thin subprocess judge for LME-03 judge mode.
//!
//! Rust twin of `LongMemEvalJudge.swift`. Provides the same three surfaces:
//!
//! - [`lme_judge_prompt`] — format the stdin prompt sent to the judge process.
//! - [`lme_run_judge`] — spawn the judge subprocess, write the prompt to stdin,
//!   capture stdout, grade for non-zero exit.
//! - [`lme_grade_judge_answer`] — deterministic normalized-substring grader.
//!
//! The judge hook is generic: any command that reads a prompt on stdin and
//! writes its answer on stdout qualifies. The command is executed via
//! `/bin/sh -c <cmd>` so shell features (pipes, env vars, quoted args) work.
//!
//! Grading reuses `lme_normalize_for_evidence` (same algorithm as the Swift
//! twin) so the evidence-density scorer and the judge grader are on the same
//! normalization scale.

use crate::longmemeval_token_efficiency::lme_normalize_for_evidence;
use std::io::Write;

// ─────────────────────────────────────────────────────────────────────────────
// Prompt formatting
// ─────────────────────────────────────────────────────────────────────────────

/// Formats the stdin prompt sent to the judge subprocess.
///
/// The question and payload are embedded verbatim. The format is stable —
/// any change here changes the semantics of stored transcripts.
///
/// Twin of Swift `lmeJudgePrompt(question:payload:)`.
pub fn lme_judge_prompt(question: &str, payload: &str) -> String {
    format!(
        "Answer the following question using the provided context. The context \
is prior conversation with the user.\n\
\n\
You may INFER the answer from what the user said — including their stated \
preferences, interests, and habits. The answer does NOT need to appear \
verbatim in the context. Only respond \"I don't know\" when the context is \
genuinely unrelated to the question.\n\
\n\
Keep your answer as concise as possible (a word, phrase, or short sentence).\n\
\n\
Question: {question}\n\
\n\
Context:\n\
{payload}\n\
\n\
Answer:"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Subprocess runner
// ─────────────────────────────────────────────────────────────────────────────


/// Runs the judge command with `prompt` on stdin, returns the trimmed stdout.
///
/// The command is executed via `/bin/sh -c <cmd>`. The judge process must
/// exit 0; a non-zero exit returns `Err` with the exit code and any stderr.
///
/// Stderr is piped so error text is available on failure. stdout is collected
/// on a background thread so a `recv_timeout` can enforce a bounded wait —
/// `wait_with_output()` already drains both concurrently (no deadlock), but
/// without a timeout a hung judge blocks the run indefinitely.
///
/// Twin of Swift `lmeRunJudge(cmd:prompt:)`.
///
/// # Errors
///
/// Returns `Err(String)` when:
/// - The subprocess fails to spawn.
/// - The subprocess exits with a non-zero status code.
/// - The subprocess does not exit within `crate::config::subprocess_timeout_secs()`.
pub fn lme_run_judge(cmd: &str, prompt: &str) -> Result<String, String> {
    lme_run_judge_with_timeout(cmd, prompt, crate::config::subprocess_timeout_secs())
}

/// Timeout-parameterized body of `lme_run_judge`, split out so tests can
/// exercise the timeout paths in seconds instead of the production 120s.
pub(crate) fn lme_run_judge_with_timeout(
    cmd: &str,
    prompt: &str,
    timeout_secs: u64,
) -> Result<String, String> {
    // Inject the command via the private MOOT_BENCH_CMD_INTERNAL env var so
    // that a command carrying an API key is not visible in `ps` argv output.
    // The shell stub copies the var to a local and UNSETS the export before
    // eval, so the command string is NOT inherited by the judge process or
    // its descendants (Wave-3 G4). Mirrors the Swift runBoundedCmdSubprocess.
    let mut child = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"__moot_bench_cmd="$MOOT_BENCH_CMD_INTERNAL"; unset MOOT_BENCH_CMD_INTERNAL; eval "$__moot_bench_cmd""#)
        .env("MOOT_BENCH_CMD_INTERNAL", cmd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn judge command: {e}"))?;

    // Write the prompt to stdin, then close to signal EOF.
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(prompt.as_bytes())
            .map_err(|e| format!("failed to write prompt to judge stdin: {e}"))?;
        // stdin is dropped here → closes the pipe → EOF to the process.
    }

    // Drain stdout and stderr on separate threads so neither pipe can fill
    // and stall the child, while the Child handle STAYS IN THIS SCOPE so the
    // timeout arm can kill the process. The previous wait_with_output shape
    // moved the handle into the thread; a timed-out judge then lived until
    // the benchmark exited. Mirrors run_rerank_subprocess.
    use std::io::Read;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "judge stdout unavailable".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "judge stderr unavailable".to_string())?;
    let (tx_out, rx_out) = std::sync::mpsc::channel::<Vec<u8>>();
    let (tx_err, rx_err) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut handle = stdout;
        let _ = handle.read_to_end(&mut buf);
        let _ = tx_out.send(buf);
    });
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut handle = stderr;
        let _ = handle.read_to_end(&mut buf);
        let _ = tx_err.send(buf);
    });

    let timeout = std::time::Duration::from_secs(timeout_secs);
    // One deadline bounds the WHOLE subprocess interaction: pipe drains AND
    // the exit wait. A child that closes both pipes and keeps running
    // satisfies the drains instantly, so the exit wait must carry the same
    // bound or the run hangs (Wave-3 G2).
    let deadline = std::time::Instant::now() + timeout;
    let stdout_bytes = match rx_out.recv_timeout(timeout) {
        Ok(bytes) => bytes,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("judge command timed out after {timeout_secs}s"));
        }
    };
    // stderr EOF follows pipe close; bounded by the same overall deadline.
    let stderr_bytes = rx_err.recv_timeout(timeout).unwrap_or_default();
    let status = crate::config::wait_with_deadline(&mut child, deadline)
        .ok_or_else(|| {
            format!(
                "judge command timed out after {timeout_secs}s (pipes closed, process still alive — killed)"
            )
        })?;

    if !status.success() {
        let code = status.code().unwrap_or(-1);
        let stderr_text = String::from_utf8_lossy(&stderr_bytes);
        let stderr_preview: String = stderr_text.chars().take(200).collect();
        let suffix = if stderr_preview.is_empty() {
            String::new()
        } else {
            format!(": {stderr_preview}")
        };
        return Err(format!("judge command exited {code}{suffix}"));
    }

    let raw = String::from_utf8_lossy(&stdout_bytes);
    Ok(raw.trim().to_string())
}

// ─────────────────────────────────────────────────────────────────────────────
// Answer grader
// ─────────────────────────────────────────────────────────────────────────────

/// Grades a judge answer against the dataset's gold answer.
///
/// Algorithm: normalize both strings via `lme_normalize_for_evidence`
/// (lowercase + collapse whitespace), then check if the normalized gold
/// answer is a substring of the normalized judge answer.
///
/// Returns false when either input normalizes to empty.
///
/// Twin of Swift `lmeGradeJudgeAnswer(_:goldAnswer:)`.
pub fn lme_grade_judge_answer(judge_answer: &str, gold_answer: &str) -> bool {
    let norm_judge = lme_normalize_for_evidence(judge_answer);
    let norm_gold = lme_normalize_for_evidence(gold_answer);
    if norm_gold.is_empty() || norm_judge.is_empty() {
        return false;
    }
    norm_judge.contains(norm_gold.as_str())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────


// ── Verdict grading (published-protocol parity) ──────────────────────────────

/// How a judge answer is graded against the dataset's gold answer.
///
/// The two modes are NOT interchangeable and a run must record which it used
/// — they answer different questions and produce different numbers on
/// identical answers. Twin of Swift `LMEJudgeGrading`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LmeJudgeGrading {
    /// Deterministic normalized-substring containment. No second model call,
    /// no non-determinism, but it under-counts every semantically-correct
    /// paraphrase.
    Substring,
    /// A second model call returns a correctness verdict. This is the protocol
    /// published leaderboard numbers are produced under, so it is the mode to
    /// use when a cell is meant to sit beside one.
    Verdict,
}

impl LmeJudgeGrading {
    /// Parse from a CLI string. Twin of the Swift raw-value init.
    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "substring" => Ok(LmeJudgeGrading::Substring),
            "verdict" => Ok(LmeJudgeGrading::Verdict),
            other => Err(format!(
                "--judge-grading must be 'substring' or 'verdict'; got '{other}'"
            )),
        }
    }

    /// The raw string as written to report JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            LmeJudgeGrading::Substring => "substring",
            LmeJudgeGrading::Verdict => "verdict",
        }
    }
}

/// Formats the verdict-step prompt: given the question, the gold answer, and a
/// candidate answer, ask for a single-word correctness verdict.
///
/// Deliberately narrow: the judge grades semantic equivalence of the ANSWER,
/// it does not re-answer the question. The wording is stable — changing it
/// changes the meaning of stored verdicts. Twin of Swift `lmeVerdictPrompt`.
pub fn lme_verdict_prompt(question: &str, gold_answer: &str, candidate_answer: &str) -> String {
    format!(
        // Continuation lines carry NO source indentation: in a Rust string
        // body, `\` at end of line strips the newline and the NEXT line's
        // leading whitespace, but spaces written after an explicit `\n\n`
        // escape are literal. Indenting them here would send the judge an
        // indented prompt while the Swift twin sends a flush-left one, and
        // the two ports' stored verdicts would no longer mean the same thing.
        // Byte-identical to Swift `lmeVerdictPrompt`.
        "You are grading a single answer for correctness.\n\
\n\
Reply with exactly one word and nothing else: CORRECT or INCORRECT. \
Do not explain, do not restate the question, do not qualify the verdict.\n\
\n\
The candidate answer is CORRECT when it conveys the same fact as the \
reference answer — wording, length, and extra context do not matter. \
It is INCORRECT when it states a different fact, contradicts the \
reference, or declines to answer.\n\
\n\
Question: {question}\n\
\n\
Reference answer: {gold_answer}\n\
\n\
Candidate answer: {candidate_answer}\n\
\n\
Verdict:"
    )
}

/// Parses a verdict-step reply into a correctness decision.
///
/// The verdict is read POSITIONALLY, from one of the two slots the prompt
/// actually defines. Nothing else in the reply is consulted:
///
///   1. The first token of the reply — `lme_verdict_prompt` asks for exactly
///      one word and nothing else, so that word is the verdict.
///   2. Failing that, the first token after the LAST colon — the prompt ends
///      with a bare `Verdict:` label, so a judge that echoes the label is an
///      expected shape ("Verdict: CORRECT", "The verdict is: INCORRECT").
///
/// Returns `None` for anything else, so the caller can treat an unparseable
/// verdict as a judge failure rather than silently scoring it wrong.
///
/// Why not search the reply for the word: "not correct" CONTAINS "CORRECT",
/// so a substring scan graded every negated reply as correct and inflated
/// answer accuracy. Position is the fix.
///
/// Sentiment is deliberately not interpreted. A negation blocklist ("contains
/// 'not' => false") fails on "not incorrect" and on every phrasing nobody
/// enumerated, so it is not used: under this contract "not incorrect" is
/// simply unparseable — a verdict that is not in its slot is absent, not a
/// double negative to be resolved. Twin of Swift `lmeParseVerdict`.
pub fn lme_parse_verdict(reply: &str) -> Option<bool> {
    // Slot 1: the reply itself is the verdict word.
    if let Some(verdict) = verdict_token(reply) {
        return Some(verdict);
    }
    // Slot 2: the judge echoed the prompt's label ahead of the verdict.
    let (_, after_last_colon) = reply.rsplit_once(':')?;
    verdict_token(after_last_colon)
}

/// Matches the FIRST whitespace-delimited token of `text` against the two
/// verdict words, exactly.
///
/// Leading and trailing non-letters are discarded so markdown emphasis and
/// trailing punctuation do not defeat the match ("**CORRECT**", "INCORRECT,"
/// and "CORRECT." all read as the bare word). The comparison is otherwise
/// exact, which is what keeps "not" from ever matching "CORRECT".
/// Twin of Swift `lmeVerdictToken`.
fn verdict_token(text: &str) -> Option<bool> {
    let raw = text.split_whitespace().next()?;
    let token: String = raw
        .chars()
        .skip_while(|c| !c.is_alphabetic())
        .take_while(|c| c.is_alphabetic())
        .collect::<String>()
        .to_uppercase();
    match token.as_str() {
        "CORRECT" => Some(true),
        "INCORRECT" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Wave-3 G2: every subprocess stage bounded ─────────────────────────────

    #[test]
    fn judge_pipes_closed_still_alive_is_killed() {
        // Closing both pipes satisfies the drain threads instantly; only the
        // bounded exit wait can end this run. 1s test bound; production 120s.
        let start = std::time::Instant::now();
        let err = lme_run_judge_with_timeout("exec 1>&- 2>&-; sleep 60", "test", 1)
            .expect_err("a pipe-closing sleeper must read as timeout");
        assert!(err.contains("timed out"), "error must name the timeout; got: {err}");
        assert!(
            start.elapsed() < std::time::Duration::from_secs(10),
            "control must return within the bound, not after sleep 60"
        );
    }

    // ── Wave-3 G4: command string not inherited by the child environment ──────

    #[test]
    fn judge_command_string_not_in_child_environment() {
        // The command dumps its own environment; the shell stub unsets the
        // carrier var before eval, so a command embedding an API key is not
        // inherited by the judge process or its descendants.
        let out = lme_run_judge("/usr/bin/env", "test").expect("env must run");
        assert!(
            !out.contains("MOOT_BENCH_CMD_INTERNAL"),
            "the carrier env var must be unset before the command runs; got: {out}"
        );
    }

    // ── Prompt formatting ──────────────────────────────────────────────────────

    #[test]
    fn prompt_includes_question() {
        let p = lme_judge_prompt("What is the capital?", "Paris is the capital.");
        assert!(
            p.contains("What is the capital?"),
            "prompt must contain the question"
        );
    }

    #[test]
    fn prompt_includes_payload() {
        let p = lme_judge_prompt("Q?", "Alice wrote the report.");
        assert!(
            p.contains("Alice wrote the report."),
            "prompt must contain the payload"
        );
    }

    #[test]
    fn prompt_ends_with_answer_cue() {
        let p = lme_judge_prompt("Q?", "P.");
        assert!(p.contains("Answer:"), "prompt must end with Answer: cue");
    }

    // ── Answer grading ─────────────────────────────────────────────────────────

    #[test]
    fn grade_exact_match() {
        assert!(lme_grade_judge_answer("Paris", "Paris"));
    }

    #[test]
    fn grade_case_insensitive() {
        assert!(lme_grade_judge_answer("paris", "Paris"));
    }

    #[test]
    fn grade_gold_substring_of_judge() {
        assert!(lme_grade_judge_answer("The answer is Paris.", "Paris"));
    }

    #[test]
    fn grade_miss() {
        assert!(!lme_grade_judge_answer("Berlin", "Paris"));
    }

    #[test]
    fn grade_empty_gold() {
        assert!(!lme_grade_judge_answer("Berlin", ""));
    }

    #[test]
    fn grade_empty_judge() {
        assert!(!lme_grade_judge_answer("", "Paris"));
    }

    #[test]
    fn grade_numeric_gold() {
        // Oracle variant answers can be integers.
        assert!(lme_grade_judge_answer("The count is 3.", "3"));
        assert!(!lme_grade_judge_answer("The count is 4.", "3"));
    }

    #[test]
    fn grade_whitespace_collapse() {
        // "New  York City" normalizes to "new york city"; gold "New York" normalizes
        // to "new york" → substring match.
        assert!(lme_grade_judge_answer("New  York City", "New York"));
    }

    // ── Subprocess runner ──────────────────────────────────────────────────────

    #[test]
    fn run_judge_echo_returns_arg() {
        // /bin/echo ignores stdin and prints its arg; exits 0.
        let result = lme_run_judge("/bin/echo hello-world", "ignored").unwrap();
        assert_eq!(result, "hello-world");
    }

    #[test]
    fn run_judge_cat_reads_stdin() {
        // /bin/cat reads stdin and echoes it.
        let result = lme_run_judge("/bin/cat", "test-prompt-value").unwrap();
        assert_eq!(result, "test-prompt-value");
    }

    #[test]
    fn run_judge_nonzero_exit_returns_err() {
        let result = lme_run_judge("/bin/sh -c 'exit 1'", "prompt");
        assert!(result.is_err(), "lme_run_judge should return Err on exit 1");
    }

    #[test]
    fn run_judge_multiline_prompt_reaches_stdin() {
        let multiline = "line one\nline two\nline three";
        let result = lme_run_judge("/bin/cat", multiline).unwrap();
        assert!(result.contains("line one"));
        assert!(result.contains("line three"));
    }

    // ── Verdict grading ────────────────────────────────────────────────────────

    #[test]
    fn parses_bare_verdicts() {
        assert_eq!(lme_parse_verdict("CORRECT"), Some(true));
        assert_eq!(lme_parse_verdict("INCORRECT"), Some(false));
    }

    #[test]
    fn parsing_is_case_insensitive_and_whitespace_tolerant() {
        assert_eq!(lme_parse_verdict("  correct \n"), Some(true));
        assert_eq!(lme_parse_verdict("\nIncorrect"), Some(false));
    }

    /// The substring trap: "INCORRECT" contains "CORRECT". Any parser that
    /// looks for "CORRECT" inside the reply grades every INCORRECT as correct
    /// — pinned deliberately. Matching the verdict token exactly rules it out.
    /// The second case reads from slot 2 (the echoed "Verdict:" label).
    #[test]
    fn incorrect_is_not_read_as_correct() {
        assert_eq!(lme_parse_verdict("INCORRECT"), Some(false));
        assert_eq!(lme_parse_verdict("The verdict is: INCORRECT"), Some(false));
    }

    /// REGRESSION (MXE-BK defect 1). A negated reply contains "CORRECT" as a
    /// substring, so the previous scan-the-whole-string parser returned
    /// `Some(true)` for every one of these and inflated answer accuracy. None
    /// of them may ever grade as correct again.
    ///
    /// Against pre-fix code all three returned `Some(true)`; they now return
    /// `None` — the verdict is not in either slot, so the caller falls back to
    /// substring grading instead of banking a correct answer it never got.
    #[test]
    fn negated_replies_never_grade_as_correct() {
        for reply in ["not correct", "not exactly correct", "this is not correct"] {
            assert_ne!(
                lme_parse_verdict(reply),
                Some(true),
                "negated reply {reply:?} must never grade as correct"
            );
            assert_eq!(
                lme_parse_verdict(reply),
                None,
                "negated reply {reply:?} is unparseable, not a wrong answer"
            );
        }
    }

    /// The parser is positional, NOT a negation blocklist. A blocklist would
    /// have to resolve "not incorrect" as a double negative and return
    /// `Some(true)`; this parser returns `None`, because the verdict is simply
    /// not in either slot. Sentiment is never read, so there is no
    /// phrasing-enumeration to get wrong.
    #[test]
    fn positional_parsing_is_not_a_negation_blocklist() {
        assert_eq!(lme_parse_verdict("not incorrect"), None);
    }

    /// The two slots the prompt defines, pinned. Slot 2 exists because the
    /// prompt ends with a bare "Verdict:" label, so a judge echoing it is an
    /// expected shape rather than a failure.
    #[test]
    fn verdict_is_read_from_either_positional_slot() {
        // Slot 1: the reply is the word, with markdown or punctuation on it.
        assert_eq!(lme_parse_verdict("**CORRECT**"), Some(true));
        assert_eq!(lme_parse_verdict("INCORRECT."), Some(false));
        // Slot 2: the label was echoed ahead of the verdict.
        assert_eq!(lme_parse_verdict("Verdict: CORRECT"), Some(true));
        assert_eq!(
            lme_parse_verdict("Reasoning: it differs. Verdict: INCORRECT"),
            Some(false)
        );
        // Slot 2 does not rescue a negated verdict.
        assert_eq!(lme_parse_verdict("Verdict: not correct"), None);
    }

    /// The prompt must forbid explanation, or the positional contract above
    /// has no basis. Pinned so a future prompt edit cannot silently loosen it.
    #[test]
    fn verdict_prompt_demands_one_word_and_nothing_else() {
        let p = lme_verdict_prompt("q", "g", "c");
        assert!(p.contains("exactly one word and nothing else"));
        assert!(p.contains("Do not explain"));
    }

    /// The prompt must be byte-identical to the Swift twin. A `\n\n` in a Rust
    /// string body does NOT strip whitespace written after it, so it is easy to
    /// leave source indentation in the prompt the judge actually receives —
    /// which this port did until MXE-BK. `contains()` assertions are blind to
    /// it, so every line is pinned flush-left explicitly.
    #[test]
    fn verdict_prompt_has_no_leading_indentation_on_any_line() {
        let p = lme_verdict_prompt("q", "g", "c");
        for line in p.lines() {
            assert!(
                !line.starts_with(' '),
                "prompt line is indented, so this port no longer matches the \
                 Swift twin and stored verdicts diverge: {line:?}"
            );
        }
        // The paragraph breaks the Swift twin emits, spelled out.
        assert!(p.starts_with("You are grading a single answer for correctness.\n\nReply with"));
        assert!(p.contains("\n\nQuestion: q\n\nReference answer: g\n\nCandidate answer: c\n\nVerdict:"));
    }

    /// A chatty judge that uses both words: the verdict is the one in slot 1,
    /// the reply's first token. The other occurrence is prose and is never
    /// consulted — position decides, not order of appearance.
    #[test]
    fn chatty_reply_is_read_from_its_first_token() {
        assert_eq!(
            lme_parse_verdict("CORRECT — it would be INCORRECT to say otherwise"),
            Some(true)
        );
        assert_eq!(
            lme_parse_verdict("INCORRECT, the CORRECT answer is Paris"),
            Some(false)
        );
    }

    #[test]
    fn unparseable_returns_none() {
        assert_eq!(lme_parse_verdict("I'm not sure"), None);
        assert_eq!(lme_parse_verdict(""), None);
    }

    #[test]
    fn verdict_prompt_carries_all_three_inputs() {
        let p = lme_verdict_prompt("Where did she move?", "Lisbon", "She relocated to Lisbon.");
        assert!(p.contains("Where did she move?"));
        assert!(p.contains("Lisbon"));
        assert!(p.contains("She relocated to Lisbon."));
        assert!(p.contains("CORRECT"));
    }

    #[test]
    fn grading_mode_round_trips() {
        assert_eq!(LmeJudgeGrading::from_str("verdict").unwrap().as_str(), "verdict");
        assert_eq!(
            LmeJudgeGrading::from_str("substring").unwrap().as_str(),
            "substring"
        );
        assert!(LmeJudgeGrading::from_str("bogus").is_err());
    }
}
