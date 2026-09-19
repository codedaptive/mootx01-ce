//! replay_lane — deterministic-replay lane fingerprint and comparison.
//!
//! Twin of `ReplayLane.swift`. Design rationale there; short version:
//!
//!   The replay lane runs the supersession lane N times with the same seed
//!   and verifies bit-identical scored outcomes. Timing fields
//!   (`p50_latency_seconds`, `hunt_seconds`, `tier_seconds`) are excluded
//!   from the fingerprint because they legitimately vary with system load
//!   even when the computation is deterministic.
//!
//!   Doubles are compared with exact `==`. See [`compare_replay_fingerprints`]
//!   for the full rationale.

use crate::supersession_runner::{SupersessionLaneOutcome, SupersessionScores};

// ─────────────────────────────────────────────────────────────────────────────
// Fingerprint structures
// ─────────────────────────────────────────────────────────────────────────────

/// Deterministic-eligible fields from one supersession lane run.
///
/// Wall-clock fields are absent by design:
/// - `SupersessionScores.p50_latency_seconds` — excluded; query latency
///   varies with system load even when the computation is deterministic.
/// - `SupersessionContradictionOutcome.hunt_seconds` — excluded; same reason.
/// - `StructuredTierOutcome.tier_seconds` — excluded; same reason.
///
/// Twin of Swift `ReplayFingerprint`.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplayFingerprint {
    // ── Supersession scores ───────────────────────────────────────────────
    pub query_count: usize,
    pub current_win_rate: f64,
    pub current_found_rate: f64,
    pub mean_stale_in_top_k: f64,
    /// Mean rank of the current version among queries that found it.
    pub mean_current_rank: f64,

    // ── Contradiction sweep ────────────────────────────────────────────────
    /// `None` if the sweep was skipped (`--skip-contradictions`) or not
    /// configured. Twin of Swift `ReplayFingerprint.contradiction`.
    pub contradiction: Option<ContradictionFingerprint>,

    // ── Structured tier ───────────────────────────────────────────────────
    /// `None` if `--structured-tier` was absent. Twin of Swift
    /// `ReplayFingerprint.structuredTier`.
    pub structured_tier: Option<StructuredTierFingerprint>,

    // ── Tiered scoring ────────────────────────────────────────────────────
    /// `None` if the contradiction sweep was skipped, which means the tiered
    /// purpose runs never executed. Twin of Swift `ReplayFingerprint.tiered`.
    pub tiered: Option<TieredFingerprint>,
}

/// Fingerprint of the contradiction sweep. Hunt wall time is excluded.
/// Twin of Swift `ReplayFingerprint.ContradictionFingerprint`.
#[derive(Debug, Clone, PartialEq)]
pub struct ContradictionFingerprint {
    pub planted_count: usize,
    pub detected_any_tier: usize,
    pub detected_proposed: usize,
    pub flagged_outside_planted: usize,
}

/// Fingerprint of the typed proving tier. Tier wall time is excluded.
/// Twin of Swift `ReplayFingerprint.StructuredTierFingerprint`.
#[derive(Debug, Clone, PartialEq)]
pub struct StructuredTierFingerprint {
    pub planted_count: usize,
    pub proven_planted: usize,
    pub proven_outside_planted: usize,
    pub proven_reported: usize,
    pub historical_reported: usize,
    pub coverage_projected: usize,
    pub coverage_scanned: usize,
}

/// Fingerprint of the MXE-CT3 P4 tiered scoring outcome. Purpose-run wall
/// times (`tier*_purpose_seconds`, `synthesis_wall_seconds`) are excluded —
/// they measure wall time and legitimately vary between runs.
/// Twin of Swift `ReplayFingerprint.TieredFingerprint`.
#[derive(Debug, Clone, PartialEq)]
pub struct TieredFingerprint {
    pub tier2_planted_count: usize,
    pub tier2_detected: usize,
    pub tier3_planted_count: usize,
    pub tier3_detected: usize,
    pub tier_inflation: usize,
    /// Hard decoy hits: marker-supersession and distinct-entity decoys
    /// flagged in any tiered section or legacy PROPOSED output. Must be 0.
    pub decoy_hits_hard: usize,
    /// Known-limitation decoy hits: unit-equivalent decoys flagged,
    /// reported separately and never treated as a hard failure.
    pub decoy_hits_known_limitation: usize,
}

impl ReplayFingerprint {
    /// Builds a fingerprint from the lane's aggregate scores and outcome.
    ///
    /// Timing fields (`p50_latency_seconds`, `hunt_seconds`, `tier_seconds`)
    /// are NOT carried into the fingerprint: they measure wall time and
    /// legitimately vary between runs even when the product is deterministic.
    ///
    /// Twin of Swift `ReplayFingerprint.init(scores:outcome:)`.
    pub fn new(scores: &SupersessionScores, outcome: &SupersessionLaneOutcome) -> Self {
        ReplayFingerprint {
            query_count: scores.query_count,
            current_win_rate: scores.current_win_rate,
            current_found_rate: scores.current_found_rate,
            mean_stale_in_top_k: scores.mean_stale_in_top_k,
            mean_current_rank: scores.mean_current_rank,
            contradiction: outcome.contradiction.as_ref().map(|c| ContradictionFingerprint {
                planted_count: c.planted_count,
                detected_any_tier: c.detected_any_tier,
                detected_proposed: c.detected_proposed,
                flagged_outside_planted: c.flagged_outside_planted,
            }),
            structured_tier: outcome.structured.as_ref().map(|s| StructuredTierFingerprint {
                planted_count: s.planted_count,
                proven_planted: s.proven_planted,
                proven_outside_planted: s.proven_outside_planted,
                proven_reported: s.proven_reported,
                historical_reported: s.historical_reported,
                coverage_projected: s.coverage_projected,
                coverage_scanned: s.coverage_scanned,
            }),
            // Timing fields (tier*_purpose_seconds, synthesis_wall_seconds) are
            // intentionally excluded — see type-level comment.
            tiered: outcome.tiered.as_ref().map(|t| TieredFingerprint {
                tier2_planted_count:      t.tier2_planted_count,
                tier2_detected:           t.tier2_detected,
                tier3_planted_count:      t.tier3_planted_count,
                tier3_detected:           t.tier3_detected,
                tier_inflation:           t.tier_inflation,
                decoy_hits_hard:          t.decoy_hits.hard,
                decoy_hits_known_limitation: t.decoy_hits.known_limitation,
            }),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Field diff
// ─────────────────────────────────────────────────────────────────────────────

/// One field comparison row. An empty `Vec<ReplayFieldDiff>` from
/// [`compare_replay_fingerprints`] means deterministic.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplayFieldDiff {
    pub field_name: String,
    pub baseline_value: String,
    pub candidate_value: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Comparison
// ─────────────────────────────────────────────────────────────────────────────

/// Compares two replay fingerprints field by field. Returns one diff per
/// drifted field. An empty result means deterministic.
///
/// Doubles are compared with exact `==` on purpose: the claim under test is
/// bit-identical determinism across runs from the same seed. An epsilon
/// comparison would hide a real non-determinism bug — a 1-ULP difference is
/// not a rounding artefact but evidence of a state leak in the product.
///
/// Section-presence is itself a drift class: if the contradiction sweep or
/// structured tier ran in one fingerprint but not the other, that is reported
/// as a section-presence diff (e.g. `"contradiction.present": "true"` vs
/// `"false"`) rather than silently comparing `None` against a real value.
///
/// Twin of Swift `compareReplayFingerprints(baseline:candidate:)`.
#[allow(clippy::float_cmp)] // exact equality is intentional — see doc comment
pub fn compare_replay_fingerprints(
    baseline: &ReplayFingerprint,
    candidate: &ReplayFingerprint,
) -> Vec<ReplayFieldDiff> {
    let mut diffs: Vec<ReplayFieldDiff> = Vec::new();

    /// Push a diff only when the two values differ. Works for any `Display +
    /// PartialEq` type; the macro is local to this function.
    macro_rules! check {
        ($field:expr, $a:expr, $b:expr) => {
            if $a != $b {
                diffs.push(ReplayFieldDiff {
                    field_name: $field.to_string(),
                    baseline_value: format!("{}", $a),
                    candidate_value: format!("{}", $b),
                });
            }
        };
    }

    // ── Scores ────────────────────────────────────────────────────────────
    check!("queryCount",       baseline.query_count,         candidate.query_count);
    check!("currentWinRate",   baseline.current_win_rate,    candidate.current_win_rate);
    check!("currentFoundRate", baseline.current_found_rate,  candidate.current_found_rate);
    check!("meanStaleInTopK",  baseline.mean_stale_in_top_k, candidate.mean_stale_in_top_k);
    check!("meanCurrentRank",  baseline.mean_current_rank,   candidate.mean_current_rank);

    // ── Contradiction sweep ────────────────────────────────────────────────
    match (&baseline.contradiction, &candidate.contradiction) {
        (None, None) => {} // both absent: consistent
        (Some(_), None) => diffs.push(ReplayFieldDiff {
            field_name: "contradiction.present".to_string(),
            baseline_value: "true".to_string(),
            candidate_value: "false".to_string(),
        }),
        (None, Some(_)) => diffs.push(ReplayFieldDiff {
            field_name: "contradiction.present".to_string(),
            baseline_value: "false".to_string(),
            candidate_value: "true".to_string(),
        }),
        (Some(a), Some(b)) => {
            check!("contradiction.plantedCount",          a.planted_count,          b.planted_count);
            check!("contradiction.detectedAnyTier",       a.detected_any_tier,       b.detected_any_tier);
            check!("contradiction.detectedProposed",      a.detected_proposed,      b.detected_proposed);
            check!("contradiction.flaggedOutsidePlanted", a.flagged_outside_planted, b.flagged_outside_planted);
        }
    }

    // ── Structured tier ───────────────────────────────────────────────────
    match (&baseline.structured_tier, &candidate.structured_tier) {
        (None, None) => {}
        (Some(_), None) => diffs.push(ReplayFieldDiff {
            field_name: "structuredTier.present".to_string(),
            baseline_value: "true".to_string(),
            candidate_value: "false".to_string(),
        }),
        (None, Some(_)) => diffs.push(ReplayFieldDiff {
            field_name: "structuredTier.present".to_string(),
            baseline_value: "false".to_string(),
            candidate_value: "true".to_string(),
        }),
        (Some(a), Some(b)) => {
            check!("structuredTier.plantedCount",         a.planted_count,          b.planted_count);
            check!("structuredTier.provenPlanted",        a.proven_planted,         b.proven_planted);
            check!("structuredTier.provenOutsidePlanted", a.proven_outside_planted, b.proven_outside_planted);
            check!("structuredTier.provenReported",       a.proven_reported,        b.proven_reported);
            check!("structuredTier.historicalReported",   a.historical_reported,    b.historical_reported);
            check!("structuredTier.coverageProjected",    a.coverage_projected,     b.coverage_projected);
            check!("structuredTier.coverageScanned",      a.coverage_scanned,       b.coverage_scanned);
        }
    }

    // ── Tiered scoring ────────────────────────────────────────────────────
    // Section-presence is itself a drift class: if the tiered scoring ran in
    // one fingerprint but not the other, that asymmetry is reported via the
    // presence row rather than silently comparing None against a real value.
    match (&baseline.tiered, &candidate.tiered) {
        (None, None) => {} // both absent: consistent
        (Some(_), None) => diffs.push(ReplayFieldDiff {
            field_name: "tiered.present".to_string(),
            baseline_value: "true".to_string(),
            candidate_value: "false".to_string(),
        }),
        (None, Some(_)) => diffs.push(ReplayFieldDiff {
            field_name: "tiered.present".to_string(),
            baseline_value: "false".to_string(),
            candidate_value: "true".to_string(),
        }),
        (Some(a), Some(b)) => {
            check!("tiered.tier2PlantedCount",           a.tier2_planted_count,        b.tier2_planted_count);
            check!("tiered.tier2Detected",               a.tier2_detected,             b.tier2_detected);
            check!("tiered.tier3PlantedCount",           a.tier3_planted_count,        b.tier3_planted_count);
            check!("tiered.tier3Detected",               a.tier3_detected,             b.tier3_detected);
            check!("tiered.tierInflation",               a.tier_inflation,             b.tier_inflation);
            check!("tiered.decoyHits.hard",              a.decoy_hits_hard,            b.decoy_hits_hard);
            check!("tiered.decoyHits.knownLimitation",   a.decoy_hits_known_limitation, b.decoy_hits_known_limitation);
        }
    }

    diffs
}

// ─────────────────────────────────────────────────────────────────────────────
// Table printer
// ─────────────────────────────────────────────────────────────────────────────

/// Prints the rendered MATCH/DRIFT table (see `render_replay_field_table`).
/// Kept as a thin writer so the rendering itself is unit-testable — the
/// first live shakedown found a crash in the Swift twin's (then untested)
/// formatting path that no pure comparison test could have caught.
///
/// Twin of Swift `printReplayFieldTable`.
pub fn print_replay_field_table(
    baseline: &ReplayFingerprint,
    candidate: &ReplayFingerprint,
    diffs: &[ReplayFieldDiff],
    candidate_run_index: usize,
    seed: u64,
    total_runs: usize,
) {
    print!(
        "{}",
        render_replay_field_table(
            baseline, candidate, diffs, candidate_run_index, seed, total_runs
        )
    );
}

/// Renders a per-field MATCH/DRIFT table comparing `baseline` (run 1) against
/// `candidate` (run `candidate_run_index`), ending with the verdict line.
///
/// ALL fields are shown — including matching ones — so the report demonstrates
/// exactly what was checked, not only what changed. The presence rows for the
/// optional contradiction/structured-tier sections always appear; the
/// sub-field rows only appear when BOTH fingerprints have that section.
///
/// `diffs` must be the result of calling
/// `compare_replay_fingerprints(baseline, candidate)` on the same pair.
///
/// Twin of Swift `renderReplayFieldTable`.
pub fn render_replay_field_table(
    baseline: &ReplayFingerprint,
    candidate: &ReplayFingerprint,
    diffs: &[ReplayFieldDiff],
    candidate_run_index: usize,
    seed: u64,
    total_runs: usize,
) -> String {
    // Build the set of drifted field names for O(1) verdict lookup.
    let drifted: std::collections::HashSet<&str> =
        diffs.iter().map(|d| d.field_name.as_str()).collect();

    // Column widths (matching Swift twin).
    let col0 = 40usize; // field name
    let col1 = 22usize; // run 1 value
    let col2 = 22usize; // run N value

    let verdict = |field: &str| -> &str {
        if drifted.contains(field) { "DRIFT" } else { "MATCH" }
    };

    // Rendered lines, joined at the end — same shape as the Swift twin.
    let mut lines: Vec<String> = Vec::new();

    // Helper: format one table row.
    let row = |field: &str, v1: &str, v2: &str| -> String {
        format!(
            "{:<col0$}  {:<col1$}  {:<col2$}  {}",
            field, v1, v2,
            verdict(field),
            col0 = col0, col1 = col1, col2 = col2,
        )
    };

    let header = format!(
        "{:<col0$}  {:<col1$}  {:<col2$}  verdict",
        "field", "run 1", format!("run {candidate_run_index}"),
        col0 = col0, col1 = col1, col2 = col2,
    );
    let sep = "-".repeat(col0 + col1 + col2 + 20);

    lines.push(String::new());
    lines.push(header);
    lines.push(sep.clone());

    // ── Scores ────────────────────────────────────────────────────────────
    lines.push(row("queryCount",
        &baseline.query_count.to_string(),
        &candidate.query_count.to_string()));
    lines.push(row("currentWinRate",
        &format!("{:.6}", baseline.current_win_rate),
        &format!("{:.6}", candidate.current_win_rate)));
    lines.push(row("currentFoundRate",
        &format!("{:.6}", baseline.current_found_rate),
        &format!("{:.6}", candidate.current_found_rate)));
    lines.push(row("meanStaleInTopK",
        &format!("{:.6}", baseline.mean_stale_in_top_k),
        &format!("{:.6}", candidate.mean_stale_in_top_k)));
    lines.push(row("meanCurrentRank",
        &format!("{:.6}", baseline.mean_current_rank),
        &format!("{:.6}", candidate.mean_current_rank)));

    // ── Contradiction sweep ────────────────────────────────────────────────
    // Presence row always appears; sub-field rows only when both have the section.
    let contra_presence = |fp: &ReplayFingerprint| -> &str {
        if fp.contradiction.is_some() { "present" } else { "absent" }
    };
    lines.push(row("contradiction.present",
        contra_presence(baseline),
        contra_presence(candidate)));
    if let (Some(a), Some(b)) = (&baseline.contradiction, &candidate.contradiction) {
        lines.push(row("contradiction.plantedCount",
            &a.planted_count.to_string(), &b.planted_count.to_string()));
        lines.push(row("contradiction.detectedAnyTier",
            &a.detected_any_tier.to_string(), &b.detected_any_tier.to_string()));
        lines.push(row("contradiction.detectedProposed",
            &a.detected_proposed.to_string(), &b.detected_proposed.to_string()));
        lines.push(row("contradiction.flaggedOutsidePlanted",
            &a.flagged_outside_planted.to_string(), &b.flagged_outside_planted.to_string()));
    }

    // ── Structured tier ───────────────────────────────────────────────────
    let struct_presence = |fp: &ReplayFingerprint| -> &str {
        if fp.structured_tier.is_some() { "present" } else { "absent" }
    };
    lines.push(row("structuredTier.present",
        struct_presence(baseline),
        struct_presence(candidate)));
    if let (Some(a), Some(b)) = (&baseline.structured_tier, &candidate.structured_tier) {
        lines.push(row("structuredTier.plantedCount",
            &a.planted_count.to_string(), &b.planted_count.to_string()));
        lines.push(row("structuredTier.provenPlanted",
            &a.proven_planted.to_string(), &b.proven_planted.to_string()));
        lines.push(row("structuredTier.provenOutsidePlanted",
            &a.proven_outside_planted.to_string(), &b.proven_outside_planted.to_string()));
        lines.push(row("structuredTier.provenReported",
            &a.proven_reported.to_string(), &b.proven_reported.to_string()));
        lines.push(row("structuredTier.historicalReported",
            &a.historical_reported.to_string(), &b.historical_reported.to_string()));
        lines.push(row("structuredTier.coverageProjected",
            &a.coverage_projected.to_string(), &b.coverage_projected.to_string()));
        lines.push(row("structuredTier.coverageScanned",
            &a.coverage_scanned.to_string(), &b.coverage_scanned.to_string()));
    }

    // ── Tiered scoring ────────────────────────────────────────────────────
    // Presence row always appears; sub-field rows only when both fingerprints
    // carry the section. The presence row already captures the asymmetric case.
    let tiered_presence = |fp: &ReplayFingerprint| -> &str {
        if fp.tiered.is_some() { "present" } else { "absent" }
    };
    lines.push(row("tiered.present",
        tiered_presence(baseline),
        tiered_presence(candidate)));
    if let (Some(a), Some(b)) = (&baseline.tiered, &candidate.tiered) {
        lines.push(row("tiered.tier2PlantedCount",
            &a.tier2_planted_count.to_string(), &b.tier2_planted_count.to_string()));
        lines.push(row("tiered.tier2Detected",
            &a.tier2_detected.to_string(), &b.tier2_detected.to_string()));
        lines.push(row("tiered.tier3PlantedCount",
            &a.tier3_planted_count.to_string(), &b.tier3_planted_count.to_string()));
        lines.push(row("tiered.tier3Detected",
            &a.tier3_detected.to_string(), &b.tier3_detected.to_string()));
        lines.push(row("tiered.tierInflation",
            &a.tier_inflation.to_string(), &b.tier_inflation.to_string()));
        lines.push(row("tiered.decoyHits.hard",
            &a.decoy_hits_hard.to_string(), &b.decoy_hits_hard.to_string()));
        lines.push(row("tiered.decoyHits.knownLimitation",
            &a.decoy_hits_known_limitation.to_string(), &b.decoy_hits_known_limitation.to_string()));
    }

    lines.push(sep);

    // Verdict line.
    if diffs.is_empty() {
        lines.push(format!(
            "[replay] verdict: DETERMINISTIC ({total_runs} runs, seed {seed})"
        ));
    } else {
        lines.push(format!(
            "[replay] verdict: DRIFT — {} field(s) differ across runs",
            diffs.len()
        ));
    }
    lines.push(String::new());

    // The trailing empty element gives the joined string its final newline;
    // the writer emits this string verbatim. Twin of the Swift renderer.
    lines.join("\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane capture — types
// ─────────────────────────────────────────────────────────────────────────────

/// Score decomposition for one recall hit, parsed from a RecallExplainer
/// `score:` line. Only non-zero components appear in the explainer output;
/// absent components default to 0.0. Field names match the explainer's
/// score tokens verbatim so a product format change fails the fixture test
/// instead of silently capturing zeros.
///
/// Twin of Swift `HitLaneScores` in ReplayLane.swift.
#[derive(Debug, Clone)]
pub struct HitLaneScores {
    pub locus: f64,
    pub bm25: f64,
    pub vector: f64,
    pub dense: f64,
    pub field_fit: f64,
    pub co_occurrence: f64,
    pub temporal: f64,
    pub graph: f64,
    pub preference: f64,
}

/// Per-query lane snapshot for one replay run.
///
/// Twin of Swift `QueryLaneSnapshot` in ReplayLane.swift.
#[derive(Debug, Clone)]
pub struct QueryLaneSnapshot {
    pub query_id: String,
    /// ISO8601 wall-clock timestamp when the query was issued.
    pub query_timestamp: String,
    /// One entry per selected hit in result order (top-1 first).
    pub hit_scores: Vec<HitLaneScores>,
}

/// Per-run collection of per-query lane snapshots. Created by
/// `run_supersession_lane` when `config.lane_capture` is true.
///
/// `import_timestamp` records when the encode queue converged for this run.
/// Comparing `import_timestamp` values across runs identifies whether drifting
/// lane magnitudes correlate with clock differences.
///
/// Twin of Swift `LaneCapture` in ReplayLane.swift.
#[derive(Debug, Clone)]
pub struct LaneCapture {
    /// ISO8601 wall-clock when the estate's encode queue converged.
    pub import_timestamp: String,
    pub snapshots: Vec<QueryLaneSnapshot>,
}

/// Per-lane drift summary comparing two captures. Produced by
/// `diff_lane_captures(baseline, candidate)`.
///
/// `delta_abs` is `|baseline_mean - candidate_mean|`. Lanes are sorted by
/// `delta_abs` descending in the result of `diff_lane_captures`.
///
/// Twin of Swift `LaneDiff` in ReplayLane.swift.
#[derive(Debug, Clone)]
pub struct LaneDiff {
    pub lane_name: String,
    pub baseline_mean: f64,
    pub candidate_mean: f64,
    /// `|baseline_mean - candidate_mean|`.
    pub delta_abs: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane capture — parsing
// ─────────────────────────────────────────────────────────────────────────────

/// Parses RecallExplainer output from the text blocks of one recall call.
///
/// The explainer emits 4 lines per selected hit, directly after the UUID
/// result line (RecallExplainer.swift:8-11). This function finds each UUID
/// line, then scans the next 4 lines for a `score: <tokens>` line, and
/// extracts per-lane values from the token list. Returns a snapshot with an
/// empty `hit_scores` if no explain lines are found.
///
/// Twin of Swift `parseLaneCaptureLines` in ReplayLane.swift.
pub fn parse_lane_capture_lines(
    text_blocks: &[String],
    query_id: &str,
    timestamp: &str,
) -> QueryLaneSnapshot {
    let text = text_blocks.join("\n");
    let lines: Vec<&str> = text.lines().collect();
    let mut hit_scores: Vec<HitLaneScores> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].trim();
        if is_uuid_prefixed_line(line) {
            // Look for `score:` in the next 1-4 lines (explainer order:
            // sources, score, mode, why — score is always line 2).
            let limit = (i + 5).min(lines.len());
            for j in (i + 1)..limit {
                let next = lines[j].trim();
                if let Some(tokens) = next.strip_prefix("score: ") {
                    hit_scores.push(parse_score_tokens(tokens));
                    break;
                }
            }
        }
        i += 1;
    }
    QueryLaneSnapshot {
        query_id: query_id.to_string(),
        query_timestamp: timestamp.to_string(),
        hit_scores,
    }
}

/// Returns true when `line` begins with a canonical UUID token (8-4-4-4-12 hex).
fn is_uuid_prefixed_line(line: &str) -> bool {
    // UUID is always 36 chars. Take the prefix up to the first space or the
    // full line if shorter, then try to parse it.
    if line.len() < 36 {
        return false;
    }
    let candidate = &line[..36];
    // Validate UUID format: groups are 8-4-4-4-12, separated by '-'.
    let parts: Vec<&str> = candidate.splitn(5, '-').collect();
    if parts.len() != 5 {
        return false;
    }
    let expected_lengths = [8usize, 4, 4, 4, 12];
    parts.iter().zip(expected_lengths.iter()).all(|(p, &len)| {
        p.len() == len && p.chars().all(|c| c.is_ascii_hexdigit())
    })
}

/// Parses a `score:` token string into `HitLaneScores`.
///
/// Input is the portion after `score: `, e.g. `"locus=0.82 bm25=0.71"` or
/// `"final=0.55"` (the fallback when all component scores are zero).
/// Unrecognised tokens are silently ignored for forward compatibility.
///
/// Twin of Swift `parseScoreTokens` in ReplayLane.swift.
pub fn parse_score_tokens(tokens: &str) -> HitLaneScores {
    let mut locus = 0.0_f64;
    let mut bm25 = 0.0_f64;
    let mut vector = 0.0_f64;
    let mut dense = 0.0_f64;
    let mut field_fit = 0.0_f64;
    let mut co_occurrence = 0.0_f64;
    let mut temporal = 0.0_f64;
    let mut graph = 0.0_f64;
    let mut preference = 0.0_f64;

    for token in tokens.split_whitespace() {
        let mut parts = token.splitn(2, '=');
        let (Some(key), Some(val)) = (parts.next(), parts.next()) else { continue };
        let Ok(v) = val.parse::<f64>() else { continue };
        match key {
            "locus"        => locus        = v,
            "bm25"         => bm25         = v,
            "vector"       => vector       = v,
            "dense"        => dense        = v,
            "fieldFit"     => field_fit    = v,
            "coOccurrence" => co_occurrence = v,
            "temporal"     => temporal     = v,
            "graph"        => graph        = v,
            "preference"   => preference   = v,
            _              => {} // forward-compatible: ignore new tokens
        }
    }

    HitLaneScores { locus, bm25, vector, dense, field_fit, co_occurrence, temporal, graph, preference }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane diff
// ─────────────────────────────────────────────────────────────────────────────

/// Computes per-lane mean scores for each capture and returns a `LaneDiff`
/// per lane, sorted by `delta_abs` descending (highest-drift lane first).
///
/// Twin of Swift `diffLaneCaptures` in ReplayLane.swift.
pub fn diff_lane_captures(baseline: &LaneCapture, candidate: &LaneCapture) -> Vec<LaneDiff> {
    fn means(cap: &LaneCapture) -> HitLaneScores {
        let mut l = 0.0_f64; let mut b = 0.0_f64; let mut v = 0.0_f64;
        let mut d = 0.0_f64; let mut ff = 0.0_f64; let mut co = 0.0_f64;
        let mut t = 0.0_f64; let mut g = 0.0_f64; let mut p = 0.0_f64;
        let mut n = 0usize;
        for snap in &cap.snapshots {
            for h in &snap.hit_scores {
                l += h.locus;  b += h.bm25;          v += h.vector;
                d += h.dense;  ff += h.field_fit;     co += h.co_occurrence;
                t += h.temporal; g += h.graph;         p += h.preference;
                n += 1;
            }
        }
        let c = if n > 0 { n as f64 } else { 1.0 };
        HitLaneScores {
            locus: l/c, bm25: b/c, vector: v/c, dense: d/c,
            field_fit: ff/c, co_occurrence: co/c,
            temporal: t/c, graph: g/c, preference: p/c,
        }
    }

    let bm = means(baseline);
    let cm = means(candidate);

    let lanes: &[(&str, f64, f64)] = &[
        ("locus",        bm.locus,         cm.locus),
        ("bm25",         bm.bm25,          cm.bm25),
        ("vector",       bm.vector,        cm.vector),
        ("dense",        bm.dense,         cm.dense),
        ("fieldFit",     bm.field_fit,     cm.field_fit),
        ("coOccurrence", bm.co_occurrence, cm.co_occurrence),
        ("temporal",     bm.temporal,      cm.temporal),
        ("graph",        bm.graph,         cm.graph),
        ("preference",   bm.preference,    cm.preference),
    ];

    let mut diffs: Vec<LaneDiff> = lanes.iter().map(|&(name, b, c)| {
        LaneDiff {
            lane_name: name.to_string(),
            baseline_mean: b,
            candidate_mean: c,
            delta_abs: (b - c).abs(),
        }
    }).collect();
    diffs.sort_by(|a, b| b.delta_abs.partial_cmp(&a.delta_abs).unwrap_or(std::cmp::Ordering::Equal));
    diffs
}

/// Renders a per-lane mean-score diff table comparing two captures.
///
/// All lanes are shown (including zero-delta lanes) so the report proves
/// exactly what was checked, not only what changed.
///
/// Twin of Swift `renderLaneDiffTable` in ReplayLane.swift.
pub fn render_lane_diff_table(
    baseline: &LaneCapture,
    candidate: &LaneCapture,
    diffs: &[LaneDiff],
    label1: &str,
    label2: &str,
) -> String {
    const COL0: usize = 16; // lane name
    const COL1: usize = 12; // baseline mean
    const COL2: usize = 12; // candidate mean
    const COL3: usize = 12; // |delta|

    fn pad(s: &str, width: usize) -> String {
        if s.len() >= width { s.to_string() } else { format!("{}{}", s, " ".repeat(width - s.len())) }
    }

    let header = format!("{}  {}  {}  {}  verdict",
        pad("lane", COL0), pad(label1, COL1), pad(label2, COL2), pad("|delta|", COL3));
    let sep = "-".repeat(COL0 + COL1 + COL2 + COL3 + 22);

    let mut lines = vec![
        "import timestamps:".to_string(),
        format!("  {}: {}", label1, baseline.import_timestamp),
        format!("  {}: {}", label2, candidate.import_timestamp),
        String::new(),
        header,
        sep.clone(),
    ];

    for d in diffs {
        let verdict = if d.delta_abs > 0.0 { "DRIFT" } else { "match" };
        lines.push(format!("{}  {}  {}  {}  {}",
            pad(&d.lane_name, COL0),
            pad(&format!("{:.6}", d.baseline_mean), COL1),
            pad(&format!("{:.6}", d.candidate_mean), COL2),
            pad(&format!("{:.6}", d.delta_abs), COL3),
            verdict));
    }

    lines.push(sep);
    lines.push(String::new());
    lines.join("\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────
//
// Pure logic only: fingerprint construction, field comparison, section-presence
// drift, and the exact-equality contract for timing-excluded fields. No binary,
// no estate, no network. Twin of `ReplayLaneTests.swift`.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::supersession_runner::{
        DecoyHitCounts, SupersessionContradictionOutcome, SupersessionLaneOutcome,
        SupersessionScores, StructuredTierOutcome, TieredScoringOutcome,
    };

    // ── Helpers ───────────────────────────────────────────────────────────

    fn make_scores(
        query_count: usize,
        current_win_rate: f64,
        current_found_rate: f64,
        mean_stale_in_top_k: f64,
        mean_current_rank: f64,
        p50_latency_seconds: f64, // timing field — must NOT appear in fingerprint
    ) -> SupersessionScores {
        SupersessionScores {
            query_count,
            current_win_rate,
            current_found_rate,
            mean_stale_in_top_k,
            mean_current_rank,
            p50_latency_seconds,
        }
    }

    fn base_scores() -> SupersessionScores {
        make_scores(40, 0.975, 1.0, 0.05, 1.2, 0.045)
    }

    fn base_outcome() -> SupersessionLaneOutcome {
        SupersessionLaneOutcome {
            query_results: vec![],
            contradiction: None,
            structured: None,
            tiered: None,
            lane_capture: None,
        }
    }

    fn outcome_with_contradiction(
        planted_count: usize,
        detected_any_tier: usize,
        detected_proposed: usize,
        flagged_outside_planted: usize,
        hunt_seconds: f64, // timing — excluded from fingerprint
    ) -> SupersessionLaneOutcome {
        SupersessionLaneOutcome {
            query_results: vec![],
            contradiction: Some(SupersessionContradictionOutcome {
                planted_count,
                detected_any_tier,
                detected_proposed,
                flagged_outside_planted,
                hunt_seconds,
            }),
            structured: None,
            tiered: None,
            lane_capture: None,
        }
    }

    fn outcome_with_structured_tier(
        planted_count: usize,
        proven_planted: usize,
        tier_seconds: f64, // timing — excluded from fingerprint
    ) -> SupersessionLaneOutcome {
        // proven_reported is a FIXED value (9) independent of proven_planted.
        // If it were set to proven_planted, test 5 would find 2 diffs instead
        // of 1 when proven_planted changes, hiding the fact that exactly one
        // field was perturbed. Mirror of the Swift helper's default.
        let proven_reported = 9usize;
        SupersessionLaneOutcome {
            query_results: vec![],
            contradiction: None,
            structured: Some(StructuredTierOutcome {
                planted_count,
                proven_planted,
                proven_outside_planted: 0,
                proven_reported,
                historical_reported: 30,
                coverage_projected: 45,
                coverage_scanned: 45,
                tier_seconds,
            }),
            tiered: None,
            lane_capture: None,
        }
    }

    /// Builds a `SupersessionLaneOutcome` with a tiered scoring outcome.
    ///
    /// `purpose_seconds` is accepted so callers can verify timing fields do
    /// NOT appear in the fingerprint: two outcomes differing only in timing
    /// must produce equal fingerprints. Mirror of the Swift helper.
    fn outcome_with_tiered(
        tier2_detected: usize,
        tier2_planted_count: usize,
        purpose_seconds: f64, // timing — excluded from fingerprint
    ) -> SupersessionLaneOutcome {
        SupersessionLaneOutcome {
            query_results: vec![],
            contradiction: None,
            structured: None,
            tiered: Some(TieredScoringOutcome {
                tier2_planted_count,
                tier2_detected,
                tier2_purpose_seconds: purpose_seconds,
                tier3_planted_count: 5,
                tier3_detected: 4,
                tier3_purpose_seconds: purpose_seconds,
                tier1_planted_count: None,
                tier1_detected: None,
                tier1_purpose_seconds: None,
                decoy_hits: DecoyHitCounts { hard: 0, known_limitation: 0 },
                tier_inflation: 0,
                lane_seconds: vec![],
                synthesis_wall_seconds: None,
            }),
            lane_capture: None,
        }
    }

    // ── Test 1: identical fingerprints → empty diff ───────────────────────

    #[test]
    fn identical_fingerprints_produce_empty_diff() {
        let scores  = base_scores();
        let outcome = base_outcome();
        let fp = ReplayFingerprint::new(&scores, &outcome);
        // Comparing a fingerprint against itself must yield no diffs.
        let diffs = compare_replay_fingerprints(&fp, &fp);
        assert!(
            diffs.is_empty(),
            "identical fingerprints must produce an empty diff list; got: {:?}",
            diffs.iter().map(|d| &d.field_name).collect::<Vec<_>>()
        );
    }

    // ── Test 2: timing fields excluded from fingerprint ───────────────────

    #[test]
    fn timing_fields_excluded_from_fingerprint() {
        // Two scores identical in every deterministic field, differing only in
        // the wall-clock p50_latency_seconds. A slow run on loaded hardware
        // must not trigger a false DRIFT.
        let slow = make_scores(40, 0.975, 1.0, 0.05, 1.2, 0.500);
        let fast = make_scores(40, 0.975, 1.0, 0.05, 1.2, 0.010);
        let outcome = base_outcome();
        let fp_slow = ReplayFingerprint::new(&slow, &outcome);
        let fp_fast = ReplayFingerprint::new(&fast, &outcome);
        let diffs = compare_replay_fingerprints(&fp_slow, &fp_fast);
        assert!(
            diffs.is_empty(),
            "timing-only difference must not appear as a diff; got: {:?}",
            diffs.iter().map(|d| &d.field_name).collect::<Vec<_>>()
        );
        // PartialEq also holds.
        assert_eq!(fp_slow, fp_fast, "fingerprints differing only in timing must be equal");
    }

    // ── Test 3: single field perturbed → exactly that field reported ──────

    #[test]
    fn single_field_perturbed_reports_exactly_that_field() {
        let base = make_scores(40, 0.900, 1.0, 0.05, 1.2, 0.045);
        let pert = make_scores(40, 0.875, 1.0, 0.05, 1.2, 0.045); // currentWinRate differs
        let outcome = base_outcome();
        let fp_base = ReplayFingerprint::new(&base, &outcome);
        let fp_pert = ReplayFingerprint::new(&pert, &outcome);
        let diffs = compare_replay_fingerprints(&fp_base, &fp_pert);
        assert_eq!(
            diffs.len(), 1,
            "exactly one field must differ; got {}: {:?}",
            diffs.len(), diffs.iter().map(|d| &d.field_name).collect::<Vec<_>>()
        );
        assert_eq!(
            diffs[0].field_name, "currentWinRate",
            "the reported field must be 'currentWinRate'"
        );
    }

    // ── Test 4: contradiction section presence/absence is drift ───────────

    #[test]
    fn contradiction_section_presence_is_drift() {
        let scores = base_scores();
        let with_c    = outcome_with_contradiction(10, 8, 7, 3, 1.2);
        let without_c = base_outcome();
        let fp_with    = ReplayFingerprint::new(&scores, &with_c);
        let fp_without = ReplayFingerprint::new(&scores, &without_c);
        // Baseline has contradiction, candidate does not: section-presence DRIFT.
        let diffs = compare_replay_fingerprints(&fp_with, &fp_without);
        let names: Vec<&str> = diffs.iter().map(|d| d.field_name.as_str()).collect();
        assert!(
            names.contains(&"contradiction.present"),
            "section-presence diff must appear; got: {names:?}"
        );
        let pres = diffs.iter().find(|d| d.field_name == "contradiction.present").unwrap();
        assert_eq!(pres.baseline_value, "true");
        assert_eq!(pres.candidate_value, "false");
    }

    // ── Test 5: structured-tier field perturbed → reported ────────────────

    #[test]
    fn structured_tier_field_perturbed_is_reported() {
        let scores  = base_scores();
        let outcome_a = outcome_with_structured_tier(10, 9, 2.5);  // provenPlanted = 9
        let outcome_b = outcome_with_structured_tier(10, 8, 2.5);  // provenPlanted = 8
        let fp_a = ReplayFingerprint::new(&scores, &outcome_a);
        let fp_b = ReplayFingerprint::new(&scores, &outcome_b);
        let diffs = compare_replay_fingerprints(&fp_a, &fp_b);
        let names: Vec<&str> = diffs.iter().map(|d| d.field_name.as_str()).collect();
        assert!(
            names.contains(&"structuredTier.provenPlanted"),
            "structuredTier.provenPlanted must appear in diffs; got: {names:?}"
        );
        // Only provenPlanted changed; tierSeconds is excluded.
        assert_eq!(
            diffs.len(), 1,
            "exactly one field must differ; got {}: {names:?}", diffs.len()
        );
    }

    // ── Test 6: the table renderer produces the full report ───────────────
    // Covers the formatting path the pure comparison tests cannot reach —
    // the Swift twin's first live shakedown segfaulted in its (then
    // untested) formatting path while the comparison tests stayed green.
    // Twin of Swift `rendererEmitsFullTable`.
    #[test]
    fn renderer_emits_full_table() {
        let scores = base_scores();
        let outcome_a = outcome_with_structured_tier(10, 9, 2.5);
        let outcome_b = outcome_with_structured_tier(10, 8, 2.5);
        let fp_a = ReplayFingerprint::new(&scores, &outcome_a);
        let fp_b = ReplayFingerprint::new(&scores, &outcome_b);
        let diffs = compare_replay_fingerprints(&fp_a, &fp_b);

        let drift = render_replay_field_table(&fp_a, &fp_b, &diffs, 2, 20260725, 2);
        assert!(drift.contains("field"), "header row must render");
        assert!(drift.contains("queryCount"), "score rows must render");
        assert!(
            drift.contains("structuredTier.provenPlanted"),
            "structured-tier rows must render when both sides carry the section"
        );
        assert!(drift.contains("DRIFT"), "the perturbed field must show DRIFT");
        assert!(drift.contains("MATCH"), "matching fields must still be listed");
        assert!(drift.contains("[replay] verdict: DRIFT — 1 field(s) differ across runs"));

        let clean = render_replay_field_table(&fp_a, &fp_a, &[], 2, 20260725, 2);
        assert!(clean.contains("[replay] verdict: DETERMINISTIC (2 runs, seed 20260725)"));
        assert!(
            !clean.contains("DRIFT"),
            "an all-MATCH table must carry no DRIFT verdicts"
        );
    }

    // ── Test 7: tiered section presence/absence is drift ─────────────────
    // Twin of Swift `tieredSectionPresenceIsDrift`.
    #[test]
    fn tiered_section_presence_is_drift() {
        let scores = base_scores();
        let with_t    = outcome_with_tiered(8, 10, 1.5);
        let without_t = base_outcome();
        let fp_with    = ReplayFingerprint::new(&scores, &with_t);
        let fp_without = ReplayFingerprint::new(&scores, &without_t);
        // Baseline has tiered section, candidate does not: section-presence DRIFT.
        let diffs = compare_replay_fingerprints(&fp_with, &fp_without);
        let names: Vec<&str> = diffs.iter().map(|d| d.field_name.as_str()).collect();
        assert!(
            names.contains(&"tiered.present"),
            "section-presence diff must appear when tiered runs in one fingerprint only; got: {names:?}"
        );
        let pres = diffs.iter().find(|d| d.field_name == "tiered.present").unwrap();
        assert_eq!(pres.baseline_value, "true");
        assert_eq!(pres.candidate_value, "false");
    }

    // ── Test 8: a tiered count field perturbed → reported ─────────────────
    // Twin of Swift `tieredCountFieldPerturbedIsReported`.
    #[test]
    fn tiered_count_field_perturbed_is_reported() {
        let scores    = base_scores();
        let outcome_a = outcome_with_tiered(8, 10, 1.5); // tier2_detected = 8
        let outcome_b = outcome_with_tiered(7, 10, 1.5); // tier2_detected = 7
        let fp_a = ReplayFingerprint::new(&scores, &outcome_a);
        let fp_b = ReplayFingerprint::new(&scores, &outcome_b);
        let diffs = compare_replay_fingerprints(&fp_a, &fp_b);
        let names: Vec<&str> = diffs.iter().map(|d| d.field_name.as_str()).collect();
        assert!(
            names.contains(&"tiered.tier2Detected"),
            "tiered.tier2Detected must appear in diffs; got: {names:?}"
        );
        // Only tier2_detected changed; timing fields are excluded, so exactly
        // one diff must be reported.
        assert_eq!(
            diffs.len(), 1,
            "exactly one tiered field must differ; got {}: {names:?}", diffs.len()
        );
    }

    // ── Lane capture tests ────────────────────────────────────────────────

    /// Format-pinning fixture: verbatim RecallExplainer output (2 hits) must
    /// parse to the expected HitLaneScores values.
    ///
    /// If the product's RecallExplainer format changes, this test fails loudly
    /// instead of silently capturing zeros. Twin of Swift
    /// `parseLaneCaptureLinesParsesScoreLines`.
    #[test]
    fn parse_lane_capture_lines_parses_score_lines() {
        let text = vec![
            "3f6a1b2c-4d5e-6f7a-8b9c-0d1e2f3a4b5c some title about cats".to_string(),
            "sources: locus".to_string(),
            "score: locus=0.82 bm25=0.71 vector=0.65 temporal=0.30".to_string(),
            "mode: hybrid".to_string(),
            "why: matched on keywords".to_string(),
            "a1b2c3d4-e5f6-7890-abcd-ef1234567890 another memory entry".to_string(),
            "sources: bm25, vector".to_string(),
            "score: bm25=0.55 vector=0.48 coOccurrence=0.20".to_string(),
            "mode: hybrid".to_string(),
            "why: co-occurrence boost applied".to_string(),
        ];

        let snap = parse_lane_capture_lines(&text, "q-001", "2026-08-09T10:00:00Z");
        assert_eq!(snap.query_id, "q-001");
        assert_eq!(snap.hit_scores.len(), 2);

        let h0 = &snap.hit_scores[0];
        assert!((h0.locus - 0.82).abs() < 1e-9, "hit0 locus");
        assert!((h0.bm25  - 0.71).abs() < 1e-9, "hit0 bm25");
        assert!((h0.vector - 0.65).abs() < 1e-9, "hit0 vector");
        assert!((h0.temporal - 0.30).abs() < 1e-9, "hit0 temporal");
        assert_eq!(h0.dense, 0.0, "hit0 dense absent");
        assert_eq!(h0.field_fit, 0.0, "hit0 fieldFit absent");
        assert_eq!(h0.co_occurrence, 0.0, "hit0 coOccurrence absent");

        let h1 = &snap.hit_scores[1];
        assert!((h1.bm25   - 0.55).abs() < 1e-9, "hit1 bm25");
        assert!((h1.vector - 0.48).abs() < 1e-9, "hit1 vector");
        assert!((h1.co_occurrence - 0.20).abs() < 1e-9, "hit1 coOccurrence");
        assert_eq!(h1.locus, 0.0, "hit1 locus absent");
    }

    /// All nine lane names parse correctly from a single score line.
    /// Twin of Swift `parseScoreTokensParsesAllNineLanes`.
    #[test]
    fn parse_score_tokens_parses_all_nine_lanes() {
        let tokens = "locus=0.1 bm25=0.2 vector=0.3 dense=0.4 fieldFit=0.5 coOccurrence=0.6 temporal=0.7 graph=0.8 preference=0.9";
        let h = parse_score_tokens(tokens);
        assert!((h.locus         - 0.1).abs() < 1e-9);
        assert!((h.bm25          - 0.2).abs() < 1e-9);
        assert!((h.vector        - 0.3).abs() < 1e-9);
        assert!((h.dense         - 0.4).abs() < 1e-9);
        assert!((h.field_fit     - 0.5).abs() < 1e-9);
        assert!((h.co_occurrence - 0.6).abs() < 1e-9);
        assert!((h.temporal      - 0.7).abs() < 1e-9);
        assert!((h.graph         - 0.8).abs() < 1e-9);
        assert!((h.preference    - 0.9).abs() < 1e-9);
    }

    /// Unknown tokens (e.g. `final=X`) are silently ignored.
    /// Twin of Swift `parseScoreTokensIgnoresUnknownTokens`.
    #[test]
    fn parse_score_tokens_ignores_unknown_tokens() {
        let h = parse_score_tokens("final=0.55 future_token=9.9");
        // All known lanes stay 0.0; no panic from unknown tokens.
        assert_eq!(h.locus, 0.0);
        assert_eq!(h.bm25,  0.0);
        assert_eq!(h.vector, 0.0);
    }

    /// Empty text → empty hit_scores (explain not active or no results).
    /// Twin of Swift `parseLaneCaptureEmptyTextProducesEmptySnapshot`.
    #[test]
    fn parse_lane_capture_empty_text_produces_empty_snapshot() {
        let snap = parse_lane_capture_lines(&[], "q-empty", "2026-08-09T00:00:00Z");
        assert!(snap.hit_scores.is_empty());
    }

    fn make_capture(locus: f64, bm25: f64) -> LaneCapture {
        LaneCapture {
            import_timestamp: "2026-08-09T10:00:00Z".to_string(),
            snapshots: vec![QueryLaneSnapshot {
                query_id: "q1".to_string(),
                query_timestamp: "2026-08-09T10:00:01Z".to_string(),
                hit_scores: vec![
                    HitLaneScores { locus, bm25, vector: 0.0, dense: 0.0,
                        field_fit: 0.0, co_occurrence: 0.0, temporal: 0.0,
                        graph: 0.0, preference: 0.0 },
                ],
            }],
        }
    }

    /// Identical captures → all delta_abs == 0.
    /// Twin of Swift `diffLaneCapturesIdenticalProducesZero`.
    #[test]
    fn diff_lane_captures_identical_produces_zero() {
        let cap = make_capture(0.80, 0.70);
        let diffs = diff_lane_captures(&cap, &cap);
        for d in &diffs {
            assert_eq!(d.delta_abs, 0.0, "lane {} should have zero delta", d.lane_name);
        }
    }

    /// A single perturbed lane (bm25) appears at the top of the sorted diff.
    /// Twin of Swift `diffLaneCapturesSinglePerturbedLaneReported`.
    #[test]
    fn diff_lane_captures_single_perturbed_lane_reported() {
        let baseline  = make_capture(0.80, 0.70);
        let candidate = make_capture(0.80, 0.55); // bm25 perturbed
        let diffs = diff_lane_captures(&baseline, &candidate);
        assert!(!diffs.is_empty());
        assert_eq!(diffs[0].lane_name, "bm25", "bm25 must be top drift lane");
        assert!((diffs[0].delta_abs - 0.15).abs() < 1e-9);
    }

    /// `render_lane_diff_table` output is deterministic (two calls on the same
    /// data produce the same string). Twin of Swift
    /// `renderLaneDiffTableProducesDeterministicTable`.
    #[test]
    fn render_lane_diff_table_produces_deterministic_table() {
        let baseline  = make_capture(0.80, 0.70);
        let candidate = make_capture(0.80, 0.55);
        let diffs = diff_lane_captures(&baseline, &candidate);
        let table1 = render_lane_diff_table(&baseline, &candidate, &diffs, "run 1", "run 2");
        let table2 = render_lane_diff_table(&baseline, &candidate, &diffs, "run 1", "run 2");
        assert_eq!(table1, table2, "two renders must be bit-identical");
        assert!(table1.contains("bm25"), "bm25 must appear in table");
        assert!(table1.contains("DRIFT"), "DRIFT verdict must appear");
    }
}
