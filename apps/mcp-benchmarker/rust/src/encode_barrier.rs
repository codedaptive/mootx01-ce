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
use crate::mcp_client::ToolCaller;
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
///
/// The `client` parameter accepts any `ToolCaller` implementation (including
/// test stubs). Callers passing `&mut MCPClient` are unaffected — Rust infers
/// the type parameter. The generic bound enables unit-testing the fatal-
/// transport early-abort path without a live server.
pub fn wait_for_encode_drain<C: ToolCaller>(
    client: &mut C,
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
                // Detect fatal transport errors: broken pipe (write to dead
                // stdin) or stream-closed (EOF from server that exited). Continuing
                // to poll when the transport is dead spins until timeout producing
                // the same error on every iteration; abort immediately with a
                // clear diagnosis so the run fails fast rather than hanging for
                // timeout_secs seconds before emitting a misleading
                // "did not converge" warning.
                let desc = e.description.to_lowercase();
                if desc.contains("broken pipe")
                    || desc.contains("stream closed")
                    || desc.contains("not connected")
                {
                    eprintln!(
                        "[{label}] drain barrier: FATAL — MCP transport died \
                         (server exited). Aborting poll."
                    );
                    return false;
                }
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
    use crate::mcp_client::MCPError;
    use crate::mcp_result::MCPToolResult;

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

    // MARK: - Fatal-transport early-abort tests

    /// Stub ToolCaller that always returns the configured error or result.
    struct StubCaller {
        /// When Some(e), call_tool returns Err(e).
        /// When None, call_tool returns Ok(idle status).
        error: Option<MCPError>,
        /// How many times call_tool was invoked.
        call_count: usize,
    }

    impl StubCaller {
        fn broken_pipe() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio write failed: Broken pipe".into() }),
                call_count: 0,
            }
        }
        fn stream_closed() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio stream closed by test-endpoint before a full message".into() }),
                call_count: 0,
            }
        }
        fn not_connected() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio transport not connected for test-endpoint".into() }),
                call_count: 0,
            }
        }
        fn idle() -> Self {
            StubCaller { error: None, call_count: 0 }
        }
        fn still_draining() -> Self {
            // Returns a valid draining status to verify non-fatal errors keep polling.
            StubCaller {
                error: Some(MCPError { description: "rpc-level error: rate limited".into() }),
                call_count: 0,
            }
        }
    }

    impl ToolCaller for StubCaller {
        fn call_tool(
            &mut self,
            _name: &str,
            _arguments: BTreeMap<String, JsonValue>,
            _format: &ResultFormat,
        ) -> Result<MCPToolResult, MCPError> {
            self.call_count += 1;
            match &self.error {
                Some(e) => Err(MCPError { description: e.description.clone() }),
                None => Ok(MCPToolResult {
                    ordered_ids: vec![],
                    items: vec![],
                    write_assigned_id: None,
                    text_blocks: vec!["drains: none".into()],
                }),
            }
        }
    }

    /// A broken-pipe error triggers an immediate return (call_count == 1, not
    /// retrying until timeout). Without the early-abort guard, the function
    /// would spin until timeout_secs — which for a 0.001 s timeout would still
    /// spin at least twice before the deadline.
    #[test]
    fn fatal_transport_broken_pipe_returns_immediately() {
        let mut stub = StubCaller::broken_pipe();
        // Use a non-zero timeout so we can verify only 1 call was made.
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(!result, "fatal transport error must return false");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    #[test]
    fn fatal_transport_stream_closed_returns_immediately() {
        let mut stub = StubCaller::stream_closed();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(!result, "fatal transport error must return false");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    #[test]
    fn fatal_transport_not_connected_returns_immediately() {
        let mut stub = StubCaller::not_connected();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(!result, "fatal transport error must return false");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    /// An idle status returns true immediately (non-fatal path still works).
    #[test]
    fn idle_status_returns_true() {
        let mut stub = StubCaller::idle();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(result, "idle status must return true");
        assert_eq!(stub.call_count, 1);
    }
}
