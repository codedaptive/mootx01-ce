import Foundation

/// Training-daemon standing signal — architecture spec §11.2, signal 9.
///
/// Fires the training-daemon `runOnce` pass on each hourly tick and surfaces
/// the result as a diagnostic. Mirrors TemporalCausalitySignal in structure:
/// hourly cadence, .single concurrency, injected closure for the live pass,
/// diagnostic-only emission.
///
/// The training daemon runs the enrichment pipeline over the post-watermark
/// audit-log tail and folds transitions into the matrix tier. The daemon's
/// own threshold gate (per the training transition threshold)
/// decides whether to actually train on each invocation; the signal is the
/// scheduler-side trigger that invokes the daemon regardless — the gate
/// short-circuits below the threshold so the emit always returns exactly one
/// diagnostic.
///
/// Cadence: hourly (3 600 seconds), matching the temporal-causality-fold
/// signal at §11.2 to keep the daemon in sync with the matrix-population
/// rhythm.
///
/// Usage pattern:
///
///     // Caller owns the estate's audit log, matrix tier, and
///     // calibration registry; wraps `TrainingDaemon.runOnce` here.
///     let spec = TrainingSignal.spec { now in
///         return try await myEstateController.runTrainingDaemon(now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// The `trainingCycle` closure does the actual daemon work. The signal is
/// the scheduler-side trigger; the closure captures whatever estate context
/// it needs (audit log, matrix tier, calibration registry, daemon instance).
/// An error thrown from the closure is caught and surfaced as a
/// `.diagnostic` emission — the scheduler's drain loop continues unaffected.
///
/// There is no no-op variant: `registerDefaultStandingSignals` registers
/// this signal only when handed a live `trainingCycle`, which the host
/// passes only while the estate's `.adaptiveRecall` preference is not
/// `.off`.
public enum TrainingSignal {

    /// Hourly cadence in seconds — matches TemporalCausalitySignal at §11.2
    /// for matrix-population rhythm.
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames` (signal 9, brain-layer governor ownership).
    public static let signalName = "training-daemon"

    /// Build a signal spec that invokes the training daemon on each fire.
    ///
    /// The `trainingCycle` closure is called with the scheduler's `now` and
    /// should invoke `TrainingDaemon.runOnce` against the estate's current
    /// audit log, matrix tier, and calibration registry, then return a
    /// string summarizing the tick outcome for the diagnostic. An empty
    /// string is correct when the daemon was dormant (below threshold); the
    /// gate detail string is included in every case so the report is
    /// observable even on dormant ticks. On error the throw is caught and
    /// surfaced as a `.diagnostic` emission.
    ///
    /// The daemon's own threshold gate handles the dormant/active decision;
    /// the signal merely invokes `runOnce` unconditionally. Callers must
    /// ensure the daemon instance is serialized correctly — the signal fires
    /// inside the GLK actor's scheduler, so the closure should not re-enter
    /// the GLK actor.
    ///
    /// - Parameter trainingCycle: async closure that executes one daemon
    ///   pass. Captures the estate's `TrainingDaemon`, `UnifiedAuditLog`,
    ///   `MatrixTier`, and `MatrixCalibrationRegistry` via its surrounding
    ///   context. Called with `now` (deterministic clock) as the single
    ///   argument. Returns a detail string for the diagnostic emission.
    ///   Throws on daemon or persistence failures.
    public static func spec(
        trainingCycle: @escaping @Sendable (Date) async throws -> String
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let detail = try await trainingCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "training-daemon.tick",
                        detail: detail,
                        observedAt: context.now))]
                } catch {
                    // Surface daemon errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "training-daemon.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
