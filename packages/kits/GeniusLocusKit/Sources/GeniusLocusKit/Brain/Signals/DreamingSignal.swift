import Foundation
import LocusKit

/// Dreaming daemon — architecture spec §11.2 row 1, cookbook §15
/// (the dreaming-daemon update rules).
///
/// What it does: reads the substrate's blob/JSON tier and association
/// graph and emits:
///
/// - `propose` for mining-pattern matches and novel structural
///   alignments uncovered by cold-path rules 6–13 (weekly NMF, weekly
///   T-matrix increment, daily eigenvalue centrality, daily community
///   detection).
/// - `diagnostic` on daemon cycle error (surfaced in the signal's
///   `recentDiagnostics` without silencing the signal).
///
/// What it does NOT do: write to bitmap state directly. Every emission
/// goes through the GLK-02 propose/associate verb boundary. The daemon
/// cycle is supplied by the caller through `spec(daemonCycle:)` — the
/// caller constructs a `DreamingDaemon` (NeuronKit) with production
/// adapters (`EstateDreamingReader` + `EstateDreamingSink`) and wraps
/// `daemon.triggerDreamingCycle(now:).proposalsEmitted` in the closure.
/// GeniusLocusKit cannot import NeuronKit (circular package dependency),
/// so the closure is the architectural bridge between the two packages.
///
/// Cadence: weekly. Cookbook §15.2 schedules the cold-path NMF and
/// T-matrix work at a weekly cadence; that is the slowest of the
/// dreaming-daemon rules and the one that bounds the signal's
/// emission tempo.
public enum DreamingSignal {

    /// Default cadence in seconds (604 800 = 7 days). Cookbook §15.2.
    public static let defaultCadenceSeconds: TimeInterval = 604_800

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "dreaming-daemon"

    /// Build a signal spec that invokes the dreaming daemon on each fire.
    ///
    /// The `daemonCycle` closure is called with the scheduler's `now` and
    /// returns the proposals the daemon emitted. An empty array is correct
    /// when the estate has no co-occurrence candidates to mine. On error, the
    /// closure's throw is caught and surfaced as a `.diagnostic` emission so
    /// the scheduler's signal log records the failure without silencing the
    /// signal.
    ///
    /// **Usage:** construct a `DreamingDaemon` (NeuronKit) once with production
    /// adapters and capture it in the closure:
    ///
    ///     let reader = EstateDreamingReader(handle: handle, kit: kit)
    ///     let sink   = EstateDreamingSink(handle: handle, kit: kit)
    ///     let store  = InMemoryDreamingPolicyStore()
    ///     let daemon = NeuronKit.dreamingDaemon(reader: reader, sink: sink, policyStore: store)
    ///     let spec   = DreamingSignal.spec { now in
    ///         try await daemon.triggerDreamingCycle(now: now).proposalsEmitted
    ///     }
    ///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
    ///
    /// The daemon is an actor; re-entry is prevented by actor isolation and the
    /// scheduler's `.single` concurrency policy, which together guarantee at most
    /// one cycle runs at a time per estate.
    public static func spec(
        daemonCycle: @escaping @Sendable (Date) async throws -> [ProposeFrame]
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let proposals = try await daemonCycle(context.now)
                    // Map each ProposeFrame (substrate verb frame) to the Brain
                    // layer's ProposalFrame (SignalEmission.propose). Both types
                    // are in GeniusLocusKit; the scheduler converts ProposalFrame
                    // back to ProposeFrame before dispatching to the verb surface.
                    return proposals.map { frame in
                        SignalEmission.propose(ProposalFrame(
                            target: frame.target,
                            kind: frame.kind,
                            justification: frame.justification))
                    }
                } catch {
                    // Surface daemon errors as a diagnostic rather than crashing
                    // the scheduler's drain loop. The error appears in the signal's
                    // recentDiagnostics so the application can observe cycle failures.
                    return [.diagnostic(DiagnosticReport(
                        title: "dreaming-daemon.cycle.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
