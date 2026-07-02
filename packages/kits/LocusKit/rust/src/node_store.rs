//! Storage for the estate's containment tree (ADR-017 §§1–8).
//!
//! NodeStore is the Rust parallel of the Swift `NodeStore` actor.
//! It wraps PersistenceKit's `Storage` and provides:
//!   - create-on-demand resolution (§7): derive lookup_name from
//!     display_name (§8), match active-only by lookup_name under
//!     parent_id, create if absent, return existing if present.
//!     Tombstoned nodes are invisible to resolution (§5).
//!   - CRUD: get_node, child_nodes (active only), tombstone_node,
//!     root_node.
//!   - Invariant enforcement at write time: I-NT-1 single root,
//!     I-NT-2 depth consistency (parent.depth + 1, max 2),
//!     I-NT-4 name uniqueness within parent (active only),
//!     I-NT-5 referential integrity on parent_id.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `public actor NodeStore` → Rust sync `NodeStore`.
//!   Persistence-kit Rust trait surface is sync; the underlying
//!   backend serialises access via an internal Mutex.
//! - Swift `async throws` → `Result<T, LocusKitError>`.
//! - Swift `Date` → Rust `i64` epoch-seconds parameter on every
//!   mutation method (deterministic-clock rule).
//! - Swift `UUID` → Rust `uuid::Uuid`.
//! - Swift `HLC` → Rust `substrate_types::hlc::HLC`.

use crate::error::LocusKitError;
use crate::node::Node;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use substrate_types::hlc::{HLCGenerator, HLC};
use substrate_types::merkle_root::MerkleRoot;
use uuid::Uuid;

pub(crate) const T_NODES: &str = "nodes";

/// Column reference shorthand for the nodes table.
fn col(name: &str) -> Column {
    Column::new(T_NODES, name)
}

/// Storage for the estate's containment tree.
///
/// Constructed over an `Arc<dyn Storage>` whose LocusKit schema has
/// already been opened. The HLC generator is interior-mutable because
/// `send()` mutates and the store methods take `&self`.
pub struct NodeStore {
    pub(crate) storage: Arc<dyn Storage>,
    hlc: Mutex<HLCGenerator>,
}

impl NodeStore {
    /// Construct over a storage handle. The schema must already be
    /// opened (LocusKitSchema). The HLC generator is optional: None =
    /// top mode (make own clock), Some = holder mode.
    pub fn new(storage: Arc<dyn Storage>, hlc: Option<HLCGenerator>) -> Self {
        Self {
            storage,
            hlc: Mutex::new(hlc.unwrap_or_else(|| HLCGenerator::new(0))),
        }
    }

    // ------------------------------------------------------------------
    // Create-on-demand resolution (§7)
    // ------------------------------------------------------------------

    /// Resolve or create a node under the given parent.
    ///
    /// Derives `lookup_name` from `display_name` (§8). Searches for an
    /// active node with that lookup_name under `parent_id`. If found,
    /// returns the existing node (first-casing wins). If absent, creates
    /// a new node. Tombstoned nodes are invisible to resolution (§5).
    ///
    /// Enforces: I-NT-2 (depth = parent.depth + 1, max 2),
    /// I-NT-4 (no duplicate active lookup_name under same parent),
    /// I-NT-5 (parent must exist).
    pub fn create_node(
        &self,
        display_name: &str,
        parent_id: Uuid,
        now: i64,
    ) -> Result<Node, LocusKitError> {
        let lookup_name = Node::normalize_lookup_name(display_name);

        // I-NT-5: parent must exist.
        let parent = self.get_node(parent_id)?.ok_or_else(|| {
            LocusKitError::InvalidContent(format!(
                "NodeStore: parent node {} does not exist (I-NT-5)",
                parent_id
            ))
        })?;

        // I-NT-2: depth = parent.depth + 1, max 2.
        let child_depth = parent.depth + 1;
        if child_depth > 2 {
            return Err(LocusKitError::InvalidContent(format!(
                "NodeStore: depth {} exceeds maximum 2 (I-NT-2)",
                child_depth
            )));
        }

        // Resolution: find active node by lookup_name under this parent.
        if let Some(existing) = self.find_active_node(&lookup_name, parent_id)? {
            return Ok(existing);
        }

        // No active match — create.
        let id = Uuid::new_v4();
        let now_ms = now; // `now` is already epoch-ms (ADR-023)
        let created_hlc = self.hlc.lock().unwrap().send(now_ms);

        // Schema declares id/parent_id as text columns, so store as
        // TypedValue::Text to match. TypedValue::Uuid would create a
        // type mismatch in InMemoryStorage's evaluate_predicate (which
        // compares enum variants, not semantic equivalence).
        let mut values = BTreeMap::new();
        values.insert("id".into(), TypedValue::Text(id.to_string()));
        values.insert("parent_id".into(), TypedValue::Text(parent_id.to_string()));
        values.insert("display_name".into(), TypedValue::Text(display_name.to_string()));
        values.insert("lookup_name".into(), TypedValue::Text(lookup_name.clone()));
        values.insert("depth".into(), TypedValue::Int(child_depth as i64));
        values.insert("lifecycle".into(), TypedValue::Int(0));
        values.insert("created_hlc".into(), TypedValue::Hlc(created_hlc));
        values.insert("created_at".into(), TypedValue::Timestamp(now));
        values.insert("updated_at".into(), TypedValue::Timestamp(now));

        // Race safety: the Mutex serialises all writes, so the
        // check-then-insert above is atomic. No concurrent create
        // can interleave between find_active_node and this insert.
        let _ = self
            .storage
            .row_store()
            .insert(T_NODES, values)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;

        // Re-fetch to return the stored node with all columns populated.
        self.find_active_node(&lookup_name, parent_id)?
            .ok_or_else(|| {
                LocusKitError::DatabaseUnavailable(
                    "NodeStore: create-on-demand resolution failed after insert".to_string(),
                )
            })
    }

    /// Create the estate root node (depth 0, no parent).
    ///
    /// Enforces I-NT-1: exactly one root. If a root already exists,
    /// returns the existing root.
    pub fn create_root(
        &self,
        display_name: &str,
        now: i64,
    ) -> Result<Node, LocusKitError> {
        // Check if root already exists (I-NT-1).
        if let Some(existing) = self.root_node()? {
            return Ok(existing);
        }

        let lookup_name = Node::normalize_lookup_name(display_name);
        let id = Uuid::new_v4();
        let now_ms = now; // `now` is already epoch-ms (ADR-023)
        let created_hlc = self.hlc.lock().unwrap().send(now_ms);

        let mut values = BTreeMap::new();
        values.insert("id".into(), TypedValue::Text(id.to_string()));
        values.insert("display_name".into(), TypedValue::Text(display_name.to_string()));
        values.insert("lookup_name".into(), TypedValue::Text(lookup_name));
        values.insert("depth".into(), TypedValue::Int(0));
        values.insert("lifecycle".into(), TypedValue::Int(0));
        values.insert("created_hlc".into(), TypedValue::Hlc(created_hlc));
        values.insert("created_at".into(), TypedValue::Timestamp(now));
        values.insert("updated_at".into(), TypedValue::Timestamp(now));

        let _ = self
            .storage
            .row_store()
            .insert(T_NODES, values)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;

        self.root_node()?.ok_or_else(|| {
            LocusKitError::DatabaseUnavailable("NodeStore: root creation failed".to_string())
        })
    }

    // ------------------------------------------------------------------
    // Read
    // ------------------------------------------------------------------

    /// Fetch a node by its UUID.
    pub fn get_node(&self, id: Uuid) -> Result<Option<Node>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_NODES,
                Some(&StoragePredicate::Eq(col("id"), TypedValue::Text(id.to_string()))),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        match rows.first() {
            Some(row) => Ok(Some(node_from_row(row)?)),
            None => Ok(None),
        }
    }

    /// The estate root node (depth 0, parent_id IS NULL, active).
    pub fn root_node(&self) -> Result<Option<Node>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::IsNull(col("parent_id")),
                    StoragePredicate::Eq(col("depth"), TypedValue::Int(0)),
                    StoragePredicate::Eq(col("lifecycle"), TypedValue::Int(0)),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        match rows.first() {
            Some(row) => Ok(Some(node_from_row(row)?)),
            None => Ok(None),
        }
    }

    /// Active children of a node, ordered by lookup_name.
    pub fn child_nodes(&self, parent_id: Uuid) -> Result<Vec<Node>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(col("parent_id"), TypedValue::Text(parent_id.to_string())),
                    StoragePredicate::Eq(col("lifecycle"), TypedValue::Int(0)),
                ])),
                &[OrderClause {
                    column: col("lookup_name"),
                    direction: OrderDirection::Ascending,
                }],
                None,
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        rows.iter().map(|r| node_from_row(r)).collect()
    }

    // ------------------------------------------------------------------
    // Tombstone (§5)
    // ------------------------------------------------------------------

    /// Tombstone a node. Sets lifecycle = 1, tombstoned_hlc, tombstoned_at.
    pub fn tombstone_node(
        &self,
        id: Uuid,
        now: i64,
    ) -> Result<Option<Node>, LocusKitError> {
        let node = match self.get_node(id)? {
            Some(n) => n,
            None => return Ok(None),
        };

        if node.is_tombstoned() {
            return Ok(Some(node));
        }

        let now_ms = now; // `now` is already epoch-ms (ADR-023)
        let t_hlc = self.hlc.lock().unwrap().send(now_ms);

        let mut values = BTreeMap::new();
        values.insert("lifecycle".into(), TypedValue::Int(1));
        values.insert("tombstoned_hlc".into(), TypedValue::Hlc(t_hlc));
        values.insert("tombstoned_at".into(), TypedValue::Timestamp(now));
        values.insert("updated_at".into(), TypedValue::Timestamp(now));

        self.storage
            .row_store()
            .update(
                T_NODES,
                values,
                &StoragePredicate::Eq(col("id"), TypedValue::Text(id.to_string())),
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;

        self.get_node(id)
    }

    // ------------------------------------------------------------------
    // Merkle root update (NT-L3)
    // ------------------------------------------------------------------

    /// Update a node's merkle_root column.
    ///
    /// Called by the Merkle rollup after recomputing a subtree. The
    /// MerkleRoot's 32 raw bytes are stored as a BLOB (NT-Q1).
    pub fn update_merkle_root(
        &self,
        node_id: Uuid,
        merkle_root: &MerkleRoot,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let mut values = BTreeMap::new();
        values.insert("merkle_root".into(), TypedValue::Blob(merkle_root.bytes().to_vec()));
        values.insert("updated_at".into(), TypedValue::Timestamp(now));

        self.storage
            .row_store()
            .update(
                T_NODES,
                values,
                &StoragePredicate::Eq(col("id"), TypedValue::Text(node_id.to_string())),
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Generate an HLC timestamp. Exposed so callers outside the store
    /// can obtain a stamped HLC without directly accessing the
    /// interior-mutable `hlc` field.
    pub fn generate_hlc(&self, now_ms: i64) -> HLC {
        self.hlc.lock().unwrap().send(now_ms)
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// Find an active node by lookup_name under a parent.
    fn find_active_node(
        &self,
        lookup_name: &str,
        parent_id: Uuid,
    ) -> Result<Option<Node>, LocusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                T_NODES,
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(col("parent_id"), TypedValue::Text(parent_id.to_string())),
                    StoragePredicate::Eq(
                        col("lookup_name"),
                        TypedValue::Text(lookup_name.to_string()),
                    ),
                    StoragePredicate::Eq(col("lifecycle"), TypedValue::Int(0)),
                ])),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        match rows.first() {
            Some(row) => Ok(Some(node_from_row(row)?)),
            None => Ok(None),
        }
    }
}

// ---------------------------------------------------------------------------
// Row decoding
// ---------------------------------------------------------------------------

/// Decode a `nodes` row into a `Node`.
///
/// Handles SQLite read-back primitive decode: .Uuid and .Text for UUID
/// columns, .Hlc and .Int for HLC columns, .Timestamp and .Int for
/// date columns.
pub(crate) fn node_from_row(row: &StorageRow) -> Result<Node, LocusKitError> {
    let id = uuid_value_of("id", row.get("id"))?;
    let parent_id = opt_uuid_value_of(row.get("parent_id"));
    let depth = i64_value_of(row.get("depth"));
    let lifecycle = i64_value_of(row.get("lifecycle"));
    let created_hlc = hlc_value_of("created_hlc", row.get("created_hlc"))?;
    let tombstoned_hlc = opt_hlc_value_of(row.get("tombstoned_hlc"));
    let tombstoned_at = opt_i64_value_of(row.get("tombstoned_at"));
    let created_at = i64_value_of(row.get("created_at"));
    let updated_at = i64_value_of(row.get("updated_at"));

    Ok(Node {
        id,
        parent_id,
        display_name: string_value_of(row.get("display_name")),
        lookup_name: string_value_of(row.get("lookup_name")),
        depth: depth as i32,
        lifecycle: lifecycle as i32,
        created_hlc,
        tombstoned_hlc,
        tombstoned_at,
        merkle_root: opt_merkle_root_value_of(row.get("merkle_root")),
        created_at,
        updated_at,
        ext: opt_string_value_of(row.get("ext")),
    })
}

// ---------------------------------------------------------------------------
// Value extraction helpers
// ---------------------------------------------------------------------------

fn string_value_of(v: Option<&TypedValue>) -> String {
    match v {
        Some(TypedValue::Text(s)) => s.clone(),
        Some(TypedValue::Uuid(u)) => u.to_string(),
        _ => String::new(),
    }
}

fn opt_string_value_of(v: Option<&TypedValue>) -> Option<String> {
    match v {
        Some(TypedValue::Text(s)) => Some(s.clone()),
        _ => None,
    }
}

/// Decode a nullable BLOB column into a MerkleRoot.
fn opt_merkle_root_value_of(v: Option<&TypedValue>) -> Option<MerkleRoot> {
    match v {
        Some(TypedValue::Blob(data)) if data.len() == 32 => {
            let mut bytes = [0u8; 32];
            bytes.copy_from_slice(data);
            Some(MerkleRoot::new(bytes))
        }
        _ => None,
    }
}

fn i64_value_of(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Int(i))
        | Some(TypedValue::Bitmap(i))
        | Some(TypedValue::Timestamp(i)) => *i,
        _ => 0,
    }
}

fn opt_i64_value_of(v: Option<&TypedValue>) -> Option<i64> {
    match v {
        Some(TypedValue::Int(i))
        | Some(TypedValue::Bitmap(i))
        | Some(TypedValue::Timestamp(i)) => Some(*i),
        _ => None,
    }
}

/// Decode a required UUID column. Handles .Uuid (direct) and .Text
/// (SQLite read-back).
fn uuid_value_of(column: &str, v: Option<&TypedValue>) -> Result<Uuid, LocusKitError> {
    match v {
        Some(TypedValue::Uuid(u)) => Ok(*u),
        Some(TypedValue::Text(s)) => Uuid::parse_str(s).map_err(|_| {
            LocusKitError::CorruptStoredValue {
                table: T_NODES.to_string(),
                column: column.to_string(),
                stored_text: s.clone(),
            }
        }),
        _ => Err(LocusKitError::CorruptStoredValue {
            table: T_NODES.to_string(),
            column: column.to_string(),
            stored_text: format!("{:?}", v),
        }),
    }
}

/// Decode an optional UUID column.
fn opt_uuid_value_of(v: Option<&TypedValue>) -> Option<Uuid> {
    match v {
        Some(TypedValue::Uuid(u)) => Some(*u),
        Some(TypedValue::Text(s)) => Uuid::parse_str(s).ok(),
        _ => None,
    }
}

/// Decode a required HLC column. Handles .Hlc (direct) and .Int
/// (SQLite read-back of packed HLC).
fn hlc_value_of(column: &str, v: Option<&TypedValue>) -> Result<HLC, LocusKitError> {
    match v {
        Some(TypedValue::Hlc(h)) => Ok(*h),
        Some(TypedValue::Int(i)) => Ok(HLC::from_packed(*i as u64)),
        _ => Err(LocusKitError::CorruptStoredValue {
            table: T_NODES.to_string(),
            column: column.to_string(),
            stored_text: format!("{:?}", v),
        }),
    }
}

/// Decode an optional HLC column.
fn opt_hlc_value_of(v: Option<&TypedValue>) -> Option<HLC> {
    match v {
        Some(TypedValue::Hlc(h)) => Some(*h),
        Some(TypedValue::Int(i)) => Some(HLC::from_packed(*i as u64)),
        _ => None,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use persistence_kit::inmemory::InMemoryStorage;
    use crate::schema;

    fn make_store() -> NodeStore {
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        storage.open(&schema::schema()).unwrap();
        NodeStore::new(storage, None)
    }

    #[test]
    fn create_root_and_retrieve() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        assert_eq!(root.depth, 0);
        assert_eq!(root.display_name, "Estate");
        assert_eq!(root.lookup_name, "estate");
        assert!(root.is_active());
        assert!(root.parent_id.is_none());

        let fetched = store.root_node().unwrap().unwrap();
        assert_eq!(fetched.id, root.id);
    }

    #[test]
    fn create_root_idempotent() {
        let store = make_store();
        let first = store.create_root("Estate", 1000).unwrap();
        let second = store.create_root("Estate", 1001).unwrap();
        assert_eq!(first.id, second.id);
    }

    #[test]
    fn create_wing_and_room() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("My Wing", root.id, 1001).unwrap();
        assert_eq!(wing.depth, 1);
        assert_eq!(wing.display_name, "My Wing");
        assert_eq!(wing.lookup_name, "my wing");

        let room = store.create_node("Room A", wing.id, 1002).unwrap();
        assert_eq!(room.depth, 2);
        assert_eq!(room.display_name, "Room A");
        assert_eq!(room.lookup_name, "room a");
    }

    #[test]
    fn create_on_demand_resolution_returns_existing() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let w1 = store.create_node("Wing", root.id, 1001).unwrap();
        let w2 = store.create_node("  WING  ", root.id, 1002).unwrap();
        // Same lookup_name after normalization — returns existing.
        assert_eq!(w1.id, w2.id);
        // First-writer casing preserved.
        assert_eq!(w2.display_name, "Wing");
    }

    #[test]
    fn depth_exceeds_maximum() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("Wing", root.id, 1001).unwrap();
        let room = store.create_node("Room", wing.id, 1002).unwrap();
        // Attempt depth 3 — should fail.
        let err = store.create_node("Sub", room.id, 1003).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(msg.contains("I-NT-2"), "expected I-NT-2: {}", msg);
            }
            _ => panic!("expected InvalidContent, got {:?}", err),
        }
    }

    #[test]
    fn parent_must_exist() {
        let store = make_store();
        let fake_parent = Uuid::new_v4();
        let err = store.create_node("Wing", fake_parent, 1000).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => {
                assert!(msg.contains("I-NT-5"), "expected I-NT-5: {}", msg);
            }
            _ => panic!("expected InvalidContent, got {:?}", err),
        }
    }

    #[test]
    fn child_nodes_returns_active_only() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let w1 = store.create_node("Alpha", root.id, 1001).unwrap();
        let w2 = store.create_node("Beta", root.id, 1002).unwrap();
        store.tombstone_node(w1.id, 1003).unwrap();

        let children = store.child_nodes(root.id).unwrap();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].id, w2.id);
    }

    #[test]
    fn tombstone_node_sets_lifecycle() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("Wing", root.id, 1001).unwrap();
        assert!(wing.is_active());

        let tombstoned = store.tombstone_node(wing.id, 1002).unwrap().unwrap();
        assert!(tombstoned.is_tombstoned());
        assert!(tombstoned.tombstoned_hlc.is_some());
        assert!(tombstoned.tombstoned_at.is_some());
    }

    #[test]
    fn tombstone_idempotent() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("Wing", root.id, 1001).unwrap();
        let t1 = store.tombstone_node(wing.id, 1002).unwrap().unwrap();
        let t2 = store.tombstone_node(wing.id, 1003).unwrap().unwrap();
        // Same tombstoned_hlc — idempotent.
        assert_eq!(
            t1.tombstoned_hlc.unwrap().packed(),
            t2.tombstoned_hlc.unwrap().packed()
        );
    }

    #[test]
    fn tombstone_nonexistent_returns_none() {
        let store = make_store();
        let result = store.tombstone_node(Uuid::new_v4(), 1000).unwrap();
        assert!(result.is_none());
    }

    /// Shared test-skeleton helper: root + wing + room.
    pub(crate) struct NodeSkeleton {
        pub store: NodeStore,
        pub root: Node,
        pub wing: Node,
        pub room: Node,
    }

    /// Stand up a fresh InMemory-backed NodeStore with root, one wing,
    /// one room. Available to all in-crate tests.
    pub(crate) fn make_skeleton() -> NodeSkeleton {
        make_skeleton_with_names("Default Wing", "Default Room")
    }

    pub(crate) fn make_skeleton_with_names(
        wing_name: &str,
        room_name: &str,
    ) -> NodeSkeleton {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node(wing_name, root.id, 1001).unwrap();
        let room = store.create_node(room_name, wing.id, 1002).unwrap();
        NodeSkeleton { store, root, wing, room }
    }

    #[test]
    fn skeleton_produces_valid_tree() {
        let skel = make_skeleton();
        assert_eq!(skel.root.depth, 0);
        assert!(skel.root.parent_id.is_none());
        assert!(skel.root.is_active());

        assert_eq!(skel.wing.depth, 1);
        assert_eq!(skel.wing.parent_id, Some(skel.root.id));
        assert_eq!(skel.wing.lookup_name, "default wing");

        assert_eq!(skel.room.depth, 2);
        assert_eq!(skel.room.parent_id, Some(skel.wing.id));
        assert_eq!(skel.room.lookup_name, "default room");
    }

    #[test]
    fn skeleton_custom_names() {
        let skel = make_skeleton_with_names("Science", "Lab A");
        assert_eq!(skel.wing.display_name, "Science");
        assert_eq!(skel.room.display_name, "Lab A");
    }

    #[test]
    fn skeleton_child_nodes_correct() {
        let skel = make_skeleton();
        let wings = skel.store.child_nodes(skel.root.id).unwrap();
        assert_eq!(wings.len(), 1);
        assert_eq!(wings[0].id, skel.wing.id);

        let rooms = skel.store.child_nodes(skel.wing.id).unwrap();
        assert_eq!(rooms.len(), 1);
        assert_eq!(rooms[0].id, skel.room.id);
    }

    #[test]
    fn get_node_by_id() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let fetched = store.get_node(root.id).unwrap().unwrap();
        assert_eq!(fetched.id, root.id);

        let missing = store.get_node(Uuid::new_v4()).unwrap();
        assert!(missing.is_none());
    }

    // -----------------------------------------------------------------
    // No-resurrection guard (ADR-017 §5)
    // -----------------------------------------------------------------

    #[test]
    fn tombstoned_invisible_to_resolution() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("Wing", root.id, 1001).unwrap();
        store.tombstone_node(wing.id, 1002).unwrap();

        let fresh = store.create_node("Wing", root.id, 1003).unwrap();
        assert_ne!(fresh.id, wing.id);
        assert!(fresh.is_active());
        assert_eq!(fresh.lookup_name, "wing");
    }

    #[test]
    fn fresh_allowed_with_same_lookup_as_tombstoned() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let original = store.create_node("My Wing", root.id, 1001).unwrap();
        store.tombstone_node(original.id, 1002).unwrap();

        let fresh = store.create_node("my wing", root.id, 1003).unwrap();
        assert_ne!(fresh.id, original.id);
        assert!(fresh.is_active());

        let tombstoned = store.get_node(original.id).unwrap().unwrap();
        assert!(tombstoned.is_tombstoned());
    }

    #[test]
    fn resolution_never_flips_tombstoned_to_active() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let wing = store.create_node("Wing", root.id, 1001).unwrap();
        store.tombstone_node(wing.id, 1002).unwrap();

        store.create_node("Wing", root.id, 1003).unwrap();
        store.create_node("wing", root.id, 1004).unwrap();

        let original = store.get_node(wing.id).unwrap().unwrap();
        assert!(original.is_tombstoned());
        assert_eq!(original.lifecycle, 1);
    }

    #[test]
    fn active_and_tombstoned_coexist() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();

        let first = store.create_node("Wing", root.id, 1001).unwrap();
        store.tombstone_node(first.id, 1002).unwrap();

        let second = store.create_node("Wing", root.id, 1003).unwrap();
        store.tombstone_node(second.id, 1004).unwrap();

        let third = store.create_node("Wing", root.id, 1005).unwrap();

        assert_ne!(first.id, second.id);
        assert_ne!(second.id, third.id);

        let f = store.get_node(first.id).unwrap().unwrap();
        let s = store.get_node(second.id).unwrap().unwrap();
        let t = store.get_node(third.id).unwrap().unwrap();
        assert!(f.is_tombstoned());
        assert!(s.is_tombstoned());
        assert!(t.is_active());
    }

    #[test]
    fn child_nodes_excludes_tombstoned() {
        let store = make_store();
        let root = store.create_root("Estate", 1000).unwrap();
        let w1 = store.create_node("Alpha", root.id, 1001).unwrap();
        store.create_node("Beta", root.id, 1002).unwrap();
        store.tombstone_node(w1.id, 1003).unwrap();

        let children = store.child_nodes(root.id).unwrap();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].lookup_name, "beta");
    }
}
