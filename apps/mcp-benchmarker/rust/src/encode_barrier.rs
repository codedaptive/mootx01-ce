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

/// Polls `moot_drain_status` after ingest completes, waiting until all drains
/// report "idle" before the caller issues its first recall query.
///
/// Response format from AriaMcpKit ToolDispatch.swift:
///   "drains: none"   — no corpus registered; treated as idle
///   "drains: N"
///   "  corpus_encode: draining — pending: N, in_flight: N"
///   "  corpus_encode: idle — pending: 0, in_flight: 0"
///
/// Returns `true` when all drains became idle within `timeout_secs`.
/// Returns `false` when timed out — a WARNING is printed to stderr and the run
/// continues (honest failure, not a hard abort).
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
                // "drains: none" — no corpus registered; treat as idle.
                if text.trim() == "drains: none" {
                    return true;
                }
                // Check for any "draining" state in the status lines.
                let any_draining = text.lines().any(|line| line.contains(": draining"));
                if !any_draining {
                    return true;
                }
                // Still draining — log for visibility.
                if let Some(draining_line) = text.lines().find(|l| l.contains(": draining")) {
                    eprintln!("[{label}] drain barrier: waiting — {}", draining_line.trim());
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
}
