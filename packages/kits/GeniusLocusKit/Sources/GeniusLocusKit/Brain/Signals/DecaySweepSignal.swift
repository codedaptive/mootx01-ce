import Foundation
import LocusKit

/// Decay-sweep signal — architecture spec §11.2 (maintenance daemon
/// emissions, "decay candidates") and §6.8 / cookbook §6.8 (matrix
/// decay).
///
/// Decay is broken out as its own standing signal even though the
/// maintenance daemon also handles decay candidates because the two
/// have different cadences and different output classes:
///
/// - Maintenance runs hourly and emits forbidden-combination
///   discipline proposals plus a mixed decay/tombstone candidate
///   list.
/// - Decay-sweep runs daily (cookbook §15.2 "Decay" entry, ~10 ms
///   compute) and emits exclusively `propose(mutate_candidate)` for
///   rows whose operational bitmap's `active → decayed` transition
///   window has matured.
///
/// Routing: every candidate is routed through `propose` per
/// architecture spec §11.1 ("mutate-candidate routed through `propose`
/// for confirmation"). The signal does not mutate the row's bitmap
/// directly.
public enum DecaySweepSignal {

    /// Default cadence in seconds (86 400 = 1 day). Cookbook §15.2.
    public static let defaultCadenceSeconds: TimeInterval = 86_400

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "decay-sweep"

    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Decay candidate — `mutateCandidate` with kind
                // `.supersede`, routed through `propose`. The scheduler
                // rewrites the emission into a ProposalFrame with
                // kind="mutate_candidate" before dispatch (see
                // StandingSignalScheduler.applyEmission).
                let candidate = SignalEmission.mutateCandidate(
                    rowID: "decay/aged-candidate",
                    kind: .supersede)
                let diagnostic = DiagnosticReport(
                    title: "decay_sweep.pass.summary",
                    detail:
                        "daily decay pass observed 1 aged candidate; signal=\(context.signalID.rawValue)",
                    observedAt: context.now)
                return [
                    candidate,
                    .diagnostic(diagnostic),
                ]
            })
    }
}
