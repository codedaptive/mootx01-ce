//! CognitionKit recipe tool surface — moot_list_recipes, moot_grounded_synthesis,
//! moot_run_migration_benchmark, moot_confirm_migration_promotion.
//!
//! Mirrors Swift `RecipeTools.swift`. Same dispatch contract: out-of-band faults
//! throw `JSONRPCError`; recipe-level refusals come back as `error_result` (isError
//! true) so the client keeps the call id.
//!
//! # moot_run_migration_benchmark
//!
//! Derives one COW branch per candidate plan, populates each from the origin corpus,
//! benchmarks recall fidelity with the zero-silent-loss gate, and returns a ranked
//! list of survivors. Never promotes. Returns branch ids in the result text so a
//! caller can pass them to the confirm tool.
//!
//! # moot_confirm_migration_promotion — v1 behavioral boundary
//!
//! The tool is advertised in tools/list and receives calls. It returns an
//! informational error_result (isError true) explaining the v1 boundary:
//! `confirm_migration_promotion` requires the live `CoreReport` produced by
//! `run_migration_benchmark`; the stateless server cannot retain that object
//! across tool calls. The README documents this gap as a v1 behavioral fact.
//! Persistent session state (needed to bridge run→confirm without re-running the
//! benchmark) is out of scope for v1.

use std::collections::BTreeMap;

use cognition_kit::{recipe_catalog, run_grounded_synthesis, OriginEntry, PlanInput};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use neuron_kit::RecallFrameTuning;

use crate::dispatch::{error_result, require_string, text_result};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Recipe tool names — mirrors Swift `RecipeTools` static constants.
const LIST_RECIPES: &str = "moot_list_recipes";
const GROUNDED_SYNTHESIS: &str = "moot_grounded_synthesis";
const RUN_MIGRATION_BENCHMARK: &str = "moot_run_migration_benchmark";
const CONFIRM_MIGRATION_PROMOTION: &str = "moot_confirm_migration_promotion";

/// True when `name` is one of the recipe tools.
pub fn is_recipe_tool(name: &str) -> bool {
    matches!(
        name,
        LIST_RECIPES | GROUNDED_SYNTHESIS | RUN_MIGRATION_BENCHMARK | CONFIRM_MIGRATION_PROMOTION
    )
}

/// Dispatch a recipe tool call. Same contract as `dispatch_tool`.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        LIST_RECIPES => Ok(run_list_recipes()),
        GROUNDED_SYNTHESIS => run_grounded_synthesis_tool(args, registry),
        RUN_MIGRATION_BENCHMARK => run_migration_benchmark_tool(args, registry),
        CONFIRM_MIGRATION_PROMOTION => run_confirm_promotion_tool(args, registry),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown recipe tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// moot_list_recipes
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
// moot_grounded_synthesis
// ---------------------------------------------------------------------------

fn run_grounded_synthesis_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let filter = decode_recipe_filter(args);
    let limit = args
        .get("limit")
        .and_then(|v| v.as_i64())
        .map(|i| i as usize);

    let mut frame = RecallFrame::new(vec![filter]);
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
// moot_run_migration_benchmark
// ---------------------------------------------------------------------------

fn run_migration_benchmark_tool(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let corpus_name = require_string(args, "corpusName")?;
    let entries = decode_entries(args)?;
    let plans = decode_plans(args)?;
    if plans.is_empty() {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "run_migration_benchmark requires at least one plan",
        ));
    }
    let origin: Vec<OriginEntry> = entries
        .into_iter()
        .map(|(id, content)| OriginEntry { id, content })
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
        "moot_confirm_migration_promotion"
    ));
    Ok(text_result(&lines.join("\n")))
}

// ---------------------------------------------------------------------------
// moot_confirm_migration_promotion — v1 gap
// ---------------------------------------------------------------------------

fn run_confirm_promotion_tool(
    _args: &BTreeMap<String, JsonValue>,
    _registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // v1 behavioral gap: confirm_migration_promotion requires the CoreReport
    // produced by run_migration_benchmark. The server is stateless across
    // tool calls so the report cannot be retained between the run and confirm
    // calls without session state. Persistent session state is a v2 feature.
    //
    // The tool is advertised in tools/list so agents can discover it; calling
    // it returns this informational error_result. The README documents this
    // gap plainly as a v1 boundary fact.
    Ok(error_result(
        "moot_confirm_migration_promotion: v1 behavioral boundary — the confirm step requires \
        the CoreReport produced by moot_run_migration_benchmark, which the stateless server cannot \
        retain across tool calls. Persistent session state (required to bridge run→confirm) is a \
        v2 feature. See the README for the full v1 boundary description.",
    ))
}

// ---------------------------------------------------------------------------
// Argument decoders
// ---------------------------------------------------------------------------

fn decode_entries(
    args: &BTreeMap<String, JsonValue>,
) -> Result<Vec<(String, String)>, JSONRPCError> {
    let arr = args
        .get("entries")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
            JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, "entries must be an array")
        })?;
    arr.iter()
        .map(|element| {
            let obj = element.as_object().ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each entry must be an object",
                )
            })?;
            let id = obj.get("id").and_then(|v| v.as_str()).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each entry needs string id",
                )
            })?;
            let content = obj.get("content").and_then(|v| v.as_str()).ok_or_else(|| {
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    "each entry needs string content",
                )
            })?;
            Ok((id.to_owned(), content.to_owned()))
        })
        .collect()
}

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
            let sensitivity = decode_sensitivity(obj.get("sensitivity").and_then(|v| v.as_str()));
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

fn decode_sensitivity(name: Option<&str>) -> i64 {
    match name {
        Some("elevated") => AdjectiveSensitivity::Elevated.raw_value(),
        Some("restricted") => AdjectiveSensitivity::Restricted.raw_value(),
        Some("secret") => AdjectiveSensitivity::Secret.raw_value(),
        _ => AdjectiveSensitivity::Normal.raw_value(),
    }
}

/// Decode the recall filter for recipe tools. Mirrors Swift
/// `RecipeTools.decodeFilter(_:)` — defaults to Unconfirmed so freshly-
/// captured rows are visible.
fn decode_recipe_filter(args: &BTreeMap<String, JsonValue>) -> Filter {
    match args.get("filter").and_then(|v| v.as_str()) {
        Some("userConfirmed") => Filter::UserConfirmed,
        Some("exportable") => Filter::Exportable,
        Some("contained") => Filter::Contained,
        Some("currentlyBelieve") => Filter::CurrentlyBelieve,
        _ => Filter::Unconfirmed,
    }
}

/// Convert a `RecipeRunError` to a `JSONRPCError` for out-of-band recipe
/// failures. Recipe-level refusals (RecipeError) that are "expected" errors
/// should be converted to `error_result` by the caller instead — this is
/// for genuine substrate failures.
fn error_from_recipe(e: cognition_kit::RecipeRunError) -> JSONRPCError {
    JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
}
