//! HashingRowStore: decorator that intercepts RowStore writes (insert,
//! update, upsert) and computes a ContentHash for rows in hashable tables.
//!
//! Emits a `DirtyChainEvent` carrying the three-identifier Merkle
//! containment chain so downstream consumers (Merkle rollup, cache
//! invalidation) can incrementally re-root without a full-tree scan.
//!
//! PersistenceKit does not depend on substrate-lib or substrate-kernel.
//! The hash function is a callback (`ContentHashProvider`) injected at
//! construction time — the consuming kit (e.g. LocusKit) imports
//! substrate-lib and supplies `MerkleHash::leaf` or an accelerated kernel
//! dispatch. This keeps PersistenceKit kernel-agnostic: the accelerated
//! SHA-256 path (sha2 crate on Rust, CryptoKit on Apple) lives in the
//! callback supplier, not here (node-tree integrity / NT-P2 Part 3).
//!
//! Decorator chain: caller → HashingRowStore → CachingRowStore → backend.

use crate::error::StorageResult;
use crate::observer::{DirtyChainEvent, DirtyChainHub};
use crate::predicate::{OrderClause, StoragePredicate};
use crate::row_store::RowStore;
use crate::types::{RowHandle, RowKey, StorageRow, TypedValue};
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use substrate_types::content_hash::ContentHash;

/// Callback that computes a ContentHash for a row's values.
///
/// The supplier (typically LocusKit) imports substrate-lib and calls
/// `MerkleHash::leaf` or an accelerated kernel variant. PersistenceKit
/// stores the result and emits a `DirtyChainEvent` — it never imports
/// a hash implementation directly.
pub type ContentHashProvider =
    Box<dyn Fn(&str, RowKey, &BTreeMap<String, TypedValue>) -> ContentHash + Send + Sync>;

/// Callback that returns the Merkle containment parent chain for a row.
///
/// Returns `(parent_node_id, grandparent_node_id)` — the two ancestor IDs
/// needed for dirty-chain propagation. Returns `None` when the row has no
/// parent chain (e.g. a root node or a table without Merkle rollup).
pub type HashParentChainProvider =
    Box<dyn Fn(&str, RowKey) -> Option<(uuid::Uuid, uuid::Uuid)> + Send + Sync>;

/// Configuration for the hash-on-write hook.
pub struct HashOnWriteConfig {
    /// The set of table names marked hashable in the schema.
    pub hashable_tables: HashSet<String>,
    /// Computes a ContentHash for a row's values.
    pub hash_provider: ContentHashProvider,
    /// Returns the Merkle containment parent chain for a row.
    pub parent_chain_provider: HashParentChainProvider,
}

/// A `RowStore` decorator that intercepts writes to hashable tables,
/// computes a ContentHash via a caller-supplied callback, and emits
/// `DirtyChainEvent` notifications to registered observers.
///
/// Writes to non-hashable tables pass through unmodified.
/// Read operations (query, count) delegate directly to the backing store.
pub struct HashingRowStore {
    backing: Arc<dyn RowStore>,
    config: HashOnWriteConfig,
    dirty_chain_hub: Option<Arc<DirtyChainHub>>,
}

impl HashingRowStore {
    /// Constructs a new `HashingRowStore`.
    ///
    /// - `backing`: The RowStore to wrap (typically a CachingRowStore
    ///   or a raw backend).
    /// - `config`: Hash-on-write configuration with hashable table set,
    ///   hash provider callback, and parent chain provider callback.
    /// - `dirty_chain_hub`: Optional hub for fan-out of dirty-chain events.
    ///   Pass `None` for backends that don't support observation.
    pub fn new(
        backing: Arc<dyn RowStore>,
        config: HashOnWriteConfig,
        dirty_chain_hub: Option<Arc<DirtyChainHub>>,
    ) -> Self {
        HashingRowStore {
            backing,
            config,
            dirty_chain_hub,
        }
    }

    /// Computes a content hash for a hashable row where the row key is already
    /// known (from a predicate or conflict-column lookup) and `merged_values`
    /// is the full committed row state after applying SET / incoming values.
    ///
    /// Used by `update` and `upsert` on the update path. Unlike
    /// `augment_with_hash`, this variant does not extract the row key from the
    /// values map — the caller supplies it directly, allowing correct hash
    /// computation even when the incoming values map omits the "id" column
    /// (e.g. a partial SET dict in an UPDATE statement). (SECFIX-WS2-PK F6)
    fn augment_with_hash_for_known_key(
        &self,
        table: &str,
        row_key: RowKey,
        merged_values: BTreeMap<String, TypedValue>,
    ) -> (BTreeMap<String, TypedValue>, Option<AugmentResult>) {
        if !self.config.hashable_tables.contains(table) {
            return (merged_values, None);
        }
        // Strip the existing `content_hash` from the input before computing the
        // new hash. The INSERT path (`augment_with_hash`) calls hash_provider with
        // values that do NOT yet include `content_hash` (it is added afterwards).
        // Stripping here ensures the hash function always receives the same column
        // set — the row's data columns — regardless of whether this is an insert
        // or an update/upsert. Without this strip, the UPDATE path would hash the
        // old `content_hash` column value along with the data columns, producing a
        // result that diverges from what the INSERT path would compute for identical
        // data (SECFIX-WS2-PK F6 consistency).
        let mut hash_input = merged_values.clone();
        hash_input.remove("content_hash");
        let content_hash = (self.config.hash_provider)(table, row_key, &hash_input);
        let mut augmented = merged_values;
        augmented.insert("content_hash".to_string(), TypedValue::Blob(content_hash.bytes().to_vec()));
        let chain = match (self.config.parent_chain_provider)(table, row_key) {
            Some(c) => c,
            None => return (augmented, None),
        };
        (augmented, Some(AugmentResult {
            row_key,
            content_hash,
            parent_node_id: chain.0,
            grandparent_node_id: chain.1,
        }))
    }

    /// Computes the content hash for hashable tables and merges the
    /// `content_hash` column into the values map. Non-hashable tables
    /// return the original values unchanged. Hash is computed BEFORE
    /// the backing write so the column is stored atomically with the
    /// row (node-tree integrity — synchronous with the write).
    fn augment_with_hash(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> (BTreeMap<String, TypedValue>, Option<AugmentResult>) {
        if !self.config.hashable_tables.contains(table) {
            return (values, None);
        }

        // Extract row key from the "id" column (UUID primary key by convention).
        let row_key = match values.get("id") {
            Some(TypedValue::Uuid(uuid)) => *uuid,
            _ => return (values, None),
        };

        let content_hash = (self.config.hash_provider)(table, row_key, &values);

        // Merge content_hash column into the row values.
        let mut augmented = values;
        augmented.insert("content_hash".to_string(), TypedValue::Blob(content_hash.bytes().to_vec()));

        let chain = match (self.config.parent_chain_provider)(table, row_key) {
            Some(c) => c,
            None => return (augmented, None),
        };

        (augmented, Some(AugmentResult {
            row_key,
            content_hash,
            parent_node_id: chain.0,
            grandparent_node_id: chain.1,
        }))
    }

    /// Emits a dirty-chain event to the hub.
    fn emit_dirty_chain(&self, table: &str, result: &AugmentResult) {
        let event = DirtyChainEvent {
            changed_row_id: result.row_key,
            parent_node_id: result.parent_node_id,
            grandparent_node_id: result.grandparent_node_id,
            content_hash: result.content_hash.clone(),
            table: table.to_string(),
        };
        if let Some(hub) = &self.dirty_chain_hub {
            hub.emit(event);
        }
    }

    /// Extracts a single UUID row key from an equality predicate.
    /// Returns `None` for compound/range predicates (batch updates
    /// skip the hash-on-write hook).
    fn extract_single_row_key(predicate: &StoragePredicate) -> Option<RowKey> {
        if let StoragePredicate::Eq(_, TypedValue::Uuid(uuid)) = predicate {
            Some(*uuid)
        } else {
            None
        }
    }
}

struct AugmentResult {
    row_key: RowKey,
    content_hash: ContentHash,
    parent_node_id: uuid::Uuid,
    grandparent_node_id: uuid::Uuid,
}

// Hash computation is synchronous with the write: the hash is computed
// BEFORE the row is committed, then merged into the values map as a
// `content_hash` column. The backing store receives the augmented values
// in a single write — no window between row commit and hash storage.
impl RowStore for HashingRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let (augmented, hash_result) = self.augment_with_hash(table, values);
        let handle = self.backing.insert(table, augmented)?;
        if let Some(result) = &hash_result {
            self.emit_dirty_chain(table, result);
        }
        Ok(handle)
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        // For hashable tables, detect whether this upsert will hit an existing
        // row (update path) or insert a new row. If it's an update, hash the
        // full committed row (current columns merged with incoming values) rather
        // than just the incoming values map, which omits unchanged columns
        // (SECFIX-WS2-PK F6).
        if self.config.hashable_tables.contains(table) {
            if let Some(first_col) = conflict_columns.first() {
                if let Some(TypedValue::Uuid(row_key)) = values.get(first_col) {
                    let row_key = *row_key;
                    // Point-lookup for existing row.
                    let existing = self.backing.query(
                        table,
                        Some(&StoragePredicate::Eq(
                            crate::Column { table: table.to_string(), name: first_col.clone() },
                            TypedValue::Uuid(row_key),
                        )),
                        &[],
                        None,
                        None,
                    )?;
                    if let Some(current_row) = existing.into_iter().next() {
                        // Upsert resolves to an update: merge incoming values over current.
                        let mut merged = current_row.values;
                        for (col, v) in values.iter() {
                            merged.insert(col.clone(), v.clone());
                        }
                        let (augmented, hash_result) =
                            self.augment_with_hash_for_known_key(table, row_key, merged);
                        let handle = self.backing.upsert(table, augmented, conflict_columns)?;
                        if let Some(result) = &hash_result {
                            self.emit_dirty_chain(table, result);
                        }
                        return Ok(handle);
                    }
                }
            }
        }
        // Insert path (no existing row) or non-hashable table: incoming values
        // IS the full row, so the existing augment logic is correct.
        let (augmented, hash_result) = self.augment_with_hash(table, values);
        let handle = self.backing.upsert(table, augmented, conflict_columns)?;
        if let Some(result) = &hash_result {
            self.emit_dirty_chain(table, result);
        }
        Ok(handle)
    }

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize> {
        // For hashable tables with a single-row UUID predicate, hash the full
        // committed row (current columns merged with the SET values) rather than
        // just the partial SET-column map (SECFIX-WS2-PK F6). Without pre-reading,
        // the hash omits all unchanged columns, producing a hash for a partial
        // row that diverges from the actual committed row state.
        if self.config.hashable_tables.contains(table) {
            if let Some(row_key) = Self::extract_single_row_key(predicate) {
                let existing = self.backing.query(table, Some(predicate), &[], None, None)?;
                if let Some(current_row) = existing.into_iter().next() {
                    let mut merged = current_row.values;
                    for (col, v) in values.iter() {
                        merged.insert(col.clone(), v.clone());
                    }
                    let (augmented, hash_result) =
                        self.augment_with_hash_for_known_key(table, row_key, merged);
                    let count = self.backing.update(table, augmented, predicate)?;
                    if count > 0 {
                        if let Some(result) = &hash_result {
                            self.emit_dirty_chain(table, result);
                        }
                    }
                    return Ok(count);
                }
            }
        }
        // Non-hashable table or batch update (no single UUID key).
        let (augmented, hash_result) = self.augment_with_hash(table, values);
        let count = self.backing.update(table, augmented, predicate)?;
        // For single-row updates via UUID predicate, emit dirty-chain.
        // Batch updates skip the event — the consuming kit re-hashes.
        if count > 0 {
            if let Some(result) = &hash_result {
                if Self::extract_single_row_key(predicate).is_some() {
                    self.emit_dirty_chain(table, result);
                }
            }
        }
        Ok(count)
    }

    // Read operations delegate directly to backing store.

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        self.backing.delete(table, predicate)
    }

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        self.backing.query(table, predicate, order_by, limit, offset)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        self.backing.count(table, predicate)
    }
}
