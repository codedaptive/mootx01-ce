//! Dream-time adornment generation seam for MOOTx01 (SPEC_ADORNMENT §3).
//!
//! The generator is a SEAM, not a model. It delegates to an external command
//! via the `MOOT_MINT_CMD` environment variable (stdin prompt → stdout claim),
//! then trims and mechanically truncates the output to the contract
//! length before returning (Bob ruling 2026-08-24).
//!
//! Thread safety: all public entry points are synchronous blocking calls
//! wrapping `std::process::Command`. Concurrent invocations spawn independent
//! child processes with no shared mutable state.
//!
//! Ports `AdornmentGenerator.swift` field-for-field.

use std::io::Write;
use std::io::{BufRead, BufReader};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;

// MARK: - Constants

/// Maximum character length of an adornment string.
///
/// Provisional pending the judging-density study (SPEC_ADORNMENT §2).
/// The density study will run the audition tool at multiple lengths
/// (controlled at runtime via the benchmark harness) and select the
/// length that maximises judged synthesize quality per token of context
/// consumed. The winning length seeds the next production const revision.
///
/// Over-length output is mechanically truncated to this length (Bob
/// ruling 2026-08-24). The prompt asks for under-limit output softly
/// ("less is better") and deliberately never mentions truncation — the
/// ceiling is enforced in code, not negotiated with the model.
pub const ADORNMENT_MAX_LENGTH: usize = 280;

// MARK: - Prompt template

/// Build the generation prompt for a single drawer.
///
/// Template per SPEC_ADORNMENT §2b as amended by Bob's date ruling
/// (2026-08-24): summarize the meaning tightly; entities named in full
/// (no pronouns, no session-relative references); dates appear ONLY when
/// available in the prompt data — stated in the record, or calculable
/// from a natural-language reference plus the supplied record date;
/// counts explicit when stated; densest-first within the length budget.
///
/// - `drawer_content`: The verbatim body text of the drawer being adorned.
/// - `event_date`: The record's own date (drawer filed_at / corpus session
///   date). When provided it is included in the prompt so relative
///   references ("next month") are calculable; when `None` the model is
///   instructed to state only dates the record itself contains.
/// - `max_length`: The maximum character length the model must respect.
///   Pass `ADORNMENT_MAX_LENGTH` for production; benchmark audition callers
///   may pass a different value for density studies.
pub fn build_adornment_prompt(
    drawer_content: &str,
    event_date: Option<&str>,
    max_length: usize,
) -> String {
    // Bob rulings 2026-08-24: output is word blobs (2-3 word chunks,
    // "; "-separated, importance-decreasing), not sentences; dates appear
    // only when available in the prompt data (the record-date line is
    // emitted only when provided so relative references are calculable);
    // the length line is a soft ask — the ceiling is enforced by
    // mechanical truncation in the seam, never mentioned to the model.
    // Output must stay byte-identical to the Swift twin for the same
    // inputs.
    let record_date_line = event_date
        .map(|d| format!("Record date: {d}\n\n"))
        .unwrap_or_default();
    format!(
        "{record_date_line}Summarize the meaning of the following memory record as ONE dense line of \
word blobs: 2-3 word chunks separated by \"; \" — not sentences, no grammar, just the \
densest possible chunks of the record's knowledge (example: \"tomato saplings planted; \
straw mulch; 12 count\"). Requirements:\n\
- Name every entity in full (no pronouns, no relative references like \"the user\" or \"it\").\n\
- Only include dates if available in the prompt data: dates stated in the record, or \
calculable from a natural-language reference plus the record date above. Never invent a date.\n\
- State counts and quantities as numbers only when the record states them.\n\
- Do not include any opinion, narrative, or commentary.\n\
- Results should be under {max_length} characters, less is better; list blobs in decreasing order of importance.\n\n\
Memory record:\n\
{drawer_content}\n\n\
Adornment:",
    )
}

// MARK: - Map-reduce chunking

/// Character threshold above which a record is minted in pieces.
/// Twin of `ADORNMENT_CHUNK_THRESHOLD` in AdornmentGenerator.swift.
pub const ADORNMENT_CHUNK_THRESHOLD: usize = 16_000;

/// Mint an adornment for one record, chunking when the record exceeds
/// the miner window (Bob miner-shape ruling, 2026-08-25). Twin of
/// `mintAdornmentMapReduce` in AdornmentGenerator.swift: small records
/// are one prompt/one mint; oversized records split on line boundaries
/// into <=threshold pieces, each piece is minted, the piece-summaries
/// are concatenated and re-summarized for the final blob line.
///
/// Returns `None` when every mint attempt returned `None` (record
/// stays in debt).
pub fn mint_adornment_map_reduce(
    drawer_content: &str,
    event_date: Option<&str>,
    max_length: usize,
    chunk_threshold: usize,
    mut mint: impl FnMut(&str) -> Option<String>,
) -> Option<String> {
    if drawer_content.chars().count() <= chunk_threshold {
        let prompt = build_adornment_prompt(drawer_content, event_date, max_length);
        return mint(&prompt);
    }

    // Split on line boundaries into <=threshold pieces; a single line
    // longer than the threshold becomes its own piece. Deterministic.
    let mut pieces: Vec<String> = Vec::new();
    let mut current = String::new();
    for line in drawer_content.split('\n') {
        if !current.is_empty()
            && current.chars().count() + line.chars().count() + 1 > chunk_threshold
        {
            pieces.push(std::mem::take(&mut current));
        }
        if !current.is_empty() {
            current.push('\n');
        }
        current.push_str(line);
    }
    if !current.is_empty() {
        pieces.push(current);
    }

    let mut piece_summaries: Vec<String> = Vec::new();
    for piece in &pieces {
        let prompt = build_adornment_prompt(piece, event_date, max_length);
        if let Some(summary) = mint(&prompt) {
            piece_summaries.push(summary);
        }
    }
    if piece_summaries.is_empty() {
        return None;
    }

    // Reduce: summarize the combined piece-summaries into the final line.
    let combined = piece_summaries.join("\n");
    let final_prompt = build_adornment_prompt(&combined, event_date, max_length);
    mint(&final_prompt)
}

// MARK: - Generator seam

/// Generate an adornment for a single drawer using the external minting command.
///
/// The command is read from the `MOOT_MINT_CMD` environment variable.
/// The prompt is written to the command's stdin; the command must write
/// the generated adornment text to stdout and exit 0.
///
/// Output handling: empty output is discarded; non-empty output is
/// mechanically truncated to `max_length` characters (Bob ruling
/// 2026-08-24 — the prompt never mentions truncation; the code
/// enforces the ceiling).
///
/// Returns `None` when the command is absent, exits non-zero, or
/// produces non-UTF-8 or empty output.
pub fn invoke_adornment_command(prompt: &str, max_length: usize) -> Option<String> {
    // Read the mint command path from the environment.
    // MOOT_MINT_CMD must be an absolute path to an executable that reads a
    // prompt from stdin and writes the adornment to stdout. If the variable
    // is absent or empty, the seam is inactive and no adornment is produced.
    // The resident GoldMiner engine wins over every subprocess path: when
    // the composition layer installed an in-process engine (the product
    // shape — quantized local model, resident, no spawns), all mints route
    // through it. The command seam below survives as the harness vehicle.
    if crate::gold_miner::engine_installed() {
        let raw = crate::gold_miner::mint_one(prompt)?;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        return Some(trimmed.chars().take(max_length).collect());
    }

    let mint_cmd = std::env::var("MOOT_MINT_CMD").ok()?;
    if mint_cmd.is_empty() {
        return None;
    }

    // Resident batch mode: the minter loads its model ONCE and serves
    // NUL-delimited prompts for the life of the session. A one-shot spawn
    // costs a full model load per 280-character claim — three orders of
    // magnitude of waste when a pass mints hundreds of pairs. The mode is
    // selected by CAPABILITY PROBE, never configuration: the seam runs
    // `CMD --mint-capabilities` once per command (cached) and uses batch
    // when the minter lists "batch"; minters that do not answer the probe
    // are driven one-shot. Twin of Swift `ResidentMintSession`.
    if supports_batch(&mint_cmd) {
        let candidate = resident_mint(prompt, &mint_cmd)?;
        let trimmed = candidate.trim();
        if trimmed.is_empty() {
            return None;
        }
        return Some(trimmed.chars().take(max_length).collect());
    }

    let mut child = Command::new(&mint_cmd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    // Write the prompt to stdin, then close so the child sees EOF.
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes());
        // stdin is dropped here, closing the pipe.
    }

    let output = child.wait_with_output().ok()?;

    // Treat non-zero exit as validation failure.
    if !output.status.success() {
        return None;
    }

    let raw_text = String::from_utf8(output.stdout).ok()?;

    // Trim leading/trailing whitespace — the model may pad its output;
    // the stored adornment must be the clean claim text.
    let candidate = raw_text.trim();

    if candidate.is_empty() {
        return None;
    }

    // Mechanical truncation at the contract length (Bob ruling
    // 2026-08-24): the prompt never mentions truncation; the code
    // enforces the ceiling. chars() (Unicode scalars) matches the Swift
    // twin's prefix() for all ASCII output, same convention as the
    // subject generator.
    Some(candidate.chars().take(max_length).collect())
}


// ── Resident batch session (twin of Swift ResidentMintSession) ─────────────

/// One resident minter child for the batch protocol: spawned with
/// `--batch`, prompts written NUL-terminated, responses read
/// NUL-terminated in order. Any protocol fault (spawn failure, torn
/// frame, child exit) tears the child down and reports None for the
/// in-flight prompt — the pair counts as failed and the next call
/// respawns. A caller presenting a DIFFERENT command (minter activation
/// changed) also tears down first: replies from the previous minter must
/// never answer the new minter's prompts.
///
/// No idle reaper here: the Rust generator runs inside short-lived pass
/// invocations on the server; the child is reaped when the process exits
/// or the command changes. (The Swift twin adds a 120 s idle reaper for
/// the long-lived macOS daemon.)
struct ResidentMint {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<std::process::ChildStdout>,
    command: String,
}

static RESIDENT_MINT: Mutex<Option<ResidentMint>> = Mutex::new(None);
static PROBE_CACHE: Mutex<Vec<(String, bool)>> = Mutex::new(Vec::new());

/// Whether `command` speaks the batch protocol, probed once per path:
/// `CMD --mint-capabilities` must exit 0 and list "batch" on stdout. The
/// probe answers before any model load by contract; a minter that errors
/// on the flag sees a closed stdin and exits on its empty-prompt path.
fn supports_batch(command: &str) -> bool {
    if let Ok(cache) = PROBE_CACHE.lock() {
        if let Some((_, hit)) = cache.iter().find(|(c, _)| c == command) {
            return *hit;
        }
    }
    let result = Command::new(command)
        .arg("--mint-capabilities")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map(|out| {
            out.status.success()
                && String::from_utf8_lossy(&out.stdout)
                    .lines()
                    .any(|l| l.trim() == "batch")
        })
        .unwrap_or(false);
    if let Ok(mut cache) = PROBE_CACHE.lock() {
        cache.push((command.to_string(), result));
    }
    result
}

fn resident_mint(prompt: &str, command: &str) -> Option<String> {
    let mut guard = RESIDENT_MINT.lock().ok()?;

    let needs_spawn = match guard.as_mut() {
        Some(session) => {
            session.command != command
                || session.child.try_wait().map(|s| s.is_some()).unwrap_or(true)
        }
        None => true,
    };
    if needs_spawn {
        if let Some(mut old) = guard.take() {
            let _ = old.child.kill();
            let _ = old.child.wait();
        }
        let mut child = Command::new(command)
            .arg("--batch")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // stderr inherits: the minter's diagnostics land in the server
            // log instead of a pipe nobody drains.
            .spawn()
            .ok()?;
        let stdin = child.stdin.take()?;
        let stdout = BufReader::new(child.stdout.take()?);
        *guard = Some(ResidentMint {
            child,
            stdin,
            stdout,
            command: command.to_string(),
        });
    }

    let session = guard.as_mut()?;
    let mut frame = prompt.as_bytes().to_vec();
    frame.push(0);
    if session.stdin.write_all(&frame).and_then(|_| session.stdin.flush()).is_err() {
        let mut old = guard.take()?;
        let _ = old.child.kill();
        let _ = old.child.wait();
        return None;
    }

    let mut response: Vec<u8> = Vec::new();
    match session.stdout.read_until(0u8, &mut response) {
        Ok(n) if n > 0 && response.last() == Some(&0u8) => {
            response.pop();
            // Empty payload = the child's per-prompt failure marker.
            if response.is_empty() {
                return None;
            }
            String::from_utf8(response).ok()
        }
        _ => {
            // EOF mid-response or read error: torn session.
            let mut old = guard.take()?;
            let _ = old.child.kill();
            let _ = old.child.wait();
            None
        }
    }
}
