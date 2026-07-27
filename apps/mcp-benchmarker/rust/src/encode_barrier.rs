// encode_barrier.rs — encode-queue synchronization strategy for benchmark runners.
//
// Twin of Swift `EncodeBarrier.swift`. The three modes, their semantics, and the
// drain polling logic are identical on both legs; the recorded "encode_barrier"
// JSON key in every report is the rawValue/as_str() of the chosen mode.
//
// Modes:
//   drain     Write without inline encoding, then poll `moot_drain_status` after
//   (default) all ingest completes, waiting for idle before the first query.
//             Official methodology for 1.0.x product.
//   impatient Write with `impatient: true` — inline encoding per write.
//             Correct key (previously wrong key "n" was silently ignored).
//   none      No barrier — documents the background-encoding race.

use std::thread;
use std::time::{Duration, Instant};

use crate::config::ResultFormat;
use crate::json_value::JsonValue;
use crate::mcp_client::{MCPClient, ToolCaller};
use std::collections::BTreeMap;

/// The encode-queue synchronization strategy for a benchmark run.
/// Recorded as the "encode_barrier" key in every report JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EncodeBarrier {
    /// Write without inline encoding; poll `moot_drain_status` post-ingest.
    Drain,
    /// Write with `impatient: true` — inline encoding per write.
    Impatient,
    /// No barrier. Documents the background-encoding race.
    None,
}

impl EncodeBarrier {
    /// Parse from a CLI string. Returns an error string on unknown value.
    pub fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "drain" => Ok(EncodeBarrier::Drain),
            "impatient" => Ok(EncodeBarrier::Impatient),
            "none" => Ok(EncodeBarrier::None),
            other => Err(format!(
                "--encode-barrier must be 'drain', 'impatient', or 'none'; got '{other}'"
            )),
        }
    }

    /// The raw string value as written to report JSON.
    pub fn as_str(&self) -> &'static str {
        match self {
            EncodeBarrier::Drain => "drain",
            EncodeBarrier::Impatient => "impatient",
            EncodeBarrier::None => "none",
        }
    }
}

impl Default for EncodeBarrier {
    fn default() -> Self {
        EncodeBarrier::Drain
    }
}

// MARK: - Drain response parsing

/// Result of parsing one `moot_drain_status` response.
///
/// The poller requires an *explicit* idle signal — not merely an absence of
/// the word "draining". Any response that does not match a known shape is a
/// fatal protocol error; the benchmark must abort rather than silently proceed
/// with under-encoded data.
#[derive(Debug, PartialEq, Eq)]
pub enum DrainParseResult {
    /// All registered drains are idle (pending == 0, in_flight == 0), or no
    /// corpus is registered ("drains: none"). Safe to issue recall queries.
    Idle,
    /// At least one drain has pending or in-flight work, or explicitly reports
    /// the state word "draining". Keep polling.
    Draining,
    /// The response did not match any recognised shape. The caller must abort
    /// the run — proceeding silently would produce invalid recall results.
    Unparseable,
}

/// Parse one text response from `moot_drain_status` into a `DrainParseResult`.
///
/// Two recognised shapes (both produced by `AriaMcpKit.ToolDispatch.runDrainStatus`
/// across product versions 1.0.x and 1.1.x):
///
///   Shape A — no corpus registered:
///     `"drains: none"`
///
///   Shape B — one or more drain-status lines:
///     `"drains: N"`
///     `"  <name>: <state> \u{2014} pending: N, in_flight: N[, <detail>]"`
///
/// where `<state>` is exactly `"draining"` or `"idle"`.
///
/// A drain is considered active when:
///   - its state word is `"draining"`, OR
///   - its `pending` count is non-zero, OR
///   - its `in_flight` count is non-zero.
///
/// Returns `Idle` only when ALL drains explicitly report `state == "idle"` with
/// both counts at zero. Returns `Unparseable` for anything else.
///
/// `pub` so unit tests in this module can call it directly.
pub fn parse_drain_response(text: &str) -> DrainParseResult {
    let trimmed = text.trim();

    // Shape A: "drains: none" — no corpus registered; treat as idle.
    if trimmed == "drains: none" {
        return DrainParseResult::Idle;
    }

    // Shape B: multi-line beginning with "drains: N" (N >= 1).
    let lines: Vec<&str> = trimmed.lines().collect();
    if lines.is_empty() {
        return DrainParseResult::Unparseable;
    }
    let first_line = lines[0];
    let header_prefix = "drains: ";
    if !first_line.starts_with(header_prefix) {
        return DrainParseResult::Unparseable;
    }
    let count_str = &first_line[header_prefix.len()..];
    // Validate that the header announces at least one drain; the actual count
    // is not used beyond this gate — each following line is parsed independently.
    let _drain_count: u64 = match count_str.parse() {
        Ok(n) if n > 0 => n,
        _ => return DrainParseResult::Unparseable,
    };

    // Parse each drain-status line that follows the header.
    // Expected format (verbatim from ToolDispatch.runDrainStatus):
    //   "  <name>: <state> — pending: N, in_flight: N[, <detail>]"
    // The em-dash separator (U+2014) divides the state prefix from the counts.
    let em_dash_sep = " \u{2014} "; // " — "
    let mut parsed_line_count: u64 = 0;
    for line in &lines[1..] {
        let stripped = line.trim();
        if stripped.is_empty() {
            continue;
        }

        // Split on the em-dash separator.
        let sep_pos = match stripped.find(em_dash_sep) {
            Some(p) => p,
            None => return DrainParseResult::Unparseable,
        };
        let name_state_str = &stripped[..sep_pos];
        let counts_str = &stripped[sep_pos + em_dash_sep.len()..];

        // Extract the state word from "<name>: <state>" — split on first ": ".
        let colon_space = ": ";
        let state: &str = match name_state_str.find(colon_space) {
            Some(p) => name_state_str[p + colon_space.len()..].trim(),
            None => return DrainParseResult::Unparseable,
        };

        // Parse pending and in_flight numeric fields from the counts side.
        let pending = match parse_int_field("pending: ", counts_str) {
            Some(n) => n,
            None => return DrainParseResult::Unparseable,
        };
        let in_flight = match parse_int_field("in_flight: ", counts_str) {
            Some(n) => n,
            None => return DrainParseResult::Unparseable,
        };

        // A drain is active if state is "draining" OR either count is non-zero.
        if state == "draining" || pending > 0 || in_flight > 0 {
            return DrainParseResult::Draining;
        }

        // State must be one of the two known words; anything else is unparseable.
        if state != "idle" {
            return DrainParseResult::Unparseable;
        }

        parsed_line_count += 1;
    }

    // If the header declared N > 0 drains and we parsed at least one drain
    // line without finding active work, all drains are idle.
    if parsed_line_count > 0 {
        return DrainParseResult::Idle;
    }
    // Header claimed N > 0 drains but we found no parseable drain lines.
    DrainParseResult::Unparseable
}

/// Extract the integer value for a named field from a comma-separated counts string.
///
/// Scans for `prefix` within `s`, then reads the decimal digits immediately
/// following it. Returns None when the prefix is absent or no digits follow.
///
/// Examples:
///   parse_int_field("pending: ",   "pending: 42, in_flight: 3")  → Some(42)
///   parse_int_field("in_flight: ", "pending: 0, in_flight: 0")   → Some(0)
fn parse_int_field(prefix: &str, s: &str) -> Option<u64> {
    let pos = s.find(prefix)?;
    let after = &s[pos + prefix.len()..];
    let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse().ok()
}

// MARK: - Drain barrier

/// Polls `moot_drain_status` after ingest completes, waiting until all drains
/// report "idle" before the caller issues its first recall query.
///
/// Response shapes handled:
///   "drains: none"  — no corpus registered; treat as idle.
///   "drains: N"
///   "  <name>: draining — pending: N, in_flight: N[, <detail>]"
///   "  <name>: idle    — pending: 0, in_flight: 0[, <detail>]"
///
/// **FATAL on unknown shape.** If `moot_drain_status` returns a response that
/// does not match a known shape, the process aborts immediately via
/// `std::process::exit(1)` after printing a diagnostic to stderr.
/// Proceeding with queries after an unrecognised response would produce
/// silently invalid recall scores.
///
/// Returns `true` when all drains became idle within `timeout_secs`.
/// Returns `false` when timed out — a WARNING is printed and the run continues.
///
/// Twin of Swift `waitForEncodeDrain(client:label:timeoutSeconds:)`.
pub fn wait_for_encode_drain(
    client: &mut MCPClient,
    label: &str,
    timeout_secs: f64,
) -> bool {
    let deadline = Instant::now() + Duration::from_secs_f64(timeout_secs);
    // 500 ms poll interval — frequent enough without hammering the estate.
    let poll_interval = Duration::from_millis(500);

    while Instant::now() < deadline {
        let args: BTreeMap<String, JsonValue> = BTreeMap::new();
        match client.call_tool("moot_drain_status", args, &ResultFormat::MootText) {
            Ok(result) => {
                let text = result.text_blocks.join("\n");

                match parse_drain_response(&text) {
                    DrainParseResult::Idle => return true,

                    DrainParseResult::Draining => {
                        // Still draining — log the trimmed response for visibility.
                        let trimmed = text.trim();
                        eprintln!("[{label}] drain barrier: waiting — {trimmed}");
                    }

                    DrainParseResult::Unparseable => {
                        // Unknown shape — the benchmark MUST NOT proceed silently.
                        // An unrecognised drain response means we cannot confirm that
                        // encoding has completed; any recall queries would be invalid.
                        let raw = if text.trim().is_empty() {
                            "(empty response — text_blocks were empty)".to_string()
                        } else {
                            text.clone()
                        };
                        eprintln!(
                            "[{label}] drain barrier: FATAL — moot_drain_status returned an \
                             unrecognised response shape. Cannot confirm encode completion; \
                             aborting to prevent invalid recall data.\nRaw response:\n{raw}"
                        );
                        std::process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!(
                    "[{label}] drain barrier: moot_drain_status error: {}",
                    e.description
                );
            }
        }
        thread::sleep(poll_interval);
    }

    // Timed out — emit honest warning and let the run proceed.
    eprintln!(
        "[{label}] drain barrier: WARNING — encode drain did not converge within \
         {timeout_secs:.0}s. Proceeding with query; recall quality may be reduced."
    );
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- EncodeBarrier enum tests (pre-existing, unchanged) ----

    #[test]
    fn from_str_round_trips() {
        assert_eq!(EncodeBarrier::from_str("drain").unwrap(), EncodeBarrier::Drain);
        assert_eq!(EncodeBarrier::from_str("impatient").unwrap(), EncodeBarrier::Impatient);
        assert_eq!(EncodeBarrier::from_str("none").unwrap(), EncodeBarrier::None);
    }

    #[test]
    fn as_str_matches_json_key() {
        assert_eq!(EncodeBarrier::Drain.as_str(), "drain");
        assert_eq!(EncodeBarrier::Impatient.as_str(), "impatient");
        assert_eq!(EncodeBarrier::None.as_str(), "none");
    }

    #[test]
    fn from_str_rejects_unknown() {
        assert!(EncodeBarrier::from_str("unknown").is_err());
    }

    #[test]
    fn default_is_drain() {
        assert_eq!(EncodeBarrier::default(), EncodeBarrier::Drain);
    }

    // ---- parse_drain_response tests ----

    // Shape A: "drains: none"

    #[test]
    fn drains_none_is_idle() {
        assert_eq!(parse_drain_response("drains: none"), DrainParseResult::Idle);
    }

    #[test]
    fn drains_none_with_whitespace_is_idle() {
        // Leading/trailing whitespace should still parse as idle.
        assert_eq!(parse_drain_response("  drains: none  \n"), DrainParseResult::Idle);
    }

    // Shape B — single drain, 1.0.x-style fixture (corpus_encode lane)

    #[test]
    fn single_drain_draining_is_draining() {
        // 1.0.x corpus_encode lane active — should report Draining.
        let text = "drains: 1\n  corpus_encode: draining \u{2014} pending: 42, in_flight: 3, encoded_chunks: 100";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    #[test]
    fn single_drain_idle_is_idle() {
        // 1.0.x corpus_encode lane fully drained.
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 2173";
        assert_eq!(parse_drain_response(text), DrainParseResult::Idle);
    }

    // Shape B — single drain, 1.1.x-style fixture (different lane name)
    // The server-side format is identical between versions; the lane name may differ.

    #[test]
    fn single_drain_11x_style_draining_is_draining() {
        // 1.1.x may surface additional lanes (e.g. a different corpus name).
        let text = "drains: 1\n  corpus_encode: draining \u{2014} pending: 7, in_flight: 1, encoded_chunks: 340";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    #[test]
    fn single_drain_11x_style_idle_is_idle() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 340";
        assert_eq!(parse_drain_response(text), DrainParseResult::Idle);
    }

    // Shape B — multiple drains (any draining means Draining overall)

    #[test]
    fn multiple_drains_one_draining_is_draining() {
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  lsa_encode: draining \u{2014} pending: 12, in_flight: 2";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    #[test]
    fn multiple_drains_all_idle_is_idle() {
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  lsa_encode: idle \u{2014} pending: 0, in_flight: 0";
        assert_eq!(parse_drain_response(text), DrainParseResult::Idle);
    }

    // Counts-vs-state consistency: pending > 0 triggers Draining even if state says idle.
    // (Defensive check — the server sets state based on pending+in_flight, but belt-and-suspenders.)

    #[test]
    fn nonzero_pending_despite_idle_state_is_draining() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 5, in_flight: 0";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    // Unknown / malformed shapes → Unparseable

    #[test]
    fn empty_string_is_unparseable() {
        assert_eq!(parse_drain_response(""), DrainParseResult::Unparseable);
    }

    #[test]
    fn whitespace_only_is_unparseable() {
        assert_eq!(parse_drain_response("  \n  "), DrainParseResult::Unparseable);
    }

    #[test]
    fn unknown_header_is_unparseable() {
        // An entirely different response format should be rejected.
        assert_eq!(parse_drain_response("status: unknown"), DrainParseResult::Unparseable);
    }

    #[test]
    fn missing_em_dash_separator_is_unparseable() {
        // Drain line without the "—" separator cannot be parsed.
        let text = "drains: 1\n  corpus_encode: draining pending: 5 in_flight: 0";
        assert_eq!(parse_drain_response(text), DrainParseResult::Unparseable);
    }

    #[test]
    fn drains_zero_is_unparseable() {
        // "drains: 0" is not a valid Shape B header (N must be >= 1).
        // This shape doesn't occur in practice but must be handled safely.
        assert_eq!(parse_drain_response("drains: 0"), DrainParseResult::Unparseable);
    }

    #[test]
    fn header_with_no_drain_lines_is_unparseable() {
        // Header claims 1 drain but no lines follow — body is empty.
        assert_eq!(parse_drain_response("drains: 1"), DrainParseResult::Unparseable);
    }

    #[test]
    fn unknown_state_word_is_unparseable() {
        // A state word other than "draining" or "idle" is not known.
        let text = "drains: 1\n  corpus_encode: encoding \u{2014} pending: 0, in_flight: 0";
        assert_eq!(parse_drain_response(text), DrainParseResult::Unparseable);
    }
}
