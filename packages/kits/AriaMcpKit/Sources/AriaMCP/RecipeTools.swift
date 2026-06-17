// RecipeTools.swift
//
// The CognitionKit behaviour-recipe surface on ARIA_MCP. These tools sit
// ABOVE the lexicon projection (provenance `.recipe`, dispatched by name)
// exactly as the federation `cross_estate_recall` tool does. They are the
// conscious-mind surface: the MCP↔CognitionKit channel is R/W, so an
// agent reads what recipes exist and triggers them, and the human-in-the-
// loop confirms the migration promotion.
//
// Five foundational tools ship here:
//   - moot_list_lenses           → ProjectedTool descriptor enumeration
//                                   (LensTools + RecipeTools, Tier 6 only — read)
//   - moot_list_recipes          → RecipeCatalog descriptor enumeration
//                                   (all 23 shipped recipes — catalog discovery)
//   - moot_synthesize            → GroundedSynthesis recipe (read)
//   - moot_run_migration         → MigrationBenchmark.run (read; no
//                                   promotion — B-3)
//   - moot_confirm_migration     → MigrationBenchmark.confirmPromotion
//                                   by branch id (the human-gated write)
//
// The analytics recipes (moot_association_rules, moot_formal_concepts) and
// all 14 reasoning-lens recipes ship through LensTools.swift — same
// provenance (.recipe), dispatched through the lens surface per
// LENS_DISCOVERABILITY_DECISION v2.0.
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
            description: "Shaped recall: run recall with a named RecallShape preset that forwards, excludes, suppresses, or inverts individual fusion lanes (and bounds the candidate frontier). Pick ONE preset by name. Roster: \(presetRosterListing()). Returns the same shape as moot_memory_search.",
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
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid."),
                ],
                required: ["query"]),
            provenance: .recipe)
    }

    /// The cognition-discovery tool. At runtime (`runListRecipes`), returns
    /// one block per Tier 6 tool drawn from `LensTools.tools()` and the two
    /// non-migration entries in `RecipeTools.tools()` — not `RecipeCatalog`.
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
            description: "Precise recall: coarse-grab a generous candidate pool then re-rank by query-specific precision (distinctive number/proper-noun match) to surface the exact answer above near-duplicates. Lifts found@1/MRR without dropping found@10. Returns the same shape as moot_memory_search.",
            inputSchema: objectSchema(
                properties: [
                    "query": stringSchema("The search query text — drives BM25 + vector recall and the precision re-rank."),
                    "limit": integerSchema("Max ranked matches to return. Default 20. Omit to use the default; null is invalid."),
                    "pool": integerSchema("Coarse candidate-pool size grabbed before the precision re-rank. Default 30; clamped to be at least limit. Omit to use the default; null is invalid."),
                    "composition": stringSchema("Named reduction composition selecting how the coarse pool is re-ranked (the ablation selector). E.g. text (default), hamming, matrix, lattice, tokenExact, hamming+tokenExact, hamming+text, text+matrix, lattice+hamming, text+tokenExact, text+mmr, weighted-all. Omit for the default (text). Unknown names and null are rejected."),
                    "filter": stringSchema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary active recall across any confirmation state. null is invalid."),
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
                    "disqualifiedBranchIDs": .object([
                        "type": .string("array"),
                        "description": .string("UUIDs the run report disqualified; the C-5 guard refuses to promote any of these."),
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
            description: "Dream the estate: rebuild the co-occurrence/temporal matrix tier (the Brain's association layer that the matrix recall lane scores against) and run one dreaming cycle (latent-alignment proposals + cycle diary). The matrix is built by dreaming, not by capture, so a freshly-loaded estate has an empty matrix until this runs. Returns a cycle summary.",
            inputSchema: objectSchema(
                properties: [
                    "now": stringSchema("Optional ISO8601 instant to run the cycle at, for deterministic runs (drives the diary timestamp and the reward window). Omit to use the current wall clock."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
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
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown recipe tool: \(name)")
        }
    }

    // MARK: - list_lenses (cognition menu)

    /// Return a one-block-per-tool cognition menu drawn from the shipped
    /// `ProjectedTool` descriptors. Shows name, description, and required
    /// args for each Tier 6 cognition tool — the 21 lens tools plus
    /// `moot_synthesize` and `moot_list_lenses` itself.
    /// Migration tools (Tier 7) are intentionally excluded here; they have
    /// their own teachme guides and a separate caller workflow.
    private static func runListRecipes() -> JSONValue {
        // Tier 6 recipe tools: list-lenses + synthesize + precise recall + shaped
        // recall (not migration, which is Tier 7).
        let tier6RecipeNames: Set<String> = [
            listRecipesToolName, groundedSynthesisToolName,
            preciseRecallToolName, shapedRecallToolName,
        ]
        let recipeTools = tools().filter { tier6RecipeNames.contains($0.name) }
        // All 21 lens tools from LensTools.
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
        let limit = try optionalInt(args["limit"], argument: "limit")
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
    /// header line then one `id  [room]  preview` line per ranked match.
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
        // 20 is moot_memory_search's own default limit; keep parity.
        let limit = try optionalInt(args["limit"], argument: "limit") ?? 20
        // Default coarse pool is CognitionKit's own default (30); honour an
        // explicit override. The recipe clamps pool >= limit internally.
        let pool = try optionalInt(args["pool"], argument: "pool") ?? CognitionKit.PreciseRecall.defaultPool
        let filter = try decodeSingleFilter(args["filter"])
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

        var lines: [String] = ["found \(matches.count) memory(s)"]
        for match in matches.prefix(50) {
            // Match moot_memory_search's preview: first 120 chars of content.
            let preview = match.content.prefix(120)
            let room = match.room.isEmpty ? "?" : match.room
            lines.append("\(match.id)  [\(room)]  \(preview)")
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
        // 20 is moot_memory_search's own default limit; keep parity.
        let limit = try optionalInt(args["limit"], argument: "limit") ?? 20
        let filter = try decodeSingleFilter(args["filter"])

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

        var lines: [String] = ["found \(out.matches.count) memory(s)"]
        for match in out.matches.prefix(50) {
            let preview = match.content.prefix(120)
            let room = match.room.isEmpty ? "?" : match.room
            lines.append("\(match.id)  [\(room)]  \(preview)")
        }
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

        // ADR-007 Decision 1 (VK-ADAPT-01): VaultKit's adapter pipeline
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
        lines.append("To promote, call \(confirmMigrationPromotionToolName) with winnerBranchID, discardBranchIDs (the other ranking ids), and disqualifiedBranchIDs from above.")
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
        let disqualified = Set(try decodeUUIDArray(args["disqualifiedBranchIDs"]))

        do {
            try await MigrationBenchmark().confirmPromotion(
                winnerBranchID: winner,
                discardBranchIDs: discard,
                disqualifiedBranchIDs: disqualified,
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

        // Step 1 — rebuild + register the matrix tier (the un-starving step).
        try await kit.rebuildDerivedAccelerators(for: handle)

        // Step 2 — one dreaming cycle over the live estate seams, constructed
        // exactly as the AutonomicGovernor does for the resident process.
        let daemon = NeuronKit.dreamingDaemon(
            reader: EstateDreamingReader(handle: handle, kit: kit),
            sink: EstateDreamingSink(handle: handle, kit: kit),
            policyStore: InMemoryDreamingPolicyStore())
        let report = try await daemon.triggerDreamingCycle(now: now)

        let body = """
        moot_dream: matrix rebuilt, dreaming cycle complete
        consideredCandidates: \(report.candidatesConsidered)
        proposalsEmitted: \(report.proposalsEmitted.count)
        suppressedDuplicates: \(report.suppressedDuplicates)
        belowThreshold: \(report.belowThreshold)
        """
        return ToolDispatcher.textResult(body)
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

    /// PreciseRecall's current public API accepts one filter entry. Omitted
    /// filter uses the same active-recall default as an empty chain without
    /// adding a confirmation constraint.
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
