import Foundation

/// Contradiction-sweep standing signal: the background half of the
/// tiered conflict-tunnel proposer.
///
/// Fires `proposeConflictTunnels(in:registry:modelID:probeLimit:lexicalTopK:now:)`
/// on each hourly tick — one typed rule sweep plus the shared lexical
/// pass — filing PROPOSED `contradicts` tunnels at every tier that
/// survives the decline matrix. The proposed count is surfaced as a
/// diagnostic.
///
/// Mirrors `AnomalySweepSignal` in structure: hourly cadence, `.single`
/// concurrency, diagnostic-only emission, injected closure for the live
/// cycle. `registerDefaultStandingSignals` registers it only when the
/// host supplies a live cycle; the estate's `.contradictionSweep`
/// preference decides that, so there is no diagnostic-only default spec.
///
/// Usage pattern:
///
///     let spec = ContradictionSweepSignal.spec { now in
///         try await kit.proposeConflictTunnels(in: handle, now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
public enum ContradictionSweepSignal {

    /// Hourly cadence in seconds — same family as the anomaly-flag sweep
    /// and the temporal-causality fold (architecture spec §11.2).
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.preferenceGatedStandingSignalNames`.
    public static let signalName = "contradiction-sweep"

    /// Build a signal spec that runs one conflict-tunnel proposal sweep
    /// on each fire.
    ///
    /// The `sweepCycle` closure is called with the scheduler's `now` and
    /// should run `GeniusLocusKit.proposeConflictTunnels`, returning its
    /// report. The sweep persists the proposed tunnels itself; the signal
    /// only records the counts. On error the throw is caught and surfaced
    /// as a `.diagnostic` emission so the scheduler's drain loop is not
    /// interrupted.
    ///
    /// - Parameter sweepCycle: async closure that executes the sweep.
    ///   Captures the estate context it needs. Called with `now`
    ///   (deterministic clock) as the single argument. Returns the
    ///   proposal report. Throws on sweep or persistence failures.
    public static func spec(
        sweepCycle: @escaping @Sendable (Date) async throws -> ConflictTunnelProposalReport
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let report = try await sweepCycle(context.now)
                    // Proposed = every tier's filings this pass; the
                    // per-tier split and the dedup suppressions ride along
                    // so recentDiagnostics shows where the proposals came from.
                    let proposed = report.proposedTunnelIDs.count
                        + report.proposedTier2IDs.count
                        + report.proposedTier3IDs.count
                    return [.diagnostic(DiagnosticReport(
                        title: "contradiction-sweep.complete",
                        detail: "proposed \(proposed) tunnel(s) "
                            + "(tier1=\(report.proposedTunnelIDs.count) "
                            + "tier2=\(report.proposedTier2IDs.count) "
                            + "tier3=\(report.proposedTier3IDs.count)) "
                            + "suppressed=\(report.suppressed) "
                            + "at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "contradiction-sweep.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
