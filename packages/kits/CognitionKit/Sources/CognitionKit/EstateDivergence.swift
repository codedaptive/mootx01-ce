import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// How two estates' mental models compare. Low `divergence` =
/// convergent.
public struct EstateDivergence: Sendable, Equatable {
    public let divergence: DriftScore
    public let aCount: Int
    public let bCount: Int
    public init(divergence: DriftScore, aCount: Int, bCount: Int) {
        self.divergence = divergence
        self.aCount = aCount
        self.bCount = bCount
    }
}

/// EstateDivergenceLens — compare two estates' room distributions by
/// Jensen-Shannon / KL divergence (NeuronKit `drift`): low = organized
/// alike, high = they diverge. The coordinator holds both estates, so
/// it's one recipe over two handles.
///
/// The recipe entry point is `EstateDivergenceLens` (the result type
/// `EstateDivergence` is the bare value type; the recipe namespace is
/// suffixed to avoid shadowing it, per the lens naming convention).
///
/// This is NOT MindOverlap (Lens 9). MindOverlap's defining property is
/// PRIVACY-PRESERVING federation — divergence computed WITHOUT either
/// side reading the other's content, via DP summaries. This recipe
/// reads BOTH estates' distributions directly — the non-private,
/// same-device divergence, useful in its own right but not the
/// federated lens. Named for what it actually does.
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall each
/// estate via GLK + NeuronKit drift. Read-only (B-6, I-6). Swift
/// version of `run_estate_divergence` (which takes a frame-builder
/// closure for Rust ownership reasons; `RecallFrame` is a Swift value
/// type, so one frame serves both recalls).
public enum EstateDivergenceLens {

    /// Room → drawer count over a recalled set.
    private static func roomCounts(_ drawers: [Drawer]) -> [String: Double] {
        drawers.reduce(into: [:]) { counts, drawer in
            counts[drawer.room, default: 0] += 1
        }
    }

    /// Divergence between estate `handleA` and estate `handleB` over
    /// their room distributions, recalling each with `frame`. Either
    /// estate empty ⇒ zero divergence (nothing to compare). Read-only;
    /// a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handleA: EstateHandle,
        handleB: EstateHandle,
        frame: LocusKit.RecallFrame
    ) async throws -> EstateDivergence {
        let drawersA = try await kit.recall(handleA, frame)
        let drawersB = try await kit.recall(handleB, frame)

        guard !drawersA.isEmpty, !drawersB.isEmpty else {
            return EstateDivergence(
                divergence: DriftScore(jensenShannon: 0, klDivergence: 0),
                aCount: drawersA.count, bCount: drawersB.count)
        }

        let roomsA = roomCounts(drawersA)
        let roomsB = roomCounts(drawersB)
        // Shared, aligned support across both estates (sorted ⇒
        // deterministic bin order).
        let vocabulary = Set(roomsA.keys).union(roomsB.keys).sorted()
        let p = vocabulary.map { Float((roomsA[$0] ?? 0) / Double(drawersA.count)) }
        let q = vocabulary.map { Float((roomsB[$0] ?? 0) / Double(drawersB.count)) }

        return EstateDivergence(
            divergence: NeuronKit.drift(from: p, to: q),
            aCount: drawersA.count, bCount: drawersB.count)
    }
}
