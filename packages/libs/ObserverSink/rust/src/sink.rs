//! PersistenceStatsSink — StatsSink conformance backed by StatsStore.
//!
//! Mirrors Swift's `PersistenceStatsSink` struct.
//!
//! ## Differences from the Swift port
//!
//! Swift: `receive(_:)` dispatches an async `Task` because the `Storage`
//! trait is async-actor-isolated. Rust: the `StatsSink` trait is synchronous
//! (`receive` takes `&self`) and `SqliteStorage` is synchronously accessible
//! (mutex-backed). So the Rust `receive` does the I/O inline — no thread
//! spawning needed. This is the correct Rust-semantics approach: use Rust
//! semantics, not a mechanical async translation of the Swift pattern.
//!
//! ## Monitoring flag semantics (identical to Swift)
//!
//! On each `receive` call, reads the "monitoring" row from the store. If the
//! flag is "0", discards the sample. If the flag is "1", inserts the sample.
//! Errors from the store are logged to stderr (never panicked).

use std::collections::BTreeMap;
use std::sync::Arc;

use intellectus_lib::{StatSample, StatsSink};
use crate::store::StatsStore;

/// A `StatsSink` that persists each `StatSample` to a `StatsStore`.
///
/// Mirrors Swift's `PersistenceStatsSink` struct.
///
/// ## Usage
///
/// ```rust,ignore
/// use observer_sink::{StatsStore, PersistenceStatsSink};
/// use intellectus_lib::Intellectus;
/// use std::sync::Arc;
///
/// let store = StatsStore::new("/tmp/stats.sqlite").unwrap();
/// store.open().unwrap();
/// store.set_monitoring_enabled(true).unwrap();
///
/// let sink = Arc::new(PersistenceStatsSink::new(Arc::new(store), "my-app".to_string()));
/// Intellectus::install(sink);
/// Intellectus::set_enabled(true);
/// ```
pub struct PersistenceStatsSink {
    store: Arc<StatsStore>,
    dropbox_id: String,
}

impl PersistenceStatsSink {
    /// Create a `PersistenceStatsSink`.
    ///
    /// - `store`:       The `StatsStore` to write samples to. Must already be opened.
    /// - `dropbox_id`:  Identifies this consumer in the stats store rows.
    pub fn new(store: Arc<StatsStore>, dropbox_id: String) -> Self {
        PersistenceStatsSink { store, dropbox_id }
    }
}

impl StatsSink for PersistenceStatsSink {
    /// Deliver one sample to the store.
    ///
    /// Checks the store's monitoring flag row first. Discards silently if the
    /// flag is `"0"`. If `"1"`, inserts the sample into the appropriate table.
    ///
    /// I/O is done inline (synchronous Rust semantics, matching SqliteStorage).
    /// Errors are printed to stderr — the sink must never panic the substrate.
    ///
    /// Mirrors Swift `PersistenceStatsSink.receive(_:)` semantics.
    fn receive(&self, sample: StatSample) {
        // Check store-level monitoring flag before any write.
        let monitoring_on = match self.store.is_monitoring_enabled() {
            Ok(v) => v,
            Err(e) => {
                // Flag read failed — discard silently (safe default: off).
                eprintln!("[ObserverSink] monitoring flag read error: {e:?}");
                return;
            }
        };
        if !monitoring_on {
            // Monitoring off at the store level — discard.
            return;
        }

        let result = match &sample {
            StatSample::Metric { name, value, tags, ts } => {
                // Convert HashMap to BTreeMap for deterministic key ordering.
                let btags: BTreeMap<String, String> = tags.iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                self.store.insert_metric(name, *value, &btags, *ts, &self.dropbox_id)
            }
            StatSample::Event { kind, noun_type, row_id, estate, ts } => {
                self.store.insert_event(
                    kind.as_str(),
                    *noun_type,
                    row_id,
                    estate,
                    *ts,
                    &self.dropbox_id,
                )
            }
        };

        if let Err(e) = result {
            eprintln!("[ObserverSink] store write failed: {e:?}");
        }
    }
}
