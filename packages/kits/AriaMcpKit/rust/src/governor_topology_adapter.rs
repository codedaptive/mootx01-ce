//! `StatsStoreTopologySink` — AriaMcpKit's `GovernorTopologySink` adapter.
//!
//! Bridges `neuron_kit::governor_topology_sink::GovernorTopologySink` (the
//! injection seam in the substrate kit) and `observer_sink::StatsStore` (the
//! host-layer telemetry store). NeuronKit cannot import observer_sink (that
//! would invert the layering: AriaMcpKit depends on NeuronKit, not the
//! reverse); this adapter, which lives in AriaMcpKit, owns that boundary.
//!
//! # Usage
//!
//! In `runtime.rs`, when `ARIA_MCP_STATS_STORE` is configured:
//! ```ignore
//! let sink: Box<dyn GovernorTopologySink> =
//!     Box::new(StatsStoreTopologySink::new(Arc::clone(&store)));
//! let governor = AutonomicGovernor::new_with_topology_sink(
//!     coord, handle, drawer_store, Some(sink));
//! ```

use std::sync::Arc;
use neuron_kit::governor_topology_sink::GovernorTopologySink;
use observer_sink::StatsStore;

/// Implements `GovernorTopologySink` over `observer_sink::StatsStore`.
///
/// `write_topology_snapshot` delegates to `StatsStore::write_topology_snapshot`.
/// `is_monitoring_enabled` delegates to `StatsStore::is_monitoring_enabled`,
/// failing open (`true`) on any read error so a transient store failure never
/// silently freezes the topology duty.
pub struct StatsStoreTopologySink {
    store: Arc<StatsStore>,
}

impl StatsStoreTopologySink {
    /// Wrap an existing `Arc<StatsStore>`.
    pub fn new(store: Arc<StatsStore>) -> Self {
        Self { store }
    }
}

impl GovernorTopologySink for StatsStoreTopologySink {
    fn write_topology_snapshot(
        &self,
        estate_id: &str,
        now_epoch_secs: f64,
        payload: &str,
    ) -> Result<(), String> {
        self.store
            .write_topology_snapshot(estate_id, now_epoch_secs, payload)
            .map_err(|e| format!("{e:?}"))
    }

    fn is_monitoring_enabled(&self) -> bool {
        // Fail open: a transient read failure must not silently freeze the
        // topology duty. The governor logs the outcome; we just say "run it".
        self.store.is_monitoring_enabled().unwrap_or(true)
    }
}
