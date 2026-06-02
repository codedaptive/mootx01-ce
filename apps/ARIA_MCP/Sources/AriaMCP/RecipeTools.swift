// RecipeTools.swift
//
// The CognitionKit behaviour-recipe surface on ARIA_MCP. These tools sit
// ABOVE the lexicon projection (provenance `.recipe`, dispatched by name)
// exactly as the federation `cross_estate_recall` tool does. They are the
// conscious-mind surface: the MCP↔CognitionKit channel is R/W, so an
// agent reads what recipes exist and triggers them, and the human-in-the-
// loop confirms the migration promotion.
//
// Six tools ship here:
//   - moot_list_recipes               → RecipeCatalog enumeration (read)
//   - moot_grounded_synthesis         → GroundedSynthesis recipe (read)
//   - moot_run_migration_benchmark    → MigrationBenchmark.run (read; no
//                                        promotion — B-3)
//   - moot_confirm_migration_promotion → MigrationBenchmark.confirmPromotion
//                                        by branch id (the human-gated write)
//   - moot_association_rules          → AssociationRules recipe (read)
//   - moot_formal_concepts            → FormalConcepts recipe (read)
//
// Stateless-boundary discipline: MCP `tools/call` is stateless across
// invocations, so the run tool cannot hand live `BranchHandle`s to a
// later confirm tool. The run tool surfaces branch *ids* in its result;
// the confirm tool takes those ids and re-resolves them through the
// long-lived kit's `GeniusLocusKit.branchHandle(for:)` accessor. This is
// the two-call run→confirm pattern the plan describes; webhook delivery
// of async completion is an additive transport, not needed for the
// synchronous behaviour.
//
// Note: the Rust MCP server's tools for moot_association_rules and
// moot_formal_concepts are sequenced after ARIA_MCP_RUST_001 merges
// (that mission is building the Rust server right now). The Rust tools
// are a follow-up; this file is the Swift-side delivery only.

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit

/// Namespace for the CognitionKit recipe tool surface. No instances.
enum RecipeTools {

    // MARK: - Tool names

    static let listRecipesToolName = "moot_list_recipes"
    static let groundedSynthesisToolName = "moot_grounded_synthesis"
    static let runMigrationBenchmarkToolName = "moot_run_migration_benchmark"
    static let confirmMigrationPromotionToolName = "moot_confirm_migration_promotion"
    static let associationRulesToolName = "moot_association_rules"
    static let formalConceptsToolName = "moot_formal_concepts"

    /// True when `name` is one of the recipe tools dispatched by name.
    static func isRecipeTool(_ name: String) -> Bool {
        name == listRecipesToolName
            || name == groundedSynthesisToolName
            || name == runMigrationBenchmarkToolName
            || name == confirmMigrationPromotionToolName
            || name == associationRulesToolName
            || name == formalConceptsToolName
    }

    // MARK: - tools/list projection

    /// All recipe tool descriptors, advertised in `tools/list`
    /// after the lexicon projection and the federation tool.
    static func tools() -> [ProjectedTool] {
        [
            listRecipesTool(),
            groundedSynthesisTool(),
            runMigrationBenchmarkTool(),
            confirmMigrationPromotionTool(),
            associationRulesTool(),
            formalConceptsTool(),
        ]
    }

    /// The recipe-discovery tool. Reads `RecipeCatalog` so the surfaced
    /// list stays in lockstep with the shipped recipes — a new recipe
    /// registered in the catalog appears here automatically. Takes no
    /// arguments; it is the conscious mind enumerating its own behaviours.
    private static func listRecipesTool() -> ProjectedTool {
        ProjectedTool(
            name: listRecipesToolName,
            description: "List the available CognitionKit behaviour recipes — each with its version, description, and the NeuronKit capabilities it requires.",
            inputSchema: objectSchema(properties: [:], required: []),
            provenance: .recipe)
    }

    private static func groundedSynthesisTool() -> ProjectedTool {
        ProjectedTool(
            name: groundedSynthesisToolName,
            description: "Behaviour recipe: hybrid-recall a query and synthesize the recalled drawers into a single grounded context document (summary, patterns, success rate, recommendations, key insights).",
            inputSchema: objectSchema(
                properties: [
                    "filter": stringSchema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve."),
                    "limit": integerSchema("Max drawers to recall."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    private static func runMigrationBenchmarkTool() -> ProjectedTool {
        ProjectedTool(
            name: runMigrationBenchmarkToolName,
            description: "Behaviour recipe: derive one COW branch per migration plan, populate each from the origin corpus, benchmark recall fidelity with the zero-silent-loss gate, and rank survivors. Never promotes — returns branch ids for a separate confirm step.",
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
            description: "Behaviour recipe (human-confirmed write): promote a migration-benchmark winner branch into the estate and discard the losers, by branch id. Refuses to promote a branch the run report disqualified.",
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
        // Recipe discovery needs no estate; answer it before resolving a
        // handle so `moot_list_recipes` works even with no estate targeted.
        if name == listRecipesToolName {
            return runListRecipes()
        }
        let handle = try resolveHandle(args)
        switch name {
        case groundedSynthesisToolName:
            return try await runGroundedSynthesis(args, kit: kit, handle: handle)
        case runMigrationBenchmarkToolName:
            return try await runMigrationBenchmark(args, kit: kit, handle: handle)
        case confirmMigrationPromotionToolName:
            return try await runConfirmPromotion(args, kit: kit, handle: handle)
        case associationRulesToolName:
            return try await runAssociationRules(args, kit: kit, handle: handle)
        case formalConceptsToolName:
            return try await runFormalConcepts(args, kit: kit, handle: handle)
        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown recipe tool: \(name)")
        }
    }

    // MARK: - list_recipes

    /// Render the recipe catalog as a text listing. Pure read over
    /// `RecipeCatalog` — no estate, no substrate touch.
    private static func runListRecipes() -> JSONValue {
        var lines: [String] = ["recipes: \(RecipeCatalog.all.count)"]
        for descriptor in RecipeCatalog.all {
            let caps = descriptor.requiredCapabilities
                .map(\.rawValue).joined(separator: ", ")
            lines.append("  - \(descriptor.name) v\(descriptor.version)")
            lines.append("      \(descriptor.description)")
            lines.append("      capabilities: \(caps)")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - grounded_synthesis

    private static func runGroundedSynthesis(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let filter = decodeFilter(args["filter"]?.stringValue)
        let limit = args["limit"]?.integerValue.map(Int.init)
        let frame = LocusKit.RecallFrame(
            filterChain: [filter],
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

    // MARK: - run_migration_benchmark

    private static func runMigrationBenchmark(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let corpusName = try requireString(args, "corpusName")
        let entries = try decodeEntries(args["entries"])
        let plans = try decodePlans(args["plans"])
        guard !plans.isEmpty else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "run_migration_benchmark requires at least one plan")
        }

        let origin = ExternalCorpus(name: corpusName, entries: entries)
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

    // MARK: - association_rules

    private static func associationRulesTool() -> ProjectedTool {
        ProjectedTool(
            name: associationRulesToolName,
            description: "Behaviour recipe: recall a frame, project each drawer's categorical facets (room, kind, channel, sensitivity) into a co-occurrence matrix, and mine pairwise association rules with the five standard metrics (support, confidence, lift, conviction, leverage).",
            inputSchema: objectSchema(
                properties: [
                    "filter": stringSchema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve."),
                    "limit": integerSchema("Max drawers to recall."),
                    "minSupport": .object(["type": .string("number"), "description": .string("Minimum rule support (0..1). Default 0.")]),
                    "minConfidence": .object(["type": .string("number"), "description": .string("Minimum rule confidence (0..1). Default 0.")]),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    private static func runAssociationRules(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let filter = decodeFilter(args["filter"]?.stringValue)
        let limit = args["limit"]?.integerValue.map(Int.init)
        let minSupport = doubleArg(args["minSupport"]) ?? 0.0
        let minConfidence = doubleArg(args["minConfidence"]) ?? 0.0
        let frame = LocusKit.RecallFrame(
            filterChain: [filter],
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc)

        let out = try await AssociationRules().run(
            input: .init(
                frame: frame,
                thresholds: MiningThresholds(minSupport: minSupport, minConfidence: minConfidence)),
            estate: handle, kit: kit)

        var lines = [
            "association_rules: \(out.rules.count) rule(s) from \(out.drawerCount) drawer(s)",
        ]
        if out.labelOverflow {
            lines.append("note: label vocabulary was capped at 64; some labels were dropped")
        }
        for rule in out.rules {
            lines.append(
                "  \(rule.antecedent) → \(rule.consequent): "
                + "sup=\(String(format: "%.3f", rule.support)) "
                + "conf=\(String(format: "%.3f", rule.confidence)) "
                + "lift=\(String(format: "%.3f", rule.lift))")
        }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - formal_concepts

    private static func formalConceptsTool() -> ProjectedTool {
        ProjectedTool(
            name: formalConceptsToolName,
            description: "Behaviour recipe: recall a frame, build a formal context where each drawer is a row with its categorical facets (room, kind, channel, sensitivity) as attributes, and mine bounded formal concepts (maximal attribute closures).",
            inputSchema: objectSchema(
                properties: [
                    "filter": stringSchema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve."),
                    "limit": integerSchema("Max drawers to recall."),
                    "minSupport": integerSchema("Minimum concept extent size. Default 1."),
                    "maxIntentSize": integerSchema("Maximum concept intent size. Default 8."),
                    "maxConcepts": integerSchema("Maximum concepts returned. Default 20."),
                    "estateID": stringSchema("Optional UUID of the open estate to target. Omit for the default estate."),
                ],
                required: []),
            provenance: .recipe)
    }

    private static func runFormalConcepts(
        _ args: [String: JSONValue],
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> JSONValue {
        let filter = decodeFilter(args["filter"]?.stringValue)
        let limit = args["limit"]?.integerValue.map(Int.init)
        let minSupport = args["minSupport"]?.integerValue.map(Int.init) ?? 1
        let maxIntentSize = args["maxIntentSize"]?.integerValue.map(Int.init) ?? 8
        let maxConcepts = args["maxConcepts"]?.integerValue.map(Int.init) ?? 20
        let frame = LocusKit.RecallFrame(
            filterChain: [filter],
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc)

        let out = try await FormalConcepts().run(
            input: .init(
                frame: frame,
                miner: BoundedConceptMiner(
                    minSupport: minSupport,
                    maxIntentSize: maxIntentSize,
                    maxConcepts: maxConcepts)),
            estate: handle, kit: kit)

        var lines = [
            "formal_concepts: \(out.concepts.count) concept(s) from \(out.drawerCount) drawer(s)",
        ]
        for (i, concept) in out.concepts.enumerated() {
            lines.append("  concept \(i + 1): support=\(concept.support)")
            lines.append("    intent: \(concept.intent.joined(separator: ", "))")
            lines.append("    extent: \(concept.extentDrawerIDs.count) drawer(s)")
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

    /// Decode the origin corpus entries. Each entry needs string `id` and
    /// `content`; `tags` is an optional string array.
    private static func decodeEntries(_ value: JSONValue?) throws -> [ExternalEntry] {
        guard let arr = value?.arrayValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "entries must be an array")
        }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let id = obj["id"]?.stringValue,
                  let content = obj["content"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each entry needs string id and content")
            }
            let tags = (obj["tags"]?.arrayValue ?? []).compactMap { $0.stringValue }
            return ExternalEntry(id: id, content: content, tags: tags)
        }
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
            let sensitivity = decodeSensitivity(obj["sensitivity"]?.stringValue)
            return MigrationPlan(
                name: name, room: room, latticeCode: code,
                embeddingModelID: model, sensitivity: sensitivity)
        }
    }

    /// Recall filter decode for grounded_synthesis. Defaults to
    /// `.unconfirmed` so freshly-captured rows (provenance == 0) are
    /// visible — the default recall prepend would otherwise prune them
    /// behind `.userConfirmed`.
    private static func decodeFilter(_ name: String?) -> LocusKit.Filter {
        switch name {
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        case "currentlyBelieve": return .currentlyBelieve
        default: return .unconfirmed
        }
    }

    private static func decodeSensitivity(_ name: String?) -> AdjectiveSensitivity {
        switch name {
        case "elevated": return .elevated
        case "restricted": return .restricted
        case "secret": return .secret
        default: return .normal
        }
    }

    // MARK: - Numeric argument decoding

    /// Extract a `Double` from a `.double` or `.integer` JSON value.
    /// Returns `nil` for absent or non-numeric values.
    private static func doubleArg(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
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
