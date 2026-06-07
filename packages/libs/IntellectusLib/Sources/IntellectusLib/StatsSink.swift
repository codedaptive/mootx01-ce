// StatsSink.swift
//
// The receiver protocol for telemetry samples, and the default no-op
// implementation that discards every sample safely.
//
// Design notes:
//   - `StatsSink` requires Sendable because the installed sink is held
//     in the global `Intellectus` holder and accessed from any thread.
//   - `receive(_:)` is the single required method. No batching, no
//     buffering, no back-pressure at this layer — those are concerns
//     for the concrete implementation a host installs.
//   - The real reporting sink (transport to the observer program) is
//     installed by a host in a later mission. This file only provides
//     the protocol and the no-op default.

// MARK: - StatsSink

/// Receiver protocol for telemetry samples.
///
/// Conforming types receive `StatSample` values as they are emitted
/// by `Intellectus.report(_:)`. The only requirement is `receive(_:)`.
///
/// Conformers must be `Sendable`: the installed sink is held globally
/// and called from any concurrent context.
///
/// The `receive(_:)` implementation should be non-blocking and
/// inexpensive. The substrate calls it from hot-path code when
/// monitoring is enabled. Long-running work (serialisation, network)
/// belongs in the concrete implementation's own queue, not in the
/// `receive(_:)` body.
public protocol StatsSink: Sendable {

    /// Deliver one telemetry sample to this sink.
    ///
    /// Called only when monitoring is enabled (`Intellectus.isEnabled`
    /// is `true`). Never called when monitoring is disabled — the
    /// short-circuit gate in `Intellectus.report(_:)` prevents it.
    ///
    /// - Parameter sample: The telemetry datum to receive.
    func receive(_ sample: StatSample)
}

// MARK: - NoOpSink

/// The default sink. Discards every sample and returns immediately.
///
/// This is the installed sink before any host calls
/// `Intellectus.install(sink:)`. Because monitoring is off by
/// default (`Intellectus.isEnabled` starts `false`), `receive(_:)`
/// is never actually called in the default configuration — but the
/// no-op is the safe, correct behaviour if `isEnabled` is set
/// before a real sink is installed.
public struct NoOpSink: StatsSink {

    /// Shared instance. Lightweight — the struct holds no state.
    public static let shared = NoOpSink()

    public init() {}

    /// Discards the sample immediately. O(1), no allocation.
    @inline(__always)
    public func receive(_ sample: StatSample) {
        // Intentional discard. Nothing to do.
    }
}
