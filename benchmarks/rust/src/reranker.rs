//! reranker.rs — post-retrieval reranking via an external command.
//!
//! Rust twin of `Reranker.swift`. Provides the same four surfaces:
//!
//! - [`apply_rerank`]         — top-level entry point; returns reranked IDs + failure flag.
//! - [`build_rerank_prompt`]  — numbered candidate prompt construction.
//! - [`run_rerank_subprocess`] — subprocess launch, stdin/stdout, exit-code check.
//! - [`parse_rerank_reply`]   — parse the model's reply for integer positions.
//! - [`apply_permutation`]    — apply a partial permutation to the ranked list.
//!
//! The command contract mirrors `--judge-cmd` (see `longmemeval_judge.rs`):
//! the command reads the prompt on stdin and writes its reply on stdout (exit 0).
//!
//! SECRECY RULE: the command string may carry API keys. The report records
//! PRESENCE ONLY (`rerank_cmd_set: bool`). Never log, hash, or derive any
//! value from the command text.
//!
//! Failure contract: subprocess errors and completely unparseable replies are
//! non-fatal. [`apply_rerank`] returns the ORIGINAL ranked list and sets
//! `failed = true` so the caller can increment its run-level `rerank_failures`
//! counter.

use std::collections::HashSet;
use std::io::Write;

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Maximum number of candidates handed to the rerank command. Candidates
/// beyond this window keep their original relative positions after the
/// reranked head. Twin of Swift `rerankWindowSize`.
pub const RERANK_WINDOW_SIZE: usize = 10;

/// Maximum preview characters shown per candidate in the rerank prompt.
/// Keeps prompts token-lean while giving the model enough signal for ordering.
/// Twin of Swift `rerankPreviewLength`.
pub const RERANK_PREVIEW_LENGTH: usize = 120;

// ─────────────────────────────────────────────────────────────────────────────
// Public interface
// ─────────────────────────────────────────────────────────────────────────────

/// Applies an external rerank command to a ranked hit list.
///
/// Builds a numbered prompt of the top `RERANK_WINDOW_SIZE` candidates and
/// pipes it to `cmd` via `/bin/sh -c`. The reply is parsed for integers in
/// `[1, window]`. Named candidates move to the front in reply order; unnamed
/// candidates follow in their original relative order. Candidates beyond the
/// window are appended unchanged.
///
/// Returns the (possibly unchanged) ID list and a failure flag. `failed` is
/// true when the subprocess returned a non-zero exit, produced a completely
/// unparseable reply (no valid integers found), or threw a launch error. Any
/// of these conditions leaves `ids` unchanged and increments the caller's
/// `rerank_failures` counter.
///
/// Twin of Swift `applyRerank(cmd:question:ids:previews:)`.
pub fn apply_rerank(
    cmd: &str,
    question: &str,
    ids: &[String],
    previews: &[String],
) -> (Vec<String>, bool) {
    let window = RERANK_WINDOW_SIZE.min(ids.len());
    if window == 0 {
        // Nothing to rerank — treat as success.
        return (ids.to_vec(), false);
    }

    let prompt = build_rerank_prompt(question, ids, previews, window);

    let reply = match run_rerank_subprocess(cmd, &prompt) {
        Some(r) => r,
        None => {
            // Subprocess failure (launch error or non-zero exit).
            return (ids.to_vec(), true);
        }
    };

    let named = parse_rerank_reply(&reply, window);
    if named.is_empty() {
        // Completely unparseable reply.
        return (ids.to_vec(), true);
    }

    let reranked = apply_permutation(ids, &named, window);
    (reranked, false)
}

// ─────────────────────────────────────────────────────────────────────────────
// Prompt construction
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the rerank prompt from the question and the top-`window` candidates.
///
/// Format mirrors the Swift twin: numbered list, best-first ordering
/// instructions, omitted candidates stay in relative order.
///
/// Twin of Swift `buildRerankPrompt(question:ids:previews:window:)`.
pub fn build_rerank_prompt(question: &str, ids: &[String], previews: &[String], window: usize) -> String {
    let mut lines = vec![
        "Rerank the following memory candidates for the question below.".to_string(),
        "Reply with candidate numbers, best first, space- or comma-separated.".to_string(),
        "Omitted candidates remain in their original relative order after the ones you list.".to_string(),
        String::new(),
        format!("Question: {question}"),
        String::new(),
        "Candidates:".to_string(),
    ];
    for i in 0..window {
        let id = &ids[i];
        let raw_preview = previews.get(i).map(String::as_str).unwrap_or("");
        // Truncate to RERANK_PREVIEW_LENGTH chars (char boundary safe via char_indices).
        let preview: &str = if raw_preview.len() > RERANK_PREVIEW_LENGTH {
            // Find the last char boundary at or before the limit.
            let mut end = RERANK_PREVIEW_LENGTH;
            while !raw_preview.is_char_boundary(end) {
                end -= 1;
            }
            &raw_preview[..end]
        } else {
            raw_preview
        };
        lines.push(format!("{}. {}: {}", i + 1, id, preview));
    }
    lines.join("\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Subprocess invocation
// ─────────────────────────────────────────────────────────────────────────────


/// Runs the rerank command as a subprocess. Returns the stdout string on exit
/// 0, `None` on launch error, non-zero exit, or timeout.
///
/// Mirrors `lme_run_judge` (longmemeval_judge.rs): the command is launched via
/// `/bin/sh -c <cmd>`, the prompt is written to stdin, and stdout is read to
/// end of file before the process exits.
///
/// Stderr is discarded (`Stdio::null`) to prevent any chance of pipe-buffer
/// stall. Stdout is collected on a background thread so `recv_timeout` can
/// bound the total wall time.
///
/// Twin of Swift `runRerankSubprocess(cmd:prompt:)`.
pub fn run_rerank_subprocess(cmd: &str, prompt: &str) -> Option<String> {
    run_rerank_subprocess_with_timeout(cmd, prompt, crate::config::subprocess_timeout_secs())
}

/// Timeout-parameterized body of `run_rerank_subprocess`, split out so tests
/// can exercise the timeout paths in seconds instead of the production 120s.
pub(crate) fn run_rerank_subprocess_with_timeout(
    cmd: &str,
    prompt: &str,
    timeout_secs: u64,
) -> Option<String> {
    // Inject the command via the private MOOT_BENCH_CMD_INTERNAL env var so
    // that a command carrying an API key is not visible in `ps` argv output.
    // The shell stub copies the var to a local and UNSETS the export before
    // eval, so the command string is NOT inherited by the rerank process or
    // its descendants (Wave-3 G4). Full shell semantics (pipes, env-var
    // expansion, quoted args) are preserved by the eval.
    let mut child = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(r#"__moot_bench_cmd="$MOOT_BENCH_CMD_INTERNAL"; unset MOOT_BENCH_CMD_INTERNAL; eval "$__moot_bench_cmd""#)
        .env("MOOT_BENCH_CMD_INTERNAL", cmd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        // Discard stderr: the parent never reads it, and piping it without
        // reading risks a pipe-buffer stall if the reranker is verbose.
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    // Write the prompt to stdin and close so the subprocess sees EOF.
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes());
        // stdin drops here, closing the pipe.
    }

    // Collect stdout on a background thread so we can enforce a timeout via
    // channel recv_timeout. This prevents a hung reranker from blocking the run.
    let stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        use std::io::Read;
        let mut buf = Vec::new();
        let mut handle = stdout;
        let _ = handle.read_to_end(&mut buf);
        let _ = tx.send(buf);
    });

    let timeout = std::time::Duration::from_secs(timeout_secs);
    // One deadline bounds pipe drain AND exit wait: a child that closes
    // stdout but keeps running would hang a plain wait() (Wave-3 G2).
    let deadline = std::time::Instant::now() + timeout;
    match rx.recv_timeout(timeout) {
        Ok(bytes) => match crate::config::wait_with_deadline(&mut child, deadline) {
            Some(status) if status.success() => String::from_utf8(bytes).ok(),
            _ => None,
        },
        Err(_) => {
            // Timeout or channel error: kill the child and treat as failure.
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reply parsing
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a rerank reply for integers in `[1, window_size]`, deduplicating
/// in first-seen order. Treats commas and whitespace as delimiters.
///
/// Returns the ordered list of valid, unique 1-based positions found in the
/// reply. Returns an empty `Vec` when none are found (counts as failure in
/// `apply_rerank`).
///
/// Twin of Swift `parseRerankReply(_:windowSize:)`.
pub fn parse_rerank_reply(reply: &str, window_size: usize) -> Vec<usize> {
    // Split on whitespace and commas.
    let mut result: Vec<usize> = Vec::new();
    let mut seen: HashSet<usize> = HashSet::new();
    for token in reply.split(|c: char| c.is_ascii_whitespace() || c == ',') {
        let trimmed = token.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Ok(n) = trimmed.parse::<usize>() {
            if n >= 1 && n <= window_size && seen.insert(n) {
                result.push(n);
            }
        }
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Permutation application
// ─────────────────────────────────────────────────────────────────────────────

/// Applies a partial permutation to the ranked ID list.
///
/// `named` is an ordered list of 1-based candidate positions from the reply.
/// Named candidates are placed first in reply order. Unnamed candidates within
/// the window follow in their original relative order. Candidates beyond
/// `window` are appended unchanged.
///
/// Twin of Swift `applyPermutation(ids:named:window:)`.
pub fn apply_permutation(ids: &[String], named: &[usize], window: usize) -> Vec<String> {
    let mut result: Vec<String> = Vec::with_capacity(ids.len());
    let named_set: HashSet<usize> = named.iter().copied().collect();

    // Named candidates in reply order (convert 1-based to 0-based).
    for &n in named {
        result.push(ids[n - 1].clone());
    }
    // Unnamed candidates within the window in original relative order.
    for i in 0..window {
        if !named_set.contains(&(i + 1)) {
            result.push(ids[i].clone());
        }
    }
    // Candidates beyond the window keep their positions.
    result.extend_from_slice(&ids[window..]);
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Wave-3 G2/G4 — bounded lifecycle and env hygiene

    #[test]
    fn rerank_pipes_closed_still_alive_is_killed() {
        // A child that closes stdout but keeps running must read as a rerank
        // failure (None) within the bound, never hang in wait().
        let start = std::time::Instant::now();
        let result = run_rerank_subprocess_with_timeout("exec 1>&-; sleep 60", "test", 1);
        assert!(result.is_none(), "a pipe-closing sleeper must read as failure");
        assert!(
            start.elapsed() < std::time::Duration::from_secs(10),
            "control must return within the bound, not after sleep 60"
        );
    }

    #[test]
    fn rerank_command_string_not_in_child_environment() {
        let out = run_rerank_subprocess("/usr/bin/env", "test").expect("env must run");
        assert!(
            !out.contains("MOOT_BENCH_CMD_INTERNAL"),
            "the carrier env var must be unset before the command runs; got: {out}"
        );
    }

    // MARK: parse_rerank_reply

    #[test]
    fn parse_space_separated() {
        let result = parse_rerank_reply("3 1 2", 5);
        assert_eq!(result, vec![3, 1, 2]);
    }

    #[test]
    fn parse_comma_separated() {
        let result = parse_rerank_reply("2,4,1", 5);
        assert_eq!(result, vec![2, 4, 1]);
    }

    #[test]
    fn parse_mixed_delimiters() {
        let reply = "I recommend: 3, 1, 2 as the best order.";
        let result = parse_rerank_reply(reply, 5);
        assert_eq!(result, vec![3, 1, 2]);
    }

    #[test]
    fn parse_deduplicates() {
        let result = parse_rerank_reply("2 2 1", 5);
        assert_eq!(result, vec![2, 1], "duplicate 2 should appear only once");
    }

    #[test]
    fn parse_rejects_out_of_range() {
        // windowSize = 3, so 4 and 0 are out of range.
        let result = parse_rerank_reply("0 4 1 2", 3);
        assert_eq!(result, vec![1, 2], "0 and 4 are out of [1,3] and must be dropped");
    }

    #[test]
    fn parse_returns_empty_for_garbage() {
        let result = parse_rerank_reply("no idea which one", 5);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_handles_newlines() {
        let reply = "2\n1\n3";
        let result = parse_rerank_reply(reply, 5);
        assert_eq!(result, vec![2, 1, 3]);
    }

    // MARK: apply_permutation

    #[test]
    fn permutation_named_first() {
        let ids = vec!["A", "B", "C", "D", "E"].into_iter().map(String::from).collect::<Vec<_>>();
        let result = apply_permutation(&ids, &[3, 1], 5);
        assert_eq!(result, vec!["C", "A", "B", "D", "E"]);
    }

    #[test]
    fn permutation_unnamed_relative_order() {
        let ids = vec!["A", "B", "C", "D", "E", "F"].into_iter().map(String::from).collect::<Vec<_>>();
        // window = 4, reply names 4, 2 — named: D, B; unnamed in window: A, C; tail: E, F
        let result = apply_permutation(&ids, &[4, 2], 4);
        assert_eq!(result, vec!["D", "B", "A", "C", "E", "F"]);
    }

    #[test]
    fn permutation_tail_preserved() {
        let ids = vec!["A", "B", "C", "D", "E"].into_iter().map(String::from).collect::<Vec<_>>();
        // window = 3, reply names 2 — named: B; unnamed in window: A, C; tail: D, E
        let result = apply_permutation(&ids, &[2], 3);
        assert_eq!(result, vec!["B", "A", "C", "D", "E"]);
    }

    #[test]
    fn permutation_all_named() {
        let ids = vec!["A", "B", "C"].into_iter().map(String::from).collect::<Vec<_>>();
        let result = apply_permutation(&ids, &[3, 1, 2], 3);
        assert_eq!(result, vec!["C", "A", "B"]);
    }

    // MARK: build_rerank_prompt

    #[test]
    fn prompt_contains_question() {
        let prompt = build_rerank_prompt(
            "What did Alice eat?",
            &[String::from("id1"), String::from("id2")],
            &[String::from("She had pizza."), String::from("She had pasta.")],
            2,
        );
        assert!(prompt.contains("What did Alice eat?"));
    }

    #[test]
    fn prompt_numbers_candidates() {
        let prompt = build_rerank_prompt(
            "Q",
            &[String::from("id1"), String::from("id2"), String::from("id3")],
            &[String::from("p1"), String::from("p2"), String::from("p3")],
            3,
        );
        assert!(prompt.contains("1. id1: p1"));
        assert!(prompt.contains("2. id2: p2"));
        assert!(prompt.contains("3. id3: p3"));
    }

    #[test]
    fn prompt_truncates_long_previews() {
        let long_preview = "x".repeat(200);
        let prompt = build_rerank_prompt(
            "Q",
            &[String::from("id1")],
            &[long_preview],
            1,
        );
        let expected = "x".repeat(RERANK_PREVIEW_LENGTH);
        assert!(prompt.contains(&expected));
        assert!(!prompt.contains(&"x".repeat(RERANK_PREVIEW_LENGTH + 1)));
    }

    #[test]
    fn prompt_handles_missing_previews() {
        let prompt = build_rerank_prompt(
            "Q",
            &[String::from("id1"), String::from("id2")],
            &[String::from("only one preview")],
            2,
        );
        assert!(prompt.contains("1. id1: only one preview"));
        // id2 gets empty preview — line still present
        assert!(prompt.contains("2. id2: "));
    }

    // MARK: apply_rerank end-to-end with stub command

    #[test]
    fn rerank_reorders() {
        let ids = vec!["alpha", "beta", "gamma", "delta"].into_iter().map(String::from).collect::<Vec<_>>();
        let previews = vec!["p1", "p2", "p3", "p4"].into_iter().map(String::from).collect::<Vec<_>>();
        // Stub: always replies "3 1 2".
        // window = min(10, 4) = 4. Named: [3,1,2]. Unnamed in window: [4 → delta].
        let (reranked, failed) = apply_rerank("printf '3 1 2'", "test?", &ids, &previews);
        assert!(!failed, "stub command should succeed");
        assert_eq!(reranked, vec!["gamma", "alpha", "beta", "delta"]);
    }

    #[test]
    fn rerank_unparseable_leaves_original_order() {
        let ids = vec!["alpha", "beta", "gamma"].into_iter().map(String::from).collect::<Vec<_>>();
        let previews = vec!["p1", "p2", "p3"].into_iter().map(String::from).collect::<Vec<_>>();
        let (reranked, failed) = apply_rerank("printf 'I cannot rank these.'", "test?", &ids, &previews);
        assert!(failed, "unparseable reply should set failed = true");
        assert_eq!(reranked, ids);
    }

    #[test]
    fn rerank_subprocess_failure() {
        let ids = vec!["a", "b", "c"].into_iter().map(String::from).collect::<Vec<_>>();
        let previews = vec!["p1", "p2", "p3"].into_iter().map(String::from).collect::<Vec<_>>();
        let (reranked, failed) = apply_rerank("exit 1", "q", &ids, &previews);
        assert!(failed);
        assert_eq!(reranked, ids);
    }

    #[test]
    fn rerank_empty_ids_not_failed() {
        let (reranked, failed) = apply_rerank("printf '1'", "q", &[], &[]);
        assert!(!failed);
        assert!(reranked.is_empty());
    }
}
