import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Anticipate — the conscious "what tends to work" recipe (Lens 8,
/// Prediction). Learn, from the estate's own memories, which capture
/// actions reach a target outcome: each drawer is an (action = capture
/// channel, outcome = content kind, success = user-confirmed)
/// observation fed to NeuronKit `anticipate` (SubstrateML's
/// action-outcome matrix). "To reach Y, you tend to do X."
///
/// This is the REAL action-outcome lens — the learned T-matrix — not
/// the explicit-tunnel successor signal in `TunnelSuccessor`. Read-only;
/// no capability gate (it sequences a recall + the action-outcome
/// model, neither a declared `NeuronKitCapability`).
///
/// The SUCCESS signal is user-confirmation, a live event source: the
/// `confirm` verb transitions a row to user-confirmed in both versions.
/// Differentiation needs to see BOTH confirmed and unconfirmed
/// observations of the same action→outcome, but the recall confirmation
/// axis is single-class (a frame returns either confirmed or
/// unconfirmed rows, never both). So this recipe OWNS that axis: it
/// unions a confirmed recall (success = true) and an unconfirmed recall
/// (success = false), both scoped by the caller's `frame` with any
/// confirmation-level filter stripped.
///
/// Swift version of `run_anticipate`.
public enum Anticipate {

    /// Drop the confirmation-level filters from a chain — the recipe
    /// re-adds exactly one per recall, so a caller-supplied confirmation
    /// filter must not survive to conflict. Rust mirrors this as
    /// `AutomatedConfirmedOnly` (renamed from `ModelConfirmedOnly` in F13
    /// parity pass; see `anticipate_recipe.rs`).
    private static func withoutConfirmationLevel(_ chain: [Filter]) -> [Filter] {
        chain.filter { filter in
            switch filter {
            case .userConfirmed, .automatedConfirmedOnly, .unconfirmed: return false
            default: return true
            }
        }
    }

    /// Learn from the recalled memories which capture channels (actions)
    /// reach `targetOutcome` (a content-kind raw value), top `k` with at
    /// least `minObservations` seen. Unions a confirmed recall
    /// (successes) and an unconfirmed recall (non-successes) under the
    /// caller's scope so the learned success rate differentiates.
    /// Read-only; a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        targetOutcome: UInt8,
        k: Int,
        minObservations: UInt32
    ) async throws -> [ActionPrediction] {
        let base = withoutConfirmationLevel(frame.filterChain)

        var confirmedFrame = frame
        confirmedFrame.filterChain = base + [.userConfirmed]
        var unconfirmedFrame = frame
        unconfirmedFrame.filterChain = base + [.unconfirmed]

        let confirmed = try await kit.recall(handle, confirmedFrame)
        let unconfirmed = try await kit.recall(handle, unconfirmedFrame)

        // success = whether the row is user-confirmed; the confirmed
        // recall yields the true observations, the unconfirmed recall
        // the false ones. The two sets are disjoint (confirmation ≥ 1
        // vs == 0), so no row is double-counted.
        let observations = (confirmed + unconfirmed).map { drawer in
            ActionObservation(
                action: UInt8(drawer.captureChannel.rawValue),
                outcome: UInt8(drawer.contentKind.rawValue),
                success: drawer.isUserConfirmed)
        }

        return NeuronKit.anticipate(
            observations: observations, targetOutcome: targetOutcome,
            k: k, minObservations: minObservations)
    }
}
