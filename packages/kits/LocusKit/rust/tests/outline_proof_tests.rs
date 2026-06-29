//! Five-level ancestor chain proof: flat drawers wired into a deep
//! outline via `Parent` tunnels, demonstrating that the containment
//! tree (parent_node_id) and the outline graph (typed parent edges)
//! are fully orthogonal.  ADR-017 §11 / NT-L5 Part 3.
//!
//! Runs against both InMemory and SQLite backends.

use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_operational::TunnelKind;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;
const LATER: i64 = 1_700_000_100;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Deterministic test UUID from a short label.
fn tid(label: &str) -> String {
    let mut bytes = [0u8; 16];
    let mut h: u64 = 0xcbf29ce484222325;
    for (i, b) in label.bytes().enumerate() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i % 16] ^= (h & 0xff) as u8;
        bytes[(i + 7) % 16] ^= ((h >> 32) & 0xff) as u8;
    }
    #[allow(clippy::needless_range_loop)]
    for i in 0..16 {
        h ^= bytes[i] as u64;
        h = h.wrapping_mul(0x100000001b3);
        bytes[i] = bytes[i].wrapping_add((h & 0xff) as u8);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes).to_string()
}

fn sample_drawer(id: &str) -> Drawer {
    let resolved = tid(id);
    let parent_id = tid("node-w-r");
    let mut d = Drawer::new(&resolved, &format!("content-{}", id), &parent_id, "bilby", NOW, "minilm-v6");
    d.udc_code = "001".to_string();
    d
}

fn parent_tunnel(child: &str, parent: &str, order_key: f64, now: i64) -> Tunnel {
    let mut t = Tunnel::new(
        Uuid::new_v4().to_string(),
        "w".to_string(), "r".to_string(),
        "w".to_string(), "r".to_string(),
        "parent".to_string(),
        "bilby".to_string(),
        now,
    );
    t.kind = TunnelKind::Parent;
    t.source_drawer_id = Some(tid(child));
    t.target_drawer_id = Some(tid(parent));
    t.order_key = Some(order_key);
    t
}

/// RAII guard that deletes SQLite files on drop.
struct TempDb {
    path: String,
}
impl TempDb {
    fn new() -> Self {
        let name = format!("locus_outline_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir().join(name).to_string_lossy().into_owned();
        TempDb { path }
    }
}
impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn open_inmemory() -> InMemoryDrawerStore {
    InMemoryDrawerStore::new(NOW, None).unwrap()
}

fn open_sqlite(path: &str) -> SqliteDrawerStore {
    SqliteDrawerStore::from_path(path, NOW, None, 5.0).unwrap()
}

// ---------------------------------------------------------------------------
// Generic test runner — exercises both backends
// ---------------------------------------------------------------------------

fn run_five_level_ancestor_chain(store: &dyn DrawerStore) {
    for id in &["a", "b", "c", "d", "e"] {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }

    // Wire: B→A, C→B, D→C, E→D
    store.add_tunnel(&parent_tunnel("b", "a", 1.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("c", "b", 1.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("d", "c", 1.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("e", "d", 1.0, NOW)).unwrap();

    // Walk ancestors of E — expect [A, B, C, D] root-first.
    let ancestors = store.outline_ancestors(&tid("e")).unwrap();
    assert_eq!(ancestors.len(), 4, "expected 4 ancestors for E");
    assert_eq!(ancestors[0], tid("a"), "first ancestor should be root A");
    assert_eq!(ancestors[1], tid("b"));
    assert_eq!(ancestors[2], tid("c"));
    assert_eq!(ancestors[3], tid("d"));
}

fn run_root_has_no_ancestors(store: &dyn DrawerStore) {
    store.add_drawer(&sample_drawer("root"), NOW).unwrap();
    let ancestors = store.outline_ancestors(&tid("root")).unwrap();
    assert!(ancestors.is_empty(), "root should have no ancestors");
}

fn run_children_sorted_by_order_key(store: &dyn DrawerStore) {
    for id in &["p", "x", "y", "z"] {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }

    // Wire: x→p (3.0), y→p (1.0), z→p (2.0)
    store.add_tunnel(&parent_tunnel("x", "p", 3.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("y", "p", 1.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("z", "p", 2.0, NOW)).unwrap();

    let children = store.outline_children(&tid("p")).unwrap();
    assert_eq!(children.len(), 3);
    // Sorted: y(1.0), z(2.0), x(3.0)
    assert_eq!(children[0].source_drawer_id.as_deref(), Some(tid("y").as_str()));
    assert_eq!(children[1].source_drawer_id.as_deref(), Some(tid("z").as_str()));
    assert_eq!(children[2].source_drawer_id.as_deref(), Some(tid("x").as_str()));
}

fn run_leaf_has_no_children(store: &dyn DrawerStore) {
    store.add_drawer(&sample_drawer("leaf"), NOW).unwrap();
    let children = store.outline_children(&tid("leaf")).unwrap();
    assert!(children.is_empty());
}

fn run_reparent_moves_child(store: &dyn DrawerStore) {
    for id in &["a", "b", "c"] {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }

    // Initial: B→A, C→B
    store.add_tunnel(&parent_tunnel("b", "a", 1.0, NOW)).unwrap();
    store.add_tunnel(&parent_tunnel("c", "b", 1.0, NOW)).unwrap();

    let before = store.outline_ancestors(&tid("c")).unwrap();
    assert_eq!(before, vec![tid("a"), tid("b")]);

    // Reparent C under A directly.
    store.reparent_drawer(&tid("c"), Some(&tid("a")), 2.0, "w", "r", "bilby", LATER).unwrap();

    let after = store.outline_ancestors(&tid("c")).unwrap();
    assert_eq!(after, vec![tid("a")]);

    // A's children should include both B and C.
    let a_children = store.outline_children(&tid("a")).unwrap();
    let child_ids: Vec<Option<&str>> = a_children.iter().map(|t| t.source_drawer_id.as_deref()).collect();
    assert!(child_ids.contains(&Some(tid("b").as_str())));
    assert!(child_ids.contains(&Some(tid("c").as_str())));
}

fn run_reparent_to_root(store: &dyn DrawerStore) {
    for id in &["a", "b"] {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }
    store.add_tunnel(&parent_tunnel("b", "a", 1.0, NOW)).unwrap();
    assert_eq!(store.outline_ancestors(&tid("b")).unwrap(), vec![tid("a")]);

    store.reparent_drawer(&tid("b"), None, 0.0, "w", "r", "bilby", LATER).unwrap();
    assert!(store.outline_ancestors(&tid("b")).unwrap().is_empty());
}

fn run_one_parent_per_child(store: &dyn DrawerStore) {
    for id in &["a", "b", "c"] {
        store.add_drawer(&sample_drawer(id), NOW).unwrap();
    }
    store.add_tunnel(&parent_tunnel("c", "a", 1.0, NOW)).unwrap();

    // Second parent edge for C should fail.
    let result = store.add_tunnel(&parent_tunnel("c", "b", 2.0, NOW));
    assert!(result.is_err(), "expected error for second parent edge");
    match result.unwrap_err() {
        LocusKitError::InvalidContent(_) => {}
        other => panic!("expected InvalidContent, got {:?}", other),
    }
}

// ---------------------------------------------------------------------------
// InMemory tests
// ---------------------------------------------------------------------------

#[test]
fn inmemory_five_level_ancestor_chain() {
    run_five_level_ancestor_chain(&open_inmemory());
}

#[test]
fn inmemory_root_has_no_ancestors() {
    run_root_has_no_ancestors(&open_inmemory());
}

#[test]
fn inmemory_children_sorted_by_order_key() {
    run_children_sorted_by_order_key(&open_inmemory());
}

#[test]
fn inmemory_leaf_has_no_children() {
    run_leaf_has_no_children(&open_inmemory());
}

#[test]
fn inmemory_reparent_moves_child() {
    run_reparent_moves_child(&open_inmemory());
}

#[test]
fn inmemory_reparent_to_root() {
    run_reparent_to_root(&open_inmemory());
}

#[test]
fn inmemory_one_parent_per_child() {
    run_one_parent_per_child(&open_inmemory());
}

// ---------------------------------------------------------------------------
// SQLite tests
// ---------------------------------------------------------------------------

#[test]
fn sqlite_five_level_ancestor_chain() {
    let db = TempDb::new();
    run_five_level_ancestor_chain(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_root_has_no_ancestors() {
    let db = TempDb::new();
    run_root_has_no_ancestors(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_children_sorted_by_order_key() {
    let db = TempDb::new();
    run_children_sorted_by_order_key(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_leaf_has_no_children() {
    let db = TempDb::new();
    run_leaf_has_no_children(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_reparent_moves_child() {
    let db = TempDb::new();
    run_reparent_moves_child(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_reparent_to_root() {
    let db = TempDb::new();
    run_reparent_to_root(&open_sqlite(db.path.as_str()));
}

#[test]
fn sqlite_one_parent_per_child() {
    let db = TempDb::new();
    run_one_parent_per_child(&open_sqlite(db.path.as_str()));
}

// ---------------------------------------------------------------------------
// P5-secfix: Arc<dyn DrawerStore> forwards the six previously-missing methods.
//
// The six methods (living_successor_in_lineage, outline_children,
// outline_ancestors, reparent_drawer, count_drawer_rows, wipe_all_content)
// had default trap implementations in the trait (returning DatabaseUnavailable)
// but were absent from the Arc blanket impl. Any caller that held an
// Arc<dyn DrawerStore> always hit the trap — never the concrete backend.
// These tests call each of the six methods via Arc and verify the concrete
// InMemory backend actually runs.
// ---------------------------------------------------------------------------

#[test]
fn arc_dyn_outline_and_wipe_forwards_reach_concrete_backend() {
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use std::sync::Arc;

    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());

    // Seed two drawers and a parent tunnel.
    store.add_drawer(&sample_drawer("p5-root"), NOW).unwrap();
    store.add_drawer(&sample_drawer("p5-child"), NOW).unwrap();
    store.add_tunnel(&parent_tunnel("p5-child", "p5-root", 1.0, NOW)).unwrap();

    // P5: outline_children — must return the child, not DatabaseUnavailable.
    let children = store.outline_children(&tid("p5-root"))
        .expect("P5-secfix: outline_children via Arc must delegate to concrete backend");
    assert_eq!(children.len(), 1, "one child expected; P5 Arc forward broken if 0");

    // P5: outline_ancestors — must return the root.
    let ancestors = store.outline_ancestors(&tid("p5-child"))
        .expect("P5-secfix: outline_ancestors via Arc must delegate to concrete backend");
    assert_eq!(ancestors.len(), 1, "one ancestor expected; P5 Arc forward broken if 0");

    // P5: reparent_drawer — move child to outline root (None parent).
    store.reparent_drawer(&tid("p5-child"), None, 0.0, "w", "r", "bilby", LATER)
        .expect("P5-secfix: reparent_drawer via Arc must delegate to concrete backend");
    let after = store.outline_ancestors(&tid("p5-child")).unwrap();
    assert!(after.is_empty(), "after reparent to root, ancestors must be empty");

    // P5: count_drawer_rows — must return 2, not DatabaseUnavailable.
    let count = store.count_drawer_rows()
        .expect("P5-secfix: count_drawer_rows via Arc must delegate to concrete backend");
    assert_eq!(count, 2, "two drawers were added; P5 Arc forward broken if error");

    // P5: wipe_all_content — must succeed, not DatabaseUnavailable.
    store.wipe_all_content()
        .expect("P5-secfix: wipe_all_content via Arc must delegate to concrete backend");

    // P5: living_successor_in_lineage — no living successor (no revive wired); must
    // return Ok(None), not Err(DatabaseUnavailable).
    let lineage_id = tid("p5-root");
    let successor = store.living_successor_in_lineage(&lineage_id, &tid("nobody"))
        .expect("P5-secfix: living_successor_in_lineage via Arc must delegate to concrete backend");
    // The two seeded drawers share no explicit lineage; None is the correct result.
    assert!(successor.is_none(), "no revive chain seeded; successor must be None");
}
