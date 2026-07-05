//! governor_hardening_tests.rs — planned-hardening cap tests (secfix/punt-neuron).
//!
//! Rust parity of Swift `GraphCentralityCapTests.swift`.
//!
//! Findings covered:
//!   • `KGFACT_CLIQUE_CAP` constant value (50) — parity with Swift.
//!   • KGFact subject-group cap in `graph_topology`: 51 drawers sharing one
//!     subject produce ≤ 1 225 kgFact edges (not 1 275).
//!   • `POOL_REDUCE_FILE_CAP` constant value (500) — parity with Swift.
//!   • Pool-reduce bounded drain: over the cap the tick FIRES and drains a
//!     bounded batch (≤ cap) — it never defers (the prior defer-when-over-cap
//!     behaviour deadlocked, growing the pool without bound).

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use genius_locus_kit::coordinator::EstateCoordinator;
use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;

use neuron_kit::autonomic_governor::AutonomicGovernor;
use neuron_kit::topology_analysis::{
    graph_topology, TopologyDrawerInput, TopologyFactInput,
    KGFACT_CLIQUE_CAP,
};
use neuron_kit::autonomic_governor::POOL_REDUCE_FILE_CAP;

// ──────────────────────────────────────────────────────────────────────────────
// Infrastructure
// ──────────────────────────────────────────────────────────────────────────────

fn make_governor_with_pool(pool_dir: PathBuf, pool_table: PathBuf) -> AutonomicGovernor {
    let store: Arc<dyn LocusDrawerStore> =
        Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(Arc::clone(&store), OwnerCredentials::new("hardening-test"), 0, 100)
        .expect("open");
    let coord = Arc::new(Mutex::new(coord));

    AutonomicGovernor::new_for_testing_with_pool(
        coord,
        handle,
        store,
        u64::MAX,   // topology cadence: never fires
        None,       // no topology sink
        0,          // pool reduce cadence: 0 = fire every tick
        pool_dir,
        pool_table,
    )
}

/// Build a live `TopologyDrawerInput` with the given id.
fn live_drawer(id: &str) -> TopologyDrawerInput {
    TopologyDrawerInput {
        id: id.to_string(),
        udc_code: String::new(),
        filed_at: 1_700_000_000,
        event_time: 1_700_000_000,
        tombstoned: false,
        tombstoned_at: None,
    }
}

/// Build a `TopologyFactInput` linking `drawer_id` to `subject`.
fn fact(subject: &str, drawer_id: &str) -> TopologyFactInput {
    TopologyFactInput {
        subject: subject.to_string(),
        source_drawer_id: drawer_id.to_string(),
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Cap constant assertions — parity with Swift
// ──────────────────────────────────────────────────────────────────────────────

/// `KGFACT_CLIQUE_CAP` must be 50 — parity with Swift `NeuronKit.kgFactCliqueCap`.
#[test]
fn kgfact_clique_cap_is_50() {
    assert_eq!(KGFACT_CLIQUE_CAP, 50,
        "KGFACT_CLIQUE_CAP must be 50, matching NeuronKit.kgFactCliqueCap in Swift");
}

/// `POOL_REDUCE_FILE_CAP` must be 500 — parity with Swift `poolReduceFileCap`.
#[test]
fn pool_reduce_file_cap_is_500() {
    assert_eq!(POOL_REDUCE_FILE_CAP, 500,
        "POOL_REDUCE_FILE_CAP must be 500, matching poolReduceFileCap in Swift");
}

// ──────────────────────────────────────────────────────────────────────────────
// KGFact clique cap — graph_topology
// ──────────────────────────────────────────────────────────────────────────────

/// With 51 drawers all sharing one subject the uncapped pair count would be
/// 51×50/2 = 1 275. The cap truncates to 50, producing 50×49/2 = 1 225 kgFact
/// edges. All 51 drawers remain as nodes.
#[test]
fn graph_topology_caps_kgfact_group_at_50_drawers() {
    let over_count = KGFACT_CLIQUE_CAP + 1;  // 51

    let drawers: Vec<TopologyDrawerInput> = (0..over_count)
        .map(|i| live_drawer(&format!("d{i}")))
        .collect();
    let facts: Vec<TopologyFactInput> = drawers
        .iter()
        .map(|d| fact("generic-subject", &d.id))
        .collect();

    // estate/ts: explicit sentinels — hardening tests have no estate context.
    let topo = graph_topology(&drawers, &[], &facts, "", 0.0);

    // All 51 drawers appear as nodes.
    assert_eq!(
        topo.nodes.len(), over_count,
        "all {over_count} drawers must appear as nodes"
    );

    // kgFact edges are capped at 50*(50-1)/2 = 1225.
    let max_expected = KGFACT_CLIQUE_CAP * (KGFACT_CLIQUE_CAP - 1) / 2;
    let kg_edge_count = topo.edges.iter().filter(|e| e.edge_type == "kgFact").count();
    assert!(
        kg_edge_count <= max_expected,
        "kgFact edge count {kg_edge_count} must be ≤ {max_expected} (cap 50, no uncapped 1275)"
    );
}

/// Exactly 50 drawers on one subject must NOT be truncated — all 50×49/2 = 1225
/// pairs must be produced (cap is inclusive-upper, not exclusive).
#[test]
fn graph_topology_does_not_cap_at_limit_boundary() {
    let count = KGFACT_CLIQUE_CAP;  // 50

    let drawers: Vec<TopologyDrawerInput> = (0..count)
        .map(|i| live_drawer(&format!("d{i}")))
        .collect();
    let facts: Vec<TopologyFactInput> = drawers
        .iter()
        .map(|d| fact("boundary-subject", &d.id))
        .collect();

    // estate/ts: explicit sentinels — hardening tests have no estate context.
    let topo = graph_topology(&drawers, &[], &facts, "", 0.0);

    let expected = count * (count - 1) / 2;  // 1225
    let kg_edge_count = topo.edges.iter().filter(|e| e.edge_type == "kgFact").count();
    assert_eq!(
        kg_edge_count, expected,
        "exactly {count} drawers must produce exactly {expected} kgFact pairs (no cap at limit)"
    );
}

// ──────────────────────────────────────────────────────────────────────────────
// Pool-reduce file-count back-pressure
// ──────────────────────────────────────────────────────────────────────────────

/// Over the cap the tick must FIRE and drain a bounded batch (≤ cap) — never
/// defer. The prior "defer when > cap" behaviour deadlocked: over cap, the very
/// reduce that shrinks the pool never ran, so the pool grew without bound. With
/// 501 submissions, one tick drains exactly the cap (500), leaving one for the
/// next tick.
#[test]
fn pool_reduce_drains_bounded_batch_when_over_cap() {
    let tmp = std::env::temp_dir()
        .join(format!("neuronkit-pool-cap-{}", uuid_v4_simple()));
    std::fs::create_dir_all(&tmp).expect("create tmp dir");

    // 501 valid submissions (one above the cap), named so filename order is
    // chronological — the reducer drains oldest-first.
    let file_count = POOL_REDUCE_FILE_CAP + 1;
    for i in 0..file_count {
        let body = format!(
            r#"{{"table_version":"1.0.0","platform":"test","tagger_version":"1","entries":[{{"token":"tok{i}","tag":"NOUN"}}]}}"#
        );
        std::fs::write(tmp.join(format!("pool_{i:04}.json")), body).expect("write submission");
    }

    let table = tmp.join("table.json");
    let mut gov = make_governor_with_pool(tmp.clone(), table);

    let report = gov.tick(SystemTime::now());

    // Remaining top-level pool_*.json submissions (drained ones moved to the
    // archive/ or quarantine/ subdirs).
    let remaining = std::fs::read_dir(&tmp)
        .expect("read_dir")
        .filter_map(|e| e.ok())
        .filter(|e| {
            let n = e.file_name();
            let n = n.to_string_lossy();
            e.path().is_file() && n.starts_with("pool_") && n.ends_with(".json")
        })
        .count();

    // Cleanup before assertions so a failed assert doesn't leave files.
    let _ = std::fs::remove_dir_all(&tmp);

    assert!(
        report.pool_reduce_fired,
        "over-cap must FIRE a bounded drain, not defer — the deadlock is fixed"
    );
    assert_eq!(
        remaining,
        file_count - POOL_REDUCE_FILE_CAP,
        "one tick drains exactly the cap ({POOL_REDUCE_FILE_CAP}); the remainder stays for the next tick"
    );
}

/// When the pool directory is empty the reduce should fire normally (returning
/// noop). `pool_reduce_fired` must be true; `table_swapped` must be false (noop).
#[test]
fn pool_reduce_fires_normally_with_empty_dir() {
    let tmp = std::env::temp_dir()
        .join(format!("neuronkit-pool-empty-{}", uuid_v4_simple()));
    std::fs::create_dir_all(&tmp).expect("create tmp dir");

    let table = tmp.join("table.json");
    let mut gov = make_governor_with_pool(tmp.clone(), table);

    let t0 = SystemTime::now();
    let report = gov.tick(t0);

    let _ = std::fs::remove_dir_all(&tmp);

    assert!(
        report.pool_reduce_fired,
        "pool_reduce_fired must be true when pool dir is empty (reduce fires, returns noop)"
    );
    assert!(
        !report.table_swapped,
        "table_swapped must be false on a noop reduce (empty pool)"
    );
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

/// Generate a simple random-looking string for unique temp directory names
/// without pulling in the `uuid` crate in tests.
fn uuid_v4_simple() -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .hash(&mut h);
    std::thread::current().id().hash(&mut h);
    format!("{:016x}", h.finish())
}
