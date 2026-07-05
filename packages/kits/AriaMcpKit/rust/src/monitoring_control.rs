//! MonitoringControl — injectable monitoring gate for `moot_monitoring_status`.
//!
//! Mirrors Swift `MonitoringControl` protocol. AriaMcpKit defines the trait;
//! the serve host supplies the concrete impl that wraps `observer_sink::StatsStore`.
//! This keeps AriaMcpKit free of the observer_sink dependency — the same
//! boundary discipline used for vault tools and sensitivity ledgers.
//!
//! # Unavailable case
//!
//! When no stats store is wired (stdio mode, test harnesses, provision-less
//! contexts), the dispatcher carries `None` for this field. The tool runner
//! (`run_monitoring_status` in `interface_tools.rs`) reports
//! "monitoring: unavailable" in that case — it never fabricates a state.
//!
//! # Threading
//!
//! `MonitoringControl: Send + Sync` because it may be shared behind `Arc` across
//! threads in the HTTP server path. `StatsStoreMonitoringControl` satisfies this
//! because `observer_sink::StatsStore` is `Send + Sync`.

use std::sync::Arc;

/// Read/set the daemon's monitoring flag without importing observer_sink directly.
///
/// Methods are infallible from the caller's perspective — errors are absorbed
/// by implementations and surface as `None` on read or are silently logged on
/// write. This matches the Swift protocol's best-effort `set` and nil-returning
/// `read` contract.
pub trait MonitoringControl: Send + Sync {
    /// Return the current monitoring-enabled flag.
    /// Returns `None` when the store cannot be read (transient error).
    /// `None` ≠ `false` — callers must not substitute one for the other.
    fn read(&self) -> Option<bool>;

    /// Persist `enabled` as the new monitoring flag.
    /// Best-effort: errors are swallowed by the implementation.
    /// The store also writes `monitoring_source=user` so downstream
    /// readers can distinguish operator-driven changes from defaults.
    fn set(&self, enabled: bool);
}

/// Concrete `MonitoringControl` backed by an `observer_sink::StatsStore`.
///
/// Constructed by `run_http_loop` from the `http_stats_store` when available.
/// `None` for the store in the `Dispatcher` means this type is never constructed.
pub struct StatsStoreMonitoringControl {
    pub store: Arc<observer_sink::StatsStore>,
}

impl MonitoringControl for StatsStoreMonitoringControl {
    fn read(&self) -> Option<bool> {
        self.store.is_monitoring_enabled().ok()
    }

    fn set(&self, enabled: bool) {
        // Best-effort — log on error but do not propagate.
        if let Err(e) = self.store.set_monitoring_enabled(enabled) {
            eprintln!("[moot_monitoring_status] set_monitoring_enabled failed: {e}");
        }
    }
}
