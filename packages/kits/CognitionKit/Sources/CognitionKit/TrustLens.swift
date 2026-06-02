import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Provenance-weighted grounding output: the synthesized context, the
/// drawer ids in trust order (most authoritative first), and how many
/// are high-trust.
public struct TrustGroundedOutput: Sendable {
    /// The synthesized, trust-ordered context document. Never persisted
    /// (NeuronKit C-9) — handed to a foundation model.
    public let context: ContextDocument
    /// Recalled drawer ids, most-trusted first.
    public let rankedIDs: [String]
    /// Count of high-trust rows (canonical or user source type).
    public let highTrustCount: Int

    public init(context: ContextDocument, rankedIDs: [String], highTrustCount: Int) {
        self.context = context
        self.rankedIDs = rankedIDs
        self.highTrustCount = highTrustCount
    }
}

/// TrustLens — provenance-weighted grounding (Lens 6, Grounding & Trust).
/// Recall a set of drawers, rank them by how authoritative their
/// provenance is (source-type trust: canonical/user above derived,
/// confidence as tiebreak), and synthesize the trust-ordered set so the
/// most trustworthy memories ground the context first. The estate
/// reasons about which of its own memories to lean on.
///
/// Layer discipline (SPEC § 5, B-1/B-2): pure sequencing — recall via
/// GLK + the drawer provenance accessors + NeuronKit `synthesize`. Zero
/// new substrate, zero new NeuronKit surface. Read-only (B-6, I-6).
///
/// Trust signal: `sourceType` is used (it is settable at capture and
/// varies), not `confirmation` — the user-confirmed tier can only be
/// reached through the confirm/mutate verb, which is Brain-layer until
/// that layer ships. When confirmation goes live, a user-confirmed
/// boost folds into `trustRank` the same way.
///
/// Swift version of `run_trust_grounded_synthesis`.
public enum TrustLens {

    /// Authority score for a source type (higher = more trustworthy).
    /// Canonical and user outrank derived/inferred provenance. A v1
    /// ordering; the precise weights are a deliberate, documented
    /// choice, not a substrate constant.
    private static func trustRank(_ sourceType: SourceType) -> Int {
        switch sourceType {
        case .canonical: return 5
        case .user: return 4
        case .imported: return 3
        case .observed: return 2
        case .derived: return 1
        default: return 0
        }
    }

    /// `true` for the high-trust tier (canonical or user).
    private static func isHighTrust(_ sourceType: SourceType) -> Bool {
        trustRank(sourceType) >= 4
    }

    /// Recall via `frame`, rank by provenance trust, and synthesize the
    /// trust-ordered set. Read-only; a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame
    ) async throws -> TrustGroundedOutput {
        // B-5: capability gate before any substrate touch.
        try verifyCapabilities(required: [.synthesize])

        let drawers = try await kit.recall(handle, frame)

        // Trust order: source-type authority desc, confidence desc,
        // id asc (deterministic).
        let ranked = drawers.sorted { a, b in
            let trustA = trustRank(a.sourceType), trustB = trustRank(b.sourceType)
            if trustA != trustB { return trustA > trustB }
            if a.confidence != b.confidence {
                return a.confidence.rawValue > b.confidence.rawValue
            }
            return a.id < b.id
        }

        let highTrustCount = ranked.count { isHighTrust($0.sourceType) }
        let rankedIDs = ranked.map(\.id)

        // Synthesize over the trust-ordered set, presented as one
        // terminal page. Read-only (NeuronKit C-9): no estate write.
        let page = RecallStream.Page(rows: ranked, pageIndex: 0, isLast: true)
        let context = try await ContextSynthesizer.synthesize(from: page, estate: handle)

        return TrustGroundedOutput(
            context: context, rankedIDs: rankedIDs, highTrustCount: highTrustCount)
    }
}
