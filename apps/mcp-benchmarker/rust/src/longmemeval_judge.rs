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
        "Answer the following question using ONLY the provided context. \
If the answer is not found in the context, respond with \"I don't know\". \
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
/// Twin of Swift `lmeRunJudge(cmd:prompt:)`.
///
/// # Errors
///
/// Returns `Err(String)` when:
/// - The subprocess fails to spawn.
/// - The subprocess exits with a non-zero status code.
pub fn lme_run_judge(cmd: &str, prompt: &str) -> Result<String, String> {
    let mut child = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
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

    let output = child
        .wait_with_output()
        .map_err(|e| format!("failed to wait for judge process: {e}"))?;

    if !output.status.success() {
        let code = output.status.code().unwrap_or(-1);
        let stderr_text = String::from_utf8_lossy(&output.stderr);
        let stderr_preview: String = stderr_text.chars().take(200).collect();
        let suffix = if stderr_preview.is_empty() {
            String::new()
        } else {
            format!(": {stderr_preview}")
        };
        return Err(format!("judge command exited {code}{suffix}"));
    }

    let raw = String::from_utf8_lossy(&output.stdout);
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
