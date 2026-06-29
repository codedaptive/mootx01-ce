// GC pin tests (ADR-017 §15).
// Rust port of Swift GCPinTests — minimum retainable HLC queries,
// pin boundary semantics, delete-moves-pin.

use persistence_kit::{
    gc_pin::{is_pinned, minimum_retainable_hlc},
    inmemory::InMemoryStorage,
    schema::SchemaDeclaration,
    snapshot_registry::{
        attestations_table_declaration, create_snapshot, delete_snapshot,
        registry_table_declaration,
    },
    Storage,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "GCPinTestKit",
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
fn no_snapshots_returns_none_minimum() {
    let storage = make_storage();
    let rs = storage.row_store();
    let min = minimum_retainable_hlc(rs.as_ref()).expect("query");
    assert!(min.is_none());
}

#[test]
fn no_snapshots_means_nothing_pinned() {
    let storage = make_storage();
    let rs = storage.row_store();
    let pinned = is_pinned(rs.as_ref(), HLC::new(1_000, 1, 0)).expect("query");
    assert!(!pinned);
}

#[test]
fn single_snapshot_pins_newer_rows() {
    let storage = make_storage();
    let rs = storage.row_store();
    let snap_hlc = HLC::new(5_000, 1, 0);

    create_snapshot(rs.as_ref(), snap_hlc, Some("pin-test"), 1_700_000_000, &[])
        .expect("create");

    let min = minimum_retainable_hlc(rs.as_ref()).expect("min");
    assert_eq!(min, Some(snap_hlc));

    assert!(is_pinned(rs.as_ref(), snap_hlc).expect("at snap"));
    assert!(is_pinned(rs.as_ref(), HLC::new(10_000, 1, 0)).expect("newer"));
    assert!(!is_pinned(rs.as_ref(), HLC::new(1_000, 1, 0)).expect("older"));
}

#[test]
fn multiple_snapshots_use_oldest() {
    let storage = make_storage();
    let rs = storage.row_store();

    for pt in [3_000i64, 7_000, 5_000] {
        create_snapshot(rs.as_ref(), HLC::new(pt, 1, 0), None, 1_700_000_000, &[])
            .expect("create");
    }

    let min = minimum_retainable_hlc(rs.as_ref()).expect("min");
    assert_eq!(min, Some(HLC::new(3_000, 1, 0)));

    assert!(!is_pinned(rs.as_ref(), HLC::new(2_000, 1, 0)).expect("old"));
    assert!(is_pinned(rs.as_ref(), HLC::new(4_000, 1, 0)).expect("mid"));
}

#[test]
fn deleting_oldest_snapshot_moves_pin() {
    let storage = make_storage();
    let rs = storage.row_store();

    let snap1 = create_snapshot(rs.as_ref(), HLC::new(2_000, 1, 0), None, 1_700_000_000, &[])
        .expect("snap1");
    create_snapshot(rs.as_ref(), HLC::new(8_000, 1, 0), None, 1_700_000_000, &[])
        .expect("snap2");

    let before = minimum_retainable_hlc(rs.as_ref()).expect("before");
    assert_eq!(before, Some(HLC::new(2_000, 1, 0)));
    assert!(is_pinned(rs.as_ref(), HLC::new(5_000, 1, 0)).expect("pinned before"));

    delete_snapshot(rs.as_ref(), &snap1.snapshot_id).expect("delete");

    let after = minimum_retainable_hlc(rs.as_ref()).expect("after");
    assert_eq!(after, Some(HLC::new(8_000, 1, 0)));
    assert!(!is_pinned(rs.as_ref(), HLC::new(5_000, 1, 0)).expect("pinned after"));
}
