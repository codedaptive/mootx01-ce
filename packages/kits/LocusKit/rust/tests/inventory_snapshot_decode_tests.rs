use locus_kit::inventory_snapshot_decode::{
    decode_inventory_snapshot, InventorySnapshotDecodeError,
};
use persistence_kit::types::{StorageRow, TypedValue};
use uuid::Uuid;

fn node(id: Uuid, parent: Option<Uuid>, name: &str, depth: i64) -> StorageRow {
    StorageRow::from_pairs([
        ("id", TypedValue::Text(id.to_string())),
        ("parent_id", parent.map(|value| TypedValue::Text(value.to_string())).unwrap_or(TypedValue::Null)),
        ("display_name", TypedValue::Text(name.to_string())),
        ("lookup_name", TypedValue::Text(name.to_lowercase())),
        ("depth", TypedValue::Int(depth)),
        ("lifecycle", TypedValue::Int(0)),
    ])
}

fn tombstoned_node(id: Uuid, parent: Option<Uuid>, name: &str, depth: i64) -> StorageRow {
    let mut row = node(id, parent, name, depth);
    row.values.insert("lifecycle".to_owned(), TypedValue::Int(1));
    row.values.insert("tombstoned_hlc".to_owned(), TypedValue::Int(1));
    row.values.insert("tombstoned_at".to_owned(), TypedValue::Timestamp(1_700_000_001));
    row
}

fn drawer(id: &str, room: Uuid) -> StorageRow {
    StorageRow::from_pairs([
        ("id", TypedValue::Text(id.to_string())),
        ("lineageID", TypedValue::Text("00000000-0000-4000-8000-000000000010".to_string())),
        ("parent_node_id", TypedValue::Text(room.to_string())),
        ("filedAt", TypedValue::Timestamp(1_700_000_000)),
        ("tombstonedAt", TypedValue::Null),
        ("provenance", TypedValue::Bitmap(0)),
        ("adjectiveBitmap", TypedValue::Bitmap(16 << 6)),
        ("subject", TypedValue::Null),
    ])
}

#[test]
fn decodes_verified_active_drawer_room_wing_root_chain() {
    let root = Uuid::from_u128(1);
    let wing = Uuid::from_u128(2);
    let room = Uuid::from_u128(3);
    let entries = decode_inventory_snapshot(
        &[drawer("drawer-1", room)],
        &[node(root, None, "Estate", 0), node(wing, Some(root), "Wing", 1), node(room, Some(wing), "Room", 2)],
    )
    .unwrap();

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].room, "Room");
    assert_eq!(entries[0].wing, "Wing");
    assert_eq!(entries[0].root, "Estate");
    assert!(entries[0].drawer.is_eligible());
    assert!(entries[0].drawer.is_bulk_visible());
}

#[test]
fn rejects_reserved_sensitivity_instead_of_defaulting_to_normal() {
    let root = Uuid::from_u128(1);
    let wing = Uuid::from_u128(2);
    let room = Uuid::from_u128(3);
    let mut corrupt = drawer("drawer-1", room);
    corrupt.values.insert("adjectiveBitmap".to_string(), TypedValue::Bitmap(1 << 6));

    assert!(matches!(
        decode_inventory_snapshot(
            &[corrupt],
            &[node(root, None, "Estate", 0), node(wing, Some(root), "Wing", 1), node(room, Some(wing), "Room", 2)],
        ),
        Err(InventorySnapshotDecodeError::InvalidValue { table: "drawers", column: "adjectiveBitmap", .. })
    ));
}

#[test]
fn rejects_wrong_wing_depth_instead_of_projecting_names() {
    let root = Uuid::from_u128(1);
    let wing = Uuid::from_u128(2);
    let room = Uuid::from_u128(3);

    assert!(matches!(
        decode_inventory_snapshot(
            &[drawer("drawer-1", room)],
            &[node(root, None, "Estate", 0), node(wing, Some(root), "Wing", 2), node(room, Some(wing), "Room", 2)],
        ),
        Err(InventorySnapshotDecodeError::InvalidAncestry { .. })
    ));
}

#[test]
fn rejects_empty_lineage_instead_of_minting_identity() {
    let root = Uuid::from_u128(1);
    let wing = Uuid::from_u128(2);
    let room = Uuid::from_u128(3);
    let mut corrupt = drawer("drawer-1", room);
    corrupt
        .values
        .insert("lineageID".to_string(), TypedValue::Text(String::new()));

    assert!(matches!(
        decode_inventory_snapshot(
            &[corrupt],
            &[
                node(root, None, "Estate", 0),
                node(wing, Some(root), "Wing", 1),
                node(room, Some(wing), "Room", 2),
            ],
        ),
        Err(InventorySnapshotDecodeError::InvalidValue {
            table: "drawers",
            column: "lineageID",
            ..
        })
    ));
}

#[test]
fn accepts_unrelated_wing_and_room_tombstones_while_validating_live_ancestry() {
    let root = Uuid::from_u128(1);
    let wing = Uuid::from_u128(2);
    let room = Uuid::from_u128(3);
    let retired_wing = Uuid::from_u128(4);
    let retired_room = Uuid::from_u128(5);

    let entries = decode_inventory_snapshot(
        &[drawer("drawer-1", room)],
        &[
            node(root, None, "Estate", 0),
            node(wing, Some(root), "Wing", 1),
            node(room, Some(wing), "Room", 2),
            tombstoned_node(retired_wing, Some(root), "Retired Wing", 1),
            tombstoned_node(retired_room, Some(retired_wing), "Retired Room", 2),
        ],
    )
    .expect("unrelated historical tombstones must not break current inventory");

    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].wing, "Wing");
    assert_eq!(entries[0].room, "Room");
}
