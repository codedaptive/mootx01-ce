import Foundation

/// T-matrix hourly population signal — architecture spec §11.2, row 7.
///
/// Runs the TemporalCausalityFold pass on each fire and surfaces the
/// result as a diagnostic. The T-population fold processes audit entries
/// since the last watermark (MatrixTier.temporalWatermarkHLC) so each
/// hourly run is incremental rather than a full rebuild.
///
/// Cadence: hourly (3 600 seconds), per design-council 2026-06-04
/// decision superseding the cookbook §6.4 weekly cadence.
/// See hourly temporal-matrix scheduling.
///
/// Usage pattern (mirrors DreamingSignal):
///
///     let spec = TemporalCausalitySignal.spec { now in
///         // Caller owns the MatrixTier and audit log; it runs the
///         // fold, applies deltas, and persists the updated tier.
///         try await myEstateController.runTemporalFold(now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// The `foldCycle` closure does the actual fold work. The signal is
/// the scheduler-side trigger; the closure captures whatever estate
/// context it needs. An error thrown from the closure is caught and
/// surfaced as a `.diagnostic` emission — the scheduler's drain loop
/// continues unaffected.
///
/// For registration without a live fold (e.g., test scaffolds), use
/// `defaultSpec()`, which fires a diagnostic-only no-op.
public enum TemporalCausalitySignal {

    /// Hourly cadence in seconds — design-council 2026-06-04 decision.
    /// Supersedes the weekly cadence in cookbook §6.4.
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames`.
    public static let signalName = "temporal-causality-fold"

    /// Build a signal spec that invokes the T-population fold on each fire.
    ///
    /// The `foldCycle` closure is called with the scheduler's `now` and
    /// should run the temporal causality fold, apply deltas to the registered
    /// MatrixTier, and advance temporalWatermarkHLC. An empty successful
    /// return is correct when the estate has no audit entries newer than the
    /// last watermark. On error the throw is caught and surfaced as a
    /// `.diagnostic` emission.
    ///
    /// - Parameter foldCycle: async closure that executes the T-population
    ///   pass. Captures the estate's MatrixTier and UnifiedAuditLog via its
    ///   surrounding context. Called with `now` (deterministic clock) as the
    ///   single argument. Throws on fold or persistence failures.
    public static func spec(
        foldCycle: @escaping @Sendable (Date) async throws -> Void
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    try await foldCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "temporal-causality-fold.complete",
                        detail: "T-population fold completed at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface fold errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "temporal-causality-fold.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live fold cycle is available.
    ///
    /// The registered signal fires at the hourly cadence and emits a
    /// single diagnostic confirming the fire. No fold work is performed.
    /// This is the correct spec for `registerDefaultStandingSignals`,
    /// which cannot supply a live fold closure without knowing the
    /// caller's estate context.
    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // No-op fold: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                return [.diagnostic(DiagnosticReport(
                    title: "temporal-causality-fold.fired",
                    detail: "T-fold signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
