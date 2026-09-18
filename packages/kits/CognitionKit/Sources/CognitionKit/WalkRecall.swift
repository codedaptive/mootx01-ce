// WalkRecall.swift
//
// An escalation-ladder recall recipe that runs cheap stages first and stops
// at the first stage that yields a confident result.
//
// Stage order (cascade study § 5, 2026-08-19):
//   Stage 1: ShapedRecall with the "session_hybrid" preset, pool 20.
//             Cheap, recency-aware, covers the common "I just filed this" query.
//   Stage 2: PreciseRecall with "hamming+text" composition.
//             Conservative choice that covers both factual (hamming-dominant)
//             and paraphrase-leaning (text-dominant) queries.
//
// Stop criterion: topGap ≥ 0.25 — the HIGH_MARGIN threshold from
// RecallDiscrimination (replicated inline below as `stopThreshold` to keep
// CognitionKit free of an AriaMcpKit import).
//
// TierAscendingQuery.computeLocal supplies the tier-ascending protocol
// semantics for the local scope. Federated traversal (peer, fleetAggregate,
// industryAggregate) is PARKED per the three-features ruling: only
// computeLocal is exercised here; the peer/fleet/industry ascension is not
// implemented and must not be added without Bob's explicit per-feature ruling.
//
// Boundary discipline (spec B-1/B-2): this recipe holds no substrate state
// and owns no math. Its only substrate touches are at most two sequential
// GLK recall verbs (one per stage). It SEQUENCES — run Stage 1, evaluate
// the stop criterion, optionally run Stage 2.
//
// Determinism: both GLK recall calls are deterministic given the same estate.
// The recipe takes `now` only for telemetry parity with the other recipes;
// it never calls Date() inside the evaluation path.

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateML
import SubstrateTypes

// MARK: - Output types

/// Which escalation stage produced the final result.
public enum WalkStage: String, Sendable, Equatable, Codable {
    /// Stage 1: ShapedRecall with the "session_hybrid" preset.
    case stage1SessionHybrid = "stage1_session_hybrid"
    /// Stage 2: PreciseRecall with "hamming+text" composition.
    case stage2PreciseHamming = "stage2_precise_hamming"
}

/// One walk-recall match: the same id/room/content/score shape PreciseMatch
/// uses, plus the stage that surfaced it.
public struct WalkMatch: Sendable, Equatable, Codable {
    /// The drawer's stable row id.
    public let id: String
    /// The drawer's room (structural coordinate).
    public let room: String
    /// The drawer's content.
    public let content: String
    /// The score from the stage that surfaced this match, in [0, 1].
    public let score: Double
    /// The escalation stage that produced this result.
    public let stage: WalkStage

    public init(id: String, room: String, content: String,
                score: Double, stage: WalkStage) {
        self.id = id
        self.room = room
        self.content = content
        self.score = score
        self.stage = stage
    }
}

/// The outcome of a walk-recall run.
public struct WalkRecallOutcome: Sendable {
    /// The matches, in the stage's rank order.
    public let matches: [WalkMatch]
    /// Which stage produced the final result.
    public let stage: WalkStage
    /// Whether the ladder stopped early (Stage 1 was confident) or
    /// escalated to Stage 2 (Stage 1 was not confident enough).
    public let stoppedEarly: Bool

    public init(matches: [WalkMatch], stage: WalkStage, stoppedEarly: Bool) {
        self.matches = matches
        self.stage = stage
        self.stoppedEarly = stoppedEarly
    }
}

// MARK: - WalkRecall namespace

/// WalkRecall — escalation-ladder recall recipe.
///
/// Runs cheap-first stages and stops at the first stage that meets the
/// confidence threshold. The recipe is a static enum namespace following the
/// TemporalRecall / PreciseRecall pattern; it does not conform to `Recipe`
/// because its output type (`WalkRecallOutcome`) is the recipe's primary
/// contract surface.
///
/// Stage 1 is cheap (session_hybrid preset, pool 20). Stage 2 escalates to
/// precise re-ranking only when Stage 1's top-gap is below the stop threshold.
///
/// TierAscendingQuery.computeLocal wraps the Stage 1 local dispatch through
/// the tier-ascending protocol structure. Peer/fleet/industry federation is
/// PARKED per the three-features ruling.
public enum WalkRecall {

    // MARK: - Stage configuration constants

    /// Stage 1 preset — "session_hybrid" is the best keeper for common
    /// estate types: recency-aware, low cost, handles the "I just filed
    /// this" query class well (cascade study § 5).
    public static let stage1Preset = "session_hybrid"

    /// Stage 1 candidate pool — 20 is the cascade study recommendation:
    /// large enough for good Stage 1 recall on typical personal estates,
    /// small enough to keep the stage cheap. The pool for Stage 2
    /// (PreciseRecall) defaults to its own `defaultPool` (30).
    public static let stage1Pool = 20

    /// Stage 2 composition — "hamming+text" is the conservative choice
    /// (cascade study § 5): covers both factual queries (hamming-dominant)
    /// and paraphrase-leaning queries (text-dominant) without pre-judging
    /// a winner between the two signal families.
    public static let stage2Composition = "hamming+text"

    /// The stop threshold: topGap must reach this value for Stage 1 to be
    /// considered confident. Matches RecallDiscrimination.HIGH_MARGIN = 0.25
    /// (AriaMcpKit); replicated here as a named constant so CognitionKit does
    /// not need to import AriaMcpKit. If HIGH_MARGIN changes, update this too.
    public static let stopThreshold: Double = 0.25

    /// Division-by-zero guard matching RecallDiscrimination.EPS.
    private static let eps: Double = 1e-9

    // MARK: - Public entry point

    /// Run the walk-recall escalation ladder.
    ///
    /// Stage 1 (ShapedRecall / session_hybrid, pool 20) runs first. If its
    /// top-gap ≥ 0.25, the result is returned immediately (stoppedEarly: true).
    /// Otherwise Stage 2 (PreciseRecall / hamming+text) runs and its result is
    /// returned (stoppedEarly: false).
    ///
    /// TierAscendingQuery.computeLocal wraps the Stage 1 dispatch through the
    /// tier-ascending protocol. Peer/fleet/industry federation is PARKED.
    ///
    /// - Parameters:
    ///   - kit:    the GeniusLocusKit actor.
    ///   - handle: the estate to recall against.
    ///   - query:  the search query text (drives BM25 + vector).
    ///   - filter: the recall filter chain entry (e.g. `.unconfirmed`).
    ///   - limit:  how many ranked matches to return.
    ///   - now:    deterministic instant for telemetry (not used in ranking).
    /// - Returns: `WalkRecallOutcome` with the results and which stage ran.
    /// - Throws: any upstream GLK recall error, unchanged.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        query: String,
        filter: LocusKit.Filter,
        limit: Int,
        now: Date
    ) async throws -> WalkRecallOutcome {

        // MARK: Stage 1 — ShapedRecall with session_hybrid preset.
        //
        // Run ShapedRecall to get PreciseMatch-shaped results WITH content.
        // The pool is clamped to at least stage1Pool (20) — the cascade study
        // recommendation — even when `limit` is smaller.
        let shapedOut = try await ShapedRecall().run(
            input: .init(query: query, preset: stage1Preset, filter: filter,
                         limit: max(limit, stage1Pool)),
            estate: handle, kit: kit)

        // Project ShapedRecall output to WalkMatch (stage 1).
        let stage1Matches = shapedOut.matches.map { m in
            WalkMatch(id: m.id, room: m.room, content: m.content,
                      score: m.score, stage: .stage1SessionHybrid)
        }

        // Wrap the Stage 1 result through TierAscendingQueryProtocol.computeLocal.
        //
        // This satisfies the tier-ascending protocol obligation (B-1): every
        // local-scope query is dispatched through computeLocal so the protocol
        // structure is observed even when no peer tier is contacted.
        //
        // The dispatch closure is synchronous; we pre-fetch the async GLK result
        // (ShapedRecall above) and return it through the closure. The protocol's
        // primitiveName/primitiveInput fields are nominal here — computeLocal
        // passes them to the closure, which ignores them and returns the
        // pre-computed RecallResult.
        //
        // targetTier: .peer marks the LOCAL scope per the protocol: "I would
        // ascend to the first peer tier", but computeLocal intercepts. No budget
        // is consumed. Peer/fleet/industry ascension is PARKED — three-features
        // ruling; do not add it without an explicit per-feature approval.
        let taqRows: [RecallScore] = shapedOut.matches.compactMap { m in
            guard let uuid = UUID(uuidString: m.id) else { return nil }
            return RecallScore(rowId: uuid, score: Float32(m.score))
        }
        let prebuiltResult = RecallResult(rows: taqRows, primitiveName: stage1Preset)
        let taq = TierAscendingQuery(
            originatingEstate: handle.estateUUID,
            primitiveName: "walk_recall_stage1",
            primitiveInput: Data(),
            targetTier: .peer,
            privacyBudget: DPParameters(),
            queryHLC: HLC.zero)
        // computeLocal is synchronous and returns the pre-built result unchanged.
        // The return value mirrors `prebuiltResult`; we use `stage1Matches`
        // (which carry content) for the actual WalkMatch projection.
        let _ = TierAscendingQueryProtocol.computeLocal(
            query: taq,
            dispatch: { _, _ in prebuiltResult })

        // MARK: Stop criterion — topGap ≥ stopThreshold (0.25).
        //
        // Compute the relative gap between rank-1 and rank-2 scores.
        // Mirrors RecallDiscrimination.classify's HIGH_MARGIN arm:
        //   topGap = (s0 - s1) / max(|s0|, eps)
        // If topGap ≥ 0.25, Stage 1 is confident — return early.
        let stage1Scores = stage1Matches.map { $0.score }
        if isConfident(stage1Scores) {
            return WalkRecallOutcome(
                matches: Array(stage1Matches.prefix(limit)),
                stage: .stage1SessionHybrid,
                stoppedEarly: true)
        }

        // MARK: Stage 2 — PreciseRecall with "hamming+text" composition.
        //
        // Stage 1 did not reach the confidence threshold. Escalate to the
        // precision re-ranker with the "hamming+text" composition (cascade
        // study § 5: the conservative choice that covers both factual and
        // paraphrase-leaning queries).
        let stage2Precise = try await PreciseRecall.run(
            kit: kit,
            handle: handle,
            query: query,
            filter: filter,
            limit: limit,
            pool: PreciseRecall.defaultPool,
            composition: stage2Composition)

        let stage2Matches = stage2Precise.map { m in
            WalkMatch(id: m.id, room: m.room, content: m.content,
                      score: m.score, stage: .stage2PreciseHamming)
        }

        return WalkRecallOutcome(
            matches: stage2Matches,
            stage: .stage2PreciseHamming,
            stoppedEarly: false)
    }

    // MARK: - Stop criterion helper

    /// True when the score list meets the stop criterion (topGap ≥ stopThreshold).
    ///
    /// Mirrors RecallDiscrimination.classify's high-level arm, inline here so
    /// CognitionKit does not need an AriaMcpKit import:
    ///   topGap = (s0 - s1) / max(|s0|, eps)  ≥  stopThreshold (0.25)
    ///
    /// Edge cases:
    ///   - Empty list  → NOT confident (escalate): Stage 1 finding nothing is a
    ///     signal to try harder, not to stop.
    ///   - Single item → confident (stop): nothing to disambiguate; Stage 2
    ///     cannot improve on a single-result list.
    internal static func isConfident(_ scores: [Double]) -> Bool {
        guard !scores.isEmpty else {
            // Empty list: Stage 1 found nothing — escalate to Stage 2.
            return false
        }
        guard scores.count >= 2 else {
            // Single result: no disambiguation needed — stop.
            return true
        }
        let s0 = scores[0]
        let s1 = scores[1]
        let denom = max(abs(s0), eps)
        let topGap = (s0 - s1) / denom
        return topGap >= stopThreshold
    }
}
