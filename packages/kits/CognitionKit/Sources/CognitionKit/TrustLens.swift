import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Provenance-weighted grounding output: the synthesized context, the
/// drawer ids in trust order (most authoritative first), how many are
/// high-trust, and optionally each drawer's confidence mapped through a
/// calibration curve (v1.1.0 extension — nil when no model id is supplied
/// or when the estate has no calibration history for the requested model).
public struct TrustGroundedOutput: Sendable {
    /// The synthesized, trust-ordered context document. Never persisted
    /// (NeuronKit C-9) — handed to a foundation model.
    public let context: ContextDocument
    /// Recalled drawer ids, most-trusted first.
    public let rankedIDs: [String]
    /// Count of high-trust rows (canonical or user source type).
    public let highTrustCount: Int
    /// Per-drawer calibrated confidence values in trust order, or nil when
    /// no `modelID` was supplied to `run` or when the estate holds no
    /// calibration curve for the requested model.
    public let calibratedConfidences: [CalibratedValue]?

    public init(context: ContextDocument, rankedIDs: [String], highTrustCount: Int,
                calibratedConfidences: [CalibratedValue]? = nil) {
        self.context = context
        self.rankedIDs = rankedIDs
        self.highTrustCount = highTrustCount
        self.calibratedConfidences = calibratedConfidences
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

    /// Recall via `frame`, rank by provenance trust, synthesize the
    /// trust-ordered set, and (v1.1.0) optionally map each drawer's
    /// confidence through a calibration curve for the given model.
    ///
    /// Read-only; a recall failure propagates.
    ///
    /// - Parameters:
    ///   - kit: Open GeniusLocusKit instance.
    ///   - handle: Open estate handle.
    ///   - frame: Recall frame controlling which drawers are fetched.
    ///   - modelID: Stable model identifier used to look up the calibration
    ///     curve (e.g. `"anthropic.claude-opus-4-8"`). When empty (the default)
    ///     or when the estate holds no curve for the model, the output's
    ///     `calibratedConfidences` field is nil and the recipe degrades
    ///     gracefully to the v1.0 behaviour.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        modelID: String = ""
    ) async throws -> TrustGroundedOutput {
        // B-5: capability gate before any substrate touch.
        try verifyCapabilities(required: [.synthesize])

        // Override hydration to .full: ContextSynthesizer extracts patterns
        // and themes from drawer content bodies, which are always "" under
        // .structured recall (spec § 7.3 — blob loading is skipped unless
        // the filter chain has a content predicate or hydration is .full).
        // Synthesizing over structured rows would silently produce an
        // empty-pattern context document — same failure class as the
        // Contradiction recipe (H-BROKEN content-stripping family).
        // The rest of the frame (filter chain, limit, ordering, asOf) is
        // preserved exactly as supplied; only hydrationLevel is overridden.
        var fullFrame = frame
        fullFrame.hydrationLevel = .full
        let drawers = try await kit.recall(handle, fullFrame)

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

        // v1.1.0 extension: map each drawer's confidence through the
        // calibration curve for `modelID`. `Confidence.rawValue` spans
        // {0,16,32,48,56}; dividing by 56 (the maximum) normalises to [0,1]
        // for the 20-bucket MatrixCalibrationCurve. Nil when modelID is
        // empty or when the estate has no history for the model.
        var calibratedConfidences: [CalibratedValue]? = nil
        if !modelID.isEmpty,
           let curve = try await kit.glkCalibrationCurve(for: handle, modelID: modelID) {
            // Maximum raw value for Confidence is 56 (verified=56).
            let claimed = ranked.map { Float($0.confidence.rawValue) / 56.0 }
            calibratedConfidences = NeuronKit.calibrate(curve: curve, claimed: claimed)
        }

        return TrustGroundedOutput(
            context: context, rankedIDs: rankedIDs, highTrustCount: highTrustCount,
            calibratedConfidences: calibratedConfidences)
    }
}
