//! stats.rs — standing/rolling statistics for a live bridge session (Rust twin).
//!
//! Mirrors the Swift `BridgeStats`: per-backend named latency series (mean / p95 /
//! count over a bounded sliding window) plus a secondary-failure count — the
//! number of write fan-outs to the non-primary backend that failed and were
//! swallowed so the client never saw an error. Per Bob: the bridge tracks stats.
//!
//! Concurrency: the bridge's run loop is single-threaded (one client line at a
//! time, fully handled before the next), so a plain owned struct suffices here —
//! no lock needed, unlike the Swift actor (Swift's mirror fan-out is an async
//! task on a shared actor; the Rust twin runs the fan-out inline on the same
//! thread). Stats flush to stderr on shutdown (never stdout — the JSON-RPC
//! channel).

use std::collections::BTreeMap;

/// Sliding-window capacity per series. 4096 keeps p95 stable over recent traffic
/// while bounding memory, matching the Swift `BridgeSeries` cap.
const SERIES_CAP: usize = 4096;

/// A single named latency series with running mean / p95 over a bounded window.
#[derive(Debug, Default, Clone)]
struct BridgeSeries {
    /// Most recent samples, seconds. Bounded to `SERIES_CAP` (sliding window).
    samples: Vec<f64>,
    /// Total samples ever recorded (not just the retained window).
    total_count: usize,
}

impl BridgeSeries {
    fn record(&mut self, seconds: f64) {
        self.total_count += 1;
        self.samples.push(seconds);
        if self.samples.len() > SERIES_CAP {
            let overflow = self.samples.len() - SERIES_CAP;
            self.samples.drain(0..overflow);
        }
    }

    fn mean(&self) -> f64 {
        if self.samples.is_empty() {
            return 0.0;
        }
        self.samples.iter().sum::<f64>() / self.samples.len() as f64
    }

    /// 95th percentile over the retained window (nearest-rank), or 0 when empty.
    /// Same method as the Swift twin so the two surfaces report on one scale.
    fn p95(&self) -> f64 {
        if self.samples.is_empty() {
            return 0.0;
        }
        let mut sorted = self.samples.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let rank = (0.95 * sorted.len() as f64).ceil() as usize;
        let index = rank.max(1) - 1;
        let index = index.min(sorted.len() - 1);
        sorted[index]
    }
}

/// An immutable snapshot of one series.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeSeriesSnapshot {
    pub label: String,
    pub mean: f64,
    pub p95: f64,
    pub total_count: usize,
}

/// An immutable snapshot of the whole bridge-stats struct.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeStatsSnapshot {
    /// Per-label latency series, sorted by label for stable output.
    pub series: Vec<BridgeSeriesSnapshot>,
    /// Swallowed secondary-write failures.
    pub secondary_failure_count: usize,
}

impl BridgeStatsSnapshot {
    /// Renders the snapshot as a human-readable block for stderr.
    pub fn rendered(&self, title: &str) -> String {
        let mut out = format!("{title}\n");
        for s in &self.series {
            out.push_str(&format!(
                "  {:<30} mean {:8.2} ms   p95 {:8.2} ms   n={}\n",
                s.label,
                s.mean * 1000.0,
                s.p95 * 1000.0,
                s.total_count
            ));
        }
        if self.secondary_failure_count > 0 {
            out.push_str(&format!(
                "  secondary write failures (non-fatal, swallowed): {}\n",
                self.secondary_failure_count
            ));
        }
        out
    }
}

/// The rolling/standing statistics for a live bridge session.
#[derive(Debug, Default)]
pub struct BridgeStats {
    series: BTreeMap<String, BridgeSeries>,
    secondary_failure_count: usize,
}

impl BridgeStats {
    pub fn new() -> Self {
        BridgeStats::default()
    }

    /// Records one latency sample (seconds) into the named series.
    pub fn record_latency(&mut self, seconds: f64, label: &str) {
        self.series
            .entry(label.to_string())
            .or_default()
            .record(seconds);
    }

    /// Records one swallowed secondary-write failure.
    pub fn record_secondary_failure(&mut self) {
        self.secondary_failure_count += 1;
    }

    /// Takes an immutable snapshot. Series are emitted in sorted-label order
    /// (BTreeMap iterates sorted) for stable output.
    pub fn snapshot(&self) -> BridgeStatsSnapshot {
        let series = self
            .series
            .iter()
            .map(|(label, s)| BridgeSeriesSnapshot {
                label: label.clone(),
                mean: s.mean(),
                p95: s.p95(),
                total_count: s.total_count,
            })
            .collect();
        BridgeStatsSnapshot {
            series,
            secondary_failure_count: self.secondary_failure_count,
        }
    }
}
