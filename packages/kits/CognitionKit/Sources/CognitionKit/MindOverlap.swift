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
    /// Whether each estate met the k-anonymity floor (≥ k recalled drawers).
    /// Exact per-estate drawer counts are deliberately NOT exposed — only
    /// this coarse sufficiency signal — so no per-estate structure crosses
    /// the recipe boundary alongside the DP-noised `overlap`. A `false` on
    /// either side forces `overlap` to 0 (insufficient data), which is what
    /// distinguishes "insufficient data" from a genuine 0 (divergent).
    public let aSufficient: Bool
    public let bSufficient: Bool
    public init(overlap: Double, aSufficient: Bool, bSufficient: Bool) {
        self.overlap = overlap
        self.aSufficient = aSufficient
        self.bSufficient = bSufficient
    }
}

/// MindOverlapLens — the conscious "where two minds converge vs
/// diverge" recipe (Lens 9, Federated), privacy-preserving. Each
/// estate's drawers are recalled and fingerprinted locally under a
/// SHARED hyperplane family (so the spaces are comparable), then reduced
/// to ONE differentially-private aggregate (NeuronKit `dpSummary`). The
/// final overlap comparison uses only the two DP summaries (`summaryOverlap`),
/// never the individual memory content. The local fingerprinting step
/// reads each estate's drawer set; no individual content crosses the
/// estate boundary.
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

        // k-sufficiency is computed from the raw recalled counts but the raw
        // counts themselves are NOT returned — only whether each side cleared
        // the k-anonymity floor. This keeps exact per-estate drawer counts from
        // leaving the recipe (the summary already crosses the boundary DP-noised;
        // the counts must not undo that).
        let aSufficient = aCount >= kAnonymity
        let bSufficient = bCount >= kAnonymity

        // Below k-anonymity, no fingerprint bit can reach the DP-OR threshold,
        // so both summaries collapse to identical all-zero/noise-only aggregates
        // and summaryOverlap returns a false 1.0 for unrelated tiny estates.
        // Treat < k recalled drawers as insufficient data ⇒ 0 overlap (this also
        // subsumes the empty-estate case, since 0 < kAnonymity).
        guard aSufficient, bSufficient else {
            return MindOverlap(overlap: 0, aSufficient: aSufficient, bSufficient: bSufficient)
        }

        return MindOverlap(
            overlap: NeuronKit.summaryOverlap(summaryA, summaryB),
            aSufficient: aSufficient, bSufficient: bSufficient)
    }
}
