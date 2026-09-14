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
        /// The stable provider supplies its verified policy explicitly for
        /// aggregate projections that otherwise do not consume a drawer frame.
        /// Nil keeps the selected-public v2 path unchanged.
        public let maximumSensitivity: AdjectiveSensitivity?
        public let exportableOnly: Bool
        /// Comparison estates the host has separately authorized for this
        /// request.  The lower adapter cannot open a peer from an opaque UUID.
        public let comparisonHandles: [UUID: EstateHandle]

        public init(
            estateID: UUID,
            now: Date,
            authorizationFrame: RecallFrame = .init(filterChain: []),
            maximumSensitivity: AdjectiveSensitivity? = nil,
            exportableOnly: Bool = false,
            comparisonHandles: [UUID: EstateHandle] = [:]
        ) {
            self.estateID = estateID
            self.now = now
            self.authorizationFrame = authorizationFrame
            self.maximumSensitivity = maximumSensitivity
            self.exportableOnly = exportableOnly
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
            // Dense-row hydration through the sensitivity gate (empty filterChain →
            // BitmapEvaluator.insertDefaults injects sensitivityAtMost(.elevated)).
            // Adjective-gated rows are absent from drawersByID when maximumSensitivity
            // is set; provenance-gated rows (bits 30-35) may be present regardless and
            // are caught by AriaV2RecallLensPrivacy.classify in the row builder. Both
            // axes produce the same sparse key set {id, centrality} (indistinguishability rule).
            let estate = try await kit.estate(for: handle)
            // Full hydration so drawer.content is populated — structured hydration
            // returns content == "" (Swift spec §7.3) which would collapse every
            // bestSpan to "-". Rust get_drawers_matching_frame always loads full rows
            // (P6-secfix), so full hydration here keeps both ports on the same path.
            // The sensitivity gate still applies via BitmapEvaluator on the filterChain.
            let drawersByID: [String: Drawer]
            if await AriaV2Withheld.enabled {
                // Count only ranked topK endpoints presented to hydration. The
                // Locus gate distinguishes sensitivity from every other predicate.
                let counted = try await kit.hydrateWithSensitivityCount(handle,
                    ids: ranked.map(\.id),
                    frame: context.maximumSensitivity == nil ? RecallFrame(filterChain: []) : context.authorizationFrame,
                    hydrationLevel: .full)
                await AriaV2Withheld.record(counted.withheldBySensitivity)
            }
            if context.maximumSensitivity != nil {
                let admitted = try await estate.getDrawers(
                    ids: ranked.map(\.id), matchingFrame: context.authorizationFrame,
                    hydrationLevel: .full).admissible
                drawersByID = Dictionary(uniqueKeysWithValues: admitted.map { ($0.id, $0) })
            } else {
                drawersByID = try await RecipeTools.structuredDrawersByID(
                    ids: ranked.map { $0.id }, estate: estate, hydrationLevel: .full)
            }
            let keystoneOnly = try boolean(request, "keystoneOnly", defaultValue: false)
            let admittedRanked = context.maximumSensitivity == nil ? ranked : ranked.filter {
                drawersByID[$0.id] != nil || drawersByID[$0.id.lowercased()] != nil
            }
            let projectedRanked = keystoneOnly ? admittedRanked.filter { keystone in
                (drawersByID[keystone.id] ?? drawersByID[keystone.id.lowercased()])?.hasFeatureFlag(.isKeystone) == true
            } : admittedRanked
            return .init(data: .object(["keystones": .array(projectedRanked.map { keystone in
                let id = keystone.id.lowercased()
                guard let drawer = drawersByID[keystone.id] ?? drawersByID[keystone.id.lowercased()] else {
                    // Adjective-gated row: id and centrality only.
                    return .object(["id": .string(id), "centrality": .double(keystone.centrality)])
                }
                // Both the adjective axis (bits 6-11) and the provenance axis (bits 30-35)
                // decide whether dense fields are emitted. Map-absent rows handle the
                // adjective gate above; AriaV2RecallLensPrivacy.classify catches
                // provenance-gated rows here. Both emit the same sparse key set
                // {id, centrality} (indistinguishability rule).
                guard AriaV2RecallLensPrivacy.classify(drawer) == .admissible else {
                    return .object(["id": .string(id), "centrality": .double(keystone.centrality)])
                }
                // Normalize and cut bestSpan through the shared ResultComposer helper.
                // The noSubjectMarker
                // matches Rust's NO_SUBJECT_MARKER = "(no subject)" via
                // ARIAServerConstants, keeping both ports on the same wire value.
                let span = ResultComposer.truncateFirstSentence(drawer.content)
                return .object([
                    "id": .string(id),
                    "centrality": .double(keystone.centrality),
                    "subject": .string(drawer.subject ?? ResultComposer.noSubjectMarker),
                    "bestSpan": .string(span.isEmpty ? "-" : span),
                    "eventTime": .string(ResultComposer.iso8601(drawer.eventTime)),
                ])
            })]), compactText: "Found \(projectedRanked.count) keystones.")

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
            // directly; it never parses a rendered text response.
            let estate = try await kit.estate(for: handle)
            // COUNT FIRST, THEN WITHHOLD. Filtering by sensitivity before
            // counting makes a restricted contradiction vanish from the total,
            // so an estate with three contradictions reports one and the
            // caller is told the estate is more consistent than it is. For a
            // contradiction lens the count IS the product. Restricted tunnel
            // rows are omitted from the emitted set; only the tally is complete.
            // Endpoint ids within kept (Normal/Elevated) tunnel rows are always
            // emitted — an id is not body-derived content (WITHHELD-ID-ONLY = a).
            let allContradictions = (try await estate.allTunnels()).filter {
                $0.kind == .contradicts && $0.tombstonedAt == nil
                    && ($0.lifecycle == .active || $0.lifecycle == .proposed)
            }
            let tunnels = allContradictions.filter { $0.adjectiveSensitivity.isBulkExportable }
            let withheldTunnelCount = allContradictions.count - tunnels.count
            let emittedTunnels = Array(tunnels.prefix(50))
            let tunnelRows = emittedTunnels.map { tunnel -> JSONValue in
                var row: [String: JSONValue] = [
                    "id": .string(tunnel.id),
                    "lifecycle": .string(tunnel.lifecycle == .proposed ? "proposed" : "active"),
                ]
                if let source = tunnel.sourceDrawerId {
                    row["sourceDrawerId"] = .string(source)
                }
                if let target = tunnel.targetDrawerId {
                    row["targetDrawerId"] = .string(target)
                }
                return .object(row)
            }

            // Same rule for fact groups: a group is conflicting or it is not,
            // and that is decided over every fact. Filtering first can hide a
            // whole group, or — worse — leave a group looking consistent
            // because the fact that disagreed was restricted.
            let allFacts = try await kit.recallKGFacts(handle)
            var allFactsByKey: [ContradictionFactKey: [KGFact]] = [:]
            for fact in allFacts {
                let key = ContradictionFactKey(
                    subject: fact.subject.lowercased(), predicate: fact.predicate.lowercased())
                allFactsByKey[key, default: []].append(fact)
            }
            let allConflictingKeys = Set(
                allFactsByKey
                    .filter { Set($0.value.map { $0.object.lowercased() }).count > 1 }
                    .keys)
            let facts = allFacts.filter { $0.adjectiveSensitivity.isBulkExportable }
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
                // The primary sort key rounds filedAt to the nearest millisecond.
                // .rounded() (Swift's .toNearestOrAwayFromZero rule) reproduces
                // what ISO8601DateFormatter with .withFractionalSeconds emits and
                // reads back: the formatter rounds fractional seconds to 3 decimal
                // places, so a Date that passes through SQLite storage loses its
                // sub-millisecond residue via rounding, not via floor. For the
                // in-memory path (InMemoryStorage), the raw Date is retained at
                // full precision; this expression normalises both paths to the
                // same persisted millisecond value.
                //
                // Why not .rounded(.down) (floor)?  floor(-1000.4) is -1001, but
                // the formatter writes the fractional-seconds part of -1.0004 s as
                // 0.9996, which it rounds UP to 1.000, carrying into the next
                // calendar second. The round-trip therefore yields -1000 ms, not
                // -1001. Floor diverges from the persisted value whenever the
                // residue MEASURED AS A FRACTION OF THE ISO SECOND is half a
                // millisecond or more — that is the quantity the formatter rounds.
                // Name the frame, because it is not the frame of the expression
                // below: -1.0004 s has a 0.4 ms residue in signed epoch
                // milliseconds, under half, and floor diverges there anyway. The
                // pre-epoch carry is one instance of the condition, not the whole
                // of it; at a negative instant floor diverges for any nonzero
                // residue at all.
                //
                // No narrowing conversion is used, so no input value can trap.
                // Two facts whose rounded-millisecond keys are equal — because
                // their filedAt values round to the same millisecond, or because
                // they were stored identically — fall through to the UTF-8
                // byte-order tie-break. Comparing the resulting Doubles with ==
                // and < is exact: the values are integral after .rounded(), and a
                // Double represents integers exactly to 2^53 (~9.0e15 ms), well
                // beyond the persistence layer's round-trip bounds of
                // -62135596800000 and 253402300799999.
                //
                // The secondary key uses UTF-8 byte order (lexicographicallyPrecedes
                // over .utf8 views) to match the Rust port's String::cmp exactly.
                // Do not simplify to `<`, which is Unicode-canonical and diverges
                // from the Rust port on any non-ASCII object text.
                let sortedFacts = conflictingFacts.sorted { lhs, rhs in
                    let lhsMs = (lhs.filedAt.timeIntervalSince1970 * 1000).rounded()
                    let rhsMs = (rhs.filedAt.timeIntervalSince1970 * 1000).rounded()
                    return lhsMs == rhsMs
                        ? lhs.object.utf8.lexicographicallyPrecedes(rhs.object.utf8)
                        : lhsMs < rhsMs
                }
                var seen = Set<String>()
                var objects: [JSONValue] = []
                for fact in sortedFacts where seen.insert(fact.object.lowercased()).inserted {
                    objects.append(.string(fact.object))
                }
                factRows.append(.object([
                    "subject": .string(key.subject),
                    "predicate": .string(key.predicate),
                    "objects": .array(objects),
                ]))
            }
            let visibleConflictingKeys = Set(
                factsByKey
                    .filter { Set($0.value.map { $0.object.lowercased() }).count > 1 }
                    .keys)
            let withheldFactGroupCount = allConflictingKeys.subtracting(visibleConflictingKeys).count
            let totalContradictions = allContradictions.count
            let totalFactGroups = allConflictingKeys.count
            var summary = "Found \(totalContradictions) contradiction tunnels "
                + "and \(totalFactGroups) conflicting fact groups."
            if withheldTunnelCount > 0 || withheldFactGroupCount > 0 {
                summary += " \(withheldTunnelCount + withheldFactGroupCount) withheld by sensitivity."
            }
            return .init(data: .object([
                "contradictsTunnels": .array(tunnelRows),
                "conflictingFacts": .array(factRows),
                // Totals over EVERYTHING, so the caller learns the estate has
                // a contradiction even where the rows are not theirs to read.
                "totalContradictionCount": .integer(Int64(totalContradictions)),
                "totalConflictingFactGroupCount": .integer(Int64(totalFactGroups)),
                // How much of the above is redacted out of the rows above.
                "withheldContradictionCount": .integer(Int64(withheldTunnelCount)),
                "withheldConflictingFactGroupCount": .integer(Int64(withheldFactGroupCount)),
            ]), compactText: summary)

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
            var countedFrame = frame(request, context: context)
            countedFrame.hydrationLevel = .full
            try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: countedFrame)
            // Dense-row hydration through the sensitivity gate (empty filterChain).
            // Full hydration so drawer.content is populated for bestSpan computation;
            // structured hydration returns content == "" per Swift spec §7.3.
            let trustEstate = try await kit.estate(for: handle)
            let trustDrawersByID = try await RecipeTools.structuredDrawersByID(
                ids: output.rankedIDs, estate: trustEstate, hydrationLevel: .full)
            return .init(
                data: trustData(output, drawersByID: trustDrawersByID),
                compactText: "Synthesized \(output.rankedIDs.count) trust-ranked memories.")

        case .lensPartialCue:
            // Map the mode string to CueMode.  AriaV2RecallLensRequest.init
            // validates the mode enum at decode time; an unknown value never
            // reaches here via the shipped surface.  The switch over a String
            // requires a default arm; the type's single validating initializer
            // makes that arm unreachable today.  Throwing rather than silently
            // defaulting stops a future non-validating construction path from
            // coercing an unknown mode into feelsLike.
            let cueMode: CueMode
            if let rawMode = request.arguments["mode"]?.stringValue {
                switch rawMode {
                case "feelsLike": cueMode = .feelsLike
                case "aboutThis": cueMode = .aboutThis
                case "fromThen":  cueMode = .fromThen
                default:
                    // Unreachable today: AriaV2RecallLensRequest declares exactly one
                    // initializer, which throws and validates.  Every construction site
                    // goes through the validating init.  Throwing here rather than
                    // silently defaulting ensures a future non-validating path does not
                    // coerce an unknown mode into feelsLike.
                    throw AriaV2InvalidArgument(
                        path: "mode",
                        message: "Unknown mode '\(rawMode)'. Valid: feelsLike, aboutThis, fromThen.",
                        allowed: ["feelsLike", "aboutThis", "fromThen"],
                        correction: "Use \"feelsLike\", \"aboutThis\", or \"fromThen\"."
                    ).jsonRPCError
                }
            } else {
                cueMode = .feelsLike
            }
            // The schema normalises anchor_memory_id to canonical lowercase.
            // PartialCueRecall.run compares drawer.id directly: the Swift port
            // stores uppercase UUIDs (Apple native form) while the Rust port
            // stores lowercase. Try both spellings so either storage form resolves.
            // AnchorNotInRecalledSetError after the first try causes a retry with
            // the other spelling; all other errors propagate immediately.
            let canonicalAnchorID = try string(request, "anchor_memory_id")
            let spellings = UUID(uuidString: canonicalAnchorID).map(
                AriaV2ArgumentDecoder.storageIdentitySpellings) ?? [canonicalAnchorID]
            let k = positiveInteger(request, "limit", defaultValue: 5)
            var latestAnchorError: AnchorNotInRecalledSetError?
            for spelling in spellings {
                let matches: [CueMatch]
                do {
                    matches = try await PartialCueRecall.run(
                        kit: kit, handle: handle, frame: context.authorizationFrame,
                        anchorID: spelling, mode: cueMode, k: k)
                } catch let e as AnchorNotInRecalledSetError {
                    latestAnchorError = e
                    continue
                }
                // partialCueOutcome is outside the retry do-block so only the
                // recall attempt is retried — an AnchorNotInRecalledSetError
                // from envelope construction would be a distinct defect and
                // must propagate, not trigger a second spelling attempt.
                try await AriaV2Withheld.recall(kit: kit, handle: handle, frame: context.authorizationFrame)
                return try await partialCueOutcome(matches, context: context)
            }
            throw latestAnchorError ?? AnchorNotInRecalledSetError(anchorID: canonicalAnchorID)

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
            // Both storage spellings, and the result is keyed by whichever one
            // the estate holds rather than by the spelling the caller sent.
            // Public v2 ids are canonical lowercase while the estate may hold
            // the native uppercase form, so a single-spelling lookup here fails
            // for every id. Both .lensNodeMotion and .lensPartialCue derive both
            // spellings via AriaV2ArgumentDecoder.storageIdentitySpellings so
            // either port's storage form resolves. Refusal is deliberately the
            // same for an unknown id, a tombstoned row and a gated one: a caller must not
            // learn which.
            let spellings = (UUID(uuidString: id).map(
                AriaV2ArgumentDecoder.storageIdentitySpellings) ?? [id])
            let resolved = try await RecipeTools.structuredDrawersByID(
                ids: spellings, estate: estate,
                filterChain: context.authorizationFrame.filterChain)
            guard let drawer = spellings.compactMap({ resolved[$0] }).first,
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
        guard let supplied = request.arguments[key] else { return defaultValue }
        let value: Int
        if let integer = supplied.integerValue {
            value = Int(integer)
        } else if let raw = supplied.stringValue, let parsed = Int(raw) {
            value = parsed
        } else {
            throw AriaV2LensLower.refusal("Lens argument '\(key)' must be an integer in 1...\(maximum).")
        }
        guard value >= 1, value <= maximum else {
            throw AriaV2LensLower.refusal("Lens argument '\(key)' must be an integer in 1...\(maximum).")
        }
        return value
    }

    private func boolean(
        _ request: AriaV2RecallLensRequest, _ key: String, defaultValue: Bool
    ) throws -> Bool {
        guard let supplied = request.arguments[key] else { return defaultValue }
        if let value = supplied.boolValue { return value }
        if let raw = supplied.stringValue, let value = Bool(raw) { return value }
        throw AriaV2LensLower.refusal("Lens argument '\(key)' must be a boolean.")
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

    /// Three years, matching the v1 ceiling. Expressed the same way v1 wrote
    /// it so the two are comparable at a glance.
    static let maximumWindowSeconds: TimeInterval = 3 * 365.25 * 24 * 60 * 60

    private func dateWindow(
        _ request: AriaV2RecallLensRequest, start: String, end: String
    ) throws -> ClosedRange<Date> {
        let lower = try iso8601Date(request, start)
        let upper = try iso8601Date(request, end)
        guard lower <= upper else {
            throw AriaV2LensLower.refusal("The lens time window must not be inverted.")
        }
        // A window spanning decades scans the entire corpus and exhausts
        // memory, so the span is capped at three years — generous for any
        // analytical query and the same ceiling v1 enforced. The cap survived
        // into v2 only inside the v1 dispatch table, where nothing can reach
        // it, so the live path had no bound at all.
        guard upper.timeIntervalSince(lower) <= Self.maximumWindowSeconds else {
            throw AriaV2LensLower.refusal(
                "The lens time window must not exceed three years; reduce the range.")
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

    /// Build the trust synthesis wire payload.
    ///
    /// `drawersByID` is the result of `RecipeTools.structuredDrawersByID` with an
    /// empty filterChain (the sensitivity gate). Rows absent from the map and
    /// provenance-gated rows (AriaV2RecallLensPrivacy.classify != .admissible)
    /// carry only the id field; admissible rows carry all dense fields
    /// (subject, bestSpan, eventTime).
    private func trustData(
        _ output: TrustGroundedOutput,
        drawersByID: [String: Drawer]
    ) -> JSONValue {
        // Dense-row hydration: rankedIDs becomes an array of objects.
        // Map-absent and provenance-gated rows carry only {id};
        // admissible rows carry {id, subject, bestSpan, eventTime}.
        let rankedRows: JSONValue = .array(output.rankedIDs.map { id in
            let lowID = id.lowercased()
            // Case-normalised lookup: dict keys come from $0.id (estate-fetched IDs)
            // which may differ in case from the IDs that flow through ranked output.
            guard let drawer = drawersByID[id] ?? drawersByID[lowID] else {
                return .object(["id": .string(lowID)])
            }
            // Both the adjective axis (bits 6-11) and the provenance axis (bits 30-35)
            // decide whether dense fields are emitted. Map-absent rows handle the
            // adjective gate above; AriaV2RecallLensPrivacy.classify catches
            // provenance-gated rows here. Both emit the same sparse key set {id}
            // (indistinguishability rule).
            guard AriaV2RecallLensPrivacy.classify(drawer) == .admissible else {
                return .object(["id": .string(lowID)])
            }
            // Normalize and cut through the shared helper so both ports emit identical
            // values for subject-debt drawers and multiline content.
            let span = ResultComposer.truncateFirstSentence(drawer.content)
            return .object([
                "id": .string(lowID),
                "subject": .string(drawer.subject ?? ResultComposer.noSubjectMarker),
                "bestSpan": .string(span.isEmpty ? "-" : span),
                "eventTime": .string(ResultComposer.iso8601(drawer.eventTime)),
            ])
        })
        var data: [String: JSONValue] = [
            "context": .object([
                "summary": .string(output.context.summary),
                "patterns": .array(output.context.patterns.map(JSONValue.string)),
                "successRate": .double(Double(output.context.successRate)),
                "averageReward": .double(Double(output.context.averageReward)),
                "recommendations": .array(output.context.recommendations.map(JSONValue.string)),
                "keyInsights": .array(output.context.keyInsights.map(JSONValue.string)),
            ]),
            "rankedIDs": rankedRows,
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
        // Full hydration so drawer.content is populated for bestSpan computation;
        // structured hydration returns content == "" (Swift spec §7.3) which would
        // make every bestSpan nil. Two independent sensitivity axes still gate
        // the row. The adjective ceiling reaches it through the filterChain:
        // BitmapEvaluator injects sensitivityAtMost(.elevated) whenever the
        // chain carries no sensitivity filter of its own, which is a wider
        // condition than an empty chain. The provenance axis is a different bit
        // field and is applied below by AriaV2RecallLensPrivacy.project; neither
        // axis covers the other. This mirrors the keystones path.
        let drawersByID = try await RecipeTools.structuredDrawersByID(
            ids: matches.map(\.id), estate: estate,
            filterChain: context.authorizationFrame.filterChain,
            hydrationLevel: .full)
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
