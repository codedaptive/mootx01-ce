import Foundation

/// Contradiction-scout signal — the background half of the contradiction
/// hunter. On each fire it runs one incremental
/// `GeniusLocusKit.huntContradictions` pass (kNN candidate mining +
/// SubstrateML `ConflictCue` screen) over recently filed drawers, and the
/// hunt itself persists any strong finding as a `contradicts` tunnel with
/// lifecycle `.proposed` / originClass `.derived` — reviewable via
/// `respondToTunnel` and surfaced by `moot_lens_contradiction`.
///
/// Wiring follows `DreamingSignal`: the hunt needs estate-specific
/// context (the kit actor, handle, VectorStore, model ID), so the caller
/// injects a closure and this spec stays generic. The default no-op
/// (zero counts) is appropriate for tests without a wired hunter.
///
/// **Single-write invariant:** the hunt pass captures proposed tunnels
/// directly through the estate verb surface. The scheduler MUST NOT
/// re-dispatch anything — the closure returns counts, and the signal
/// emits one diagnostic summarising the pass.
///
/// **Usage:**
///
///     let spec = ContradictionScoutSignal.spec { now in
///         let report = try await kit.huntContradictions(
///             in: handle, modelID: modelID,
///             filedAfter: now.addingTimeInterval(-ContradictionScoutSignal.defaultCadenceSeconds * 4),
///             now: now)
///         return (report.proposed.count, report.borderline.count)
///     }
///
/// Cadence: hourly. Content does not change on the five-minute tempo of
/// vector-proximity maintenance, and the pass re-examines a bounded
/// recent window, so an hourly fire keeps proposals timely without
/// re-screening the same pairs every few minutes (the durable
/// contradicts-tunnel dedup makes re-screens cheap but pointless).
public enum ContradictionScoutSignal {

    /// Default cadence in seconds (3600 = hourly).
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "contradiction-scout"

    /// Build a signal spec that runs one hunt pass on each fire.
    ///
    /// The `huntCycle` closure is called with the scheduler's `now` and
    /// returns `(proposed, borderline)` counts. Zero/zero is correct when
    /// nothing new conflicts. On error, the closure's throw is caught and
    /// surfaced as a `.diagnostic` emission so the scheduler's signal log
    /// records the failure without silencing the signal.
    public static func spec(
        huntCycle: @escaping @Sendable (Date) async throws -> (proposed: Int, borderline: Int)
            = { _ in (0, 0) }
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let counts = try await huntCycle(context.now)
                    // The hunt already persisted proposed tunnels through the
                    // estate verb surface — emit a summary diagnostic only.
                    return [.diagnostic(DiagnosticReport(
                        title: "contradiction-scout.pass.complete",
                        detail: "proposed \(counts.proposed) contradiction(s), "
                            + "\(counts.borderline) borderline candidate(s); "
                            + "signal=\(context.signalID.rawValue)",
                        observedAt: context.now))]
                } catch {
                    return [.diagnostic(DiagnosticReport(
                        title: "contradiction-scout.pass.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
