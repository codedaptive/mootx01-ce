import AriaMCPWire
import CognitionKit
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML

/// Direct typed lower bindings for the Mission02 lenses whose engines
/// already expose stable result values.  This is intentionally unadvertised:
/// selected-surface admission remains owned elsewhere.
public enum AriaV2LensLower {
    public static let supported: Set<AriaV2RecallLensOperation> = [
        .lensKeystones, .lensConstellation, .lensFreeAssociation, .lensBias, .lensCohesion,
        .lensThemeWeather, .lensLatentThemes, .lensDrift, .lensTrustSynthesis,
        .lensPartialCue, .lensAnticipate,
        .lensNodeMotion, .lensContradiction, .lensSuccessors, .lensOverlap, .lensDivergence,
        .lensAssociations, .lensConcepts, .lensApriori, .lensMoment, .lensRhythm,
        .lensPrecedence, .lensComplexity,
    ]

    public struct Context: Sendable {
        public let estateID: UUID
        public let now: Date
        /// The caller's already-authorized read scope.  Engines retain this
        /// frame rather than reconstructing an unscoped estate recall.
        public let authorizationFrame: RecallFrame
        /// Comparison estates the host has separately authorized for this
        /// request.  The lower adapter cannot open a peer from an opaque UUID.
        public let comparisonHandles: [UUID: EstateHandle]

        public init(
            estateID: UUID,
            now: Date,
            authorizationFrame: RecallFrame = .init(filterChain: []),
            comparisonHandles: [UUID: EstateHandle] = [:]
        ) {
            self.estateID = estateID
            self.now = now
            self.authorizationFrame = authorizationFrame
            self.comparisonHandles = comparisonHandles
        }
    }

    public enum Failure: Error, Sendable {
        case refusal(AriaV2OperationalRefusal)
    }

    public static func refusal(_ message: String) -> Failure {
        .refusal(.init(code: "lens_unavailable", message: message, retryable: false))
    }
}

/// The shared request/result boundary used by the recall/lens family.  Hosts
/// may substitute this protocol in focused tests without fabricating a legacy
/// tool response.
public protocol AriaV2LensLowerAuthority: Sendable {
    func execute(
        _ request: AriaV2RecallLensRequest,
        context: AriaV2LensLower.Context
    ) async throws -> AriaV2RecallLensOutcome
}

/// Source-faithful adapter over CognitionKit's recipe entry points.  Every
/// branch receives typed engine values and projects them directly into the
/// Mission02 data shape.
public struct AriaV2GeniusLocusLensLowerAuthority: AriaV2LensLowerAuthority {
    public let kit: GeniusLocusKit
    public let handle: EstateHandle

    public init(kit: GeniusLocusKit, handle: EstateHandle) {
        self.kit = kit
        self.handle = handle
    }

    public func execute(
        _ request: AriaV2RecallLensRequest,
        context: AriaV2LensLower.Context
    ) async throws -> AriaV2RecallLensOutcome {
        guard request.estateID == nil || request.estateID == context.estateID,
              handle.estateUUID == context.estateID else {
            throw AriaV2LensLower.refusal("The requested estate is not available to this caller.")
        }
        guard AriaV2LensLower.supported.contains(request.operation) else {
            throw AriaV2LensLower.refusal("This typed lower adapter does not support \(request.operation.rawValue).")
        }

        switch request.operation {
        case .lensKeystones:
            let ranked = try await Keystones.run(
                kit: kit, handle: handle, wing: try string(request, "wing"),
                topK: try boundedStringInteger(request, "topK", defaultValue: 5, maximum: 500),
                now: context.now)
            return .init(data: .object(["keystones": .array(ranked.map {
                .object(["id": .string($0.id.lowercased()), "centrality": .double($0.centrality)])
            })]), compactText: "Found \(ranked.count) keystones.")

        case .lensConstellation:
            let constellation = try await ConstellationLens.run(
                kit: kit, handle: handle, wing: try string(request, "wing"), now: context.now)
            return .init(data: .object(["communities": .array(constellation.communities.map {
                .array($0.map { .string($0.lowercased()) })
            })]), compactText: "Found \(constellation.communities.count) communities.")

        case .lensFreeAssociation:
            let associations = try await FreeAssociationLens.run(
                kit: kit, handle: handle, wing: try string(request, "wing"),
                seedDrawerID: try string(request, "seed_memory_id"),
                walkLength: try boundedStringInteger(request, "walkLength", defaultValue: 10_000, maximum: 100_000),
                k: try boundedStringInteger(request, "k", defaultValue: 10, maximum: 500))
            return .init(data: .object(["associations": .array(associations.map {
                .object(["drawerID": .string($0.drawerID.lowercased()), "activation": .double($0.activation)])
            })]), compactText: "Found \(associations.count) associations.")

        case .lensBias:
            let report = try await Bias.run(kit: kit, handle: handle, reference: try reference(request))
            return .init(data: .object([
                "biasedFor": .array(report.biasedFor.map { .object(["label": .string($0.label), "bias": .double($0.bias)]) }),
                "biasedAgainst": .array(report.biasedAgainst.map { .object(["label": .string($0.label), "bias": .double($0.bias)]) }),
                "dismissal": .array(report.dismissal.map { .object(["nodeId": .string($0.nodeId.lowercased()), "rate": .double($0.rate)]) }),
                "learned": .array(report.learned.map { .object([
                    "label": .string($0.label), "strength": .double($0.strength),
                    "endorsements": .integer(Int64($0.endorsements)), "dismissals": .integer(Int64($0.dismissals)),
                ]) }),
            ]), compactText: "Computed bias signals.")

        case .lensCohesion:
            guard request.arguments["dataset_id"] == nil else {
                throw AriaV2LensLower.refusal("Dataset cohesion is not available through this estate lens adapter.")
            }
            let output = try await Contradiction.run(
                kit: kit, handle: handle, frame: context.authorizationFrame, threshold: 1.5)
            return .init(data: .object([
                "considered": .integer(Int64(output.considered)),
                "outliers": .array(output.outliers.map { .string($0.lowercased()) }),
            ]), compactText: "Found \(output.outliers.count) cohesion outliers.")

        case .lensContradiction:
            // The v2 projection preserves the existing contradiction lens's two
            // typed signals.  It reads the persisted output of the atomic hunt
            // directly; it never invokes LensTools or parses its text response.
            let estate = try await kit.estate(for: handle)
            let tunnels = (try await estate.allTunnels()).filter {
                $0.kind == .contradicts && $0.tombstonedAt == nil
                    && ($0.lifecycle == .active || $0.lifecycle == .proposed)
                    && $0.adjectiveSensitivity.isBulkExportable
            }
            let emittedTunnels = Array(tunnels.prefix(50))
            let endpointIDs = Set(emittedTunnels.flatMap {
                [$0.sourceDrawerId, $0.targetDrawerId].compactMap { $0 }
            })
            let hiddenEndpointIDs: Set<String>
            if endpointIDs.isEmpty {
                hiddenEndpointIDs = []
            } else {
                let result = try await estate.getDrawers(
                    ids: Array(endpointIDs), matchingFrame: RecallFrame(filterChain: []),
                    hydrationLevel: .structured)
                hiddenEndpointIDs = result.loadedIDs.subtracting(Set(result.admissible.map(\.id)))
            }
            let tunnelRows = emittedTunnels.map { tunnel -> JSONValue in
                var row: [String: JSONValue] = [
                    "id": .string(tunnel.id),
                    "lifecycle": .string(tunnel.lifecycle == .proposed ? "proposed" : "active"),
                ]
                if let source = tunnel.sourceDrawerId, !hiddenEndpointIDs.contains(source) {
                    row["sourceDrawerId"] = .string(source)
                }
                if let target = tunnel.targetDrawerId, !hiddenEndpointIDs.contains(target) {
                    row["targetDrawerId"] = .string(target)
                }
                return .object(row)
            }

            let facts = (try await kit.recallKGFacts(handle)).filter {
                $0.adjectiveSensitivity.isBulkExportable
            }
            var factsByKey: [ContradictionFactKey: [KGFact]] = [:]
            for fact in facts {
                let key = ContradictionFactKey(
                    subject: fact.subject.lowercased(), predicate: fact.predicate.lowercased())
                factsByKey[key, default: []].append(fact)
            }
            let conflictingGroups = factsByKey
                .filter { Set($0.value.map { $0.object.lowercased() }).count > 1 }
                .sorted { lhs, rhs in
                    lhs.key.subject == rhs.key.subject
                        ? lhs.key.predicate < rhs.key.predicate
                        : lhs.key.subject < rhs.key.subject
                }
                .prefix(20)
            var factRows: [JSONValue] = []
            factRows.reserveCapacity(conflictingGroups.count)
            for (key, conflictingFacts) in conflictingGroups {
                var seen = Set<String>()
                var objects: [JSONValue] = []
                for fact in conflictingFacts where seen.insert(fact.object.lowercased()).inserted {
                    objects.append(.string(fact.object))
                }
                factRows.append(.object([
                    "subject": .string(key.subject),
                    "predicate": .string(key.predicate),
                    "objects": .array(objects),
                ]))
            }
            return .init(data: .object([
                "contradictsTunnels": .array(tunnelRows),
                "conflictingFacts": .array(factRows),
            ]), compactText: "Found \(tunnels.count) contradiction tunnels and \(factRows.count) conflicting fact groups.")

        case .lensThemeWeather:
            let weather = try await ThemeWeather.run(
                kit: kit, handle: handle, frame: context.authorizationFrame,
                halfLifeSeconds: 604_800, now: context.now)
            return .init(data: .object(["weather": .array(weather.map {
                .object(["category": .string($0.category), "momentum": .double($0.momentum)])
            })]), compactText: "Computed \(weather.count) theme-weather rows.")

        case .lensLatentThemes:
            let themes = try await LatentThemesLens.run(
                kit: kit, handle: handle, frame: context.authorizationFrame, k: 3)
            return .init(data: .object([
                "k": .integer(Int64(themes.k)),
                "loadings": .array(themes.loadings.map {
                    .object(["label": .string($0.label), "dominantTheme": .integer(Int64($0.dominantTheme))])
                }),
            ]), compactText: "Computed \(themes.loadings.count) latent-theme loadings.")

        case .lensDrift:
            let output = try await Drift.run(
                kit: kit, handle: handle, frame: context.authorizationFrame,
                splitAt: try iso8601Date(request, "splitAt"))
            return .init(data: .object([
                "beforeCount": .integer(Int64(output.beforeCount)),
                "afterCount": .integer(Int64(output.afterCount)),
                "drift": .object([
                    "jensenShannon": .double(Double(output.drift.jensenShannon)),
                    "klDivergence": .double(Double(output.drift.klDivergence)),
                ]),
            ]), compactText: "Computed drift across \(output.beforeCount + output.afterCount) memories.")

        case .lensTrustSynthesis:
            let output = try await TrustLens.run(
                kit: kit, handle: handle, frame: frame(request, context: context))
            return .init(data: trustData(output), compactText: "Synthesized \(output.rankedIDs.count) trust-ranked memories.")

        case .lensPartialCue:
            let matches = try await PartialCueRecall.run(
                kit: kit, handle: handle, frame: context.authorizationFrame,
                anchorID: try string(request, "anchor_memory_id"), mode: .feelsLike,
                k: positiveInteger(request, "limit", defaultValue: 5))
            return try await partialCueOutcome(matches, context: context)

        case .lensAnticipate:
            let predictions = try await Anticipate.run(
                kit: kit, handle: handle, frame: context.authorizationFrame,
                targetOutcome: try targetOutcome(request),
                k: positiveInteger(request, "limit", defaultValue: 5), minObservations: 1)
            return .init(data: .object(["actions": .array(predictions.map {
                .object([
                    "action": .integer(Int64($0.action)),
                    "successRate": .double(Double($0.successRate)),
                    "count": .integer(Int64($0.count)),
                ])
            })]), compactText: "Computed \(predictions.count) anticipated actions.")

        case .lensNodeMotion:
            let id = try string(request, "memory_id")
            let estate = try await kit.estate(for: handle)
            guard let drawer = try await RecipeTools.structuredDrawersByID(
                ids: [id], estate: estate, filterChain: context.authorizationFrame.filterChain)[id],
                drawer.tombstonedAt == nil else {
                throw AriaV2LensLower.refusal("The requested memory is unavailable to this caller.")
            }
            let motion = try await NodeMotionLens.run(
                kit: kit, handle: handle, rowID: drawer.id, now: context.now)
            let anomaly = NodeMotionLens.classify(motion: motion)
            var data: [String: JSONValue] = [
                "rowID": .string(motion.rowID.uuidString.lowercased()),
                "volatility": .double(motion.volatility),
                "eventCount": .integer(Int64(motion.eventCount)),
                "anchorTrajectory": .array(motion.anchorTrajectory.map {
                    .integer(Int64(bitPattern: $0))
                }),
                "reanchored": .bool(anomaly.reanchored),
                "anomaly": .string(anomaly.isChurning ? "churning" : (anomaly.reanchored ? "reanchored" : "stable")),
            ]
            if let last = motion.lastEventPhysicalMs { data["lastEventPhysicalMs"] = .integer(last) }
            if let anchor = anomaly.currentAnchor { data["currentAnchor"] = .integer(Int64(bitPattern: anchor)) }
            return .init(data: .object(data), compactText: "Computed node motion.")

        case .lensSuccessors:
            let successors = try await TunnelSuccessor.run(
                kit: kit, handle: handle, wing: try string(request, "wing"),
                anchorID: try string(request, "anchor_memory_id"),
                k: positiveInteger(request, "limit", defaultValue: 5))
            return .init(data: .object(["successors": .array(successors.map {
                .object(["id": .string($0.id.lowercased()), "weight": .integer(Int64($0.weight))])
            })]), compactText: "Found \(successors.count) successors.")

        case .lensOverlap:
            let peer = try comparisonHandle(request, context: context)
            let overlap = try await MindOverlapLens.run(
                kit: kit, handleA: handle, handleB: peer, frame: context.authorizationFrame)
            return .init(data: .object([
                "overlap": .double(overlap.overlap),
                "aSufficient": .bool(overlap.aSufficient),
                "bSufficient": .bool(overlap.bSufficient),
            ]), compactText: "Computed estate overlap.")

        case .lensDivergence:
            let peer = try comparisonHandle(request, context: context)
            let divergence = try await EstateDivergenceLens.run(
                kit: kit, handleA: handle, handleB: peer, frame: context.authorizationFrame)
            return .init(data: .object([
                "aCount": .integer(Int64(divergence.aCount)),
                "bCount": .integer(Int64(divergence.bCount)),
                "divergence": .object([
                    "jensenShannon": .double(Double(divergence.divergence.jensenShannon)),
                    "klDivergence": .double(Double(divergence.divergence.klDivergence)),
                ]),
            ]), compactText: "Computed estate divergence.")

        case .lensAssociations:
            guard request.arguments["dataset_id"] == nil else {
                throw AriaV2LensLower.refusal("Dataset associations require a dataset-store authority.")
            }
            let output = try await AssociationRules().run(
                input: .init(
                    frame: frame(request, context: context),
                    thresholds: .init(minSupport: 0, minConfidence: 0)),
                estate: handle, kit: kit)
            return .init(data: associationData(output), compactText: "Found \(output.rules.count) association rules.")

        case .lensConcepts:
            let output = try await FormalConcepts().run(
                input: .init(
                    frame: frame(request, context: context, limitKey: "recall_limit"),
                    miner: .init(
                        minSupport: 1, maxIntentSize: 8,
                        maxConcepts: positiveInteger(request, "limit", defaultValue: 20))),
                estate: handle, kit: kit)
            return .init(data: conceptsData(output), compactText: "Found \(output.concepts.count) concepts.")

        case .lensApriori:
            let output = try await AprioriRules().run(
                input: .init(thresholds: .init(minSupport: 0, minConfidence: 0, minLift: 1, maxK: 3)),
                estate: handle, kit: kit)
            let rules = Array(output.rules.prefix(positiveInteger(request, "limit", defaultValue: 20)))
            return .init(data: aprioriData(rules), compactText: "Found \(rules.count) Apriori rules.")

        case .lensMoment:
            guard request.arguments["comparison_windows"] == nil else {
                throw AriaV2LensLower.refusal("comparison_windows needs a typed date-range decoder.")
            }
            let output = try await Moment.run(
                kit: kit, handle: handle,
                window: try dateWindow(request, start: "windowStart", end: "windowEnd"),
                comparisonWindows: [], now: context.now)
            return .init(data: .object([
                "windowCount": .integer(Int64(output.windowCount)),
                "ranking": .array(output.result.ranking.map {
                    .object(["hammingDistance": .integer(Int64($0.hammingDistance))])
                }),
            ]), compactText: "Computed moment signature.")

        case .lensRhythm:
            let output = try await Rhythm.run(
                kit: kit, handle: handle,
                bit: try stringInteger(request, "bit", minimum: 0, maximum: 255),
                bucketSeconds: try stringInteger(request, "bucketSeconds", minimum: 1, maximum: 31_536_000),
                bucketCount: try stringInteger(request, "bucketCount", minimum: 1, maximum: 10_000),
                endingAt: try iso8601Date(request, "endingAt"), topK: 3, now: context.now)
            return .init(data: .object([
                "bucketCount": .integer(Int64(output.bucketCount)),
                "periods": .array(output.periods.map {
                    .object([
                        "periodSeconds": .integer(Int64($0.periodSeconds.rounded())),
                        "relativeMagnitude": .double($0.relativeMagnitude),
                    ])
                }),
            ]), compactText: "Computed \(output.periods.count) rhythms.")

        case .lensPrecedence:
            let output = try await Precedence.run(
                kit: kit, handle: handle,
                window: try dateWindow(request, start: "windowStart", end: "windowEnd"),
                target: .init(fieldPath: try string(request, "targetField"), valueRepr: try string(request, "targetValue")),
                k: 5, now: context.now)
            return .init(data: .object([
                "entryCount": .integer(Int64(output.entryCount)),
                "antecedents": .array(output.antecedents.map {
                    .object([
                        "source": .object([
                            "fieldPath": .string($0.source.fieldPath),
                            "valueRepr": .string($0.source.valueRepr),
                        ]),
                        "lagBucket": .integer(Int64($0.lagBucket)),
                        "count": .integer($0.count),
                    ])
                }),
            ]), compactText: "Found \(output.antecedents.count) precedence antecedents.")

        case .lensComplexity:
            guard request.arguments["dataset_id"] == nil else {
                throw AriaV2LensLower.refusal("Dataset complexity requires a dataset-store authority.")
            }
            let output = try await Complexity.run(
                kit: kit, handle: handle, frame: context.authorizationFrame,
                fieldA: try complexityField(request, "fieldA"),
                fieldB: try optionalComplexityField(request, "fieldB"), now: context.now)
            return .init(data: complexityData(output), compactText: "Computed estate complexity.")

        default:
            throw AriaV2LensLower.refusal("This typed lower adapter does not support \(request.operation.rawValue).")
        }
    }

    private func string(_ request: AriaV2RecallLensRequest, _ key: String) throws -> String {
        guard let value = request.arguments[key]?.stringValue, !value.isEmpty else {
            throw AriaV2LensLower.refusal("Missing required lens argument '\(key)'.")
        }
        return value
    }

    private func boundedStringInteger(
        _ request: AriaV2RecallLensRequest, _ key: String, defaultValue: Int, maximum: Int
    ) throws -> Int {
        guard let raw = request.arguments[key]?.stringValue else { return defaultValue }
        guard let value = Int(raw), value >= 1, value <= maximum else {
            throw AriaV2LensLower.refusal("Lens argument '\(key)' must be an integer in 1...\(maximum).")
        }
        return value
    }

    private func positiveInteger(
        _ request: AriaV2RecallLensRequest, _ key: String, defaultValue: Int
    ) -> Int {
        Int(request.arguments[key]?.integerValue ?? Int64(defaultValue))
    }

    private func frame(
        _ request: AriaV2RecallLensRequest,
        context: AriaV2LensLower.Context,
        limitKey: String = "limit"
    ) -> RecallFrame {
        var frame = context.authorizationFrame
        if let limit = request.arguments[limitKey]?.integerValue {
            frame.limit = Int(limit)
        }
        return frame
    }

    private func iso8601Date(_ request: AriaV2RecallLensRequest, _ key: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: try string(request, key)) else {
            throw AriaV2LensLower.refusal("Lens argument '\(key)' must be an ISO-8601 timestamp.")
        }
        return date
    }

    private func dateWindow(
        _ request: AriaV2RecallLensRequest, start: String, end: String
    ) throws -> ClosedRange<Date> {
        let lower = try iso8601Date(request, start)
        let upper = try iso8601Date(request, end)
        guard lower <= upper else {
            throw AriaV2LensLower.refusal("The lens time window must not be inverted.")
        }
        return lower...upper
    }

    private func stringInteger(
        _ request: AriaV2RecallLensRequest, _ key: String, minimum: Int, maximum: Int
    ) throws -> Int {
        guard let value = Int(try string(request, key)), value >= minimum, value <= maximum else {
            throw AriaV2LensLower.refusal("Lens argument '\(key)' must be an integer in \(minimum)...\(maximum).")
        }
        return value
    }

    private func comparisonHandle(
        _ request: AriaV2RecallLensRequest, context: AriaV2LensLower.Context
    ) throws -> EstateHandle {
        guard let id = UUID(uuidString: try string(request, "comparison_estate_id")),
              let handle = context.comparisonHandles[id],
              handle.estateUUID != self.handle.estateUUID else {
            throw AriaV2LensLower.refusal("The requested comparison estate is unavailable to this caller.")
        }
        return handle
    }

    private func complexityField(
        _ request: AriaV2RecallLensRequest, _ key: String
    ) throws -> String {
        let value = try string(request, key)
        guard ["room", "wing", "addedBy", "embeddingModelID"].contains(value) else {
            throw AriaV2LensLower.refusal("\(key) is not available for estate complexity.")
        }
        return value
    }

    private func optionalComplexityField(
        _ request: AriaV2RecallLensRequest, _ key: String
    ) throws -> String? {
        guard request.arguments[key] != nil else { return nil }
        return try complexityField(request, key)
    }

    private func targetOutcome(_ request: AriaV2RecallLensRequest) throws -> UInt8 {
        let kind: ContentKind? = switch try string(request, "targetKind") {
        case "prose": .prose
        case "code": .code
        case "transcript": .transcript
        case "list": .list
        case "structuredJSON": .structuredJSON
        case "imageCaption": .imageCaption
        case "fingerprintOnly": .fingerprintOnly
        case "dataset": .dataset
        default: nil
        }
        guard let kind, kind != .dataset else {
            throw AriaV2LensLower.refusal("targetKind is not available for the anticipate lens.")
        }
        return UInt8(kind.rawValue)
    }

    private func reference(_ request: AriaV2RecallLensRequest) throws -> [(label: String, mass: Double)] {
        guard let values = request.arguments["reference"]?.arrayValue else { return [] }
        return try values.enumerated().map { index, value in
            guard let object = value.objectValue,
                  let label = object["label"]?.stringValue,
                  let mass = number(object["mass"]),
                  !label.isEmpty else {
                throw AriaV2LensLower.refusal("reference[\(index)] must contain a non-empty label and numeric mass.")
            }
            return (label, mass)
        }
    }

    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .some(.integer(let value)): Double(value)
        case .some(.double(let value)) where value.isFinite: value
        default: nil
        }
    }

    private func associationData(_ output: AssociationRules.Output) -> JSONValue {
        .object([
            "rules": .array(output.rules.map {
                .object([
                    "antecedent": .string($0.antecedent),
                    "consequent": .string($0.consequent),
                    "support": .double($0.support),
                    "confidence": .double($0.confidence),
                    "lift": .double($0.lift),
                    "conviction": .double($0.conviction),
                    "leverage": .double($0.leverage),
                    "exemplarDrawerIDs": .array($0.exemplarDrawerIDs.map {
                        .string($0.lowercased())
                    }),
                ])
            }),
            "drawerCount": .integer(Int64(output.drawerCount)),
            "labelOverflow": .bool(output.labelOverflow),
        ])
    }

    private func conceptsData(_ output: FormalConcepts.Output) -> JSONValue {
        .object([
            "concepts": .array(output.concepts.map { concept in
                var row: [String: JSONValue] = [
                    "intent": .array(concept.intent.map(JSONValue.string)),
                    "extentDrawerIDs": .array(concept.extentDrawerIDs.map {
                        .string($0.lowercased())
                    }),
                    "support": .integer(Int64(concept.support)),
                ]
                if let stability = concept.stability { row["stability"] = .double(stability) }
                return .object(row)
            }),
            "drawerCount": .integer(Int64(output.drawerCount)),
            "coverDeltas": .array(output.coverDeltas.coverDeltas.map {
                .object([
                    "lowerIntent": .array($0.lowerIntent.map(attributeString).sorted().map(JSONValue.string)),
                    "addedAttributes": .array($0.addedAttributes.map(attributeString).sorted().map(JSONValue.string)),
                ])
            }),
            "implications": .array(output.implications.implications.map {
                .object([
                    "premise": .array($0.premise.map(attributeString).sorted().map(JSONValue.string)),
                    "conclusion": .array($0.conclusion.map(attributeString).sorted().map(JSONValue.string)),
                ])
            }),
            "implicationsTruncated": .bool(output.implications.isTruncated),
        ])
    }

    private func attributeString(_ attribute: FormalAttribute) -> String {
        "\(attribute.namespace).\(attribute.key)=\(attribute.value)"
    }

    private func aprioriData(_ rules: [AprioriRule]) -> JSONValue {
        .object([
            "rules": .array(rules.map {
                .object([
                    "antecedent": .array($0.antecedent.map { .string("\($0)") }),
                    "consequent": .string("\($0.consequent)"),
                    "support": .double($0.support),
                    "confidence": .double($0.confidence),
                    "lift": .double($0.lift),
                    "evidenceCount": .integer(Int64($0.evidenceCount)),
                ])
            }),
        ])
    }

    private func complexityData(_ output: ComplexityOutput) -> JSONValue {
        var result: [String: JSONValue] = [
            "entropyA": .double(Double(output.result.entropyA)),
        ]
        if let entropyB = output.result.entropyB { result["entropyB"] = .double(Double(entropyB)) }
        if let mutualInformation = output.result.mutualInformation {
            result["mutualInformation"] = .double(Double(mutualInformation))
        }
        return .object([
            "totalCount": .integer(Int64(output.totalCount)),
            "result": .object(result),
        ])
    }

    private func trustData(_ output: TrustGroundedOutput) -> JSONValue {
        var data: [String: JSONValue] = [
            "context": .object([
                "summary": .string(output.context.summary),
                "patterns": .array(output.context.patterns.map(JSONValue.string)),
                "successRate": .double(Double(output.context.successRate)),
                "averageReward": .double(Double(output.context.averageReward)),
                "recommendations": .array(output.context.recommendations.map(JSONValue.string)),
                "keyInsights": .array(output.context.keyInsights.map(JSONValue.string)),
            ]),
            "rankedIDs": .array(output.rankedIDs.map { .string($0.lowercased()) }),
            "highTrustCount": .integer(Int64(output.highTrustCount)),
        ]
        if let values = output.calibratedConfidences {
            data["calibratedConfidences"] = .array(values.map {
                .object([
                    "claimed": .double(Double($0.claimed)),
                    "calibrated": .double(Double($0.calibrated)),
                    "isCalibrated": .bool($0.isCalibrated),
                ])
            })
        }
        return .object(data)
    }

    private func partialCueOutcome(
        _ matches: [CueMatch], context: AriaV2LensLower.Context
    ) async throws -> AriaV2RecallLensOutcome {
        let estate = try await kit.estate(for: handle)
        let drawersByID = try await RecipeTools.structuredDrawersByID(
            ids: matches.map(\.id), estate: estate,
            filterChain: context.authorizationFrame.filterChain)
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: drawersByID.values.map(\.parentNodeId))
        let rows = matches.map { match -> CandidateRowData in
            guard let drawer = drawersByID[match.id] else {
                return .init(id: match.id, eventTime: "-", score: match.score)
            }
            let projection = AriaV2RecallLensPrivacy.project(
                drawer: drawer, subject: drawer.subject,
                bestSpan: drawer.content.isEmpty ? nil : drawer.content,
                sscFacts: drawer.sscFacts, distilled: nil, representation: nil)
            return .init(
                id: drawer.id, subject: projection.subject, bestSpan: projection.bestSpan, sscFacts: projection.sscFacts,
                eventTime: ResultComposer.iso8601(drawer.eventTime), score: match.score,
                room: nodeNames[drawer.parentNodeId]?.room)
        }
        return .init(
            data: ResultComposer.structuredS1(rows: rows, control: .init()),
            compactText: "Found \(rows.count) partial-cue matches.")
    }
}

private struct ContradictionFactKey: Hashable {
    let subject: String
    let predicate: String
}

/// Typed v2 envelope projection with an operational refusal distinct from a
/// malformed request.  It never receives a text or JSON result from v1.
public struct AriaV2LensLowerService: Sendable {
    public let authority: any AriaV2LensLowerAuthority
    public let context: AriaV2LensLower.Context

    public init(authority: any AriaV2LensLowerAuthority, context: AriaV2LensLower.Context) {
        self.authority = authority
        self.context = context
    }

    public func execute(_ request: AriaV2RecallLensRequest) async throws -> JSONValue {
        do {
            let outcome = try await authority.execute(request, context: context)
            return AriaV2Envelope.success(
                tool: request.operation.rawValue, effect: .read, data: outcome.data,
                meta: ["completeness": .string("incomplete")], compactText: outcome.compactText)
        } catch let failure as AriaV2LensLower.Failure {
            switch failure {
            case .refusal(let refusal):
                return AriaV2Envelope.refusal(tool: request.operation.rawValue, error: refusal)
            }
        }
    }
}
