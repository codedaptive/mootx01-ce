//! C4 (benchmark reset 2026-08-13): leg-level capture of the estate's
//! audit-derived timing report — the four CYCLE tiers plus INGEST samples —
//! via the `moot_timing_report` maintenance tool (C3+A6 derivation engine,
//! §6b one-derivation-two-consumers; the harness is the first consumer).
//! Mirrors Swift `TimingCapture.swift`.
//!
//! The harness cannot link the kits (layering rule: benchmark deps are the
//! harness-local crates only), so the tiers arrive as the tool's rendered
//! report text and are embedded verbatim in the lane report JSON. The
//! renderer is byte-compatible across the Swift and Rust servers, so the
//! embedded text also serves cross-port parity diffs.

use std::collections::BTreeMap;
use std::sync::Mutex;

use crate::config::ResultFormat;
use crate::mcp_client::ToolCaller;

/// Manages timing-report capture across the units of one benchmark leg.
///
/// Create one sampler at the start of a leg; call [`LegTimingSampler::capture`]
/// at each unit's settle point (after ingest → drain → dream → reindex, while
/// the unit's estate is still alive). The fetch closure runs on the FIRST
/// unit only; all subsequent units return the cached text with no MCP calls
/// issued. Sampling once per leg mirrors the DegeneracyGuard precedent (C5):
/// every unit of a leg builds the same estate shape, so one settled estate's
/// timing profile represents the leg. The report labels the sampling
/// explicitly (`timing_sampling`) so the cap is never silent.
///
/// Thread safety (C6): interior `Mutex` so parallel unit workers can share
/// one sampler by reference; exactly one worker issues the fetch. Mirrors
/// Swift's `LegTimingSampler` actor.
#[derive(Debug)]
pub struct LegTimingSampler {
    /// `None` = not yet captured. `Some(text)` = first capture completed
    /// (with `text == None` permanently when that first fetch failed — a
    /// fetch error is not retried on later units; the caller logs the miss).
    state: Mutex<Option<Option<String>>>,
}

impl LegTimingSampler {
    /// A fresh sampler for one leg.
    pub fn new() -> Self {
        Self { state: Mutex::new(None) }
    }

    /// Executes or skips the timing-report fetch for one unit.
    ///
    /// `fetch` calls `moot_timing_report` on the unit's live MCP client and
    /// returns the report text (`None` on error). Called only on the leg's
    /// first unit. Returns the leg's timing report text (first unit's
    /// capture), or `None` when the first capture failed.
    ///
    /// The fetch runs while the lock is held: under C6 that serialises
    /// same-instant first arrivals, which is exactly the once-per-leg
    /// contract (the losers return the winner's cached text).
    pub fn capture<F: FnOnce() -> Option<String>>(&self, fetch: F) -> Option<String> {
        let mut state = self.state.lock().expect("timing sampler lock poisoned");
        if let Some(cached) = state.as_ref() {
            return cached.clone();
        }
        let text = fetch();
        *state = Some(text.clone());
        text
    }

    /// The leg's captured report text without triggering a fetch. `None`
    /// when no unit reached a capture point (e.g. every unit restored from
    /// the artifact cache) or the first capture failed.
    pub fn text(&self) -> Option<String> {
        self.state
            .lock()
            .expect("timing sampler lock poisoned")
            .clone()
            .flatten()
    }
}

impl Default for LegTimingSampler {
    fn default() -> Self {
        Self::new()
    }
}

/// Calls `moot_timing_report` on a live client and returns the rendered
/// report text. A full-history scan (no `since_ms`) is correct here: lane
/// estates are born inside the run, so the audit log holds exactly this
/// unit's activity and no watermark is needed.
///
/// Errors are swallowed into `None` by design — timing capture is
/// observability riding an accuracy lane, and a capture failure must never
/// abort a measurement run. The caller logs the miss.
pub fn fetch_timing_report(client: &mut dyn ToolCaller) -> Option<String> {
    let result = client
        .call_tool(crate::aria_v2_surface::TIMING_REPORT, BTreeMap::new(), &ResultFormat::MootV2)
        .ok()?;
    let text = result.text_blocks.join("\n");
    if text.is_empty() { None } else { Some(text) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_runs_fetch_once_and_caches() {
        let sampler = LegTimingSampler::new();
        let first = sampler.capture(|| Some("report-a".to_string()));
        assert_eq!(first.as_deref(), Some("report-a"));
        // Second unit: fetch must NOT run again — a panicking closure proves it.
        let second = sampler.capture(|| unreachable!("fetch must not re-run"));
        assert_eq!(second.as_deref(), Some("report-a"));
    }

    #[test]
    fn failed_first_capture_stays_nil_without_retry() {
        let sampler = LegTimingSampler::new();
        assert_eq!(sampler.capture(|| None), None);
        // The failure is cached; later units do not retry.
        let second = sampler.capture(|| unreachable!("failed capture must not retry"));
        assert_eq!(second, None);
    }
}
