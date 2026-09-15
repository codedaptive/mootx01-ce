import Foundation
import LocusKit

/// byReference validation standing signal — architecture spec §11.2 row 6.
///
/// Fires the NeuronKit maintenance engine's `byReference` category on each tick:
/// `MaintenanceDaemon.triggerMaintenanceCycle(now:categories: [.byReference])`
/// scans that category only, proposes its candidates through the engine's
/// own sink (routed through `propose`), and the signal surfaces the
/// `byReferenceDrifts` count as a diagnostic. The engine's audit-chain monitor
/// and QID-pending retry run on the same call.
///
/// Mirrors `AnomalySweepSignal` in structure: interval cadence, `.single`
/// concurrency, diagnostic-only emission, injected closure for the live
/// cycle. Registered by `registerDefaultStandingSignals` only when the host
/// passes a live cycle — the host reads the estate's `.maintenance`
/// preference and passes nil when it is `.off`, so the governor's tick
/// never pumps the engine on this category.
public enum ByReferenceValiditySignal {

    /// Default cadence in seconds (604 800 = 7 days; architecture spec §10 row 7).
    public static let defaultCadenceSeconds: TimeInterval = 604_800

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "by-reference-validity"

    /// Build a signal spec that runs the engine's `byReference` category on each fire.
    ///
    /// - Parameter byReferenceCycle: async closure called with the scheduler's `now`;
    ///   runs the scoped maintenance cycle and returns `byReferenceDrifts`.
    ///   A throw is caught and surfaced as a diagnostic so the scheduler's
    ///   drain loop is not interrupted.
    public static func spec(
        byReferenceCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await byReferenceCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "by-reference-validity.complete",
                        detail: "\(count) drift(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface cycle errors as diagnostics so the scheduler's
                    // drain loop is not interrupted; the failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "by-reference-validity.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
