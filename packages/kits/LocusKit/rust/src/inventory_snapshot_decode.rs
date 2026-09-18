//! Strict, compact decoding of a captured drawers/nodes inventory snapshot.
//!
//! This is deliberately separate from scan decoding. Scan paths preserve
//! availability by skipping corrupt rows or accepting historical fallbacks;
//! an inventory surface must instead reject a snapshot it cannot account for.

use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fmt;

use persistence_kit::types::{StorageRow, TypedValue};
use uuid::Uuid;

use crate::node::Node;

const DRAWERS: &str = "drawers";
const NODES: &str = "nodes";

/// Compact drawer fields needed by inventory projections.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventorySnapshotDrawer {
    pub id: String,
    pub lineage_id: Uuid,
    /// The drawer's parent node: its room, or a chest under its room (ADR-026).
    pub parent_node_id: Uuid,
    pub filed_at: i64,
    pub tombstoned_at: Option<i64>,
    pub provenance: i64,
    pub adjective_bitmap: i64,
    pub subject: Option<String>,
}

impl InventorySnapshotDrawer {
    /// Current inventory eligibility follows the estate's non-tombstoned
    /// drawer predicate.
    pub fn is_eligible(&self) -> bool {
        self.tombstoned_at.is_none()
    }

    /// Bulk visibility follows the adjective sensitivity field (bits 6–11).
    /// Decode rejects reserved values, so this never falls back to Normal.
    pub fn is_bulk_visible(&self) -> bool {
        matches!(sensitivity_raw(self.adjective_bitmap), 0 | 16)
    }
}

/// Compact node fields needed to prove drawer containment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventorySnapshotNode {
    pub id: Uuid,
    pub parent_id: Option<Uuid>,
    pub display_name: String,
    pub lookup_name: String,
    pub depth: i32,
    pub lifecycle: i32,
    pub tombstoned_at: Option<i64>,
}

/// A drawer whose room, wing, and estate-root ancestry was verified in one
/// captured snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InventorySnapshotEntry {
    pub drawer: InventorySnapshotDrawer,
    pub room: String,
    pub wing: String,
    pub root: String,
}

/// The snapshot contract is fail-closed: no malformed field is replaced with
/// a generated ID, empty string, or zero value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InventorySnapshotDecodeError {
    MissingColumn { table: &'static str, column: &'static str },
    InvalidValue { table: &'static str, column: &'static str, detail: String },
    DuplicateNode { id: Uuid },
    InvalidAncestry { drawer_id: String, detail: String },
}

impl fmt::Display for InventorySnapshotDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingColumn { table, column } => write!(f, "{table}.{column} is missing"),
            Self::InvalidValue { table, column, detail } => {
                write!(f, "{table}.{column} is invalid: {detail}")
            }
            Self::DuplicateNode { id } => write!(f, "nodes contains duplicate id {id}"),
            Self::InvalidAncestry { drawer_id, detail } => {
                write!(f, "drawer {drawer_id} has invalid ancestry: {detail}")
            }
        }
    }
}

impl Error for InventorySnapshotDecodeError {}

/// Decode all supplied rows and prove every drawer has an active
/// drawer -> room -> wing -> root chain. A corrupt or incomplete row rejects
/// the whole snapshot rather than producing a partial inventory.
pub fn decode_inventory_snapshot(
    drawer_rows: &[StorageRow],
    node_rows: &[StorageRow],
) -> Result<Vec<InventorySnapshotEntry>, InventorySnapshotDecodeError> {
    let nodes = decode_nodes(node_rows)?;
    let node_by_id = nodes
        .iter()
        .map(|node| (node.id, node))
        .collect::<HashMap<_, _>>();

    drawer_rows
        .iter()
        .map(|row| {
            let drawer = decode_drawer_row(row)?;
            // The parent is a room, or a chest under a room (ADR-026, spec
            // § 12). Chests are internal, so the proven chain is room, wing,
            // root either way.
            let room_id = match node_by_id.get(&drawer.parent_node_id) {
                Some(node) if node.depth == crate::node_store::NodeStore::CHEST_DEPTH => {
                    node.parent_id.ok_or_else(|| InventorySnapshotDecodeError::InvalidAncestry {
                        drawer_id: drawer.id.clone(),
                        detail: "chest has no room parent".to_string(),
                    })?
                }
                _ => drawer.parent_node_id,
            };
            let room = require_role(&node_by_id, room_id, 2, "room", &drawer.id)?;
            let wing_id = room.parent_id.ok_or_else(|| InventorySnapshotDecodeError::InvalidAncestry {
                drawer_id: drawer.id.clone(),
                detail: "room has no wing parent".to_string(),
            })?;
            let wing = require_role(&node_by_id, wing_id, 1, "wing", &drawer.id)?;
            let root_id = wing.parent_id.ok_or_else(|| InventorySnapshotDecodeError::InvalidAncestry {
                drawer_id: drawer.id.clone(),
                detail: "wing has no root parent".to_string(),
            })?;
            let root = require_role(&node_by_id, root_id, 0, "root", &drawer.id)?;
            if root.parent_id.is_some() {
                return Err(InventorySnapshotDecodeError::InvalidAncestry {
                    drawer_id: drawer.id.clone(),
                    detail: "root has a parent".to_string(),
                });
            }
            let chain = [room.id, wing.id, root.id];
            if chain.iter().copied().collect::<HashSet<_>>().len() != chain.len() {
                return Err(InventorySnapshotDecodeError::InvalidAncestry {
                    drawer_id: drawer.id.clone(),
                    detail: "containment cycle".to_string(),
                });
            }
            Ok(InventorySnapshotEntry {
                drawer,
                room: room.display_name.clone(),
                wing: wing.display_name.clone(),
                root: root.display_name.clone(),
            })
        })
        .collect()
}

/// Decode one drawer row without the permissive legacy scan fallbacks.
pub fn decode_drawer_row(
    row: &StorageRow,
) -> Result<InventorySnapshotDrawer, InventorySnapshotDecodeError> {
    let id = required_text(DRAWERS, "id", row)?;
    if id.is_empty() {
        return invalid(DRAWERS, "id", "must not be empty");
    }
    let lineage_id = required_uuid(DRAWERS, "lineageID", row)?;
    let parent_node_id = required_uuid(DRAWERS, "parent_node_id", row)?;
    let filed_at = required_timestamp(DRAWERS, "filedAt", row)?;
    let tombstoned_at = optional_timestamp(DRAWERS, "tombstonedAt", row)?;
    let provenance = required_bitmap(DRAWERS, "provenance", row)?;
    let adjective_bitmap = required_bitmap(DRAWERS, "adjectiveBitmap", row)?;
    validate_adjective_bitmap(adjective_bitmap)?;
    let subject = optional_text(DRAWERS, "subject", row)?;
    Ok(InventorySnapshotDrawer {
        id,
        lineage_id,
        parent_node_id,
        filed_at,
        tombstoned_at,
        provenance,
        adjective_bitmap,
        subject,
    })
}

/// Decode one node row without the permissive empty-string/zero fallbacks.
pub fn decode_node_row(
    row: &StorageRow,
) -> Result<InventorySnapshotNode, InventorySnapshotDecodeError> {
    let id = required_uuid(NODES, "id", row)?;
    let parent_id = optional_uuid(NODES, "parent_id", row)?;
    let display_name = required_text(NODES, "display_name", row)?;
    if display_name.trim().is_empty() {
        return invalid(NODES, "display_name", "must not be blank");
    }
    let lookup_name = required_text(NODES, "lookup_name", row)?;
    if lookup_name != Node::normalize_lookup_name(&display_name) {
        return invalid(NODES, "lookup_name", "does not normalize from display_name");
    }
    let depth = required_i32(NODES, "depth", row)?;
    // 0 estate, 1 wing, 2 room, 3 chest (ADR-026, spec § 12).
    if !(0..=crate::node_store::NodeStore::CHEST_DEPTH).contains(&depth) {
        return invalid(NODES, "depth", "must be 0, 1, 2, or 3");
    }
    let lifecycle = required_i32(NODES, "lifecycle", row)?;
    if !matches!(lifecycle, 0 | 1) {
        return invalid(NODES, "lifecycle", "must be active (0) or tombstoned (1)");
    }
    let tombstoned_at = optional_timestamp(NODES, "tombstoned_at", row)?;
    let tombstoned_hlc = optional_hlc(NODES, "tombstoned_hlc", row)?;
    match (lifecycle, tombstoned_at, tombstoned_hlc) {
        (0, None, None) | (1, Some(_), Some(_)) => {}
        (0, _, _) => return invalid(NODES, "lifecycle", "active node has tombstone metadata"),
        (1, _, _) => return invalid(NODES, "lifecycle", "tombstoned node lacks tombstone metadata"),
        _ => unreachable!("lifecycle is constrained above"),
    }
    Ok(InventorySnapshotNode {
        id,
        parent_id,
        display_name,
        lookup_name,
        depth,
        lifecycle,
        tombstoned_at,
    })
}

fn decode_nodes(rows: &[StorageRow]) -> Result<Vec<InventorySnapshotNode>, InventorySnapshotDecodeError> {
    let mut ids = HashSet::with_capacity(rows.len());
    let mut nodes = Vec::with_capacity(rows.len());
    for row in rows {
        let node = decode_node_row(row)?;
        if !ids.insert(node.id) {
            return Err(InventorySnapshotDecodeError::DuplicateNode { id: node.id });
        }
        nodes.push(node);
    }
    Ok(nodes)
}

fn require_role<'a>(
    nodes: &HashMap<Uuid, &'a InventorySnapshotNode>,
    id: Uuid,
    depth: i32,
    role: &str,
    drawer_id: &str,
) -> Result<&'a InventorySnapshotNode, InventorySnapshotDecodeError> {
    let node = nodes.get(&id).ok_or_else(|| InventorySnapshotDecodeError::InvalidAncestry {
        drawer_id: drawer_id.to_string(),
        detail: format!("{role} node {id} is absent"),
    })?;
    if node.depth != depth {
        return Err(InventorySnapshotDecodeError::InvalidAncestry {
            drawer_id: drawer_id.to_string(),
            detail: format!("{role} node {id} has depth {}, expected {depth}", node.depth),
        });
    }
    if node.lifecycle != 0 || node.tombstoned_at.is_some() {
        return Err(InventorySnapshotDecodeError::InvalidAncestry {
            drawer_id: drawer_id.to_string(),
            detail: format!("{role} node {id} is not active"),
        });
    }
    Ok(node)
}

fn required_text(table: &'static str, column: &'static str, row: &StorageRow) -> Result<String, InventorySnapshotDecodeError> {
    match row.get(column) {
        Some(TypedValue::Text(value)) => Ok(value.clone()),
        Some(value) => invalid(table, column, format!("expected text, got {}", value.type_description())),
        None => Err(InventorySnapshotDecodeError::MissingColumn { table, column }),
    }
}

fn optional_text(table: &'static str, column: &'static str, row: &StorageRow) -> Result<Option<String>, InventorySnapshotDecodeError> {
    match row.get(column) {
        None | Some(TypedValue::Null) => Ok(None),
        Some(TypedValue::Text(value)) => Ok(Some(value.clone())),
        Some(value) => invalid(table, column, format!("expected text or null, got {}", value.type_description())),
    }
}

fn required_uuid(table: &'static str, column: &'static str, row: &StorageRow) -> Result<Uuid, InventorySnapshotDecodeError> {
    let text = required_text(table, column, row)?;
    Uuid::parse_str(&text).map_err(|_| InventorySnapshotDecodeError::InvalidValue {
        table,
        column,
        detail: "expected UUID text".to_string(),
    })
}

fn optional_uuid(table: &'static str, column: &'static str, row: &StorageRow) -> Result<Option<Uuid>, InventorySnapshotDecodeError> {
    match row.get(column) {
        None | Some(TypedValue::Null) => Ok(None),
        Some(TypedValue::Text(value)) => Uuid::parse_str(value).map(Some).map_err(|_| {
            InventorySnapshotDecodeError::InvalidValue { table, column, detail: "expected UUID text or null".to_string() }
        }),
        Some(value) => invalid(table, column, format!("expected UUID text or null, got {}", value.type_description())),
    }
}

fn required_i32(table: &'static str, column: &'static str, row: &StorageRow) -> Result<i32, InventorySnapshotDecodeError> {
    match row.get(column) {
        Some(TypedValue::Int(value)) => i32::try_from(*value).map_err(|_| InventorySnapshotDecodeError::InvalidValue {
            table, column, detail: "outside i32 range".to_string(),
        }),
        Some(value) => invalid(table, column, format!("expected int, got {}", value.type_description())),
        None => Err(InventorySnapshotDecodeError::MissingColumn { table, column }),
    }
}

fn required_timestamp(table: &'static str, column: &'static str, row: &StorageRow) -> Result<i64, InventorySnapshotDecodeError> {
    match row.get(column) {
        Some(TypedValue::Timestamp(value)) | Some(TypedValue::Int(value)) => Ok(*value),
        Some(value) => invalid(table, column, format!("expected timestamp, got {}", value.type_description())),
        None => Err(InventorySnapshotDecodeError::MissingColumn { table, column }),
    }
}

fn optional_timestamp(table: &'static str, column: &'static str, row: &StorageRow) -> Result<Option<i64>, InventorySnapshotDecodeError> {
    match row.get(column) {
        None | Some(TypedValue::Null) => Ok(None),
        Some(TypedValue::Timestamp(value)) | Some(TypedValue::Int(value)) => Ok(Some(*value)),
        Some(value) => invalid(table, column, format!("expected timestamp or null, got {}", value.type_description())),
    }
}

fn optional_hlc(table: &'static str, column: &'static str, row: &StorageRow) -> Result<Option<()>, InventorySnapshotDecodeError> {
    match row.get(column) {
        None | Some(TypedValue::Null) => Ok(None),
        Some(TypedValue::Hlc(_)) | Some(TypedValue::Int(_)) => Ok(Some(())),
        Some(value) => invalid(table, column, format!("expected HLC or null, got {}", value.type_description())),
    }
}

fn required_bitmap(table: &'static str, column: &'static str, row: &StorageRow) -> Result<i64, InventorySnapshotDecodeError> {
    match row.get(column) {
        Some(TypedValue::Bitmap(value)) | Some(TypedValue::Int(value)) => Ok(*value),
        Some(value) => invalid(table, column, format!("expected bitmap, got {}", value.type_description())),
        None => Err(InventorySnapshotDecodeError::MissingColumn { table, column }),
    }
}

fn validate_adjective_bitmap(bitmap: i64) -> Result<(), InventorySnapshotDecodeError> {
    let state = bitmap & 0x3f;
    if !matches!(state, 0 | 1 | 2 | 3 | 16 | 17 | 18 | 19 | 32 | 33) {
        return invalid(DRAWERS, "adjectiveBitmap", "has reserved state field");
    }
    if !matches!(sensitivity_raw(bitmap), 0 | 16 | 32 | 48) {
        return invalid(DRAWERS, "adjectiveBitmap", "has reserved sensitivity field");
    }
    Ok(())
}

fn sensitivity_raw(bitmap: i64) -> i64 {
    (bitmap >> 6) & 0x3f
}

fn invalid<T>(
    table: &'static str,
    column: &'static str,
    detail: impl Into<String>,
) -> Result<T, InventorySnapshotDecodeError> {
    Err(InventorySnapshotDecodeError::InvalidValue { table, column, detail: detail.into() })
}
