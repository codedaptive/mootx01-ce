//! Production lower-kit adapter for the typed v2 memory-list service.
//!
//! The selected surface supplies admission through `MemoryListAuthorizationAuthority`.
//! This adapter owns only the bounded capture, strict Locus interpretation, and
//! complete authorized projection; it never calls a v1 runner or a paged query.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::inventory_snapshot_decode::{
    decode_inventory_snapshot, decode_node_row, InventorySnapshotEntry, InventorySnapshotNode,
};
use persistence_kit::inventory_snapshot::{InventorySnapshotError, InventorySnapshotLimits};
use serde_json::{Map, Value};
use uuid::Uuid;

use super::memory_list::{
    MemoryListAuthorization, MemoryListError, MemoryListFilter, MemoryListSnapshot,
    MemoryListSnapshotProvider, MemoryListSnapshotRow,
};

/// Compact memory-list subjects match Swift's Unicode-scalar response bound.
const COMPACT_SUBJECT_SCALAR_LIMIT: usize = 512;

/// The selected surface owns policy and estate selection. Generation is
/// returned by that authority and is never synthesized from a local counter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListAuthorizedContext {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub context_id: String,
    pub policy_version: String,
    pub authorization_generation: String,
}

impl MemoryListAuthorizedContext {
    fn public_authorization(&self) -> MemoryListAuthorization {
        MemoryListAuthorization {
            caller_binding: self.caller_binding.clone(),
            context_id: self.context_id.clone(),
            policy_version: self.policy_version.clone(),
        }
    }
}

/// Injected admission and generation authority. Its implementation belongs to
/// selected-surface wiring, where the real caller, request context, policy,
/// expiry, and selected estate are available.
pub trait MemoryListAuthorizationAuthority: Send + Sync {
    fn authorize_memory_list(
        &self,
        requested_estate_id: Option<Uuid>,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError>;

    fn revalidate_memory_list(
        &self,
        authorization: &MemoryListAuthorization,
    ) -> Result<MemoryListAuthorizedContext, MemoryListError>;
}

/// Concrete v2 provider over the coordinator's registered production storage.
/// The coordinator is mutexed because its runtime registry has interior
/// mutability and must remain behind the transport's serialized access seam.
pub struct AriaMemoryListSnapshotProvider<A> {
    coordinator: Arc<Mutex<EstateCoordinator>>,
    authority: A,
}

impl<A> AriaMemoryListSnapshotProvider<A> {
    pub fn new(coordinator: Arc<Mutex<EstateCoordinator>>, authority: A) -> Self {
        Self {
            coordinator,
            authority,
        }
    }
}

impl<A: MemoryListAuthorizationAuthority> MemoryListSnapshotProvider
    for AriaMemoryListSnapshotProvider<A>
{
    fn authorize(
        &self,
        requested_estate_id: Option<Uuid>,
    ) -> Result<MemoryListAuthorization, MemoryListError> {
        let context = self.authority.authorize_memory_list(requested_estate_id)?;
        validate_context(&context, None)?;
        Ok(context.public_authorization())
    }

    fn capture_authorized_inventory(
        &self,
        authorization: &MemoryListAuthorization,
        wing: &str,
        room: Option<&str>,
        filter: Option<MemoryListFilter>,
    ) -> Result<MemoryListSnapshot, MemoryListError> {
        // Admission is checked before acquiring the storage Arc and before the
        // capture transaction begins.
        let before = self.authority.revalidate_memory_list(authorization)?;
        validate_context(&before, Some(authorization))?;
        let storage = self
            .coordinator
            .lock()
            .map_err(|_| inventory_unavailable())?
            .inventory_snapshot_storage(&before.estate_handle)
            .map_err(|_| inventory_unavailable())?;
        let snapshot = storage
            .capture_inventory_snapshot(InventorySnapshotLimits::production())
            .map_err(map_capture_error)?;

        // A changed authority or generation after capture invalidates the
        // entire result; no row from the captured state may be released.
        let after_capture = self.authority.revalidate_memory_list(authorization)?;
        validate_same_context(&before, &after_capture)?;

        let entries = decode_inventory_snapshot(&snapshot.drawers, &snapshot.nodes)
            .map_err(|_| inventory_unavailable())?;
        let nodes = decode_nodes(&snapshot.nodes)?;
        let rows = project_complete_inventory(entries, &nodes, wing, room, filter)?;

        // Keep the revalidation closest to release as well as around capture.
        let before_return = self.authority.revalidate_memory_list(authorization)?;
        validate_same_context(&before, &before_return)?;
        Ok(MemoryListSnapshot {
            estate_id: before.estate_id,
            authorization_generation: before.authorization_generation,
            drawer_rows: snapshot.drawers.len(),
            node_rows: snapshot.nodes.len(),
            serialized_row_bytes: snapshot.serialized_row_bytes(),
            rows,
        })
    }

    fn revalidate(&self, authorization: &MemoryListAuthorization) -> Result<(), MemoryListError> {
        let context = self.authority.revalidate_memory_list(authorization)?;
        validate_context(&context, Some(authorization))
    }
}

fn decode_nodes(
    rows: &[persistence_kit::types::StorageRow],
) -> Result<HashMap<Uuid, InventorySnapshotNode>, MemoryListError> {
    rows.iter()
        .map(|row| decode_node_row(row).map(|node| (node.id, node)))
        .collect::<Result<HashMap<_, _>, _>>()
        .map_err(|_| inventory_unavailable())
}

fn project_complete_inventory(
    entries: Vec<InventorySnapshotEntry>,
    nodes: &HashMap<Uuid, InventorySnapshotNode>,
    wing: &str,
    room: Option<&str>,
    filter: Option<MemoryListFilter>,
) -> Result<Vec<MemoryListSnapshotRow>, MemoryListError> {
    Ok(entries
        .into_iter()
        // Capture provenance is immutable and independently sensitivity-tagged.
        // Inspect its raw six-bit field so reserved values fail closed rather
        // than taking the general decoder's legacy Normal fallback.
        .filter(|entry| public_capture_provenance(entry.drawer.provenance))
        .map(|entry| {
            project_entry(
                entry,
                nodes,
                filter == Some(MemoryListFilter::MissingSubject),
            )
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|row| {
            row.eligibility_state == "current"
                && row.visibility_state == "bulk_exportable"
                && row.ancestry_names.first().is_some_and(|name| name == wing)
                && room.map_or(true, |requested| {
                    row.ancestry_names
                        .get(1)
                        .is_some_and(|name| name == requested)
                })
                && (filter != Some(MemoryListFilter::MissingSubject)
                    || !row.projection.contains_key("subject"))
        })
        .collect::<Vec<_>>())
}

pub(crate) fn public_capture_provenance(provenance: i64) -> bool {
    matches!((provenance >> 30) & 0x3f, 0 | 16)
}

fn project_entry(
    entry: InventorySnapshotEntry,
    nodes: &HashMap<Uuid, InventorySnapshotNode>,
    omit_provenance: bool,
) -> Result<MemoryListSnapshotRow, MemoryListError> {
    // Public memory-list identity is intentionally narrower than Locus's
    // general TEXT drawer key: a non-UUID key makes the complete v2 inventory
    // unavailable rather than being skipped or fabricated.
    let memory_id = Uuid::parse_str(&entry.drawer.id).map_err(|_| inventory_unavailable())?;
    // The parent is the room, or a chest under it (ADR-026): the public
    // inventory names rooms, so a chest parent hops to its room.
    let parent = nodes
        .get(&entry.drawer.parent_node_id)
        .ok_or_else(inventory_unavailable)?;
    let room = if parent.depth == 3 {
        let room_id = parent.parent_id.ok_or_else(inventory_unavailable)?;
        nodes.get(&room_id).ok_or_else(inventory_unavailable)?
    } else {
        parent
    };
    let wing_id = room.parent_id.ok_or_else(inventory_unavailable)?;
    let wing = nodes.get(&wing_id).ok_or_else(inventory_unavailable)?;
    let root_id = wing.parent_id.ok_or_else(inventory_unavailable)?;
    let root = nodes.get(&root_id).ok_or_else(inventory_unavailable)?;
    if root.parent_id.is_some()
        || room.depth != 2
        || wing.depth != 1
        || root.depth != 0
        || room.display_name != entry.room
        || wing.display_name != entry.wing
        || root.display_name != entry.root
    {
        return Err(inventory_unavailable());
    }

    let cluster_a = matches!(entry.drawer.adjective_bitmap & 0x3f, 0 | 1 | 2 | 3);
    let eligible = entry.drawer.is_eligible() && cluster_a;
    // This fixed sensitivity ceiling is deliberately independent of grants or
    // caller-provided elevation. Restricted and Secret rows never enter this
    // endpoint's public inventory.
    let bulk_visible = entry.drawer.is_bulk_visible();
    let provenance = provenance_name(entry.drawer.provenance)?;
    let projection = public_projection(
        memory_id,
        Some(provenance),
        entry.drawer.subject.as_deref(),
        omit_provenance,
    );
    Ok(MemoryListSnapshotRow {
        memory_id,
        // Estate identity is carried separately. The public ancestry contains
        // the user-facing wing and room; root was validated above but omitted.
        ancestry_ids: vec![wing.id, room.id],
        ancestry_names: vec![wing.display_name.clone(), room.display_name.clone()],
        eligibility_state: if eligible { "current" } else { "not_current" }.to_owned(),
        visibility_state: if bulk_visible {
            "bulk_exportable"
        } else {
            "not_bulk_exportable"
        }
        .to_owned(),
        projection,
    })
}

/// Construct the complete public projection from already validated storage
/// fields. Exposed only within this crate so the production-provider vectors
/// can prove Unicode capping and filter-specific omission before revisioning.
pub(crate) fn public_projection(
    memory_id: Uuid,
    provenance: Option<&str>,
    subject: Option<&str>,
    omit_provenance: bool,
) -> Map<String, Value> {
    let mut projection = Map::from_iter([(
        "fetch".to_owned(),
        Value::Object(Map::from_iter([
            (
                "tool".to_owned(),
                Value::String("moot_memory_get".to_owned()),
            ),
            (
                "arguments".to_owned(),
                Value::Object(Map::from_iter([(
                    "memory_id".to_owned(),
                    Value::String(memory_id.hyphenated().to_string()),
                )])),
            ),
        ])),
    )]);
    if !omit_provenance {
        if let Some(provenance) = provenance {
            projection.insert(
                "provenance".to_owned(),
                Value::String(provenance.to_owned()),
            );
        }
    }
    if let Some(subject) = subject {
        projection.insert(
            "subject".to_owned(),
            Value::String(subject.chars().take(COMPACT_SUBJECT_SCALAR_LIMIT).collect()),
        );
    }
    projection
}

fn provenance_name(provenance: i64) -> Result<&'static str, MemoryListError> {
    match provenance & 0x3f {
        0 => Ok("user"),
        1 => Ok("observed"),
        2 => Ok("imported"),
        3 => Ok("canonical"),
        4 => Ok("derived"),
        5 => Ok("federation_aggregate"),
        6 => Ok("tier_aggregate"),
        7 => Ok("paired_estate"),
        8 => Ok("ambient"),
        9 => Ok("actuator"),
        _ => Err(inventory_unavailable()),
    }
}

fn validate_context(
    context: &MemoryListAuthorizedContext,
    expected: Option<&MemoryListAuthorization>,
) -> Result<(), MemoryListError> {
    if context.estate_id != Uuid::from_bytes(context.estate_handle.estate_uuid)
        || context.authorization_generation.is_empty()
        || context.caller_binding.is_empty()
        || context.context_id.is_empty()
        || context.policy_version.is_empty()
    {
        return Err(inventory_unavailable());
    }
    if let Some(expected) = expected {
        if context.public_authorization() != *expected {
            return Err(inventory_unavailable());
        }
    }
    Ok(())
}

fn validate_same_context(
    expected: &MemoryListAuthorizedContext,
    actual: &MemoryListAuthorizedContext,
) -> Result<(), MemoryListError> {
    validate_context(actual, Some(&expected.public_authorization()))?;
    if actual.estate_id != expected.estate_id
        || actual.estate_handle != expected.estate_handle
        || actual.authorization_generation != expected.authorization_generation
    {
        return Err(inventory_unavailable());
    }
    Ok(())
}

fn map_capture_error(error: InventorySnapshotError) -> MemoryListError {
    match error {
        InventorySnapshotError::RowLimitExceeded { .. }
        | InventorySnapshotError::ByteLimitExceeded { .. }
        | InventorySnapshotError::LimitExceedsProduction { .. } => {
            MemoryListError::inventory_too_large(
                "The complete authorized memory inventory exceeds the snapshot limit.",
            )
        }
        InventorySnapshotError::Storage(_) => inventory_unavailable(),
    }
}

fn inventory_unavailable() -> MemoryListError {
    MemoryListError::operational(
        "inventory_unavailable",
        "The complete authorized memory inventory is unavailable.",
        true,
    )
}
