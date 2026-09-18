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

// MARK: - Drain response parsing

/// Result of parsing one `moot_drain_status` response.
///
/// The poller requires an *explicit* idle signal — not merely an absence of
/// the word "draining". Any response that does not match a known shape is a
/// fatal protocol error; the benchmark must abort rather than silently proceed
/// with under-encoded data.
/// `Idle` and `NoLanes` are deliberately DISTINCT variants. The corpus_encode
/// lane appears in drain status only once the Corpus is wired for the estate
/// (GeniusLocusKit `drainStatuses`: present iff `corpusKits[handle]` exists),
/// and it never deregisters afterwards. On a FRESH estate the first poll can
/// therefore beat lane wiring: "drains: none" is truthfully parseable but is
/// NOT evidence that encoding finished — it may mean encoding hasn't STARTED.
/// The barrier's state machine (`DrainBarrierState`) treats `Idle` (lane
/// listed, all counts zero) as proof and `NoLanes` as ambiguity that needs a
/// grace window.
#[derive(Debug, PartialEq, Eq)]
pub enum DrainParseResult {
    /// Shape B with every listed lane at state "idle", pending == 0,
    /// in_flight == 0. The lane is registered AND reports no work — positive
    /// evidence that encoding completed. Safe to issue recall queries.
    Idle,
    /// At least one drain has pending or in-flight work, or explicitly reports
    /// the state word "draining". Keep polling.
    Draining,
    /// Shape A — `"drains: none"`: no lane registered (yet). Ambiguous on a
    /// fresh estate: either the corpus lane has not wired yet (encoding still
    /// ahead of us) or this estate genuinely runs no drains. NOT proof of
    /// completion by itself.
    NoLanes,
    /// The response did not match any recognised shape. The caller must abort
    /// the run — proceeding silently would produce invalid recall results.
    Unparseable,
}

/// Lanes whose `pending` is a row-level ELIGIBILITY count rather than a queue
/// depth, and which therefore must never hold the encode barrier open.
///
/// This is a DENYLIST, not an allowlist, and the direction matters: an
/// unknown lane keeps gating. For a measurement tool a visible hang is a far
/// better failure than silently querying under-encoded data — a hang gets
/// noticed and fixed; invalid recall numbers get published. A lane earns a
/// place here only once its counts are shown not to be queue work.
///
/// `distillation` qualifies: its `pending` is
/// `count_undistilled(pipeline_version)` — drawers owing a representation —
/// and its `in_flight` is a hardcoded 0, so it can sit non-zero at a steady
/// state that no amount of draining resolves.
///
/// Twin of Swift `barrierNonGatingLanes`.
/// `subject_backfill` qualifies for the same reason (rider-default
/// ruling 2026-08-02: the Apple subject rider is on by default, so the
/// lane renders on Apple estates): its `pending` is the subject-debt
/// eligibility count with `in_flight` hardcoded 0, and dreaming pays it
/// down out-of-band — a steady non-zero no encode drain resolves.
/// `fact_extraction` qualifies too: bit-28 row debt (drawers still owed
/// extraction for the active recipe), always rendered, paid down only by a
/// dreaming cycle's bounded batch — it sits non-zero across a measured
/// session on a healthy estate. The bulk build settles on it explicitly; the
/// encode barrier must not.
pub const BARRIER_NON_GATING_LANES: &[&str] =
    &["distillation", "subject_backfill", "fact_extraction"];

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
/// EVERY LANE GATES THE BARRIER except those in
/// `BARRIER_NON_GATING_LANES`, whose `pending` is a row-level eligibility
/// count rather than queue work and can therefore sit non-zero forever on a
/// healthy estate. Non-gating lines are still parsed — a malformed one is
/// still a protocol error — they simply never hold the barrier open.
///
/// A gating drain is considered active when:
///   - its state word is `"draining"`, OR
///   - its `pending` count is non-zero, OR
///   - its `in_flight` count is non-zero.
///
/// Returns `Idle` only when ALL GATING drains explicitly report
/// `state == "idle"` with both counts at zero — and also when the response
/// carries only non-gating lanes (nothing queue-backed is outstanding).
/// Returns `NoLanes` for Shape A. Returns `Unparseable` for anything else.
///
/// `pub` so unit tests in this module can call it directly.
pub fn parse_drain_response(text: &str) -> DrainParseResult {
    let trimmed = text.trim();

    // Shape A: "drains: none" — no lane registered. NOT idle-equivalent on a
    // fresh estate; the state machine decides what to do with it.
    if trimmed == "drains: none" {
        return DrainParseResult::NoLanes;
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
    let mut non_gating_line_count: u64 = 0;
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

        // Extract the name and state word from "<name>: <state>".
        let colon_space = ": ";
        let (name, state): (&str, &str) = match name_state_str.find(colon_space) {
            Some(p) => (
                name_state_str[..p].trim(),
                name_state_str[p + colon_space.len()..].trim(),
            ),
            None => return DrainParseResult::Unparseable,
        };

        // Non-gating lane: parsed (so a malformed line is still caught) but
        // never allowed to hold the barrier open. See the doc-comment.
        if BARRIER_NON_GATING_LANES.contains(&name) {
            if parse_int_field("pending: ", counts_str).is_none()
                || parse_int_field("in_flight: ", counts_str).is_none()
                || (state != "draining" && state != "idle")
            {
                return DrainParseResult::Unparseable;
            }
            non_gating_line_count += 1;
            continue;
        }

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

    // Every gating lane reported idle with zero counts — the ingest work is
    // done. This also covers a response carrying only non-gating lanes:
    // nothing queue-backed is outstanding, so the barrier is satisfied.
    if parsed_line_count > 0 || non_gating_line_count > 0 {
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

// MARK: - Barrier state machine

/// What the drain barrier concluded, returned to the runner and recorded in
/// the report JSON as the per-unit `drain_lane_observed` key.
///
/// Twin of Swift `DrainBarrierOutcome`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DrainBarrierOutcome {
    /// True when the barrier accepted an idle state (via lane evidence or the
    /// no-lanes grace window) within the timeout. False on timeout or fatal
    /// transport death.
    pub converged: bool,
    /// True when at least one poll returned Shape B (the corpus lane was
    /// registered — draining or idle). False means the barrier only ever saw
    /// "drains: none": ambiguous evidence, disclosed as such in the report.
    pub lane_observed: bool,
}

/// Grace-window policy for accepting `"drains: none"` as idle.
///
/// The corpus lane registers when the Corpus is wired for the estate and never
/// deregisters. On a fresh estate the first poll can precede wiring, so a
/// single no-lanes response proves nothing. Requiring BOTH a minimum number of
/// consecutive no-lanes polls AND a minimum elapsed time bounds the two
/// failure modes independently. A tiny corpus that legitimately finished (or
/// an estate that genuinely runs no drains) still converges — ~2 s later,
/// with `lane_observed == false` recorded so the ambiguity is visible.
///
/// Twin of Swift `DrainBarrierGrace`.
#[derive(Debug, Clone, Copy)]
pub struct DrainBarrierGrace {
    /// Minimum consecutive `NoLanes` polls (uninterrupted by any other
    /// response or RPC error) before no-lanes may be accepted as idle.
    pub min_consecutive_no_lanes: u32,
    /// Minimum seconds since the barrier started before no-lanes may be
    /// accepted as idle.
    pub min_seconds: f64,
}

impl Default for DrainBarrierGrace {
    fn default() -> Self {
        DrainBarrierGrace { min_consecutive_no_lanes: 4, min_seconds: 2.0 }
    }
}

/// The barrier's next action after observing one parsed poll response.
/// Twin of Swift `DrainBarrierDecision`.
#[derive(Debug, PartialEq, Eq)]
pub enum DrainBarrierDecision {
    /// Accept: encoding is complete (or accepted via grace). Stop polling.
    Converged { lane_observed: bool },
    /// Not enough evidence yet — poll again.
    KeepPolling,
    /// Protocol error — the caller must abort the benchmark (exit 1).
    AbortUnparseable,
}

/// Pure state machine for the drain barrier's evidence tracking. Extracted
/// from the poll loop so the sequencing rules are unit-testable without an
/// MCP client:
///
///   Idle        → converged immediately (lane listed and empty — proof).
///   Draining    → lane observed; keep polling.
///   NoLanes     → before any lane sighting: accept only after the grace
///                 window; after a lane sighting: the lane vanishing is
///                 anomalous — keep polling until timeout rather than trust it.
///   Unparseable → abort.
///
/// RPC errors are reported via `note_error()`: they reset the consecutive
/// no-lanes counter because the evidence stream was interrupted.
///
/// Twin of Swift `DrainBarrierState`.
pub struct DrainBarrierState {
    lane_observed: bool,
    consecutive_no_lanes: u32,
    /// Consecutive `moot_drain_status` RPC failures — see `note_error`.
    consecutive_errors: u32,
    start: Instant,
    grace: DrainBarrierGrace,
}

impl DrainBarrierState {
    pub fn new(start: Instant, grace: DrainBarrierGrace) -> Self {
        DrainBarrierState {
            lane_observed: false,
            consecutive_no_lanes: 0,
            consecutive_errors: 0,
            start,
            grace,
        }
    }

    /// True when at least one poll has shown the lane registered.
    pub fn lane_observed(&self) -> bool {
        self.lane_observed
    }

    /// Feed one parsed poll response; returns what the barrier should do next.
    /// `now` is injectable for tests (pass `Instant::now()` in production).
    pub fn observe(&mut self, parse: DrainParseResult, now: Instant) -> DrainBarrierDecision {
        match parse {
            DrainParseResult::Draining => {
                self.lane_observed = true;
                self.consecutive_no_lanes = 0;
                DrainBarrierDecision::KeepPolling
            }
            DrainParseResult::Idle => {
                // Lane listed with zero counts — positive completion evidence.
                self.lane_observed = true;
                DrainBarrierDecision::Converged { lane_observed: true }
            }
            DrainParseResult::NoLanes => {
                if self.lane_observed {
                    // The lane never deregisters in the product; seeing
                    // no-lanes AFTER a lane sighting is anomalous. Do not
                    // trust it — keep polling; the timeout bounds the worst case.
                    return DrainBarrierDecision::KeepPolling;
                }
                self.consecutive_no_lanes += 1;
                let elapsed = now.duration_since(self.start).as_secs_f64();
                if self.consecutive_no_lanes >= self.grace.min_consecutive_no_lanes
                    && elapsed >= self.grace.min_seconds
                {
                    DrainBarrierDecision::Converged { lane_observed: false }
                } else {
                    DrainBarrierDecision::KeepPolling
                }
            }
            DrainParseResult::Unparseable => DrainBarrierDecision::AbortUnparseable,
        }
    }

    /// Note an RPC error between polls: the consecutive no-lanes evidence
    /// chain is broken, so the counter restarts. The error streak advances —
    /// a crashed server answers nothing, so every poll fails identically and
    /// the COUNT is what identifies death without depending on the error's
    /// wording. Twin of Swift `DrainBarrierState.noteError`.
    pub fn note_error(&mut self) {
        self.consecutive_no_lanes = 0;
        self.consecutive_errors += 1;
    }

    /// Called after any poll that produced a parseable response — the server
    /// is answering, so the failure streak is over.
    /// Twin of Swift `DrainBarrierState.noteResponded`.
    pub fn note_responded(&mut self) {
        self.consecutive_errors = 0;
    }

    /// Consecutive failed polls so far.
    pub fn consecutive_errors(&self) -> u32 {
        self.consecutive_errors
    }
}

/// Consecutive failed polls after which the server is declared dead.
///
/// At the 500 ms poll interval this is ~5 s of total silence. A live server
/// answers `moot_drain_status` in milliseconds even while draining, so this
/// cannot be reached by load — only by a server that is gone.
/// Twin of Swift `deadServerPollThreshold`.
const DEAD_SERVER_POLL_THRESHOLD: u32 = 10;

// MARK: - Drain barrier

/// Polls `moot_drain_status` after ingest completes, waiting until the corpus
/// lane reports "idle" before the caller issues its first recall query.
///
/// Response shapes handled:
///   "drains: none"  — no lane registered; accepted only via the grace window.
///   "drains: N"
///   "  <name>: draining — pending: N, in_flight: N[, <detail>]"
///   "  <name>: idle    — pending: 0, in_flight: 0[, <detail>]"
///
/// **Fresh-estate race:** the corpus lane appears in drain status only once
/// the Corpus is wired; a first poll that beats wiring sees "drains: none".
/// The barrier therefore accepts no-lanes as idle only after
/// `DrainBarrierGrace` is satisfied, and records whether the lane was ever
/// observed (`DrainBarrierOutcome.lane_observed` → report key
/// `drain_lane_observed`).
// MARK: - Dream drain status (item 8)

/// Dream-drain status captured once at measurement run start.
///
/// `pending`: the `pending` count from the `dreaming` drain lane.
///   0 when the lane is absent or the estate reports "drains: none".
/// `draining`: true when the dreaming lane explicitly reports "draining";
///   false when idle or absent.
///
/// Twin of Swift `DreamStatus`.
#[derive(Debug, Clone, Copy, Default)]
pub struct DreamStatus {
    /// Pending count from the `dreaming` drain lane at run start.
    pub pending: u64,
    /// True when the dreaming lane was actively draining at run start.
    pub draining: bool,
}

/// Parses the `dreaming` lane state from a `moot_drain_status` text response.
///
/// Twin of Swift `dreamStatusFromDrainText(_:)`.
pub fn dream_status_from_drain_text(text: &str) -> DreamStatus {
    let trimmed = text.trim();
    if trimmed == "drains: none" {
        return DreamStatus::default();
    }
    for line in trimmed.lines().skip(1) {
        let stripped = line.trim();
        if !stripped.starts_with("dreaming:") {
            continue;
        }
        // Format: "dreaming: <state> — pending: N, in_flight: M[, ...]"
        let draining = stripped.contains("draining");
        let mut pending: u64 = 0;
        if let Some(pos) = stripped.find("pending: ") {
            let after = &stripped[pos + "pending: ".len()..];
            let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
            pending = digits.parse().unwrap_or(0);
        }
        return DreamStatus { pending, draining };
    }
    DreamStatus::default()
}

/// Reads drain state from a parsed `MCPToolResult`.
///
/// Prefers `drain_entries` (v2 structured data); falls back to text parsing
/// via `parse_drain_response` for v1 compatibility.
///
/// Twin of Swift `parseDrainResult(_:)`.
pub fn parse_drain_result(result: &crate::mcp_result::MCPToolResult) -> DrainParseResult {
    if let Some(entries) = &result.drain_entries {
        if entries.is_empty() {
            return DrainParseResult::NoLanes;
        }
        for entry in entries {
            if entry.state == "draining" || entry.pending > 0 {
                return DrainParseResult::Draining;
            }
            if entry.state != "idle" {
                return DrainParseResult::Unparseable;
            }
        }
        return DrainParseResult::Idle;
    }
    // v1 fallback: parse from text blocks.
    parse_drain_response(&result.text_blocks.join("\n"))
}

/// Reads dream lane status from a parsed `MCPToolResult`.
///
/// Prefers `drain_entries` (v2 structured data); falls back to text parsing
/// via `dream_status_from_drain_text` for v1 compatibility.
///
/// Twin of Swift `dreamStatusFromResult(_:)`.
pub fn dream_status_from_result(result: &crate::mcp_result::MCPToolResult) -> DreamStatus {
    if let Some(entries) = &result.drain_entries {
        if let Some(dreaming) = entries.iter().find(|e| e.name == "dreaming") {
            let draining = dreaming.state == "draining" || dreaming.pending > 0;
            return DreamStatus {
                pending: dreaming.pending as u64,
                draining,
            };
        }
        // No dreaming lane found in structured entries — settled.
        return DreamStatus::default();
    }
    // v1 fallback: parse from text blocks.
    dream_status_from_drain_text(&result.text_blocks.join("\n"))
}

/// Calls `moot_drain_status` once and returns the dreaming drain lane state.
///
/// Non-failing: if the call fails or the response is unparseable, returns the
/// default (pending=0, draining=false) and logs to stderr.  Dream status is
/// informational and must not abort a measurement run.
///
/// Twin of Swift `readDrainStatusOnce(client:)`.
pub fn read_drain_status_once<C: ToolCaller>(client: &mut C) -> DreamStatus {
    let args = BTreeMap::new();
    match client.call_tool(crate::aria_v2_surface::DRAIN_STATUS, args, &ResultFormat::MootV2) {
        Ok(result) => {
            dream_status_from_result(&result)
        }
        Err(e) => {
            eprintln!("[dream-status] moot_drain_status failed: {e}");
            DreamStatus::default()
        }
    }
}

///
/// **FATAL on unknown shape.** If `moot_drain_status` returns a response that
/// does not match a known shape, the process aborts immediately via
/// `std::process::exit(1)` after printing a diagnostic to stderr.
/// Proceeding with queries after an unrecognised response would produce
/// silently invalid recall scores.
///
/// Returns `converged == false` when timed out or the transport died — a
/// WARNING is printed and the run continues.
///
/// Twin of Swift `waitForEncodeDrain(client:label:timeoutSeconds:grace:)`.
///
/// The `client` parameter accepts any `ToolCaller` implementation (including
/// test stubs). Callers passing `&mut MCPClient` are unaffected — Rust infers
/// the type parameter. The generic bound enables unit-testing the fatal-
/// transport early-abort path without a live server.
pub fn wait_for_encode_drain<C: ToolCaller>(
    client: &mut C,
    label: &str,
    timeout_secs: f64,
) -> DrainBarrierOutcome {
    let start = Instant::now();
    let deadline = start + Duration::from_secs_f64(timeout_secs);
    // 500 ms poll interval — frequent enough without hammering the estate.
    let poll_interval = Duration::from_millis(500);
    let mut state = DrainBarrierState::new(start, DrainBarrierGrace::default());

    while Instant::now() < deadline {
        let args: BTreeMap<String, JsonValue> = BTreeMap::new();
        match client.call_tool(crate::aria_v2_surface::DRAIN_STATUS, args, &ResultFormat::MootV2) {
            Ok(result) => {
                // Keep text for logging; use parse_drain_result for decision
                // (prefers structured drain_entries, falls back to text).
                let text = result.text_blocks.join("\n");
                let parsed = parse_drain_result(&result);
                state.note_responded();
                let was_no_lanes = parsed == DrainParseResult::NoLanes;
                let was_draining = parsed == DrainParseResult::Draining;

                match state.observe(parsed, Instant::now()) {
                    DrainBarrierDecision::Converged { lane_observed } => {
                        if !lane_observed {
                            // Grace-window acceptance: no lane was ever seen.
                            // Disclosed note — either a tiny corpus finished
                            // before the first poll, or the lane never wired.
                            eprintln!(
                                "[{label}] drain barrier: accepted no-lanes as idle after grace \
                                 window ({:.1}s) — corpus lane never observed. \
                                 drain_lane_observed=false",
                                start.elapsed().as_secs_f64()
                            );
                        }
                        return DrainBarrierOutcome { converged: true, lane_observed };
                    }

                    DrainBarrierDecision::KeepPolling => {
                        if was_draining {
                            // Still draining — log the trimmed response for visibility.
                            let trimmed = text.trim();
                            eprintln!("[{label}] drain barrier: waiting — {trimmed}");
                        } else if was_no_lanes && state.lane_observed() {
                            eprintln!(
                                "[{label}] drain barrier: WARNING — lane disappeared after \
                                 being observed (drains: none). Continuing to poll."
                            );
                        }
                        // Pre-lane no-lanes polls are quiet; grace decides.
                    }

                    DrainBarrierDecision::AbortUnparseable => {
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
                state.note_error();
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
                // Wording-based detection, for transports that announce death.
                if desc.contains("broken pipe")
                    || desc.contains("stream closed")
                    || desc.contains("not connected")
                    // A crashed server does NOT announce itself: the request
                    // simply never gets an answer, and every later poll times
                    // out identically. That is how a SynapseKit SIGTRAP
                    // presented as a ten-minute silent stall rather than a
                    // failure (2026-08-15) — none of the wordings above
                    // matched. Twin of Swift.
                    || desc.contains("response timeout")
                {
                    eprintln!(
                        "[{label}] drain barrier: FATAL — MCP transport died \
                         (server exited). Aborting poll."
                    );
                    return DrainBarrierOutcome {
                        converged: false,
                        lane_observed: state.lane_observed(),
                    };
                }
                // Wording-INDEPENDENT backstop: whatever a future transport
                // calls its failure, a server that has missed this many polls
                // in a row is not coming back, and polling to the timeout only
                // delays a failure that already happened.
                if state.consecutive_errors() >= DEAD_SERVER_POLL_THRESHOLD {
                    eprintln!(
                        "[{label}] drain barrier: FATAL — moot_drain_status failed {} polls in a \
                         row ({:.1}s). The server is not answering; treating it as dead rather \
                         than polling to the {timeout_secs:.0}s timeout. Last error: {}",
                        state.consecutive_errors(),
                        start.elapsed().as_secs_f64(),
                        e.description
                    );
                    return DrainBarrierOutcome {
                        converged: false,
                        lane_observed: state.lane_observed(),
                    };
                }
            }
        }
        thread::sleep(poll_interval);
    }

    // Timed out — emit an explicit warning and let the run proceed.
    eprintln!(
        "[{label}] drain barrier: WARNING — encode drain did not converge within \
         {timeout_secs:.0}s. Proceeding with query; recall quality may be reduced."
    );
    DrainBarrierOutcome { converged: false, lane_observed: state.lane_observed() }
}

#[cfg(test)]
mod tests {

    // MARK: - Dead-server detection (2026-08-15)

    /// A crashed server does not announce itself: the transport reports a
    /// response timeout and every later poll reports the same, so the wording
    /// list matches nothing and the barrier polls to its full timeout. The
    /// error STREAK is the wording-independent signal — a live server answers
    /// moot_drain_status in milliseconds even while draining, so a run of
    /// failures is silence rather than load.
    /// Twin of Swift `test_consecutiveErrors_countsAcrossFailedPolls`.
    #[test]
    fn consecutive_errors_count_across_failed_polls() {
        let mut state = DrainBarrierState::new(Instant::now(), DrainBarrierGrace::default());
        assert_eq!(state.consecutive_errors(), 0);
        for expected in 1..=12 {
            state.note_error();
            assert_eq!(state.consecutive_errors(), expected);
        }
    }

    /// One good answer ends the streak, so a transient failure cannot
    /// accumulate toward the death threshold across a healthy run.
    /// Twin of Swift `test_responseClearsTheErrorStreak`.
    #[test]
    fn response_clears_the_error_streak() {
        let mut state = DrainBarrierState::new(Instant::now(), DrainBarrierGrace::default());
        state.note_error();
        state.note_error();
        assert_eq!(state.consecutive_errors(), 2);
        state.note_responded();
        assert_eq!(
            state.consecutive_errors(),
            0,
            "a parseable response proves the server is alive; the streak restarts"
        );
    }
    use super::*;
    use crate::mcp_client::MCPError;
    use crate::mcp_result::MCPToolResult;

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
    fn drains_none_is_no_lanes() {
        // Shape A means the corpus lane has not registered (or the estate runs
        // no drains). The state machine, not the parser, decides acceptance.
        assert_eq!(parse_drain_response("drains: none"), DrainParseResult::NoLanes);
    }

    #[test]
    fn drains_none_with_whitespace_is_no_lanes() {
        // Leading/trailing whitespace should still parse as Shape A.
        assert_eq!(parse_drain_response("  drains: none  \n"), DrainParseResult::NoLanes);
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

    // MARK: - Fatal-transport early-abort tests

    /// Stub ToolCaller that always returns the configured error or result text.
    struct StubCaller {
        /// When Some(e), call_tool returns Err(e).
        /// When None, call_tool returns Ok with `response_text`.
        error: Option<MCPError>,
        /// The drain-status text returned on the Ok path.
        response_text: String,
        /// How many times call_tool was invoked.
        call_count: usize,
    }

    impl StubCaller {
        fn broken_pipe() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio write failed: Broken pipe".into() }),
                response_text: String::new(),
                call_count: 0,
            }
        }
        fn stream_closed() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio stream closed by test-endpoint before a full message".into() }),
                response_text: String::new(),
                call_count: 0,
            }
        }
        fn not_connected() -> Self {
            StubCaller {
                error: Some(MCPError { description: "stdio transport not connected for test-endpoint".into() }),
                response_text: String::new(),
                call_count: 0,
            }
        }
        /// Shape B idle: the lane is registered and drained — trusted evidence.
        fn lane_idle() -> Self {
            StubCaller {
                error: None,
                response_text:
                    "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0".into(),
                call_count: 0,
            }
        }
        /// Shape A: no lane registered — the fresh-estate race response.
        fn no_lanes() -> Self {
            StubCaller { error: None, response_text: "drains: none".into(), call_count: 0 }
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
                    text_blocks: vec![self.response_text.clone()],
                    // All other fields default to empty/false/None so this literal
                    // survives future MCPToolResult field additions without update.
                    ..Default::default()
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
        assert!(!result.converged, "fatal transport error must not converge");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    #[test]
    fn fatal_transport_stream_closed_returns_immediately() {
        let mut stub = StubCaller::stream_closed();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(!result.converged, "fatal transport error must not converge");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    #[test]
    fn fatal_transport_not_connected_returns_immediately() {
        let mut stub = StubCaller::not_connected();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(!result.converged, "fatal transport error must not converge");
        assert_eq!(stub.call_count, 1, "must abort after the first fatal error, not retry");
    }

    /// Shape B idle converges on the FIRST poll with lane evidence — the
    /// trusted-idle fast path is unaffected by the grace window.
    #[test]
    fn lane_idle_converges_immediately() {
        let mut stub = StubCaller::lane_idle();
        let result = wait_for_encode_drain(&mut stub, "test", 5.0);
        assert!(result.converged, "Shape B idle must converge");
        assert!(result.lane_observed, "Shape B idle IS lane evidence");
        assert_eq!(stub.call_count, 1, "trusted idle must not wait for the grace window");
    }

    /// The fresh-estate race response ("drains: none" forever): the barrier
    /// must NOT accept the first poll. It converges only after the grace
    /// window (>= 4 consecutive polls AND >= 2.0 s) with lane_observed=false.
    /// Pre-fix, this returned after ONE poll — that was the defect.
    #[test]
    fn no_lanes_accepted_only_after_grace_window() {
        let mut stub = StubCaller::no_lanes();
        let start = Instant::now();
        let result = wait_for_encode_drain(&mut stub, "test", 30.0);
        let elapsed = start.elapsed().as_secs_f64();
        assert!(result.converged, "persistent no-lanes must converge via grace");
        assert!(!result.lane_observed, "no lane was ever observed");
        assert!(stub.call_count >= 4,
            "grace requires >= 4 consecutive no-lanes polls, got {}", stub.call_count);
        assert!(elapsed >= 2.0,
            "grace requires >= 2.0 s elapsed, got {elapsed:.2}s");
    }

    // MARK: - DrainBarrierState (pure state machine) tests
    // Twin coverage of Swift `DrainBarrierStateTests`.

    fn grace() -> DrainBarrierGrace {
        DrainBarrierGrace { min_consecutive_no_lanes: 4, min_seconds: 2.0 }
    }

    /// Deterministic instants for the state machine: offsets from a base.
    fn at(base: Instant, secs: f64) -> Instant {
        base + Duration::from_secs_f64(secs)
    }

    #[test]
    fn state_shape_b_idle_converges_immediately() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        assert_eq!(
            state.observe(DrainParseResult::Idle, base),
            DrainBarrierDecision::Converged { lane_observed: true }
        );
    }

    #[test]
    fn state_first_no_lanes_keeps_polling() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        assert_eq!(
            state.observe(DrainParseResult::NoLanes, base),
            DrainBarrierDecision::KeepPolling
        );
    }

    #[test]
    fn state_no_lanes_then_draining_then_idle_does_not_converge_early() {
        // The defect scenario: poll beats lane wiring, then the lane appears.
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        assert_eq!(state.observe(DrainParseResult::NoLanes, base),
                   DrainBarrierDecision::KeepPolling);
        assert_eq!(state.observe(DrainParseResult::Draining, at(base, 0.5)),
                   DrainBarrierDecision::KeepPolling);
        assert_eq!(state.observe(DrainParseResult::Idle, at(base, 1.0)),
                   DrainBarrierDecision::Converged { lane_observed: true });
    }

    #[test]
    fn state_grace_window_needs_count_and_time() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 0.5)),
                   DrainBarrierDecision::KeepPolling);
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 1.0)),
                   DrainBarrierDecision::KeepPolling);
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 1.5)),
                   DrainBarrierDecision::KeepPolling);
        // 4th consecutive poll AND >= 2.0 s elapsed → accept via grace.
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 2.0)),
                   DrainBarrierDecision::Converged { lane_observed: false });
    }

    #[test]
    fn state_fast_burst_count_alone_does_not_converge() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        for i in 0..10 {
            // 10 polls all within 1 second — the 2.0 s time constraint unmet.
            assert_eq!(
                state.observe(DrainParseResult::NoLanes, at(base, i as f64 * 0.1)),
                DrainBarrierDecision::KeepPolling,
                "poll {i}: count alone must not satisfy the grace window"
            );
        }
    }

    #[test]
    fn state_single_late_poll_time_alone_does_not_converge() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 10.0)),
                   DrainBarrierDecision::KeepPolling);
    }

    #[test]
    fn state_no_lanes_after_lane_observed_keeps_polling() {
        // The lane never deregisters in the product; post-lane no-lanes is
        // anomalous and must never converge, no matter how late.
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        let _ = state.observe(DrainParseResult::Draining, base);
        for i in 0..6 {
            assert_eq!(
                state.observe(DrainParseResult::NoLanes, at(base, 60.0 + i as f64)),
                DrainBarrierDecision::KeepPolling
            );
        }
    }

    #[test]
    fn state_note_error_resets_no_lanes_count() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        let _ = state.observe(DrainParseResult::NoLanes, at(base, 0.5));
        let _ = state.observe(DrainParseResult::NoLanes, at(base, 1.0));
        let _ = state.observe(DrainParseResult::NoLanes, at(base, 1.5));
        state.note_error();
        // Would be the 4th consecutive poll past 2.0 s — but the error reset
        // the counter, so it is the 1st.
        assert_eq!(state.observe(DrainParseResult::NoLanes, at(base, 2.5)),
                   DrainBarrierDecision::KeepPolling);
    }

    #[test]
    fn state_unparseable_aborts() {
        let base = Instant::now();
        let mut state = DrainBarrierState::new(base, grace());
        let _ = state.observe(DrainParseResult::Draining, base);
        assert_eq!(state.observe(DrainParseResult::Unparseable, at(base, 0.5)),
                   DrainBarrierDecision::AbortUnparseable);
    }

    // Non-gating lanes (probe-1 stall regression). Twin of Swift
    // EncodeBarrierTests non-gating cases.

    #[test]
    fn distillation_pending_does_not_hold_barrier_open() {
        // The exact shape probe 1 hung on: corpus_encode idle, distillation
        // pinned at a non-zero eligibility count with in_flight 0.
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 508\n  distillation: draining \u{2014} pending: 7, in_flight: 0, pipeline: p1";
        assert_eq!(parse_drain_response(text), DrainParseResult::Idle);
    }

    #[test]
    fn distillation_skipped_but_corpus_encode_still_gates() {
        let text = "drains: 2\n  corpus_encode: draining \u{2014} pending: 12, in_flight: 2\n  distillation: draining \u{2014} pending: 7, in_flight: 0, pipeline: p1";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    #[test]
    fn unknown_lane_still_gates() {
        // The denylist is deliberately narrow: a lane we have not proven to
        // be non-queue still holds the barrier.
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  lsa_encode: draining \u{2014} pending: 12, in_flight: 2";
        assert_eq!(parse_drain_response(text), DrainParseResult::Draining);
    }

    #[test]
    fn malformed_non_gating_line_is_unparseable() {
        // Skipping a lane for gating purposes must not skip validating it.
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  distillation: wobbling \u{2014} pending: 7, in_flight: 0";
        assert_eq!(parse_drain_response(text), DrainParseResult::Unparseable);
    }

    // ── dream_status_from_drain_text (item 8) ─────────────────────────────────

    #[test]
    fn dream_status_drains_none_returns_default() {
        let status = dream_status_from_drain_text("drains: none");
        assert_eq!(status.pending, 0);
        assert!(!status.draining);
    }

    #[test]
    fn dream_status_absent_lane_returns_default() {
        // Response has drains but no dreaming lane — should default.
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 100";
        let status = dream_status_from_drain_text(text);
        assert_eq!(status.pending, 0);
        assert!(!status.draining);
    }

    #[test]
    fn dream_status_draining_parses_pending() {
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  dreaming: draining \u{2014} pending: 17, in_flight: 2";
        let status = dream_status_from_drain_text(text);
        assert_eq!(status.pending, 17);
        assert!(status.draining);
    }

    #[test]
    fn dream_status_idle_lane_draining_false() {
        let text = "drains: 1\n  dreaming: idle \u{2014} pending: 0, in_flight: 0";
        let status = dream_status_from_drain_text(text);
        assert_eq!(status.pending, 0);
        assert!(!status.draining);
    }

    // ── parse_drain_result: structured drain_entries path ──

    fn make_result(drain_entries: Option<Vec<crate::mcp_result::V2DrainEntry>>,
                   text: Option<&str>) -> crate::mcp_result::MCPToolResult {
        crate::mcp_result::MCPToolResult {
            text_blocks: text.map(|t| vec![t.to_string()]).unwrap_or_default(),
            drain_entries,
            ..crate::mcp_result::MCPToolResult::default()
        }
    }

    #[test]
    fn parse_drain_result_all_idle_is_idle() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "corpus_encode".to_string(), state: "idle".to_string(), pending: 0 },
            crate::mcp_result::V2DrainEntry { name: "dreaming".to_string(), state: "idle".to_string(), pending: 0 },
        ]), None);
        assert_eq!(parse_drain_result(&r), DrainParseResult::Idle);
    }

    #[test]
    fn parse_drain_result_one_draining_is_draining() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "corpus_encode".to_string(), state: "draining".to_string(), pending: 5 },
            crate::mcp_result::V2DrainEntry { name: "dreaming".to_string(), state: "idle".to_string(), pending: 0 },
        ]), None);
        assert_eq!(parse_drain_result(&r), DrainParseResult::Draining);
    }

    #[test]
    fn parse_drain_result_pending_positive_is_draining() {
        // state="idle" but pending > 0 still means draining.
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "corpus_encode".to_string(), state: "idle".to_string(), pending: 3 },
        ]), None);
        assert_eq!(parse_drain_result(&r), DrainParseResult::Draining);
    }

    #[test]
    fn parse_drain_result_empty_entries_is_no_lanes() {
        let r = make_result(Some(vec![]), None);
        assert_eq!(parse_drain_result(&r), DrainParseResult::NoLanes);
    }

    // -- Unrecognised state word (structured path) --

    /// Unrecognised state word "wedged" on the structured path → Unparseable,
    /// not Idle. Covers the structured fallback branch (encode_barrier.rs:515).
    #[test]
    fn parse_drain_result_unknown_state_word_is_unparseable() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry {
                name: "corpus_encode".to_string(),
                state: "wedged".to_string(),
                pending: 0,
            },
        ]), None);
        assert_eq!(parse_drain_result(&r), DrainParseResult::Unparseable);
    }

    #[test]
    fn parse_drain_result_unknown_state_word_is_not_idle() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry {
                name: "corpus_encode".to_string(),
                state: "wedged".to_string(),
                pending: 0,
            },
        ]), None);
        assert_ne!(parse_drain_result(&r), DrainParseResult::Idle);
    }

    #[test]
    fn parse_drain_result_no_entries_falls_back_to_text_idle() {
        let r = make_result(None, Some(
            "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 100"
        ));
        assert_eq!(parse_drain_result(&r), DrainParseResult::Idle);
    }

    #[test]
    fn parse_drain_result_no_entries_falls_back_to_text_draining() {
        let r = make_result(None, Some(
            "drains: 1\n  corpus_encode: draining \u{2014} pending: 7, in_flight: 1, encoded_chunks: 50"
        ));
        assert_eq!(parse_drain_result(&r), DrainParseResult::Draining);
    }

    // ── dream_status_from_result: structured drain_entries path ──

    #[test]
    fn dream_status_from_result_dreaming_idle_settled() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "corpus_encode".to_string(), state: "idle".to_string(), pending: 0 },
            crate::mcp_result::V2DrainEntry { name: "dreaming".to_string(), state: "idle".to_string(), pending: 0 },
        ]), None);
        let status = dream_status_from_result(&r);
        assert_eq!(status.pending, 0);
        assert!(!status.draining);
    }

    #[test]
    fn dream_status_from_result_dreaming_draining_not_settled() {
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "dreaming".to_string(), state: "draining".to_string(), pending: 12 },
        ]), None);
        let status = dream_status_from_result(&r);
        assert_eq!(status.pending, 12);
        assert!(status.draining);
    }

    #[test]
    fn dream_status_from_result_no_dreaming_lane_settled() {
        // No "dreaming" entry → settled (default DreamStatus).
        let r = make_result(Some(vec![
            crate::mcp_result::V2DrainEntry { name: "corpus_encode".to_string(), state: "idle".to_string(), pending: 0 },
        ]), None);
        let status = dream_status_from_result(&r);
        assert_eq!(status.pending, 0);
        assert!(!status.draining);
    }

    #[test]
    fn dream_status_from_result_falls_back_to_text_draining() {
        let r = make_result(None, Some(
            "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  dreaming: draining \u{2014} pending: 5, in_flight: 2"
        ));
        let status = dream_status_from_result(&r);
        assert_eq!(status.pending, 5);
        assert!(status.draining);
    }
}
