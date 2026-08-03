// ConflictProjectionSweep.swift
//
// DCP M3 — the typed lane's orchestration: read the estate once, project
// KGFacts (M2), bucket them on the coordinate index (M2), evaluate every
// within-bucket pair (M1 evaluator), and return one deterministic report.
// Retrieval proposes; typed constraints prove — this sweep is the proving
// half that the lexical hunter (ContradictionHunt.swift) cannot supply.
//
// The sweep is a pure read: no clock (all instants come from stored fact
// and drawer times), no writes, no tunnel proposals. Downstream surfaces
// (moot_hunt_contradictions / moot_dream report sections, M4) render the
// findings; tunnel lifecycle wiring is M5. Rust twin:
// rust/src/brain/conflict_projection_sweep.rs (pure core) + the
// coordinator's estate seam.

import Foundation
import LocusKit
import SubstrateML

/// One proven-or-notable finding with the redaction input M4 needs: the
/// MAX sensitivity across both endpoints, counting each endpoint's own
/// KGFact as well as the drawer it was extracted from (M0 §8 — the
/// report ceiling is the max of sources; rendering applies grants).
public struct ConflictFinding: Sendable, Equatable {
    public let outcome: ConflictOutcome
    /// Raw `AdjectiveSensitivity` value of the most sensitive input to
    /// the pair: either endpoint's KGFact or either endpoint's source
    /// drawer. A fact carries its own sensitivity axis, independent of
    /// the drawer it came from, so a Restricted fact filed against a
    /// Normal drawer redacts the finding here. Any input whose
    /// sensitivity could not be resolved counts as the MAXIMUM tier
    /// (`.secret`), never as `.normal` — see `ConflictSweepCore.ceiling`
    /// for why this direction is the safe one.
    public let sensitivityCeilingRaw: Int
}

/// Outcome tallies for the report's additive lines (M0 §7).
public struct ConflictSweepCounts: Sendable, Equatable {
    public var agreement = 0
    public var compatiblePlurality = 0
    public var historicalSuccession = 0
    public var provenContradiction = 0
    public var candidateReview = 0
    /// InvalidInput + Irrelevant — pairs the typed lane could not judge
    /// (report line `unknown_or_invalid` together with unparsed facts).
    public var unknownOrInvalid = 0

    public init() {}
}

/// One sweep's outcome. Deterministic for a given estate state.
public struct ConflictProjectionSweepReport: Sendable {
    /// Projection exclusion counts (`coverage: projected/scanned`).
    public let diagnostics: ConflictProjectionDiagnostics
    /// Coordinate buckets that hit the cap (report line only when > 0).
    public let truncatedBuckets: Int
    /// Within-bucket pairs evaluated this sweep.
    public let pairsEvaluated: Int
    public let counts: ConflictSweepCounts
    /// Full detail for ProvenContradiction findings — the block M4
    /// renders (result id, rule, coordinate, reasons, source ids).
    public let proven: [ConflictFinding]
    /// Full detail for HistoricalSuccession findings — the "superseded,
    /// not conflicting" ledger.
    public let historical: [ConflictFinding]
}

/// The pure sweep core: estate reads happen in the caller; everything
/// here is deterministic on its inputs. Kept separate so tests drive it
/// without an estate and the Rust twin mirrors a function, not a verb.
public enum ConflictSweepCore {

    /// Run projection + index + evaluation.
    ///
    /// - Parameters:
    ///   - facts: All KGFacts scanned this sweep.
    ///   - eventTimeSecondsBySourceDrawer: Source-drawer event times in
    ///     EPOCH SECONDS (the caller owns the ms→s conversion, KI-003).
    ///   - sensitivityRawBySourceDrawer: Raw adjective-sensitivity per
    ///     source drawer — ONE of the two axes of the per-finding
    ///     redaction ceiling. The other axis, each fact's own
    ///     sensitivity, is read straight off `facts` and needs no
    ///     parameter (see the locator map built below).
    ///   - acceptedSupersessionPairs: Canonical pair keys (GLK
    ///     `pairKey` form) of drawer pairs joined by an ACTIVE
    ///     `supersedes` tunnel — the accepted-supersession input to the
    ///     evaluator (M0 §2: supersession converts overlap to
    ///     HistoricalSuccession only via an accepted tunnel or disjoint
    ///     validity).
    public static func run(
        facts: [KGFact],
        eventTimeSecondsBySourceDrawer: [String: Int64],
        sensitivityRawBySourceDrawer: [String: Int],
        acceptedSupersessionPairs: Set<String>,
        registry: ConflictRuleRegistry,
        bucketCap: Int = ConflictCoordinateIndex.defaultBucketCap
    ) -> ConflictProjectionSweepReport {
        let projection = ConflictProjector.project(
            facts: facts,
            eventTimeSecondsBySourceDrawer: eventTimeSecondsBySourceDrawer,
            registry: registry)
        var index = ConflictCoordinateIndex(bucketCap: bucketCap)
        index.insert(contentsOf: projection.signatures)

        // Each fact's OWN adjective sensitivity, keyed by the evidence
        // locator its signature carries. A KGFact has a sensitivity axis
        // independent of the drawer it was extracted from, so a
        // Restricted fact filed against a Normal drawer must still raise
        // the finding's ceiling.
        //
        // Keyed PER FACT, never folded into the drawer map. Several facts
        // routinely share one source drawer, and facts filed with no
        // source share the key "" — a drawer-keyed fold would push one
        // sensitive fact's tier onto every unrelated Normal fact behind
        // the same key. That over-redaction is not the safe direction: it
        // silently guts the contradiction surface this lane exists to
        // provide, and nothing surfaces the loss.
        //
        // Derived from `facts` rather than taken as a parameter so the
        // map is complete by construction — every signature in the index
        // was projected from this same array. A caller cannot hand in a
        // stale or partial map and blank the whole surface through the
        // fail-closed default below.
        var sensitivityRawByEvidenceLocator: [String: Int] = [:]
        for fact in facts {
            let locator = ConflictProjector.evidenceLocator(forFactID: fact.id)
            let raw = fact.adjectiveSensitivity.rawValue
            // Fold duplicates with MAX. Fact ids are unique in the
            // kg_facts table, but `run` is public and takes an arbitrary
            // array; on a repeated id the more sensitive reading wins.
            sensitivityRawByEvidenceLocator[locator] =
                max(sensitivityRawByEvidenceLocator[locator] ?? raw, raw)
        }

        var counts = ConflictSweepCounts()
        var proven: [ConflictFinding] = []
        var historical: [ConflictFinding] = []
        let pairs = index.pairs()

        for pair in pairs {
            let accepted = acceptedSupersessionPairs.contains(
                GeniusLocusKit.pairKey(pair.a.sourceDrawerID, pair.b.sourceDrawerID))
            let outcome = ConflictEvaluator.evaluate(
                pair.a, pair.b, registry: registry,
                acceptedSupersession: accepted)
            switch outcome.kind {
            case .agreement:
                counts.agreement += 1
            case .compatiblePlurality:
                counts.compatiblePlurality += 1
            case .historicalSuccession:
                counts.historicalSuccession += 1
                historical.append(ConflictFinding(
                    outcome: outcome,
                    sensitivityCeilingRaw: ceiling(
                        pair, sensitivityRawBySourceDrawer,
                        sensitivityRawByEvidenceLocator)))
            case .provenContradiction:
                counts.provenContradiction += 1
                proven.append(ConflictFinding(
                    outcome: outcome,
                    sensitivityCeilingRaw: ceiling(
                        pair, sensitivityRawBySourceDrawer,
                        sensitivityRawByEvidenceLocator)))
            case .candidateReview:
                counts.candidateReview += 1
            case .invalidInput, .irrelevant:
                counts.unknownOrInvalid += 1
            }
        }
        return ConflictProjectionSweepReport(
            diagnostics: projection.diagnostics,
            truncatedBuckets: index.truncatedBuckets,
            pairsEvaluated: pairs.count,
            counts: counts,
            proven: proven,
            historical: historical)
    }

    /// The finding's redaction ceiling: the MAX over four inputs — each
    /// endpoint's own KGFact sensitivity and each endpoint's source
    /// drawer sensitivity. The two axes are independent; a pair
    /// discloses through whichever of them is the more sensitive.
    private static func ceiling(
        _ pair: (a: ConflictSignature, b: ConflictSignature),
        _ sensitivityRawBySourceDrawer: [String: Int],
        _ sensitivityRawByEvidenceLocator: [String: Int]
    ) -> Int {
        // Fail closed. ANY of the four inputs that cannot be resolved
        // counts as the MAXIMUM tier, never as `.normal`: a hydration
        // gap — or a signature carrying no evidence locator — is not
        // evidence of low sensitivity, and the Elevated ceiling the
        // proposal loop enforces (`proposeConflictTunnels`) must not be
        // passable by a failed lookup.
        //
        // `.secret` — a real tier — rather than a sentinel like
        // `Int.max`, because this field is documented as a raw
        // `AdjectiveSensitivity` value and decoding coerces beyond-spec
        // raws back to `.normal`. Parking an out-of-range value here
        // would re-open the fail-open hole for any future caller that
        // decodes before comparing.
        let unresolved = AdjectiveSensitivity.secret.rawValue
        func factRaw(_ signature: ConflictSignature) -> Int {
            guard let locator = signature.evidenceLocator else { return unresolved }
            return sensitivityRawByEvidenceLocator[locator] ?? unresolved
        }
        return max(
            max(factRaw(pair.a), factRaw(pair.b)),
            max(sensitivityRawBySourceDrawer[pair.a.sourceDrawerID] ?? unresolved,
                sensitivityRawBySourceDrawer[pair.b.sourceDrawerID] ?? unresolved))
    }
}

public extension GeniusLocusKit {

    /// Run one typed conflict-projection sweep over `handle` (M0 §7's
    /// proving lane). Pure read — proposes no tunnels, mutates nothing.
    func conflictProjectionSweep(
        in handle: EstateHandle,
        registry: ConflictRuleRegistry = .v01,
        bucketCap: Int = ConflictCoordinateIndex.defaultBucketCap
    ) async throws -> ConflictProjectionSweepReport {
        let estate = try estate(for: handle)
        let facts = try await estate.allKGFacts()

        // One hydration for both per-drawer inputs: validity instants
        // and sensitivity ceilings.
        let sourceDrawerIDs = Array(Set(facts.map(\.sourceDrawerID)))
        var eventTimeSeconds: [String: Int64] = [:]
        var sensitivityRaw: [String: Int] = [:]
        if !sourceDrawerIDs.isEmpty {
            for drawer in try await estate.hydrateBodies(ids: sourceDrawerIDs) {
                eventTimeSeconds[drawer.id] =
                    Int64(drawer.eventTime.timeIntervalSince1970.rounded(.down))
                sensitivityRaw[drawer.id] = drawer.adjectiveSensitivity.rawValue
            }
        }

        // Accepted supersession: an ACTIVE supersedes tunnel between the
        // two source drawers (review-accept sets lifecycle .active).
        var acceptedPairs: Set<String> = []
        for tunnel in try await estate.allTunnels()
        where tunnel.kind == .supersedes && tunnel.lifecycle == .active {
            if let s = tunnel.sourceDrawerId, let t = tunnel.targetDrawerId {
                acceptedPairs.insert(Self.pairKey(s, t))
            }
        }

        return ConflictSweepCore.run(
            facts: facts,
            eventTimeSecondsBySourceDrawer: eventTimeSeconds,
            sensitivityRawBySourceDrawer: sensitivityRaw,
            acceptedSupersessionPairs: acceptedPairs,
            registry: registry,
            bucketCap: bucketCap)
    }
}
