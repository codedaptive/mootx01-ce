import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// The frozen Mission02 read-only recall and lens roster.  These requests are
/// intentionally separate from RecipeTools/LensTools' v1 argument spelling;
/// they are the admission boundary for a typed v2 implementation.
public enum AriaV2RecallLensOperation: String, Sendable, CaseIterable {
    case recallPrecise = "moot_recall_precise", recallTemporal = "moot_recall_temporal"
    case recallConnected = "moot_recall_connected", recallShaped = "moot_recall_shaped"
    case recallDistilled = "moot_recall_distilled", recallVague = "moot_recall_vague"
    case recallWalk = "moot_recall_walk"
    case lensKeystones = "moot_lens_keystones", lensConstellation = "moot_lens_constellation"
    case lensFreeAssociation = "moot_lens_free_association", lensThemeWeather = "moot_lens_theme_weather"
    case lensLatentThemes = "moot_lens_latent_themes", lensBias = "moot_lens_bias"
    case lensDrift = "moot_lens_drift", lensNodeMotion = "moot_lens_node_motion"
    case lensCohesion = "moot_lens_cohesion", lensContradiction = "moot_lens_contradiction"
    case lensTrustSynthesis = "moot_lens_trust_synthesis", lensPartialCue = "moot_lens_partial_cue"
    case lensAnticipate = "moot_lens_anticipate", lensSuccessors = "moot_lens_successors"
    case lensOverlap = "moot_lens_overlap", lensDivergence = "moot_lens_divergence"
    case lensAssociations = "moot_lens_associations", lensConcepts = "moot_lens_concepts"
    case lensApriori = "moot_lens_apriori", lensMoment = "moot_lens_moment"
    case lensRhythm = "moot_lens_rhythm", lensPrecedence = "moot_lens_precedence"
    case lensComplexity = "moot_lens_complexity"
}

public struct AriaV2RecallLensRequest: Sendable, Equatable {
    public let operation: AriaV2RecallLensOperation
    public let arguments: [String: JSONValue]
    public let estateID: UUID?

    public init(tool: String, arguments value: JSONValue) throws {
        guard let operation = AriaV2RecallLensOperation(rawValue: tool) else {
            throw AriaV2InvalidArgument(path: "tool", message: "Unsupported recall or lens tool '\(tool)'.").jsonRPCError
        }
        let schema = Self.schemas[operation]!
        let decoder = try AriaV2ArgumentDecoder(value, allowedKeys: Set(schema.keys.keys))
        var canonical = decoder.arguments
        for (key, kind) in schema.keys {
            if schema.required.contains(key), !decoder.has(key) {
                throw AriaV2InvalidArgument(path: key, message: "Missing required argument '\(key)'.").jsonRPCError
            }
            guard decoder.has(key) else { continue }
            switch kind {
            case .string:
                _ = try decoder.optionalString(key)
            case .boolean:
                _ = try decoder.optionalBoolean(key)
            case .positiveInteger:
                guard let integer = try decoder.optionalInteger(key), integer >= 1 else {
                    throw AriaV2InvalidArgument(path: key, message: "Argument '\(key)' must be an integer at least 1.").jsonRPCError
                }
            case .positiveIntegerOrString:
                if let integer = canonical[key]?.integerValue, integer >= 1 { break }
                guard let raw = canonical[key]?.stringValue, Int(raw).map({ $0 >= 1 }) == true else {
                    throw AriaV2InvalidArgument(path: key, message: "Argument '\(key)' must be an integer at least 1.").jsonRPCError
                }
            case .booleanOrString:
                if canonical[key]?.boolValue != nil { break }
                guard let raw = canonical[key]?.stringValue, Bool(raw) != nil else {
                    throw AriaV2InvalidArgument(path: key, message: "Argument '\(key)' must be a boolean.").jsonRPCError
                }
            case .uuid:
                let uuid = try decoder.optionalUUID(key)!
                canonical[key] = .string(AriaV2ArgumentDecoder.canonicalUUID(uuid))
            case .array:
                guard canonical[key]?.arrayValue != nil else { throw Self.invalid(key, "array") }
            case .object:
                guard canonical[key]?.objectValue != nil else { throw Self.invalid(key, "object") }
            }
        }
        // Validate the mode enum for moot_lens_partial_cue at decode time so
        // an unknown value produces a -32602 INVALID_PARAMS transport fault rather
        // than an isError:true result from the lower.  Matches Rust's decode-time
        // validation in V2RecallLensRequest::decode (recall_lens.rs).
        // Path convention: Swift uses a bare key ("mode"); Rust uses "$.mode".
        // That difference is each port's repo-wide convention and is intentional.
        if operation == .lensPartialCue, let rawMode = canonical["mode"]?.stringValue {
            switch rawMode {
            case "feelsLike", "aboutThis", "fromThen": break
            default:
                throw AriaV2InvalidArgument(
                    path: "mode",
                    message: "Argument 'mode' must be one of: feelsLike, aboutThis, fromThen.",
                    allowed: ["feelsLike", "aboutThis", "fromThen"],
                    correction: "Use \"feelsLike\", \"aboutThis\", or \"fromThen\"."
                ).jsonRPCError
            }
        }
        self.operation = operation
        self.arguments = canonical
        self.estateID = try decoder.optionalUUID("estate_id")
    }

    private enum Kind { case string, boolean, positiveInteger, positiveIntegerOrString, booleanOrString, uuid, array, object }
    private struct Schema { let required: Set<String>; let keys: [String: Kind] }
    private static func invalid(_ key: String, _ expected: String) -> JSONRPCError {
        AriaV2InvalidArgument(path: key, message: "Argument '\(key)' must be an \(expected).").jsonRPCError
    }
    private static let estate: [String: Kind] = ["estate_id": .uuid]
    private static func schema(_ required: Set<String> = [], _ keys: [String: Kind]) -> Schema {
        Schema(required: required, keys: estate.merging(keys) { _, new in new })
    }
    private static let recall: [String: Kind] = ["query": .string, "limit": .positiveInteger, "filter": .string, "wing": .string]
    private static let schemas: [AriaV2RecallLensOperation: Schema] = [
        .recallPrecise: schema(["query"], recall.merging(["pool": .positiveInteger, "composition": .string]) { _, n in n }),
        .recallTemporal: schema(["query"], recall.merging(["window": .string, "from": .string, "to": .string, "pool": .positiveInteger, "grab": .string]) { _, n in n }),
        .recallConnected: schema(["query"], recall.merging(["depth": .positiveInteger]) { _, n in n }),
        // frontier_k shares the .positiveInteger kind used on moot_memory_search;
        // the shaped-recall engine clamps [64, 256] internally.
        .recallShaped: schema(["query"], recall.merging(["preset": .string, "frontier_k": .positiveInteger]) { _, n in n }),
        .recallDistilled: schema(["query"], recall), .recallVague: schema(["query"], recall), .recallWalk: schema(["query"], recall),
        // Public-v2 retains its documented string wire fields. The fixed
        // provider admits native integer/bool forms before building this
        // shared v2 request.
        .lensKeystones: schema(["wing"], ["wing": .string, "topK": .positiveIntegerOrString, "keystoneOnly": .booleanOrString]),
        .lensConstellation: schema(["wing"], ["wing": .string]),
        .lensFreeAssociation: schema(["wing", "seed_memory_id"], ["wing": .string, "seed_memory_id": .uuid, "walkLength": .string, "k": .string]),
        .lensThemeWeather: schema([], [:]), .lensLatentThemes: schema([], [:]),
        .lensBias: schema([], ["reference": .array]), .lensDrift: schema(["splitAt"], ["splitAt": .string]),
        .lensNodeMotion: schema(["memory_id"], ["memory_id": .uuid]), .lensCohesion: schema([], ["dataset_id": .uuid]), .lensContradiction: schema([], [:]),
        .lensTrustSynthesis: schema([], ["limit": .positiveInteger]), .lensPartialCue: schema(["anchor_memory_id"], ["anchor_memory_id": .uuid, "limit": .positiveInteger, "mode": .string]),
        .lensAnticipate: schema(["targetKind"], ["targetKind": .string, "limit": .positiveInteger]), .lensSuccessors: schema(["wing", "anchor_memory_id"], ["wing": .string, "anchor_memory_id": .uuid, "limit": .positiveInteger]),
        .lensOverlap: schema(["comparison_estate_id"], ["comparison_estate_id": .uuid]), .lensDivergence: schema(["comparison_estate_id"], ["comparison_estate_id": .uuid]),
        .lensAssociations: schema([], ["dataset_id": .uuid, "limit": .positiveInteger]), .lensConcepts: schema([], ["recall_limit": .positiveInteger, "limit": .positiveInteger]), .lensApriori: schema([], ["limit": .positiveInteger]),
        .lensMoment: schema(["windowStart", "windowEnd"], ["windowStart": .string, "windowEnd": .string, "comparison_windows": .string]),
        .lensRhythm: schema(["bit", "bucketSeconds", "bucketCount", "endingAt"], ["bit": .string, "bucketSeconds": .string, "bucketCount": .string, "endingAt": .string]),
        .lensPrecedence: schema(["windowStart", "windowEnd", "targetField", "targetValue"], ["windowStart": .string, "windowEnd": .string, "targetField": .string, "targetValue": .string]),
        .lensComplexity: schema(["fieldA"], ["fieldA": .string, "fieldB": .string, "dataset_id": .uuid]),
    ]
}

/// Direct lower-kit adapters return already-typed data.  They must never call
/// RecipeTools/LensTools dispatch or parse a v1 renderer response.
public protocol AriaV2RecallLensAuthority: Sendable {
    func execute(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome
}

/// Concrete direct lower-kit authority for the first extracted vertical.  It
/// calls CognitionKit's recall engine itself; it never invokes a v1 dispatcher
/// or consumes a rendered response.  More operations are admitted only after
/// their existing renderer has been separated into an equivalent typed result
/// projection.
public struct AriaV2GeniusLocusRecallLensAuthority: AriaV2RecallLensAuthority {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle
    /// Server-owned policy narrowed in addition to request filters. Public-v2
    /// calls leave this nil; the stable provider supplies its verified frame.
    public let authorizationFilter: LocusKit.Filter?
    public init(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        authorizationFilter: LocusKit.Filter? = nil
    ) {
        self.kit = kit
        self.handle = handle
        self.authorizationFilter = authorizationFilter
    }

    public func execute(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome {
        guard request.estateID == nil || request.estateID == handle.estateUUID else {
            throw AriaV2InvalidArgument(path: "estate_id", message: "The requested estate is not available to this caller.").jsonRPCError
        }
        switch request.operation {
        case .recallPrecise:
            return try await precise(request)
        case .recallConnected:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let scoped = a["wing"]?.stringValue.map { LocusKit.Filter.all([f, .inWing($0)]) } ?? f
            let rows = try await ConnectedRecall.run(kit: kit, handle: handle, query: a["query"]!.stringValue!, wing: a["wing"]?.stringValue ?? "", filter: scoped, limit: Int(a["limit"]?.integerValue ?? 20))
            try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
                filterChain: [scoped], hydrationLevel: .full, limit: max(Int(a["limit"]?.integerValue ?? 20), 20)))
            return try await projectedResult(
                rows.map { .init(id: $0.id, retrievalSource: $0.source) },
                filterChain: [scoped], label: "connected recall")
        case .recallShaped:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let preset = a["preset"]?.stringValue ?? "balanced"
            // Presets are a closed set, so the refusal names it. The message keeps
            // the phrase the contract has always used and the list rides in
            // `allowed` as well, since a caller reading either should be able to
            // fix the call without a second round trip.
            guard RecallShape.presetNames.contains(preset) else {
                throw AriaV2InvalidArgument(
                    path: "preset",
                    message: "unknown preset '\(preset)'; valid presets: "
                        + RecallShape.presetNames.sorted().joined(separator: ", "),
                    allowed: RecallShape.presetNames.sorted()).jsonRPCError
            }
            // Thread frontier_k through to the engine; absent means nil (engine default formula).
            let frontierK = a["frontier_k"]?.integerValue.map { Int($0) }
            let rows = try await ShapedRecall().run(input: .init(query: a["query"]!.stringValue!, preset: preset, filter: a["wing"]?.stringValue.map { .all([f, .inWing($0)]) } ?? f, limit: Int(a["limit"]?.integerValue ?? 20), frontierK: frontierK), estate: handle, kit: kit).matches
            try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
                filterChain: [a["wing"]?.stringValue.map { .all([f, .inWing($0)]) } ?? f],
                hydrationLevel: .full, limit: Int(a["limit"]?.integerValue ?? 20), ordering: .byCaptureTimeDesc))
            return try await projectedResult(
                rows.map { .init(id: $0.id, score: $0.score) },
                control: discrimination(rows.map(\.score)), label: "shaped recall")
        case .recallDistilled:
            let a = request.arguments; let out = try await DistilledRecall().run(input: .init(query: a["query"]!.stringValue!, filter: try filter(a["filter"]?.stringValue), limit: Int(a["limit"]?.integerValue ?? 20)), estate: handle, kit: kit)
            try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
                filterChain: [try filter(a["filter"]?.stringValue)], hydrationLevel: .full,
                limit: Int(a["limit"]?.integerValue ?? 20)))
            return try await projectedResult(
                out.matches.map {
                    .init(id: $0.id, score: $0.score, distilled: $0.text, representation: "distilled",
                          originalTokenCount: $0.originalTokenCount, distilledTokenCount: $0.tokenCount)
                },
                control: distilledDiscrimination(out.discrimination), label: "distilled recall",
                reportsDistillation: true)
        case .recallTemporal:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let mode = TemporalWindowMode(rawValue: a["window"]?.stringValue ?? "loose")
            let grab = TemporalGrab(rawValue: a["grab"]?.stringValue ?? "pool")
            guard let mode, let grab else { throw AriaV2InvalidArgument(path: "window", message: "Unknown temporal window or grab selector.").jsonRPCError }
            let out = try await TemporalRecall.run(kit: kit, handle: handle, query: a["query"]!.stringValue!, filter: a["wing"]?.stringValue.map { .all([f, .inWing($0)]) } ?? f, limit: Int(a["limit"]?.integerValue ?? 20), pool: min(Int(a["pool"]?.integerValue ?? Int64(TemporalRecall.defaultPool)), 500), mode: mode, from: a["from"]?.stringValue, to: a["to"]?.stringValue, grab: grab)
            let temporalCapability = out.windows.first.map {
                TemporalCapability(
                    mode: out.mode.rawValue, source: out.windowSource, grab: out.grab.rawValue,
                    from: $0.start, to: $0.end,
                    widenedDays: out.appliedPad == 0 ? nil : out.appliedPad)
            }
            return try await projectedResult(
                out.matches.map { .init(id: $0.id, eventTime: $0.eventTime) },
                control: .init(temporalCapability: temporalCapability), label: "temporal recall")
        case .recallWalk:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let out = try await WalkRecall.run(kit: kit, handle: handle, query: a["query"]!.stringValue!, filter: a["wing"]?.stringValue.map { .all([f, .inWing($0)]) } ?? f, limit: Int(a["limit"]?.integerValue ?? 20), now: Date())
            return try await projectedResult(
                out.matches.map { .init(id: $0.id, score: $0.score) },
                control: .init(
                    discrimination: discrimination(out.matches.map(\.score)).discrimination,
                    walkStage: out.stage.rawValue, walkStoppedEarly: out.stoppedEarly),
                label: "walk recall")
        case .recallVague:
            let a = request.arguments; let out = try await kit.vagueRecall(handle, query: a["query"]!.stringValue!, hitLimit: Int(a["limit"]?.integerValue ?? 8), constituentsPerHit: 8, totalConstituents: 32)
            await AriaV2Withheld.record(out.withheldBySensitivity)
            let inputs = out.vagueHits.map { ProjectedMatch(id: $0.id, tier: "summary") }
                + out.constituents.map { ProjectedMatch(id: $0.id, tier: "original") }
            return try await projectedResult(inputs, label: "vague recall")
        default:
            throw AriaV2InvalidArgument(code: "operation_unavailable", path: "tool", message: "A typed lower-kit implementation is not available for \(request.operation.rawValue).").jsonRPCError
        }
    }

    private func precise(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome {
        let args = request.arguments
        let query = args["query"]!.stringValue!
        let limit = Int(args["limit"]?.integerValue ?? 20)
        let pool = min(Int(args["pool"]?.integerValue ?? Int64(PreciseRecall.defaultPool)), 500)
        let requested = try filter(args["filter"]?.stringValue)
        let base = authorizationFilter.map { LocusKit.Filter.all([requested, $0]) } ?? requested
        let scoped: LocusKit.Filter
        if let wing = args["wing"]?.stringValue { scoped = .all([base, .inWing(wing)]) } else { scoped = base }
        let composition = args["composition"]?.stringValue
        if let composition, !NeuronKit.CompositionGrid.names.contains(composition) {
            throw AriaV2InvalidArgument(
                path: "composition",
                message: "unknown composition '\(composition)'; valid names: "
                    + NeuronKit.CompositionGrid.names.sorted().joined(separator: ", "),
                allowed: NeuronKit.CompositionGrid.names).jsonRPCError
        }
        let matches = try await PreciseRecall.run(kit: kit, handle: handle, query: query, filter: scoped, limit: limit, pool: pool, composition: composition)
        try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: .init(
            filterChain: [scoped], hydrationLevel: .bitmapOnly,
            limit: max(pool, limit), ordering: .byCaptureTimeDesc))
        return try await projectedResult(
            matches.map { .init(id: $0.id, score: $0.score) },
            control: discrimination(matches.map(\.score)), label: "precise recall")
    }

    private func filter(_ raw: String?) throws -> LocusKit.Filter {
        switch raw {
        case nil, "currentlyBelieve": return .currentlyBelieve
        case "unconfirmed": return .unconfirmed
        case "userConfirmed": return .userConfirmed
        case "exportable": return .exportable
        case "contained": return .contained
        case .some(let value):
            throw AriaV2InvalidArgument(path: "filter", message: "Unknown filter '\(value)'.").jsonRPCError
        }
    }
    private struct ProjectedMatch: Sendable {
        let id: String
        let score: Double?
        let eventTime: String?
        let retrievalSource: String?
        let distilled: String?
        let representation: String?
        let tier: String?
        /// Estimator counts the distilled recipe carries per match: the full
        /// original content and the distilled text. Nil for every other
        /// operation.
        let originalTokenCount: Int64?
        let distilledTokenCount: Int64?

        init(id: String, score: Double? = nil, eventTime: String? = nil,
             retrievalSource: String? = nil, distilled: String? = nil,
             representation: String? = nil, tier: String? = nil,
             originalTokenCount: Int64? = nil, distilledTokenCount: Int64? = nil) {
            self.id = id
            self.score = score
            self.eventTime = eventTime
            self.retrievalSource = retrievalSource
            self.distilled = distilled
            self.representation = representation
            self.tier = tier
            self.originalTokenCount = originalTokenCount
            self.distilledTokenCount = distilledTokenCount
        }
    }

    /// Project direct lower-kit matches through the full-hydration gate the v2
    /// lens surfaces use.  This function is itself the v2 recall surface for all
    /// seven recall operations.  It intentionally consumes typed match/drawer
    /// values and never invokes or reparses a v1 tool.
    /// `reportsDistillation` is true only for distilled recall, whose response
    /// always carries `capabilities.distillation`, even with zero rows.
    ///
    /// Full hydration is required so `drawer.content` is populated for
    /// `bestSpan` computation; structured hydration returns `content == ""`
    /// (Swift spec §7.3), which would make `bestSpan` nil for every row.
    private func projectedResult(
        _ matches: [ProjectedMatch],
        filterChain: [LocusKit.Filter] = [],
        control: ControlSignals = .init(),
        label: String,
        reportsDistillation: Bool = false
    ) async throws -> AriaV2RecallLensOutcome {
        let shown = Array(matches.prefix(50))
        let estate = try await kit.estate(for: handle)
        let drawersByID = try await RecipeTools.structuredDrawersByID(
            ids: shown.map(\.id), estate: estate, filterChain: filterChain,
            hydrationLevel: .full)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawersByID.values.map(\.parentNodeId))
        let rows = shown.map { match -> CandidateRowData in
            guard let drawer = drawersByID[match.id] else {
                return AriaV2RecallLensPrivacy.unavailableRow(
                    id: match.id, eventTime: match.eventTime ?? "-", score: match.score,
                    retrievalSource: match.retrievalSource, tier: match.tier,
                    discardedDistilled: match.distilled, discardedRepresentation: match.representation)
            }
            let projection = AriaV2RecallLensPrivacy.project(
                drawer: drawer, subject: drawer.subject,
                bestSpan: drawer.content.isEmpty ? nil : drawer.content,
                sscFacts: drawer.sscFacts, distilled: match.distilled,
                representation: match.representation)
            return CandidateRowData(
                id: drawer.id, subject: projection.subject, bestSpan: projection.bestSpan, sscFacts: projection.sscFacts,
                eventTime: match.eventTime ?? ResultComposer.iso8601(drawer.eventTime), score: match.score,
                room: nodeNames[drawer.parentNodeId]?.room, retrievalSource: match.retrievalSource,
                distilled: projection.distilled, representation: projection.representation, tier: match.tier)
        }
        var data = ResultComposer.structuredS1(rows: rows, control: control)
        var compactText = "Returned \(rows.count) \(label) result(s)."
        if reportsDistillation {
            let savings = distilledSavings(shown: shown, rows: rows)
            data = Self.insertingDistillation(savings, into: data)
            // Both ports append the display line after a newline.
            compactText += "\n" + savings.display
        }
        return .init(data: data, compactText: compactText)
    }

    /// Sum the per-match estimator counts over the rows this response actually
    /// emits with a distilled body, joined to the matches by id. A row whose
    /// body the privacy projection withheld (restricted, secret or unknown
    /// provenance) or whose drawer is unavailable counts on neither side, so
    /// the published figure covers the payload as sent after the row cap
    /// (ARIA_V2_CONTRACT.md, "Distilled recall savings"). Zero rows measure
    /// as zero on both sides.
    private func distilledSavings(shown: [ProjectedMatch], rows: [CandidateRowData]) -> DistilledSavings {
        let emittedWithBody = Set(rows.filter { $0.distilled != nil }.map(\.id))
        var originalTokens: Int64 = 0
        var distilledTokens: Int64 = 0
        for match in shown where emittedWithBody.contains(match.id) {
            originalTokens += match.originalTokenCount ?? 0
            distilledTokens += match.distilledTokenCount ?? 0
        }
        // Skim is not applied on this surface today; the key stays absent.
        return DistilledSavings.measure(
            originalTokens: originalTokens, distilledTokens: distilledTokens, skimOmittedTokens: nil)
    }

    /// Insert `capabilities.distillation` into a structured S1 object, creating
    /// the `capabilities` object when the control signals produced none.
    private static func insertingDistillation(_ savings: DistilledSavings, into data: JSONValue) -> JSONValue {
        var object = data.objectValue ?? [:]
        var capabilities = object["capabilities"]?.objectValue ?? [:]
        capabilities["distillation"] = distillationValue(savings)
        object["capabilities"] = .object(capabilities)
        return .object(object)
    }

    /// Hand-encoded `DistilledSavings` wire object. The `skim` key is present
    /// only when skim was applied, matching the Rust serde shape key for key.
    private static func distillationValue(_ savings: DistilledSavings) -> JSONValue {
        var object: [String: JSONValue] = [
            "returnedTokens": .integer(savings.returnedTokens),
            "originalTokens": .integer(savings.originalTokens),
            "savedTokens": .integer(savings.savedTokens),
            "savedPercent": .integer(savings.savedPercent),
            "estimated": .bool(savings.estimated),
            "estimator": .string(savings.estimator),
            "display": .string(savings.display),
        ]
        if let skim = savings.skim {
            object["skim"] = .object(["omittedTokens": .integer(skim.omittedTokens)])
        }
        return .object(object)
    }

    private func discrimination(_ scores: [Double]) -> ControlSignals {
        let value: String? = switch RecallDiscrimination.classify(scores) {
        case .low: "low"
        case .medium: "medium"
        case .high, .notFound, .single: nil
        }
        return .init(discrimination: value)
    }

    private func distilledDiscrimination(_ level: DistilledDiscriminationLevel) -> ControlSignals {
        let value: String? = switch level {
        case .low: "low"
        case .medium: "medium"
        case .high, .single: nil
        }
        return .init(discrimination: value)
    }
}

/// V2-only raw provenance gate. `Drawer.sensitivity` intentionally defaults
/// unknown packed values to normal for legacy access compatibility; a public
/// v2 projection must instead fail closed before the composer sees body data.
enum AriaV2RecallLensPrivacy {
    /// Four-way verdict on whether and how a drawer's body may be presented.
    /// Mirrors Rust's `DrawerFill` in lens_lower.rs. Bit arithmetic lives
    /// once, in `classify`, so every call site switches on the verdict rather
    /// than repeating the extraction — matches the Rust single-enforcement
    /// mandate at lens_lower.rs:113-118.
    enum Verdict: Equatable {
        case admissible
        case restricted
        case secret
        case offScale
    }

    /// Classify a drawer by the provenance axis (bits 30-35 of drawer.provenance).
    ///
    /// raw 0 or 16 → admissible; raw 32 → restricted; raw 48 → secret;
    /// any other value → offScale (fail closed). This is the single place
    /// that holds the `(provenance >> 30) & 0x3f` extraction — callers
    /// switch on Verdict, never on the raw integer.
    static func classify(_ drawer: Drawer) -> Verdict {
        let raw = Int((drawer.provenance >> 30) & 0x3f)
        switch raw {
        case 0, 16: return .admissible
        case 32:    return .restricted
        case 48:    return .secret
        default:    return .offScale
        }
    }

    struct Projection: Equatable {
        let subject: String?
        let bestSpan: String?
        let sscFacts: String?
        let distilled: String?
        let representation: String?
    }

    static func project(
        drawer: Drawer, subject: String?, bestSpan: String?, sscFacts: String?,
        distilled: String?, representation: String?
    ) -> Projection {
        switch classify(drawer) {
        case .admissible:
            return .init(subject: subject, bestSpan: bestSpan, sscFacts: sscFacts,
                         distilled: distilled, representation: representation)
        case .restricted:
            return .init(subject: ResultComposer.restrictedMarker, bestSpan: nil,
                         sscFacts: nil, distilled: nil, representation: nil)
        case .secret:
            return .init(subject: ResultComposer.secretMarker, bestSpan: nil,
                         sscFacts: nil, distilled: nil, representation: nil)
        case .offScale:
            return .init(subject: nil, bestSpan: nil, sscFacts: nil,
                         distilled: nil, representation: nil)
        }
    }

    /// A filtered, unavailable, or withdrawn drawer has no admissible source
    /// body. In particular, never preserve an inline distillate from the
    /// pre-hydration match in this opaque fallback row.
    static func unavailableRow(
        id: String, eventTime: String, score: Double?, retrievalSource: String?, tier: String?,
        discardedDistilled _: String?, discardedRepresentation _: String?
    ) -> CandidateRowData {
        .init(id: id, eventTime: eventTime, score: score,
              retrievalSource: retrievalSource, tier: tier)
    }
}

public struct AriaV2RecallLensOutcome: Sendable, Equatable {
    public let data: JSONValue
    public let compactText: String
    public init(data: JSONValue, compactText: String) { self.data = data; self.compactText = compactText }
}

public struct AriaV2RecallLensService: Sendable {
    public let authority: any AriaV2RecallLensAuthority
    public init(authority: any AriaV2RecallLensAuthority) { self.authority = authority }
    public func execute(tool: String, arguments: JSONValue) async throws -> JSONValue {
        let request = try AriaV2RecallLensRequest(tool: tool, arguments: arguments)
        do {
            let outcome = try await authority.execute(request)
            return AriaV2Envelope.success(tool: request.operation.rawValue, effect: .read, data: outcome.data, meta: ["completeness": .string("incomplete")], compactText: outcome.compactText)
        } catch let error as JSONRPCError {
            // A bad argument is the CALLER's error and must reach them as one,
            // with the path and the allowed values, so they can fix the call
            // rather than retry it. This file already raises exactly that at
            // :137 (unknown preset), :153 (unknown window), :193 (unknown
            // composition, carrying the allowed list) and :209 (unknown
            // filter) — a blanket catch here would flatten all four into
            // "unavailable", which reads as an estate problem and invites a
            // pointless retry.
            throw error
        } catch {
            // Anything else genuinely is the estate failing to serve the call.
            // Absent and inaccessible deliberately collapse here, so the
            // caller cannot use the refusal as an existence oracle.
            return AriaV2Envelope.refusal(tool: request.operation.rawValue, error: .init(code: "recall_unavailable", message: "The requested recall or lens operation is unavailable in the selected estate.", retryable: false))
        }
    }
}
