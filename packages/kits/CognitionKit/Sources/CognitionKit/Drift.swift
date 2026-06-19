import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Drift between the two time windows, with each window's size.
public struct DriftOutput: Sendable, Equatable {
    public let drift: DriftScore
    public let beforeCount: Int
    public let afterCount: Int
    public init(drift: DriftScore, beforeCount: Int, afterCount: Int) {
        self.drift = drift
        self.beforeCount = beforeCount
        self.afterCount = afterCount
    }
}

/// Drift — the conscious "what's changed about you" recipe (Lens 5,
/// Surprise). Recall a set, split it by event time into a before-window
/// and an after-window, build each window's distribution over rooms,
/// and measure how far the after-window has drifted (Jensen-Shannon /
/// KL via NeuronKit `drift`). "Your filing shifted across April."
///
/// Split is on `eventTime` (the memory's original event clock, ING-01),
/// not `filedAt` (the ingest clock). For live-capture drawers the two
/// coincide; for back-dated bulk ingest they differ — splitting on
/// `filedAt` would put a back-dated corpus entirely in the after-window.
/// `eventTime` is always non-nil on a Drawer (it resolves eagerly to
/// `filedAt` at capture when the caller does not supply an explicit
/// event time).
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via
/// GLK + NeuronKit drift (which surfaces SubstrateML's
/// InformationTheory). Read-only (B-6, I-6). Swift version of
/// `run_drift`.
public enum Drift {

    /// Measure room-distribution drift between drawers whose event time
    /// is before `splitAt` and those at/after it. A window with no
    /// drawers yields zero drift (nothing to compare). Read-only; a
    /// recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        splitAt: Date
    ) async throws -> DriftOutput {
        let drawers = try await kit.recall(handle, frame)

        var before: [String: Double] = [:]
        var after: [String: Double] = [:]
        for drawer in drawers {
            // Split on eventTime (the memory's event clock), not filedAt
            // (the ingest clock). ING-01: for back-dated corpora the two
            // differ; drifting on event time gives the semantically correct
            // "when did this happen" partition.
            if drawer.eventTime < splitAt {
                before[drawer.room, default: 0] += 1
            } else {
                after[drawer.room, default: 0] += 1
            }
        }
        let beforeCount = Int(before.values.reduce(0, +))
        let afterCount = Int(after.values.reduce(0, +))

        guard beforeCount > 0, afterCount > 0 else {
            return DriftOutput(
                drift: DriftScore(jensenShannon: 0, klDivergence: 0),
                beforeCount: beforeCount, afterCount: afterCount)
        }

        // Shared, aligned support across both windows (sorted ⇒
        // deterministic bin order, same discipline as the Rust BTree).
        let vocabulary = Set(before.keys).union(after.keys).sorted()

        // Laplace add-0.5 smoothing over the shared vocabulary.
        //
        // Without smoothing, bins present in one window but absent in the
        // other produce a p=0 / q>0 (or vice-versa) term. NeuronKit's
        // klDivergence skips the q=0 case (avoids +∞), but the p>0, q=0
        // case contributes a finite p*log(p/ε) term while the shared
        // negative terms dominate, giving KL < 0 — violating Gibbs'
        // inequality. Laplace smoothing with ε = 0.5 per bin guarantees
        // full shared support so no bin is zero in either distribution and
        // KL ≥ 0 holds unconditionally.
        //
        // ε = 0.5 (Jeffreys prior / Krichevsky–Trofimov estimator):
        // conservative enough to not swamp small counts, standard choice
        // for information-theoretic divergence on small multinomials.
        let epsilon = 0.5
        let n = Double(vocabulary.count)
        let smoothedBeforeTotal = Double(beforeCount) + n * epsilon
        let smoothedAfterTotal = Double(afterCount) + n * epsilon

        let p = vocabulary.map {
            Float(((before[$0] ?? 0) + epsilon) / smoothedBeforeTotal)
        }
        let q = vocabulary.map {
            Float(((after[$0] ?? 0) + epsilon) / smoothedAfterTotal)
        }

        // Renormalize to exactly 1.0 in Float32 so ∑p = ∑q = 1 at the
        // precision level NeuronKit's InformationTheory sees. Float32
        // accumulation of N terms can drift slightly from the true ratio
        // when N > 1; dividing by the Float32 sum corrects the rounding.
        let pSum = p.reduce(0, +)
        let qSum = q.reduce(0, +)
        let pNorm = p.map { $0 / pSum }
        let qNorm = q.map { $0 / qSum }

        return DriftOutput(
            drift: NeuronKit.drift(from: pNorm, to: qNorm),
            beforeCount: beforeCount, afterCount: afterCount)
    }
}
