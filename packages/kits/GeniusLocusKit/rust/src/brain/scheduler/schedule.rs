// brain/scheduler/schedule.rs — schedule-layer types for the Rust
// mirror. The Rust port keeps schedule state alongside the serial
// lane in `serial_lane.rs`; this file exposes the error vocabulary
// the conformance gate asserts against.

use crate::brain::scheduler::api::SignalID;

/// Mirrors a subset of Swift's `GeniusLocusKitError`. The Rust port
/// surfaces only the scheduler-specific cases since the wider error
/// taxonomy (estate lifecycle, manifest validation, fan-out) lives
/// in `coordinator.rs` and is unrelated to the standing-signals
/// surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SchedulerError {
    /// `subscribe`, `unsubscribe`, or `request_fire` referenced a
    /// SignalID that is not currently registered.
    SignalNotRegistered(SignalID),
}

impl std::fmt::Display for SchedulerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SchedulerError::SignalNotRegistered(id) => write!(
                f,
                "signal {} is not registered with the addressed estate's scheduler",
                id.0
            ),
        }
    }
}

impl std::error::Error for SchedulerError {}
