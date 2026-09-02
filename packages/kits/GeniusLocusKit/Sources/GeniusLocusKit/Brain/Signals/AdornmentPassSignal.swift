import Foundation

/// Adornment-pass standing signal — GENIUSLOCUSKIT_SPEC 2.0.0 § 16, signal 13.
///
/// Fires the dream-time adornment-minting pass on each hourly tick and
/// surfaces the adorned-pair count as a diagnostic.
/// `AdornmentPass.run(estate:batchSize:...now:)` (see its declaration
/// for the resolver and width parameters) fetches
/// up to `batchSize` `(live Drawer, active minter)` pairs without an
/// adornment row, invokes the generator for each pair, and writes
/// `StoredAdornment(drawerID, minterID, text)` via LocusKit's normalized
/// store surface. A failure on one pair leaves only that pair missing;
/// the minter is never disabled.
///
/// Mirrors `AnomalySweepSignal` exactly in structure: hourly cadence,
/// `.single` concurrency, diagnostic-only emission, injected closure for
/// the live cycle. Registered 13th in `registerDefaultStandingSignals`.
///
/// Usage pattern (mirrors AnomalySweepSignal):
///
///     let spec = AdornmentPassSignal.spec { now in
///         let result = try await AdornmentPass.run(estate: estate, now: now)
///         return result.adornedPairs
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// For registration without a live pass (e.g., test scaffolds), use
/// `defaultSpec()`, which fires a diagnostic-only no-op.
public enum AdornmentPassSignal {

    /// Hourly cadence in seconds — same family as the anomaly sweep
    /// and distillation sweep (architecture spec §11.2).
    public static let defaultCadenceSeconds: TimeInterval = 3_600

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames` (registered by
    /// `registerDefaultStandingSignals`).
    public static let signalName = "adornment-pass"

    /// Build a signal spec that invokes the adornment-minting pass
    /// on each fire.
    ///
    /// The `adornmentCycle` closure is called with the scheduler's `now`
    /// and should run `AdornmentPass.run`, returning the count of (drawer,
    /// minter) pairs that were successfully adorned. An empty successful
    /// return (0) is correct when no debt pairs are present or all active
    /// minters have existing rows. On error the throw is caught and surfaced
    /// as a `.diagnostic` emission so the scheduler's drain loop is not
    /// interrupted.
    ///
    /// - Parameter adornmentCycle: async closure that executes the pass.
    ///   Captures the estate context it needs. Called with `now`
    ///   (deterministic clock) as the single argument. Returns the count
    ///   of (drawer, minter) pairs whose adornment was minted and stored.
    ///   Throws on persistence failures.
    public static func spec(
        adornmentCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await adornmentCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "adornment-pass.complete",
                        detail: "adorned \(count) pair(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface pass errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "adornment-pass.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live adornment pass cycle is available.
    ///
    /// The registered signal fires at the hourly cadence and emits a
    /// single diagnostic confirming the fire. No minting work is performed.
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
                // No-op pass: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                return [.diagnostic(DiagnosticReport(
                    title: "adornment-pass.fired",
                    detail: "adornment pass signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
