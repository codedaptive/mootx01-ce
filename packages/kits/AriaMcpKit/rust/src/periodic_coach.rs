//! Deterministic coaching block renderer for the Moot Modes periodic coaching system.
//!
//! ## Tone contract
//!
//! Bob's positive-reinforcement shape (spec §4): praise the parts done right by
//! name, then ONE improvement framed as friendly confidence ("I bet next time…").
//! Never scolding, never more than one suggestion per block. ~80 token cap.
//!
//! ## Template selection
//!
//! Templates are selected deterministically from the session's call counters.
//! No LLM is involved. The first matching template wins; the fallback always fires.
//!
//! ## Golden pin
//!
//! `render_block` is the entry point tested by the Rust `modes_tests.rs` and
//! the Swift `PeriodicCoachTests.swift`. Both read the shared golden-pin fixture
//! at `Tests/Conformance/modes_coaching_fixture.json` and assert byte-identical
//! output. If either port diverges, its golden-pin test fails.
//!
//! ## Block format
//!
//! ```text
//! [Moot coaching · call N]
//! <praise sentence>
//! <one improvement sentence framed as "I bet …">
//! Modes available: <attribution breakdown>.
//! ```
//!
//! Parity: Rust twin of Swift `PeriodicCoach.swift`.

use crate::mode_registry::MootMode;
use crate::mode_session_state::CoachingSnapshot;

/// Render the coaching block for the given snapshot.
///
/// This is the public entry point — tested by the golden-pin fixture in both
/// Swift and Rust. Returns the complete block string including the header line.
pub fn render_block(snapshot: &CoachingSnapshot) -> String {
    let header = format!("[Moot coaching · call {}]", snapshot.total_calls);
    let body = select_template(snapshot);
    let modes_line = modes_available_line(snapshot);
    format!("{}\n{}\n{}", header, body, modes_line)
}

/// Select the best-matching template from the snapshot.
///
/// Templates are evaluated in priority order; the first match wins.
/// The fallback template always matches.
fn select_template(snapshot: &CoachingSnapshot) -> String {
    // Template 1: Heavy search pattern — moot_memory_search dominant.
    if let Some(&search_count) = snapshot.tool_counts.get("moot_memory_search") {
        if search_count >= 5 {
            let hydration_count = snapshot.tool_counts.get("moot_memory_get").copied().unwrap_or(0);
            if hydration_count > 0 {
                return format!(
                    "Nice run: {} searches and every hydration you made was on a row you'd already ranked \
                     — that's the cheap-pile pattern working. I bet recall_precise earns a place when you know the subject exactly.",
                    search_count
                );
            }
            return format!(
                "Good searching — {} queries this session. I bet moot_memory_get on rank-1 IDs would save you a round-trip when you already know what you need.",
                search_count
            );
        }
    }

    // Template 2: Filing pattern — moot_file_memory dominant.
    if let Some(&file_count) = snapshot.tool_counts.get("moot_file_memory") {
        if file_count >= 3 {
            let confirm_count = snapshot.tool_counts.get("moot_confirm_memory").copied().unwrap_or(0);
            if confirm_count == 0 {
                return format!(
                    "Good filing — {} memories stored this session. I bet moot_confirm_memory on your most important ones marks them user-verified, which puts them on the recall fast path.",
                    file_count
                );
            }
            return format!(
                "Solid filing: {} memories stored, {} confirmed. I bet moot_link_memories between related ones builds the association graph so future searches surface the cluster.",
                file_count, confirm_count
            );
        }
    }

    // Template 3: Fact-heavy pattern — moot_file_fact dominant.
    if let Some(&fact_count) = snapshot.tool_counts.get("moot_file_fact") {
        if fact_count >= 3 {
            return format!(
                "You're building the knowledge graph — {} facts filed. I bet moot_fact_timeline for your main subject shows you what the estate knows over time.",
                fact_count
            );
        }
    }

    // Template 4: Bigram pattern — search→get bigram strong (good pattern, reinforce).
    let search_to_get = snapshot.bigram_counts
        .get("moot_memory_search→moot_memory_get")
        .copied()
        .unwrap_or(0);
    if search_to_get >= 2 {
        return "Great pattern: search then immediately get — you're navigating by relevance rank. I bet adding recall_temporal to your toolkit answers date-anchored questions in one call.".to_string();
    }

    // Template 5: Single-mode session — praise the focus.
    if let Some((top_mode_name, &count)) = top_mode(snapshot) {
        if count >= 3 {
            return format!(
                "Focused {} session — {} calls in that mode. I bet a quick moot_estate_status at the start of your next session orients you even faster.",
                top_mode_name, count
            );
        }
    }

    // Fallback: general positive reinforcement.
    let tool_count = snapshot.tool_counts.len();
    format!(
        "Good session — {} calls across {} tool{}. I bet moot_estate_status teaches you a tool you haven't tried yet.",
        snapshot.total_calls,
        tool_count,
        if tool_count == 1 { "" } else { "s" }
    )
}

/// Render the "Modes available: …" attribution breakdown.
///
/// Shows top-3 used modes by percentage and marks unused modes (up to 2).
fn modes_available_line(snapshot: &CoachingSnapshot) -> String {
    let total: usize = snapshot.mode_attribution_counts.values().sum();
    if total == 0 {
        return "Modes available: Recall, Filing, Lenses, Vault, Curator (try mode:\"Recall=Auto\" on your next search).".to_string();
    }

    // Sort modes by attribution count (descending). Use BTreeMap-like sort for determinism.
    let mut sorted: Vec<(&String, &usize)> = snapshot.mode_attribution_counts.iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));

    let all_mode_names: Vec<&'static str> = MootMode::all_cases()
        .iter()
        .map(|m| m.raw_value())
        .collect();

    let mut parts: Vec<String> = Vec::new();

    for (name, &count) in sorted.iter().take(3) {
        let pct = (count as f64 / total as f64 * 100.0) as usize;
        parts.push(format!("{} ({}%)", name, pct));
    }

    // Mark modes with zero attribution as unused (up to 2).
    let used_names: std::collections::HashSet<&str> =
        snapshot.mode_attribution_counts.keys().map(|s| s.as_str()).collect();
    for name in all_mode_names.iter().filter(|&&n| !used_names.contains(n)).take(2) {
        parts.push(format!("{} (unused)", name));
    }

    format!("Modes available: {}.", parts.join(", "))
}

/// Return the top attributed mode name and its call count, or None when no
/// mode attribution has been recorded.
///
/// Tiebreak: descending count, then name ascending (same rule as `modes_available_line`).
/// A deterministic tiebreak ensures both ports produce identical output when two
/// modes share the highest attribution count.
fn top_mode(snapshot: &CoachingSnapshot) -> Option<(&str, &usize)> {
    snapshot.mode_attribution_counts
        .iter()
        // Primary: higher count wins. Tiebreak: name ascending (alphabetical).
        .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
        .map(|(k, v)| (k.as_str(), v))
}
