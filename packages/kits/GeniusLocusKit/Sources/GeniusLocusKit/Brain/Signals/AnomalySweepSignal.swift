import Foundation

/// Anomaly-flag sweep standing signal — architecture spec §11.18,
/// signal 12.
///
/// Fires the room-cohesion anomaly-flag sweep on each hourly tick and
/// surfaces the changed-drawer count as a diagnostic.
/// `anomalyFlagSweep(handle:threshold:now:)` sets/clears bit 26
/// (`isAnomalous`) on each drawer based on char-3-shingle Jaccard
/// z-scores against room peers (SubstrateML `ShingleSimilarity` +
/// `AnomalyDetection`). Rooms below `anomalySweepMinRoomSize` (3) have
/// bit 26 cleared on all members.
///
/// Mirrors `TemporalCausalitySignal` in structure: hourly cadence,
/// `.single` concurrency, diagnostic-only emission, injected closure for
/// the live cycle. Registered by `registerDefaultStandingSignals`.
///
/// Usage pattern (mirrors TemporalCausalitySignal):
///
///     let spec = AnomalySweepSignal.spec { now in
///         return try await kit.anomalyFlagSweep(handle: handle, now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// For registration without a live sweep (e.g., test scaffolds), use
/// `defaultSpec()`, which fires a diagnostic-only no-op.
public enum AnomalySweepSignal {

    /// Hourly cadence in seconds — same family as the temporal-causality
    /// fold and training-daemon tick (architecture spec §11.2).
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames` (registered by
    /// `registerDefaultStandingSignals`).
    public static let signalName = "anomaly-flag-sweep"

    /// Build a signal spec that invokes the room-cohesion anomaly sweep
    /// on each fire.
    ///
    /// The `anomalyCycle` closure is called with the scheduler's `now` and
    /// should run `GeniusLocusKit.anomalyFlagSweep`, returning the count
    /// of drawers whose bit 26 changed state. An empty successful return
    /// (0) is correct when no bits changed. On error the throw is caught
    /// and surfaced as a `.diagnostic` emission so the scheduler's drain
    /// loop is not interrupted.
    ///
    /// - Parameter anomalyCycle: async closure that executes the sweep.
    ///   Captures the estate context it needs. Called with `now`
    ///   (deterministic clock) as the single argument. Returns the count
    ///   of drawers whose `isAnomalous` bit changed. Throws on sweep or
    ///   persistence failures.
    public static func spec(
        anomalyCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await anomalyCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "anomaly-flag-sweep.complete",
                        detail: "updated \(count) drawer(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "anomaly-flag-sweep.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live anomaly-sweep cycle is available.
    ///
    /// The registered signal fires at the hourly cadence and emits a
    /// single diagnostic confirming the fire. No sweep work is performed.
    /// This is the correct spec for `registerDefaultStandingSignals`,
    /// which cannot supply a live closure without knowing the caller's
    /// estate context.
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
                    title: "anomaly-flag-sweep.fired",
                    detail: "sweep signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
