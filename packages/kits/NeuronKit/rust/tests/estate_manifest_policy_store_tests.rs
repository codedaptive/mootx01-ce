//! F6 / ADR-020: the manifest-backed policy stores persist dreaming/maintenance
//! policy and daemon cycle state THROUGH the substrate's public KV surface
//! (DrawerStore::get_meta/set_meta). These tests prove the round-trip through a
//! live in-memory estate store. Mirrors Swift `EstateManifestPolicyStoreTests`.

use std::collections::BTreeMap;
use std::sync::Arc;

use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;

use neuron_kit::dreaming_cycle::{DreamingDaemonState, DreamingPolicy, DreamingPolicyStore};
use neuron_kit::estate_manifest_policy_store::{
    EstateManifestDreamingPolicyStore, EstateManifestMaintenancePolicyStore,
};
use neuron_kit::maintenance_cycle::{
    MaintenanceDaemonState, MaintenancePolicy, MaintenancePolicyStore,
};
use neuron_kit::solver_bandit::{DreamingTriggerMode, SolverBandit};

const NOW: i64 = 1_700_000_000;

fn store() -> Arc<dyn DrawerStore> {
    Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap())
}

#[test]
fn dreaming_policy_round_trips_through_manifest() {
    let s = store();
    let mut dstore = EstateManifestDreamingPolicyStore::new(Arc::clone(&s));
    assert_eq!(dstore.load_policy(), None, "absent before first save");

    let mut policy = DreamingPolicy::default();
    policy.min_confidence = 0.8;
    policy.tick_interval_ms = 45_000;
    dstore.save_policy(policy);
    assert_eq!(dstore.load_policy(), Some(policy));
}

#[test]
fn dreaming_bandit_round_trips_through_manifest() {
    let s = store();
    let mut dstore = EstateManifestDreamingPolicyStore::new(Arc::clone(&s));
    assert_eq!(dstore.load_bandit(), None, "absent before first save");

    let mut bandit = SolverBandit::default();
    bandit.observe(DreamingTriggerMode::Timer, 1.0);
    bandit.observe(DreamingTriggerMode::Event, 0.0);
    dstore.save_bandit(bandit.clone());
    assert_eq!(dstore.load_bandit(), Some(bandit));
}

#[test]
fn dreaming_daemon_state_round_trips_through_manifest() {
    let s = store();
    let mut dstore = EstateManifestDreamingPolicyStore::new(Arc::clone(&s));
    assert_eq!(dstore.load_daemon_state(), None);

    let mut consolidated = BTreeMap::new();
    consolidated.insert("a|b".to_string(), 0.88_f32);
    consolidated.insert("c|d".to_string(), 0.42_f32);
    let state = DreamingDaemonState {
        last_timer_fire_epoch_secs: Some(1_700_000_000.0),
        proposed_keys: vec!["a|b".to_string(), "c|d".to_string()],
        last_reindex_vocab: 1_234,
        consolidated,
        cycle_count: 7,
        co_recall_counts: BTreeMap::new(),
        last_theta_run_epoch_secs: None,
        last_beta_run_epoch_secs: None,
        last_omega_run_epoch_secs: None,
    };
    dstore.save_daemon_state(state.clone());
    assert_eq!(dstore.load_daemon_state(), Some(state));
}

#[test]
fn maintenance_policy_round_trips_through_manifest() {
    let s = store();
    let mut mstore = EstateManifestMaintenancePolicyStore::new(Arc::clone(&s));
    assert_eq!(mstore.load_policy(), None);

    let policy = MaintenancePolicy::default();
    mstore.save_policy(policy);
    assert_eq!(mstore.load_policy(), Some(policy));
}

#[test]
fn maintenance_daemon_state_round_trips_through_manifest() {
    let s = store();
    let mut mstore = EstateManifestMaintenancePolicyStore::new(Arc::clone(&s));
    assert_eq!(mstore.load_daemon_state(), None);

    let state = MaintenanceDaemonState {
        last_fire_epoch_secs: Some(1_700_000_500.0),
        last_audit_check_epoch_secs: Some(1_700_000_400.0),
        proposed_keys: vec!["decay:room-1".to_string(), "tombstone:row-9".to_string()],
        cycle_count: 3,
    };
    mstore.save_daemon_state(state.clone());
    assert_eq!(mstore.load_daemon_state(), Some(state));
}

/// Two stores over the SAME backing DrawerStore observe each other's writes —
/// the persistence is in the shared manifest table, not store-local memory
/// (the cross-restart property, simulated by a second store instance).
#[test]
fn daemon_state_persists_across_store_instances() {
    let s = store();
    let mut first = EstateManifestDreamingPolicyStore::new(Arc::clone(&s));
    let state = DreamingDaemonState {
        last_timer_fire_epoch_secs: Some(42.0),
        proposed_keys: vec!["x|y".to_string()],
        last_reindex_vocab: 10,
        consolidated: BTreeMap::new(),
        cycle_count: 1,
        co_recall_counts: BTreeMap::new(),
        last_theta_run_epoch_secs: None,
        last_beta_run_epoch_secs: None,
        last_omega_run_epoch_secs: None,
    };
    first.save_daemon_state(state.clone());

    // A brand-new store over the same backing store (the "restart") sees it.
    let second = EstateManifestDreamingPolicyStore::new(Arc::clone(&s));
    assert_eq!(second.load_daemon_state(), Some(state));
}
