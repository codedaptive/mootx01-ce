// sink.rs
//
// StatsSink trait and the default NoOpSink implementation.
//
// Parity:
//   Swift `protocol StatsSink: Sendable { func receive(_ sample: StatSample) }`
//   Rust  `trait StatsSink: Send + Sync { fn receive(&self, sample: StatSample); }`
//
// The trait requires Send + Sync because the installed sink is held
// behind an Arc<dyn StatsSink> in the global IntellectusHolder and
// called from any thread.

use crate::sample::StatSample;

// MARK: - StatsSink

/// Receiver trait for telemetry samples.
///
/// Conforming types receive [`StatSample`] values as they are emitted
/// by the [`report!`] macro. The only requirement is `receive`.
///
/// Implementors must be `Send + Sync`: the installed sink is held in
/// the global holder and called from concurrent contexts.
///
/// The `receive` body should be non-blocking and inexpensive. Long-
/// running work (serialisation, network I/O) belongs in the concrete
/// implementation's own task or thread, not in `receive` itself.
pub trait StatsSink: Send + Sync {
    /// Deliver one telemetry sample to this sink.
    ///
    /// Called only when monitoring is enabled. The [`report!`] macro
    /// short-circuits before this is reached when disabled.
    fn receive(&self, sample: StatSample);
}

// MARK: - NoOpSink

/// The default sink. Discards every sample and returns immediately.
///
/// This is the installed sink before any host calls
/// [`Intellectus::install`]. Because monitoring is off by default
/// (`is_enabled()` starts `false`), `receive` is never actually
/// called in the default configuration — but the no-op is the safe,
/// correct behaviour if `set_enabled(true)` is called before a real
/// sink is installed.
#[derive(Debug, Clone, Default)]
pub struct NoOpSink;

impl StatsSink for NoOpSink {
    /// Discards the sample immediately. O(1), no allocation.
    #[inline(always)]
    fn receive(&self, _sample: StatSample) {
        // Intentional discard. Nothing to do.
    }
}
