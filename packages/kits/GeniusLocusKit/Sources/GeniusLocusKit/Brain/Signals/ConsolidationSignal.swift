import Foundation

/// Consolidation sweep standing signal — Wave-2 D9: true consolidation runs
/// ONLY in dream/maintenance windows, never inline with capture. Mirrors
/// DistillationSignal exactly in structure: fixed cadence, .single
/// concurrency, diagnostic emission, injected closure for the live cycle.
///
/// Cadence: daily (86 400 seconds) — the THETA-window cadence class. Every
/// fire runs ONE bounded sweep (the D9 candidate cap inside
/// ConsolidationConfig bounds the work per window; the sweep resumes from
/// its cursor next fire, so a large aged estate consolidates across cycles
/// without ever starving the other dream-cycle work).
///
/// Usage pattern (mirrors DistillationSignal):
///
///     let spec = ConsolidationSignal.spec { now in
///         try await kit.consolidationSweepReport(
///             handle: handle, distillFn: distillFn, now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// The report's fold-in rejection counter is surfaced in the diagnostic so
/// the D10 drift policy (defrag trigger) can be evaluated from
/// recentDiagnostics without a separate metrics channel.
public enum ConsolidationSignal {

    /// Daily cadence in seconds — Wave-2 D9/D11 maintenance-window class.
    public static let defaultCadenceSeconds: TimeInterval = 86_400

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "consolidation-sweep"

    /// Build a signal spec that runs one bounded consolidation sweep per fire.
    ///
    /// - Parameter consolidationCycle: async closure executing the sweep with
    ///   the scheduler's `now`; returns the sweep report. Errors are caught
    ///   and surfaced as `.diagnostic` emissions — the scheduler's drain loop
    ///   continues unaffected.
    public static func spec(
        consolidationCycle: @escaping @Sendable (Date) async throws -> ConsolidationSweepReport
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let report = try await consolidationCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "consolidation-sweep.complete",
                        detail: "new=\(report.newVagueItems) foldIns=\(report.foldIns) "
                            + "foldInRejections=\(report.foldInRejections) "
                            + "at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    return [.diagnostic(DiagnosticReport(
                        title: "consolidation-sweep.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Diagnostic-only spec for registration contexts with no live cycle
    /// (mirrors DistillationSignal.defaultSpec — registerDefaultStandingSignals
    /// cannot supply estate context).
    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                return [.diagnostic(DiagnosticReport(
                    title: "consolidation-sweep.fired",
                    detail: "sweep signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
