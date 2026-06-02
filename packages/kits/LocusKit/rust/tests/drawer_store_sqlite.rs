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
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::error::LocusKitError;
use locus_kit::kg_fact::KGFact;
use locus_kit::manifest::ManifestKey;
use locus_kit::recall_trace_item::RecallTraceItem;
use locus_kit::summaries::WingSummary;
use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_operational::TunnelKind;
use substrate_lib::row_state::RowVerb;
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
fn sample_drawer(id: &str, wing: &str, room: &str, content: &str) -> Drawer {
    let resolved = match Uuid::parse_str(id) {
        Ok(_) => id.to_string(),
        Err(_) => tid(id),
    };
    let mut d = Drawer::new(&resolved, content, wing, room, "alice", NOW, "test-v1");
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

// ---------------------------------------------------------------------------
// § 2 — Drawer CRUD (parity)
// ---------------------------------------------------------------------------

#[test]
fn add_drawer_then_get_round_trips() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let d = sample_drawer("d1", "w", "kitchen", "hello");
    store.add_drawer(&d, NOW).unwrap();
    let back = store.get_drawer(&tid("d1")).unwrap().unwrap();
    assert_eq!(back.content, "hello");
    assert_eq!(back.wing, "w");
    assert_eq!(back.room, "kitchen");
}

#[test]
fn add_drawer_rejects_empty_wing() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    let mut d = sample_drawer("d1", "w", "kitchen", "hello");
    d.wing = String::new();
    let err = store.add_drawer(&d, NOW).unwrap_err();
    match err {
        LocusKitError::InvalidContent(msg) => assert!(msg.contains("wing")),
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
    let mut d1 = sample_drawer("d1", "w", "k", "first");
    d1.filed_at = NOW + 10;
    let mut d2 = sample_drawer("d2", "w", "k", "second");
    d2.filed_at = NOW + 20;
    // d3 is inserted with a tombstonedAt already set — the schema
    // accepts this (it's how restore-and-read-tombstoned works). The
    // drawers_in_wing predicate filters IsNull(tombstonedAt).
    let mut d3 = sample_drawer("d3", "w", "k", "tombstoned");
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
            assert!(msg.contains("IllegalTransition"), "got: {}", msg);
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
    store
        .expunge_gated(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "alice",
            Some("GDPR"),
            NOW + 500,
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
// § 7 — Summary surface (parity)
// ---------------------------------------------------------------------------

#[test]
fn list_wings_and_list_rooms() {
    let db = TempDb::new();
    let store = open_sqlite(db.path());
    store
        .add_drawer(&sample_drawer("d1", "w1", "k", "a"), NOW)
        .unwrap();
    store
        .add_drawer(&sample_drawer("d2", "w1", "study", "b"), NOW)
        .unwrap();
    store
        .add_drawer(&sample_drawer("d3", "w2", "lab", "c"), NOW)
        .unwrap();
    let wings: Vec<WingSummary> = store.list_wings().unwrap();
    assert_eq!(wings.len(), 2);
    // BTreeMap order: w1 < w2.
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
    store
        .add_drawer(&sample_drawer("d1", "w1", "k", "a"), NOW)
        .unwrap();
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
        store
            .add_drawer(&sample_drawer("d1", "w", "k", "hello world"), NOW)
            .unwrap();
        // store is dropped here; the SQLite connection closes.
    }
    // Reopen the same path.
    let store2 = open_sqlite(db.path());
    let back = store2.get_drawer(&tid("d1")).unwrap().unwrap();
    assert_eq!(back.content, "hello world");
    assert_eq!(back.wing, "w");
    assert_eq!(back.room, "k");
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
