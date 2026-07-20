// RecipeTools.swift
//
// The CognitionKit behaviour-recipe surface on ARIA_MCP. These tools sit
// ABOVE the lexicon projection (provenance `.recipe`, dispatched by name)
// exactly as the federation `cross_estate_recall` tool does. They are the
// conscious-mind surface: the MCP↔CognitionKit channel is R/W, so an
// agent reads what recipes exist and triggers them, and the human-in-the-
// loop confirms the migration promotion.
//
// Eleven recipe tools ship here:
//   - moot_list_lenses           → ProjectedTool descriptor enumeration
//                                   (LensTools + Tier 6 RecipeTools — read)
//   - moot_list_recipes          → RecipeCatalog descriptor enumeration
//                                   (catalog discovery)
//   - moot_synthesize            → GroundedSynthesis recipe (read)
//   - moot_recall_precise        → PreciseRecall recipe (read)
//   - moot_recall_shaped         → ShapedRecall recipe (read)
//   - moot_run_migration         → MigrationBenchmark.run (read; no
//                                   promotion — B-3)
//   - moot_confirm_migration     → MigrationBenchmark.confirmPromotion
//                                   by branch id (the human-gated write)
//   - moot_dream, moot_consolidate, moot_recall_distilled, moot_recollect
//                                 → distillation-family and Brain-layer tools
//
// The 23 lens tools (16 reasoning/federated, 4 temporal/information-theoretic,
// 3 analytics: moot_lens_associations, moot_lens_concepts, moot_lens_apriori)
// ship through LensTools.swift — same provenance (.recipe), dispatched
// through the lens surface per LENS_DISCOVERABILITY_DECISION v2.0.
//
// Stateless-boundary discipline: MCP `tools/call` is stateless across
// invocations, so the run tool cannot hand live `BranchHandle`s to a
// later confirm tool. The run tool surfaces branch *ids* in its result;
// the confirm tool takes those ids and re-resolves them through the
// long-lived kit's `GeniusLocusKit.branchHandle(for:)` accessor. This is
// the two-call run→confirm pattern the plan describes; webhook delivery
// of async completion is an additive transport, not needed for the
// synchronous behaviour.

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit
import VaultKit

/// Namespace for the CognitionKit recipe tool surface. No instances.
enum RecipeTools {

    // MARK: - Tool names

    static let listRecipesToolName = "moot_list_lenses"
    /// Catalog discovery tool: returns name/version/description/capabilities
    /// for every shipped recipe in catalog order. Distinct from
    /// `moot_list_lenses` which enumerates ProjectedTool descriptors
    /// (schema + required args) for Tier 6 invokable tools.
    static let listRecipesCatalogToolName = "moot_list_recipes"
    static let groundedSynthesisToolName = "moot_synthesize"
    static let preciseRecallToolName = "moot_recall_precise"
    /// Shaped-recall tool: a single recall tool with a discoverable `preset` enum
    /// param selecting one named RecallShape from the GLK roster. Preferable to ~20
    /// tools (one per shape) — the AI picks a deterministic recipe by name instead
    /// of simulating steering.
    static let shapedRecallToolName = "moot_recall_shaped"
    static let runMigrationBenchmarkToolName = "moot_run_migration"
    static let confirmMigrationPromotionToolName = "moot_confirm_migration"
    /// On-demand dream tool: rebuild the estate's derived accelerators (the
    /// co-occurrence/temporal matrix tier that feeds the `matrix`/`coOccurrence`
    /// recall lanes) and run one dreaming cycle (latent-alignment proposals +
    /// the cycle diary). The Brain's matrix is built by the dreaming pass, not
    /// by impatient encode, so a freshly-loaded estate has an EMPTY matrix until
    /// this runs — the reason the matrix-driven precise compositions score zero
    /// on an undreamt estate.
    static let dreamToolName = "moot_dream"
    /// On-demand distillation sweep: compact working memory by distilling active
    /// items into factoids. Delegates to GeniusLocusKit.distillItemsSweep,
    /// which processes all eligible not-yet-distilled items.
    static let consolidateToolName = "moot_consolidate"
    /// Dense distilled-tier recall: Hamming NN over the distillation-features-v1
    /// VectorKit lane — no embedding model inference. Returns factoid prose
    /// (~10 tokens/hit) + confidence metadata. Full spec: DISTILLATION_ARIA_TOOLS.md §2.
    static let recallDistilledToolName = "moot_recall_distilled"
    /// Fan-out from a distilled factoid to its source memories by following the
    /// _distilled_from tunnel graph. Returns full episodic content from the M
    /// source memories that produced the factoid. Full spec: DISTILLATION_ARIA_TOOLS.md §3.
    static let recollectToolName = "moot_recollect"
    /// On-demand contradiction hunt: one bounded sweep of the content-driven
    /// contradiction detector (BM25 lexical candidates + ConflictCue screen). Strong
    /// findings persist as proposed contradicts tunnels; borderline pairs are
    /// returned for the calling agent to adjudicate.
    static let huntContradictionsToolName = "moot_hunt_contradictions"

    /// True when `name` is one of the foundational recipe tools dispatched by name.
    static func isRecipeTool(_ name: String) -> Bool {
        name == listRecipesToolName
            || name == listRecipesCatalogToolName
            || name == groundedSynthesisToolName
            || name == preciseRecallToolName
            || name == shapedRecallToolName
            || name == runMigrationBenchmarkToolName
            || name == confirmMigrationPromotionToolName
            || name == dreamToolName
            || name == consolidateToolName
            || name == recallDistilledToolName
            || name == recollectToolName
            || name == huntContradictionsToolName
    }

    // MARK: - tools/list projection

    /// All foundational recipe tool descriptors, advertised in `tools/list`
    /// after the lexicon projection and the federation tool. The analytics
    /// and reasoning-lens tools are projected by LensTools.
    static func tools() -> [ProjectedTool] {
        [
            listRecipesTool(),
            listRecipesCatalogTool(),
            groundedSynthesisTool(),
            preciseRecallTool(),
            shapedRecallTool(),
            runMigrationBenchmarkTool(),
            confirmMigrationPromotionTool(),
            dreamTool(),
            consolidateTool(),
            recallDistilledTool(),
            recollectTool(),
            huntContradictionsTool(),
        ]
    }

    /// The roster listing the shaped-recall tool advertises in its description:
    /// one `name — description` line per preset, built from the GLK roster so a
    /// new preset is reflected automatically. This is the "AI lists the roster"
    /// surface — name + one-line description + which signals it emphasizes.
    private static func presetRosterListing() -> String {
        RecallShape.presetNames
            .map { "\($0) — \(RecallShape.presetDescription($0))" }
            .joined(separator: "; ")
    }

    /// The shaped-recall tool. Runs the ShapedRecall recipe with a named
    /// RecallShape preset applied — one tool, a discoverable `preset` enum, the
    /// full roster in the description. Returns results in the same plain-text
    /// shape `moot_memory_search` uses so existing mootText parsers work unchanged.
    /// The four ARIA filtering adjectives compose orthogonally: the preset RANKS,
    /// the `filter` arg FILTERS.
    private static func shapedRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: shapedRecallToolName,
            description: "Shaped recall: run recall with a named RecallShape preset that forwards, excludes, suppresses, or inverts individual fusion lanes (and bounds the candidate frontier). Pick ONE preset by name. Roster: \(presetRosterListing()). Returns the same shape as moot_memory_search including a discrimination signal. Use for fuzzy/semantic association and exploration; note that associative/conceptual presets rely on fusion lanes that are weaker on small corpora until the embedding encoder lands (v1.1 planned), so low discrimination from shaped recall on a small estate is expected — switch to moot_recall_precise for precision.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The search query text — drives BM25 + vector recall."),
                    "preset": .object([
                        "type": .string("string"),
                        "description": .string("The RecallShape preset to apply (how to steer the fusion). One of the roster names. balanced (or an omitted preset) is the unsteered default. Unknown names are rejected."),
                        // Discoverable enum: the exact roster the GLK ships.
                        "enum": .array(RecallShape.presetNames.map { .string($0) }),
                    ]),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid. Composes orthogonally with the preset — the preset ranks, the filter filters."),
                    "wing": stringSchema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    /// The cognition-discovery tool. At runtime (`runListRecipes`), returns
    /// one block per Tier 6 tool drawn from `LensTools.tools()` and the four
    /// Tier 6 recipe tools (`moot_list_lenses`, `moot_synthesize`,
    /// `moot_recall_precise`, `moot_recall_shaped`) — not `RecipeCatalog`.
    /// Takes no arguments; it is the conscious mind enumerating its surface.
    private static func listRecipesTool() -> ProjectedTool {
        ProjectedTool(
            name: listRecipesToolName,
            description: "List the available reasoning lenses and CognitionKit behaviour recipes — each with its version, description, and the NeuronKit capabilities it requires.",
            inputSchema: objectSchema(properties: [:], required: []),
            provenance: .recipe)
    }

    /// Catalog discovery tool: returns name, version, description, and required
    /// capabilities for every shipped recipe in `RecipeCatalog.all` order.
    /// Hard-codes nothing; reads the catalog directly so new registrations are
    /// automatically reflected.
    private static func listRecipesCatalogTool() -> ProjectedTool {
        ProjectedTool(
            name: listRecipesCatalogToolName,
            description: "List every shipped CognitionKit recipe — name, version, description, and required NeuronKit capabilities — in catalog order.",
            inputSchema: objectSchema(properties: [:], required: []),
            provenance: .recipe)
    }

    private static func groundedSynthesisTool() -> ProjectedTool {
        ProjectedTool(
            name: groundedSynthesisToolName,
            description: "Synthesize memories into a grounded context document: hybrid-recall and summarise into patterns, success rate, recommendations, and key insights.",
            inputSchema: objectSchema(
                properties: [
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary recall across any confirmation state. null is invalid."),
                    "limit": integerSchema("Max drawers to recall. Omit for no explicit cap; null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: []),
            provenance: .recipe)
    }

    /// The precise-recall tool. Runs the PreciseRecall recipe: a generous
    /// coarse grab (matrixAware/unionBest, same lane as moot_memory_search)
    /// re-ranked by query-specific precision so the EXACT answer rises above
    /// its near-duplicate distractors. Returns results in the same plain-text
    /// shape moot_memory_search uses (`found N memory(s)` then one ranked
    /// line per hit) so existing mootText parsers work unchanged. Distinct
    /// from moot_memory_search, which is the fetch-only verb (left intact).
    private static func preciseRecallTool() -> ProjectedTool {
        ProjectedTool(
            name: preciseRecallToolName,
            description: "Precise recall: coarse-grab a generous candidate pool then re-rank by query-specific precision (distinctive number/proper-noun match) to surface the exact answer above near-duplicates. Lifts found@1/MRR without dropping found@10. Returns the same shape as moot_memory_search including a discrimination signal. Use when you need a specific known-token answer — exact names, numbers, identifiers — especially on small estates where semantic/associative modes produce low discrimination. This is the recommended mode when the discrimination signal from moot_memory_search or moot_recall_shaped is low.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The search query text — drives BM25 + vector recall and the precision re-rank."),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "pool": integerSchema("Coarse candidate-pool size grabbed before the precision re-rank. Default 30; clamped to be at least limit. Omit to use the default; null is invalid."),
                    "composition": stringSchema("Named reduction composition selecting how the coarse pool is re-ranked (the ablation selector). E.g. text (default), hamming, matrix, lattice, tokenExact, hamming+tokenExact, hamming+text, text+matrix, lattice+hamming, text+tokenExact, text+mmr, weighted-all. Omit for the default (text). Unknown names and null are rejected."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid."),
                    "wing": stringSchema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    private static func runMigrationBenchmarkTool() -> ProjectedTool {
        ProjectedTool(
            name: runMigrationBenchmarkToolName,
            description: "Run a migration benchmark: derive COW branches, populate from origin corpus, benchmark recall fidelity, and rank survivors. Returns branch ids for a separate confirm step. Never promotes automatically.",
            inputSchema: objectSchema(
                properties: [
                    "corpusName": stringSchema("Human-readable name for the origin corpus."),
                    "entries": .object([
                        "type": .string("array"),
                        "description": .string("Origin entries: objects with string fields id, content, and a string-array field tags."),
                        "items": objectSchema(
                            properties: [
                                "id": stringSchema("Stable source id."),
                                "content": stringSchema("Verbatim content."),
                                "tags": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")]),
                                ]),
                            ],
                            required: ["id", "content"]),
                    ]),
                    "plans": .object([
                        "type": .string("array"),
                        "description": .string("Candidate plans: objects with string fields name, room, latticeCode, embeddingModelID, and optional sensitivity (normal/elevated/restricted/secret)."),
                        "items": objectSchema(
                            properties: [
                                "name": stringSchema("Plan name (also the branch name)."),
                                "room": stringSchema("Room every migrated drawer is filed into."),
                                "latticeCode": stringSchema("UDC lattice code for every migrated drawer."),
                                "embeddingModelID": stringSchema("Embedding model id tagged on every drawer."),
                                "sensitivity": stringSchema("Optional sensitivity tier; default normal."),
                            ],
                            required: ["name", "room", "latticeCode", "embeddingModelID"]),
                    ]),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: ["corpusName", "entries", "plans"]),
            provenance: .recipe)
    }

    private static func confirmMigrationPromotionTool() -> ProjectedTool {
        ProjectedTool(
            name: confirmMigrationPromotionToolName,
            description: "Confirm a migration: promote the winning branch into the estate and discard the losers, by branch id. Refuses to promote any branch the run report disqualified.",
            inputSchema: objectSchema(
                properties: [
                    "winnerBranchID": stringSchema("UUID of the winning branch to promote (from the run report)."),
                    "discardBranchIDs": .object([
                        "type": .string("array"),
                        "description": .string("UUIDs of losing branches to discard."),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: ["winnerBranchID"]),
            provenance: .recipe)
    }

    /// The on-demand dream tool. Rebuilds the estate's derived accelerators
    /// (the matrix tier — co-occurrence and temporal causality — that the
    /// `matrix`/`coOccurrence` recall lanes score against) and runs one
    /// dreaming cycle (latent-alignment proposals + the cycle diary). Returns a
    /// small cycle summary. Idempotent: re-running over unchanged estate state
    /// rebuilds the same matrix and emits no duplicate proposals.
    private static func dreamTool() -> ProjectedTool {
        ProjectedTool(
            name: dreamToolName,
            description: "Dream the estate: rebuild the co-occurrence/temporal matrix tier (the Brain's association layer that the matrix recall lane scores against), run one dreaming cycle (latent-alignment proposals + cycle diary), and run one contradiction-hunt sweep (content screen over lexically-near memory pairs; strong conflicts persist as PROPOSED contradicts links for review). The matrix is built by dreaming, not by capture, so a freshly-loaded estate has an empty matrix until this runs. Returns a cycle summary including contradiction counts.",
            inputSchema: objectSchema(
                properties: [
                    "now": stringSchema("Optional ISO8601 instant to run the cycle at, for deterministic runs (drives the diary timestamp and the reward window). Omit to use the current wall clock."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - hunt-contradictions descriptor

    /// The on-demand contradiction hunt. One bounded sweep of the
    /// content-driven detector: kNN candidate mining over the estate's
    /// vector index, then the deterministic ConflictCue screen. Strong
    /// findings persist as `contradicts` tunnels with lifecycle PROPOSED
    /// (reviewable via `moot_review_tunnel`, surfaced by
    /// `moot_lens_contradiction`); borderline pairs are returned with
    /// content snippets so the CALLING AGENT judges them — the
    /// adjudication feed for paraphrased conflicts the lexical screen
    /// cannot settle.
    private static func huntContradictionsTool() -> ProjectedTool {
        ProjectedTool(
            name: huntContradictionsToolName,
            description: "Hunt for contradictions in memory content: one bounded sweep that finds lexically-near memory pairs via the corpus keyword (BM25) index and screens them for lexical conflict (negation asymmetry, same-template value divergence, revision markers). Strong findings are persisted as PROPOSED contradicts links (review with moot_lens_contradiction, accept/reject with moot_review_tunnel; rejected pairs are never re-proposed). Borderline pairs are RETURNED with snippets for YOU to judge — if a pair genuinely conflicts, record it with moot_link_memories kind=contradicts proposed=true. Requires the corpus search index (run moot_reindex after bulk import).",
            inputSchema: objectSchema(
                properties: [
                    "probe_limit": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Maximum vector-indexed memories probed this sweep (default 500). "
                                + "Repeated calls converge: settled pairs are skipped."),
                    ]),
                    "now": stringSchema("Optional ISO8601 instant for deterministic runs. Omit to use the current wall clock."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - consolidate descriptor

    /// On-demand per-item distillation sweep. Delegates all work to
    /// GeniusLocusKit.distillItemsSweep — processes all active not-yet-distilled
    /// items and persists each factoid as a drawer in room `_distilled`.
    /// The `cluster_id` and `include_held` args are accepted for API stability
    /// but are not used by the per-item sweep model.
    private static func consolidateTool() -> ProjectedTool {
        ProjectedTool(
            name: consolidateToolName,
            description: "Compact working memory by distilling active items into factoids. "
                + "Calls the GLK per-item distillation sweep, which processes all "
                + "eligible not-yet-distilled items and persists each factoid as a "
                + "drawer in room `_distilled`. Returns the count of factoids produced "
                + "this sweep.",
            inputSchema: objectSchema(
                properties: [
                    "cluster_id": stringSchema(
                        "Accepted for API stability; not used by the per-item sweep model."),
                    "include_held": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Accepted for API stability; not used by the per-item sweep model. "
                                + "Default false."),
                    ]),
                    "estateID": stringSchema(
                        "Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    // MARK: - recall_distilled descriptor

    /// Dense distilled-tier recall. Structural fingerprint Hamming NN over the
    /// distillation-features-v1 VectorKit lane — no embedding model inference.
    /// Returns factoid prose (~10 tokens/hit) + confidence metadata.
    private static func recallDistilledTool() -> ProjectedTool {
        ProjectedTool(
            name: recallDistilledToolName,
            description: "Dense recall: search the distilled memory tier and return factoid "
                + "prose (~10 tokens/hit) for AI reasoning. Uses structural fingerprint "
                + "Hamming NN — no embedding model inference, no full corpus scan. Factoids "
                + "carry confidence scores and source counts. For full episodic detail on a "
                + "specific factoid call moot_recollect with the returned drawer_id. "
                + "Returns a discrimination signal over confidence scores.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema(
                        "Query text — feature-extracted and fingerprinted for Hamming NN "
                            + "against the distillation-features-v1 lane. No embedding inference."),
                    "limit": integerSchema(
                        "Max factoids to return. Default 20. Omit to use the default; "
                            + "null is invalid."),
                    "filter": stringSchema(
                        "Filter kind: unconfirmed, userConfirmed, exportable, contained, "
                            + "currentlyBelieve. Omit for ordinary recall across any confirmation "
                            + "state. null is invalid."),
                    "estateID": stringSchema(
                        "Optional UUID of the open estate to target. Omit for the default estate; "
                            + "null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    // MARK: - recollect descriptor

    /// Fan-out from a distilled factoid to its M source memories by following the
    /// _distilled_from tunnel graph. Returns full episodic content for the AI
    /// to synthesize into a user-facing narrative.
    private static func recollectTool() -> ProjectedTool {
        ProjectedTool(
            name: recollectToolName,
            description: "Recollect: fan-out from a distilled factoid to its source memories. "
                + "Follows the _distilled_from tunnel graph from a _distilled drawer and returns the "
                + "full episodic content of the M source memories that produced it. Use "
                + "when the user needs the full explanation behind a dense factoid returned "
                + "by moot_recall_distilled. You synthesize the sources into a narrative — "
                + "MOOTx01 provides the evidence chain.",
            inputSchema: objectSchema(
                properties: [
                    "drawer_id": stringSchema(
                        "UUID of the _distilled drawer to expand. Obtain from "
                            + "moot_recall_distilled results."),
                    "estateID": stringSchema(
                        "Optional UUID of the open estate to target. Omit for the default estate; "
                            + "null is invalid."),
                ],
                required: ["drawer_id"]),
            provenance: .recipe)
    }

    // MARK: - Dispatch

    /// Run the named recipe tool. `resolveHandle` is the dispatcher's own
    /// estateID→handle resolver (absent estateID ⇒ default handle), passed
    /// in so recipe tools honour the same multi-estate routing as lexicon
    /// tools. Out-of-band faults throw `JSONRPCError`; recipe-level
    /// refusals come back as `errorResult` (isError == true) so the client
    /// keeps the call id, matching the lexicon-tool discipline.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        // Recipe discovery needs no estate; answer before resolving a handle
        // so discovery tools work even with no estate targeted.
        if name == listRecipesToolName {
            return runListRecipes()
        }
        if name == listRecipesCatalogToolName {
            return runListRecipesCatalog()
        }
        let handle = try resolveHandle(args)
        switch name {
        case groundedSynthesisToolName:
            return try await runGroundedSynthesis(args, kit: kit, handle: handle)
        case preciseRecallToolName:
            return try await runPreciseRecall(args, kit: kit, handle: handle)
        case shapedRecallToolName:
            return try await runShapedRecall(args, kit: kit, handle: handle)
        case runMigrationBenchmarkToolName:
            return try await runMigrationBenchmark(args, kit: kit, handle: handle)
        case confirmMigrationPromotionToolName:
            return try await runConfirmPromotion(args, kit: kit, handle: handle)
        case dreamToolName:
            return try await runDream(args, kit: kit, handle: handle)
        case consolidateToolName:
            return try await runConsolidate(args, kit: kit, handle: handle)
        case recallDistilledToolName:
            return try await runRecallDistilled(args, kit: kit, handle: handle)
        case recollectToolName:
            return try await runRecollect(args, kit: kit, handle: handle)
        case huntContradictionsToolName:
            return try await runHuntContradictions(args, kit: kit, handle: handle)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown recipe tool: \(name)")
        }
    }

    // MARK: - list_lenses (cognition menu)

    /// Return a one-block-per-tool cognition menu drawn from the shipped
    /// `ProjectedTool` descriptors. Shows name, description, and required
    /// args for each Tier 6 cognition tool — the 23 lens tools plus four
    /// recipe tools (`moot_list_lenses`, `moot_synthesize`,
    /// `moot_recall_precise`, `moot_recall_shaped`) for 27 total.
    /// Migration and distillation tools (Tier 7) are intentionally excluded;
    /// they have their own teachme guides and a separate caller workflow.
    private static func runListRecipes() -> JSONValue {
        // Tier 6 recipe tools: list-lenses + synthesize + precise recall + shaped
        // recall (not migration or distillation, which are Tier 7).
        let tier6RecipeNames: Set<String> = [
            listRecipesToolName, groundedSynthesisToolName,
            preciseRecallToolName, shapedRecallToolName,
        ]
        let recipeTools = tools().filter { tier6RecipeNames.contains($0.name) }
        // All 23 lens tools from LensTools.
        let lensTools = LensTools.tools()
        let cognitionTools = recipeTools + lensTools

        var lines: [String] = ["\(listRecipesToolName): \(cognitionTools.count) cognition tools"]
        for tool in cognitionTools {
            let required = requiredArgNames(from: tool.inputSchema)
            let requiredText = required.isEmpty ? "none" : required.joined(separator: ", ")
            lines.append("")
            lines.append(tool.name)
            lines.append("  \(tool.description)")
            lines.append("  Required: \(requiredText).")
        }
        lines.append("")
        lines.append("Call any tool with teachme:true for a full usage guide.")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    /// Return every shipped recipe from `RecipeCatalog.all` — name, version,
    /// description, and required NeuronKit capabilities — in catalog order.
    /// Reads the catalog directly; hard-codes nothing.
    private static func runListRecipesCatalog() -> JSONValue {
        let catalog = RecipeCatalog.all
        var lines: [String] = ["\(listRecipesCatalogToolName): \(catalog.count) recipe(s)"]
        for recipe in catalog {
            lines.append("")
            lines.append(recipe.name)
            lines.append("  version: \(recipe.version)")
            lines.append("  \(recipe.description)")
            let caps = recipe.requiredCapabilities.map { "\($0)" }
            lines.append("  requires: \(caps.isEmpty ? "none" : caps.joined(separator: ", "))")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    /// Extract required argument names from a JSON Schema `required` array.
    private static func requiredArgNames(from schema: JSONValue) -> [String] {
        schema.objectValue?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    // MARK: - grounded_synthesis

    private static func runGroundedSynthesis(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let filterChain = try decodeFilterChain(args["filter"])
        // Route through clampLimit so negative and over-ceiling values are
        // rejected/clamped at the MCP boundary. Parity: Rust recipe_tools.rs
        // run_grounded_synthesis_tool uses clamp_limit with the same ceiling.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        let frame = LocusKit.RecallFrame(
            filterChain: filterChain,
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc)

        let out = try await GroundedSynthesis().run(
            input: .init(frame: frame), estate: handle, kit: kit)

        let doc = out.context
        let body = """
        grounded_synthesis: \(out.drawerCount) drawer(s)
        summary: \(doc.summary)
        patterns: \(doc.patterns.joined(separator: ", "))
        successRate: \(doc.successRate)
        recommendations:
        \(doc.recommendations.map { "  - \($0)" }.joined(separator: "\n"))
        keyInsights:
        \(doc.keyInsights.map { "  - \($0)" }.joined(separator: "\n"))
        """
        return ToolDispatcher.textResult(body)
    }

    // MARK: - recall_precise

    /// Run the PreciseRecall recipe and serialize its matches in the SAME
    /// plain-text shape `moot_memory_search` emits: a `found N memory(s)`
    /// header line then up to `prefix(50)` `id  [room]  preview` lines.
    /// Mirroring that shape (including the 120-char content preview) keeps
    /// every mootText parser — the gauntlet's included — working unchanged.
    ///
    /// Composition validation is fail-CLOSED: an absent `composition` arg maps
    /// to nil → the recipe default (`text`), reproducing existing behavior.
    /// A present-but-unknown name is a caller error — the access surface rejects
    /// it with a tool error (isError: true) instead of silently degrading to
    /// `text` and returning surprising results under a name the caller did not
    /// realize was ignored.
    /// Parity: mirrors the Rust boundary contract (94a62696,
    /// `recall_precise_unknown_composition_fails_closed`).
    private static func runPreciseRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: reject negative/zero, cap absurdly-large values.
        // DoS prevention at the MCP boundary before the substrate is touched.
        // Parity: Rust run_precise_recall_tool uses clamp_limit with same ceiling.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // Default coarse pool is CognitionKit's own default (30); honour an
        // explicit override. The recipe clamps pool >= limit internally.
        // Pool is also clamped: an unbounded pool drives an unbounded substrate scan.
        let pool = try ToolDispatcher.clampLimit(
            try optionalInt(args["pool"], argument: "pool"),
            argument: "pool",
            default: CognitionKit.PreciseRecall.defaultPool)
        // optional `wing` scopes recall to a single wing.
        // When present, compose with the explicit filter via Filter.all so both
        // constraints apply. When absent, the filter arg stands alone.
        let baseFilter = try decodeSingleFilter(args["filter"])
        let filter: LocusKit.Filter
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filter = .all([baseFilter, .inWing(wingName)])
        } else {
            filter = baseFilter
        }
        // The ablation selector: a named reduction composition.
        //   Absent  → nil → the recipe's default (`text`); absence ≠ unknown.
        //   Present → validated against the grid; unknown name → fail closed
        //             (tool error, not silent fall-through). The grid is the
        //             authoritative name set; callers that supply a bad name
        //             receive an explicit error rather than opaque text results.
        let composition: String?
        if let rawComposition = try optionalString(args["composition"], argument: "composition") {
            guard NeuronKit.CompositionGrid.names.contains(rawComposition) else {
                let valid = NeuronKit.CompositionGrid.names.joined(separator: ", ")
                return ToolDispatcher.errorResult(
                    "unknown composition '\(rawComposition)'; valid names: \(valid)")
            }
            composition = rawComposition
        } else {
            composition = nil
        }

        let matches = try await PreciseRecall.run(
            kit: kit, handle: handle, query: query,
            filter: filter, limit: limit, pool: pool, composition: composition)

        // Part 1a — distinctive-token containment gate.
        //
        // When the query carries distinctive tokens (numbers or proper nouns)
        // but NO returned candidate's content contains any of those tokens, the
        // result set is a confident NON-match: the re-ranker produced a ranked
        // list of things that are definitively NOT the queried entity. Returning
        // that list as-is would cause the calling AI to confidently report the
        // wrong answer. Instead: suppress results and emit not_found so the
        // caller knows to widen the search or confirm the content exists.
        //
        // When the query has NO distinctive tokens we cannot apply the gate
        // (every word is a stopword / generic term that cannot be required to be
        // present) — but we emit a coaching hint so the calling AI knows the
        // recall may be indiscriminate.
        let candidateContents = matches.map { $0.content }
        let hasDistinctive = NeuronKit.hasDistinctiveTokens(query)
        let satisfied = NeuronKit.containmentSatisfied(query: query, candidateContents: candidateContents)

        if hasDistinctive && !satisfied {
            // Containment gate fired — return zero results with not_found.
            let lines: [String] = [
                "found 0 memory(s)",
                RecallDiscrimination.resultLine(for: .notFound),
            ]
            return ToolDispatcher.textResult(lines.joined(separator: "\n"))
        }

        // Part 1b — discrimination is computed over composition precision
        // scores (PreciseMatch.score = candidate.precisionScore from the
        // weighted-sum fold), not the coarse fusion score, so the level
        // reflects re-rank quality rather than coarse-grab noise.
        let preciseScores = matches.map { $0.score }
        let preciseDiscrimination = RecallDiscrimination.classify(preciseScores)

        // resolve parentNodeIds to room display names via the
        // node tree, matching moot_memory_search's resolution path.
        let estate = try await kit.estate(for: handle)
        let parentNodeIds = matches.map { $0.room }
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: parentNodeIds)

        var lines: [String] = ["found \(matches.count) memory(s)"]
        for match in matches.prefix(50) {
            let preview = match.content.prefix(120)
            let room = nodeNames[match.room]?.room ?? (match.room.isEmpty ? "?" : match.room)
            lines.append("\(match.id)  [\(room)]  \(preview)")
        }
        lines.append(RecallDiscrimination.resultLine(for: preciseDiscrimination))
        if !hasDistinctive {
            lines.append("hint: query contains no distinctive tokens (numbers or proper nouns) — "
                + "results may be imprecise. Refine with specific identifiers for higher confidence.")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - recall_shaped

    /// Run the ShapedRecall recipe with a named RecallShape preset and serialize
    /// its matches in the SAME plain-text shape `moot_memory_search` emits: a
    /// `found N memory(s)` header then one `id  [room]  preview` line per match.
    /// Mirroring that shape keeps every mootText parser working unchanged.
    ///
    /// Preset validation is fail-CLOSED: an absent `preset` arg maps to "balanced"
    /// (the unsteered default). A present-but-unknown name is a caller error — the
    /// access surface rejects it with a tool error (isError: true) against the GLK
    /// roster instead of silently degrading to balanced and returning surprising
    /// results under a name the caller did not realize was ignored. (The recipe
    /// itself degrades to balanced; the access surface is where fail-closed
    /// validation lives — the same boundary discipline as the precise-recall
    /// composition arg.)
    private static func runShapedRecall(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: reject negative/zero, cap absurdly-large values.
        // DoS prevention at the MCP boundary before the substrate is touched.
        // Parity: Rust run_shaped_recall_tool uses clamp_limit with same ceiling.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        // optional `wing` scopes recall to a single wing.
        // When present, compose with the explicit filter via Filter.all.
        let baseFilter = try decodeSingleFilter(args["filter"])
        let filter: LocusKit.Filter
        if let wingName = try optionalString(args["wing"], argument: "wing") {
            filter = .all([baseFilter, .inWing(wingName)])
        } else {
            filter = baseFilter
        }

        // The steering selector: a named RecallShape preset.
        //   Absent  → "balanced" → the unsteered default; absence ≠ unknown.
        //   Present → validated against the GLK roster; unknown name → fail closed
        //             (tool error, not silent fall-through to balanced).
        let preset: String
        if let rawPreset = try optionalString(args["preset"], argument: "preset") {
            guard RecallShape.presetNames.contains(rawPreset) else {
                let valid = RecallShape.presetNames.joined(separator: ", ")
                return ToolDispatcher.errorResult(
                    "unknown preset '\(rawPreset)'; valid presets: \(valid)")
            }
            preset = rawPreset
        } else {
            preset = "balanced"
        }

        let out = try await ShapedRecall().run(
            input: .init(query: query, preset: preset, filter: filter, limit: limit),
            estate: handle, kit: kit)

        // Discrimination is computed over the full ordered list before the
        // display prefix so the signal reflects all returned scores.
        let shapedScores = out.matches.map { $0.score }
        let shapedDiscrimination = RecallDiscrimination.classify(shapedScores)

        // resolve parentNodeIds to room display names via the
        // node tree, matching moot_memory_search's resolution path.
        let estate = try await kit.estate(for: handle)
        let parentNodeIds = out.matches.map { $0.room }
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: parentNodeIds)

        var lines: [String] = ["found \(out.matches.count) memory(s)"]
        for match in out.matches.prefix(50) {
            let preview = match.content.prefix(120)
            let room = nodeNames[match.room]?.room ?? (match.room.isEmpty ? "?" : match.room)
            lines.append("\(match.id)  [\(room)]  \(preview)")
        }
        lines.append(RecallDiscrimination.resultLine(for: shapedDiscrimination))
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - run_migration_benchmark

    private static func runMigrationBenchmark(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let corpusName = try requireString(args, "corpusName")
        guard let entriesValue = args["entries"], entriesValue.arrayValue != nil else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "entries must be an array")
        }
        let plans = try decodePlans(args["plans"])
        guard !plans.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "run_migration_benchmark requires at least one plan")
        }

        // data-movement privacy tiers (VK-ADAPT-01): VaultKit's adapter pipeline
        // owns the export-decode knowledge. Re-encode the wire entries as
        // an export document and run ExchangeAdapter → CorpusProjection —
        // the same consolidated path file import uses — instead of
        // decoding entries inline here. Tool name and input schema are
        // unchanged; the decode error maps to the same invalidParams
        // message clients saw before the re-plumb.
        let exportDocument = JSONValue.object([
            "name": .string(corpusName),
            "entries": entriesValue,
        ])
        let export: ExchangeExport
        do {
            export = try ExchangeAdapter().decode(exportDocument.encoded())
        } catch is DecodingError {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "each entry needs string id and content")
        }
        let origin = CorpusProjection.externalCorpus(name: export.name, notes: export.notes)
        let out = try await MigrationBenchmark().run(
            input: .init(origin: origin, plans: plans),
            estate: handle, kit: kit)

        let report = out.comparisonReport
        var lines: [String] = ["run_migration_benchmark"]
        if let wid = report.winnerBranchID, let wname = report.winnerPlanName {
            lines.append("winner: plan '\(wname)' branch \(wid)")
        } else {
            lines.append("winner: none (all plans disqualified or no plans)")
        }
        lines.append("rankings:")
        for r in report.rankings {
            lines.append("  - \(r.planName) [\(r.branchID)] score=\(r.combinedScore) overlap=\(r.recallOverlap) mrr=\(r.meanReciprocalRank)")
        }
        lines.append("disqualified:")
        for d in report.disqualified {
            lines.append("  - \(d.planName) [\(d.branchID)] lost: \(d.lostConcepts.joined(separator: ", "))")
        }
        lines.append("")
        // Disqualified branches were discarded server-side by the run; the
        // confirm tool refuses them regardless of what the caller sends.
        lines.append("To promote, call \(confirmMigrationPromotionToolName) with winnerBranchID and discardBranchIDs (the other ranking ids). Disqualified branches above were already discarded and cannot be promoted.")
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - confirm_migration_promotion

    private static func runConfirmPromotion(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let winner = try requireUUID(args, "winnerBranchID")
        let discard = try decodeUUIDArray(args["discardBranchIDs"])
        // NOTE: no client-supplied disqualification set. The C-5 verdict is
        // server-side: the run discarded disqualified branches, and the
        // confirm below refuses any non-active branch.

        do {
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: winner,
                discardBranchIDs: discard,
                estate: handle, kit: kit)
        } catch let error as RecipeError {
            // Recipe-level refusal (e.g. silentConceptLoss on a
            // disqualified winner, or an unknown branch). The call reached
            // the recipe and was refused; surface it as a tool error so
            // the client keeps the call id and sees why.
            return ToolDispatcher.errorResult(error.description)
        }
        return ToolDispatcher.textResult(
            "confirm_migration_promotion: promoted \(winner); discarded \(discard.count) branch(es).")
    }

    // MARK: - dream

    /// Run `moot_dream`: rebuild the estate's derived accelerators, then run one
    /// dreaming cycle. Two distinct effects, both required for a fully "dreamt"
    /// estate:
    ///
    ///   1. MATRIX REBUILD — `kit.rebuildDerivedAccelerators(for:)` feeds the
    ///      estate's audit log into the GLK UnifiedAuditLog CRDT and rebuilds the
    ///      MatrixTier (field-presence F, co-occurrence C/O, temporal causality
    ///      T) then registers it on the estate. Before this call the estate has
    ///      no registered matrix tier, so the RecallDirector's `coOccurrence`
    ///      and temporal score columns read 0.0 and the matrix-driven precise
    ///      compositions (matrix, text+matrix, weighted-all's matrix term)
    ///      score nothing. This is THE step that un-starves them.
    ///   2. DREAMING CYCLE — a `DreamingDaemon` over the same estate seams the
    ///      AutonomicGovernor uses (`EstateDreamingReader` + `EstateDreamingSink`
    ///      + an in-memory policy store) runs one `triggerDreamingCycle(now:)`,
    ///      mining latent co-occurrence alignments into Tunnel proposals and
    ///      writing one cycle diary entry. This is the literal "dream".
    ///
    /// `now` is explicit (CLAUDE.md determinism): an optional ISO8601 arg drives
    /// the cycle's diary timestamp and reward window so a benchmark run is
    /// reproducible. Absent ⇒ wall clock, matching the other write tools.
    private static func runDream(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        // Deterministic `now` when supplied; otherwise the wall clock. A
        // malformed instant is an out-of-band client error.
        //
        // Upper-bound guard: a future `now` causes pruneRecallTraces(olderThan: now - 30.days)
        // to delete ALL recall traces (since every trace is older than a future minus 30 days).
        // Reject any `now` that is more than 24 hours in the future; this is generous enough
        // for timezone edge cases and deliberate benchmark offsets while closing the wipe vector.
        let now: Date
        if let raw = try optionalString(args["now"], argument: "now") {
            guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is not a valid ISO8601 instant: \(raw)")
            }
            // Future-now guard: reject timestamps more than 86400s (24 h) ahead of
            // wall clock. A far-future `now` causes pruneRecallTraces(olderThan:
            // now − 30 days) to prune recent real recall traces, corrupting the
            // reward signal. Hard ceiling: 24 h. Parity: Rust run_dream_tool.
            guard parsed.timeIntervalSince(Date()) <= 86400 else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is more than 24 hours in the future; "
                        + "pass a timestamp close to the current time")
            }
            now = parsed
        } else {
            now = Date()
        }

        // Step 1 — rebuild + register the matrix tier (the un-starving step).
        try await kit.rebuildDerivedAccelerators(for: handle)

        // Step 2 — one dreaming cycle over the live estate seams, constructed
        // exactly as the AutonomicGovernor does for the resident process.
        let daemon = NeuronKit.dreamingDaemon(
            reader: EstateDreamingReader(handle: handle, kit: kit),
            sink: EstateDreamingSink(handle: handle, kit: kit),
            policyStore: InMemoryDreamingPolicyStore())
        let report = try await daemon.triggerDreamingCycle(now: now)

        // Step 3 — the content-driven phase: one contradiction-hunt sweep
        // (kNN candidates + ConflictCue screen; strong findings persist as
        // proposed contradicts tunnels; dedup is durable, so re-running
        // moot_dream never re-proposes). This is what makes post-import
        // dreaming produce content results on a never-recalled estate.
        // Bounded probe budget per call; repeated calls stay cheap because
        // settled pairs are skipped.
        // Sensitivity ceiling is hardcoded .elevated (fail-safe by design); huntContradictions does NOT consult SensitivityGrantLedger.
        let hunt = try await kit.huntContradictions(
            in: handle, probeLimit: 500, now: now)

        var body = """
        moot_dream: matrix rebuilt, dreaming cycle complete
        consideredCandidates: \(report.candidatesConsidered)
        proposalsEmitted: \(report.proposalsEmitted.count)
        suppressedDuplicates: \(report.suppressedDuplicates)
        belowThreshold: \(report.belowThreshold)
        contradictionsProposed: \(hunt.proposed.count)
        contradictionCandidatesBorderline: \(hunt.borderline.count)
        """
        if !hunt.vectorStoreAvailable {
            body += "\n(contradiction hunt skipped: no vector index for this estate — run moot_reindex first)"
        }
        if !hunt.proposed.isEmpty {
            body += "\nReview proposed contradictions with moot_lens_contradiction, then accept/reject via moot_review_tunnel."
        }
        return ToolDispatcher.textResult(body)
    }

    // MARK: - hunt contradictions

    /// Run `moot_hunt_contradictions`: one bounded contradiction-hunt sweep.
    /// Strong findings persist as proposed contradicts tunnels (the hunt does
    /// its own writes); borderline candidates come back with snippets for the
    /// calling agent to adjudicate.
    private static func runHuntContradictions(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let now: Date
        if let raw = try optionalString(args["now"], argument: "now") {
            guard let parsed = ISO8601DateFormatter().date(from: raw) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "now is not a valid ISO8601 instant: \(raw)")
            }
            now = parsed
        } else {
            now = Date()
        }
        var probeLimit = 500
        if let raw = args["probe_limit"] {
            guard case .integer(let n) = raw, n > 0, n <= 10_000 else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "probe_limit must be an integer in 1...10000")
            }
            probeLimit = Int(n)
        }

        // Sensitivity ceiling is hardcoded .elevated (fail-safe by design); huntContradictions does NOT consult SensitivityGrantLedger.
        let report = try await kit.huntContradictions(
            in: handle, probeLimit: probeLimit, now: now)

        guard report.vectorStoreAvailable else {
            return ToolDispatcher.textResult(
                "moot_hunt_contradictions: no vector index for this estate — "
                    + "run moot_reindex first, then hunt again.")
        }

        var lines: [String] = [
            "moot_hunt_contradictions: sweep complete",
            "probesScanned: \(report.probesScanned)",
            "pairsScreened: \(report.pairsScreened)",
            "alreadySettled: \(report.deduplicated)",
            "proposed: \(report.proposed.count)",
        ]
        for p in report.proposed {
            lines.append("  PROPOSED \(p.sourceDrawerID) contradicts \(p.targetDrawerID) "
                + "(\(p.cueKind), score \(p.score), tunnel \(p.tunnelID))")
        }
        if !report.proposed.isEmpty {
            lines.append("Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.")
        }
        lines.append("borderlineCandidates: \(report.borderline.count)")
        for c in report.borderline {
            lines.append("  CANDIDATE \(c.sourceDrawerID) vs \(c.targetDrawerID) "
                + "(\(c.cueKind), score \(c.score))")
            lines.append("    a: \(c.sourceSnippet)")
            lines.append("    b: \(c.targetSnippet)")
        }
        if !report.borderline.isEmpty {
            lines.append("Judge each CANDIDATE pair: if the two memories genuinely conflict, "
                + "record it with moot_link_memories kind=contradicts proposed=true; otherwise ignore it.")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - consolidate

    /// Run `moot_consolidate`: trigger a per-item distillation sweep on demand.
    ///
    /// Decodes the optional `cluster_id` and `include_held` args (accepted for
    /// API stability, not used by the per-item model) and delegates to the
    /// Consolidate recipe, which calls GLK.distillItemsSweep. Returns a
    /// plain-text summary of factoids produced this sweep.
    private static func runConsolidate(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let clusterID = try optionalString(args["cluster_id"], argument: "cluster_id")
        // include_held: boolean parameter — absent means false (the safe default).
        // Present non-bool values are rejected so the caller knows what went wrong.
        let includeHeld: Bool
        if let raw = args["include_held"] {
            guard let b = raw.boolValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "include_held must be a boolean; omit it to use the default (false)")
            }
            includeHeld = b
        } else {
            includeHeld = false
        }

        let out = try await Consolidate().run(
            input: .init(clusterID: clusterID, includeHeld: includeHeld),
            estate: handle, kit: kit)

        let body = """
        moot_consolidate: sweep complete
        factoidsProduced: \(out.factoidsProduced)
        """
        return ToolDispatcher.textResult(body)
    }

    // MARK: - recall_distilled

    /// Run `moot_recall_distilled`: dense Hamming NN recall over the distilled tier.
    ///
    /// Decodes query, limit, filter, and estateID, runs the DistilledRecall recipe,
    /// and formats output as:
    ///   found N distilled factoid(s) for: {query}
    ///   [1] drawer_id: {uuid}
    ///       {prose}
    ///       confidence: X | sources: N | snr: X | delta: TYPE [uncertain]
    ///   ...
    ///   discrimination: {level} — {description}
    private static func runRecallDistilled(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let query = try requireString(args, "query")
        // Clamp to [1, 500]: same DoS gate as moot_memory_search and the other
        // recall tools. Parity: Rust run_recall_distilled_tool uses clamp_limit.
        let limit = try ToolDispatcher.clampLimit(
            try optionalInt(args["limit"], argument: "limit"), argument: "limit")
        let filter = try decodeSingleFilter(args["filter"])

        let out: DistilledRecall.Output
        do {
            out = try await DistilledRecall().run(
                input: .init(query: query, filter: filter, limit: limit),
                estate: handle, kit: kit)
        } catch {
            // Any error from DistilledRecall().run — including a missing
            // distillation-features-v1 VectorKit lane — returns "found 0"
            // and suggests moot_consolidate to build the distilled tier.
            let body = """
            found 0 distilled factoid(s) for: \(query)

            discrimination: single — only one result.
            hint: distilled tier not yet available for this estate. \
            Run moot_consolidate to build the distilled tier from accumulated memories.
            """
            return ToolDispatcher.textResult(body)
        }

        var lines: [String] = [
            "found \(out.matches.count) distilled factoid(s) for: \(query)",
        ]

        for (idx, match) in out.matches.enumerated() {
            lines.append("")
            lines.append("[\(idx + 1)] drawer_id: \(match.id)")
            // Preview cap: distilled prose can be arbitrarily long; cap at 300 chars
            // to prevent context-window overflow in the LLM caller.
            // Parity: Rust run_recall_distilled_tool uses DISTILLED_PROSE_PREVIEW_CAP.
            let prose = String(match.prose.prefix(ToolDispatcher.distilledProseCap))
            lines.append("    \(prose)")

            // Metadata line — delta and uncertain are optional.
            var meta = "confidence: \(String(format: "%.2f", match.confidence))"
                + " | sources: \(match.sourceCount)"
                + " | snr: \(String(format: "%.1f", match.snr))"
            if let delta = match.deltaType {
                meta += " | delta: \(delta)"
            }
            if match.uncertain {
                meta += " [uncertain]"
            }
            lines.append("    \(meta)")
        }

        lines.append("")
        // Discrimination signal mirrors moot_memory_search format (RecallDiscrimination.resultLine).
        let discLevel: String
        switch out.discrimination {
        case .high:   discLevel = "discrimination: high — clear top result."
        case .medium: discLevel = "discrimination: medium — some separation."
        case .low:    discLevel = "discrimination: low — results are effectively unranked."
        case .single: discLevel = "discrimination: single — only one result."
        }
        lines.append(discLevel)

        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - recollect

    /// Run `moot_recollect`: fan-out from a distilled factoid to its source memories.
    ///
    /// Decodes `drawer_id` and estateID, runs the Recollect recipe, and formats
    /// output as:
    ///   expand: {drawer_id}
    ///   factoid: {prose}
    ///   confidence: X | sources: N | delta: TYPE
    ///
    ///   source [1] — room: {room} | id: {uuid}
    ///   {full content}
    ///   ...
    ///
    /// RecollectError cases map to errorResult with guidance for the caller.
    private static func runRecollect(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let drawerID = try requireString(args, "drawer_id")

        let out: Recollect.Output
        do {
            out = try await Recollect().run(
                input: .init(factoidDrawerID: drawerID),
                estate: handle, kit: kit)
        } catch let err as RecollectError {
            switch err {
            case .notADistilledDrawer(let id):
                return ToolDispatcher.errorResult(
                    "drawer \(id) is not a distilled factoid. "
                        + "Use moot_recall_distilled to find distilled drawers.")
            case .factoidNotFound(let id):
                return ToolDispatcher.errorResult(
                    "drawer \(id) not found — it may have been expunged from the estate.")
            case .noSourceTunnels(let id):
                return ToolDispatcher.errorResult(
                    "drawer \(id) has no _distilled_from tunnels. "
                        + "The factoid may predate tunnel wiring — "
                        + "fall back to lineage_id query to locate source drawers.")
            }
        }

        var lines: [String] = [
            "expand: \(out.factoidID)",
            "factoid: \(out.prose)",
        ]
        var meta = "confidence: \(String(format: "%.2f", out.confidence))"
            + " | sources: \(out.sourceCount)"
        if let delta = out.deltaType {
            meta += " | delta: \(delta)"
        }
        lines.append(meta)

        // node-tree integrity bridge consumer: source.room is a display name for provenance.
        for (idx, source) in out.sources.enumerated() {
            lines.append("")
            lines.append("source [\(idx + 1)] — room: \(source.room) | id: \(source.id)")
            lines.append(source.content)
        }

        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - Argument decoding

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let v = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return v
    }

    private static func requireUUID(
        _ args: [String: JSONValue], _ key: String
    ) throws -> UUID {
        let raw = try requireString(args, key)
        guard let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Argument \(key) is not a UUID: \(raw)")
        }
        return uuid
    }

    private static func optionalString(_ value: JSONValue?, argument: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be a string; omit it to use the default")
        }
        return string
    }

    private static func optionalInt(_ value: JSONValue?, argument: String) throws -> Int? {
        guard let value else { return nil }
        guard let integer = value.integerValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(argument) must be an integer; omit it to use the default")
        }
        return Int(integer)
    }

    private static func decodeUUIDArray(_ value: JSONValue?) throws -> [UUID] {
        guard let arr = value?.arrayValue else { return [] }
        var out: [UUID] = []
        out.reserveCapacity(arr.count)
        for element in arr {
            guard let s = element.stringValue, let uuid = UUID(uuidString: s) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "Branch id array contains a non-UUID value")
            }
            out.append(uuid)
        }
        return out
    }

    /// Decode the candidate migration plans.
    private static func decodePlans(_ value: JSONValue?) throws -> [MigrationPlan] {
        guard let arr = value?.arrayValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "plans must be an array")
        }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let name = obj["name"]?.stringValue,
                  let room = obj["room"]?.stringValue,
                  let code = obj["latticeCode"]?.stringValue,
                  let model = obj["embeddingModelID"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each plan needs name, room, latticeCode, embeddingModelID")
            }
            let sensitivity = try decodeSensitivity(obj["sensitivity"])
            return MigrationPlan(
                name: name, room: room, latticeCode: code,
                embeddingModelID: model, sensitivity: sensitivity)
        }
    }

    /// Recall filter-chain decode for grounded_synthesis. Omitted filter means
    /// ordinary recall: LocusKit inserts state/trust/sensitivity defaults, but
    /// no confirmation constraint.
    private static func decodeFilterChain(_ value: JSONValue?) throws -> [LocusKit.Filter] {
        guard let name = try optionalString(value, argument: "filter") else { return [] }
        switch name {
        case "unconfirmed": return [.unconfirmed]
        case "userConfirmed": return [.userConfirmed]
        case "exportable": return [.exportable]
        case "contained": return [.contained]
        case "currentlyBelieve": return [.currentlyBelieve]
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)")
        }
    }

    /// Shared single-filter decoder used by precise recall, shaped recall, and
    /// distilled recall. Omitted filter maps to the active-recall default
    /// (.currentlyBelieve) without adding a confirmation constraint.
    private static func decodeSingleFilter(_ value: JSONValue?) throws -> LocusKit.Filter {
        guard let name = try optionalString(value, argument: "filter") else { return .currentlyBelieve }
        switch name {
        case "unconfirmed": return .unconfirmed
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        case "currentlyBelieve": return .currentlyBelieve
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown filter: \(name)")
        }
    }

    private static func decodeSensitivity(_ value: JSONValue?) throws -> AdjectiveSensitivity {
        guard let name = try optionalString(value, argument: "sensitivity") else { return .normal }
        switch name {
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        case "normal": return .normal
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Unknown sensitivity: \(name)")
        }
    }

    // MARK: - JSON schema helpers
    //
    // ToolProjection's schema helpers are private to that type, so the
    // recipe surface carries its own minimal copies. Identical shapes —
    // a future refactor could promote one shared set.

    private static func objectSchema(
        properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func stringSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerSchema(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
