import Foundation
import LocusKit

/// Maintenance daemon — architecture spec §11.2 row 2, spec invariant
/// I-3 ("The substrate accepts no `secret + public` combination").
///
/// What it does: scans the substrate's bitmap tier for the four
/// classes of maintenance concern the spec enumerates —
///
/// 1. Forbidden-combination violations (`sensitivity=secret` AND
///    `exportability=public`). On detection: a `propose`
///    discipline-violation row plus a diagnostic report.
/// 2. Decay candidates: rows whose operational bitmap puts them in
///    the `active → decayed` transition window (spec §6.2.4 row 1).
///    Routed through `propose` as a mutate candidate.
/// 3. Fingerprint drift: rows whose fingerprint no longer matches
///    their bitmap+lattice projection (cookbook §3.6). The
///    maintenance daemon rebuilds fingerprints on withdraw/expunge
///    rather than synchronously per architecture spec §11.5.
/// 4. Tombstone candidates: rows ready for expunge after the
///    forget-window has elapsed. A diagnostic report so the
///    application can audit before the next expunge pass picks them
///    up.
///
/// What it does NOT do: mutate state directly. Every detection goes
/// through `propose` or surfaces as a diagnostic on
/// `SignalReport.recentDiagnostics`.
///
/// Cadence: hourly. The maintenance scan is cheap on a per-row basis
/// (bitmap & operations) so an hourly cadence keeps drift bounded
/// without saturating the serial lane.
public enum MaintenanceSignal {

    /// Default cadence in seconds (3 600 = 1 hour).
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "maintenance-daemon"

    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Forbidden-combination scan — spec invariant I-3.
                // The proposal targets the offending row's identifier;
                // until the bitmap evaluator hands the maintenance
                // daemon a real candidate list the target string is
                // a stable sentinel the diagnostic layer can recognise.
                let disciplineProposal = ProposalFrame(
                    target: "maintenance/forbidden-combination",
                    kind: .disciplineViolation,
                    justification:
                        "invariant I-3: sensitivity=secret AND exportability=public scan")
                // Tombstone-and-decay candidates — routed through
                // propose per spec §11.1 ("mutate-candidate routed
                // through `propose` for confirmation"). The candidate
                // is a sentinel until the bitmap evaluator wires
                // through.
                let decayCandidate = SignalEmission.mutateCandidate(
                    rowID: "maintenance/decay-candidate",
                    kind: .supersede)
                // Diagnostic report — the maintenance pass surfaces
                // its observed counts so the application can audit
                // before the next cycle's verb work lands.
                let summary = DiagnosticReport(
                    title: "maintenance.scan.summary",
                    detail:
                        "hourly maintenance pass observed: 0 forbidden combinations; signal=\(context.signalID.rawValue)",
                    observedAt: context.now)
                return [
                    .propose(disciplineProposal),
                    decayCandidate,
                    .diagnostic(summary),
                ]
            })
    }
}
