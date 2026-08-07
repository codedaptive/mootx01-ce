//! SessionHybridFusion — post-processing boosts for the "session_hybrid" named
//! RecallShape preset. Rust parity of the Swift
//! `CognitionKit/SessionHybridFusion.swift`.
//!
//! Applied by `shaped_recall::run()` AFTER the GLK shaped recall returns its
//! ranked hit list, before the final limit-and-project step.
//!
//! Two composable boost mechanisms:
//!
//!   1. TEMPORAL WINDOW BOOST — amplifies drawers whose `event_time` falls
//!      within the session window expressed by `CreatedAfter`/`CreatedBefore`
//!      in the filter chain. Active only when at least one temporal bound is
//!      present; a no-op otherwise.
//!
//!   2. SPEAKER-AWARE BOOST — amplifies drawers authored by the MCP server
//!      (`drawer.channel() == Channel::McpAgent`) when the query references the
//!      assistant's own prior statements. Active only when self-reference query
//!      patterns are detected.
//!
//! EVIDENCE GATE INVARIANT:
//! The boosts are applied as a SECONDARY sort key over the primary rank order.
//! Max combined boost = 0.006 (temporal_boost_max + speaker_boost_max). For the
//! invariant to hold, frame-only hits must sit at rank >= 36, where their boosted
//! score (1/(36+61) + 0.006 ≈ 0.0163) stays below a rank-0 hit (1/61 ≈ 0.0164).
//! Session-hybrid callers should ensure a gap of at least 36 evidence-bearing
//! hits ahead of any frame-only hit to preserve this guarantee.
//!
//! DETERMINISM:
//! All inputs are caller-supplied (drawer fields and absolute filter bounds).
//! No system-clock calls inside the math. Identical inputs → identical output.

use locus_kit::drawer::Drawer;
use locus_kit::filter::Filter;
use locus_kit::provenance::Channel;

// MARK: - Configuration constants

/// Maximum score delta a temporal window boost can contribute. Capped so the
/// boost acts as a tie-breaker between near-equal ranked drawers, never as a
/// primary re-orderer. Combined max with `SPEAKER_BOOST_MAX` is 0.006, below
/// the cross-group evidence gap at rank >= 36 (see module-level doc).
const TEMPORAL_BOOST_MAX: f64 = 0.003;

/// Maximum score delta a speaker-aware boost can contribute. Same bound as
/// `TEMPORAL_BOOST_MAX`; the two boosts are additive (max combined 0.006).
const SPEAKER_BOOST_MAX: f64 = 0.003;

/// RRF damping constant — mirrors NeuronKit's HybridRecallEngine k=60 convention.
/// Base score at rank N = 1.0 / (N as f64 + RRF_K + 1.0).
const RRF_K: f64 = 60.0;

// MARK: - Temporal window extraction

/// Extract a (start, end) session window from the filter chain (millisecond i64).
///
/// Returns `None` when the filter chain contains no temporal bounds — the temporal
/// boost mechanism is inactive for this call. Only `CreatedAfter` and
/// `CreatedBefore` contribute; all other filter cases are ignored. The window is
/// half-open: [start, end) with `None` meaning "no bound" on either side.
pub fn extract_temporal_window(filter: &Filter) -> Option<(Option<i64>, Option<i64>)> {
    let mut start: Option<i64> = None;
    let mut end: Option<i64> = None;
    extract_bounds(filter, &mut start, &mut end);
    // Return None if neither bound found — boost mechanism is inactive.
    if start.is_none() && end.is_none() {
        return None;
    }
    Some((start, end))
}

/// Recursive helper that walks the filter tree collecting temporal bounds.
fn extract_bounds(filter: &Filter, start: &mut Option<i64>, end: &mut Option<i64>) {
    match filter {
        Filter::CreatedAfter(date_ms) => {
            // Take the latest lower bound when multiple CreatedAfter appear.
            *start = Some(match *start {
                Some(existing) if *date_ms <= existing => existing,
                _ => *date_ms,
            });
        }
        Filter::CreatedBefore(date_ms) => {
            // Take the earliest upper bound when multiple CreatedBefore appear.
            *end = Some(match *end {
                Some(existing) if *date_ms >= existing => existing,
                _ => *date_ms,
            });
        }
        Filter::All(children) => {
            for child in children {
                extract_bounds(child, start, end);
            }
        }
        Filter::Any(children) => {
            // In an OR chain, take the broadest window — the union of bounds.
            for child in children {
                extract_bounds(child, start, end);
            }
        }
        Filter::Not(_) => {
            // NOT inverts the meaning; skip temporal extraction inside NOT.
        }
        _ => {}
    }
}

// MARK: - Self-reference query detection

/// Detect whether `query` references the assistant's own prior statements.
///
/// Conservative: only the clearest English self-reference patterns trigger the
/// speaker-aware boost. Misses are acceptable (the boost is not required to be
/// comprehensive); false positives are the bigger concern since they would boost
/// MCP-authored content for unrelated queries. Pattern set is deterministic and
/// locale-fixed (English only).
pub fn is_self_reference_query(query: &str) -> bool {
    let lower = query.to_lowercase();
    // Explicit second-person assistant reference patterns — same list as Swift.
    let patterns: &[&str] = &[
        "what did you say",
        "you said",
        "you mentioned",
        "you told me",
        "you wrote",
        "you noted",
        "your response",
        "your answer",
        "your earlier",
        "your previous",
        "you earlier",
        "you previously",
        "you just",
        "what you said",
        "what you wrote",
        "as you said",
        "as you mentioned",
    ];
    patterns.iter().any(|p| lower.contains(p))
}

// MARK: - Boost application

/// Apply temporal and speaker boosts as a secondary sort key over the ranked
/// drawer list.
///
/// The primary sort key is the rank index in `drawers` (lower index = higher
/// relevance from hybridRecall or shaped recall). The secondary key is the sum
/// of temporal + speaker boost deltas, each in [0, boost_max]. Boosted score =
/// `base_score + boost_delta` where `base_score = 1.0 / (rank as f64 + RRF_K + 1)`.
/// Re-sort is stable: equal boosted scores preserve input order.
///
/// - `drawers`: ranked list from the shaped recall, in evidence-first order.
/// - `filter`: the caller's filter, used to extract the temporal window.
/// - `query`: the raw query string, used for self-reference detection.
/// - `limit`: result cap.
///
/// Returns up to `limit` (drawer, score) pairs in boosted rank order.
pub fn boost(
    drawers: Vec<Drawer>,
    filter: &Filter,
    query: &str,
    limit: usize,
) -> Vec<(Drawer, f64)> {
    if drawers.is_empty() {
        return Vec::new();
    }

    // Extract temporal window from the filter chain. None means inactive.
    let temporal_window = extract_temporal_window(filter);

    // Detect self-reference in the query. False means inactive.
    let apply_speaker = is_self_reference_query(query);

    // Build (drawer, boosted_score) pairs.
    let mut scored: Vec<(Drawer, f64)> = drawers
        .into_iter()
        .enumerate()
        .map(|(rank, drawer)| {
            // RRF base score with k=60 damping — same convention as NeuronKit's
            // HybridRecallEngine.
            let base_score = 1.0 / (rank as f64 + RRF_K + 1.0);

            // Temporal boost: full boost if inside window, zero otherwise.
            // Active only when the filter chain contained temporal bounds.
            let mut delta = 0.0;
            if let Some((start, end)) = temporal_window {
                if is_inside_window(drawer.event_time, start, end) {
                    delta += TEMPORAL_BOOST_MAX;
                }
            }

            // Speaker-aware boost: boost MCP-agent-authored drawers when the
            // query references the assistant's prior statements.
            // Channel::McpAgent is stamped at capture time for MCP server rows
            // (bits 6–11 of the provenance bitmap per provenance.rs).
            if apply_speaker && drawer.channel() == Channel::McpAgent {
                delta += SPEAKER_BOOST_MAX;
            }

            (drawer, base_score + delta)
        })
        .collect();

    // Stable sort by boosted score descending. The primary ordering (input rank)
    // is preserved for equal scores because sort_by is stable in Rust.
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    // Return up to limit results.
    scored.truncate(limit);
    scored
}

// MARK: - Helpers

/// Returns true when `date_ms` falls within the half-open session window [start, end).
///
/// - `start == None`: no lower bound (open from the beginning of time).
/// - `end == None`: no upper bound (open to the future).
///
/// Boundary semantics: >= start (inclusive), < end (exclusive). Mirrors Swift's
/// `isInsideWindow(_:start:end:)` conventions.
fn is_inside_window(date_ms: i64, start: Option<i64>, end: Option<i64>) -> bool {
    if let Some(s) = start {
        if date_ms < s {
            return false;
        }
    }
    if let Some(e) = end {
        if date_ms >= e {
            return false;
        }
    }
    true
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use locus_kit::drawer::Drawer;
    use locus_kit::provenance::Channel;

    // Millisecond epoch anchor for tests. 1_000_000 * 1000 = 1_000_000_000 ms.
    const NOW_MS: i64 = 1_000_000_000;

    /// Build a minimal Drawer with the given id, event_time, and provenance.
    fn make_drawer(id: &str, event_time_ms: i64, provenance: i64) -> Drawer {
        let mut d = Drawer::new(
            id.to_string(),    // id
            id.to_string(),    // content (unused in boost logic)
            "room-1",          // parent_node_id
            "user",            // added_by
            event_time_ms,     // filed_at (event_time is set = filed_at by default)
            "test-v1",         // embedding_model_id
        );
        d.event_time = event_time_ms;
        d.provenance = provenance;
        d
    }

    // SHF-1: temporal window extraction returns None when no temporal bounds.
    #[test]
    fn shf1_no_temporal_bounds_returns_none() {
        assert!(extract_temporal_window(&Filter::CurrentlyBelieve).is_none());
        assert!(extract_temporal_window(&Filter::Unconfirmed).is_none());
        assert!(extract_temporal_window(&Filter::All(vec![Filter::CurrentlyBelieve])).is_none());
    }

    // SHF-2: temporal window extracted from CreatedAfter / CreatedBefore.
    #[test]
    fn shf2_temporal_bounds_extracted() {
        let filter = Filter::All(vec![
            Filter::CreatedAfter(NOW_MS - 7200_000),
            Filter::CreatedBefore(NOW_MS - 600_000),
        ]);
        let window = extract_temporal_window(&filter).unwrap();
        assert_eq!(window.0, Some(NOW_MS - 7200_000));
        assert_eq!(window.1, Some(NOW_MS - 600_000));
    }

    // SHF-3: self-reference query detection — positive cases.
    #[test]
    fn shf3_self_reference_patterns_detected() {
        assert!(is_self_reference_query("what did you say about that"));
        assert!(is_self_reference_query("you mentioned the deadline"));
        assert!(is_self_reference_query("your earlier response was correct"));
        assert!(is_self_reference_query("as you said, the answer is"));
    }

    // SHF-4: self-reference query detection — negative cases.
    #[test]
    fn shf4_non_self_reference_not_detected() {
        assert!(!is_self_reference_query("what is quantum entanglement"));
        assert!(!is_self_reference_query("find sessions about databases"));
        assert!(!is_self_reference_query("recent notes on Swift concurrency"));
    }

    // SHF-5: temporal boost lifts in-window drawer above out-of-window drawer.
    #[test]
    fn shf5_temporal_boost_reorders_near_equal_drawers() {
        let window_start = NOW_MS - 7200_000;
        let window_end = NOW_MS - 600_000;

        // Out-of-window at rank 0 (hybridRecall ranked it first).
        let out = make_drawer("out-window", NOW_MS - 86400_000, 0);
        // In-window at rank 1.
        let in_win = make_drawer("in-window", NOW_MS - 3600_000, 0);

        let filter = Filter::All(vec![
            Filter::CreatedAfter(window_start),
            Filter::CreatedBefore(window_end),
        ]);
        let result = boost(vec![out, in_win], &filter, "session topic", 10);

        assert_eq!(result.len(), 2);
        assert_eq!(result[0].0.id, "in-window",
            "temporal boost must lift in-window drawer above out-of-window drawer");
    }

    // SHF-6: speaker boost lifts McpAgent drawer for self-reference query.
    #[test]
    fn shf6_speaker_boost_lifts_mcp_agent_drawer() {
        // McpAgent channel: rawValue 2, bits 6–11 → provenance = 2 << 6 = 128.
        let mcp_provenance = Channel::McpAgent.raw_value() << 6;

        // User-authored at rank 0, MCP-authored at rank 1.
        let user = make_drawer("user-authored", NOW_MS, 0);
        let mcp = make_drawer("mcp-authored", NOW_MS, mcp_provenance);

        let result = boost(
            vec![user, mcp],
            &Filter::Unconfirmed,
            "what did you say about the deployment",
            10,
        );

        assert_eq!(result[0].0.id, "mcp-authored",
            "speaker boost must lift AI-authored drawer for self-reference query");
    }

    // SHF-7: evidence gate — max boost cannot displace a rank-0 hit when the
    // frame-only hit is at rank >= 36 (invariant threshold, see module doc).
    #[test]
    fn shf7_evidence_gate_holds_at_rank_40() {
        let window_start = NOW_MS - 3700_000;
        let window_end = NOW_MS + 3700_000;
        let mcp_provenance = Channel::McpAgent.raw_value() << 6;

        // Rank 0: evidence-bearing, outside window, user-authored (no boost).
        let evidence = make_drawer("evidence-bearing", NOW_MS - 7200_000, 0);

        // Ranks 1–39: filler hits, all outside window, user-authored (no boost).
        let mut all_drawers = vec![evidence];
        for i in 1..=39_i64 {
            // Offset starts at (i+12)*600s ago → all > 7800s ago, outside window.
            let offset_ms = (i + 12) * 600_000;
            all_drawers.push(make_drawer("filler", NOW_MS - offset_ms, 0));
        }

        // Rank 40: frame-only, inside window, mcpAgent (gets max boost 0.006).
        // At rank 40: base = 1/101 ≈ 0.0099. Boosted = 0.0099 + 0.006 = 0.0159.
        // evidenceHit at rank 0: base = 1/61 ≈ 0.0164. 0.0164 > 0.0159 ✓
        all_drawers.push(make_drawer("frame-only", NOW_MS, mcp_provenance));

        let filter = Filter::All(vec![
            Filter::CreatedAfter(window_start),
            Filter::CreatedBefore(window_end),
        ]);
        let result = boost(
            all_drawers,
            &filter,
            "what did you say about quantum mechanics",
            50,
        );

        assert_eq!(result[0].0.id, "evidence-bearing",
            "evidence gate: rank-0 evidence hit must not be displaced by boosted rank-40 frame-only hit");
    }

    // SHF-8: no boosts — output preserves input order unchanged.
    #[test]
    fn shf8_no_boosts_preserves_order() {
        let drawers = (0..4_i64).map(|i| {
            make_drawer(&format!("d-{i}"), NOW_MS - i * 300_000, 0)
        }).collect::<Vec<_>>();

        // No temporal bounds, no self-reference query.
        let result = boost(drawers, &Filter::Unconfirmed, "find items", 10);

        let ids: Vec<String> = result.into_iter().map(|(d, _)| d.id).collect();
        assert_eq!(ids, vec!["d-0", "d-1", "d-2", "d-3"],
            "no boosts active — SessionHybridFusion must return input order unchanged");
    }

    // SHF-9: determinism — identical inputs produce identical order across two calls.
    #[test]
    fn shf9_deterministic_ranking() {
        let window_start = NOW_MS - 7200_000;
        let make_drawers = || {
            (0..5_i64).map(|i| {
                make_drawer(&format!("d-{i}"), NOW_MS - i * 600_000, 0)
            }).collect::<Vec<_>>()
        };
        let filter = Filter::CreatedAfter(window_start);
        let query = "you mentioned content";

        let ids1: Vec<_> = boost(make_drawers(), &filter, query, 5)
            .into_iter().map(|(d, _)| d.id).collect();
        let ids2: Vec<_> = boost(make_drawers(), &filter, query, 5)
            .into_iter().map(|(d, _)| d.id).collect();
        assert_eq!(ids1, ids2, "SessionHybridFusion must produce identical ranking for identical inputs");
    }
}
