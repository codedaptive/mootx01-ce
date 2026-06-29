//! T12 REM-BETA prune/GC cycle tests (ADR-021 Phase 7, NEURONKIT_SPEC § 12.6).
//!
//! Rust parity of `NeuronKitTests/DreamingBetaTests.swift`.
//!
//! Covers:
//!   Prune — `consolidated` entries below BETA_PRUNE_FLOOR are removed;
//!            above-floor entries are retained. Exact survivor set asserted.
//!   Co-recall orphan prune — `co_recall_counts` entries whose key is absent
//!            from `consolidated` after the prune are dropped; live entries kept.
//!   Memory-only — BETA writes no proposals, diary entries, or tunnel writes.
//!            The recording sink is empty after a BETA run.
//!   Cadence / persistence — BETA not due within 7 days; when due it prunes and
//!            advances `last_beta_run_epoch_secs`; the timestamp survives a
//!            `restore_state` so BETA is not due again until +7d.
//!   Anti-inert — a below-floor entry that exists before the cycle must be
//!            absent after (i.e. actual pruning occurred, not a no-op).
//!   ALPHA / THETA regression — prior cycles unaffected by T12.

use std::collections::BTreeMap;

use neuron_kit::dreaming_cycle::{
    DreamingDaemon, DreamingDaemonState, DreamingPolicy,
    DreamingPolicyStore, InMemoryDreamingPolicyStore,
};
use neuron_kit::rem_cycle_table::RemCycleKind;

// ─── Constants ──────────────────────────────────────────────────────────────

/// Arbitrary base epoch for all tests.
const T0: f64 = 1_700_000_000.0;

// ─── Local fakes ────────────────────────────────────────────────────────────

// BETA is memory-only: run_beta_cycle takes no reader or sink parameters in
// Rust — it operates solely on the daemon's in-memory maps. No fake
// reader or recording sink is needed. The DreamingProposalSink /
// DreamingSubstrateReader traits are imported only for completeness with
// the module's public surface; they are not instantiated in BETA tests.

// ─── Helper: seed a DreamingDaemon with explicit consolidated + co_recall_counts ─

/// Build a daemon and restore the given pre-loaded state into it.
/// The daemon's own `last_beta_run_epoch_secs` starts at None so
/// `beta_due` returns true unconditionally at any `now`.
fn seeded_daemon(
    consolidated: BTreeMap<String, f32>,
    co_recall_counts: BTreeMap<String, u64>,
) -> DreamingDaemon {
    let state = DreamingDaemonState {
        last_timer_fire_epoch_secs: None,
        proposed_keys: vec![],
        last_reindex_vocab: -1,
        consolidated,
        cycle_count: 0,
        co_recall_counts,
        last_theta_run_epoch_secs: None,
        last_beta_run_epoch_secs: None,
        last_omega_run_epoch_secs: None,
    };
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.restore_state(state);
    daemon
}

// ─── Prune semantics ────────────────────────────────────────────────────────

#[test]
fn beta_prunes_below_floor_consolidated_entries_and_retains_above() {
    // Two below-floor entries (0.005 and 0.009 < 0.01 = BETA_PRUNE_FLOOR).
    // Two above-floor entries (0.020 and 0.800 >= 0.01).
    // Key format: "min|max" canonical pair key.
    let below_key_1 = "drawer-a|drawer-b";
    let below_key_2 = "drawer-c|drawer-d";
    let above_key_1 = "drawer-e|drawer-f";
    let above_key_2 = "drawer-g|drawer-h";

    let mut consolidated = BTreeMap::new();
    consolidated.insert(below_key_1.to_string(), 0.005_f32);
    consolidated.insert(below_key_2.to_string(), 0.009_f32);
    consolidated.insert(above_key_1.to_string(), 0.020_f32);
    consolidated.insert(above_key_2.to_string(), 0.800_f32);

    let mut daemon = seeded_daemon(consolidated, BTreeMap::new());
    let report = daemon.run_beta_cycle(T0);

    // Returns None (no proposals, no diary entry).
    assert!(report.is_none());

    // Below-floor entries must be gone (this is the anti-inert assertion:
    // if the prune body is removed and reverted to a no-op, these fail).
    let state = daemon.daemon_state();
    assert!(
        !state.consolidated.contains_key(below_key_1),
        "below-floor entry (0.005) should be pruned by BETA"
    );
    assert!(
        !state.consolidated.contains_key(below_key_2),
        "below-floor entry (0.009) should be pruned by BETA"
    );

    // Above-floor entries must be retained.
    assert!(
        state.consolidated.contains_key(above_key_1),
        "above-floor entry (0.020) must be retained by BETA"
    );
    assert!(
        state.consolidated.contains_key(above_key_2),
        "above-floor entry (0.800) must be retained by BETA"
    );

    // Exact survivor count: 2 of 4 entries remain.
    assert_eq!(
        state.consolidated.len(),
        2,
        "exactly 2 above-floor entries should survive BETA prune"
    );
}

#[test]
fn pre_beta_state_contains_below_floor_entry_confirming_setup() {
    // Companion anti-inert test: the below-floor entry must exist BEFORE
    // the cycle so we know the prune assertion in the test above is meaningful.
    let below_key = "drawer-a|drawer-b";
    let mut consolidated = BTreeMap::new();
    consolidated.insert(below_key.to_string(), 0.005_f32);

    let daemon = seeded_daemon(consolidated, BTreeMap::new());
    let state = daemon.daemon_state();
    assert!(
        state.consolidated.contains_key(below_key),
        "below-floor entry must be present before BETA runs (setup check)"
    );
}

#[test]
fn beta_retains_entry_exactly_at_prune_floor_boundary() {
    // An entry at exactly BETA_PRUNE_FLOOR (0.01) is NOT pruned —
    // the threshold is strictly "below which".
    let at_floor_key = "drawer-x|drawer-y";
    let mut consolidated = BTreeMap::new();
    consolidated.insert(at_floor_key.to_string(), DreamingDaemon::BETA_PRUNE_FLOOR);

    let mut daemon = seeded_daemon(consolidated, BTreeMap::new());
    daemon.run_beta_cycle(T0);

    let state = daemon.daemon_state();
    assert!(
        state.consolidated.contains_key(at_floor_key),
        "entry exactly at BETA_PRUNE_FLOOR must be retained (strictly below is pruned)"
    );
}

#[test]
fn beta_prunes_orphaned_co_recall_counts_and_retains_live_counts() {
    // live_key: consolidated 0.8 (above floor) → survives prune; its count kept.
    // pruned_key: consolidated 0.005 (below floor) → pruned; its count orphaned.
    let live_key   = "drawer-e|drawer-f";
    let pruned_key = "drawer-a|drawer-b";

    let mut consolidated = BTreeMap::new();
    consolidated.insert(live_key.to_string(),   0.800_f32);
    consolidated.insert(pruned_key.to_string(), 0.005_f32);

    let mut co_recall_counts = BTreeMap::new();
    co_recall_counts.insert(live_key.to_string(),   3_u64);
    co_recall_counts.insert(pruned_key.to_string(), 7_u64);

    let mut daemon = seeded_daemon(consolidated, co_recall_counts);
    daemon.run_beta_cycle(T0);

    let state = daemon.daemon_state();

    // Live pair: count retained.
    assert_eq!(
        state.co_recall_counts.get(live_key).copied(),
        Some(3),
        "co-recall count for live pair must be retained by BETA"
    );

    // Orphan pair: count dropped.
    assert!(
        !state.co_recall_counts.contains_key(pruned_key),
        "orphaned co-recall count (consolidated pruned) must be dropped by BETA"
    );
}

// ─── Memory-only constraint ─────────────────────────────────────────────────

#[test]
fn beta_does_not_write_proposals_or_diary_entries() {
    let mut consolidated = BTreeMap::new();
    consolidated.insert("a|b".to_string(), 0.005_f32); // will be pruned
    consolidated.insert("c|d".to_string(), 0.900_f32); // will be kept

    let mut daemon = seeded_daemon(consolidated, BTreeMap::new());

    // BETA takes no sink — by design it cannot write proposals or diary entries.
    // This structural constraint is the test: the function signature accepts
    // no DreamingProposalSink, so any proposal/diary write would be a compile
    // error, not a runtime failure. The test asserts the return type is None.
    let report = daemon.run_beta_cycle(T0);
    assert!(
        report.is_none(),
        "BETA must return None (no proposals, no diary entry)"
    );
}

// ─── Cadence and persistence ────────────────────────────────────────────────

#[test]
fn beta_due_after_7_days() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_beta_cycle(T0);
    // Exactly at the 7-day boundary — due again.
    assert!(
        daemon.beta_due(T0 + DreamingDaemon::BETA_CADENCE_SECS),
        "BETA must be due again at exactly 7 days"
    );
}

#[test]
fn beta_advances_last_run_timestamp() {
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    assert!(daemon.beta_due(T0), "BETA should be due on first call");
    daemon.run_beta_cycle(T0);
    assert_eq!(
        daemon.last_run_epoch_secs("beta"),
        Some(T0),
        "last_beta_run_epoch_secs must be set to now_epoch_secs after the cycle"
    );
}

#[test]
fn last_beta_run_survives_restore_state_d5c() {
    // Simulates: run BETA → save daemon_state → create fresh daemon →
    // restore_state → verify cadence gate uses the persisted timestamp.
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.run_beta_cycle(T0);

    let mut store = InMemoryDreamingPolicyStore::new(None);
    store.save_daemon_state(daemon.daemon_state());

    let mut fresh = DreamingDaemon::new(DreamingPolicy::default());
    fresh.restore_state(store.load_daemon_state().unwrap());

    // 3 days after T0 — not yet 7 days (not due).
    assert!(
        !fresh.beta_due(T0 + 3.0 * 86_400.0),
        "BETA should not be due 3 days after the persisted last run"
    );
    // At the 7-day boundary — due again.
    assert!(
        fresh.beta_due(T0 + DreamingDaemon::BETA_CADENCE_SECS),
        "BETA must be due again after 7 days from the persisted last run"
    );
}

#[test]
fn pruned_state_survives_daemon_state_restore() {
    // After a BETA run, the shrunken consolidated + co_recall_counts survive
    // a daemon_state() → restore_state() round-trip (GC is durable across restarts).
    let pruned_key = "d1|d2";
    let live_key   = "d3|d4";

    let mut consolidated = BTreeMap::new();
    consolidated.insert(pruned_key.to_string(), 0.005_f32);
    consolidated.insert(live_key.to_string(),   0.900_f32);

    let mut co_recall_counts = BTreeMap::new();
    co_recall_counts.insert(pruned_key.to_string(), 3_u64);
    co_recall_counts.insert(live_key.to_string(),   5_u64);

    let mut daemon = seeded_daemon(consolidated, co_recall_counts);
    daemon.run_beta_cycle(T0);

    // Round-trip the state through restore_state.
    let post_beta_state = daemon.daemon_state();
    let mut fresh = DreamingDaemon::new(DreamingPolicy::default());
    fresh.restore_state(post_beta_state);

    let state = fresh.daemon_state();

    // Pruned entry must not reappear.
    assert!(
        !state.consolidated.contains_key(pruned_key),
        "pruned consolidated entry must not reappear after restore"
    );
    assert!(
        !state.co_recall_counts.contains_key(pruned_key),
        "orphaned co-recall count must not reappear after restore"
    );

    // Live entry must survive.
    assert!(
        state.consolidated.contains_key(live_key),
        "live consolidated entry must survive restore"
    );
    assert_eq!(
        state.co_recall_counts.get(live_key).copied(),
        Some(5),
        "live co-recall count must survive restore"
    );
}

// ─── ALPHA / THETA regression ───────────────────────────────────────────────

#[test]
fn beta_does_not_reset_theta_last_run() {
    // BETA must not modify last_theta_run_epoch_secs.
    let state = DreamingDaemonState {
        last_timer_fire_epoch_secs: None,
        proposed_keys: vec![],
        last_reindex_vocab: -1,
        consolidated: BTreeMap::new(),
        cycle_count: 0,
        co_recall_counts: BTreeMap::new(),
        last_theta_run_epoch_secs: Some(T0),
        last_beta_run_epoch_secs: None,
        last_omega_run_epoch_secs: None,
    };
    let mut daemon = DreamingDaemon::new(DreamingPolicy::default());
    daemon.restore_state(state);

    // Run BETA at T0 + 3 days.
    daemon.run_beta_cycle(T0 + 3.0 * 86_400.0);

    // THETA last-run must be unchanged.
    assert_eq!(
        daemon.last_run_epoch_secs("theta"),
        Some(T0),
        "BETA must not modify last_theta_run_epoch_secs"
    );
}

#[test]
fn rem_cycle_table_beta_entry_is_present_and_correct() {
    use neuron_kit::rem_cycle_table::rem_cycle_table;
    let table = rem_cycle_table();
    let beta = &table[2];
    assert_eq!(beta.kind, RemCycleKind::Beta);
    assert_eq!(beta.name, "REM-BETA");
    assert_eq!(beta.cadence_secs, DreamingDaemon::BETA_CADENCE_SECS);
}
