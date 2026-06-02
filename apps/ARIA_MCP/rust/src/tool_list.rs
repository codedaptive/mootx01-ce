//! Tool list projection — builds the `tools/list` response body.
//!
//! Mirrors the Swift `ToolProjection.tools()` + `RecipeTools.tools()` +
//! `LensTools.tools()` composition. Lexicon tools are now built from a
//! programmatic (verb × noun) matrix loop, mirroring the shape of
//! `ToolProjection.tools()` in Swift — outer loop over nouns in
//! `Noun.allCases` order, inner loop over verbs in `Verb.allCases` order,
//! keeping only pairs the acceptance matrix accepts and that are
//! caller-surfaced (verb.flow != substrateDriven, matching
//! `ToolProjection.surfaces(_:)`). Per-verb schema builders (`lexicon_schema`)
//! mirror `ToolProjection.inputSchema(verb:noun:)`.
//!
//! The recipe/lens tools append after the lexicon loop, unchanged.
//!
//! Wire identity: tool names, descriptions, and inputSchema key names are
//! byte-identical to the Swift server for every matching tool. The
//! `estateID` optional field is added to every lexicon tool schema via
//! `with_estate_id`, mirroring `ToolProjection.withEstateID(_:)`.
//!
//! # Acceptance matrix (AriaLexicon.Acceptance.verbs(for:))
//!
//! | Noun             | Accepted + surfaced verbs (excludes propose, associate) |
//! |------------------|----------------------------------------------------------|
//! | drawer           | capture, reanchor, mutate, withdraw, expunge, recall     |
//! | tunnel           | capture, mutate, withdraw, expunge, recall               |
//! | kgFact           | mutate, withdraw, expunge, recall                       |
//! | vector           | (none)                                                  |
//! | diaryEntry       | recall                                                  |
//! | proposal         | mutate, withdraw, expunge, recall                       |
//! | association      | mutate, expunge, recall                                 |
//! | learnedReference | learn, mutate, withdraw, expunge, recall                |
//!
//! # Tool naming convention (ToolProjection.toolName(verb:noun:))
//!
//! - recall verb → `moot_{noun}_recall`  (noun_verb form; recall is the read verb)
//! - every other surfaced verb → `moot_{verb}_{noun}` (verb_noun form)
//!
//! # Ordering (49 tools after v2b-p2)
//!
//! moot_list_recipes, then 16 lens tools in catalog order (14 reasoning + 2 analytics),
//! then 3 foundational recipe tools (grounded_synthesis, run_migration_benchmark,
//! confirm_migration_promotion), then the lexicon projection loop (28 tools,
//! outer noun in allCases order, inner verb in allCases order, accepted +
//! surfaced only), then moot_cross_estate_recall.

use serde_json::json;

// ---------------------------------------------------------------------------
// Lexicon vocabulary constants (mirrors AriaLexicon Noun + Verb allCases)
// ---------------------------------------------------------------------------

/// Nouns in `Noun.allCases` declaration order. Mirrors Swift `Noun.swift`.
/// Vector is included but accepts no surfaced verbs, so it produces no tools.
const NOUNS: &[Noun] = &[
    Noun::Drawer,
    Noun::Tunnel,
    Noun::KgFact,
    Noun::Vector,
    Noun::DiaryEntry,
    Noun::Proposal,
    Noun::Association,
    Noun::LearnedReference,
];

/// Verbs in `Verb.allCases` declaration order. Mirrors Swift `Verb.swift`.
/// Propose and associate are substrate-driven and excluded by `is_surfaced`.
const VERBS: &[Verb] = &[
    Verb::Capture,
    Verb::Reanchor,
    Verb::Mutate,
    Verb::Withdraw,
    Verb::Expunge,
    Verb::Recall,
    Verb::Propose,
    Verb::Associate,
    Verb::Learn,
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Noun {
    Drawer,
    Tunnel,
    KgFact,
    Vector,
    DiaryEntry,
    Proposal,
    Association,
    LearnedReference,
}

impl Noun {
    /// Wire-format noun name — matches Swift `Noun.rawValue` exactly.
    fn raw_value(self) -> &'static str {
        match self {
            Noun::Drawer => "drawer",
            Noun::Tunnel => "tunnel",
            Noun::KgFact => "kgFact",
            Noun::Vector => "vector",
            Noun::DiaryEntry => "diaryEntry",
            Noun::Proposal => "proposal",
            Noun::Association => "association",
            Noun::LearnedReference => "learnedReference",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Verb {
    Capture,
    Reanchor,
    Mutate,
    Withdraw,
    Expunge,
    Recall,
    Propose,
    Associate,
    Learn,
}

impl Verb {
    /// Wire-format verb name — matches Swift `Verb.rawValue` exactly.
    fn raw_value(self) -> &'static str {
        match self {
            Verb::Capture => "capture",
            Verb::Reanchor => "reanchor",
            Verb::Mutate => "mutate",
            Verb::Withdraw => "withdraw",
            Verb::Expunge => "expunge",
            Verb::Recall => "recall",
            Verb::Propose => "propose",
            Verb::Associate => "associate",
            Verb::Learn => "learn",
        }
    }

    /// Whether this verb participates in the MCP tool surface.
    /// Propose and associate are substrate-driven and surface as notifications,
    /// not callable tools. Mirrors `ToolProjection.surfaces(_:)` in Swift.
    fn is_surfaced(self) -> bool {
        !matches!(self, Verb::Propose | Verb::Associate)
    }
}

/// Whether `noun` accepts `verb`. Mirrors `AriaLexicon.Acceptance.accepts(_:_:)`.
/// Inline data — same closed sets as Swift `Acceptance.verbs(for:)`.
fn accepts(noun: Noun, verb: Verb) -> bool {
    match noun {
        Noun::Drawer => matches!(
            verb,
            Verb::Capture
                | Verb::Reanchor
                | Verb::Mutate
                | Verb::Withdraw
                | Verb::Expunge
                | Verb::Recall
        ),
        Noun::Tunnel => matches!(
            verb,
            Verb::Capture | Verb::Mutate | Verb::Withdraw | Verb::Expunge | Verb::Recall
        ),
        Noun::KgFact => matches!(
            verb,
            Verb::Mutate | Verb::Withdraw | Verb::Expunge | Verb::Recall
        ),
        Noun::Vector => false,
        Noun::DiaryEntry => matches!(verb, Verb::Recall),
        Noun::Proposal => matches!(
            verb,
            Verb::Mutate | Verb::Withdraw | Verb::Expunge | Verb::Recall
        ),
        Noun::Association => matches!(verb, Verb::Mutate | Verb::Expunge | Verb::Recall),
        Noun::LearnedReference => matches!(
            verb,
            Verb::Learn | Verb::Mutate | Verb::Withdraw | Verb::Expunge | Verb::Recall
        ),
    }
}

/// MCP tool name for a (verb, noun) pair. Mirrors `ToolProjection.toolName(verb:noun:)`:
/// recall is the query verb (noun_verb form); every other surfaced verb is an action
/// (verb_noun form). The `moot_` namespace prefix marks the tool surface as MOOTx01's.
fn tool_name(verb: Verb, noun: Noun) -> String {
    if verb == Verb::Recall {
        format!("moot_{}_{}", noun.raw_value(), verb.raw_value())
    } else {
        format!("moot_{}_{}", verb.raw_value(), noun.raw_value())
    }
}

/// One-line description for a (verb, noun) tool. Mirrors `ToolProjection.description(verb:noun:)`.
///
/// Note: the v1 hand-written descriptor for capture/tunnel carried a
/// Rust-only "(directed graph edge)" qualifier that diverged from the
/// Swift template. Swift leads the wire, so this projection emits the
/// Swift string for every pair — that one description deliberately
/// changed when the projection replaced the hand-written functions.
fn tool_description(verb: Verb, noun: Noun) -> String {
    match verb {
        Verb::Capture => format!("File a new {} into the estate.", noun.raw_value()),
        Verb::Recall => format!("Read {} rows back by filter.", noun.raw_value()),
        Verb::Mutate => format!("Apply a named mutation to a {}.", noun.raw_value()),
        Verb::Withdraw => format!("Withdraw a {} from active circulation.", noun.raw_value()),
        Verb::Expunge => format!("Hard-erase a {} (irreversible).", noun.raw_value()),
        Verb::Reanchor => format!("Move where a {} sits in structure.", noun.raw_value()),
        Verb::Learn => format!("Ingest a canonical external {}.", noun.raw_value()),
        // Propose and associate do not surface — filtered before this call.
        Verb::Propose | Verb::Associate => {
            format!(
                "Substrate-driven verb on {} (not callable as a tool).",
                noun.raw_value()
            )
        }
    }
}

/// Build the per-verb input schema for a (verb, noun) tool. Mirrors
/// `ToolProjection.inputSchema(verb:noun:)` in Swift. The `estateID` optional
/// is added by `with_estate_id` after this call, matching `withEstateID(_:)`.
///
/// Schemas are intentionally minimal — they match the verb frame slot sets.
/// Required / optional split and field types are wire-identical to Swift.
fn lexicon_schema(verb: Verb, noun: Noun) -> serde_json::Value {
    match verb {
        Verb::Capture if noun == Noun::Drawer => object_schema(
            json!({
                "content": string_schema("Verbatim content to file."),
                "room": string_schema("Room within the estate."),
                // Arg name stays udcCode for wire compatibility; renaming it is a
                // separate storage migration (§5.8 dual-scheme model), out of scope here.
                "udcCode": string_schema("Lattice anchor classification code (e.g. \"000.000\"), interpreted under classificationScheme."),
                "classificationScheme": string_schema("Optional classification scheme for the anchor code: \"udc\" (default) or \"mdcc\". Omitting it preserves UDC behavior."),
                "addedBy": string_schema("Actor identifier filed with the row."),
                "embeddingModelID": string_schema("Embedding model the row tags vectors with."),
                "channel": string_schema("Capture channel: typed, voiced, ocr, importedFile, sensor."),
                "sensitivity": string_schema("Sensitivity tier: normal, elevated, restricted, secret."),
                "kind": string_schema("Content kind: prose, code, transcript, list, structuredJSON, imageCaption.")
            }),
            json!(["content", "room", "udcCode", "addedBy", "embeddingModelID"]),
        ),
        Verb::Capture if noun == Noun::Tunnel => object_schema(
            json!({
                "sourceWing": string_schema("Wing of the source drawer."),
                "sourceRoom": string_schema("Room of the source drawer."),
                "targetWing": string_schema("Wing of the target drawer."),
                "targetRoom": string_schema("Room of the target drawer."),
                "kind": string_schema("Tunnel kind: relates, precedes, contradicts, supports, refines, exemplifies, extends."),
                "addedBy": string_schema("Actor identifier filed with the tunnel."),
                "sourceDrawerID": string_schema("Optional source drawer id (drawer-to-drawer edge)."),
                "targetDrawerID": string_schema("Optional target drawer id.")
            }),
            json!([
                "sourceWing",
                "sourceRoom",
                "targetWing",
                "targetRoom",
                "kind",
                "addedBy"
            ]),
        ),
        // Recall schemas: the standard recall arguments (filter/limit/ordering/
        // hydrationLevel) match Swift ToolProjection.inputSchema(.recall, .drawer).
        // Noun-specific args (e.g. wing for tunnel_recall) are grounded in the
        // actual Rust coordinator interface because the Swift server has no live
        // handler for these tools and falls through to methodNotFound with an empty
        // schema. Flagged as Swift-side reconciliation items in the v2b-p2 report.
        Verb::Recall if noun == Noun::Drawer => object_schema(
            json!({
                "filter": string_schema("Filter kind: unconfirmed, userConfirmed, exportable, contained."),
                "limit": integer_schema("Max rows to return."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly.")
            }),
            json!([]),
        ),
        Verb::Recall if noun == Noun::Tunnel => object_schema(
            // wing is the graph partition argument the coordinator's recall_tunnels
            // requires. The Swift server advertises this tool but has no live handler;
            // schema is grounded in the Rust coordinator interface. (Swift reconciliation
            // item: wire Swift's schema to match once the Swift handler lands.)
            json!({
                "wing": string_schema("Wing to read outgoing tunnels from.")
            }),
            json!(["wing"]),
        ),
        Verb::Recall => object_schema(
            // Generic recall schema for kgFact, diaryEntry, proposal, association,
            // learnedReference. Swift has no live handler for these; schema is grounded
            // in the standard recall frame shape. (Swift reconciliation item per v2b-p2.)
            json!({
                "filter": string_schema("Filter kind: unconfirmed, userConfirmed, exportable, contained."),
                "limit": integer_schema("Max rows to return."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly.")
            }),
            json!([]),
        ),
        Verb::Mutate => object_schema(
            json!({
                "rowID": string_schema(format!("Row identifier of the {}.", noun.raw_value()).as_str()),
                "kind": string_schema("Mutation kind: confirm, reject, contest, resolve, supersede, revive, accept."),
                "payload": string_schema("Optional free-text payload.")
            }),
            json!(["rowID", "kind"]),
        ),
        Verb::Withdraw => object_schema(
            json!({
                "rowID": string_schema(format!("Row identifier of the {}.", noun.raw_value()).as_str()),
                "reason": string_schema("Optional free-text justification.")
            }),
            json!(["rowID"]),
        ),
        Verb::Expunge => object_schema(
            json!({
                "rowID": string_schema(format!("Row identifier of the {}.", noun.raw_value()).as_str()),
                "reason": string_schema("Required free-text justification."),
                "confirmation": boolean_schema("Must be true; expunge is irreversible.")
            }),
            json!(["rowID", "reason", "confirmation"]),
        ),
        Verb::Reanchor => object_schema(
            json!({
                "rowID": string_schema(format!("Row identifier of the {}.", noun.raw_value()).as_str()),
                "toRoom": string_schema("Optional target room."),
                "toUDC": string_schema("Optional target UDC code.")
            }),
            json!(["rowID"]),
        ),
        Verb::Learn => object_schema(
            json!({
                "handle": string_schema("Source handle naming the reference to learn.")
            }),
            json!(["handle"]),
        ),
        // capture for non-drawer/tunnel nouns: not in the acceptance matrix, so this
        // arm only fires if a future noun gains capture. Return empty object so
        // tools/list still encodes; dispatcher refuses with methodNotFound until
        // a schema is added.
        _ => object_schema(json!({}), json!([])),
    }
}

/// Add the optional `estateID` field to a lexicon tool's schema. Mirrors
/// `ToolProjection.withEstateID(_:)`. Returns the schema unchanged if it is
/// not an object schema with a properties map (the empty-fallback schema).
///
/// Description is wire-identical to Swift: "Optional UUID of the open estate
/// to target. Omit for the default estate." — the single house string for
/// every single-estate tool on both legs (Swift's lexicon wrapper carried a
/// longer variant until the 2026-06-02 harmonization; the two-estate lens
/// tools deliberately use the "estate A" wording instead).
fn with_estate_id(schema: serde_json::Value) -> serde_json::Value {
    let estate_desc = "Optional UUID of the open estate to target. Omit for the default estate.";
    match schema {
        serde_json::Value::Object(mut obj) => {
            if let Some(serde_json::Value::Object(mut props)) = obj.remove("properties") {
                props.insert("estateID".to_string(), string_schema(estate_desc));
                obj.insert("properties".to_string(), serde_json::Value::Object(props));
            }
            serde_json::Value::Object(obj)
        }
        other => other,
    }
}

/// Build a single lexicon tool descriptor from a (verb, noun) pair.
fn lexicon_tool(verb: Verb, noun: Noun) -> serde_json::Value {
    let name = tool_name(verb, noun);
    let description = tool_description(verb, noun);
    let schema = with_estate_id(lexicon_schema(verb, noun));
    json!({
        "name": name,
        "description": description,
        "inputSchema": schema
    })
}

/// Build the full `tools/list` tool array as a `serde_json::Value`.
/// Called once at startup and cached in `Dispatcher`.
pub fn build_tool_list() -> serde_json::Value {
    let mut tools = Vec::new();

    // 1. Recipe discovery.
    tools.push(list_recipes_tool());

    // 2. The 16 lens tools (14 reasoning + 2 analytics) — descriptions from the catalog.
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

    // 4. Lexicon projection loop: outer noun in Noun.allCases order, inner verb in
    //    Verb.allCases order, keeping only pairs the acceptance matrix accepts and
    //    that are caller-surfaced (verb.is_surfaced()). Mirrors the Swift
    //    ToolProjection.tools() loop body. Each (verb, noun) pair becomes one tool
    //    via lexicon_tool().
    for &noun in NOUNS {
        for &verb in VERBS {
            if accepts(noun, verb) && verb.is_surfaced() {
                tools.push(lexicon_tool(verb, noun));
            }
        }
    }

    // 5. Federation tool — sits above the lexicon projection; dispatched by name.
    //    Matches ToolProjection.federationTool() in Swift.
    tools.push(cross_estate_recall_tool());

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
        "moot_association_rules" => object_schema(
            json!({
                "filter": filter_schema,
                "limit": integer_schema("Max drawers to recall."),
                "minSupport": number_schema("Minimum rule support (0..1). Default 0."),
                "minConfidence": number_schema("Minimum rule confidence (0..1). Default 0."),
                "estateID": estate_id
            }),
            json!([]),
        ),
        "moot_formal_concepts" => object_schema(
            json!({
                "filter": filter_schema,
                "limit": integer_schema("Max drawers to recall."),
                "minSupport": integer_schema("Minimum concept extent size. Default 1."),
                "maxIntentSize": integer_schema("Maximum concept intent size. Default 8."),
                "maxConcepts": integer_schema("Maximum concepts returned. Default 20."),
                "estateID": estate_id
            }),
            json!([]),
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
// Federation tool — sits above the lexicon projection; dispatched by name.
// Mirrors ToolProjection.federationTool() in Swift.
// ---------------------------------------------------------------------------

/// The `cross_estate_recall` tool descriptor. This tool has no (verb, noun)
/// pair — it is a federation-surface read that fans across open estates the
/// caller is entitled to read. The Rust GLK fan_out is a scaffold with no
/// grant model; the tool is advertised but the dispatcher returns error_result
/// ("not yet implemented: federation requires the grant model") for every
/// call. Per DECISION_FEDERATION_SHARING_MODEL_2026-05-21 §13 this is the
/// correct A-versus-C refusal discipline at the MCP boundary.
///
/// Schema mirrors ToolProjection.federationTool() exactly: requesterEstateID
/// required; filter, limit, ordering, hydrationLevel optional; no estateID
/// (the call fans across estates rather than targeting one).
fn cross_estate_recall_tool() -> serde_json::Value {
    json!({
        "name": "moot_cross_estate_recall",
        "description": "Grant-authorized cross-estate federated read: fans across the locally-open estates the requester is entitled to read and returns per-estate contributions, each narrowed to its grant's scope.",
        "inputSchema": object_schema(
            json!({
                "requesterEstateID": string_schema("UUID of the requesting (caller) estate; the grant gate is evaluated against it. Must name an open estate."),
                "filter": string_schema("Filter kind: unconfirmed, userConfirmed, exportable, contained."),
                "limit": integer_schema("Max rows per estate to return."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly.")
            }),
            json!(["requesterEstateID"])
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

fn boolean_schema(description: &str) -> serde_json::Value {
    json!({ "type": "boolean", "description": description })
}
