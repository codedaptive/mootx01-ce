//! Merkle content-integrity rollup: room → wing → estate (NT-L3).
//!
//! After a drawer write, the rollup recomputes the affected subtree:
//!   1. Room root: MerkleHash.interior over the room's active drawers.
//!   2. Wing root: MerkleHash.interior over the wing's room roots.
//!   3. Estate root: MerkleHash.interior over the wing roots.
//!
//! Content hashes are read from the `content_hash` column when stored
//! (by the hash-on-write hook). For rows without a stored hash (NULL),
//! a leaf hash is computed on-demand from the drawer's content.
//!
//! Mirror: LocusKit/Sources/LocusKit/MerkleRollup.swift

use crate::error::LocusKitError;
use crate::estate::Estate;
use crate::node_store::NodeStore;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::snapshot_registry;
use persistence_kit::types::{Column, TypedValue};
use std::sync::Arc;
use substrate_lib::merkle_hash;
use substrate_types::content_hash::ContentHash;
use substrate_types::merkle_root::MerkleRoot;
use uuid::Uuid;

pub use persistence_kit::snapshot_registry::{SnapshotAttestation, SnapshotId, SnapshotRecord};

impl Estate {
    /// Roll up the Merkle roots of the rooms the given drawers live in — each
    /// room exactly ONCE (coalesced), using the room's drawers' latest
    /// `filed_at` as the deterministic `now`.
    ///
    /// This is the deferred, off-the-capture-path rollup. Capture no longer
    /// rolls up inline (that is O(room) per write → O(N²) for a bulk import and
    /// pegs the CPU); instead the rollup rides the estate's single QueueKit work
    /// queue — the encode drain worker hands this method the drawer ids it just
    /// drained, and the touched rooms roll up here, off the write path and
    /// coalesced. Ids that don't resolve to a live drawer are skipped (e.g. the
    /// queue's wake marker). Deterministic: the `now` for each room is sourced
    /// from its own drawers' `filed_at`, never a wall clock.
    pub fn rollup_rooms_for_drawers(&self, drawer_ids: &[String]) -> Result<(), LocusKitError> {
        use std::collections::HashMap;
        // room node id → latest filed_at among this batch's drawers in that room.
        let mut rooms: HashMap<Uuid, i64> = HashMap::new();
        for id in drawer_ids {
            if let Some(drawer) = self.store.get_drawer(id)? {
                if let Ok(room) = Uuid::parse_str(&drawer.parent_node_id) {
                    let entry = rooms.entry(room).or_insert(drawer.filed_at);
                    if drawer.filed_at > *entry {
                        *entry = drawer.filed_at;
                    }
                }
            }
        }
        for (room, now) in rooms {
            self.rollup_merkle_roots(room, now)?;
        }
        Ok(())
    }

    /// Recompute Merkle roots up the containment tree from a room to
    /// the estate root. Called after a drawer write to incrementally
    /// update the affected subtree.
    pub fn rollup_merkle_roots(
        &self,
        room_node_id: Uuid,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let node_store = self.node_store_ref()?;

        // Step 1: Room root — hash over active drawers in this room.
        let room_root = self.compute_room_merkle_root(room_node_id)?;
        node_store.update_merkle_root(room_node_id, &room_root, now)?;

        // Resolve wing from room's parent chain.
        let room_node = match node_store.get_node(room_node_id)? {
            Some(n) => n,
            None => return Ok(()),
        };
        let wing_node_id = match room_node.parent_id {
            Some(id) => id,
            None => return Ok(()),
        };

        // Step 2: Wing root — hash over room roots in this wing.
        let wing_root = self.compute_estate_or_wing_merkle_root(node_store.clone(), wing_node_id)?;
        node_store.update_merkle_root(wing_node_id, &wing_root, now)?;

        // Step 3: Estate root — hash over wing roots.
        let root_node = match node_store.root_node()? {
            Some(n) => n,
            None => return Ok(()),
        };
        let estate_root = self.compute_estate_or_wing_merkle_root(node_store.clone(), root_node.id)?;
        node_store.update_merkle_root(root_node.id, &estate_root, now)?;

        Ok(())
    }

    /// Compute the Merkle root for a room by hashing its live drawers.
    ///
    /// Excludes both tombstoned and withdrawn drawers from the snapshot.
    /// Tombstoned drawers have tombstonedAt IS NOT NULL. Withdrawn drawers
    /// have tombstonedAt IS NULL but carry state raw value 18 in bits 0-5
    /// of adjectiveBitmap (mask 0x3F). Including withdrawn drawers in the
    /// snapshot would allow retrieval of content that the user retracted,
    /// violating snapshot completeness (WS2-F1, fixed 2026-06-28).
    fn compute_room_merkle_root(
        &self,
        room_node_id: Uuid,
    ) -> Result<MerkleRoot, LocusKitError> {
        let rows = self
            .store
            .storage().ok_or_else(|| LocusKitError::DatabaseUnavailable("no storage".to_string()))?
            .row_store()
            .query(
                "drawers",
                Some(&StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new("drawers", "parent_node_id"),
                        TypedValue::Text(room_node_id.to_string()),
                    ),
                    // Exclude tombstoned drawers (irreversible deletion).
                    StoragePredicate::IsNull(Column::new("drawers", "tombstonedAt")),
                    // Exclude withdrawn drawers (state 18, bits 0-5 of adjectiveBitmap).
                    // Withdrawn means the user retracted the drawer; it must not
                    // appear in the live snapshot that commits hash to.
                    StoragePredicate::Not(Box::new(StoragePredicate::BitwiseEq {
                        column: Column::new("drawers", "adjectiveBitmap"),
                        expected: 18,
                        mask: 0x3F,
                    })),
                ])),
                &[],
                None,
                None,
            )
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;

        let mut child_hashes: Vec<([u8; 16], ContentHash)> = Vec::new();

        for row in &rows {
            let drawer_id_str = match row.get("id") {
                Some(TypedValue::Text(s)) => s.clone(),
                Some(TypedValue::Uuid(u)) => u.to_string(),
                _ => continue,
            };
            let drawer_uuid = deterministic_uuid(&drawer_id_str);

            let content_hash = match row.get("content_hash") {
                Some(TypedValue::Blob(data)) if data.len() == 32 => {
                    let mut bytes = [0u8; 32];
                    bytes.copy_from_slice(data);
                    ContentHash::new(bytes)
                }
                _ => {
                    // No stored hash — compute on-demand from drawer content.
                    let content = match row.get("content") {
                        Some(TypedValue::Text(s)) => s.as_bytes().to_vec(),
                        _ => Vec::new(),
                    };
                    merkle_hash::leaf(&uuid_to_be_bytes(drawer_uuid), &content, &[])
                }
            };

            child_hashes.push((uuid_to_be_bytes(drawer_uuid), content_hash));
        }

        Ok(merkle_hash::interior(&child_hashes))
    }

    /// Compute the Merkle root for a wing or estate by hashing child
    /// nodes' merkle_roots.
    ///
    /// Uses the typed `interior_roots` overload (NT-Q1) so child
    /// MerkleRoots flow through without type punning.
    fn compute_estate_or_wing_merkle_root(
        &self,
        node_store: Arc<NodeStore>,
        parent_node_id: Uuid,
    ) -> Result<MerkleRoot, LocusKitError> {
        let children = node_store.child_nodes(parent_node_id)?;
        let mut child_roots: Vec<([u8; 16], MerkleRoot)> = Vec::new();

        for child in &children {
            let root = child.merkle_root.unwrap_or(MerkleRoot::EMPTY);
            child_roots.push((uuid_to_be_bytes(child.id), root));
        }

        Ok(merkle_hash::interior_roots(&child_roots))
    }

    /// Bottom-up recompute of every Merkle root in the estate.
    pub fn recompute_all_merkle_roots(&self, now: i64) -> Result<(), LocusKitError> {
        let node_store = self.node_store_ref()?;

        let root_node = match node_store.root_node()? {
            Some(n) => n,
            None => return Ok(()),
        };

        let wings = node_store.child_nodes(root_node.id)?;
        for wing in &wings {
            let rooms = node_store.child_nodes(wing.id)?;
            for room in &rooms {
                let room_root = self.compute_room_merkle_root(room.id)?;
                node_store.update_merkle_root(room.id, &room_root, now)?;
            }
            let wing_root = self.compute_estate_or_wing_merkle_root(node_store.clone(), wing.id)?;
            node_store.update_merkle_root(wing.id, &wing_root, now)?;
        }

        let estate_root = self.compute_estate_or_wing_merkle_root(node_store.clone(), root_node.id)?;
        node_store.update_merkle_root(root_node.id, &estate_root, now)?;

        Ok(())
    }

    /// Full-tree Merkle rollup for the batch-capture reindex pass (NT_R1).
    ///
    /// Thin alias over `recompute_all_merkle_roots`. Called after a
    /// `capture_batch` pass that deliberately deferred per-drawer rollup to
    /// avoid O(N²) recomputation during bulk import. Produces the same
    /// result as N incremental `rollup_merkle_roots` calls but in O(N).
    ///
    /// - `now`: epoch-seconds wall-clock for node `updated_at`.
    pub fn rollup_all_merkle_roots(&self, now: i64) -> Result<(), LocusKitError> {
        self.recompute_all_merkle_roots(now)
    }

    /// Create a snapshot with Merkle root attestations for every wing
    /// and the estate root, plus any additional attestations from the
    /// composition layer (e.g. CorpusKit roots via GeniusLocusKit).
    ///
    /// Delegates to PersistenceKit's `snapshot_registry::create_snapshot`
    /// for the actual row writes and SnapshotId minting. Mirrors Swift's
    /// `MerkleRollup.createSnapshot` which delegates to
    /// `SnapshotRegistryOps.createSnapshot`.
    pub fn create_snapshot(
        &self,
        label: Option<&str>,
        now: i64,
        additional_attestations: &[SnapshotAttestation],
    ) -> Result<SnapshotRecord, LocusKitError> {
        // Barrier: capture defers Merkle rollups off the write path, so node
        // roots may be stale here. Recompute the full tree before attesting so a
        // snapshot always commits the current roots. O(N) but snapshots are rare.
        self.recompute_all_merkle_roots(now)?;
        let node_store = self.node_store_ref()?;
        // `now` is epoch seconds (Rust verb-layer convention); HLC expects ms.
        let now_ms = now * 1000;
        let hlc = node_store.generate_hlc(now_ms);

        // Dummy id — PK's create_snapshot mints the real one and stamps
        // each attestation with it before writing.
        let placeholder = SnapshotId::new("");

        let mut attestations: Vec<SnapshotAttestation> = Vec::new();

        if let Some(root_node) = node_store.root_node()? {
            let estate_hex = root_node.merkle_root.unwrap_or(MerkleRoot::EMPTY).hex_string();
            attestations.push(SnapshotAttestation {
                snapshot_id: placeholder.clone(),
                subject_kind: "estate".to_string(),
                subject_id: root_node.id.to_string(),
                merkle_root: estate_hex,
                key_version: None,
            });

            let wings = node_store.child_nodes(root_node.id)?;
            for wing in &wings {
                let wing_hex = wing.merkle_root.unwrap_or(MerkleRoot::EMPTY).hex_string();
                attestations.push(SnapshotAttestation {
                    snapshot_id: placeholder.clone(),
                    subject_kind: "wing".to_string(),
                    subject_id: wing.id.to_string(),
                    merkle_root: wing_hex,
                    key_version: None,
                });
            }
        }

        // Append composition-layer attestations (CorpusKit, etc.).
        attestations.extend_from_slice(additional_attestations);

        let row_store = self.store.storage()
            .ok_or_else(|| LocusKitError::DatabaseUnavailable("no storage".to_string()))?
            .row_store();

        snapshot_registry::create_snapshot(row_store.as_ref(), hlc, label, now, &attestations)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))
    }

    /// Get a reference to the node store, returning an error if not set.
    fn node_store_ref(&self) -> Result<Arc<NodeStore>, LocusKitError> {
        self.node_store
            .clone()
            .ok_or_else(|| LocusKitError::DatabaseUnavailable(
                "MerkleRollup: node store not available".to_string(),
            ))
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a drawer string ID to a deterministic UUID.
/// Parses as UUID when possible; otherwise derives a stable UUID from
/// SHA-256 of the string (first 16 bytes with UUID v5 version and
/// variant bits set). Mirrors Swift `Estate.deterministicUUID(from:)`.
fn deterministic_uuid(string_id: &str) -> Uuid {
    if let Ok(uuid) = Uuid::parse_str(string_id) {
        return uuid;
    }
    let hash = substrate_kernel::sha256::hash(string_id.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    // Set version nibble (byte 6 high nibble) to 5.
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    // Set variant bits (byte 8 high 2 bits) to 10.
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

/// Convert a UUID to 16-byte big-endian representation.
fn uuid_to_be_bytes(uuid: Uuid) -> [u8; 16] {
    *uuid.as_bytes()
}

