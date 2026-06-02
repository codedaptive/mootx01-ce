//! Tool list projection — builds the `tools/list` response body.
//!
//! Mirrors the Swift `ToolProjection.tools()` + `RecipeTools.tools()` +
//! `LensTools.tools()` composition. The Rust server does not have a
//! lexicon-projection loop (the full lexicon surface is a v2 item — see
//! README); v1 ships the capture/recall lexicon minimum (Part 5) plus all
//! recipe and lens tools.
//!
//! Tool names, descriptions, and inputSchema fields are wire-identical to
//! the Swift server for every tool that appears in both. The catalog
//! descriptions for the lens tools come directly from `recipe_catalog()` so
//! they stay in lockstep with the Swift catalog's byte-identical strings.
//!
//! # Tool ordering
//!
//! moot_list_recipes, then the 14 lens tools (catalog order), then the
//! 2 foundational recipe tools (grounded_synthesis, run_migration_benchmark,
//! confirm_migration_promotion), then the v1 lexicon minimum
//! (moot_capture_drawer, moot_drawer_recall, moot_capture_tunnel).

use serde_json::json;

/// Build the full `tools/list` tool array as a `serde_json::Value`.
/// Called once at startup and cached in `Dispatcher`.
pub fn build_tool_list() -> serde_json::Value {
    let mut tools = Vec::new();

    // 1. Recipe discovery.
    tools.push(list_recipes_tool());

    // 2. The 14 reasoning-lens tools — descriptions from the catalog.
    for desc in cognition_kit::recipe_catalog() {
        // The 2 foundational recipes appear in the catalog but get their own
        // dedicated tools below with richer descriptions. Skip them here.
        if desc.name == "grounded_synthesis" || desc.name == "migration_benchmark" {
            continue;
        }
        tools.push(lens_tool_from_catalog(&desc.name, &desc.description));
    }

    // 3. Foundational recipe tools.
    tools.push(grounded_synthesis_tool());
    tools.push(run_migration_benchmark_tool());
    tools.push(confirm_migration_promotion_tool());

    // 4. v1 lexicon minimum.
    tools.push(capture_drawer_tool());
    tools.push(recall_drawer_tool());
    tools.push(capture_tunnel_tool());

    json!(tools)
}

// ---------------------------------------------------------------------------
// Recipe discovery tool
// ---------------------------------------------------------------------------

fn list_recipes_tool() -> serde_json::Value {
    json!({
        "name": "moot_list_recipes",
        "description": "List the available CognitionKit behaviour recipes — each with its version, description, and the NeuronKit capabilities it requires.",
        "inputSchema": object_schema(serde_json::json!({}), serde_json::json!([]))
    })
}

// ---------------------------------------------------------------------------
// Lens tools — descriptions from catalog (byte-identical to Swift)
// ---------------------------------------------------------------------------

fn lens_tool_from_catalog(name: &str, catalog_description: &str) -> serde_json::Value {
    let tool_name = format!("moot_{name}");
    let schema = lens_input_schema(&tool_name);
    json!({
        "name": tool_name,
        "description": catalog_description,
        "inputSchema": schema
    })
}

/// Per-lens input schemas — mirror Swift `LensTools.tools()` property lists.
fn lens_input_schema(tool_name: &str) -> serde_json::Value {
    let estate_id =
        string_schema("Optional UUID of the open estate to target. Omit for the default estate.");
    let filter_schema = string_schema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve.");
    match tool_name {
        "moot_keystones" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnel graph to read."),
                "topK": integer_schema("How many keystones to return (default 5)."),
                "estateID": estate_id
            }),
            json!(["wing"]),
        ),
        "moot_constellation" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnel graph to read."),
                "estateID": estate_id
            }),
            json!(["wing"]),
        ),
        "moot_free_association" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnel graph to walk."),
                "seedDrawerID": string_schema("The drawer id to associate from."),
                "walkLength": integer_schema("Walk steps (default 10000)."),
                "k": integer_schema("How many associations to return (default 10)."),
                "estateID": estate_id
            }),
            json!(["wing", "seedDrawerID"]),
        ),
        "moot_theme_weather" => object_schema(
            json!({
                "filter": filter_schema,
                "halfLifeSeconds": number_schema("Attention half-life in seconds (default 604800 = 7 days)."),
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_latent_themes" => object_schema(
            json!({
                "filter": filter_schema,
                "k": integer_schema("How many themes to factor (default 3)."),
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_bias" => object_schema(
            json!({
                "reference": {
                    "type": "array",
                    "description": "Reference distribution: objects with string label and number mass. Empty = report estate shares alone.",
                    "items": object_schema(
                        json!({
                            "label": string_schema("Room / category label."),
                            "mass": number_schema("Reference mass for the label.")
                        }),
                        json!(["label", "mass"])
                    )
                },
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_drift" => object_schema(
            json!({
                "splitAt": string_schema("ISO8601 instant splitting the before/after windows."),
                "filter": filter_schema,
                "estateID": estate_id
            }),
            json!(["splitAt"]),
        ),
        "moot_contradiction" => object_schema(
            json!({
                "threshold": number_schema("Z-score magnitude threshold (default 1.5)."),
                "filter": filter_schema,
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_trust_grounded_synthesis" => object_schema(
            json!({
                "filter": filter_schema,
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_partial_cue_recall" => object_schema(
            json!({
                "anchorID": string_schema("The anchor drawer id (the cue)."),
                "mode": string_schema("Cue mode: feelsLike (default), aboutThis, fromThen."),
                "k": integer_schema("How many matches to return (default 5)."),
                "filter": filter_schema,
                "estateID": estate_id
            }),
            json!(["anchorID"]),
        ),
        "moot_anticipate" => object_schema(
            json!({
                "targetKind": string_schema("Target outcome as a content kind: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly."),
                "k": integer_schema("How many actions to return (default 5)."),
                "minObservations": integer_schema("Minimum observations per action (default 1)."),
                "filter": filter_schema,
                "estateID": estate_id
            }),
            json!(["targetKind"]),
        ),
        "moot_tunnel_successor" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnels to read."),
                "anchorID": string_schema("The anchor drawer id."),
                "k": integer_schema("How many successors to return (default 5)."),
                "estateID": estate_id
            }),
            json!(["wing", "anchorID"]),
        ),
        "moot_mind_overlap" => object_schema(
            json!({
                "estateID": string_schema("Optional UUID of estate A. Omit for the default estate."),
                "estateIDB": string_schema("UUID of estate B (must be a registered open estate)."),
                "filter": filter_schema
            }),
            json!(["estateIDB"]),
        ),
        "moot_estate_divergence" => object_schema(
            json!({
                "estateID": string_schema("Optional UUID of estate A. Omit for the default estate."),
                "estateIDB": string_schema("UUID of estate B (must be a registered open estate)."),
                "filter": filter_schema
            }),
            json!(["estateIDB"]),
        ),
        _ => object_schema(json!({}), json!([])),
    }
}

// ---------------------------------------------------------------------------
// Foundational recipe tools
// ---------------------------------------------------------------------------

fn grounded_synthesis_tool() -> serde_json::Value {
    json!({
        "name": "moot_grounded_synthesis",
        "description": "Behaviour recipe: hybrid-recall a query and synthesize the recalled drawers into a single grounded context document (summary, patterns, success rate, recommendations, key insights).",
        "inputSchema": object_schema(
            json!({
                "filter": string_schema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve."),
                "limit": integer_schema("Max drawers to recall."),
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!([])
        )
    })
}

fn run_migration_benchmark_tool() -> serde_json::Value {
    json!({
        "name": "moot_run_migration_benchmark",
        "description": "Behaviour recipe: derive one COW branch per migration plan, populate each from the origin corpus, benchmark recall fidelity with the zero-silent-loss gate, and rank survivors. Never promotes — returns branch ids for a separate confirm step.",
        "inputSchema": object_schema(
            json!({
                "corpusName": string_schema("Human-readable name for the origin corpus."),
                "entries": {
                    "type": "array",
                    "description": "Origin entries: objects with string fields id, content, and a string-array field tags.",
                    "items": object_schema(
                        json!({
                            "id": string_schema("Stable source id."),
                            "content": string_schema("Verbatim content."),
                            "tags": { "type": "array", "items": { "type": "string" } }
                        }),
                        json!(["id", "content"])
                    )
                },
                "plans": {
                    "type": "array",
                    "description": "Candidate plans: objects with string fields name, room, latticeCode, embeddingModelID, and optional sensitivity.",
                    "items": object_schema(
                        json!({
                            "name": string_schema("Plan name (also the branch name)."),
                            "room": string_schema("Room every migrated drawer is filed into."),
                            "latticeCode": string_schema("UDC lattice code for every migrated drawer."),
                            "embeddingModelID": string_schema("Embedding model id tagged on every drawer."),
                            "sensitivity": string_schema("Optional sensitivity tier; default normal.")
                        }),
                        json!(["name", "room", "latticeCode", "embeddingModelID"])
                    )
                },
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!(["corpusName", "entries", "plans"])
        )
    })
}

fn confirm_migration_promotion_tool() -> serde_json::Value {
    json!({
        "name": "moot_confirm_migration_promotion",
        "description": "Behaviour recipe (human-confirmed write): promote a migration-benchmark winner branch into the estate and discard the losers, by branch id. Refuses to promote a branch the run report disqualified.",
        "inputSchema": object_schema(
            json!({
                "winnerBranchID": string_schema("UUID of the winning branch to promote (from the run report)."),
                "discardBranchIDs": {
                    "type": "array",
                    "description": "UUIDs of losing branches to discard.",
                    "items": { "type": "string" }
                },
                "disqualifiedBranchIDs": {
                    "type": "array",
                    "description": "UUIDs the run report disqualified; the C-5 guard refuses to promote any of these.",
                    "items": { "type": "string" }
                },
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!(["winnerBranchID"])
        )
    })
}

// ---------------------------------------------------------------------------
// Lexicon minimum (v1 capture/recall surface)
// ---------------------------------------------------------------------------

fn capture_drawer_tool() -> serde_json::Value {
    json!({
        "name": "moot_capture_drawer",
        "description": "File a new drawer into the estate.",
        "inputSchema": object_schema(
            json!({
                "content": string_schema("Verbatim content to file."),
                "room": string_schema("Room within the estate."),
                // The anchor code is interpreted under classificationScheme below.
                // The arg name stays udcCode for wire compatibility; renaming it is
                // a separate storage migration (§5.8 dual-scheme model), out of scope here.
                "udcCode": string_schema("Lattice anchor classification code (e.g. \"000.000\"), interpreted under classificationScheme."),
                "classificationScheme": string_schema("Optional classification scheme for the anchor code: \"udc\" (default) or \"mdcc\". Omitting it preserves UDC behavior."),
                "addedBy": string_schema("Actor identifier filed with the row."),
                "embeddingModelID": string_schema("Embedding model the row tags vectors with."),
                "channel": string_schema("Capture channel: typed, voiced, ocr, importedFile, sensor."),
                "sensitivity": string_schema("Sensitivity tier: normal, elevated, restricted, secret."),
                "kind": string_schema("Content kind: prose, code, transcript, list, structuredJSON, imageCaption."),
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!(["content", "room", "udcCode", "addedBy", "embeddingModelID"])
        )
    })
}

fn recall_drawer_tool() -> serde_json::Value {
    json!({
        "name": "moot_drawer_recall",
        "description": "Read drawer rows back by filter.",
        "inputSchema": object_schema(
            json!({
                "filter": string_schema("Filter kind: unconfirmed, userConfirmed, exportable, contained."),
                "limit": integer_schema("Max rows to return."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly."),
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!([])
        )
    })
}

fn capture_tunnel_tool() -> serde_json::Value {
    json!({
        "name": "moot_capture_tunnel",
        "description": "File a new tunnel (directed graph edge) into the estate.",
        "inputSchema": object_schema(
            json!({
                "sourceWing": string_schema("Wing of the source drawer."),
                "sourceRoom": string_schema("Room of the source drawer."),
                "targetWing": string_schema("Wing of the target drawer."),
                "targetRoom": string_schema("Room of the target drawer."),
                "kind": string_schema("Tunnel kind: relates, precedes, contradicts, supports, refines, exemplifies, extends."),
                "addedBy": string_schema("Actor identifier filed with the tunnel."),
                "sourceDrawerID": string_schema("Optional source drawer id (drawer-to-drawer edge)."),
                "targetDrawerID": string_schema("Optional target drawer id."),
                "estateID": string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
            }),
            json!(["sourceWing", "sourceRoom", "targetWing", "targetRoom", "kind", "addedBy"])
        )
    })
}

// ---------------------------------------------------------------------------
// Schema builder helpers — mirror Swift ToolProjection schema helpers
// ---------------------------------------------------------------------------

fn object_schema(properties: serde_json::Value, required: serde_json::Value) -> serde_json::Value {
    let req_arr = required.as_array().unwrap_or(&vec![]).clone();
    if req_arr.is_empty() {
        json!({ "type": "object", "properties": properties })
    } else {
        json!({ "type": "object", "properties": properties, "required": req_arr })
    }
}

fn string_schema(description: &str) -> serde_json::Value {
    json!({ "type": "string", "description": description })
}

fn integer_schema(description: &str) -> serde_json::Value {
    json!({ "type": "integer", "description": description })
}

fn number_schema(description: &str) -> serde_json::Value {
    json!({ "type": "number", "description": description })
}
