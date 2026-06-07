// sample.rs
//
// StatSample — the telemetry datum.
//
// Parity surface with Swift's `StatSample` enum:
//   .metric(name:value:tags:ts:)  ↔  StatSample::Metric { name, value, tags, ts }
//   .event(kind:nounType:rowID:estate:ts:) ↔ StatSample::Event { ... }
//
// Design notes:
//   - Timestamps (ts) are caller-supplied epoch seconds (f64). Never
//     read a clock inside IntellectusLib. Determinism is required.
//   - Both variants are Clone + Send + Sync so they can be forwarded
//     across thread boundaries without per-call allocation.
//   - The tag map uses HashMap<String, String> to match Swift's
//     [String: String] semantics.
//   - nounType is i64 (matching the NounType ordinal in SubstrateTypes).
//     Passed as plain integer here to keep this crate zero-dependency;
//     callers cast their NounType to i64 at the call site.

use std::collections::HashMap;

// MARK: - EventKind

/// The substrate verb class that triggered a topology event.
///
/// `Capture` corresponds to a caller-driven write (the nine-verb
/// `capture` and its close relatives). `Think` corresponds to a
/// substrate-driven autonomous transition (Brain layer).
///
/// Parity: mirrors Swift `EventKind` exactly (same raw string values
/// to allow round-tripping through JSON if a future mission adds
/// serialisation).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum EventKind {
    /// Caller-driven write verb — capture and close relatives.
    Capture,
    /// Substrate-driven autonomous transition — Brain layer.
    Think,
}

impl EventKind {
    /// The canonical string tag for this kind (matches Swift rawValue).
    pub fn as_str(&self) -> &'static str {
        match self {
            EventKind::Capture => "capture",
            EventKind::Think => "think",
        }
    }
}

// MARK: - StatSample

/// A single telemetry observation. Either a named floating-point
/// metric with optional string tags, or a topology-worker event
/// recording a substrate lifecycle transition.
///
/// Parity: mirrors Swift's `StatSample` enum variant-for-variant.
/// The `Metric` variant maps to `.metric(name:value:tags:ts:)`;
/// the `Event` variant maps to `.event(kind:nounType:rowID:estate:ts:)`.
#[derive(Debug, Clone)]
pub enum StatSample {
    /// A named floating-point measurement with optional string tags.
    ///
    /// - `name`:  Dot-separated metric name.
    /// - `value`: The measured quantity (count, duration, rate, …).
    /// - `tags`:  Arbitrary string key-value context.
    /// - `ts`:    Caller-supplied epoch seconds. Never read a clock here.
    Metric {
        name: String,
        value: f64,
        tags: HashMap<String, String>,
        ts: f64,
    },

    /// A topology-worker lifecycle event.
    ///
    /// - `kind`:       The verb kind (`Capture` or `Think`).
    /// - `noun_type`:  The NounType ordinal from SubstrateTypes (i64).
    /// - `row_id`:     The row UUID string.
    /// - `estate`:     The estate identifier string.
    /// - `ts`:         Caller-supplied epoch seconds.
    Event {
        kind: EventKind,
        noun_type: i64,
        row_id: String,
        estate: String,
        ts: f64,
    },
}

impl StatSample {
    // MARK: Constructors (mirror Swift's enum cases)

    /// Construct a `Metric` sample. Mirrors Swift `.metric(name:value:tags:ts:)`.
    pub fn metric(
        name: String,
        value: f64,
        tags: HashMap<String, String>,
        ts: f64,
    ) -> Self {
        StatSample::Metric { name, value, tags, ts }
    }

    /// Construct an `Event` sample. Mirrors Swift `.event(kind:nounType:rowID:estate:ts:)`.
    pub fn event(
        kind: EventKind,
        noun_type: i64,
        row_id: String,
        estate: String,
        ts: f64,
    ) -> Self {
        StatSample::Event { kind, noun_type, row_id, estate, ts }
    }

    // MARK: Accessors

    /// The event timestamp, regardless of variant.
    /// Mirrors Swift's `StatSample.ts` computed property.
    pub fn ts(&self) -> f64 {
        match self {
            StatSample::Metric { ts, .. } => *ts,
            StatSample::Event { ts, .. } => *ts,
        }
    }
}
