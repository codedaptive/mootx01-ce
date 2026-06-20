import Foundation

/// Distillation sweep standing signal — architecture spec §11.2, signal 8.
///
/// Fires the per-item distillation sweep on each hourly tick and surfaces
/// the factoid count as a diagnostic. Mirrors TemporalCausalitySignal
/// exactly in structure: hourly cadence, .single concurrency, diagnostic
/// emission, injected closure for the live cycle.
///
/// Cadence: hourly (3 600 seconds). Registered by Dg4
/// (DefaultStandingSignals) after this signal file lands.
///
/// Usage pattern (mirrors TemporalCausalitySignal):
///
///     let spec = DistillationSignal.spec { now in
///         // Caller owns the estate and distillation pipeline;
///         // it runs the per-item sweep and returns the factoid count.
///         return try await kit.distillItemsSweep(handle: handle,
///             distillFn: distillFn, now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// The `distillationCycle` closure does the actual sweep work. The signal is
/// the scheduler-side trigger; the closure captures whatever estate context
/// it needs. An error thrown from the closure is caught and surfaced as a
/// `.diagnostic` emission — the scheduler's drain loop continues unaffected.
///
/// For registration without a live sweep (e.g., test scaffolds), use
/// `defaultSpec()`, which fires a diagnostic-only no-op.
public enum DistillationSignal {

    /// Hourly cadence in seconds — architecture spec §11.2, signal 8.
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames` (registered by Dg4).
    public static let signalName = "distillation-sweep"

    /// Build a signal spec that invokes the per-item distillation pipeline on each fire.
    ///
    /// The `distillationCycle` closure is called with the scheduler's `now`
    /// and should run the per-item distillation sweep, returning the count of
    /// factoids produced. An empty successful return (0) is correct when no
    /// items were ready to distill. On error the throw is caught and surfaced
    /// as a `.diagnostic` emission.
    ///
    /// - Parameter distillationCycle: async closure that executes the
    ///   distillation sweep. Captures the estate's cluster store and
    ///   distillation pipeline via its surrounding context. Called with `now`
    ///   (deterministic clock) as the single argument. Returns the count of
    ///   factoids produced. Throws on sweep or persistence failures.
    public static func spec(
        distillationCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await distillationCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "distillation-sweep.complete",
                        detail: "produced \(count) factoid(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "distillation-sweep.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live distillation cycle is available.
    ///
    /// The registered signal fires at the hourly cadence and emits a
    /// single diagnostic confirming the fire. No distillation work is
    /// performed. This is the correct spec for `registerDefaultStandingSignals`,
    /// which cannot supply a live distillation closure without knowing the
    /// caller's estate context.
    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // No-op sweep: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                return [.diagnostic(DiagnosticReport(
                    title: "distillation-sweep.fired",
                    detail: "sweep signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
