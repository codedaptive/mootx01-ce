// CognitionKit.swift
//
// Eighteen retrieval primitives per cookbook § 11 and paper § 10.2.
//
// CognitionKit composes substrate-tier operations (Hamming-NN,
// matrix-tier scans, lattice traversal, audit-log fold) into
// higher-level retrieval primitives the cognition tier consumes.
// Each primitive returns a RecallResult: a ranked list of RowId
// plus a composite-distance breakdown plus (for federated queries)
// a confidence interval reflecting differential-privacy noise.
//
// Classes (paper § 10.2):
//
//   A direct retrieval:    by_id, by_fingerprint, by_lattice,
//                          by_predicate, recent, as_of
//   B similarity:          about, similar_moments,
//                          similar_moments_by_summary,
//                          partial_match, by_latent_factor,
//                          loading_on_factor
//   C graph-derived:       keystone, community,
//                          exploratory
//   D federation-aware:    federated, about_peer
//   E audit/explanation:   explain
//
// Composition rules (paper § 10.3): no hidden state, every output
// is an exposable RecallResult, composition is associative.
//
// Used by:
//   § 11 of cookbook   Eighteen primitives (this file)
//   § 10.2 of paper    Class taxonomy
//   § 10.3 of paper    Composition rules
//   § 10.4 of paper    RecallTrace feedback

import Foundation

// MARK: - Result types

public struct RecallScore: Equatable, Sendable {
    public let rowId: RowId
    public let score: Float32

    public init(rowId: RowId, score: Float32) {
        self.rowId = rowId
        self.score = score
    }
}

public struct DistanceBreakdown: Equatable, Sendable {
    public var latticeContribution: Float32
    public var fingerprintContribution: Float32
    public var temporalContribution: Float32
    public var bitmapContribution: Float32

    public init(lattice: Float32 = 0, fingerprint: Float32 = 0,
                temporal: Float32 = 0, bitmap: Float32 = 0) {
        self.latticeContribution = lattice
        self.fingerprintContribution = fingerprint
        self.temporalContribution = temporal
        self.bitmapContribution = bitmap
    }
}

public struct RecallResult: Sendable {
    public let rows: [RecallScore]
    public let breakdown: DistanceBreakdown
    public let confidenceInterval: (lower: Float32, upper: Float32)?
    public let primitiveName: String

    public init(rows: [RecallScore],
                breakdown: DistanceBreakdown = DistanceBreakdown(),
                confidenceInterval: (Float32, Float32)? = nil,
                primitiveName: String) {
        self.rows = rows
        self.breakdown = breakdown
        self.confidenceInterval = confidenceInterval
        self.primitiveName = primitiveName
    }
}

/// Minimal substrate row projection consumed by primitives.
public struct RowProjection: Sendable {
    public let rowId: RowId
    public let captureHLC: HLC
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor
    public let bitmaps: (adjective: UInt64, operational: UInt64, provenance: UInt64)
    public let rowState: UInt8

    public init(rowId: RowId, captureHLC: HLC,
                fingerprint: Fingerprint256, lattice: LatticeAnchor,
                bitmaps: (UInt64, UInt64, UInt64),
                rowState: UInt8) {
        self.rowId = rowId
        self.captureHLC = captureHLC
        self.fingerprint = fingerprint
        self.lattice = lattice
        self.bitmaps = bitmaps
        self.rowState = rowState
    }
}

// MARK: - CognitionKit primitives

public enum CognitionKit {

    // -----------------------------------------------------------
    // CLASS A: Direct retrieval
    // -----------------------------------------------------------

    /// 1. recall_by_id — single row lookup. Score is 1.0 if found.
    public static func recallById(rowId: RowId,
                                  in store: [RowProjection]) -> RecallResult {
        if let row = store.first(where: { $0.rowId == rowId }) {
            return RecallResult(rows: [RecallScore(rowId: row.rowId, score: 1.0)],
                                primitiveName: "recall_by_id")
        }
        return RecallResult(rows: [], primitiveName: "recall_by_id")
    }

    /// 2. recall_by_fingerprint — Hamming-NN top-k against a probe.
    public static func recallByFingerprint(probe: Fingerprint256,
                                           k: Int,
                                           in store: [RowProjection]) -> RecallResult {
        let scored = store.map { row -> RecallScore in
            let d = HammingDistance.distance(probe, row.fingerprint)
            let score = 1.0 - Float32(d) / 256.0
            return RecallScore(rowId: row.rowId, score: score)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rowId < rhs.rowId
        }
        return RecallResult(rows: Array(sorted.prefix(k)),
                            breakdown: DistanceBreakdown(fingerprint: 1.0),
                            primitiveName: "recall_by_fingerprint")
    }

    /// 3. recall_by_lattice — rows under a lattice anchor (optional
    /// subtree expansion to children in UDC or Wikidata).
    public static func recallByLattice(anchor: LatticeAnchor,
                                       includeSubtree: Bool,
                                       in store: [RowProjection]) -> RecallResult {
        let hits = store.compactMap { row -> RecallScore? in
            let match = includeSubtree
                ? LatticeDistance.isInSubtree(row.lattice, of: anchor)
                : (row.lattice == anchor)
            return match ? RecallScore(rowId: row.rowId, score: 1.0) : nil
        }
        return RecallResult(rows: hits,
                            breakdown: DistanceBreakdown(lattice: 1.0),
                            primitiveName: "recall_by_lattice")
    }

    /// 4. recall_by_predicate — rows whose bitmap columns match a
    /// (mask, value) pair on each of the three columns.
    public struct BitmapPredicate: Sendable {
        public let adjectiveMask: UInt64
        public let adjectiveValue: UInt64
        public let operationalMask: UInt64
        public let operationalValue: UInt64
        public let provenanceMask: UInt64
        public let provenanceValue: UInt64

        public init(adjectiveMask: UInt64 = 0, adjectiveValue: UInt64 = 0,
                    operationalMask: UInt64 = 0, operationalValue: UInt64 = 0,
                    provenanceMask: UInt64 = 0, provenanceValue: UInt64 = 0) {
            self.adjectiveMask = adjectiveMask
            self.adjectiveValue = adjectiveValue
            self.operationalMask = operationalMask
            self.operationalValue = operationalValue
            self.provenanceMask = provenanceMask
            self.provenanceValue = provenanceValue
        }
    }

    public static func recallByPredicate(_ pred: BitmapPredicate,
                                         in store: [RowProjection]) -> RecallResult {
        let hits = store.compactMap { row -> RecallScore? in
            let a = (row.bitmaps.adjective & pred.adjectiveMask) == pred.adjectiveValue
            let o = (row.bitmaps.operational & pred.operationalMask) == pred.operationalValue
            let p = (row.bitmaps.provenance & pred.provenanceMask) == pred.provenanceValue
            return (a && o && p) ? RecallScore(rowId: row.rowId, score: 1.0) : nil
        }
        return RecallResult(rows: hits,
                            breakdown: DistanceBreakdown(bitmap: 1.0),
                            primitiveName: "recall_by_predicate")
    }

    /// 5. recall_recent — rows captured in an HLC window.
    public static func recallRecent(window: ClosedRange<HLC>,
                                    in store: [RowProjection]) -> RecallResult {
        let hits = store
            .filter { window.contains($0.captureHLC) }
            .sorted { $0.captureHLC > $1.captureHLC }
            .map { RecallScore(rowId: $0.rowId, score: 1.0) }
        return RecallResult(rows: hits,
                            breakdown: DistanceBreakdown(temporal: 1.0),
                            primitiveName: "recall_recent")
    }

    /// 6. recall_as_of — substrate state projected to the supplied
    /// HLC. Returns one RecallScore per row that was non-tombstoned
    /// at the asOf instant. Score is 1.0 for matching rows. This is
    /// a wrapper over AuditLogFold.projectStateAt.
    public static func recallAsOf(hlc: HLC,
                                  auditLog: GSetAuditLog) -> RecallResult {
        // STUB — pre-v1.1: The canonical `AuditLogFold.projectStateAt` operates
        // per-row (rowId:, nounType:, events:, asOf:). A full
        // recall_as_of pass would iterate all known rowIds,
        // project each, then collect non-tombstoned hits. The
        // reference defers this aggregate to the substrate
        // adapter; here we return an empty result so the
        // signature is preserved for harness purposes.
        _ = hlc; _ = auditLog
        return RecallResult(rows: [], primitiveName: "recall_as_of")
    }

    // -----------------------------------------------------------
    // CLASS B: Similarity composition
    // -----------------------------------------------------------

    /// 7. recall_about — composite-distance top-k around a probe.
    /// Mixes lattice distance and fingerprint distance with the
    /// supplied learned weights.
    public static func recallAbout(probe: RowProjection,
                                   weights: CompositeDistanceWeights,
                                   k: Int,
                                   in store: [RowProjection]) -> RecallResult {
        let scored = store.map { row -> (RecallScore, DistanceBreakdown) in
            let lat = LatticeDistance.distance(probe.lattice, row.lattice)
            let fp = Float32(HammingDistance.distance(probe.fingerprint,
                                                     row.fingerprint)) / 256.0
            let composite = weights.latticeWeight * lat
                          + weights.fingerprintWeight * fp
            let score = 1.0 - composite
            return (RecallScore(rowId: row.rowId, score: score),
                    DistanceBreakdown(lattice: lat, fingerprint: fp))
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
            return lhs.0.rowId < rhs.0.rowId
        }
        let top = Array(sorted.prefix(k))
        let avgLat = top.reduce(Float32(0)) { $0 + $1.1.latticeContribution }
                   / Float32(max(top.count, 1))
        let avgFp = top.reduce(Float32(0)) { $0 + $1.1.fingerprintContribution }
                  / Float32(max(top.count, 1))
        return RecallResult(rows: top.map { $0.0 },
                            breakdown: DistanceBreakdown(lattice: avgLat,
                                                         fingerprint: avgFp),
                            primitiveName: "recall_about")
    }

    /// 8. recall_similar_moments — fingerprint-based similarity over
    /// MomentSummary fingerprints (each moment is OR-reduced).
    public static func recallSimilarMoments(probe: Fingerprint256,
                                            momentFps: [(RowId, Fingerprint256)],
                                            k: Int) -> RecallResult {
        let scored = momentFps.map { entry -> RecallScore in
            let d = HammingDistance.distance(probe, entry.1)
            return RecallScore(rowId: entry.0,
                               score: 1.0 - Float32(d) / 256.0)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rowId < rhs.rowId
        }
        return RecallResult(rows: Array(sorted.prefix(k)),
                            breakdown: DistanceBreakdown(fingerprint: 1.0),
                            primitiveName: "recall_similar_moments")
    }

    /// 9. recall_similar_moments_by_summary — moment-summary
    /// fingerprint similarity against precomputed window summaries.
    /// Same shape as recall_similar_moments but the index is the
    /// cached hour/day/week-window summaries from TemporalCompression.
    public static func recallSimilarMomentsBySummary(probe: Fingerprint256,
                                                     windowSummaries: [(RowId, Fingerprint256)],
                                                     k: Int) -> RecallResult {
        let result = recallSimilarMoments(probe: probe,
                                          momentFps: windowSummaries,
                                          k: k)
        return RecallResult(rows: result.rows,
                            breakdown: result.breakdown,
                            primitiveName: "recall_similar_moments_by_summary")
    }

    /// 10. recall_partial_match — match on some blocks, differ on
    /// others. Returns rows whose specified blocks have low Hamming
    /// distance and other specified blocks have HIGH Hamming
    /// distance. See PartialStateRecall for the shared logic.
    public static func recallPartialMatch(probe: Fingerprint256,
                                          matchBlocks: Set<Int>,
                                          differBlocks: Set<Int>,
                                          k: Int,
                                          in store: [RowProjection]) -> RecallResult {
        let hits = PartialStateRecall.topK(
            anchor: probe,
            rows: store.map { ($0.rowId, $0.fingerprint) },
            matchBlocks: matchBlocks,
            differBlocks: differBlocks,
            k: k)
        return RecallResult(rows: hits.map { RecallScore(rowId: $0.0, score: Float32($0.1)) },
                            breakdown: DistanceBreakdown(fingerprint: 1.0),
                            primitiveName: "recall_partial_match")
    }

    /// 11. recall_by_latent_factor — rows in the m × k W matrix from
    /// NMF that load on a specific factor above the threshold.
    public static func recallByLatentFactor(W: [[Float32]],
                                            factorIdx: Int,
                                            threshold: Float32,
                                            rowIds: [RowId]) -> RecallResult {
        precondition(W.count == rowIds.count, "W rows match rowIds")
        let hits = (0..<W.count).compactMap { i -> RecallScore? in
            let loading = W[i][factorIdx]
            return loading >= threshold
                ? RecallScore(rowId: rowIds[i], score: loading)
                : nil
        }
        let sorted = hits.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rowId < rhs.rowId
        }
        return RecallResult(rows: sorted,
                            primitiveName: "recall_by_latent_factor")
    }

    /// 12. recall_loading_on_factor — top-k rows ranked by loading
    /// on the requested factor (no threshold gate).
    public static func recallLoadingOnFactor(W: [[Float32]],
                                             factorIdx: Int,
                                             k: Int,
                                             rowIds: [RowId]) -> RecallResult {
        precondition(W.count == rowIds.count, "W rows match rowIds")
        let scored = (0..<W.count).map {
            RecallScore(rowId: rowIds[$0], score: W[$0][factorIdx])
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rowId < rhs.rowId
        }
        return RecallResult(rows: Array(sorted.prefix(k)),
                            primitiveName: "recall_loading_on_factor")
    }

    // -----------------------------------------------------------
    // CLASS C: Graph-derived retrieval
    // -----------------------------------------------------------

    /// 13. recall_keystone — top-k rows ranked by eigenvalue
    /// centrality on the supplied co-activation graph.
    public static func recallKeystone(centrality: [RowId: Float32],
                                      k: Int) -> RecallResult {
        let sorted = centrality
            .map { RecallScore(rowId: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.rowId < rhs.rowId
            }
        return RecallResult(rows: Array(sorted.prefix(k)),
                            primitiveName: "recall_keystone")
    }

    /// 14. recall_community — returns rows in the same Louvain community
    /// as the probe. Performs a same-community lookup and scoring pass
    /// against the provided community-label map.
    public static func recallCommunity(probe: RowId,
                                       communityLabels: [RowId: Int]) -> RecallResult {
        guard let probeLabel = communityLabels[probe] else {
            return RecallResult(rows: [], primitiveName: "recall_community")
        }
        let hits = communityLabels
            .filter { $0.value == probeLabel && $0.key != probe }
            .map { RecallScore(rowId: $0.key, score: 1.0) }
            .sorted { $0.rowId < $1.rowId }
        return RecallResult(rows: hits,
                            primitiveName: "recall_community")
    }

    /// 15. recall_exploratory — random-walk-with-restart aggregate that
    /// surfaces rows reachable via co-activation paths from the seed,
    /// delegating to RandomWalks.walkWithRestart.
    public static func recallExploratory(seed: RowId,
                                         steps: Int,
                                         restartProbability: Float32,
                                         rngSeed: UInt64,
                                         adjacency: [RowId: [RowId]]) -> RecallResult {
        let visits = RandomWalks.walkWithRestart(seed: seed,
                                                 steps: steps,
                                                 restartProbability: restartProbability,
                                                 rngSeed: rngSeed,
                                                 adjacency: adjacency)
        let totalVisits = visits.values.reduce(0, +)
        let scored = visits.map { (rowId, count) -> RecallScore in
            let prob = totalVisits > 0
                ? Float32(count) / Float32(totalVisits)
                : 0
            return RecallScore(rowId: rowId, score: prob)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rowId < rhs.rowId
        }
        return RecallResult(rows: sorted,
                            primitiveName: "recall_exploratory")
    }

    // -----------------------------------------------------------
    // CLASS D: Federation-aware retrieval
    // -----------------------------------------------------------

    /// 16. recall_federated — wrap any class-A or class-B primitive
    /// in a federated query. The local exact result is combined with
    /// noisy peer contributions; the breakdown includes a
    /// differential-privacy confidence interval.
    public static func recallFederated(localResult: RecallResult,
                                       peerResults: [RecallResult],
                                       privacyBudget: (epsilon: Float32,
                                                       delta: Float32)) -> RecallResult {
        // Combine: union rowId, sum scores
        var combined: [RowId: Float32] = [:]
        for s in localResult.rows {
            combined[s.rowId, default: 0] += s.score
        }
        for peer in peerResults {
            for s in peer.rows {
                combined[s.rowId, default: 0] += s.score
            }
        }
        let merged = combined
            .map { RecallScore(rowId: $0.key, score: $0.value) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.rowId < rhs.rowId
            }
        // CI bounds based on privacy budget (Laplace noise scale)
        let scale = 1.0 / privacyBudget.epsilon
        let ci: (Float32, Float32) = (-1.96 * scale, 1.96 * scale)
        return RecallResult(rows: merged,
                            breakdown: localResult.breakdown,
                            confidenceInterval: ci,
                            primitiveName: "recall_federated")
    }

    /// 17. recall_about_peer — recall_about applied across a paired
    /// estate's shareable rows. Uses the shared hyperplane family
    /// from the pairing handshake to make fingerprints comparable.
    public static func recallAboutPeer(probe: RowProjection,
                                       peerStore: [RowProjection],
                                       sharedFamily: HyperplaneFamily,
                                       weights: CompositeDistanceWeights,
                                       k: Int) -> RecallResult {
        // Note: `sharedFamily` is accepted as a parameter but not used here;
        // the probe is forwarded directly into recallAbout with the original
        // fingerprint. Production code would apply the shared family before recall.
        let result = recallAbout(probe: probe,
                                 weights: weights,
                                 k: k,
                                 in: peerStore)
        return RecallResult(rows: result.rows,
                            breakdown: result.breakdown,
                            primitiveName: "recall_about_peer")
    }

    // -----------------------------------------------------------
    // CLASS E: Audit and explanation
    // -----------------------------------------------------------

    /// 18. explain_recall — given a prior RecallResult, return the
    /// full intermediate state used to produce it: the candidate
    /// set before ranking, the composite-distance breakdown, the
    /// learned-weight values applied. The substrate's invariant
    /// I-13 forbids hiding internal state from the cognition tier,
    /// so explain is a first-class primitive.
    public struct Explanation: Sendable {
        public let primitive: String
        public let candidates: [RecallScore]
        public let breakdown: DistanceBreakdown
        public let appliedWeights: CompositeDistanceWeights?
        public let confidenceInterval: (lower: Float32, upper: Float32)?
    }

    public static func explainRecall(_ prior: RecallResult,
                                     candidates: [RecallScore],
                                     weights: CompositeDistanceWeights?) -> Explanation {
        return Explanation(primitive: prior.primitiveName,
                           candidates: candidates,
                           breakdown: prior.breakdown,
                           appliedWeights: weights,
                           confidenceInterval: prior.confidenceInterval)
    }
}
