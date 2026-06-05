//! CognitionKit recipe tool surface — moot_list_lenses, moot_synthesize,
//! moot_run_migration, moot_confirm_migration.
//!
//! Mirrors Swift `RecipeTools.swift`. Same dispatch contract: out-of-band faults
//! throw `JSONRPCError`; recipe-level refusals come back as `error_result` (isError
//! true) so the client keeps the call id.
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

use cognition_kit::{recipe_catalog, run_grounded_synthesis, OriginEntry, PlanInput};
use genius_locus_kit::branches::BranchId;
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use neuron_kit::RecallFrameTuning;
use uuid::Uuid;

use crate::dispatch::{error_result, require_string, text_result};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Recipe tool names — mirrors Swift `RecipeTools` static constants.
const LIST_LENSES: &str = "moot_list_lenses";
const SYNTHESIZE: &str = "moot_synthesize";
const RUN_MIGRATION: &str = "moot_run_migration";
const CONFIRM_MIGRATION: &str = "moot_confirm_migration";

/// True when `name` is one of the recipe tools.
pub fn is_recipe_tool(name: &str) -> bool {
    matches!(
        name,
        LIST_LENSES | SYNTHESIZE | RUN_MIGRATION | CONFIRM_MIGRATION
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
        SYNTHESIZE => run_grounded_synthesis_tool(args, registry),
        RUN_MIGRATION => run_migration_benchmark_tool(args, registry),
        CONFIRM_MIGRATION => run_confirm_promotion_tool(args, registry),
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
