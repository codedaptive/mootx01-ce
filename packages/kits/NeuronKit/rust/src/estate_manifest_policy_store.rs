//! Manifest-backed implementations of the dreaming and maintenance policy
//! stores (F6 / ADR-020). These satisfy the daemon persistence seams by reading
//! and writing the estate manifest THROUGH the substrate's public key-value
//! surface (`DrawerStore::get_meta` / `set_meta`, backed by the durable manifest
//! table), so policy and daemon cycle state survive a process restart.
//!
//! The Rust governor already holds the `Arc<dyn DrawerStore>` the estate was
//! opened with (the sink write path), so these stores take it directly — the
//! same public KV surface `Estate::meta`/`set_meta` delegates to. The substrate
//! OWNS the durable storage; NeuronKit owns the typed serialization of what goes
//! in it (Interface Rules: features owned at the lowest level). Mirrors Swift
//! `EstateManifestPolicyStore.swift`.

use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde::Serialize;

use locus_kit::drawer_store::DrawerStore;

use crate::dreaming_cycle::{DreamingDaemonState, DreamingPolicy, DreamingPolicyStore};
use crate::maintenance_cycle::{
    MaintenanceDaemonState, MaintenancePolicy, MaintenancePolicyStore,
};
use crate::solver_bandit::SolverBandit;

/// Namespaced manifest keys for NeuronKit daemon state (ADR-020). Namespaced to
/// avoid collision with the typed v1 manifest keys. Keys match the Swift port.
mod keys {
    pub const DREAMING_POLICY: &str = "neuronkit.dreaming.policy";
    pub const DREAMING_BANDIT: &str = "neuronkit.dreaming.bandit";
    pub const DREAMING_STATE: &str = "neuronkit.dreaming.state";
    pub const MAINTENANCE_POLICY: &str = "neuronkit.maintenance.policy";
    pub const MAINTENANCE_STATE: &str = "neuronkit.maintenance.state";
}

/// Decode a JSON manifest value by key. A present-but-undecodable value returns
/// `None` (fail-soft: the daemon falls back to its defaults rather than failing
/// on a value written by a newer schema). A store read error also yields `None`.
fn load_value<T: DeserializeOwned>(store: &Arc<dyn DrawerStore>, key: &str) -> Option<T> {
    let json = store.get_meta(key).ok().flatten()?;
    serde_json::from_str(&json).ok()
}

/// Encode and upsert a JSON manifest value. Best-effort: a serialization or
/// store-write failure is dropped (the daemon keeps running on in-memory state).
fn save_value<T: Serialize>(store: &Arc<dyn DrawerStore>, key: &str, value: &T) {
    if let Ok(json) = serde_json::to_string(value) {
        let _ = store.set_meta(key, &json);
    }
}

/// Manifest-backed `DreamingPolicyStore`: persists the dreaming policy and the
/// daemon's cycle state to the estate manifest.
pub struct EstateManifestDreamingPolicyStore {
    store: Arc<dyn DrawerStore>,
}

impl EstateManifestDreamingPolicyStore {
    /// Construct a store over the estate's backing `DrawerStore`.
    pub fn new(store: Arc<dyn DrawerStore>) -> Self {
        Self { store }
    }
}

impl DreamingPolicyStore for EstateManifestDreamingPolicyStore {
    fn load_policy(&self) -> Option<DreamingPolicy> {
        load_value(&self.store, keys::DREAMING_POLICY)
    }

    fn save_policy(&mut self, policy: DreamingPolicy) {
        save_value(&self.store, keys::DREAMING_POLICY, &policy);
    }

    fn load_bandit(&self) -> Option<SolverBandit> {
        load_value(&self.store, keys::DREAMING_BANDIT)
    }

    fn save_bandit(&mut self, bandit: SolverBandit) {
        save_value(&self.store, keys::DREAMING_BANDIT, &bandit);
    }

    fn load_daemon_state(&self) -> Option<DreamingDaemonState> {
        load_value(&self.store, keys::DREAMING_STATE)
    }

    fn save_daemon_state(&mut self, state: DreamingDaemonState) {
        save_value(&self.store, keys::DREAMING_STATE, &state);
    }
}

/// Manifest-backed `MaintenancePolicyStore`: persists the maintenance policy and
/// the daemon's cycle state to the estate manifest.
pub struct EstateManifestMaintenancePolicyStore {
    store: Arc<dyn DrawerStore>,
}

impl EstateManifestMaintenancePolicyStore {
    /// Construct a store over the estate's backing `DrawerStore`.
    pub fn new(store: Arc<dyn DrawerStore>) -> Self {
        Self { store }
    }
}

impl MaintenancePolicyStore for EstateManifestMaintenancePolicyStore {
    fn load_policy(&self) -> Option<MaintenancePolicy> {
        load_value(&self.store, keys::MAINTENANCE_POLICY)
    }

    fn save_policy(&mut self, policy: MaintenancePolicy) {
        save_value(&self.store, keys::MAINTENANCE_POLICY, &policy);
    }

    fn load_daemon_state(&self) -> Option<MaintenanceDaemonState> {
        load_value(&self.store, keys::MAINTENANCE_STATE)
    }

    fn save_daemon_state(&mut self, state: MaintenanceDaemonState) {
        save_value(&self.store, keys::MAINTENANCE_STATE, &state);
    }
}
