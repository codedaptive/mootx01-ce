//! CognitionKit recipe tool surface — moot_list_lenses, moot_list_recipes,
//! moot_synthesize, moot_run_migration, moot_confirm_migration, moot_dream.
//!
//! Mirrors Swift `RecipeTools.swift`. Same dispatch contract: out-of-band faults
//! throw `JSONRPCError`; recipe-level refusals come back as `error_result` (isError
//! true) so the client keeps the call id.
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
//! estate seams through `EstateCoordinator`, `EstateDreamingSink::new` writes
//! proposals and diary entries through `DrawerStore`, and `DreamingDaemon::run_cycle`
//! runs the 7-step NEURONKIT_SPEC § 3.1 algorithm. The cycle writes ZERO recall-trace
//! rows — B-10a is enforced by the seam design: `EstateDreamingReader` reads through
//! `coordinator.all_drawers` (no `trace_limit`) and `EstateDreamingSink` writes
//! through `store.add_proposal` / `store.add_diary_entry` (not the recall_scored path).
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
//! # moot_run_migration
//! …unchanged…
//!
//! # moot_confirm_migration
//! …unchanged…
//!
//! # moot_run_migration
//!
//! Derives one COW branch per candidate plan, populates each from the origin corpus,
//! benchmarks recall fidelity with the zero-silent-loss gate, and returns a ranked
//! list of survivors. Never promotes. Returns branch ids in the result text so a
//! caller can pass them to the confirm tool.
//!
//! # moot_confirm_migration
//!
//! Dispatches `confirm_migration_promotion_by_id` — the id-addressed form of the
//! human-gated promotion step. The server is stateless across tool calls; the
//! two-call pattern (run then confirm) works because the coordinator retains all
//! minted branches in memory, and the run result text carries the branch ids the
//! caller needs. Required: `winnerBranchID` (UUID string). Optional:
//! `discardBranchIDs` and `disqualifiedBranchIDs` (arrays of UUID strings). Mirrors
//! the Swift server's confirm handler contract and the Swift
//! `MigrationBenchmark.confirmPromotion` by-id overload as the behavioral reference.

use std::collections::BTreeMap;
use std::sync::Arc;

use cognition_kit::{
    recipe_catalog, run_grounded_synthesis, run_precise_recall, run_shaped_recall, OriginEntry,
    PlanInput, PRECISE_DEFAULT_POOL,
};
use genius_locus_kit::recall::RecallShape;
use genius_locus_kit::branches::BranchId;
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use neuron_kit::RecallFrameTuning;
use uuid::Uuid;

use crate::dispatch::{
    decode_filter_chain, error_result, optional_integer, optional_string, require_string,
    text_result,
};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Recipe tool names — mirrors Swift `RecipeTools` static constants.
const LIST_LENSES: &str = "moot_list_lenses";
/// Full recipe catalog browse tool — mirrors Swift `RecipeTools.listRecipesCatalogToolName`.
const LIST_RECIPES_CATALOG: &str = "moot_list_recipes";
const SYNTHESIZE: &str = "moot_synthesize";
const RUN_MIGRATION: &str = "moot_run_migration";
const CONFIRM_MIGRATION: &str = "moot_confirm_migration";
/// Precise-recall tool — mirrors Swift `RecipeTools.preciseRecallToolName`.
const RECALL_PRECISE: &str = "moot_recall_precise";
/// Shaped-recall tool (named RecallShape preset) — mirrors Swift
/// `RecipeTools.shapedRecallToolName`.
const RECALL_SHAPED: &str = "moot_recall_shaped";
/// On-demand dream tool — mirrors Swift `RecipeTools.dreamToolName`.
const DREAM: &str = "moot_dream";

/// True when `name` is one of the recipe tools.
pub fn is_recipe_tool(name: &str) -> bool {
    matches!(
        name,
        LIST_LENSES
            | LIST_RECIPES_CATALOG
            | SYNTHESIZE
            | RUN_MIGRATION
            | CONFIRM_MIGRATION
            | RECALL_PRECISE
            | RECALL_SHAPED
            | DREAM
    )
}

/// Dispatch a recipe tool call. Same contract as `dispatch_tool`.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        LIST_LENSES => Ok(run_list_recipes()),
        LIST_RECIPES_CATALOG => Ok(run_list_recipes_catalog()),
        SYNTHESIZE => run_grounded_synthesis_tool(args, registry),
        RUN_MIGRATION => run_migration_benchmark_tool(args, registry),
        CONFIRM_MIGRATION => run_confirm_promotion_tool(args, registry),
        RECALL_PRECISE => run_precise_recall_tool(args, registry),
        RECALL_SHAPED => run_shaped_recall_tool(args, registry),
        DREAM => run_dream_tool(args, registry),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown recipe tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// moot_list_lenses
// ---------------------------------------------------------------------------

fn run_list_recipes() -> serde_json::Value {
    let catalog = recipe_catalog();
    let mut lines = vec![format!("recipes: {}", catalog.len())];
    for d in &catalog {
        let caps: Vec<&str> = d
            .required_capabilities
            .iter()
            .map(|c| {
                // The capability rawValue — matches the Swift .rawValue string.
                // Delegates to the capability's own raw_value() to stay in sync
                // with declaration order and avoid exhaustive match maintenance.
                c.raw_value()
            })
            .collect();
        lines.push(format!("  - {} v{}", d.name, d.version));
        lines.push(format!("      {}", d.description));
        lines.push(format!("      capabilities: {}", caps.join(", ")));
    }
    text_result(&lines.join("\n"))
}

// ---------------------------------------------------------------------------
// moot_list_recipes — full catalog browse (format mirrors Swift runListRecipesCatalog)
// ---------------------------------------------------------------------------

fn run_list_recipes_catalog() -> serde_json::Value {
    let catalog = recipe_catalog();
    let mut lines = vec![format!("moot_list_recipes: {} recipe(s)", catalog.len())];
    for d in &catalog {
        let caps: Vec<&str> = d
            .required_capabilities
            .iter()
            .map(|c| c.raw_value())
            .collect();
        lines.push(String::new());
        lines.push(d.name.clone());
        lines.push(format!("  version: {}", d.version));
        lines.push(format!("  {}", d.description));
        lines.push(format!(
            "  requires: {}",
            if caps.is_empty() {
                "none".to_owned()
            } else {
                caps.join(", ")
            }
        ));
    }
    text_result(&lines.join("\n"))
}

// ---------------------------------------------------------------------------
// moot_grounded_synthesis
// ---------------------------------------------------------------------------

fn run_grounded_synthesis_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let filter_chain = decode_filter_chain(args)?;
    let limit = optional_integer(args, "limit")?.map(|i| i as usize);

    let mut frame = RecallFrame::new(filter_chain);
    frame.hydration_level = HydrationLevel::Structured;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    if let Some(l) = limit {
        frame.limit = Some(l);
    }

    let now = crate::dispatch::wall_now();
    let coord = estate.coord.lock().unwrap();
    let out = run_grounded_synthesis(
        &coord,
        &estate.handle,
        frame,
        RecallFrameTuning::default(),
        now,
    )
    .map_err(error_from_recipe)?;

    let doc = &out.context;
    let body = format!(
        "grounded_synthesis: {} drawer(s)\nsummary: {}\npatterns: {}\nsuccessRate: {}\nrecommendations:\n{}\nkeyInsights:\n{}",
        out.drawer_count,
        doc.summary,
        doc.patterns.join(", "),
        doc.success_rate,
        doc.recommendations.iter().map(|r| format!("  - {r}")).collect::<Vec<_>>().join("\n"),
        doc.key_insights.iter().map(|i| format!("  - {i}")).collect::<Vec<_>>().join("\n"),
    );
    Ok(text_result(&body))
}

// ---------------------------------------------------------------------------
// moot_recall_precise
// ---------------------------------------------------------------------------

/// Run the PreciseRecall recipe and serialize its matches in the SAME
/// plain-text shape `moot_memory_search` emits: a `found N memory(s)` header
/// line then one `id  [room]  preview` line per ranked match (120-char preview).
/// Mirroring that shape keeps every mootText parser working unchanged.
///
/// Threads `pool`/`limit`/`composition` exactly as the Swift `runPreciseRecall`
/// does. UNLIKE the Swift dispatch, the Rust boundary VALIDATES the composition
/// against the grid and FAILS CLOSED on an unknown name (returns an
/// `error_result`) rather than silently degrading to `text` — the access
/// surface rejects a malformed ablation selector instead of returning
/// surprising results under a name the caller does not realize was ignored.
fn run_precise_recall_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let query = require_string(args, "query")?;
    // 20 is moot_memory_search's own default limit; keep parity.
    let limit = optional_integer(args, "limit")?
        .map(|i| i as usize)
        .unwrap_or(20);
    // Default coarse pool is CognitionKit's own default (30); honour an explicit
    // override. The recipe clamps pool >= limit internally.
    let pool = optional_integer(args, "pool")?
        .map(|i| i as usize)
        .unwrap_or(PRECISE_DEFAULT_POOL);
    let filter = decode_precise_filter(args)?;

    // The ablation selector: a named reduction composition. Absent ⇒ None ⇒ the
    // recipe's default (`text`). Present-but-unknown ⇒ fail closed at the
    // boundary (the grid is the authoritative name set; an unknown name is a
    // caller error, not a silent fall-through).
    let composition = match optional_string(args, "composition")? {
        Some(name) if neuron_kit::composition_grid::is_known(name) => Some(name.to_string()),
        Some(name) => {
            return Ok(error_result(&format!(
                "unknown composition '{name}'; valid names: {}",
                neuron_kit::composition_grid::names().join(", ")
            )));
        }
        None => None,
    };

    let now = crate::dispatch::wall_now();
    let coord = estate.coord.lock().unwrap();
    let matches = run_precise_recall(
        &coord,
        &estate.handle,
        &query,
        filter,
        limit,
        pool,
        composition.as_deref(),
        now,
    )
    .map_err(error_from_recipe)?;

    // Compute discrimination over the full ordered list before the display prefix.
    let precise_scores: Vec<f64> = matches.iter().map(|m| m.score).collect();
    let discrimination = crate::recall_discrimination::classify(&precise_scores);

    let mut lines = vec![format!("found {} memory(s)", matches.len())];
    for m in matches.iter().take(50) {
        // Match moot_memory_search's preview: first 120 chars of content.
        let preview: String = m.content.chars().take(120).collect();
        let room = if m.room.is_empty() { "?" } else { &m.room };
        lines.push(format!("{}  [{}]  {}", m.id, room, preview));
    }
    lines.push(crate::recall_discrimination::result_line(discrimination).to_string());
    Ok(text_result(&lines.join("\n")))
}

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
fn run_shaped_recall_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let query = require_string(args, "query")?;
    // 20 is moot_memory_search's own default limit; keep parity.
    let limit = optional_integer(args, "limit")?
        .map(|i| i as usize)
        .unwrap_or(20);
    let filter = decode_precise_filter(args)?;

    // The steering selector: a named RecallShape preset. Absent ⇒ "balanced"
    // (unsteered default). Present-but-unknown ⇒ fail closed at the boundary (the
    // roster is the authoritative name set).
    let preset = match optional_string(args, "preset")? {
        Some(name) if RecallShape::PRESET_NAMES.contains(&name) => name.to_string(),
        Some(name) => {
            return Ok(error_result(&format!(
                "unknown preset '{name}'; valid presets: {}",
                RecallShape::PRESET_NAMES.join(", ")
            )));
        }
        None => "balanced".to_string(),
    };

    let now = crate::dispatch::wall_now();
    let coord = estate.coord.lock().unwrap();
    let out = run_shaped_recall(&coord, &estate.handle, &query, &preset, filter, limit, now)
        .map_err(error_from_recipe)?;

    // Compute discrimination over the full ordered list before the display prefix.
    let shaped_scores: Vec<f64> = out.matches.iter().map(|m| m.score).collect();
    let discrimination = crate::recall_discrimination::classify(&shaped_scores);

    let mut lines = vec![format!("found {} memory(s)", out.matches.len())];
    for m in out.matches.iter().take(50) {
        // Match moot_memory_search's preview: first 120 chars of content.
        let preview: String = m.content.chars().take(120).collect();
        let room = if m.room.is_empty() { "?" } else { &m.room };
        lines.push(format!("{}  [{}]  {}", m.id, room, preview));
    }
    lines.push(crate::recall_discrimination::result_line(discrimination).to_string());
    Ok(text_result(&lines.join("\n")))
}

// ---------------------------------------------------------------------------
// moot_run_migration_benchmark
// ---------------------------------------------------------------------------

fn run_migration_benchmark_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let corpus_name = require_string(args, "corpusName")?;
    let entries_value = args
        .get("entries")
        .filter(|v| v.as_array().is_some())
        .cloned()
        .ok_or_else(|| {
            JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, "entries must be an array")
        })?;
    let plans = decode_plans(args)?;
    if plans.is_empty() {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "run_migration_benchmark requires at least one plan",
        ));
    }

    // ADR-007 Decision 1 (VK-ADAPT-01): vault-kit's adapter pipeline owns
    // the export-decode knowledge. Re-encode the wire entries as an export
    // document and run ExchangeAdapter → corpus_projection — the same
    // consolidated path file import uses — instead of decoding entries
    // inline here. Tool name and input schema are unchanged; decode
    // failures map to an invalidParams error as before the re-plumb.
    let mut export_object = BTreeMap::new();
    export_object.insert(
        "name".to_string(),
        JsonValue::String(corpus_name.to_string()),
    );
    export_object.insert("entries".to_string(), entries_value);
    let export_bytes =
        serde_json::to_vec(&JsonValue::Object(export_object)).map_err(|e| {
            JSONRPCError::new(
                JSONRPCErrorCode::INTERNAL_ERROR,
                format!("failed to re-encode entries: {e}"),
            )
        })?;
    let export = vault_kit::ExchangeAdapter::new()
        .decode(&export_bytes)
        .map_err(|_| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "each entry needs string id and content",
            )
        })?;
    let corpus = vault_kit::corpus_projection::external_corpus(&export.name, &export.notes);
    let origin: Vec<OriginEntry> = corpus
        .entries
        .into_iter()
        .map(|entry| OriginEntry { id: entry.id, content: entry.content })
        .collect();

    let now = crate::dispatch::wall_now();
    let mut coord = estate.coord.lock().unwrap();

    use cognition_kit::migration_live::LiveRecipeSubstrate;
    // EstateHandle is Copy — use directly without clone.
    let mut substrate = LiveRecipeSubstrate::new(&mut coord, estate.handle, now);

    let report = cognition_kit::run_migration_benchmark(&mut substrate, &plans, &origin)
        .map_err(error_from_recipe)?;

    let mut lines = vec![format!("run_migration_benchmark: corpus={corpus_name}")];
    if let Some(winner) = &report.winner {
        let bid = report
            .plan_results
            .iter()
            .find(|p| &p.name == winner)
            .map(|p| p.branch_id.clone())
            .unwrap_or_default();
        lines.push(format!("winner: plan '{winner}' branch {bid}"));
    } else {
        lines.push("winner: none (all plans disqualified or no plans)".to_owned());
    }
    lines.push("rankings:".to_owned());
    for r in &report.rankings {
        let bid = report
            .plan_results
            .iter()
            .find(|p| p.name == r.name)
            .map(|p| p.branch_id.clone())
            .unwrap_or_default();
        lines.push(format!(
            "  - {} [{}] score={:.4} overlap={:.4} mrr={:.4}",
            r.name, bid, r.combined_score, r.recall_overlap, r.mean_reciprocal_rank
        ));
    }
    lines.push("disqualified:".to_owned());
    for d in &report.disqualified {
        let bid = report
            .plan_results
            .iter()
            .find(|p| p.name == d.name)
            .map(|p| p.branch_id.clone())
            .unwrap_or_default();
        lines.push(format!(
            "  - {} [{}] lost: {}",
            d.name,
            bid,
            d.lost_concepts.join(", ")
        ));
    }
    lines.push(String::new());
    lines.push(format!(
        "To promote, call {} with winnerBranchID, discardBranchIDs (the other ranking ids), and disqualifiedBranchIDs from above.",
        "moot_confirm_migration"
    ));
    Ok(text_result(&lines.join("\n")))
}

// ---------------------------------------------------------------------------
// moot_confirm_migration_promotion
// ---------------------------------------------------------------------------

fn run_confirm_promotion_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // Parse winnerBranchID — required UUID string. Missing or malformed →
    // invalidParams (transport-level fault, mirrors server's existing pattern).
    let winner_str = require_string(args, "winnerBranchID")?;
    let winner_bid: BranchId = Uuid::parse_str(winner_str).map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Malformed winnerBranchID (not a UUID): {winner_str}"),
        )
    })?;

    // Parse optional discardBranchIDs — array of UUID strings; malformed
    // element → invalidParams.
    let discard_bids = parse_uuid_array(args, "discardBranchIDs")?;

    // Parse optional disqualifiedBranchIDs — same shape.
    let disqualified_bids = parse_uuid_array(args, "disqualifiedBranchIDs")?;

    // Resolve estate — absent estateID → default estate (v1 single-estate path).
    let estate = registry.resolve(args, "estateID")?;
    let now = crate::dispatch::wall_now();
    let mut coord = estate.coord.lock().unwrap();

    // Dispatch the by-id overload. RecipeError results surface as isError:true
    // tool results (lens-refusal discipline: call id kept). Substrate errors
    // surface as tool errors too — the coordinator failure detail is informative.
    match cognition_kit::migration_live::confirm_migration_promotion_by_id(
        &mut coord,
        winner_bid,
        &discard_bids,
        &disqualified_bids,
        &estate.handle,
        now,
    ) {
        Ok(()) => {
            // Mirror the Swift server's success text shape.
            let body = format!(
                "confirm_migration: promoted {}; discarded {} branch(es).",
                winner_str,
                discard_bids
                    .iter()
                    .filter(|&&bid| bid != winner_bid)
                    .count(),
            );
            Ok(text_result(&body))
        }
        // RecipeError results (SilentConceptLoss, UserConfirmationRequired) and
        // substrate errors surface as isError:true so the client keeps the call id.
        Err(e) => Ok(error_result(&format!("{e}"))),
    }
}

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
/// trace rows are written. The write path (`EstateDreamingSink`) only calls
/// `store.add_proposal` and `store.add_diary_entry`. The `recall_scored` path
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
fn run_dream_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    use neuron_kit::{
        dreaming_cycle::{DreamingDaemon, DreamingPolicy, RecallTraceRewardSource},
        EstateDreamingReader, EstateDreamingSink,
    };

    // Resolve estate — absent estateID → default estate.
    let estate = registry.resolve(args, "estateID")?;

    // Deterministic `now` when supplied; otherwise the wall clock. A malformed
    // ISO8601 instant is an out-of-band client error (invalidParams), NOT a
    // silent fallback — mirroring Swift's identical check.
    let now_epoch_secs: i64 = if let Some(raw) = optional_string(args, "now")? {
        parse_iso8601_to_epoch(raw).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("now is not a valid ISO8601 instant: {raw}"),
            )
        })?
    } else {
        crate::dispatch::wall_now()
    };

    // Step 1 — Matrix rebuild.
    // Feed the estate's unified audit log and rebuild the recall-scoring
    // MatrixTier from it, registering the tier on the coordinator's per-estate
    // map. The Rust parity of the Swift handler's
    // `kit.rebuildDerivedAccelerators(for:)`. The mutable borrow ends before the
    // dreaming reader takes its immutable borrow below.
    let now_iso = epoch_to_iso8601(now_epoch_secs);
    let mut coord = estate.coord.lock().unwrap();
    coord
        .rebuild_derived_accelerators(&estate.handle)
        .map_err(|e| {
            JSONRPCError::new(
                JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                format!("dream: matrix rebuild failed: {e:?}"),
            )
        })?;

    // Step 2 — One dreaming cycle over the live estate seams.
    // EstateDreamingReader snapshots the three reads (recall traces, co-occurrence
    // observations, existing tunnels) from the estate at construction time.
    // The since/now window uses the injected epoch as both bounds (single-instant
    // window), consistent with the B-10a contract: no recall-scored call is made.
    let reader =
        EstateDreamingReader::new(&coord, &estate.handle, &now_iso, &now_iso).map_err(|e| {
            JSONRPCError::new(
                JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                format!("dream: failed to snapshot estate seams: {e:?}"),
            )
        })?;

    // EstateDreamingSink writes proposals and diary entries through DrawerStore
    // directly — no GLK coordinator involvement, no recall-scored calls, no
    // trace-row writes. This is the B-10a write path (internal-origin proof).
    let mut sink = EstateDreamingSink::new(Arc::clone(&estate.store), now_epoch_secs);

    let reward = RecallTraceRewardSource;
    let policy = DreamingPolicy::default();
    let mut daemon = DreamingDaemon::new(policy);

    // run_cycle is synchronous and deterministic: now_epoch_secs is the only
    // clock input; no SystemTime::now() is called inside.
    let report = daemon.run_cycle(now_epoch_secs as f64, &reader, &reward, &mut sink);

    // Propagate any sink write errors as advisory text — the cycle itself
    // completed; individual write failures should not abort the result.
    let write_warn = if sink.write_errors.is_empty() {
        String::new()
    } else {
        format!("\nwrite_warnings: {}", sink.write_errors.join("; "))
    };

    let body = format!(
        "moot_dream: matrix rebuild complete\ndreaming cycle complete\nconsideredCandidates: {}\nproposalsEmitted: {}\nsuppressedDuplicates: {}\nbelowThreshold: {}{}",
        report.candidates_considered,
        report.proposals_emitted.len(),
        report.suppressed_duplicates,
        report.below_threshold,
        write_warn,
    );
    Ok(text_result(&body))
}

/// Parse an ISO8601 UTC instant string (e.g. "2026-06-11T00:00:00Z") to Unix
/// epoch seconds. Returns `None` for any malformed or out-of-range input.
///
/// Supports the two formats the substrate uses:
///   - `YYYY-MM-DDTHH:MM:SSZ`          (no fractional seconds)
///   - `YYYY-MM-DDTHH:MM:SS.sssZ`      (fractional seconds, up to milliseconds)
///
/// Does NOT support timezone offsets — only the `Z` (UTC) suffix, matching the
/// ISO8601 instants the substrate stores and the Swift `ISO8601DateFormatter`
/// default format. Mirrors the Swift parse in `RecipeTools.runDream`.
fn parse_iso8601_to_epoch(s: &str) -> Option<i64> {
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

    Some(days_since_epoch * 86_400 + hour * 3600 + min * 60 + sec)
}

/// Format Unix epoch seconds as `YYYY-MM-DDTHH:MM:SSZ`.
///
/// Used to construct the `since`/`now` ISO8601 bounds for `EstateDreamingReader::new`.
/// Delegates to the `neuron_kit::topology_analysis::epoch_to_iso8601` helper which
/// is the conformance-tested Rust implementation of this conversion.
fn epoch_to_iso8601(epoch_secs: i64) -> String {
    neuron_kit::topology_analysis::epoch_to_iso8601(epoch_secs)
}

/// Parse an optional array of UUID strings from `args[key]`.
/// Absent key → empty vec. Malformed element → invalidParams.
fn parse_uuid_array(
    args: &BTreeMap<String, JsonValue>,
    key: &str,
) -> Result<Vec<BranchId>, JSONRPCError> {
    let Some(val) = args.get(key) else {
        return Ok(vec![]);
    };
    let arr = val.as_array().ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{key} must be an array of UUID strings"),
        )
    })?;
    arr.iter()
        .map(|v| {
            let s = v.as_str().ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!("each element of {key} must be a UUID string"),
                )
            })?;
            Uuid::parse_str(s).map_err(|_| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!("Malformed UUID in {key}: {s}"),
                )
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Argument decoders
// ---------------------------------------------------------------------------

fn decode_plans(args: &BTreeMap<String, JsonValue>) -> Result<Vec<PlanInput>, JSONRPCError> {
    let arr = args
        .get("plans")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
            JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, "plans must be an array")
        })?;
    arr.iter()
        .map(|element| {
            let obj = element.as_object().ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each plan must be an object",
                )
            })?;
            let name = obj.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
                JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, "each plan needs name")
            })?;
            let room = obj.get("room").and_then(|v| v.as_str()).ok_or_else(|| {
                JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, "each plan needs room")
            })?;
            let code = obj
                .get("latticeCode")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INVALID_PARAMS,
                        "each plan needs latticeCode",
                    )
                })?;
            let model = obj
                .get("embeddingModelID")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    JSONRPCError::new(
                        JSONRPCErrorCode::INVALID_PARAMS,
                        "each plan needs embeddingModelID",
                    )
                })?;
            let sensitivity = decode_sensitivity(obj.get("sensitivity"))?;
            Ok(PlanInput {
                name: name.to_owned(),
                room: room.to_owned(),
                lattice_code: code.to_owned(),
                embedding_model_id: model.to_owned(),
                sensitivity,
            })
        })
        .collect()
}

fn optional_string_value<'a>(
    value: Option<&'a JsonValue>,
    key: &str,
) -> Result<Option<&'a str>, JSONRPCError> {
    match value {
        None => Ok(None),
        Some(JsonValue::String(s)) => Ok(Some(s.as_str())),
        Some(_) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("{key} must be a string; omit it to use the default"),
        )),
    }
}

fn decode_sensitivity(value: Option<&JsonValue>) -> Result<i64, JSONRPCError> {
    match optional_string_value(value, "sensitivity")? {
        None | Some("normal") => Ok(AdjectiveSensitivity::Normal.raw_value()),
        Some("elevated") => Ok(AdjectiveSensitivity::Elevated.raw_value()),
        Some("restricted") => Ok(AdjectiveSensitivity::Restricted.raw_value()),
        Some("secret") => Ok(AdjectiveSensitivity::Secret.raw_value()),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown sensitivity: {unknown}"),
        )),
    }
}

/// `run_precise_recall` currently accepts a single filter entry. Omitted
/// filter uses the same active-recall default as an empty chain without adding
/// a confirmation constraint.
fn decode_precise_filter(args: &BTreeMap<String, JsonValue>) -> Result<Filter, JSONRPCError> {
    match optional_string(args, "filter")? {
        None => Ok(Filter::CurrentlyBelieve),
        Some("unconfirmed") => Ok(Filter::Unconfirmed),
        Some("userConfirmed") => Ok(Filter::UserConfirmed),
        Some("exportable") => Ok(Filter::Exportable),
        Some("contained") => Ok(Filter::Contained),
        Some("currentlyBelieve") => Ok(Filter::CurrentlyBelieve),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown filter: {unknown}"),
        )),
    }
}

/// Convert a `RecipeRunError` to a `JSONRPCError` for out-of-band recipe
/// failures. Recipe-level refusals (RecipeError) that are "expected" errors
/// should be converted to `error_result` by the caller instead — this is
/// for genuine substrate failures.
fn error_from_recipe(e: cognition_kit::RecipeRunError) -> JSONRPCError {
    JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
}
