// Snapshot registry tests (ADR-017 §15).
// Rust port of Swift SnapshotRegistryTests — CRUD round-trips,
// attestation write/read, delete cascade, HLC ordering.

use persistence_kit::{
    inmemory::InMemoryStorage,
    schema::SchemaDeclaration,
    snapshot_registry::{
        attestations_table_declaration, create_snapshot, delete_snapshot, list_snapshots,
        registry_table_declaration, snapshot_attestations, SnapshotAttestation, SnapshotId,
    },
    Storage,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "SnapshotTestKit",
        1,
        vec![
            registry_table_declaration(),
            attestations_table_declaration(),
        ],
    );
    storage.open(&schema).expect("open");
    storage
}

#[test]
fn create_snapshot_mints_id_and_records_hlc() {
    let storage = make_storage();
    let rs = storage.row_store();
    let hlc = HLC::new(1_000_000, 1, 0);
    let created_at: i64 = 1_700_000_000;

    let record = create_snapshot(rs.as_ref(), hlc, Some("test-snap"), created_at, &[])
        .expect("create");

    assert_eq!(record.hlc, hlc);
    assert_eq!(record.label.as_deref(), Some("test-snap"));
    assert_eq!(record.created_at, created_at);
    assert!(!record.snapshot_id.raw_value.is_empty());
}

#[test]
fn list_snapshots_ordered_by_hlc() {
    let storage = make_storage();
    let rs = storage.row_store();
    let created_at: i64 = 1_700_000_000;

    let snap1 = create_snapshot(rs.as_ref(), HLC::new(1_000, 1, 0), Some("first"), created_at, &[])
        .expect("snap1");
    let snap2 = create_snapshot(rs.as_ref(), HLC::new(3_000, 1, 0), Some("third"), created_at, &[])
        .expect("snap2");
    let snap3 = create_snapshot(rs.as_ref(), HLC::new(2_000, 1, 0), Some("second"), created_at, &[])
        .expect("snap3");

    let list = list_snapshots(rs.as_ref()).expect("list");

    assert_eq!(list.len(), 3);
    assert_eq!(list[0].snapshot_id, snap1.snapshot_id);
    assert_eq!(list[1].snapshot_id, snap3.snapshot_id);
    assert_eq!(list[2].snapshot_id, snap2.snapshot_id);
}

#[test]
fn delete_snapshot_removes_registry_row() {
    let storage = make_storage();
    let rs = storage.row_store();
    let snap = create_snapshot(rs.as_ref(), HLC::new(1_000, 1, 0), None, 1_700_000_000, &[])
        .expect("create");

    let deleted = delete_snapshot(rs.as_ref(), &snap.snapshot_id).expect("delete");
    assert!(deleted);

    let list = list_snapshots(rs.as_ref()).expect("list");
    assert!(list.is_empty());
}

#[test]
fn delete_nonexistent_snapshot_returns_false() {
    let storage = make_storage();
    let rs = storage.row_store();
    let deleted = delete_snapshot(rs.as_ref(), &SnapshotId::new("nonexistent")).expect("delete");
    assert!(!deleted);
}

#[test]
fn nil_label_round_trips() {
    let storage = make_storage();
    let rs = storage.row_store();
    create_snapshot(rs.as_ref(), HLC::new(1_000, 1, 0), None, 1_700_000_000, &[])
        .expect("create");

    let list = list_snapshots(rs.as_ref()).expect("list");
    assert_eq!(list.len(), 1);
    assert!(list[0].label.is_none());
}

#[test]
fn attestations_written_at_create_time() {
    let storage = make_storage();
    let rs = storage.row_store();

    let atts = vec![
        SnapshotAttestation {
            snapshot_id: SnapshotId::new("placeholder"),
            subject_kind: "wing".to_string(),
            subject_id: "wing-1".to_string(),
            merkle_root: "abc123".to_string(),
            key_version: None,
        },
        SnapshotAttestation {
            snapshot_id: SnapshotId::new("placeholder"),
            subject_kind: "drawer".to_string(),
            subject_id: "drawer-42".to_string(),
            merkle_root: "def456".to_string(),
            key_version: Some(2),
        },
    ];

    let snap = create_snapshot(rs.as_ref(), HLC::new(5_000, 1, 0), Some("attested"), 1_700_000_000, &atts)
        .expect("create");

    let read_back = snapshot_attestations(rs.as_ref(), &snap.snapshot_id).expect("attestations");
    assert_eq!(read_back.len(), 2);

    let drawer = read_back.iter().find(|a| a.subject_kind == "drawer").unwrap();
    assert_eq!(drawer.subject_id, "drawer-42");
    assert_eq!(drawer.merkle_root, "def456");
    assert_eq!(drawer.key_version, Some(2));
    assert_eq!(drawer.snapshot_id, snap.snapshot_id);

    let wing = read_back.iter().find(|a| a.subject_kind == "wing").unwrap();
    assert_eq!(wing.subject_id, "wing-1");
    assert_eq!(wing.merkle_root, "abc123");
    assert_eq!(wing.key_version, None);
    assert_eq!(wing.snapshot_id, snap.snapshot_id);
}

#[test]
fn delete_snapshot_cascades_to_attestations() {
    let storage = make_storage();
    let rs = storage.row_store();

    let snap = create_snapshot(
        rs.as_ref(),
        HLC::new(1_000, 1, 0),
        None,
        1_700_000_000,
        &[SnapshotAttestation {
            snapshot_id: SnapshotId::new("placeholder"),
            subject_kind: "wing".to_string(),
            subject_id: "w1".to_string(),
            merkle_root: "root1".to_string(),
            key_version: None,
        }],
    )
    .expect("create");

    let before = snapshot_attestations(rs.as_ref(), &snap.snapshot_id).expect("before");
    assert_eq!(before.len(), 1);

    let deleted = delete_snapshot(rs.as_ref(), &snap.snapshot_id).expect("delete");
    assert!(deleted);

    let after = snapshot_attestations(rs.as_ref(), &snap.snapshot_id).expect("after");
    assert!(after.is_empty());
}

#[test]
fn attestations_for_nonexistent_snapshot_returns_empty() {
    let storage = make_storage();
    let rs = storage.row_store();
    let result = snapshot_attestations(rs.as_ref(), &SnapshotId::new("ghost")).expect("query");
    assert!(result.is_empty());
}

#[test]
fn create_snapshot_full_cycle() {
    let storage = make_storage();
    let rs = storage.row_store();
    let hlc = HLC::new(10_000, 5, 0);

    let snap = create_snapshot(
        rs.as_ref(),
        hlc,
        Some("full-cycle"),
        1_700_000_000,
        &[SnapshotAttestation {
            snapshot_id: SnapshotId::new("_"),
            subject_kind: "estate".to_string(),
            subject_id: "e1".to_string(),
            merkle_root: "rootHash".to_string(),
            key_version: Some(1),
        }],
    )
    .expect("create");

    let listed = list_snapshots(rs.as_ref()).expect("list");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].snapshot_id, snap.snapshot_id);
    assert_eq!(listed[0].hlc, hlc);
    assert_eq!(listed[0].label.as_deref(), Some("full-cycle"));

    let atts = snapshot_attestations(rs.as_ref(), &snap.snapshot_id).expect("attestations");
    assert_eq!(atts.len(), 1);
    assert_eq!(atts[0].merkle_root, "rootHash");

    let deleted = delete_snapshot(rs.as_ref(), &snap.snapshot_id).expect("delete");
    assert!(deleted);

    let after_list = list_snapshots(rs.as_ref()).expect("list after");
    assert!(after_list.is_empty());
    let after_atts = snapshot_attestations(rs.as_ref(), &snap.snapshot_id).expect("atts after");
    assert!(after_atts.is_empty());
}
