//! Integration tests for `SqliteDrawerStore`.
//!
//! ## Coverage strategy
//!
//! Two categories:
//!
//! 1. **Parity tests** — same behavioural assertions as the
//!    `InMemoryDrawerStore` unit tests (`drawer_store_inmemory.rs`).
//!    These run `SqliteDrawerStore` through the same scenarios to
//!    confirm both backends produce identical observable behaviour at
//!    the `DrawerStore` surface.
//!
//! 2. **SQLite-specific tests** — reopen-from-disk round-trip. Write,
//!    drop the store, reopen the same path, confirm rows survive. This
//!    is the one property `InMemoryDrawerStore` cannot exhibit.
//!
//! Every test constructs a fresh `SqliteDrawerStore` over a
//! `tempfile::NamedTempFile`-based path so tests are isolated and the
//! database file is deleted on drop. No `tempfile` crate is needed —
//! we use a deterministic path under `std::env::temp_dir()` with a
//! random suffix from `uuid::Uuid::new_v4()`, dropped via the guard
//! struct defined below.

use locus_kit::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};
use locus_kit::diary_entry::DiaryEntry;
use locus_kit::drawer::Drawer;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate::Estate;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;
use locus_kit::error::LocusKitError;
use locus_kit::kg_fact::KGFact;
use locus_kit::manifest::ManifestKey;
use locus_kit::node_store::NodeStore;
use locus_kit::recall_trace_item::RecallTraceItem;
use locus_kit::summaries::WingSummary;
use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_operational::TunnelKind;
use substrate_lib::row_state::RowVerb;
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

/// RAII guard that deletes the SQLite database file (and its WAL/SHM
/// siblings) when dropped. Keeps each test's disk footprint clean.
struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_sqlite_test_{}.db", Uuid::new_v4().simple());
        let path = std::env::temp_dir()
            .join(name)
            .to_string_lossy()
            .into_owned();
        TempDb { path }
    }

    fn path(&self) -> &str {
        &self.path
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        // Remove the main file and WAL/SHM companions produced by SQLite.
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

/// Open a fresh `SqliteDrawerStore` at the given path.
fn open_sqlite(path: &str) -> SqliteDrawerStore {
    SqliteDrawerStore::from_path(path, NOW, None, 5.0).unwrap()
}

/// Deterministic UUID from a short label. Mirrors `tid()` in the
/// `InMemoryDrawerStore` unit tests so IDs are consistent between the
/// two test suites (e.g., `tid("d1")` yields the same UUID string here
/// as in `drawer_store_inmemory::tests`).
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
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    Uuid::from_bytes(bytes).to_string()
}

/// Build a Drawer with all required fields populated.
/// For tests that don't need node-tree resolution (e.g. bitmap-only tests),
/// uses a deterministic parent_node_id derived from wing+room.
fn sample_drawer(id: &str, wing: &str, room: &str, content: &str) -> Drawer {
    let resolved = match Uuid::parse_str(id) {
        Ok(_) => id.to_string(),
        Err(_) => tid(id),
    };
    let parent_id = tid(&format!("node-{}-{}", wing, room));
    let mut d = Drawer::new(&resolved, content, &parent_id, "alice", NOW, "test-v1");
    d.udc_code = "001".to_string();
    d
}

/// Seed a node tree for tests: root → wing (depth=1) → room (depth=2).
/// Returns the room node ID string.
fn seed_node_tree(store: &SqliteDrawerStore, wing: &str, room: &str) -> String {
    let storage = store.storage().expect("storage must be available");
    let ns = NodeStore::new(storage, None);
    let root = ns.create_root("Estate", NOW).unwrap();
    let wing_node = ns.create_node(wing, root.id, NOW).unwrap();
    let room_node = ns.create_node(room, wing_node.id, NOW).unwrap();
    room_node.id.to_string()
}

/// Seed nodes and create a drawer whose parent_node_id points to the
/// real room node in the tree. Use for tests that exercise node-tree
/// resolution (drawersInWing, list_wings, recall, etc.).
fn sample_drawer_with_nodes(
    store: &SqliteDrawerStore,
    id: &str,
    wing: &str,
    room: &str,
    content: &str,
) -> Drawer {
    let room_node_id = seed_node_tree(store, wing, room);
    let resolved = match Uuid::parse_str(id) {
        Ok(_) => id.to_string(),
        Err(_) => tid(id),
    };
    let mut d = Drawer::new(&resolved, content, &room_node_id, "alice", NOW, "test-v1");
    d.udc_code = "001".to_string();
    d
}

// ---------------------------------------------------------------------------
// § 1 — Manifest defaults (parity with InMemoryDrawerStore)
// ---------------------------------------------------------------------------

#[test]
fn manifest_defaults_populated_on_first_open() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let m = store.read_manifest().unwrap();
    assert_eq!(m.manifest_version, "1.0");
    assert_eq!(m.bitmap_layout_version, "v1.0");
    assert_eq!(m.provenance_bitmap_version, "v1.0");
    assert_eq!(m.active_storage_mode, 8);
    assert_eq!(m.zoom_window_high, 99);
    assert!(Uuid::parse_str(&m.estate_uuid).is_ok());
    assert!(m.federation_group_id.is_none());
}

#[test]
fn set_meta_and_get_meta_round_trip() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    store
        .set_meta(ManifestKey::EstateName.as_str(), "lab")
        .unwrap();
    assert_eq!(store.read_manifest().unwrap().estate_name, "lab");
    assert_eq!(
        store
            .get_meta(ManifestKey::EstateName.as_str())
            .unwrap()
            .as_deref(),
        Some("lab")
    );
}

/// The public `Estate` consumer key-value surface (`set_meta`/`meta`) round-trips
/// a namespaced value and survives reopen. This is the substrate-owned persistence
/// primitive upper layers (e.g. NeuronKit's daemons) use instead of a host-owned
/// store. Mirrors Swift `metaRoundTripsAcrossReopen`.
#[test]
fn estate_meta_round_trips_across_reopen() {
    use locus_kit::estate::Estate;
    use locus_kit::estate_types::OwnerCredentials;
    use std::sync::Arc;

    let db = TempDb::new();
    let key = "neuronkit.dreaming.policy";
    let value = r#"{"minConfidence":0.7}"#;

    {
        let store = Arc::new(open_sqlite(db.path()));
        let estate = Estate::open(store, OwnerCredentials::new("owner")).unwrap();
        assert_eq!(estate.meta(key).unwrap(), None, "absent before first write");
        estate.set_meta(key, value).unwrap();
        assert_eq!(estate.meta(key).unwrap().as_deref(), Some(value));
    }
    // Reopen the same database — the value persisted.
    let store = Arc::new(open_sqlite(db.path()));
    let estate = Estate::open(store, OwnerCredentials::new("owner")).unwrap();
    assert_eq!(
        estate.meta(key).unwrap().as_deref(),
        Some(value),
        "consumer manifest value must survive a restart"
    );
}

// ---------------------------------------------------------------------------
// § 2 — Drawer CRUD (parity)
// ---------------------------------------------------------------------------

#[test]
fn add_drawer_then_get_round_trips() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer_with_nodes(&store, "d1", "w", "kitchen", "hello");
    store.add_drawer(&d, NOW).unwrap();
    let back = store.get_drawer(&tid("d1")).unwrap().unwrap();
    assert_eq!(back.content, "hello");
    // wing/room resolved from node tree, not stored on Drawer.
    let names = store.resolve_node_names(&[back.parent_node_id.clone()]).unwrap();
    let (wing, room) = names.get(&back.parent_node_id).expect("node must resolve");
    assert_eq!(wing, "w");
    assert_eq!(room, "kitchen");
}

#[test]
fn add_drawer_rejects_empty_parent_node_id() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d = sample_drawer("d1", "w", "kitchen", "hello");
    d.parent_node_id = String::new();
    let err = store.add_drawer(&d, NOW).unwrap_err();
    match err {
        LocusKitError::InvalidContent(msg) => assert!(msg.contains("parent_node_id")),
        other => panic!("expected InvalidContent, got {:?}", other),
    }
}

#[test]
fn add_drawer_rejects_secret_plus_exportable() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d = sample_drawer("d-bad", "w", "kitchen", "secret stuff");
    // I-22: secret sensitivity + public exportability is forbidden.
    // sensitivity nibble at bits 6-11, exportability nibble at bits 12-17
    // per cookbook §2.3 adjective bitmap layout.
    d.adjective_bitmap = (AdjectiveSensitivity::Secret.raw_value() << 6)
        | (AdjectiveExportability::Public.raw_value() << 12);
    let err = store.add_drawer(&d, NOW).unwrap_err();
    match err {
        LocusKitError::InvalidContent(msg) => {
            assert!(
                msg.contains("I-22"),
                "expected I-22 gate rejection, got: {}",
                msg
            );
        }
        other => panic!("expected InvalidContent (gate rejection), got {:?}", other),
    }
    assert!(store.get_drawer(&tid("d-bad")).unwrap().is_none());
}

#[test]
fn drawers_in_wing_excludes_tombstoned_and_orders_by_filed_at() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d1 = sample_drawer_with_nodes(&store, "d1", "w", "k", "first");
    d1.filed_at = NOW + 10;
    let mut d2 = sample_drawer_with_nodes(&store, "d2", "w", "k", "second");
    d2.filed_at = NOW + 20;
    // d3 is inserted with a tombstonedAt already set — the schema
    // accepts this (it's how restore-and-read-tombstoned works). The
    // drawers_in_wing predicate filters IsNull(tombstonedAt).
    let mut d3 = sample_drawer_with_nodes(&store, "d3", "w", "k", "tombstoned");
    d3.filed_at = NOW + 30;
    d3.tombstoned_at = Some(NOW + 31);
    store.add_drawer(&d1, NOW).unwrap();
    store.add_drawer(&d2, NOW).unwrap();
    store.add_drawer(&d3, NOW).unwrap();
    let rows = store.drawers_in_wing("w").unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].id, tid("d1"));
    assert_eq!(rows[1].id, tid("d2"));
}

#[test]
fn all_drawers_includes_tombstoned() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d1 = sample_drawer("d1", "w", "k", "live");
    d1.filed_at = NOW + 10;
    let mut d2 = sample_drawer("d2", "w", "k", "dead");
    d2.filed_at = NOW + 20;
    d2.tombstoned_at = Some(NOW + 21);
    store.add_drawer(&d1, NOW).unwrap();
    store.add_drawer(&d2, NOW).unwrap();
    let all = store.all_drawers().unwrap();
    assert_eq!(all.len(), 2);
}

#[test]
fn drawer_ids_returns_every_id() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    store
        .add_drawer(&sample_drawer("a", "w", "k", "one"), NOW)
        .unwrap();
    store
        .add_drawer(&sample_drawer("b", "w", "k", "two"), NOW)
        .unwrap();
    let mut ids = store.drawer_ids().unwrap();
    ids.sort();
    let mut want = vec![tid("a"), tid("b")];
    want.sort();
    assert_eq!(ids, want);
}

// ---------------------------------------------------------------------------
// § 3 — Supersession cascade (parity)
// ---------------------------------------------------------------------------

#[test]
fn supersession_cascade_flips_predecessor_state_and_files_tunnel() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let lineage = Uuid::new_v4();
    let mut prior = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "v1");
    prior.lineage_id = lineage;
    prior.filed_at = NOW;
    let mut next = sample_drawer("22222222-2222-4222-8222-222222222222", "w", "k", "v2");
    next.lineage_id = lineage;
    next.filed_at = NOW + 100;

    store.add_drawer(&prior, NOW).unwrap();
    store.add_drawer(&next, NOW + 100).unwrap();

    // Predecessor state nibble flipped to Superseded (raw 16).
    let p_back = store
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(
        p_back.adjective_bitmap & 0x3F,
        State::Superseded.raw_value()
    );

    // Directional supersedes tunnel exists from new → prior.
    let tunnel = store
        .get_tunnel(&format!(
            "supersedes:{}:{}",
            "22222222-2222-4222-8222-222222222222", "11111111-1111-4111-8111-111111111111"
        ))
        .unwrap()
        .unwrap();
    assert_eq!(tunnel.kind, TunnelKind::Supersedes);
}

// ---------------------------------------------------------------------------
// § 4 — Bitmap mutation paths (parity)
// ---------------------------------------------------------------------------

#[test]
fn mutate_state_validates_and_preserves_upper_axes() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
    // Trust at bits 18-23; Canonical (raw 3) satisfies S-1.
    d.adjective_bitmap = Trust::Canonical.raw_value() << 18;
    store.add_drawer(&d, NOW).unwrap();
    store
        .mutate_state(
            "11111111-1111-4111-8111-111111111111",
            State::Contested,
            RowVerb::Contest,
            "alice",
            None,
            NOW + 1,
        )
        .unwrap();
    let back = store
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    // Lower 6 bits = state field; upper axes preserved.
    assert_eq!(back.adjective_bitmap & 0x3F, State::Contested.raw_value());
    assert_eq!(
        (back.adjective_bitmap >> 18) & 0x3F,
        Trust::Canonical.raw_value()
    );
}

#[test]
fn mutate_state_rejects_illegal_transition() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
    store.add_drawer(&d, NOW).unwrap();
    let err = store
        .mutate_state(
            "11111111-1111-4111-8111-111111111111",
            State::Accepted,
            RowVerb::Observe,
            "alice",
            None,
            NOW + 1,
        )
        .unwrap_err();
    match err {
        LocusKitError::InvalidContent(msg) => {
            // After the Display fix, the gate uses English names rather than
            // the Debug variant name "IllegalTransition".
            assert!(
                msg.contains("illegal state transition"),
                "expected gate-rejection text, got: {}",
                msg
            );
        }
        other => panic!("expected InvalidContent, got {:?}", other),
    }
}

#[test]
fn mutate_operational_persists() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
    store.add_drawer(&d, NOW).unwrap();
    store
        .mutate_operational(
            "11111111-1111-4111-8111-111111111111",
            0x100,
            "alice",
            None,
            NOW + 1,
        )
        .unwrap();
    let back = store
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(back.operational_bitmap, 0x100);
}

#[test]
fn expunge_gated_tombstones_zeros_content_sets_bit_26() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer(
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "w",
        "k",
        "content-aaaa",
    );
    store.add_drawer(&d, NOW).unwrap();
    // seal_audit: true — direct-caller path, audit appended immediately.
    store
        .expunge_gated(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "alice",
            Some("GDPR"),
            NOW + 500,
            true,
        )
        .unwrap();
    let after = store
        .get_drawer("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        .unwrap()
        .unwrap();
    assert_eq!(after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
    assert_eq!(after.content, "");
    assert!(after.tombstoned_at.is_some());
    // bit 26 = dreaming_recalc_required — must be set on tombstone.
    assert_ne!(after.adjective_bitmap & (1 << 26), 0);
}

/// node-tree integrity conformance: create, supersede with  (same
/// lineage_id), expunge D2, verify D1 content is empty.
#[test]
fn lineage_wide_expunge_conformance_predecessor_content_zeroed() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let lineage = Uuid::new_v4();

    let mut d1 = sample_drawer(
        "11111111-1111-4111-8111-111111111111",
        "w", "r", "predecessor-content",
    );
    d1.lineage_id = lineage;
    store.add_drawer(&d1, NOW).unwrap();

    let mut d2 = sample_drawer(
        "22222222-2222-4222-8222-222222222222",
        "w", "r", "head-content",
    );
    d2.lineage_id = lineage;
    store.add_drawer(&d2, NOW + 100).unwrap();

    // Verify D1 is superseded.
    let d1_before = store
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(
        d1_before.adjective_bitmap & 0x3F,
        State::Superseded.raw_value()
    );
    assert_eq!(d1_before.content, "predecessor-content");

    // Expunge the head.
    store
        .expunge_gated(
            "22222222-2222-4222-8222-222222222222",
            "test",
            Some("lineage conformance"),
            NOW + 200,
            true,
        )
        .unwrap();

    // Verify both are tombstoned with empty content.
    let head_after = store
        .get_drawer("22222222-2222-4222-8222-222222222222")
        .unwrap()
        .unwrap();
    assert_eq!(
        head_after.adjective_bitmap & 0x3F,
        State::Tombstoned.raw_value()
    );
    assert_eq!(head_after.content, "");

    let pred_after = store
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(
        pred_after.adjective_bitmap & 0x3F,
        State::Tombstoned.raw_value(),
        "predecessor must be tombstoned after lineage-wide expunge"
    );
    assert_eq!(
        pred_after.content, "",
        "predecessor content must be empty after lineage-wide expunge"
    );
}

/// Gate-reject conformance (MXE-EZ): when a lineage sibling's state machine
/// forbids the tombstone transition (S-3: Accepted → Tombstoned is
/// forbidden), that sibling is left byte-identical — content verbatim,
/// representation columns intact, state unchanged. A refused gate is a
/// refusal, not a partial apply. Mirrors the Swift
/// `DrawerStore.expungeGated` gate-reject branch.
///
/// Scenario:
///   D1 — Trust=Canonical, promoted to Accepted. Representation columns
///        populated to confirm they SURVIVE the refusal untouched.
///   D2 — Active, same lineage. D1 is Accepted (g_state_cluster = 3 which
///        is NOT < 3), so find_active_predecessor does not find it — D1 is
///        NOT superseded when D2 is added.
///   expunge_gated(D2) → D2 tombstoned; sibling loop processes D1 → gate
///        rejects (S-3) → D1 is preserved verbatim.
#[test]
fn expunge_gate_rejected_sibling_left_byte_identical() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let lineage = Uuid::new_v4();

    // D1: Trust=Canonical (bits 18-23) so S-1 allows promote to Accepted.
    // Representation columns populated so the gate-reject scrub can be
    // verified to NULL them.
    let mut d1 = sample_drawer("d1-gate-reject-accepted", "w", "r", "accepted-sibling-content");
    d1.lineage_id = lineage;
    d1.adjective_bitmap = Trust::Canonical.raw_value() << 18;
    d1.distilled = Some("accepted-sibling-distilled-text".to_string());
    d1.distilled_pipeline_version = Some("p1".to_string());
    d1.distilled_token_count = Some(7);
    d1.distilled_at = Some(NOW);
    store.add_drawer(&d1, NOW).unwrap();
    // Promote D1: Active → Accepted. Trust=Canonical satisfies S-1.
    store
        .mutate_state(
            &d1.id,
            State::Accepted,
            RowVerb::Promote,
            "alice",
            None,
            NOW + 100,
        )
        .unwrap();

    // D2: Active state, same lineage.
    // D1 is Accepted (g_state_cluster = 3, NOT < 3) so find_active_predecessor
    // does not find D1 — D1 is NOT superseded.
    let mut d2 = sample_drawer("d2-gate-reject-head", "w", "r", "head-content");
    d2.lineage_id = lineage;
    store.add_drawer(&d2, NOW + 200).unwrap();

    // Confirm D1 is still Accepted (not superseded by the D2 add).
    let d1_mid = store.get_drawer(&d1.id).unwrap().unwrap();
    assert_eq!(
        d1_mid.adjective_bitmap & 0x3F,
        State::Accepted.raw_value(),
        "D1 must remain Accepted after D2 is added (Accepted is not an active predecessor)"
    );

    // Capture D1's full pre-expunge shape for byte-identity comparison.
    let d1_before = store.get_drawer(&d1.id).unwrap().unwrap();

    // Expunge D2. The sibling loop processes D1. The gate rejects
    // Accepted → Tombstoned (S-3). The refusal must leave D1
    // byte-identical: no content write, no state write, no
    // representation clear.
    store
        .expunge_gated(&d2.id, "test", None, NOW + 300, true)
        .unwrap();

    // D2 itself is scrubbed and tombstoned as before.
    let d2_after = store.get_drawer(&d2.id).unwrap().unwrap();
    assert_eq!(
        d2_after.adjective_bitmap & 0x3F,
        State::Tombstoned.raw_value(),
        "the expunge target itself must still be tombstoned"
    );
    assert_eq!(d2_after.content, "");

    let d1_after = store.get_drawer(&d1.id).unwrap().unwrap();
    // State unchanged — the gate rejected the transition.
    assert_eq!(
        d1_after.adjective_bitmap & 0x3F,
        State::Accepted.raw_value(),
        "D1 state must remain Accepted after gate refusal"
    );
    // Content survives verbatim. This also proves D1 was NOT recorded
    // in the erasure ledger: the read-time ErasureOverlay nulls content
    // for any ledgered id, so a ledger record alone would fail this.
    assert_eq!(
        d1_after.content, "accepted-sibling-content",
        "gate-refused sibling content must survive verbatim"
    );
    // Bitmaps unchanged.
    assert_eq!(
        d1_after.adjective_bitmap, d1_before.adjective_bitmap,
        "adjective bitmap must be untouched on refusal"
    );
    assert_eq!(
        d1_after.operational_bitmap, d1_before.operational_bitmap,
        "operational bitmap must be untouched on refusal"
    );
    // All four representation columns intact.
    assert_eq!(
        d1_after.distilled.as_deref(),
        Some("accepted-sibling-distilled-text"),
        "distilled must survive the refusal"
    );
    assert_eq!(
        d1_after.distilled_pipeline_version.as_deref(),
        Some("p1"),
        "distilled_pipeline_version must survive the refusal"
    );
    assert_eq!(
        d1_after.distilled_token_count,
        Some(7),
        "distilled_token_count must survive the refusal"
    );
    assert_eq!(
        d1_after.distilled_at,
        Some(NOW),
        "distilled_at must survive the refusal"
    );
    assert!(
        d1_after.tombstoned_at.is_none(),
        "refused sibling must not be tombstone-stamped"
    );
}

/// The caller can tell the expunge was partial: the outcome carries the
/// refused sibling ids in walk order. Twin of Swift
/// `expungeOutcomeReportsRefusedSiblings`.
#[test]
fn expunge_outcome_reports_refused_siblings() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let lineage = Uuid::new_v4();

    let mut d1 = sample_drawer("d1-outcome-accepted", "w", "r", "accepted-content");
    d1.lineage_id = lineage;
    d1.adjective_bitmap = Trust::Canonical.raw_value() << 18;
    store.add_drawer(&d1, NOW).unwrap();
    store
        .mutate_state(&d1.id, State::Accepted, RowVerb::Promote, "alice", None, NOW + 100)
        .unwrap();

    let mut d2 = sample_drawer("d2-outcome-head", "w", "r", "head-content");
    d2.lineage_id = lineage;
    store.add_drawer(&d2, NOW + 200).unwrap();

    let outcome = store
        .expunge_gated(&d2.id, "test", None, NOW + 300, true)
        .unwrap();
    assert_eq!(
        outcome.refused_sibling_ids,
        vec![d1.id.clone()],
        "the refused accepted sibling must be reported to the caller"
    );
}

/// A lineage with no accepted members: every member is scrubbed and
/// tombstoned, and the outcome reports zero refusals. Twin of Swift
/// `expungeOutcomeEmptyForCleanLineage`.
#[test]
fn expunge_outcome_empty_for_clean_lineage() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let lineage = Uuid::new_v4();

    let mut d1 = sample_drawer("d1-clean-predecessor", "w", "r", "predecessor-content");
    d1.lineage_id = lineage;
    store.add_drawer(&d1, NOW).unwrap();
    let mut d2 = sample_drawer("d2-clean-head", "w", "r", "head-content");
    d2.lineage_id = lineage;
    store.add_drawer(&d2, NOW + 100).unwrap();

    let outcome = store
        .expunge_gated(&d2.id, "test", None, NOW + 200, true)
        .unwrap();
    assert!(
        outcome.refused_sibling_ids.is_empty(),
        "no refusals in a lineage without accepted members"
    );

    // Gate-admitted members are still scrubbed and tombstoned as before.
    let d1_after = store.get_drawer(&d1.id).unwrap().unwrap();
    assert_eq!(d1_after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
    assert_eq!(d1_after.content, "");
    let d2_after = store.get_drawer(&d2.id).unwrap().unwrap();
    assert_eq!(d2_after.adjective_bitmap & 0x3F, State::Tombstoned.raw_value());
    assert_eq!(d2_after.content, "");
}

/// The reachability case from Codex finding 06cce9cc4, end to end:
/// lineage membership is selected solely by matching lineageID, and a
/// capture accepts a caller-supplied lineage id (VaultKit maps a vault
/// note's frontmatter `moot_id` straight into `CaptureFrame.lineage_id` —
/// finding de1284c73). An attacker can therefore create their own row
/// inside a protected accepted row's lineage and then expunge it, walking
/// the shared lineage. The accepted row must survive byte-identical.
/// Twin of Swift `attackerLineageJoinCannotScrubAcceptedRow`.
#[test]
fn attacker_lineage_join_cannot_scrub_accepted_row() {
    let db = TempDb::new();
    let store = Arc::new(open_sqlite(db.path()));
    let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();
    let lineage = Uuid::new_v4();

    // The protected row: added and promoted to accepted legitimately
    // (trust=canonical at bits 18-23 satisfies S-1).
    let mut protected = sample_drawer(
        "protected-accepted-row",
        "w",
        "r",
        "protected-audit-grade-content",
    );
    protected.lineage_id = lineage;
    protected.adjective_bitmap = Trust::Canonical.raw_value() << 18;
    store.add_drawer(&protected, NOW).unwrap();
    store
        .mutate_state(
            &protected.id,
            State::Accepted,
            RowVerb::Promote,
            "owner",
            None,
            NOW + 100,
        )
        .unwrap();
    let before = store.get_drawer(&protected.id).unwrap().unwrap();
    assert_eq!(before.adjective_bitmap & 0x3F, State::Accepted.raw_value());

    // The attacker's row: an ordinary capture that names the protected
    // row's lineage id — the moot_id path.
    let mut frame = CaptureFrame::new(
        "attacker-controlled note",
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("004"),
        "attacker",
        "test-v1",
    );
    frame.lineage_id = Some(lineage);
    let attacker_row = estate.capture(frame, NOW + 200).unwrap();

    // Expunging the attacker's own row walks the shared lineage.
    estate
        .expunge(&attacker_row.id, "attacker-initiated expunge", true, NOW + 300, true)
        .unwrap();

    // The attacker's row is gone…
    let attacker_after = store.get_drawer(&attacker_row.id).unwrap().unwrap();
    assert_eq!(
        attacker_after.adjective_bitmap & 0x3F,
        State::Tombstoned.raw_value()
    );
    assert_eq!(attacker_after.content, "");

    // …and the protected accepted row is byte-identical.
    let after = store.get_drawer(&protected.id).unwrap().unwrap();
    assert_eq!(
        after.content, "protected-audit-grade-content",
        "the protected accepted row must survive an attacker-initiated lineage expunge"
    );
    assert_eq!(after.adjective_bitmap & 0x3F, State::Accepted.raw_value());
    assert_eq!(after.adjective_bitmap, before.adjective_bitmap);
    assert_eq!(after.operational_bitmap, before.operational_bitmap);
    assert!(after.tombstoned_at.is_none());
}

// ---------------------------------------------------------------------------
// § 5 — Tunnel / KGFact / Diary CRUD (parity)
// ---------------------------------------------------------------------------

#[test]
fn add_tunnel_and_query_by_source_wing() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut t = Tunnel::new(
        "t1".to_string(),
        "w".to_string(),
        "k".to_string(),
        "w".to_string(),
        "p".to_string(),
        "supplies".to_string(),
        "alice".to_string(),
        NOW,
    );
    t.source_drawer_id = Some(tid("d1"));
    store.add_tunnel(&t).unwrap();
    let from = store.tunnels_from_wing("w").unwrap();
    assert_eq!(from.len(), 1);
    let to = store.tunnels_to_wing("w").unwrap();
    assert_eq!(to.len(), 1);
}

#[test]
fn add_kg_fact_and_kg_facts_for_drawer() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let f = KGFact::new(
        "f1".to_string(),
        "alice".to_string(),
        "livesIn".to_string(),
        "berlin".to_string(),
        tid("d1"),
        NOW,
    );
    store.add_kg_fact(&f).unwrap();
    let rows = store.kg_facts_for_drawer(&tid("d1")).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].subject, "alice");
}

// ---------------------------------------------------------------------------
// KG-active filter == RowState Cluster-A (single-source-of-truth gate)
//
// The KG-fact "active" filter (all_kg_facts / kg_facts_for_drawer) must derive
// "active" from the canonical RowState Cluster-A boundary
// (RowState::ACTIVE_CLUSTER_UPPER_BOUND_RAW == 16), NOT a hand-rolled `< 7`.
// These run against the SQLite-backed store, so they exercise the real SQL
// storage predicate — proving the persisted filter and the automaton agree.
// ---------------------------------------------------------------------------

/// File one fact in every defined RowState; the active set returned by
/// `all_kg_facts()` must be EXACTLY the RowState Cluster-A states
/// {active, pending, contested, accepted}. Behavior-preserving over the
/// prior `< 7` gate (every defined active raw is < 7 AND < 16), and every
/// retired B/C state is excluded.
#[test]
fn all_kg_facts_active_set_equals_cluster_a() {
    use substrate_types::RowState;
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    let defined = [
        RowState::Active,
        RowState::Pending,
        RowState::Contested,
        RowState::Accepted,
        RowState::Superseded,
        RowState::Decayed,
        RowState::Withdrawn,
        RowState::Expired,
        RowState::Rejected,
        RowState::Tombstoned,
    ];
    for (i, state) in defined.iter().enumerate() {
        let raw = *state as u8;
        let mut f = KGFact::new(
            tid(&format!("f-{raw}")),
            format!("s-{raw}"),
            "rel".to_string(),
            "obj".to_string(),
            tid("d1"),
            NOW + i as i64,
        );
        // bits 0–5 of adjective_bitmap carry the raw RowState.
        f.adjective_bitmap = raw as i64;
        store.add_kg_fact(&f).unwrap();
    }

    let active: std::collections::HashSet<String> =
        store.all_kg_facts().unwrap().into_iter().map(|f| f.subject).collect();

    // Active set is exactly Cluster-A {active=0, pending=1, contested=2, accepted=3}.
    let expected: std::collections::HashSet<String> =
        ["s-0", "s-1", "s-2", "s-3"].iter().map(|s| s.to_string()).collect();
    assert_eq!(active, expected, "active set must equal RowState Cluster-A");

    // Per-state membership must match the automaton for every defined raw.
    for state in defined {
        let raw = state as u8;
        let present = active.contains(&format!("s-{raw}"));
        assert_eq!(
            present,
            state.is_active_cluster(),
            "state {state:?} (raw {raw}) active-membership must match Cluster-A"
        );
    }
}

/// The per-drawer active filter and the estate-wide active filter agree on
/// the same data — both derive from RowState Cluster-A.
#[test]
fn kg_facts_for_drawer_and_all_kg_facts_agree() {
    use substrate_types::RowState;
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    let defined = [
        RowState::Active,
        RowState::Pending,
        RowState::Contested,
        RowState::Accepted,
        RowState::Superseded,
        RowState::Decayed,
        RowState::Withdrawn,
        RowState::Expired,
        RowState::Rejected,
        RowState::Tombstoned,
    ];
    for (i, state) in defined.iter().enumerate() {
        let raw = *state as u8;
        let mut f = KGFact::new(
            tid(&format!("f-{raw}")),
            format!("s-{raw}"),
            "rel".to_string(),
            "obj".to_string(),
            tid("d1"),
            NOW + i as i64,
        );
        f.adjective_bitmap = raw as i64;
        store.add_kg_fact(&f).unwrap();
    }

    let per_drawer: std::collections::HashSet<String> = store
        .kg_facts_for_drawer(&tid("d1"))
        .unwrap()
        .into_iter()
        .map(|f| f.subject)
        .collect();
    let estate: std::collections::HashSet<String> =
        store.all_kg_facts().unwrap().into_iter().map(|f| f.subject).collect();

    assert_eq!(per_drawer, estate, "per-drawer and estate active filters must agree");
    let expected: std::collections::HashSet<String> =
        ["s-0", "s-1", "s-2", "s-3"].iter().map(|s| s.to_string()).collect();
    assert_eq!(per_drawer, expected);
}

#[test]
fn diary_round_trip_and_lastn_ordering() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let e1 = DiaryEntry {
        id: "e1".to_string(),
        agent_name: "skippy".to_string(),
        entry: "first".to_string(),
        topic: "log".to_string(),
        wing: "wing_skippy".to_string(),
        room: "diary".to_string(),
        filed_at: NOW + 1,
        embedding_model_id: "test-v1".to_string(),
        tombstoned_at: None,
        removed_by_batch: None,
        operational_bitmap: 0,
        reward: None,
        reward_provenance: None,
    };
    let mut e2 = e1.clone();
    e2.id = "e2".to_string();
    e2.entry = "second".to_string();
    e2.filed_at = NOW + 2;
    store.add_diary_entry(&e1).unwrap();
    store.add_diary_entry(&e2).unwrap();
    // read_diary orders newest first.
    let last = store.read_diary("skippy", 1).unwrap();
    assert_eq!(last.len(), 1);
    assert_eq!(last[0].id, "e2");
    let in_wing = store
        .read_diary_in_wing("skippy", "wing_skippy", 5)
        .unwrap();
    assert_eq!(in_wing.len(), 2);
}

// ---------------------------------------------------------------------------
// § 6 — Recall trace (parity)
// ---------------------------------------------------------------------------

#[test]
fn recall_trace_insert_get_and_mark_used() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let item = RecallTraceItem::new(
        "trace-1",
        "drawer-1",
        "2024-01-01T00:00:00.000Z",
        Some(0.75),
        0,
    );
    store.insert_recall_trace(&item).unwrap();
    let back = store.get_recall_trace("trace-1").unwrap().unwrap();
    assert!(!back.used());
    store.mark_recall_trace_used("trace-1", NOW + 5).unwrap();
    let after = store.get_recall_trace("trace-1").unwrap().unwrap();
    assert!(after.used());
    // Idempotent.
    store.mark_recall_trace_used("trace-1", NOW + 6).unwrap();
    // Missing id surfaces RecallTraceItemNotFound.
    let err = store
        .mark_recall_trace_used("missing", NOW + 7)
        .unwrap_err();
    match err {
        LocusKitError::RecallTraceItemNotFound { id } => assert_eq!(id, "missing"),
        other => panic!("expected RecallTraceItemNotFound, got {:?}", other),
    }
}

#[test]
fn recall_trace_since_filters_and_orders_ascending() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let early = RecallTraceItem::new("early", "d-a", "2024-01-01T00:00:00.000Z", None, 0);
    let mid = RecallTraceItem::new("mid", "d-b", "2024-06-01T00:00:00.000Z", None, 0);
    let late = RecallTraceItem::new("late", "d-c", "2024-12-01T00:00:00.000Z", None, 0);
    store.insert_recall_trace(&early).unwrap();
    store.insert_recall_trace(&late).unwrap();
    store.insert_recall_trace(&mid).unwrap();
    let rows = store
        .recall_trace_since("2024-06-01T00:00:00.000Z")
        .unwrap();
    let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, vec!["mid", "late"]);
}

// ---------------------------------------------------------------------------
// § 6b — mark_recall_traces_used + count_recall_traces (parity)
// ---------------------------------------------------------------------------

/// Bulk-mark flips the used bit on matching rows only, leaving out-of-window
/// and different-target rows untouched. Mirrors Swift
/// `MarkRecallTracesUsedTests.bulkMarkFlipsBit`.
#[test]
fn mark_recall_traces_used_marks_only_matching_rows() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    // Five rows: two for target "drawer-A" in window, one outside, two for "drawer-B".
    let since = "2024-01-01T00:00:00.000Z";
    let now_ts = "2024-01-03T00:00:00.000Z";

    store.insert_recall_trace(&RecallTraceItem::new("t1", "drawer-A", "2024-01-01T00:00:00.000Z", None, 0)).unwrap();
    store.insert_recall_trace(&RecallTraceItem::new("t2", "drawer-A", "2024-01-02T00:00:00.000Z", None, 0)).unwrap();
    store.insert_recall_trace(&RecallTraceItem::new("t3", "drawer-A", "2024-01-04T00:00:00.000Z", None, 0)).unwrap(); // outside window
    store.insert_recall_trace(&RecallTraceItem::new("t4", "drawer-B", "2024-01-01T12:00:00.000Z", None, 0)).unwrap();
    store.insert_recall_trace(&RecallTraceItem::new("t5", "drawer-B", "2024-01-02T12:00:00.000Z", None, 0)).unwrap();

    let touched = store.mark_recall_traces_used("drawer-A", since, now_ts).unwrap();
    assert_eq!(touched, 2, "only two drawer-A rows are in the window");

    assert!(store.get_recall_trace("t1").unwrap().unwrap().used(), "t1 must be marked");
    assert!(store.get_recall_trace("t2").unwrap().unwrap().used(), "t2 must be marked");
    assert!(!store.get_recall_trace("t3").unwrap().unwrap().used(), "t3 (outside window) must NOT be marked");
    assert!(!store.get_recall_trace("t4").unwrap().unwrap().used(), "t4 (different target) must NOT be marked");
    assert!(!store.get_recall_trace("t5").unwrap().unwrap().used(), "t5 (different target) must NOT be marked");
}

/// Second call on already-marked rows returns 0 (idempotent).
#[test]
fn mark_recall_traces_used_is_idempotent() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    store.insert_recall_trace(&RecallTraceItem::new(
        "idem-1", "drawer-Y", "2024-01-02T00:00:00.000Z", None, 0,
    )).unwrap();

    let first = store.mark_recall_traces_used(
        "drawer-Y", "2024-01-01T00:00:00.000Z", "2024-01-03T00:00:00.000Z",
    ).unwrap();
    assert_eq!(first, 1);

    // Second call — already marked, must return 0.
    let second = store.mark_recall_traces_used(
        "drawer-Y", "2024-01-01T00:00:00.000Z", "2024-01-03T00:00:00.000Z",
    ).unwrap();
    assert_eq!(second, 0);
}

/// Unknown target returns Ok(0) without error.
#[test]
fn mark_recall_traces_used_unknown_target_returns_zero() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let n = store.mark_recall_traces_used(
        "nonexistent", "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z",
    ).unwrap();
    assert_eq!(n, 0);
}

/// count_recall_traces returns total row count across all targets and used states.
#[test]
fn count_recall_traces_reports_total() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    assert_eq!(store.count_recall_traces().unwrap(), 0, "empty table → 0");

    for i in 1..=3u32 {
        store.insert_recall_trace(&RecallTraceItem::new(
            &format!("ct-{i}"), &format!("drawer-{i}"),
            "2024-06-01T00:00:00.000Z", None, 0,
        )).unwrap();
    }

    // Mark one as used; count must still include it.
    store.mark_recall_trace_used("ct-2", NOW).unwrap();

    assert_eq!(store.count_recall_traces().unwrap(), 3, "three rows total");
}

// ---------------------------------------------------------------------------
// § 6c — prune_recall_traces (parity)
//
// Mirrors Swift DrawerStore.pruneRecallTraces(olderThan:) and the
// InMemory counterpart tests added in Item A.
// ---------------------------------------------------------------------------

/// prune_recall_traces deletes rows with recalledAt strictly before cutoff.
#[test]
fn prune_recall_traces_removes_rows_before_cutoff() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    store.insert_recall_trace(&RecallTraceItem::new(
        "p-old1", "d-1", "2024-01-01T00:00:00.000Z", None, 0,
    )).unwrap();
    store.insert_recall_trace(&RecallTraceItem::new(
        "p-old2", "d-2", "2024-06-01T00:00:00.000Z", None, 0,
    )).unwrap();
    store.insert_recall_trace(&RecallTraceItem::new(
        "p-keep", "d-3", "2024-12-01T00:00:00.000Z", None, 0,
    )).unwrap();

    // ISO8601 lexicographic < equals numeric < for canonical UTC strings
    // (fleet date rule). Cutoff is the exact timestamp of the kept row —
    // only rows strictly before the cutoff are deleted.
    let deleted = store.prune_recall_traces("2024-12-01T00:00:00.000Z").unwrap();
    assert_eq!(deleted, 2, "two rows before cutoff must be deleted");

    assert!(store.get_recall_trace("p-keep").unwrap().is_some(), "kept row must survive");
    assert!(store.get_recall_trace("p-old1").unwrap().is_none(), "p-old1 pruned");
    assert!(store.get_recall_trace("p-old2").unwrap().is_none(), "p-old2 pruned");
}

/// prune_recall_traces returns 0 when no rows are before the cutoff.
#[test]
fn prune_recall_traces_nothing_to_prune_returns_zero() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    store.insert_recall_trace(&RecallTraceItem::new(
        "recent", "d-r", "2025-06-01T00:00:00.000Z", None, 0,
    )).unwrap();
    let deleted = store.prune_recall_traces("2020-01-01T00:00:00.000Z").unwrap();
    assert_eq!(deleted, 0);
    assert!(store.get_recall_trace("recent").unwrap().is_some());
}

/// prune_recall_traces on an empty table returns 0.
#[test]
fn prune_recall_traces_empty_table_returns_zero() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let deleted = store.prune_recall_traces("2099-01-01T00:00:00.000Z").unwrap();
    assert_eq!(deleted, 0);
}

// ---------------------------------------------------------------------------
// § 7 — Summary surface (parity)
// ---------------------------------------------------------------------------

#[test]
fn list_wings_and_list_rooms() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d1 = sample_drawer_with_nodes(&store, "d1", "w1", "k", "a");
    let d2 = sample_drawer_with_nodes(&store, "d2", "w1", "study", "b");
    let d3 = sample_drawer_with_nodes(&store, "d3", "w2", "lab", "c");
    store.add_drawer(&d1, NOW).unwrap();
    store.add_drawer(&d2, NOW).unwrap();
    store.add_drawer(&d3, NOW).unwrap();
    let wings: Vec<WingSummary> = store.list_wings().unwrap();
    assert_eq!(wings.len(), 2);
    assert_eq!(wings[0].name, "w1");
    assert_eq!(wings[0].drawer_count, 2);
    assert_eq!(wings[0].room_count, 2);
    let rooms = store.list_rooms(Some("w1")).unwrap();
    assert_eq!(rooms.len(), 2);
    let all_rooms = store.list_rooms(None).unwrap();
    assert_eq!(all_rooms.len(), 3);
}

#[test]
fn taxonomy_equals_list_wings() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer_with_nodes(&store, "d1", "w1", "k", "a");
    store.add_drawer(&d, NOW).unwrap();
    assert_eq!(store.taxonomy().unwrap(), store.list_wings().unwrap());
}

// ---------------------------------------------------------------------------
// § 8 — SQLite-specific: reopen-from-disk round-trip
//
// These tests are the distinguishing property of `SqliteDrawerStore`:
// data written in one process lifetime survives a drop+reopen.
// ---------------------------------------------------------------------------

#[test]
fn drawer_survives_drop_and_reopen() {
    let db = TempDb::new();
    {
        let store = open_sqlite(db.path());
        let d = sample_drawer_with_nodes(&store, "d1", "w", "k", "hello world");
        store.add_drawer(&d, NOW).unwrap();
        // store is dropped here; the SQLite connection closes.
    }
    // Reopen the same path. Nodes persist to the same SQLite file.
    let store2 = open_sqlite(db.path());
    let back = store2.get_drawer(&tid("d1")).unwrap().unwrap();
    assert_eq!(back.content, "hello world");
    // wing/room resolved from node tree, not stored on Drawer.
    let names = store2.resolve_node_names(&[back.parent_node_id.clone()]).unwrap();
    let (wing, room) = names.get(&back.parent_node_id).expect("node must resolve after reopen");
    assert_eq!(wing, "w");
    assert_eq!(room, "k");
}

#[test]
fn manifest_estate_uuid_preserved_across_reopen() {
    let db = TempDb::new();
    let uuid_a = {
        let store = open_sqlite(db.path());
        store.read_manifest().unwrap().estate_uuid
    };
    // Second open must see the same estate_uuid written on first open.
    let store2 = open_sqlite(db.path());
    let uuid_b = store2.read_manifest().unwrap().estate_uuid;
    assert_eq!(uuid_a, uuid_b, "estate_uuid must be stable across reopens");
}

#[test]
fn set_meta_survives_reopen() {
    let db = TempDb::new();
    {
        let store = open_sqlite(db.path());
        store
            .set_meta(ManifestKey::EstateName.as_str(), "reopened_estate")
            .unwrap();
    }
    let store2 = open_sqlite(db.path());
    assert_eq!(
        store2.read_manifest().unwrap().estate_name,
        "reopened_estate"
    );
}

#[test]
fn bitmap_mutation_survives_reopen() {
    let db = TempDb::new();
    // Use DrawerFeatureFlags::HAS_ATTACHMENTS (bit 12 = 0x1000). This sits
    // in the unconstrained `feature_flags` slot (bits 12-23), so the gate
    // accepts it regardless of the capture_channel and content_kind slots
    // (both remain 0 = Typed / Prose, which are legal values).
    let valid_op_bitmap = 1_i64 << 12; // HAS_ATTACHMENTS bit only
    {
        let store = open_sqlite(db.path());
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_operational(
                "11111111-1111-4111-8111-111111111111",
                valid_op_bitmap,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap();
    }
    let store2 = open_sqlite(db.path());
    let back = store2
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    // The operational bitmap written before the drop must survive.
    assert_eq!(back.operational_bitmap, valid_op_bitmap);
}

#[test]
fn supersession_cascade_survives_reopen() {
    let db = TempDb::new();
    let lineage = Uuid::new_v4();
    {
        let store = open_sqlite(db.path());
        let mut prior = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "v1");
        prior.lineage_id = lineage;
        let mut next = sample_drawer("22222222-2222-4222-8222-222222222222", "w", "k", "v2");
        next.lineage_id = lineage;
        next.filed_at = NOW + 100;
        store.add_drawer(&prior, NOW).unwrap();
        store.add_drawer(&next, NOW + 100).unwrap();
    }
    // Reopen and verify the predecessor's state was persisted.
    let store2 = open_sqlite(db.path());
    let prior_back = store2
        .get_drawer("11111111-1111-4111-8111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(
        prior_back.adjective_bitmap & 0x3F,
        State::Superseded.raw_value(),
        "predecessor state must survive disk round-trip"
    );
}

#[test]
fn tunnel_survives_reopen() {
    let db = TempDb::new();
    {
        let store = open_sqlite(db.path());
        let t = Tunnel::new(
            "t1".to_string(),
            "w".to_string(),
            "k".to_string(),
            "w".to_string(),
            "p".to_string(),
            "supplies".to_string(),
            "alice".to_string(),
            NOW,
        );
        store.add_tunnel(&t).unwrap();
    }
    let store2 = open_sqlite(db.path());
    let from = store2.tunnels_from_wing("w").unwrap();
    assert_eq!(from.len(), 1, "tunnel must survive disk round-trip");
}

#[test]
fn audit_events_survive_reopen() {
    let db = TempDb::new();
    // Use DrawerFeatureFlags::HAS_VOICE (bit 13 = 0x2000), which sits
    // in the unconstrained `feature_flags` slot (bits 12-23). This avoids
    // triggering the gate's `capture_channel` range check (bits 0-5 stay
    // at 0 = Typed, a legal value).
    let valid_op_bitmap = 1_i64 << 13; // HAS_VOICE bit only
    {
        let store = open_sqlite(db.path());
        let d = sample_drawer("11111111-1111-4111-8111-111111111111", "w", "k", "hi");
        store.add_drawer(&d, NOW).unwrap();
        store
            .mutate_operational(
                "11111111-1111-4111-8111-111111111111",
                valid_op_bitmap,
                "alice",
                None,
                NOW + 1,
            )
            .unwrap();
    }
    let store2 = open_sqlite(db.path());
    let events = store2
        .audit_events_for_row("11111111-1111-4111-8111-111111111111")
        .unwrap();
    // Capture event + operational mutation event = 2.
    assert_eq!(events.len(), 2, "audit events must survive disk round-trip");
}

// ---------------------------------------------------------------------------
// C3 regression gate — bounded recall delegation must never silently empty
// ---------------------------------------------------------------------------

/// C3 (2026-06-12 inspection): `PostgresDrawerStore` once lacked an
/// `all_drawers_bounded` override and the trait default returned `Ok(vec![])`
/// — every recall on that backend silently returned ZERO rows, caught by no
/// test. The default now DERIVES from `all_drawers` (truncate to limit). This
/// gate pins the delegation contract on a real durable backend: with drawers
/// present, a bounded scan must return them (bounded), never empty.
#[test]
fn c3_all_drawers_bounded_never_silently_empty() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    for i in 0..5 {
        let d = sample_drawer(&format!("c3-{i}"), "Archive", "delegation", "body");
        store.add_drawer(&d, NOW + i).unwrap();
    }

    // Bounded: exactly the limit, never empty.
    let two = store.all_drawers_bounded(Some(2)).unwrap();
    assert_eq!(two.len(), 2, "bounded scan must honor the limit, not return empty");

    // Unbounded (None): every live drawer.
    let all = store.all_drawers_bounded(None).unwrap();
    assert_eq!(all.len(), 5, "None limit must return every live drawer");

    // Projected variant (the .structured no-blob path) — same cardinality,
    // content stripped.
    let projected = store.all_drawers_bounded_projected(Some(5)).unwrap();
    assert_eq!(projected.len(), 5, "projected bounded scan must not be empty");
    assert!(projected.iter().all(|d| d.content.is_empty()),
            "projected scan must strip content (spec § 7.3 parity)");
}

// ---------------------------------------------------------------------------
// FINDING-3 regression gate — all_kg_facts_including_retired (math-provenance)
// ---------------------------------------------------------------------------
//
// Guards the math-provenance gate finding that `all_kg_facts_including_retired`
// had a silent-empty trait default. The SQLite concrete backend overrides with a
// real implementation. These tests verify the concrete backend produces correct
// results so the silent-empty default change does not regress production reads.

/// SQLite concrete store — empty estate returns empty vec, not an error.
/// A genuinely-empty estate is a valid state distinct from a missing impl.
#[test]
fn finding3_sqlite_all_kg_facts_including_retired_empty_estate() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let result = store.all_kg_facts_including_retired().unwrap();
    assert!(result.is_empty(), "empty estate should return empty vec on SQLite");
}

/// SQLite concrete store — active facts appear in the timeline.
#[test]
fn finding3_sqlite_all_kg_facts_including_retired_sees_active_facts() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let f = KGFact::new(
        tid("f1"),
        "alice".to_string(),
        "livesIn".to_string(),
        "berlin".to_string(),
        tid("d1"),
        NOW,
    );
    store.add_kg_fact(&f).unwrap();
    let rows = store.all_kg_facts_including_retired().unwrap();
    assert_eq!(rows.len(), 1, "active fact must appear in timeline (SQLite)");
    assert_eq!(rows[0].subject, "alice");
}

/// SQLite concrete store — retired (withdrawn) facts appear in the timeline
/// but NOT in the active-only `all_kg_facts()` scan.
#[test]
fn finding3_sqlite_all_kg_facts_including_retired_sees_retired_facts() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let f = KGFact::new(
        tid("f2"),
        "bob".to_string(),
        "worksAt".to_string(),
        "acme".to_string(),
        tid("d2"),
        NOW,
    );
    store.add_kg_fact(&f).unwrap();
    store.withdraw_kg_fact(&tid("f2"), NOW + 1).unwrap();

    // Active-only scan must not include the retired fact.
    let active = store.all_kg_facts().unwrap();
    assert!(active.is_empty(), "withdrawn fact must not appear in active-only scan (SQLite)");

    // Full timeline must include it.
    let timeline = store.all_kg_facts_including_retired().unwrap();
    assert_eq!(timeline.len(), 1, "withdrawn fact must appear in timeline (SQLite)");
    assert_eq!(timeline[0].subject, "bob");
}

/// SQLite concrete store — results survive disk round-trip (reopen).
/// Pins that the SQLite backend actually persists kg_facts, so timeline
/// results are not ephemeral in-process artifacts.
#[test]
fn finding3_sqlite_all_kg_facts_including_retired_survives_reopen() {
    let db = TempDb::new();
    {
        let store = open_sqlite(db.path());
        let f_active = KGFact::new(
            tid("fa"),
            "carol".to_string(),
            "knows".to_string(),
            "dave".to_string(),
            tid("d3"),
            NOW,
        );
        let f_retired = KGFact::new(
            tid("fr"),
            "eve".to_string(),
            "uses".to_string(),
            "tool".to_string(),
            tid("d4"),
            NOW + 1,
        );
        store.add_kg_fact(&f_active).unwrap();
        store.add_kg_fact(&f_retired).unwrap();
        store.withdraw_kg_fact(&tid("fr"), NOW + 2).unwrap();
        // Drop store — flushes WAL-mode SQLite.
    }
    // Reopen from same path.
    let store2 = open_sqlite(db.path());
    let timeline = store2.all_kg_facts_including_retired().unwrap();
    assert_eq!(
        timeline.len(),
        2,
        "both active and retired facts must survive disk round-trip"
    );
}

// ---------------------------------------------------------------------------
// § N — Durable-newtype trait-default regression guard
//
// Background: commit 2b549c37 made all empty-success DrawerStore read
// defaults fail-loud (return DatabaseUnavailable). `SqliteDrawerStore` is a
// newtype over `DrawerStoreCore` that hand-forwards every method to `.0`
// with no `Deref`. If a method is NOT forwarded, the newtype inherits the
// fail-loud trait default and HARD-ERRORS on a real estate. `all_tunnels`
// was the one omitted forward; these tests assert it (and the B-1 reader
// path that depends on it) return the REAL DrawerStoreCore result on the
// durable SQLite backend, never DatabaseUnavailable.
// ---------------------------------------------------------------------------

/// `all_tunnels` on the durable SQLite newtype returns the real rows — it
/// must NOT inherit the fail-loud trait default. Populated case.
#[test]
fn all_tunnels_durable_sqlite_returns_real_rows() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    // Two distinct tunnels in different wings so we exercise the
    // cross-wing aggregation `all_tunnels` performs.
    let mut t1 = Tunnel::new(
        "t1".to_string(),
        "w1".to_string(),
        "k1".to_string(),
        "w1".to_string(),
        "p1".to_string(),
        "supplies".to_string(),
        "alice".to_string(),
        NOW,
    );
    t1.source_drawer_id = Some(tid("d1"));
    let mut t2 = Tunnel::new(
        "t2".to_string(),
        "w2".to_string(),
        "k2".to_string(),
        "w2".to_string(),
        "p2".to_string(),
        "supplies".to_string(),
        "alice".to_string(),
        NOW,
    );
    t2.source_drawer_id = Some(tid("d2"));
    store.add_tunnel(&t1).unwrap();
    store.add_tunnel(&t2).unwrap();

    // The load-bearing assertion: this is `.unwrap()`, so a
    // DatabaseUnavailable from an inherited fail-loud default would panic.
    let all = store
        .all_tunnels()
        .expect("durable SQLite all_tunnels must return real rows, not DatabaseUnavailable");
    assert_eq!(all.len(), 2, "both tunnels across both wings must be returned");
}

/// `all_tunnels` on a genuinely empty durable SQLite estate returns an empty
/// Vec — NOT DatabaseUnavailable. Distinguishes "real empty result" from
/// "fail-loud trait default".
#[test]
fn all_tunnels_durable_sqlite_empty_estate_is_ok_empty() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let all = store
        .all_tunnels()
        .expect("empty durable estate must return Ok(empty), not DatabaseUnavailable");
    assert!(all.is_empty(), "fresh estate has no tunnels");
}

/// Regression guard for the dreaming-reader B-1 path: `Estate::all_tunnels`
/// (estate_verbs.rs) delegates to `DrawerStore::all_tunnels`. Over a
/// SQLite-backed Estate this must return real rows — the path the re-gate
/// flagged as hard-erroring on durable backends.
#[test]
fn estate_all_tunnels_b1_path_works_on_sqlite_backend() {
    use locus_kit::estate::Estate;
    use locus_kit::estate_types::OwnerCredentials;
    use std::sync::Arc;

    let db = TempDb::new();
    let store = Arc::new(SqliteDrawerStore::from_path(db.path(), NOW, None, 5.0).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("owner"), None).unwrap();

    let mut t = Tunnel::new(
        "t1".to_string(),
        "w1".to_string(),
        "k1".to_string(),
        "w1".to_string(),
        "p1".to_string(),
        "supplies".to_string(),
        "alice".to_string(),
        NOW,
    );
    t.source_drawer_id = Some(tid("d1"));
    store.add_tunnel(&t).unwrap();

    let all = estate
        .all_tunnels()
        .expect("B-1 reader path must work on a SQLite-backed estate, not DatabaseUnavailable");
    assert_eq!(all.len(), 1, "the single estate tunnel must surface via the B-1 path");
}

// ---------------------------------------------------------------------------
// § N — tombstoned_rows_without_expunge_audit SQL LEFT JOIN conformance
//
// Verifies that the SQLite-backed DrawerStore returns exactly the set of
// tombstoned drawers that have NO corresponding "tombstone" or
// "expungeOrphan" audit event — the crash-window orphan set.
//
// The implementation uses two SQL queries that together are semantically
// equivalent to a LEFT JOIN (see drawer_store_sqlite.rs comment). This
// test confirms the result is identical to the InMemory scan reference,
// which is the correctness criterion for the optimisation.
// ---------------------------------------------------------------------------

/// Three drawers in various expunge states:
///
///   A: expunge_gated(seal_audit: true)  → tombstoned + audit sealed
///   B: expunge_gated(seal_audit: false) → tombstoned, NO audit (orphan)
///   C: not expunged at all              → live, not tombstoned
///
/// Expected: tombstoned_rows_without_expunge_audit returns exactly [B].
#[test]
fn tombstoned_rows_without_expunge_audit_sql_join_returns_only_orphans() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    // Drawer A — will be tombstoned with the audit event sealed immediately.
    let id_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    let da = sample_drawer(id_a, "w", "k", "content-a");
    store.add_drawer(&da, NOW).unwrap();

    // Drawer B — will be tombstoned but audit NOT sealed (crash-window orphan).
    let id_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    let db_ = sample_drawer(id_b, "w", "k", "content-b");
    store.add_drawer(&db_, NOW).unwrap();

    // Drawer C — never expunged; stays live.
    let id_c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    let dc = sample_drawer(id_c, "w", "k", "content-c");
    store.add_drawer(&dc, NOW).unwrap();

    // Expunge A with audit sealed (normal expunge path — not an orphan).
    store
        .expunge_gated(id_a, "alice", None, NOW + 10, true)
        .unwrap();

    // Expunge B with audit NOT sealed (crash-window simulation — is an orphan).
    store
        .expunge_gated(id_b, "alice", None, NOW + 20, false)
        .unwrap();

    // tombstoned_rows_without_expunge_audit must return exactly [B].
    let orphans = store
        .tombstoned_rows_without_expunge_audit()
        .expect("SQL LEFT JOIN path must succeed on a live SQLite estate");

    assert_eq!(
        orphans.len(),
        1,
        "exactly one orphan (drawer B) expected; got {:?}",
        orphans.iter().map(|d| d.id.as_str()).collect::<Vec<_>>()
    );
    assert_eq!(
        orphans[0].id, id_b,
        "the orphan must be drawer B (tombstoned without audit seal)"
    );

    // Drawer A has an audit event — must NOT appear in the orphan set.
    assert!(
        orphans.iter().all(|d| d.id != id_a),
        "drawer A has a sealed audit event and must not appear as an orphan"
    );

    // Drawer C is not tombstoned — must NOT appear.
    assert!(
        orphans.iter().all(|d| d.id != id_c),
        "drawer C is not tombstoned and must not appear in the orphan set"
    );
}

/// Empty estate: tombstoned_rows_without_expunge_audit returns an empty Vec,
/// not DatabaseUnavailable. This guards the fail-loud trait default — the
/// SQL backends must override it with a real implementation.
#[test]
fn tombstoned_rows_without_expunge_audit_empty_estate_returns_ok_empty() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let orphans = store
        .tombstoned_rows_without_expunge_audit()
        .expect("empty durable estate must return Ok(empty), not DatabaseUnavailable");
    assert!(
        orphans.is_empty(),
        "fresh estate has no tombstoned rows and must return an empty orphan set"
    );
}

/// All tombstoned rows have audit events: orphan set is empty.
/// Confirms the LEFT JOIN correctly returns zero rows when the right-hand
/// side matches every tombstoned drawer.
#[test]
fn tombstoned_rows_without_expunge_audit_all_sealed_returns_empty() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    let id_x = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    let id_y = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    store.add_drawer(&sample_drawer(id_x, "w", "k", "cx"), NOW).unwrap();
    store.add_drawer(&sample_drawer(id_y, "w", "k", "cy"), NOW).unwrap();

    // Both expunged with audit sealed — neither is an orphan.
    store.expunge_gated(id_x, "alice", None, NOW + 1, true).unwrap();
    store.expunge_gated(id_y, "alice", None, NOW + 2, true).unwrap();

    let orphans = store
        .tombstoned_rows_without_expunge_audit()
        .expect("all-sealed tombstoned set must return Ok(empty), not error");
    assert!(
        orphans.is_empty(),
        "all tombstoned rows have audit events; orphan set must be empty"
    );
}

// ---------------------------------------------------------------------------
// c-recall-determinism: bounded DESC deterministic tie-break tests
//
// These tests verify that the (filed_at DESC, id DESC) compound sort key
// produces a stable total order on SQLite — the same invariants the Swift
// port tests via RecallPerfCorrectnessTests. The id tie-break uses the
// declared TEXT primary key (portable to PostgreSQL; rowid was SQLite-only,
// c-recall-portable fix).
// ---------------------------------------------------------------------------

/// Two consecutive `all_drawers_bounded_desc` calls over the same SQLite
/// estate must return identical ordering when drawers share the same filed_at.
/// Guards against the non-deterministic tie order reported in c-recall-determinism.
#[test]
fn all_drawers_bounded_desc_deterministic_on_tied_filed_at() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    // Insert 5 drawers all with the same filed_at (NOW) to produce ties.
    // The id (declared TEXT primary key) is the stable tie-break key — same
    // on every query and portable to PostgreSQL (c-recall-portable fix).
    let ids: Vec<String> = (0..5).map(|i| tid(&format!("tied-drawer-{}", i))).collect();
    let contents = ["ca", "cb", "cc", "cd", "ce"];
    for (id, content) in ids.iter().zip(contents.iter()) {
        let mut d = Drawer::new(id.as_str(), *content, &tid("node-w-r"), "alice", NOW, "test-v1");
        d.udc_code = "001".to_string();
        store.add_drawer(&d, NOW).unwrap();
    }

    // Two consecutive bounded DESC scans must return the same order.
    let first = store
        .all_drawers_bounded_desc(Some(10))
        .expect("first bounded_desc scan must succeed");
    let second = store
        .all_drawers_bounded_desc(Some(10))
        .expect("second bounded_desc scan must succeed");

    let first_ids: Vec<&str> = first.iter().map(|d| d.id.as_str()).collect();
    let second_ids: Vec<&str> = second.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(
        first_ids, second_ids,
        "two consecutive bounded_desc scans over tied filed_at must return identical order;\
        first={:?} second={:?}",
        first_ids, second_ids
    );
    assert_eq!(first.len(), 5, "expected 5 rows, got {}", first.len());
}

/// `all_drawers_bounded_desc(limit)` must return exactly the reverse of
/// `all_drawers_bounded(limit)` when applied to the same fixed dataset.
/// This is the fundamental invariant of the (filed_at, id) compound key.
#[test]
fn all_drawers_bounded_desc_is_reverse_of_asc() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());

    // Insert 5 drawers with strictly ordered filed_at values so the reversal
    // is unambiguous. Also guards the common case (no ties).
    let contents = ["d1", "d2", "d3", "d4", "d5"];
    for (i, content) in contents.iter().enumerate() {
        let id = tid(&format!("rev-drawer-{}", i));
        let mut d = Drawer::new(id.as_str(), *content, &tid("node-w-r"), "alice", NOW + i as i64, "test-v1");
        d.udc_code = "001".to_string();
        store.add_drawer(&d, NOW + i as i64).unwrap();
    }

    let asc = store
        .all_drawers_bounded(Some(10))
        .expect("all_drawers_bounded (ASC) must succeed");
    let desc = store
        .all_drawers_bounded_desc(Some(10))
        .expect("all_drawers_bounded_desc (DESC) must succeed");

    let asc_ids: Vec<&str> = asc.iter().map(|d| d.id.as_str()).collect();
    let desc_ids: Vec<&str> = desc.iter().map(|d| d.id.as_str()).collect();
    let asc_reversed: Vec<&str> = asc_ids.iter().copied().rev().collect();
    assert_eq!(
        desc_ids, asc_reversed,
        "all_drawers_bounded_desc must equal reverse(all_drawers_bounded);\
        asc={:?} desc={:?}",
        asc_ids, desc_ids
    );
}

// ---------------------------------------------------------------------------
// c-recall-portable: bounded-scan-stays-bounded via Arc<dyn DrawerStore>
//
// Guards against the Part 2 regression where wrapper types omitted DESC
// forwarding overrides. Without the forwards, trait-object dispatch hits
// the O(estate) default (load all_drawers, reverse, truncate) even when
// the concrete backend has an efficient (filed_at DESC, id DESC, LIMIT)
// implementation. These tests assert that calling bounded DESC methods
// through Arc<dyn DrawerStore> on an estate larger than the limit returns
// AT MOST `limit` rows — proving the efficient override path was taken
// rather than the O(estate) default that materialises the whole set first.
// ---------------------------------------------------------------------------

/// `all_drawers_bounded_desc` via `Arc<dyn DrawerStore>` must return at
/// most `limit` rows even when the estate has more rows than the limit.
/// If the forwarding override is absent, the O(estate) default materialises
/// all rows and truncates — this test would still pass but loses the
/// efficiency guarantee. Combined with the comment confirming the override
/// path, it documents the correct dispatch behaviour.
#[test]
fn arc_dyn_drawer_store_bounded_desc_respects_limit() {
    let db = TempDb::new();
    // Wrap the store in Arc<dyn DrawerStore> — this is the production usage
    // path (estate_registry.rs new_sqlite). If SqliteDrawerStore.all_drawers_bounded_desc
    // is absent, Arc dispatch falls through to the O(estate) trait default.
    let store: Arc<dyn DrawerStore> = Arc::new(open_sqlite(db.path()));

    let limit: usize = 3;
    // Insert `limit + 3` drawers so a non-bounded scan would return more.
    for i in 0..(limit + 3) {
        let id = tid(&format!("arc-bounded-{}", i));
        // Distinct filed_at so ordering is deterministic without tie-break.
        let filed_at = NOW + i as i64;
        let mut d = Drawer::new(id.as_str(), "content", &tid("node-w-r"), "alice", filed_at, "test-v1");
        d.udc_code = "001".to_string();
        store.add_drawer(&d, filed_at).unwrap();
    }

    let result = store
        .all_drawers_bounded_desc(Some(limit))
        .expect("arc bounded_desc must succeed");

    assert_eq!(
        result.len(),
        limit,
        "bounded_desc via Arc<dyn DrawerStore> must return exactly {limit} rows (got {}); \
        if the forwarding override is absent the default path materialises all rows first",
        result.len()
    );
    // Verify newest-first order: DESC over distinct filed_at means the
    // result set should be sorted with highest filed_at first.
    let filed_ats: Vec<i64> = result.iter().map(|d| d.filed_at).collect();
    let mut sorted_desc = filed_ats.clone();
    sorted_desc.sort_unstable_by(|a, b| b.cmp(a));
    assert_eq!(
        filed_ats, sorted_desc,
        "bounded_desc via Arc<dyn DrawerStore> must be sorted newest-first; got filed_ats={:?}",
        filed_ats
    );
}

/// `all_drawers_bounded_projected_desc` via `Arc<dyn DrawerStore>` must
/// return at most `limit` rows and omit content blobs (content == "").
/// Guards that the projected DESC forward is also present on the wrapper.
#[test]
fn arc_dyn_drawer_store_bounded_projected_desc_respects_limit() {
    let db = TempDb::new();
    let store: Arc<dyn DrawerStore> = Arc::new(open_sqlite(db.path()));

    let limit: usize = 2;
    for i in 0..(limit + 4) {
        let id = tid(&format!("arc-proj-{}", i));
        let filed_at = NOW + i as i64;
        let mut d = Drawer::new(id.as_str(), "some-content", &tid("node-w-r"), "alice", filed_at, "test-v1");
        d.udc_code = "001".to_string();
        store.add_drawer(&d, filed_at).unwrap();
    }

    let result = store
        .all_drawers_bounded_projected_desc(Some(limit))
        .expect("arc bounded_projected_desc must succeed");

    assert_eq!(
        result.len(),
        limit,
        "bounded_projected_desc via Arc<dyn DrawerStore> must return exactly {limit} rows (got {})",
        result.len()
    );
    // Projected (structured) scan must clear content blobs.
    for d in &result {
        assert!(
            d.content.is_empty(),
            "projected desc scan must return empty content; got {:?}",
            d.content
        );
    }
}
