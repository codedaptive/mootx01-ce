import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateTypes

/// Privacy-preserving overlap of two estates. `overlap` in `[0, 1]`:
/// 1 = convergent (organized into the same fingerprint space), → 0 =
/// divergent.
public struct MindOverlap: Sendable, Equatable {
    public let overlap: Double
    public let aCount: Int
    public let bCount: Int
    public init(overlap: Double, aCount: Int, bCount: Int) {
        self.overlap = overlap
        self.aCount = aCount
        self.bCount = bCount
    }
}

/// MindOverlapLens — the conscious "where two minds converge vs
/// diverge" recipe (Lens 9, Federated), privacy-preserving. Each
/// estate's drawers are fingerprinted under a SHARED hyperplane family
/// (so the spaces are comparable) and reduced to ONE
/// differentially-private aggregate (NeuronKit `dpSummary`); the two
/// aggregates are compared (`summaryOverlap`). The comparison touches
/// only the DP summaries — never either estate's individual memories.
/// "The moat": overlap computed without either side reading the other's
/// content.
///
/// The recipe entry point is `MindOverlapLens` (the result type
/// `MindOverlap` is the bare value type; the recipe namespace is
/// suffixed to avoid shadowing it, per the lens naming convention).
/// This is the REAL MindOverlap, distinct from `EstateDivergenceLens`
/// (which reads both estates' room distributions directly).
///
/// The shared family + shared DP seed are derived deterministically
/// from both estate UUIDs (the role the pairing handshake plays — a
/// shared nonce so both sides reduce into comparable, comparably-noised
/// spaces). The full federation transport (PairingHandshake exchange
/// across a real boundary) is the wiring above this; the
/// privacy-preserving COMPUTATION is here. Read-only (B-6, I-6). Swift
/// version of `run_mind_overlap`.
public enum MindOverlapLens {

    /// Default differential-privacy budget for the aggregate. epsilon
    /// high enough that the aggregate is informative on modest estates;
    /// delta/k per the DP reduction's contract.
    private static let epsilon = 8.0
    private static let delta = 1e-6
    /// k-anonymity > 1 so only bits SHARED by several memories survive
    /// the reduction — the summary becomes the estate's dominant
    /// structure, not a near-all-ones saturation (k = 1 keeps any bit
    /// any single drawer sets, which saturates and makes every estate
    /// look identical).
    private static let kAnonymity = 3

    /// Compute the privacy-preserving overlap between estate `handleA`
    /// and estate `handleB`, recalling each with `frame`. Reads each
    /// estate independently, reduces each to a DP summary under a shared
    /// family + seed, and compares only the summaries. Either estate
    /// empty ⇒ overlap 0. Read-only; a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handleA: EstateHandle,
        handleB: EstateHandle,
        frame: LocusKit.RecallFrame
    ) async throws -> MindOverlap {
        // Shared family key + DP seed from both estate UUIDs
        // (symmetric), so both sides fingerprint into the same space and
        // add comparable DP noise.
        let estateA = try await kit.estate(for: handleA)
        let estateB = try await kit.estate(for: handleB)
        let uuidA = await estateA.estateUUID.uuidString
        let uuidB = await estateB.estateUUID.uuidString
        let sharedKey = uuidA <= uuidB ? "\(uuidA)|\(uuidB)" : "\(uuidB)|\(uuidA)"
        let seed = FNV.hash64(sharedKey)
        let families = EstateFingerprintFamilies(estateUUID: sharedKey)

        func summarize(_ handle: EstateHandle) async throws -> (Fingerprint256, Int) {
            let drawers = try await kit.recall(handle, frame)
            let fingerprints = drawers.map { families.fingerprint(of: $0) }
            let summary = NeuronKit.dpSummary(
                fingerprints: fingerprints, epsilon: epsilon, delta: delta,
                kAnonymity: kAnonymity, seed: seed)
            return (summary, drawers.count)
        }

        let (summaryA, aCount) = try await summarize(handleA)
        let (summaryB, bCount) = try await summarize(handleB)

        guard aCount > 0, bCount > 0 else {
            return MindOverlap(overlap: 0, aCount: aCount, bCount: bCount)
        }

        return MindOverlap(
            overlap: NeuronKit.summaryOverlap(summaryA, summaryB),
            aCount: aCount, bCount: bCount)
    }
}
