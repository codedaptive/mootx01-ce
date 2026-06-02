// LensTools.swift
//
// The CognitionKit reasoning-lens surface on ARIA_MCP — one hard-bound
// tool per cataloged lens recipe (LENS_DISCOVERABILITY_DECISION v2.0:
// listing and invokability ship together; `moot_list_recipes` never
// advertises a behaviour an agent cannot reach). Same dispatch shape as
// RecipeTools: provenance `.recipe`, matched by name above the lexicon
// projection, no generic run-by-name dispatcher.
//
// Tool stem = catalog name: moot_keystones … moot_formal_concepts.
// The 14 reasoning lenses span structure, topic, preference, surprise,
// grounding/trust, associative, prediction, and federated categories.
// The 2 analytics lenses (moot_association_rules, moot_formal_concepts)
// follow in catalog order.
// The two federated lenses take a second estate via `estateIDB`,
// resolved through the dispatcher's own estate registry exactly like
// `estateID`.

import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit

/// Namespace for the reasoning-lens tool surface. No instances.
enum LensTools {

    // MARK: - Tool names (catalog name with the moot_ stem)

    static let lensToolNames: Set<String> = [
        "moot_keystones", "moot_constellation", "moot_free_association",
        "moot_theme_weather", "moot_latent_themes", "moot_bias",
        "moot_drift", "moot_contradiction", "moot_trust_grounded_synthesis",
        "moot_partial_cue_recall", "moot_anticipate", "moot_tunnel_successor",
        "moot_mind_overlap", "moot_estate_divergence",
        "moot_association_rules", "moot_formal_concepts",
    ]

    /// True when `name` is one of the lens tools dispatched by name.
    static func isLensTool(_ name: String) -> Bool {
        lensToolNames.contains(name)
    }

    // MARK: - tools/list projection

    static func tools() -> [ProjectedTool] {
        [
            ProjectedTool(
                name: "moot_keystones",
                description: "Reasoning lens: rank a wing's load-bearing memories by centrality over its drawer-to-drawer tunnel graph.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to read."),
                        "topK": integerSchema("How many keystones to return (default 5)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_constellation",
                description: "Reasoning lens: recover the emergent communities of a wing's drawer-to-drawer tunnel graph.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to read."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_free_association",
                description: "Reasoning lens: from a seed memory, walk the wing's tunnel graph with restart and rank the memories the walk keeps landing on.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnel graph to walk."),
                        "seedDrawerID": stringSchema("The drawer id to associate from."),
                        "walkLength": integerSchema("Walk steps (default 10000)."),
                        "k": integerSchema("How many associations to return (default 10)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing", "seedDrawerID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_theme_weather",
                description: "Reasoning lens: per-room momentum — recent attention share vs historical share; what's rising and what's fading.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "halfLifeSeconds": numberSchema("Attention half-life in seconds (default 604800 = 7 days)."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_latent_themes",
                description: "Reasoning lens: factor the recalled set's metadata co-occurrence into soft latent themes — the emergent topics in how the estate is filed.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "k": integerSchema("How many themes to factor (default 3)."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_bias",
                description: "Reasoning lens: representation bias vs a reference, per-room dismissal rates, and learned preference from real curation choices.",
                inputSchema: objectSchema(
                    properties: [
                        "reference": .object([
                            "type": .string("array"),
                            "description": .string("Reference distribution: objects with string label and number mass. Empty = report estate shares alone."),
                            "items": objectSchema(
                                properties: [
                                    "label": stringSchema("Room / category label."),
                                    "mass": numberSchema("Reference mass for the label."),
                                ],
                                required: ["label", "mass"]),
                        ]),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_drift",
                description: "Reasoning lens: how far the room distribution after a split instant has drifted from the distribution before it.",
                inputSchema: objectSchema(
                    properties: [
                        "splitAt": stringSchema("ISO8601 instant splitting the before/after windows."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["splitAt"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_contradiction",
                description: "Reasoning lens: flag the recalled memories whose content cohesion with their peers is anomalously low — the odd-ones-out.",
                inputSchema: objectSchema(
                    properties: [
                        "threshold": numberSchema("Z-score magnitude threshold (default 1.5)."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_trust_grounded_synthesis",
                description: "Reasoning lens: recall, rank by provenance trust (canonical and user above derived), and synthesize the trust-ordered set.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_partial_cue_recall",
                description: "Reasoning lens: one anchor memory, three recalls — feels-like, about-this, from-then — by per-block fingerprint matching.",
                inputSchema: objectSchema(
                    properties: [
                        "anchorID": stringSchema("The anchor drawer id (the cue)."),
                        "mode": stringSchema("Cue mode: feelsLike (default), aboutThis, fromThen."),
                        "k": integerSchema("How many matches to return (default 5)."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["anchorID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_anticipate",
                description: "Reasoning lens: learn which capture actions tend to reach a target outcome, ranked by conservative success rate.",
                inputSchema: objectSchema(
                    properties: [
                        "targetKind": stringSchema("Target outcome as a content kind: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly."),
                        "k": integerSchema("How many actions to return (default 5)."),
                        "minObservations": integerSchema("Minimum observations per action (default 1)."),
                        "filter": filterSchema,
                        "estateID": estateIDSchema,
                    ],
                    required: ["targetKind"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_tunnel_successor",
                description: "Reasoning lens: the memories an anchor points onward to by explicit tunnels, ranked by frequency.",
                inputSchema: objectSchema(
                    properties: [
                        "wing": stringSchema("The wing whose tunnels to read."),
                        "anchorID": stringSchema("The anchor drawer id."),
                        "k": integerSchema("How many successors to return (default 5)."),
                        "estateID": estateIDSchema,
                    ],
                    required: ["wing", "anchorID"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_mind_overlap",
                description: "Reasoning lens (federated): privacy-preserving overlap of two estates via differentially-private fingerprint summaries.",
                inputSchema: objectSchema(
                    properties: [
                        "estateID": stringSchema("Optional UUID of estate A. Omit for the default estate."),
                        "estateIDB": stringSchema("UUID of estate B (must be a registered open estate)."),
                        "filter": filterSchema,
                    ],
                    required: ["estateIDB"]),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_estate_divergence",
                description: "Reasoning lens (federated): how two estates' room distributions diverge, by Jensen-Shannon divergence.",
                inputSchema: objectSchema(
                    properties: [
                        "estateID": stringSchema("Optional UUID of estate A. Omit for the default estate."),
                        "estateIDB": stringSchema("UUID of estate B (must be a registered open estate)."),
                        "filter": filterSchema,
                    ],
                    required: ["estateIDB"]),
                provenance: .recipe),
            // Analytics lenses.
            ProjectedTool(
                name: "moot_association_rules",
                description: "Recall a frame, project each drawer's categorical facets into a co-occurrence matrix, and mine pairwise association rules.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "limit": integerSchema("Max drawers to recall."),
                        "minSupport": .object(["type": .string("number"), "description": .string("Minimum rule support (0..1). Default 0.")]),
                        "minConfidence": .object(["type": .string("number"), "description": .string("Minimum rule confidence (0..1). Default 0.")]),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
            ProjectedTool(
                name: "moot_formal_concepts",
                description: "Recall a frame, build a formal context where each drawer is a row with its categorical facets as attributes, and mine bounded formal concepts.",
                inputSchema: objectSchema(
                    properties: [
                        "filter": filterSchema,
                        "limit": integerSchema("Max drawers to recall."),
                        "minSupport": integerSchema("Minimum concept extent size. Default 1."),
                        "maxIntentSize": integerSchema("Maximum concept intent size. Default 8."),
                        "maxConcepts": integerSchema("Maximum concepts returned. Default 20."),
                        "estateID": estateIDSchema,
                    ],
                    required: []),
                provenance: .recipe),
        ]
    }

    // MARK: - Dispatch

    /// Run the named lens tool. Same contract as `RecipeTools.dispatch`:
    /// out-of-band faults throw `JSONRPCError`; lens-level refusals come
    /// back as `errorResult` so the client keeps the call id.
    static func dispatch(
        name: String,
        args: [String: JSONValue],
        kit: GeniusLocusKit,
        defaultHandle: EstateHandle,
        resolveHandle: ([String: JSONValue]) throws -> EstateHandle
    ) async throws -> JSONValue {
        let handle = try resolveHandle(args)
        switch name {
        case "moot_keystones":
            let ranked = try await Keystones.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                topK: integer(args, "topK", default: 5))
            return list("keystones", ranked.map { "\($0.id) centrality=\($0.centrality)" })

        case "moot_constellation":
            let out = try await ConstellationLens.run(
                kit: kit, handle: handle, wing: try requireString(args, "wing"))
            return list("constellation", out.communities.map { $0.joined(separator: ", ") })

        case "moot_free_association":
            let out = try await FreeAssociationLens.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                seedDrawerID: try requireString(args, "seedDrawerID"),
                walkLength: integer(args, "walkLength", default: 10_000),
                k: integer(args, "k", default: 10))
            return list("free_association", out.map { "\($0.drawerID) activation=\($0.activation)" })

        case "moot_theme_weather":
            let weather = try await ThemeWeather.run(
                kit: kit, handle: handle, frame: frame(args),
                halfLifeSeconds: number(args, "halfLifeSeconds", default: 604_800),
                now: Date())
            return list("theme_weather", weather.map { "\($0.category) momentum=\($0.momentum)" })

        case "moot_latent_themes":
            let themes = try await LatentThemesLens.run(
                kit: kit, handle: handle, frame: frame(args),
                k: integer(args, "k", default: 3))
            return list(
                "latent_themes (k=\(themes.k))",
                themes.loadings.map { "\($0.label) → theme \($0.dominantTheme)" })

        case "moot_bias":
            let report = try await Bias.run(
                kit: kit, handle: handle, reference: try decodeReference(args["reference"]))
            var lines = ["bias"]
            lines.append("for:")
            lines += report.biasedFor.map { "  \($0.label) bias=\($0.bias)" }
            lines.append("against:")
            lines += report.biasedAgainst.map { "  \($0.label) bias=\($0.bias)" }
            lines.append("dismissal:")
            lines += report.dismissal.map { "  \($0.room) rate=\($0.rate)" }
            lines.append("learned:")
            lines += report.learned.map {
                "  \($0.label) strength=\($0.strength) (+\($0.endorsements)/−\($0.dismissals))"
            }
            return ToolDispatcher.textResult(lines.joined(separator: "\n"))

        case "moot_drift":
            let out = try await Drift.run(
                kit: kit, handle: handle, frame: frame(args),
                splitAt: try requireDate(args, "splitAt"))
            return ToolDispatcher.textResult("""
            drift: before=\(out.beforeCount) after=\(out.afterCount)
            jensenShannon: \(out.drift.jensenShannon)
            klDivergence: \(out.drift.klDivergence)
            """)

        case "moot_contradiction":
            let out = try await Contradiction.run(
                kit: kit, handle: handle, frame: frame(args),
                threshold: Float(number(args, "threshold", default: 1.5)))
            return list(
                "contradiction (considered \(out.considered))",
                out.outliers)

        case "moot_trust_grounded_synthesis":
            let out = try await TrustLens.run(
                kit: kit, handle: handle, frame: frame(args))
            return ToolDispatcher.textResult("""
            trust_grounded_synthesis: \(out.rankedIDs.count) drawer(s), \(out.highTrustCount) high-trust
            ranked: \(out.rankedIDs.joined(separator: ", "))
            summary: \(out.context.summary)
            """)

        case "moot_partial_cue_recall":
            do {
                let out = try await PartialCueRecall.run(
                    kit: kit, handle: handle, frame: frame(args),
                    anchorID: try requireString(args, "anchorID"),
                    mode: decodeCueMode(args["mode"]?.stringValue),
                    k: integer(args, "k", default: 5))
                return list("partial_cue_recall", out.map { "\($0.id) score=\($0.score)" })
            } catch let error as AnchorNotInRecalledSetError {
                // The cue pointed at nothing — a lens-level refusal, not
                // a transport fault.
                return ToolDispatcher.errorResult(
                    "anchor '\(error.anchorID)' is not in the recalled set")
            }

        case "moot_anticipate":
            guard let kind = decodeContentKind(try requireString(args, "targetKind")) else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "targetKind is not a content kind name")
            }
            let predictions = try await Anticipate.run(
                kit: kit, handle: handle, frame: frame(args),
                targetOutcome: UInt8(kind.rawValue),
                k: integer(args, "k", default: 5),
                minObservations: UInt32(integer(args, "minObservations", default: 1)))
            return list("anticipate", predictions.map {
                "action=\(channelName($0.action)) successRate=\($0.successRate) n=\($0.count)"
            })

        case "moot_tunnel_successor":
            let out = try await TunnelSuccessor.run(
                kit: kit, handle: handle,
                wing: try requireString(args, "wing"),
                anchorID: try requireString(args, "anchorID"),
                k: integer(args, "k", default: 5))
            return list("tunnel_successor", out.map { "\($0.id) weight=\($0.weight)" })

        case "moot_mind_overlap":
            let out = try await MindOverlapLens.run(
                kit: kit, handleA: handle,
                handleB: try resolveHandle(secondEstateArgs(args)),
                frame: frame(args))
            return ToolDispatcher.textResult(
                "mind_overlap: \(out.overlap) (a=\(out.aCount), b=\(out.bCount) drawer(s))")

        case "moot_estate_divergence":
            let out = try await EstateDivergenceLens.run(
                kit: kit, handleA: handle,
                handleB: try resolveHandle(secondEstateArgs(args)),
                frame: frame(args))
            return ToolDispatcher.textResult("""
            estate_divergence: jensenShannon=\(out.divergence.jensenShannon) klDivergence=\(out.divergence.klDivergence)
            a=\(out.aCount) drawer(s), b=\(out.bCount) drawer(s)
            """)

        case "moot_association_rules":
            let filter = decodeFilter(args["filter"]?.stringValue)
            let limit = args["limit"]?.integerValue.map(Int.init)
            let minSupport = doubleArg(args["minSupport"]) ?? 0.0
            let minConfidence = doubleArg(args["minConfidence"]) ?? 0.0
            let arFrame = LocusKit.RecallFrame(
                filterChain: [filter],
                hydrationLevel: .structured,
                limit: limit,
                ordering: .byCaptureTimeDesc)
            let arOut = try await AssociationRules().run(
                input: .init(
                    frame: arFrame,
                    thresholds: MiningThresholds(minSupport: minSupport, minConfidence: minConfidence)),
                estate: handle, kit: kit)
            var arLines = [
                "association_rules: \(arOut.rules.count) rule(s) from \(arOut.drawerCount) drawer(s)",
            ]
            if arOut.labelOverflow {
                arLines.append("note: label vocabulary was capped at 64; some labels were dropped")
            }
            for rule in arOut.rules {
                arLines.append(
                    "  \(rule.antecedent) → \(rule.consequent): "
                    + "sup=\(String(format: "%.3f", rule.support)) "
                    + "conf=\(String(format: "%.3f", rule.confidence)) "
                    + "lift=\(String(format: "%.3f", rule.lift))")
            }
            return ToolDispatcher.textResult(arLines.joined(separator: "\n"))

        case "moot_formal_concepts":
            let fcFilter = decodeFilter(args["filter"]?.stringValue)
            let fcLimit = args["limit"]?.integerValue.map(Int.init)
            let minSupport = args["minSupport"]?.integerValue.map(Int.init) ?? 1
            let maxIntentSize = args["maxIntentSize"]?.integerValue.map(Int.init) ?? 8
            let maxConcepts = args["maxConcepts"]?.integerValue.map(Int.init) ?? 20
            let fcFrame = LocusKit.RecallFrame(
                filterChain: [fcFilter],
                hydrationLevel: .structured,
                limit: fcLimit,
                ordering: .byCaptureTimeDesc)
            let fcOut = try await FormalConcepts().run(
                input: .init(
                    frame: fcFrame,
                    miner: BoundedConceptMiner(
                        minSupport: minSupport,
                        maxIntentSize: maxIntentSize,
                        maxConcepts: maxConcepts)),
                estate: handle, kit: kit)
            var fcLines = [
                "formal_concepts: \(fcOut.concepts.count) concept(s) from \(fcOut.drawerCount) drawer(s)",
            ]
            for (i, concept) in fcOut.concepts.enumerated() {
                fcLines.append("  concept \(i + 1): support=\(concept.support)")
                fcLines.append("    intent: \(concept.intent.joined(separator: ", "))")
                fcLines.append("    extent: \(concept.extentDrawerIDs.count) drawer(s)")
            }
            return ToolDispatcher.textResult(fcLines.joined(separator: "\n"))

        default:
            throw JSONRPCError(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown lens tool: \(name)")
        }
    }

    // MARK: - Argument decoding

    /// The second federated estate, routed through the dispatcher's own
    /// registry: `estateIDB` is presented to the resolver as `estateID`.
    private static func secondEstateArgs(
        _ args: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard let b = args["estateIDB"] else { return [:] }
        return ["estateID": b]
    }

    private static func requireString(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        guard let value = args[key]?.stringValue else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Missing required string argument: \(key)")
        }
        return value
    }

    private static func requireDate(
        _ args: [String: JSONValue], _ key: String
    ) throws -> Date {
        let raw = try requireString(args, key)
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "Argument \(key) is not an ISO8601 instant: \(raw)")
        }
        return date
    }

    private static func integer(
        _ args: [String: JSONValue], _ key: String, default fallback: Int
    ) -> Int {
        args[key]?.integerValue.map(Int.init) ?? fallback
    }

    private static func number(
        _ args: [String: JSONValue], _ key: String, default fallback: Double
    ) -> Double {
        switch args[key] {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return fallback
        }
    }

    private static func decodeReference(
        _ value: JSONValue?
    ) throws -> [(label: String, mass: Double)] {
        guard let arr = value?.arrayValue else { return [] }
        return try arr.map { element in
            guard let obj = element.objectValue,
                  let label = obj["label"]?.stringValue else {
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each reference entry needs string label and number mass")
            }
            let mass: Double
            switch obj["mass"] {
            case .double(let d): mass = d
            case .integer(let i): mass = Double(i)
            default:
                throw JSONRPCError(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "each reference entry needs string label and number mass")
            }
            return (label: label, mass: mass)
        }
    }

    private static func decodeCueMode(_ name: String?) -> CueMode {
        switch name {
        case "aboutThis": return .aboutThis
        case "fromThen": return .fromThen
        default: return .feelsLike
        }
    }

    private static func decodeContentKind(_ name: String) -> ContentKind? {
        switch name {
        case "prose": return .prose
        case "code": return .code
        case "transcript": return .transcript
        case "list": return .list
        case "structuredJSON": return .structuredJSON
        case "imageCaption": return .imageCaption
        case "fingerprintOnly": return .fingerprintOnly
        default: return nil
        }
    }

    /// Action labels for anticipate output (capture channel raw values).
    private static func channelName(_ raw: UInt8) -> String {
        CaptureChannel(rawValue: Int(raw)).map { "\($0)" } ?? "channel(\(raw))"
    }

    /// Recall frame for the recall-scoped lenses. Same filter vocabulary
    /// as `RecipeTools.decodeFilter` (a deliberate small copy — the
    /// helpers there are private; same precedent as the schema helpers).
    private static func frame(_ args: [String: JSONValue]) -> LocusKit.RecallFrame {
        let filter: LocusKit.Filter
        switch args["filter"]?.stringValue {
        case "userConfirmed": filter = .userConfirmed
        case "exportable": filter = .exportable
        case "contained": filter = .contained
        case "currentlyBelieve": filter = .currentlyBelieve
        default: filter = .unconfirmed
        }
        return LocusKit.RecallFrame(filterChain: [filter])
    }

    /// Decode a filter kind string to a `LocusKit.Filter`. Used by the
    /// analytics lenses that take an explicit filter + limit frame.
    private static func decodeFilter(_ name: String?) -> LocusKit.Filter {
        switch name {
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        case "currentlyBelieve": return .currentlyBelieve
        default: return .unconfirmed
        }
    }

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

    // MARK: - Result shaping

    private static func list(_ heading: String, _ items: [String]) -> JSONValue {
        var lines = ["\(heading): \(items.count) result(s)"]
        lines += items.map { "  - \($0)" }
        return ToolDispatcher.textResult(lines.joined(separator: "\n"))
    }

    // MARK: - JSON schema helpers (same small copies as RecipeTools)

    private static var estateIDSchema: JSONValue {
        stringSchema("Optional UUID of the open estate to target. Omit for the default estate.")
    }

    private static var filterSchema: JSONValue {
        stringSchema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve.")
    }

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

    private static func numberSchema(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }
}
