//! IntellectusLib — substrate self-report telemetry faculty.
//!
//! Zero-dependency leaf library. Depends on `std` only. The lowest
//! substrate crates (substrate-types, substrate-kernel, substrate-lib,
//! substrate-ml) declare `intellectus-lib` dependencies, making this
//! crate the floor of the dependency tree with no layering cycle.
//!
//! ## Public surface
//!
//! - [`StatSample`] — the telemetry datum (metric or topology event)
//! - [`EventKind`] — the verb class for topology events
//! - [`StatsSink`] — trait for receiving `StatSample` values
//! - [`NoOpSink`] — the default discard implementation
//! - [`RecentWindowSink`] — bounded ring-buffer sink exposing a recent window
//! - [`Intellectus`] — global holder: installed sink + atomic enabled flag
//! - [`report!`] — macro for short-circuit emission
//!
//! ## Design invariant
//!
//! When monitoring is disabled (the default), the `report!` macro
//! argument is **never evaluated**. Off-path cost: one atomic load +
//! branch. No allocation, no payload construction.
//!
//! ## Example
//!
//! ```rust
//! use intellectus_lib::{Intellectus, StatSample, report};
//!
//! // Install a real sink and enable monitoring.
//! // (skipped in this doctest — using the default no-op.)
//! Intellectus::set_enabled(false);
//!
//! // The closure argument is NEVER evaluated when disabled.
//! report!(StatSample::metric(
//!     "locus.capture.latency_ms".into(),
//!     42.5,
//!     Default::default(),
//!     0.0,
//! ));
//! ```

// ─────────────────────────────────────────────────────────────────
// DO NOT IMPORT SUBSTRATE MATH.
//
// This crate is the dependency floor. It depends on std only.
// Do not add substrate-types, substrate-kernel, or any other
// repo crate. Higher crates that need both telemetry and substrate
// math depend on both independently; this crate's zero-dep status
// is what allows them to do so without cycles.
// ─────────────────────────────────────────────────────────────────


mod sample;
pub use sample::{StatSample, EventKind};

mod sink;
pub use sink::{StatsSink, NoOpSink};

mod window;
pub use window::RecentWindowSink;

mod holder;
pub use holder::IntellectusHolder;

mod global;
pub use global::Intellectus;

/// Short-circuit emission macro.
///
/// Equivalent to `Intellectus::report(|| { $sample })`. The argument
/// expression is evaluated **only** when `Intellectus::is_enabled()`
/// returns `true`. When disabled, the macro expands to a single
/// `AtomicBool::load + branch` with no allocation.
///
/// # Example
///
/// ```rust
/// use intellectus_lib::{Intellectus, StatSample, report};
///
/// Intellectus::set_enabled(false);
///
/// let mut counter = 0usize;
/// report!({
///     counter += 1;   // NEVER runs when disabled
///     StatSample::metric("test".into(), 1.0, Default::default(), 0.0)
/// });
/// assert_eq!(counter, 0);
/// ```
#[macro_export]
macro_rules! report {
    ($make:expr) => {
        if $crate::Intellectus::is_enabled() {
            $crate::Intellectus::report_sample($make)
        }
    };
}
