// telemetry.rs — Per-estate rollup telemetry for GeniusLocusKit (GLK_ROLLUPS_001).
//
// Rust parity of `Sources/GeniusLocusKit/GeniusLocusKitTelemetry.swift`.
//
// DESIGN: OFF-PATH IS FREE
// All emit calls use the `report!` macro from intellectus_lib, which expands to:
//   if Intellectus::is_enabled() { Intellectus::report_sample(expr) }
// When monitoring is disabled (the default), the argument expression is NEVER
// evaluated — cost is a single AtomicBool::load(Acquire) + branch (~1 ns,
// lock-free). Results are byte-identical whether monitoring is on or off.
//
// METRIC NAMESPACE
// All metrics are under `geniuslocus.estate.*` to distinguish these per-estate
// rollups from per-kit metrics emitted by LocusKit, VectorKit, and CorpusKit.
//
// TIMESTAMPS
// Rust is synchronous; timestamps are produced via
// `std::time::SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64()`.
// This mirrors the Swift pattern of using `Date().timeIntervalSince1970`
// inside the autoclosure — evaluated only when monitoring is enabled.

/// Canonical metric names for the `geniuslocus.estate.*` namespace.
/// Mirrors `GLKMetricName` in the Swift port. Adding a new metric
/// here is the only place the name is authored — prevents drift across files.
pub mod metric_names {
    /// A per-estate mount state transition (mounted/quiesced/draining/unmounted).
    /// Tagged: `estate_id`, `state`.
    pub const MOUNT_STATE_TRANSITION: &str = "geniuslocus.estate.mount_state_transition";

    /// A provisioning event (create + open + wiring) for a new estate.
    /// Tagged: `estate_id`, `kind`.
    pub const PROVISION: &str = "geniuslocus.estate.provision";

    /// Snapshot of the estate's active drawer count at admission time.
    /// Tagged: `estate_id`.
    pub const NOUN_COUNT: &str = "geniuslocus.estate.noun_count";

    /// A verb error crossing the GLK estate boundary in `remap`.
    /// Tagged: `estate_id`, `verb`.
    pub const VERB_ERROR: &str = "geniuslocus.estate.verb_error";
}

/// Produce the current time as epoch seconds (f64) for telemetry timestamps.
///
/// Used inside `report!` argument expressions — only evaluated when monitoring
/// is enabled. Never called on the disabled path.
#[inline(always)]
pub fn now_secs() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Emit a `geniuslocus.estate.*` metric through `Intellectus`.
///
/// This is a convenience wrapper around the `report!` macro. The `tags`
/// parameter is built at the call site so it is NOT inside the macro argument
/// — which is fine because HashMap allocation only happens when monitoring is
/// enabled (the macro guard fires first). Callers that want zero allocation on
/// the disabled path should inline `report!` with a HashMap constructed inside
/// the macro argument.
///
/// All current call sites use this convenience form; the comment above
/// documents the tradeoff for future callers.
#[macro_export]
macro_rules! glk_emit {
    ($name:expr, $value:expr, $tags:expr) => {
        intellectus_lib::report!({
            intellectus_lib::StatSample::metric(
                $name.to_string(),
                $value,
                $tags,
                $crate::telemetry::now_secs(),
            )
        })
    };
}
