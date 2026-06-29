// StatSample.swift
//
// The telemetry datum. A StatSample is either a named metric with a
// floating-point value and tag map, or a topology-worker event that
// records a substrate lifecycle transition.
//
// Design notes:
//   - Timestamps are caller-supplied (epoch seconds as Double) — never
//     read a clock inside IntellectusLib. Determinism is required.
//   - Both variants are value types and Sendable so they can cross
//     actor / task boundaries without copying overhead on the caller.
//   - The tag map uses String keys and String values. Keeping both
//     sides String (rather than, say, Int for nounType tag) keeps the
//     metric variant general-purpose; the event variant uses typed
//     fields where the types are fixed by the topology protocol.

import Foundation

// MARK: - StatSample

/// A single telemetry observation. Either a named floating-point
/// metric with optional string tags, or a topology-worker event
/// recording a substrate lifecycle transition.
///
/// All instances are value types and `Sendable`. They may be
/// forwarded across task / actor boundaries without synchronisation
/// overhead on the construction site.
///
/// Timestamps (`ts`) are **caller-supplied epoch seconds** (Double).
/// Never call a clock inside `IntellectusLib`. Pass `Date().timeIntervalSince1970`
/// or any deterministic time source at the call site.
public enum StatSample: Sendable {

    // MARK: Metric

    /// A named floating-point measurement with optional string tags.
    ///
    /// - Parameters:
    ///   - name:  Dot-separated metric name, e.g. `"locus.capture.latency_ms"`.
    ///   - value: The measured quantity (count, duration, rate, …).
    ///   - tags:  Arbitrary string key-value context, e.g. `["kit": "LocusKit"]`.
    ///   - ts:    Caller-supplied epoch seconds. Never read a clock here.
    case metric(
        name: String,
        value: Double,
        tags: [String: String],
        ts: Double
    )

    // MARK: Event

    /// A topology-worker lifecycle event. Records that a substrate
    /// verb (capture or think) was applied to a noun row in an estate.
    ///
    /// Event samples are emitted by callers such as `LocusKit.EstateVerbs`
    /// and `NeuronKit.EstateDreamingSink`, then retained by `RecentWindowSink`
    /// and persisted through `ObserverSink.PersistenceStatsSink`. The
    /// `AutonomicGovernor`'s topology-snapshot duty recomputes from estate
    /// drawers/tunnels/facts on its own cadence; it does not consume this
    /// event stream.
    ///
    /// - Parameters:
    ///   - kind:      The verb kind: `.capture` or `.think`.
    ///   - nounType:  The NounType ordinal (Int) from SubstrateTypes.
    ///                Passed as Int here to keep IntellectusLib a zero-
    ///                dependency leaf — the caller casts NounType to Int.
    ///   - rowID:     The row's UUID string from the estate.
    ///   - estate:    The estate identifier string.
    ///   - ts:        Caller-supplied epoch seconds.
    case event(
        kind: EventKind,
        nounType: Int,
        rowID: String,
        estate: String,
        ts: Double
    )
}

// MARK: - EventKind

/// The substrate verb class that triggered a topology event.
///
/// `capture` corresponds to a caller-driven write (the nine-verb
/// `capture` and its close relatives). `think` corresponds to a
/// substrate-driven autonomous transition (Brain layer).
public enum EventKind: String, Sendable, Hashable, CaseIterable {
    case capture
    case think
}

// MARK: - StatSample convenience accessors

extension StatSample {

    /// The event timestamp, regardless of variant.
    public var ts: Double {
        switch self {
        case let .metric(_, _, _, ts): return ts
        case let .event(_, _, _, _, ts): return ts
        }
    }
}
