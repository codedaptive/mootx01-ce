//! Gauntlet report — aggregation and rendering of a gauntlet run.
//!
//! Port of `GauntletReport.swift` (Phase 2.2). Aggregates per-needle
//! [`NeedleScore`] values into per-tier and per-strategy tables, renders the
//! human report (header + per-tier tables + leaderboard + worst-10 appendix),
//! and defines the complete [`GauntletRunReport`] struct with all lane-standard
//! fields (C1/C4/C5/C6, benchmark reset 2026-08-13).
//!
//! Aggregation is pure: no live contact, no clock reads — the run label and
//! timestamp are passed in by the CLI so the report is deterministic.
//!
//! ASYNC → SYNC ASYMMETRY: Swift's `GauntletRunner` is async; the Rust port is
//! synchronous (one MCP connection, sequential scoring). The report struct and
//! its rendering are identical across the ports.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::gauntlet_corpus::NoiseTier;
use crate::gauntlet_scorer::NeedleScore;
use crate::run_environment::RunEnvironment;

// ─────────────────────────────────────────────────────────────────────────────
// StrategyTierAggregate
// ─────────────────────────────────────────────────────────────────────────────

/// The aggregate for one strategy over one tier (or over ALL tiers when `tier`
/// is `None`): mean found@k, MRR, mean completeness, mean contamination, and
/// latency mean/p95. Mirrors Swift `StrategyTierAggregate`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StrategyTierAggregate {
    /// `None` = aggregate across every tier (the per-strategy overall row).
    pub tier: Option<NoiseTier>,
    pub needle_count: usize,
    /// Mean found@k (fraction of needles found within k), keyed by k.
    /// Keys are stringified integers so JSON sidecar round-trips cleanly.
    pub found_at_k: HashMap<i32, f64>,
    pub mrr: f64,
    pub completeness: f64,
    pub mean_contamination: f64,
    pub latency_mean_seconds: f64,
    pub latency_p95_seconds: f64,
}

impl StrategyTierAggregate {
    /// Builds the aggregate from a slice of per-needle scores. Mirrors Swift
    /// `StrategyTierAggregate.from(tier:scores:kValues:)`.
    pub fn from_scores(
        tier: Option<NoiseTier>,
        scores: &[NeedleScore],
        k_values: &[i32],
    ) -> Self {
        let n = scores.len();
        if n == 0 {
            let zeros: HashMap<i32, f64> = k_values.iter().map(|&k| (k, 0.0)).collect();
            return Self {
                tier,
                needle_count: 0,
                found_at_k: zeros,
                mrr: 0.0,
                completeness: 0.0,
                mean_contamination: 0.0,
                latency_mean_seconds: 0.0,
                latency_p95_seconds: 0.0,
            };
        }

        let mut found: HashMap<i32, f64> = HashMap::new();
        for &k in k_values {
            let hits: usize = scores
                .iter()
                .filter(|s| *s.found_at_k.get(&k).unwrap_or(&false))
                .count();
            found.insert(k, hits as f64 / n as f64);
        }

        let mrr = scores.iter().map(|s| s.reciprocal_rank()).sum::<f64>() / n as f64;
        let completeness = scores.iter().map(|s| s.completeness).sum::<f64>() / n as f64;
        let contamination =
            scores.iter().map(|s| s.contamination as f64).sum::<f64>() / n as f64;

        let mut latencies: Vec<f64> = scores.iter().map(|s| s.latency_seconds).collect();
        latencies.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let lat_mean = latencies.iter().sum::<f64>() / n as f64;

        // p95 by nearest-rank on sorted samples. Mirrors Swift's convention:
        // `Int((Double(count) * 0.95).rounded(.up)) - 1` clamped to [0, count-1].
        let p95_index = {
            let raw = ((n as f64 * 0.95).ceil() as usize).saturating_sub(1);
            raw.min(n - 1)
        };
        let lat_p95 = latencies[p95_index];

        Self {
            tier,
            needle_count: n,
            found_at_k: found,
            mrr,
            completeness,
            mean_contamination: contamination,
            latency_mean_seconds: lat_mean,
            latency_p95_seconds: lat_p95,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// StrategyResult
// ─────────────────────────────────────────────────────────────────────────────

/// One strategy column's full result: its name, every per-needle score, and the
/// per-tier + overall aggregates. Mirrors Swift `StrategyResult`.
#[derive(Debug, Clone)]
pub struct StrategyResult {
    pub name: String,
    pub is_mootx01: bool,
    pub scores: Vec<NeedleScore>,
    pub per_tier: Vec<StrategyTierAggregate>,
    pub overall: StrategyTierAggregate,
}

impl StrategyResult {
    /// Constructs from flat scores, computing per-tier and overall aggregates.
    /// Mirrors Swift `StrategyResult.build(name:isMootx01:scores:kValues:)`.
    pub fn build(
        name: String,
        is_mootx01: bool,
        scores: Vec<NeedleScore>,
        k_values: &[i32],
    ) -> Self {
        let mut per_tier: Vec<StrategyTierAggregate> = Vec::new();
        for tier in NoiseTier::all_cases() {
            let slice: Vec<&NeedleScore> =
                scores.iter().filter(|s| s.tier == tier).collect();
            if slice.is_empty() { continue; }
            let owned: Vec<NeedleScore> = slice.into_iter().cloned().collect();
            per_tier.push(StrategyTierAggregate::from_scores(Some(tier), &owned, k_values));
        }
        let overall = StrategyTierAggregate::from_scores(None, &scores, k_values);
        Self { name, is_mootx01, scores, per_tier, overall }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RetainedFailure
// ─────────────────────────────────────────────────────────────────────────────

/// A retained worst-case failure: the needle, the strategy that failed it, and
/// the full request/response kept for inspection. Mirrors Swift `RetainedFailure`.
#[derive(Debug, Clone)]
pub struct RetainedFailure {
    pub strategy_name: String,
    pub needle_id: String,
    pub tier: NoiseTier,
    pub query: String,
    pub request: String,
    pub response: String,
    pub reason: String,
    /// Sort key — higher is worse. Used to select the worst 10.
    pub severity: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// GauntletRunReport
// ─────────────────────────────────────────────────────────────────────────────

/// The complete gauntlet run report. Mirrors Swift `GauntletRunReport`.
///
/// Lane-standard fields (C1/C4/C5/C6 — benchmark reset 2026-08-13) are set
/// post-construction by the CLI, matching the Swift pattern.
#[derive(Debug, Clone)]
pub struct GauntletRunReport {
    pub seed: u64,
    pub run_label: String,
    pub k_values: Vec<i32>,
    pub distractors_per_needle: usize,
    pub tier_counts: HashMap<NoiseTier, usize>,
    pub strategies: Vec<StrategyResult>,
    /// Up to ten retained worst failures across all strategies.
    pub worst_failures: Vec<RetainedFailure>,
    /// True when the DegeneracyGuard ran and returned healthy for every backend.
    pub guard_healthy: bool,
    /// When true, the precise-recall composition columns were skipped (--quick).
    pub quick_mode: bool,
    /// Caller-supplied header epilogue (a caller supplying a baseline column
    /// inserts its evaluation text here; moot-only runs leave it empty).
    pub header_epilogue: String,

    // ── Provenance (stale-report detection) ─────────────────────────────────
    pub git_sha: String,
    pub git_dirty_count: Option<i32>,
    pub run_timestamp: String,
    pub columns_run: Vec<String>,
    pub composition_list_version: Vec<String>,
    pub run_environment: Option<RunEnvironment>,

    // ── Lane standard fields (C1/C4/C5/C6 — benchmark reset 2026-08-13) ────
    /// Estate storage shape: "disk" (SQLite, default) or "ram" (inmemory, C1).
    pub shape: String,
    /// How the DegeneracyGuard was sampled. "once" = structurally once-per-run.
    pub guard_sampling: String,
    /// Effective parallel units. Always 1 for the gauntlet (one MCP connection).
    pub parallel_units: usize,
    /// moot_timing_report text captured after load + dream, before needle scoring.
    /// Nil when the tool was unavailable or the capture failed.
    pub timing_report: Option<String>,
    /// How the timing report was sampled. "once-per-run" for the gauntlet.
    pub timing_sampling: String,
    /// The estate manifest `schema_version` for artifacts in this run.
    /// Per BENCHMARK_PROTOCOL §9 this appears in every report header so the
    /// historical table can carry the column. Defaults to
    /// `CURRENT_ESTATE_SCHEMA_VERSION` at construction. Twin of Swift
    /// `estateSchemaVersion`.
    pub estate_schema_version: String,
}

impl GauntletRunReport {
    /// Renders the full human report: header, per-tier tables, per-strategy
    /// aggregate, ablation leaderboard, and worst-10 appendix.
    /// Mirrors Swift `GauntletRunReport.rendered()`.
    pub fn rendered(&self) -> String {
        let mut out = String::new();
        out.push_str("================ MOOT RETRIEVAL GAUNTLET — v1 ================\n");
        if self.quick_mode {
            out.push_str(
                "⚠  QUICK MODE — precise ablation grid skipped (composition columns omitted)\n",
            );
            out.push_str(
                "   Re-run without --quick for the full ablation grid (~25 min).\n\n",
            );
        }
        out.push_str(&format!("seed:                 {}\n", self.seed));
        out.push_str(&format!("run label:            {}\n", self.run_label));
        out.push_str(&format!("git SHA:              {}\n", self.git_sha));
        let dirty_desc = match self.git_dirty_count {
            None => "(not recorded)".to_string(),
            Some(-1) => "unknown (git unavailable)".to_string(),
            Some(0) => "CLEAN".to_string(),
            Some(n) => format!(
                "DIRTY ({} paths) — source may not match the SHA above",
                n
            ),
        };
        out.push_str(&format!("working tree:         {}\n", dirty_desc));
        let ts = if self.run_timestamp.is_empty() {
            "(not set)".to_string()
        } else {
            self.run_timestamp.clone()
        };
        out.push_str(&format!("run timestamp:        {}\n", ts));
        let k_str: Vec<String> = self.k_values.iter().map(|k| k.to_string()).collect();
        out.push_str(&format!("found@k depths:       {}\n", k_str.join(", ")));
        out.push_str(&format!(
            "distractors/needle:   {}\n",
            self.distractors_per_needle
        ));
        // Tier profile in canonical T1→T5 order.
        let tier_profile: Vec<String> = NoiseTier::all_cases()
            .iter()
            .filter_map(|t| self.tier_counts.get(t).map(|&n| format!("{}={}", t.raw_value(), n)))
            .collect();
        out.push_str(&format!("tier profile:         {}\n", tier_profile.join(" ")));
        out.push_str(&format!("shape:                {}\n", self.shape));
        out.push_str(&format!(
            "parallel units:       {} (serial — shared backend, single MCP connection)\n",
            self.parallel_units
        ));
        let guard_healthy_str = if self.guard_healthy {
            "HEALTHY (ran on every backend)"
        } else {
            "NOT HEALTHY"
        };
        out.push_str(&format!(
            "DegeneracyGuard:      {} [{}]\n",
            guard_healthy_str, self.guard_sampling
        ));
        let col_line = if self.columns_run.is_empty() {
            "(not recorded)".to_string()
        } else {
            self.columns_run.join(", ")
        };
        out.push_str(&format!("columns run:          {}\n", col_line));
        let comp_line = if self.composition_list_version.is_empty() {
            "(not recorded)".to_string()
        } else {
            self.composition_list_version.join(", ")
        };
        out.push_str(&format!("composition grid:     {}\n", comp_line));
        // Per BENCHMARK_PROTOCOL §9: estate schema version in every report
        // header so the historical table carries the column.
        out.push_str(&format!(
            "estate schema ver:    {}\n",
            self.estate_schema_version
        ));

        if !self.header_epilogue.is_empty() {
            out.push('\n');
            out.push_str(&self.header_epilogue);
            out.push_str("\n\n");
        } else {
            out.push('\n');
        }

        // Per-tier table: one block per tier, every strategy as a row.
        out.push_str("---------------- PER-TIER RESULTS ----------------\n");
        for tier in NoiseTier::all_cases() {
            let has_tier = self
                .strategies
                .iter()
                .any(|s| s.per_tier.iter().any(|a| a.tier == Some(tier)));
            if !has_tier { continue; }
            out.push_str(&format!("\nTier {}:\n", tier.raw_value()));
            out.push_str(&self.row_header());
            for s in &self.strategies {
                if let Some(agg) = s.per_tier.iter().find(|a| a.tier == Some(tier)) {
                    out.push_str(&self.row(&s.name, agg));
                }
            }
        }

        // Per-strategy aggregate.
        out.push_str(
            "\n---------------- PER-STRATEGY AGGREGATE (all tiers) ----------------\n",
        );
        out.push_str(&self.row_header());
        for s in &self.strategies {
            out.push_str(&self.row(&s.name, &s.overall));
        }

        // Ablation leaderboard.
        out.push('\n');
        out.push_str(&self.leaderboard());

        // Worst-10 failures appendix.
        out.push_str(
            "\n---------------- WORST 10 FAILURES (full request/response retained) ----------------\n",
        );
        if self.worst_failures.is_empty() {
            out.push_str(
                "(none — every needle was found and complete on every strategy)\n",
            );
        }
        for (i, f) in self.worst_failures.iter().enumerate() {
            out.push_str(&format!(
                "\n[{}] strategy={} needle={} tier={} reason={}\n",
                i + 1,
                f.strategy_name,
                f.needle_id,
                f.tier.raw_value(),
                f.reason
            ));
            out.push_str(&format!("    query:    {}\n", f.query));
            out.push_str(&format!("    request:  {}\n", f.request));
            out.push_str(&format!("    response: {}\n", truncate_for_log(&f.response)));
        }
        out.push_str("\n=============================================================\n");
        out
    }

    /// Ablation leaderboard: per-tier and aggregate, every column ranked by
    /// (found@1, MRR, found@deepest), deterministic name tie-break.
    /// Mirrors Swift `GauntletRunReport.leaderboard()`.
    fn leaderboard(&self) -> String {
        let mut out = String::from(
            "---------------- ABLATION LEADERBOARD (ranked by found@1, then MRR, then found@10) ----------------\n",
        );
        let deepest = self.k_values.iter().max().copied().unwrap_or(10);

        // Per-tier blocks + aggregate block.
        let mut blocks: Vec<(String, Vec<(&str, &StrategyTierAggregate)>)> = Vec::new();
        for tier in NoiseTier::all_cases() {
            let mut rows: Vec<(&str, &StrategyTierAggregate)> = Vec::new();
            for s in &self.strategies {
                if let Some(agg) = s.per_tier.iter().find(|a| a.tier == Some(tier)) {
                    rows.push((s.name.as_str(), agg));
                }
            }
            if !rows.is_empty() {
                blocks.push((format!("Tier {}", tier.raw_value()), rows));
            }
        }
        let aggregate_rows: Vec<(&str, &StrategyTierAggregate)> =
            self.strategies.iter().map(|s| (s.name.as_str(), &s.overall)).collect();
        blocks.push(("AGGREGATE (all tiers)".to_string(), aggregate_rows));

        for (label, mut rows) in blocks {
            // Sort descending: found@1, then MRR, then found@deepest, then name asc.
            rows.sort_by(|(ln, la), (rn, ra)| {
                let lf1 = la.found_at_k.get(&1).copied().unwrap_or(0.0);
                let rf1 = ra.found_at_k.get(&1).copied().unwrap_or(0.0);
                if (lf1 - rf1).abs() > 1e-9 {
                    return rf1.partial_cmp(&lf1).unwrap_or(std::cmp::Ordering::Equal);
                }
                if (la.mrr - ra.mrr).abs() > 1e-9 {
                    return ra.mrr.partial_cmp(&la.mrr).unwrap_or(std::cmp::Ordering::Equal);
                }
                let lfd = la.found_at_k.get(&deepest).copied().unwrap_or(0.0);
                let rfd = ra.found_at_k.get(&deepest).copied().unwrap_or(0.0);
                if (lfd - rfd).abs() > 1e-9 {
                    return rfd.partial_cmp(&lfd).unwrap_or(std::cmp::Ordering::Equal);
                }
                ln.cmp(rn) // deterministic name tie-break
            });

            let winner = rows.first().map(|(n, _)| *n).unwrap_or("(none)");
            out.push_str(&format!("\n{} — winner: {}\n", label, winner));
            // Indented rank header.
            let raw_header = self.row_header();
            out.push_str(&format!(
                "  rank  {}",
                raw_header.trim_start()
            ));
            for (i, (name, agg)) in rows.iter().enumerate() {
                let raw_row = self.row(name, agg);
                out.push_str(&format!("  {:2}. {}", i + 1, raw_row.trim_start()));
            }
        }
        out
    }

    fn row_header(&self) -> String {
        let mut h = pad_right("  strategy", 26);
        for &k in &self.k_values {
            h.push_str(&pad_right(&format!("f@{k}"), 8));
        }
        h.push_str(&pad_right("MRR", 8));
        h.push_str(&pad_right("compl", 8));
        h.push_str(&pad_right("contam", 8));
        h.push_str(&pad_right("lat_ms", 9));
        h.push_str("p95_ms\n");
        h
    }

    fn row(&self, name: &str, agg: &StrategyTierAggregate) -> String {
        let mut r = pad_right(&format!("  {name}"), 26);
        for &k in &self.k_values {
            r.push_str(&pad_right(
                &format!("{:.2}", agg.found_at_k.get(&k).copied().unwrap_or(0.0)),
                8,
            ));
        }
        r.push_str(&pad_right(&format!("{:.3}", agg.mrr), 8));
        r.push_str(&pad_right(&format!("{:.2}", agg.completeness), 8));
        r.push_str(&pad_right(&format!("{:.2}", agg.mean_contamination), 8));
        r.push_str(&pad_right(
            &format!("{:.1}", agg.latency_mean_seconds * 1000.0),
            9,
        ));
        r.push_str(&format!("{:.1}", agg.latency_p95_seconds * 1000.0));
        r.push('\n');
        r
    }
}

/// Right-pads `s` to `width` with spaces. Mirrors Swift's
/// `padding(toLength:withPad:startingAt:)` for ASCII strings.
fn pad_right(s: &str, width: usize) -> String {
    if s.len() >= width {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(width - s.len()))
    }
}

/// Bounds a retained response in the rendered text so the report stays readable.
/// Matches Swift `GauntletRunReport.truncateForLog`.
fn truncate_for_log(s: &str) -> String {
    let one_line = s.replace('\n', " ⏎ ");
    // Cap the total output at 400 bytes. The suffix " …[truncated]" is 15
    // bytes (1 space + 3-byte U+2026 + 11 ASCII), so the content window is
    // 400 - 15 = 385 bytes. We slice at a char boundary by scanning down from
    // the byte cap until we land on one.
    const TOTAL_CAP: usize = 400;
    const SUFFIX: &str = " \u{2026}[truncated]"; // U+2026 = 3 UTF-8 bytes
    if one_line.len() > TOTAL_CAP {
        let content_cap = TOTAL_CAP - SUFFIX.len();
        // Truncate to a valid char boundary at or before content_cap.
        let end = one_line
            .char_indices()
            .take_while(|(i, _)| *i < content_cap)
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(content_cap.min(one_line.len()));
        format!("{}{}", &one_line[..end], SUFFIX)
    } else {
        one_line
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gauntlet_corpus::NoiseTier;
    use std::collections::HashMap;

    fn make_score(tier: NoiseTier, rank: Option<usize>, latency: f64) -> NeedleScore {
        let mut found_at_k = HashMap::new();
        found_at_k.insert(1, rank.map(|r| r <= 1).unwrap_or(false));
        found_at_k.insert(5, rank.map(|r| r <= 5).unwrap_or(false));
        found_at_k.insert(10, rank.map(|r| r <= 10).unwrap_or(false));
        NeedleScore {
            needle_id: "n0001".to_string(),
            tier,
            found_at_k,
            rank,
            completeness: if rank == Some(1) { 1.0 } else { 0.0 },
            contamination: 0,
            latency_seconds: latency,
            bytes_returned: 100,
        }
    }

    // ── StrategyTierAggregate ─────────────────────────────────────────────────

    #[test]
    fn aggregate_empty_scores_returns_zeros() {
        let agg = StrategyTierAggregate::from_scores(None, &[], &[1, 5, 10]);
        assert_eq!(agg.needle_count, 0);
        assert_eq!(agg.mrr, 0.0);
        assert_eq!(agg.found_at_k.get(&1), Some(&0.0));
    }

    #[test]
    fn aggregate_found_at_k_correct() {
        // Two needles: one at rank 1, one at rank 8.
        let scores = vec![
            make_score(NoiseTier::Lexical, Some(1), 0.1),
            make_score(NoiseTier::Lexical, Some(8), 0.2),
        ];
        let agg = StrategyTierAggregate::from_scores(Some(NoiseTier::Lexical), &scores, &[1, 5, 10]);
        assert_eq!(agg.needle_count, 2);
        // found@1: 1/2 = 0.5.
        assert!((agg.found_at_k[&1] - 0.5).abs() < 1e-9);
        // found@5: 1/2 = 0.5 (only rank-1 is within 5).
        assert!((agg.found_at_k[&5] - 0.5).abs() < 1e-9);
        // found@10: 2/2 = 1.0.
        assert!((agg.found_at_k[&10] - 1.0).abs() < 1e-9);
    }

    #[test]
    fn aggregate_mrr_correct() {
        let scores = vec![
            make_score(NoiseTier::Lexical, Some(1), 0.1), // RR=1.0
            make_score(NoiseTier::Lexical, Some(4), 0.2), // RR=0.25
        ];
        let agg = StrategyTierAggregate::from_scores(None, &scores, &[1, 5, 10]);
        // MRR = (1.0 + 0.25) / 2 = 0.625.
        assert!((agg.mrr - 0.625).abs() < 1e-9);
    }

    #[test]
    fn aggregate_p95_single_sample() {
        let scores = vec![make_score(NoiseTier::Lexical, Some(1), 0.5)];
        let agg = StrategyTierAggregate::from_scores(None, &scores, &[1]);
        assert!((agg.latency_p95_seconds - 0.5).abs() < 1e-9);
    }

    // ── StrategyResult ────────────────────────────────────────────────────────

    #[test]
    fn strategy_result_builds_per_tier_and_overall() {
        let scores = vec![
            make_score(NoiseTier::Lexical, Some(1), 0.1),
            make_score(NoiseTier::Semantic, Some(2), 0.2),
        ];
        let result = StrategyResult::build("test".to_string(), true, scores, &[1, 5, 10]);
        // Two tiers in per_tier.
        assert_eq!(result.per_tier.len(), 2);
        // Overall is all-tier aggregate.
        assert_eq!(result.overall.needle_count, 2);
    }

    // ── pad_right ─────────────────────────────────────────────────────────────

    #[test]
    fn pad_right_pads_short_string() {
        assert_eq!(pad_right("hi", 6), "hi    ");
    }

    #[test]
    fn pad_right_leaves_long_string_unchanged() {
        assert_eq!(pad_right("toolong", 4), "toolong");
    }

    // ── truncate_for_log ──────────────────────────────────────────────────────

    #[test]
    fn truncate_replaces_newlines() {
        let s = truncate_for_log("line1\nline2");
        assert!(s.contains(" ⏎ "));
    }

    #[test]
    fn truncate_caps_at_400_chars() {
        let long = "x".repeat(500);
        let t = truncate_for_log(&long);
        // Total output is capped at 400 bytes: 385 content + 15-byte suffix
        // " …[truncated]" (space + 3-byte U+2026 + "[truncated]").
        assert!(t.len() <= 400);
        assert!(t.ends_with("\u{2026}[truncated]"));
    }
}
