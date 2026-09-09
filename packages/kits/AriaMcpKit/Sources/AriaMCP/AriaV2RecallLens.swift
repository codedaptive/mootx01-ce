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
            case .uuid:
                let uuid = try decoder.optionalUUID(key)!
                canonical[key] = .string(AriaV2ArgumentDecoder.canonicalUUID(uuid))
            case .array:
                guard canonical[key]?.arrayValue != nil else { throw Self.invalid(key, "array") }
            case .object:
                guard canonical[key]?.objectValue != nil else { throw Self.invalid(key, "object") }
            }
        }
        self.operation = operation
        self.arguments = canonical
        self.estateID = try decoder.optionalUUID("estate_id")
    }

    private enum Kind { case string, boolean, positiveInteger, uuid, array, object }
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
        .recallShaped: schema(["query"], recall.merging(["preset": .string]) { _, n in n }),
        .recallDistilled: schema(["query"], recall), .recallVague: schema(["query"], recall), .recallWalk: schema(["query"], recall),
        .lensKeystones: schema(["wing"], ["wing": .string, "topK": .string, "keystoneOnly": .string]),
        .lensConstellation: schema(["wing"], ["wing": .string]),
        .lensFreeAssociation: schema(["wing", "seed_memory_id"], ["wing": .string, "seed_memory_id": .uuid, "walkLength": .string, "k": .string]),
        .lensThemeWeather: schema([], [:]), .lensLatentThemes: schema([], [:]),
        .lensBias: schema([], ["reference": .array]), .lensDrift: schema(["splitAt"], ["splitAt": .string]),
        .lensNodeMotion: schema(["memory_id"], ["memory_id": .uuid]), .lensCohesion: schema([], ["dataset_id": .uuid]), .lensContradiction: schema([], [:]),
        .lensTrustSynthesis: schema([], ["limit": .positiveInteger]), .lensPartialCue: schema(["anchor_memory_id"], ["anchor_memory_id": .uuid, "limit": .positiveInteger]),
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
    public init(kit: GeniusLocusKit, handle: EstateHandle) { self.kit = kit; self.handle = handle }

    public func execute(_ request: AriaV2RecallLensRequest) async throws -> AriaV2RecallLensOutcome {
        guard request.estateID == nil || request.estateID == handle.estateUUID else {
            throw AriaV2InvalidArgument(path: "estate_id", message: "The requested estate is not available to this caller.").jsonRPCError
        }
        switch request.operation {
        case .recallPrecise:
            return try await precise(request)
        case .recallConnected:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let rows = try await ConnectedRecall.run(kit: kit, handle: handle, query: a["query"]!.stringValue!, wing: a["wing"]?.stringValue ?? "", filter: f, limit: Int(a["limit"]?.integerValue ?? 20))
            return try await projectedResult(
                rows.map { .init(id: $0.id, retrievalSource: $0.source) },
                filterChain: [f], label: "connected recall")
        case .recallShaped:
            let a = request.arguments; let f = try filter(a["filter"]?.stringValue)
            let preset = a["preset"]?.stringValue ?? "balanced"
            guard RecallShape.presetNames.contains(preset) else { throw AriaV2InvalidArgument(path: "preset", message: "Unknown recall preset '\(preset)'.").jsonRPCError }
            let rows = try await ShapedRecall().run(input: .init(query: a["query"]!.stringValue!, preset: preset, filter: a["wing"]?.stringValue.map { .all([f, .inWing($0)]) } ?? f, limit: Int(a["limit"]?.integerValue ?? 20), frontierK: nil), estate: handle, kit: kit).matches
            return try await projectedResult(
                rows.map { .init(id: $0.id, score: $0.score) },
                control: discrimination(rows.map(\.score)), label: "shaped recall")
        case .recallDistilled:
            let a = request.arguments; let out = try await DistilledRecall().run(input: .init(query: a["query"]!.stringValue!, filter: try filter(a["filter"]?.stringValue), limit: Int(a["limit"]?.integerValue ?? 20)), estate: handle, kit: kit)
            return try await projectedResult(
                out.matches.map { .init(id: $0.id, score: $0.score, distilled: $0.text, representation: "distilled") },
                control: distilledDiscrimination(out.discrimination), label: "distilled recall")
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
        let base = try filter(args["filter"]?.stringValue)
        let scoped: LocusKit.Filter
        if let wing = args["wing"]?.stringValue { scoped = .all([base, .inWing(wing)]) } else { scoped = base }
        let composition = args["composition"]?.stringValue
        if let composition, !NeuronKit.CompositionGrid.names.contains(composition) {
            throw AriaV2InvalidArgument(path: "composition", message: "Unknown precise-recall composition '\(composition)'.", allowed: NeuronKit.CompositionGrid.names).jsonRPCError
        }
        let matches = try await PreciseRecall.run(kit: kit, handle: handle, query: query, filter: scoped, limit: limit, pool: pool, composition: composition)
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

        init(id: String, score: Double? = nil, eventTime: String? = nil,
             retrievalSource: String? = nil, distilled: String? = nil,
             representation: String? = nil, tier: String? = nil) {
            self.id = id
            self.score = score
            self.eventTime = eventTime
            self.retrievalSource = retrievalSource
            self.distilled = distilled
            self.representation = representation
            self.tier = tier
        }
    }

    /// Project direct lower-kit matches through the same structured hydration
    /// gate used by the existing recall surfaces.  It intentionally consumes
    /// typed match/drawer values and never invokes or reparses a v1 tool.
    private func projectedResult(
        _ matches: [ProjectedMatch],
        filterChain: [LocusKit.Filter] = [],
        control: ControlSignals = .init(),
        label: String
    ) async throws -> AriaV2RecallLensOutcome {
        let shown = Array(matches.prefix(50))
        let estate = try await kit.estate(for: handle)
        let drawersByID = try await RecipeTools.structuredDrawersByID(
            ids: shown.map(\.id), estate: estate, filterChain: filterChain)
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
        return .init(
            data: ResultComposer.structuredS1(rows: rows, control: control),
            compactText: "Returned \(rows.count) \(label) result(s).")
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
        let raw = Int((drawer.provenance >> 30) & 0x3f)
        switch raw {
        case 0, 16:
            return .init(subject: subject, bestSpan: bestSpan, sscFacts: sscFacts,
                         distilled: distilled, representation: representation)
        case 32:
            return .init(subject: ResultComposer.restrictedMarker, bestSpan: nil,
                         sscFacts: nil, distilled: nil, representation: nil)
        case 48:
            return .init(subject: ResultComposer.secretMarker, bestSpan: nil,
                         sscFacts: nil, distilled: nil, representation: nil)
        default:
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
        } catch {
            return AriaV2Envelope.refusal(tool: request.operation.rawValue, error: .init(code: "recall_unavailable", message: "The requested recall or lens operation is unavailable in the selected estate.", retryable: false))
        }
    }
}
