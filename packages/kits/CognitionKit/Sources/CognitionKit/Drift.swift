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
/// Surprise). Recall a set, split it by capture time into a
/// before-window and an after-window, build each window's distribution
/// over rooms, and measure how far the after-window has drifted
/// (Jensen-Shannon / KL via NeuronKit `drift`). "Your filing shifted
/// across April."
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via
/// GLK + NeuronKit drift (which surfaces SubstrateML's
/// InformationTheory). Read-only (B-6, I-6). Swift version of
/// `run_drift`.
public enum Drift {

    /// Measure room-distribution drift between drawers captured before
    /// `splitAt` and those captured at/after it. A window with no
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
            if drawer.filedAt < splitAt {
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
        let p = vocabulary.map { Float((before[$0] ?? 0) / Double(beforeCount)) }
        let q = vocabulary.map { Float((after[$0] ?? 0) / Double(afterCount)) }

        return DriftOutput(
            drift: NeuronKit.drift(from: p, to: q),
            beforeCount: beforeCount, afterCount: afterCount)
    }
}
