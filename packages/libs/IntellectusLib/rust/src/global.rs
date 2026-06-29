// global.rs
//
// Intellectus — the global telemetry facade.
//
// Parity with Swift's `Intellectus` enum (caseless namespace):
//   Intellectus.install(sink:)  ↔  Intellectus::install(sink)
//   Intellectus.setEnabled(_:)  ↔  Intellectus::set_enabled(enabled)
//   Intellectus.isEnabled       ↔  Intellectus::is_enabled()
//   Intellectus.report(_:)      ↔  report!(…) macro / Intellectus::report_sample(…)
//
// The global singleton uses OnceLock so the initial state is created
// lazily but exactly once, with no unsafe initialization.

use std::sync::{Arc, OnceLock};
use crate::holder::IntellectusHolder;
use crate::sink::StatsSink;
use crate::sample::StatSample;

/// Module-private global singleton. Created lazily on first access.
static _INTELLECTUS: OnceLock<IntellectusHolder> = OnceLock::new();

/// Access the global singleton, initialising it on first call.
#[inline(always)]
fn global() -> &'static IntellectusHolder {
    _INTELLECTUS.get_or_init(IntellectusHolder::new)
}

/// The global telemetry facade for IntellectusLib.
///
/// `Intellectus` is a stateless namespace (unit struct with only
/// associated functions). All state lives in the module-internal
/// `_INTELLECTUS` singleton.
///
/// ## Default state
///
/// Monitoring is **off** by default. The installed sink is `NoOpSink`.
/// No `report!` call will construct a payload or call any sink until
/// the host calls `Intellectus::set_enabled(true)`.
///
/// ## Example
///
/// ```rust
/// use intellectus_lib::{Intellectus, StatSample, report};
///
/// // Enable monitoring (install a real sink first in production).
/// Intellectus::set_enabled(true);
///
/// let mut hit = 0usize;
/// report!({
///     hit += 1;
///     StatSample::metric("x".into(), 1.0, Default::default(), 0.0)
/// });
/// assert_eq!(hit, 1);
///
/// Intellectus::set_enabled(false);
/// ```
pub struct Intellectus;

impl Intellectus {
    // MARK: - Host API

    /// Replace the installed sink with `sink`.
    ///
    /// Thread-safe. Takes effect for all subsequent `report!` calls.
    /// The previous sink is discarded.
    ///
    /// Install before calling `set_enabled(true)` to avoid a window
    /// where monitoring is on but the real sink is not yet installed.
    pub fn install(sink: Arc<dyn StatsSink>) {
        global().install(sink);
    }

    /// Enable or disable the global telemetry gate.
    ///
    /// When `false` (the default), every `report!` invocation is a
    /// no-op — the payload closure is never evaluated.
    pub fn set_enabled(enabled: bool) {
        global().set_enabled(enabled);
    }

    /// Whether monitoring is currently enabled.
    pub fn is_enabled() -> bool {
        global().is_enabled()
    }

    // MARK: - Internal emission (called by report! macro)

    /// Deliver a pre-constructed sample to the installed sink.
    ///
    /// This is a low-level entry point called by the `report!` macro
    /// after the macro's own enabled check. Direct callers should
    /// prefer the `report!` macro, which avoids evaluating the payload
    /// expression when monitoring is disabled.
    ///
    /// Both this function and the `report!` macro check `is_enabled()`
    /// before forwarding to the sink — a direct call when disabled is a
    /// no-op, matching Swift's `Intellectus.report(_:)` semantics.
    #[doc(hidden)]
    #[inline]
    pub fn report_sample(sample: StatSample) {
        // Disabled gate: if monitoring is off, discard the sample. Matches
        // Swift's `Intellectus.report(_:)` which checks `isEnabled` before
        // forwarding. The `report!` macro already gates; this protects direct
        // callers of `report_sample` from delivering to the sink when disabled.
        if !Self::is_enabled() {
            return;
        }
        let sink = {
            let guard = global()._sink.lock()
                .expect("Intellectus sink lock poisoned");
            std::sync::Arc::clone(&*guard)
        };
        sink.receive(sample);
    }
}
