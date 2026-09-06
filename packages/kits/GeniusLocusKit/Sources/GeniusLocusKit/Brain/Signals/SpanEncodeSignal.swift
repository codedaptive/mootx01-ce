import Foundation

/// Span-encode standing signal — ENCODER_RERANK_CONTRACT §10, signal 13.
///
/// Replaces `AdornmentPassSignal` (removed): fires the span-encode drain
/// duty on each REM-ALPHA (30 s) tick and surfaces the encoded-drawer count
/// as a diagnostic. `SpanEncodeDuty.encodeBatch(estate:encoder:store:limit:now:)`
/// pulls up to `encoder_batch` drawers with operational bit 27 clear, encodes
/// their content into int8 span vectors, writes rows to `vectors_v6`, and
/// sets bit 27 (spanIndexed, contract §5) on success.
///
/// Mirrors `AnomalySweepSignal` exactly in structure: `.single` concurrency,
/// diagnostic-only emission, injected closure for the live cycle. Registered
/// 13th in `registerDefaultStandingSignals`.
///
/// Cadence is REM-ALPHA (30 s, `RemCycleTable.swift` line 78). This is
/// significantly faster than the hourly adornment-pass it replaces because
/// span encoding must index fresh content before queries arrive; the 30 s
/// drain keeps bit-27-clear debt bounded to at most one poll interval.
///
/// Usage pattern (mirrors AnomalySweepSignal):
///
///     let spec = SpanEncodeSignal.spec { now in
///         return try await kit.runSpanEncodeBatch(
///             handle: handle, encoder: encoder, store: store, now: now)
///     }
///     let id = try await kit.registerStandingSignal(spec, in: handle, now: now)
///
/// For registration without a live encoder (e.g., test scaffolds), use
/// `defaultSpec()`, which fires a diagnostic-only no-op.
public enum SpanEncodeSignal {

    /// REM-ALPHA cadence in seconds — 30 s, matching the ALPHA row in
    /// `RemCycleTable` (NEURONKIT_SPEC §12.6).  Significantly faster than the
    /// hourly adornment pass this signal replaces: fast indexing of fresh content
    /// is required for retrieval quality, while adornment minting was low-priority.
    public static let defaultCadenceSeconds: TimeInterval = 30

    /// Stable name surfaced in `SignalReport.name` and in
    /// `GeniusLocusKit.defaultStandingSignalNames` (registered by
    /// `registerDefaultStandingSignals`).
    ///
    /// Contract §10: signal name is "span-encode".
    public static let signalName = "span-encode"

    /// Build a signal spec that invokes the span-encode drain on each fire.
    ///
    /// The `spanEncodeCycle` closure is called with the scheduler's `now` and
    /// should call `GeniusLocusKit.runSpanEncodeBatch`, returning the count of
    /// drawers whose span rows were written and bit 27 set. An empty successful
    /// return (0) is correct when no unindexed drawers are present or the
    /// encoder is nil. On error the throw is caught and surfaced as a
    /// `.diagnostic` emission so the scheduler's drain loop is not interrupted.
    ///
    /// - Parameter spanEncodeCycle: async closure that executes one batch.
    ///   Captures the estate handle, encoder, and vector store it needs.
    ///   Called with `now` (deterministic clock) as the single argument.
    ///   Returns the count of drawers encoded. Throws on persistence failures.
    public static func spec(
        spanEncodeCycle: @escaping @Sendable (Date) async throws -> Int
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let count = try await spanEncodeCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "span-encode.complete",
                        detail: "encoded \(count) drawer(s) at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    // Surface drain errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. The failure appears in
                    // recentDiagnostics for application-layer monitoring.
                    return [.diagnostic(DiagnosticReport(
                        title: "span-encode.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live encoder is wired.
    ///
    /// The registered signal fires at the REM-ALPHA cadence and emits a
    /// single diagnostic confirming the fire. No encoding work is performed.
    /// This is the correct spec for `registerDefaultStandingSignals`,
    /// which cannot supply a live closure without knowing the caller's
    /// encoder and estate context.
    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // No-op drain: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                return [.diagnostic(DiagnosticReport(
                    title: "span-encode.fired",
                    detail: "span-encode signal fired (no-op) at \(context.now.ISO8601Format())",
                    observedAt: context.now))]
            })
    }
}
