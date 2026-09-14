//! Typed CognitionKit recipe execution seams shared by the selected v2 surface.
//!
//! # moot_dream
//!
//! On-demand dream tool: runs one dreaming cycle (latent-alignment proposals +
//! cycle diary) using the NeuronKit `DreamingDaemon` over the estate's live seams
//! (`EstateDreamingReader` + `EstateDreamingSink`). Returns a cycle summary.
//!
//! ## Step 1 — Matrix rebuild
//!
//! The Swift handler calls `kit.rebuildDerivedAccelerators(for:)`, which builds
//! a `MatrixTier` from the estate's audit log and registers it on the GLK actor's
//! per-estate map. The Rust GLK coordinator now exposes the same surface:
//! `EstateCoordinator::rebuild_derived_accelerators` feeds the unified audit log,
//! runs `MatrixTier::full_rebuild`, and registers the tier on the coordinator's
//! per-estate `matrix_tiers` map. `run_dream_tool` calls it before the dreaming
//! cycle, so the recall-scoring tier is current after each on-demand dream — full
//! parity with the Swift handler.
//!
//! ## Step 2 — Dreaming cycle
//!
//! The dreaming cycle is fully available: `EstateDreamingReader::new` snapshots the
//! estate seams through `EstateCoordinator`, `EstateDreamingSink::new` routes all
//! writes through the GLK `EstateCoordinator` verb surface (B-1 compliant), and
//! `DreamingDaemon::run_cycle` runs the 7-step NEURONKIT_SPEC § 3.1 algorithm. The
//! cycle writes ZERO recall-trace rows — B-10a is enforced by the seam design:
//! `EstateDreamingReader` reads through `coordinator.all_drawers` (no `trace_limit`)
//! and `EstateDreamingSink` writes through `coordinator.propose` /
//! `coordinator.add_diary_entry` (not the recall_scored path).
//!
//! ## Tool surface is on-demand only — by design, not by omission
//!
//! `moot_dream` deliberately exposes a single on-demand cycle: the schema
//! accepts a `now` arg and runs one cycle immediately, exactly as the
//! AutonomicGovernor does for the resident process. The `.timer`, `.event`,
//! and `.hybrid` dreaming modes (NeuronKit `DreamingTriggerMode`) are all
//! fully implemented in both ports, but they are RESIDENT-SCHEDULER concerns
//! driven by the autonomic governor / SolverBandit — not ARIA tool arguments.
//! Mode selection is intentionally not surfaced here; callers do not pass a
//! mode field.
//!
use cognition_kit::{run_precise_recall, run_shaped_recall};
use locus_kit::filter::Filter;

/// Direct typed core for the PreciseRecall recipe.
///
/// Returns CognitionKit matches rather than a rendered ARIA result, so the
/// selected surface retains rank, room, body, and precision evidence directly.
pub fn execute_precise_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    pool: usize,
    composition: Option<&str>,
    now_millis: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<Vec<cognition_kit::PreciseMatch>, cognition_kit::RecipeRunError> {
    run_precise_recall(
        coordinator, handle, query, filter, limit, pool, composition, now_millis, node_names,
    )
}

/// Direct typed core for the graph-diffusion connected-recall recipe.
pub fn execute_connected_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    wing: &str,
    filter: Filter,
    limit: usize,
    now_millis: i64,
) -> Result<Vec<cognition_kit::connected_recall::ConnectedMatch>, cognition_kit::RecipeRunError> {
    cognition_kit::connected_recall::run_connected_recall(
        coordinator, handle, query, wing, filter, limit, now_millis,
    )
}

/// Direct typed core for temporal recall.  The caller supplies the decoded
/// window/grab selectors so the recipe outcome retains its temporal evidence.
#[allow(clippy::too_many_arguments)]
pub fn execute_temporal_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    pool: usize,
    mode: cognition_kit::TemporalWindowMode,
    grab: cognition_kit::TemporalGrab,
    from: Option<&str>,
    to: Option<&str>,
    now_millis: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<cognition_kit::TemporalRecallOutcome, cognition_kit::RecipeRunError> {
    cognition_kit::run_temporal_recall(
        coordinator, handle, query, filter, limit, pool, mode, grab, from, to, now_millis,
        node_names,
    )
}

/// Direct typed core for the two-hop vague-recall seam.  The v1 renderer keeps
/// its summary/original presentation but no longer owns the estate call.
pub fn execute_vague_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    hit_limit: usize,
    constituents_per_hit: usize,
    total_constituents: usize,
) -> Result<genius_locus_kit::brain::consolidation_cycle::VagueRecallResult, genius_locus_kit::VerbDispatchError> {
    coordinator.vague_recall(handle, query, hit_limit, constituents_per_hit, total_constituents)
}

/// Direct typed core for the named-shape recipe.  It carries the exact
/// frontier override and room-name map that the v1 renderer currently uses.
pub fn execute_shaped_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    preset: &str,
    filter: Filter,
    limit: usize,
    now_millis: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
    frontier_k: Option<usize>,
) -> Result<cognition_kit::ShapedRecallOutput, cognition_kit::RecipeRunError> {
    run_shaped_recall(
        coordinator, handle, query, preset, filter, limit, now_millis, node_names, frontier_k,
    )
}

/// Direct typed core for the walk ladder.  Its result preserves both the
/// winning rows and stage evidence; renderers do not reconstruct it from text.
pub fn execute_walk_recall_typed(
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    now_millis: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<cognition_kit::WalkRecallOutcome, cognition_kit::RecipeRunError> {
    cognition_kit::run_walk_recall(
        coordinator, handle, query, filter, limit, now_millis, node_names,
    )
}

/// Direct typed core for distilled recall.  The caller owns its typed input,
/// including filter and limit, so neither public surface parses rendered rows.
pub fn execute_distilled_recall_typed(
    input: &cognition_kit::DistilledRecallInput,
    coordinator: &genius_locus_kit::EstateCoordinator,
    handle: &genius_locus_kit::EstateHandle,
    now_millis: i64,
) -> Result<cognition_kit::DistilledRecallOutput, genius_locus_kit::VerbDispatchError> {
    cognition_kit::run_distilled_recall(input, coordinator, handle, now_millis)
}

/// Render the typed conflict-projection sweep as the ADDITIVE report
/// section every contradiction surface appends (DCP M4, M0 §7):
/// moot_hunt_contradictions, moot_dream, and moot_lens_contradiction
/// all route through this one renderer so the lines never drift.
///
/// Redaction (M0 §8, ceiling = MAX endpoint sensitivity, no grant
/// plumbing in v0.1 — same fixed posture as the lexical hunter):
/// ceiling ≤ elevated (raw 16) → full block incl. S2 candidate rows;
/// restricted (raw 32) → one line naming only the coordinate DIGEST;
/// secret (raw 48) → counted in `proven: N`, no block at all.
///
/// `lexical_candidates` is the borderline count from the lexical hunter
/// (the `candidates:` relabel); None on surfaces with no lexical lane
/// (the lens). The selected Swift and Rust v2 lowers project the same typed sweep.


/// Structured-tier by-id S2-row fetch behind the default-gated RecallFrame —
/// the ONE drawer-content path every contradiction renderer uses. Gated rows
/// are ABSENT from the map; callers fall through to the unhydrated-row fallback.
/// Twin of Swift `RecipeTools.s2RowsByID`. Replaces the legacy `denseRowsByID`.
///
/// THE EMPTY `RecallFrame` FILTER CHAIN IS LOAD-BEARING. `BitmapEvaluator::insert_defaults`
/// inserts `SensitivityAtMost(Elevated)` into any chain carrying no sensitivity filter,
/// so restricted/secret drawers never reach the renderer. Do NOT replace with
/// a raw `store.get_drawer` loop.


/// Exact tier section headers — the wire contract for every surface
/// that renders a `TieredContradictionReport` (hunt and dream share
/// this ONE renderer, M4 pattern: one renderer, lines never drift).
/// Parity: Swift `RecipeTools.tier1Header` etc.

/// Render a `TieredContradictionReport` as report lines. The ONE
/// tiered renderer: `moot_hunt_contradictions` (both modes) and
/// `moot_dream` (synthesis digest) both route through here so the
/// sections never drift between surfaces or ports.
///
/// Tier-1 blocks reuse the typed lane's rendering contract
/// (`conflict_projection_section`'s F13 redaction path): a secret
/// finding is counted by the lane counts only (no block), a restricted
/// finding renders ONLY the coordinate-digest line, and a finding at or
/// below elevated renders result essentials plus the same gated dense
/// rows. The tiered verb already ceiling-filters
/// findings above elevated out of its tier-1 section
/// (`tier1_ceiling_filtered`), so the secret/restricted arms here are
/// defense in depth, not the primary gate.
///
/// Tiers 2/3 render the drawer pair plus cue kind and score — no
/// content snippets: the legacy CANDIDATE feed is the snippet surface,
/// and the digest must not become a second content disclosure path.
///
/// `lane_seconds` is `Some` in SYNTHESIS mode only: per-tier lane
/// counts and the elapsed-seconds lines render only for a synthesis
/// digest. The seconds are measured by the CALLER around each GLK
/// call — the engines are deterministic (no clock reads inside), so
/// wall-clock timing lives at this dispatch layer, the I/O boundary.
/// Mirrors Swift `RecipeTools.tieredSectionLines`.


/// Hydrate the gated S2 candidate rows for a tiered report's fully visible
/// tier-1 findings and render its sections. Mirrors Swift
/// `RecipeTools.renderTieredSections`.


/// Precise-recall tool — mirrors Swift `RecipeTools.preciseRecallToolName`.
/// Connected recall: multi-hop retrieval by graph diffusion (scored anchor
/// seeds a walk-with-restart over tunnels ∪ pending associations). The
/// EXPENSIVE recall path — callers escalate here for bridge questions.
/// Shaped-recall tool (named RecallShape preset) — mirrors Swift
/// `RecipeTools.shapedRecallToolName`.
/// On-demand dream tool — mirrors Swift `RecipeTools.dreamToolName`.
/// Distilled-payload recall (§10.3): exact-search geometry + distilled
/// hydration — mirrors Swift `RecipeTools.recallDistilledToolName`.
/// ACK-GATED: requires ack: "recall_distilled/v2" (Wave 1 contract change).
/// On-demand contradiction-hunt sweep — mirrors Swift
/// `RecipeTools.huntContradictionsToolName`.
/// Escalation-ladder recall (D10) — mirrors Swift
/// `RecipeTools.walkRecallToolName`. Stage 1 (session_hybrid, cheap) stops
/// when confident (topGap ≥ 0.25); Stage 2 (hamming+text) fires only when
/// Stage 1 is insufficient.
/// Maximum probe count for `moot_dream` when `associates: "all"` is requested.
///
/// "all" mode is intended for post-import full-estate coverage: the caller
/// wants proximity associations mined across every item. Without a cap,
/// `probe_limit: None` passes `usize::MAX` to `recent_item_ids`, loading the
/// whole table and running O(N × k) kNN probes — on a large estate that runs
/// for minutes inside an MCP call.
///
/// 10_000 items is the bound:
///   - At HNSW scale (k = 5, O(k·log N)): ~700K similarity ops, a few seconds.
///   - Personal estates with >10K vector-indexed drawers are exceptional;
///     repeated calls converge anyway (existing associations are skipped).
///   - Consistent with hunt_contradictions' 500-probe per-call bound:
///     the associate sweep is the "full-coverage" companion, so 20× is generous.
///
/// Parity constant: Swift `RecipeTools.dreamAssociateAllModeMaxProbe = 10_000`.
const DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE: usize = 10_000;
/// Exported alias for use in the v2 lower engine (`v2::dream`).  The constant
/// value is the same; the alias keeps the canonical definition in one place.
pub(crate) const DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE_PUB: usize = DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE;

// ---------------------------------------------------------------------------
// moot_list_lenses
// ---------------------------------------------------------------------------

/// Decode the shared `verbose` flag for the two catalogue tools (PR-04).
/// Absent → false (terse default); present-but-non-bool → invalidParams.


/// First sentence of a tool description, for the terse catalogue rows
/// (PR-04). Deterministic and byte-identical to the Swift twin: cut at
/// the first ". " boundary, keeping the period.




// ---------------------------------------------------------------------------
// moot_list_recipes — full catalog browse (format mirrors Swift runListRecipesCatalog)
// ---------------------------------------------------------------------------



// ---------------------------------------------------------------------------
// moot_grounded_synthesis
// ---------------------------------------------------------------------------



// ---------------------------------------------------------------------------
// moot_recall_precise
// ---------------------------------------------------------------------------

/// Run the PreciseRecall recipe and serialize its matches in the SAME
/// plain-text shape `moot_memory_search` emits: a `found N candidate memories, one per line` header
/// line then one `id  [room]  preview` line per ranked match (120-char preview).
/// Mirroring that shape keeps every mootText parser working unchanged.
///
/// Threads `pool`/`limit`/`composition` exactly as the Swift `runPreciseRecall`
/// does. UNLIKE the Swift dispatch, the Rust boundary VALIDATES the composition
/// against the grid and FAILS CLOSED on an unknown name (returns an
/// `error_result`) rather than silently degrading to `text` — the access
/// surface rejects a malformed ablation selector instead of returning
/// surprising results under a name the caller does not realize was ignored.
/// moot_recall_vague — two-hop vague recall (Wave-2 §4.4). Mirrors Swift
/// `RecipeTools.runVagueRecall`: D12 bounds clamped at the boundary, vague
/// summaries first with level tags, hydrated originals after, no-hits hint.
/// moot_recall_connected — the ConnectedRecall recipe over MCP. Serializes
/// matches in the SAME shape moot_memory_search emits (canonical S1
/// candidate rows, no tool-specific text line — ARIA_MCP_SPEC 2.0.0
/// § 8.4; graph provenance travels as structured data). Twin of Swift
/// `runConnectedRecall`.




/// moot_recall_temporal — the query-date window recipe (twin of Swift
/// RecipeTools.runTemporalRecall). Parses the query's absolute date (or takes
/// an explicit from/to window), coarse-grabs a wide pool, applies the window
/// (loose = boost, tight = filter), and replies in the house dense-row shape
/// with a trailing `temporal:` narration line.




// ---------------------------------------------------------------------------
// moot_recall_shaped
// ---------------------------------------------------------------------------

/// Run the ShapedRecall recipe with a named RecallShape preset and serialize its
/// matches in the SAME plain-text shape `moot_memory_search` emits. Mirrors Swift
/// `RecipeTools.runShapedRecall`.
///
/// Preset validation is fail-CLOSED: an absent `preset` arg maps to "balanced"
/// (the unsteered default). A present-but-unknown name is rejected with an
/// `error_result` against the GLK roster rather than silently degrading — the
/// same boundary discipline as the precise-recall composition arg. (The recipe
/// itself degrades to balanced; the access surface is where fail-closed
/// validation lives.)


// ---------------------------------------------------------------------------
// moot_dream
// ---------------------------------------------------------------------------

/// Run `moot_dream`: run one dreaming cycle over the live estate seams.
///
/// # B-10a internal-origin proof
///
/// The dreaming cycle writes ZERO recall-trace rows. The cycle reads through
/// `EstateDreamingReader::new` which calls `coordinator.all_drawers` and
/// `coordinator.all_tunnels` — neither of which sets a `trace_limit`, so no
/// trace rows are written. The write path (`EstateDreamingSink`) routes through
/// `coordinator.propose` and `coordinator.add_diary_entry`. The `recall_scored` path
/// (the only path that writes trace rows) is never invoked. This is the
/// literal proof: grep `run_dream_tool` for `recall_scored` — zero hits.
///
/// # Matrix rebuild
///
/// Before the dreaming cycle, `coordinator.rebuild_derived_accelerators` feeds
/// the unified audit log, rebuilds the `MatrixTier` (`MatrixTier::full_rebuild`),
/// and registers it on the coordinator's per-estate `matrix_tiers` map — the
/// Rust parity of the Swift handler's `kit.rebuildDerivedAccelerators(for:)`. A
/// rebuild failure (stale handle) surfaces as a TOOL_DISPATCH_FAILURE rather
/// than a silent skip.
///
/// # `now` determinism
///
/// A malformed `now` is an out-of-band invalidParams fault, not a silent
/// fallback — the determinism contract must not be bypassed quietly.
/// Mirrors Swift `RecipeTools.runDream` identical check.


/// Run `moot_hunt_contradictions`: one bounded contradiction-hunt sweep.
/// Strong findings persist as proposed contradicts tunnels (the hunt does
/// its own writes); borderline candidates come back with snippets for the
/// calling agent to adjudicate. Mirrors Swift `runHuntContradictions`.
///
/// MXE-CT3 P3 tier modes:
/// - `tier` absent or `"all"` (the default): today's exact legacy sweep
///   report, unchanged byte for byte, PLUS an appended tiered synthesis
///   digest (`tiered_contradiction_search` synthesis mode).
/// - `tier` 1|2|3: a read-only purpose search of that single lane —
///   no legacy sweep, no tunnels filed, no writes of any kind.


// ---------------------------------------------------------------------------
// moot_recall_walk (D10)
// ---------------------------------------------------------------------------

/// Run `moot_recall_walk`: escalation-ladder recall.
///
/// Stage 1 (ShapedRecall / session_hybrid, pool 20) runs first. When its
/// top-gap reaches the confidence threshold (≥ 0.25) the result is returned
/// immediately (stopped_early: true). Otherwise Stage 2 (PreciseRecall /
/// hamming+text) runs and its result is returned (stopped_early: false).
///
/// Mirrors Swift `RecipeTools.runWalkRecall(_:kit:handle:)`. Returns the
/// same dense-row shape as moot_memory_search plus a `walk:` line naming
/// the stage and the stopped_early flag.


/// Parse an ISO8601 UTC instant string (e.g. "2026-06-11T00:00:00Z") to Unix
/// epoch milliseconds. Returns `None` for any malformed or out-of-range input.
///
/// Supports the two formats the substrate uses:
///   - `YYYY-MM-DDTHH:MM:SSZ`          (no fractional seconds)
///   - `YYYY-MM-DDTHH:MM:SS.sssZ`      (fractional seconds, up to milliseconds)
///
/// Does NOT support timezone offsets — only the `Z` (UTC) suffix, matching the
/// ISO8601 instants the substrate stores and the Swift `ISO8601DateFormatter`
/// default format. Mirrors the Swift parse in `RecipeTools.runDream`.
pub(crate) fn parse_iso8601_to_epoch(s: &str) -> Option<i64> {
    // Accept "Z"-terminated strings only; strip the suffix.
    let s = s.strip_suffix('Z')?;
    // Split date and time on 'T'.
    let (date_part, time_part) = s.split_once('T')?;
    let date_fields: Vec<&str> = date_part.split('-').collect();
    if date_fields.len() != 3 {
        return None;
    }
    let year: i64 = date_fields[0].parse().ok()?;
    let month: i64 = date_fields[1].parse().ok()?;
    let day: i64 = date_fields[2].parse().ok()?;

    // Strip optional fractional seconds before the last colon-delimited field.
    let time_no_frac = time_part.split('.').next()?;
    let time_fields: Vec<&str> = time_no_frac.split(':').collect();
    if time_fields.len() != 3 {
        return None;
    }
    let hour: i64 = time_fields[0].parse().ok()?;
    let min: i64 = time_fields[1].parse().ok()?;
    let sec: i64 = time_fields[2].parse().ok()?;

    // Validate ranges.
    if month < 1 || month > 12 || day < 1 || day > 31 {
        return None;
    }
    if hour > 23 || min > 59 || sec > 60 {
        return None;
    }

    // Days since Unix epoch (1970-01-01) using the proleptic Gregorian calendar.
    // Algorithm: Julian Day Number subtraction. JDN(1970-01-01) = 2440588.
    // Handles all years, leap years, and month-end boundaries correctly.
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045;
    let days_since_epoch = jdn - 2440588;

    // Return epoch MILLISECONDS — second precision (the fractional
    // field is dropped upstream), scaled to the ms the storage path expects.
    Some((days_since_epoch * 86_400 + hour * 3600 + min * 60 + sec) * 1000)
}

/// Stopwords excluded from grounding-term extraction: question scaffolding
/// and function words that would match nearly every memory and destroy the
/// cue's selectivity. Deliberately small — an over-eager list starts eating
/// content words. MUST stay byte-identical to Swift `groundingStopwords` in
/// RecipeTools.swift.
const GROUNDING_STOPWORDS: &[&str] = &[
    "the", "and", "for", "are", "was", "were", "has", "have", "had",
    "did", "does", "not", "with", "that", "this", "from", "they",
    "their", "them", "then", "than", "there", "these", "those", "you",
    "your", "what", "when", "where", "which", "who", "whom", "why",
    "how", "will", "would", "could", "should", "about", "been", "being",
    "into", "over", "under", "after", "before", "between", "during",
    "any", "all", "each", "most", "some", "such", "can", "may", "might",
    "must", "shall", "its", "his", "her", "him", "she", "our", "out",
    "but", "per", "via", "also", "just", "only", "very", "much", "more",
];

/// Extracts the distinctive grounding terms from a free-text query:
/// alphanumeric runs, lowercased (content matching is case-insensitive on
/// both ports), dropping stopwords and short fragments (< 3 chars unless
/// they carry a digit — "42" or "3b" are distinctive, "at" is not),
/// deduplicated in first-appearance order, capped at 12 terms so a pasted
/// paragraph cannot degenerate into an unbounded OR. Deterministic pure
/// function of the query — MUST stay behavior-identical to Swift
/// `groundingTerms(from:)` in RecipeTools.swift.
pub fn grounding_terms(query: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut terms: Vec<String> = Vec::new();
    for raw in query.split(|c: char| !c.is_alphanumeric()) {
        if raw.is_empty() {
            continue;
        }
        let token = raw.to_lowercase();
        let has_digit = token.chars().any(|c| c.is_numeric());
        if token.chars().count() < 3 && !has_digit {
            continue;
        }
        if GROUNDING_STOPWORDS.contains(&token.as_str()) {
            continue;
        }
        if !seen.insert(token.clone()) {
            continue;
        }
        terms.push(token);
        if terms.len() == 12 {
            break;
        }
    }
    terms
}
