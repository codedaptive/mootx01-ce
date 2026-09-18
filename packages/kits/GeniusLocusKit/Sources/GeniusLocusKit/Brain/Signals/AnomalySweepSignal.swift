import Foundation

/// Anomaly-flag sweep standing signal — architecture spec §11.18,
/// signal 12.
///
/// Fires each hour; the live closure ENQUEUES the anomaly-sweep duty
/// (§ DUTY_LIFECYCLE) and the resident's duty worker scores, off the tick,
/// only the rooms touched since their last scoring. The scoring
/// (`AnomalyFlagSweep.swift`) sets/clears bit 26 (`isAnomalous`) on each
/// drawer from char-3-shingle Jaccard z-scores against room peers
/// (SubstrateML `ShingleSimilarity` + `AnomalyDetection`); rooms below
/// `anomalySweepMinRoomSize` (3) have bit 26 cleared on all members.
///
/// Mirrors `TemporalCausalitySignal` in structure: hourly cadence,
/// `.single` concurrency, diagnostic-only emission, injected closure for
/// the live cycle. Registered by `registerDefaultStandingSignals`.
///
/// Usage pattern (mirrors TemporalCausalitySignal):
///
///     let spec = AnomalySweepSignal.spec { now in
///         _ = try await kit.enqueueDuty(.anomalySweep, in: handle, now: now)
///         return 0
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

    /// Build a signal spec that runs `anomalyCycle` on each fire.
    ///
    /// The closure is called with the scheduler's `now`; the resident's
    /// closure enqueues the anomaly-sweep duty and returns 0, and a test
    /// closure may run the whole-estate sweep and return its changed count.
    /// The count is surfaced as a `.diagnostic` emission; on error the throw
    /// is caught and surfaced the same way so the scheduler's drain loop is
    /// not interrupted.
    ///
    /// - Parameter anomalyCycle: async closure called with `now`
    ///   (deterministic clock) as the single argument. Returns a count for
    ///   the diagnostic. Throws on failure.
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
