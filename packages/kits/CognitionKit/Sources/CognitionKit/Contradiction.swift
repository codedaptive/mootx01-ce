import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// The odd-ones-out: drawer ids whose cohesion with the recalled set is
/// anomalously low, plus how many drawers were considered.
public struct ContradictionOutput: Sendable, Equatable {
    public let outliers: [String]
    public let considered: Int
    public init(outliers: [String], considered: Int) {
        self.outliers = outliers
        self.considered = considered
    }
}

/// Contradiction / odd-one-out — the conscious "what doesn't fit"
/// recipe (Lens 5, Surprise). Recall a set, score each drawer's content
/// cohesion with its peers (mean shingle similarity), and flag the ones
/// whose cohesion is anomalously LOW (a negative-z outlier) — the
/// memory in tension with the rest. The estate notices when something
/// doesn't belong.
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via
/// GLK + NeuronKit `shingleSimilarity` (cohesion) + NeuronKit
/// `anomalies` (which surfaces SubstrateML's AnomalyDetection).
/// Read-only (B-6, I-6). Swift version of `run_contradiction`.
public enum Contradiction {

    /// Flag drawers that don't fit the recalled set: cohesion[i] = mean
    /// content shingle-similarity of drawer i to the others; a drawer
    /// whose cohesion is a negative-z outlier (below the set, beyond
    /// `threshold`) is in tension. Needs at least 3 drawers to define
    /// "fit". Read-only; a recall failure propagates.
    ///
    /// Per spec § 7.3, `.structured` hydration returns `content = ""`
    /// (blob loading is skipped unless the filter chain has a content
    /// predicate or hydration is `.full`). This recipe requires the
    /// content body to compute shingle similarity, so the caller's
    /// hydration level is overridden to `.full` unconditionally. The
    /// rest of the frame (filter chain, limit, ordering, asOf) is
    /// preserved exactly as supplied.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        threshold: Float
    ) async throws -> ContradictionOutput {
        // Override hydration to .full: shingleSimilarity operates on
        // drawer.content, which is always "" under .structured (spec § 7.3).
        // Without .full the pairwise similarity is uniformly 0 and the
        // outlier detector runs on a flat cohesion vector — silent garbage.
        var fullFrame = frame
        fullFrame.hydrationLevel = .full
        let drawers = try await kit.recall(handle, fullFrame)
        let count = drawers.count
        guard count >= 3 else {
            return ContradictionOutput(outliers: [], considered: count)
        }

        // Per-drawer cohesion: mean shingle-similarity to every other
        // drawer.
        let cohesion = drawers.indices.map { i -> Float in
            var sum: Float = 0
            for j in drawers.indices where i != j {
                sum += NeuronKit.shingleSimilarity(drawers[i].content, drawers[j].content)
            }
            return sum / Float(count - 1)
        }

        // Low-cohesion outliers (negative z) are the contradictions.
        let outliers = NeuronKit.anomalies(values: cohesion, threshold: threshold)
            .filter { $0.zScore < 0 }
            .map { drawers[$0.index].id }

        return ContradictionOutput(outliers: outliers, considered: count)
    }
}
