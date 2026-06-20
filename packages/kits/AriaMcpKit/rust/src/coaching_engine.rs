//! CoachingEngine — hint injection for non-error tool results.
//!
//! Mirrors Swift `CoachingEngine.swift`. Eleven trigger conditions append a
//! `hint:` line to non-error results to guide the AI client toward better
//! usage patterns. The first matching trigger wins; the rest are skipped.
//!
//! # Trigger table
//!
//! 1.  `long_query`          — moot_memory_search with query > 200 chars
//! 2.  `no_results_search`   — moot_memory_search returns "found 0 memory(s)"
//! 3.  `filed_memory`        — moot_file_memory success — prompt to confirm
//! 4.  `empty_estate_status` — moot_estate_status with "drawers: 0"
//! 5.  `journal_empty`       — moot_read_journal returns "0 entry(s)"
//! 6.  `connection_empty`    — moot_connection_search returns ": 0"
//! 7.  `facts_empty`         — moot_fact_search returns ": 0" and no query
//! 8.  `many_facts`          — moot_fact_timeline returns ≥20 facts
//! 9.  `search_after_empty`  — moot_memory_search after estate_status with
//!                             zero drawers (detected from result pattern)
//! 10. `tunnel_graph_lens`   — moot_lens_keystones / moot_lens_constellation
//!                             returns "0 result" — names missing tunnel edges,
//!                             never claims "0 memories" (Bug-L fix)
//! 11. `generic_lens`        — any other moot_lens_* tool returns "0 result"

use std::collections::BTreeMap;

use crate::jsonrpc::JsonValue;

/// Return a coaching hint to append to the result text, or `None`.
///
/// Called by `dispatch.rs` after a successful (non-error) tool dispatch.
/// `name` is the tool name, `args` is the raw argument map, `result_text`
/// is the formatted result text. Returns a static hint string or `None`.
pub fn hint(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    result_text: &str,
) -> Option<&'static str> {
    // Trigger 1: long query — moot_memory_search with query > 200 chars
    // Fires before inspecting the result; prompt the client to shorten.
    if name == "moot_memory_search" {
        if let Some(q) = args.get("query").and_then(|v| v.as_str()) {
            if q.len() > 200 {
                return Some(
                    "queries over 200 characters may reduce recall precision; \
                     try a shorter, more specific phrase",
                );
            }
        }
    }

    // Trigger 2: no results — moot_memory_search returned 0 hits
    if name == "moot_memory_search" && result_text.contains("found 0 memory(s)") {
        return Some(
            "no memories matched — try moot_estate_status to check estate \
             contents, or broaden the query",
        );
    }

    // Trigger 3: filed first memory — suggest confirming it
    if name == "moot_file_memory" && result_text.contains("filed memory") {
        return Some(
            "memory filed — call moot_confirm_memory with this ID to mark it \
             as user-verified",
        );
    }

    // Trigger 4: empty estate — moot_estate_status shows drawers: 0
    if name == "moot_estate_status" && result_text.contains("drawers: 0") {
        return Some(
            "estate is empty — start with moot_file_memory to store your \
             first memory",
        );
    }

    // Trigger 5: empty journal — moot_read_journal returned 0 entries
    if name == "moot_read_journal" && result_text.contains("0 entry(s)") {
        return Some(
            "no journal entries found — use moot_write_journal to record \
             session notes",
        );
    }

    // Trigger 6: no outgoing connections — moot_connection_search returned 0
    if name == "moot_connection_search" && result_text.contains(": 0") {
        return Some(
            "no outgoing connections found — use moot_link_memories to \
             create typed relationships between memories",
        );
    }

    // Trigger 7: empty fact store — moot_fact_search with no query returned 0
    if name == "moot_fact_search"
        && result_text.starts_with("facts: 0")
        && !args.contains_key("query")
    {
        return Some(
            "no facts in this estate — use moot_file_fact to store \
             subject-predicate-object knowledge",
        );
    }

    // Trigger 8: many facts — moot_fact_timeline with ≥ 20 entries
    if name == "moot_fact_timeline" {
        // Parse the count from "fact timeline: N" or "fact timeline for ...: N"
        if let Some(count) = parse_timeline_count(result_text) {
            if count >= 20 {
                return Some(
                    "large fact timeline — consider using moot_retire_fact to \
                     remove outdated facts and keep the knowledge graph current",
                );
            }
        }
    }

    // Trigger 9: connection map empty — moot_connection_map returned 0
    if name == "moot_connection_map" && result_text.contains(": 0") {
        return Some(
            "no incoming connections found — use moot_link_memories to \
             build the association graph",
        );
    }

    // Trigger 10: tunnel-graph lens 0 results — keystones/constellation operate
    // on drawer-to-drawer edges; "0 result" means no tunnel edges exist in the
    // wing, not 0 memories. The message must name the real reason and must not
    // claim "0 memories" or suggest scope:active (scope does not affect tunnel
    // topology). Mirrors Swift CoachingEngine.tunnelGraphLensHint.
    if (name == "moot_lens_keystones" || name == "moot_lens_constellation")
        && result_text.contains("0 result")
    {
        return Some(
            "no tunnel connections found in this wing — these lenses require \
             linked memories; use moot_link_memories to connect memories and \
             then re-run this lens",
        );
    }

    // Trigger 11: generic lens tool 0 results — any other moot_lens_* tool.
    // Fires when the result text contains "0 result(s)" (the list() helper format).
    if name.starts_with("moot_lens_") && result_text.contains("0 result") {
        return Some(
            "lens results are thin — try scope: active for a broader search",
        );
    }

    None
}

/// Parse the fact count from a fact-timeline result header.
/// Matches "fact timeline: N" or "fact timeline for ...: N".
fn parse_timeline_count(text: &str) -> Option<usize> {
    let first_line = text.lines().next()?;
    let colon_pos = first_line.rfind(':')?;
    let count_str = first_line[colon_pos + 1..].trim();
    count_str.parse().ok()
}
