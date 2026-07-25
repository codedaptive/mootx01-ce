//! CachingRowStore: in-memory LRU hot tier wrapping any RowStore.
//!
//! Mirrors Swift's `CachingRowStore`. Synchronous throughout (the Rust
//! `RowStore` trait is synchronous; Swift is async because actors require
//! it, not because of real I/O). Thread-safety is achieved via
//! `Arc<CachingRowStore>` with `Mutex<CacheState>` for mutable hot-tier
//! state — equivalent to Swift's actor isolation of `CacheActor`.
//!
//! Cache key: (table, UUID key, AsOfCoordinate). A present read and an
//! as-of snapshot read of the same row are distinct cache entries per
//! node-tree integrity. Snapshot reads (AsOf(hlc)) against pinned immutable
//! views are safely cacheable because the GC pin (NT-P3) prevents
//! vacuum of pinned rows. Present reads remain invalidation-driven.
//!
//! Parent-chain callback: when a write mutates a hashable row, the
//! optional parent_chain_provider returns the Merkle-aggregate parent
//! chain (e.g. drawer→room→wing). CachingRowStore evicts cached
//! aggregates for every node in the chain.
//!
//! Sensitivity gate: rows whose `provenance` column encodes a sensitivity
//! level above the configured threshold — or equal to Secret (ordinal 3) —
//! are never admitted. Absent column → admit; unparseable value or
//! unrecognised bit pattern → reject (fail closed).
//! Encoding per provenance bitmap spec (cookbook §2.5 v0.6):
//!   field = (raw_i64 >> 30) & 0x3F   (bits [35:30])
//!   raw 0 = Normal, 16 = Elevated, 32 = Restricted, 48 = Secret (scale-gapped)
//! EstateCacheConfig.sensitivity_threshold is an ordinal (0–2); the gate maps
//! scale-gapped raw values to ordinals before comparing.
//!
//! LRU eviction fires when estimated hot-tier bytes exceed `ceiling_bytes`.
//! `ceiling_bytes == 0` means no limit.

use crate::cache_config::EstateCacheConfig;
use crate::error::StorageResult;
use crate::predicate::{OrderClause, StoragePredicate};
use crate::row_store::RowStore;
use crate::types::{RowHandle, RowKey, StorageRow, TypedValue};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use substrate_types::AsOfCoordinate;

/// Callback that maps a changed row to its Merkle-aggregate parent chain.
/// Returns RowHandles for each ancestor whose cached aggregate must be
/// invalidated (e.g. [room, wing, estate]). Returns empty when no chain
/// invalidation is needed.
pub type ParentChainProvider = Box<dyn Fn(&str, RowKey) -> Vec<RowHandle> + Send + Sync>;

// ─────────────────────────────────────────────────────────────────
// Temporal cache key
// ─────────────────────────────────────────────────────────────────

/// Internal key type that adds the temporal coordinate to a RowHandle.
/// A present read and an as-of snapshot read of the same row produce
/// distinct keys, so they occupy separate cache entries.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct TemporalCacheKey {
    handle: RowHandle,
    as_of: AsOfCoordinate,
}

impl TemporalCacheKey {
    fn new(handle: RowHandle, as_of: AsOfCoordinate) -> Self {
        TemporalCacheKey { handle, as_of }
    }
}

// ─────────────────────────────────────────────────────────────────
// Internal cache state
// ─────────────────────────────────────────────────────────────────

struct CacheEntry {
    row: StorageRow,
    access_order: u64, // higher = more recently used
    byte_size: usize,
}

struct CacheState {
    entries: HashMap<TemporalCacheKey, CacheEntry>,
    access_counter: u64,
    total_bytes: usize,
}

impl CacheState {
    fn new() -> Self {
        CacheState {
            entries: HashMap::new(),
            access_counter: 0,
            total_bytes: 0,
        }
    }

    /// Return the cached row for `key`, updating its LRU position.
    fn get(&mut self, key: &TemporalCacheKey) -> Option<StorageRow> {
        let entry = self.entries.get_mut(key)?;
        self.access_counter += 1;
        entry.access_order = self.access_counter;
        Some(entry.row.clone())
    }

    /// Admit `row` under `key` subject to the sensitivity gate and byte
    /// budget. Evicts LRU entries as needed.
    fn admit(&mut self, key: TemporalCacheKey, row: StorageRow, config: &EstateCacheConfig) {
        if !config.enabled {
            return;
        }
        if !is_admissible(&row, config) {
            return;
        }
        let size = estimated_bytes(&row);
        if let Some(existing) = self.entries.remove(&key) {
            self.total_bytes -= existing.byte_size;
        }
        if config.ceiling_bytes > 0 {
            let ceiling = config.ceiling_bytes as usize;
            while !self.entries.is_empty() && self.total_bytes + size > ceiling {
                self.evict_lru();
            }
            if self.total_bytes + size > ceiling {
                return;
            }
        }
        self.access_counter += 1;
        self.total_bytes += size;
        self.entries.insert(
            key,
            CacheEntry {
                row,
                access_order: self.access_counter,
                byte_size: size,
            },
        );
    }

    /// Remove the present-read entry for `handle`. Snapshot entries
    /// (AsOf(hlc)) are left intact because pinned snapshot data is
    /// immutable — writes cannot invalidate them.
    fn evict_present(&mut self, handle: &RowHandle) {
        let key = TemporalCacheKey::new(handle.clone(), AsOfCoordinate::Present);
        if let Some(entry) = self.entries.remove(&key) {
            self.total_bytes -= entry.byte_size;
        }
    }

    /// Remove all present-read entries whose table matches. Snapshot
    /// entries are left intact.
    fn evict_all_present_for_table(&mut self, table: &str) {
        let to_remove: Vec<TemporalCacheKey> = self
            .entries
            .keys()
            .filter(|k| k.handle.table == table && k.as_of == AsOfCoordinate::Present)
            .cloned()
            .collect();
        for key in to_remove {
            if let Some(entry) = self.entries.remove(&key) {
                self.total_bytes -= entry.byte_size;
            }
        }
    }

    /// Evict the least-recently-used entry (smallest `access_order`). O(n)
    /// over entry count; acceptable for caches bounded by `ceiling_bytes`.
    fn evict_lru(&mut self) {
        let lru = self
            .entries
            .iter()
            .min_by_key(|(_, e)| e.access_order)
            .map(|(k, _)| k.clone());
        if let Some(key) = lru {
            if let Some(entry) = self.entries.remove(&key) {
                self.total_bytes -= entry.byte_size;
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

/// Extract a `RowKey` UUID from `Eq(_, Uuid(key))` predicates.
/// Returns `None` for any other predicate shape.
fn extract_key(predicate: Option<&StoragePredicate>) -> Option<RowKey> {
    match predicate {
        Some(StoragePredicate::Eq(_, TypedValue::Uuid(uuid))) => Some(*uuid),
        _ => None,
    }
}

/// Returns `true` when `row` is eligible for the hot tier.
///
/// Sensitivity is encoded in the `provenance` bitmap at bits 30–35 (6-bit
/// field, scale-gapped per cookbook §2.5 v0.6). The gate converts the raw
/// field value to an ordinal (0–3) and compares it against the config
/// threshold, which is also expressed as an ordinal.
///
///   - Column absent              → admit
///   - ordinal > threshold        → reject
///   - ordinal == 3 (Secret)      → reject always regardless of threshold
///   - Unrecognised bit pattern   → reject (fail closed)
///   - Unparseable value          → reject (fail closed)
fn is_admissible(row: &StorageRow, config: &EstateCacheConfig) -> bool {
    match row.get("provenance") {
        None => true,
        Some(TypedValue::Int(raw)) | Some(TypedValue::Bitmap(raw)) => {
            // Sensitivity at capture lives in bits 30–35 of the provenance bitmap
            // (6-bit field, scale-gapped: 0/16/32/48 per cookbook §2.5 v0.6).
            let raw_field = ((raw >> 30) & 0x3F) as i32;
            let ordinal = match raw_field {
                0  => 0,  // Normal
                16 => 1,  // Elevated
                32 => 2,  // Restricted
                48 => 3,  // Secret
                _  => return false, // Unrecognised bit pattern → fail closed
            };
            // Hard Secret exclusion is defence-in-depth: threshold is already
            // clamped to ≤2 by EstateCacheConfig, but the guard is correct
            // even if that clamp were bypassed.
            if ordinal == 3 {
                return false;
            }
            ordinal <= config.sensitivity_threshold
        }
        Some(_) => false, // unparseable → fail closed
    }
}

/// Conservative byte estimate for one `StorageRow`. Used for eviction
/// decisions only; intentional over-estimation is safe.
fn estimated_bytes(row: &StorageRow) -> usize {
    let mut size: usize = 64; // per-entry overhead
    for (key, value) in &row.values {
        size += key.len() + 8;
        size += estimated_value_bytes(value);
    }
    size
}

fn estimated_value_bytes(value: &TypedValue) -> usize {
    match value {
        TypedValue::Null => 8,
        TypedValue::Bool(_) => 8,
        TypedValue::Int(_) | TypedValue::Bitmap(_) | TypedValue::Float(_) => 16,
        TypedValue::Text(s) => s.len() + 16,
        TypedValue::Blob(b) => b.len() + 16,
        TypedValue::Uuid(_) => 24,
        TypedValue::Timestamp(_) => 24,
        TypedValue::Json(b) => b.len() + 16,
        TypedValue::Hlc(_) => 24,
        TypedValue::Fingerprint(_) => 40,
        TypedValue::Array(arr) => arr
            .iter()
            .fold(16, |acc, v| acc + estimated_value_bytes(v)),
    }
}

// ─────────────────────────────────────────────────────────────────
// CachingRowStore
// ─────────────────────────────────────────────────────────────────

/// In-memory LRU hot tier wrapping any `RowStore`. Mirrors Swift's
/// `CachingRowStore`. Thread-safe via `Mutex<CacheState>`.
///
/// Pass `EstateCacheConfig::disabled()` for a zero-overhead passthrough.
pub struct CachingRowStore {
    backing: Arc<dyn RowStore>,
    config: EstateCacheConfig,
    parent_chain_provider: Option<ParentChainProvider>,
    state: Mutex<CacheState>,
}

impl CachingRowStore {
    /// Wrap `backing` with an in-memory LRU hot tier governed by `config`.
    ///
    /// `parent_chain_provider`: optional callback that returns the
    /// Merkle-aggregate parent chain for a changed row. When set,
    /// writes evict cached aggregates for every node in the chain.
    pub fn new(
        backing: Arc<dyn RowStore>,
        config: EstateCacheConfig,
    ) -> Self {
        CachingRowStore {
            backing,
            config,
            parent_chain_provider: None,
            state: Mutex::new(CacheState::new()),
        }
    }

    /// Wrap `backing` with an in-memory LRU hot tier and a parent-chain
    /// callback for Merkle-aggregate invalidation.
    pub fn with_parent_chain(
        backing: Arc<dyn RowStore>,
        config: EstateCacheConfig,
        provider: ParentChainProvider,
    ) -> Self {
        CachingRowStore {
            backing,
            config,
            parent_chain_provider: Some(provider),
            state: Mutex::new(CacheState::new()),
        }
    }

    /// Invalidate cached present-read entries. Called by `CacheInvalidator`
    /// when an external write arrives via `StorageObserver`. Pass `key: None`
    /// to evict all present entries for `table`.
    ///
    /// Snapshot-read entries (AsOf(hlc)) are never evicted because the
    /// pinned snapshot data is immutable.
    pub fn invalidate(&self, table: &str, key: Option<RowKey>) {
        if !self.config.enabled {
            return;
        }
        let mut state = self.state.lock().unwrap();
        match key {
            Some(k) => {
                state.evict_present(&RowHandle::new(table, k));
                drop(state);
                self.invalidate_parent_chain(table, k);
            }
            None => state.evict_all_present_for_table(table),
        }
    }

    /// Evict cached Merkle-aggregate entries for every node in the parent
    /// chain. No-op when no provider is registered.
    fn invalidate_parent_chain(&self, table: &str, key: RowKey) {
        if let Some(ref provider) = self.parent_chain_provider {
            let chain = provider(table, key);
            let mut state = self.state.lock().unwrap();
            for parent_handle in &chain {
                state.evict_present(parent_handle);
            }
        }
    }
}

impl RowStore for CachingRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let handle = self.backing.insert(table, values)?;
        if self.config.enabled {
            self.invalidate_parent_chain(table, handle.key);
        }
        Ok(handle)
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        let handle = self.backing.upsert(table, values, conflict_columns)?;
        if self.config.enabled {
            self.state.lock().unwrap().evict_present(&handle);
            self.invalidate_parent_chain(table, handle.key);
        }
        Ok(handle)
    }

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize> {
        let count = self.backing.update(table, values, predicate)?;
        if self.config.enabled && count > 0 {
            if let Some(key) = extract_key(Some(predicate)) {
                self.state.lock().unwrap().evict_present(&RowHandle::new(table, key));
                self.invalidate_parent_chain(table, key);
            } else {
                self.state.lock().unwrap().evict_all_present_for_table(table);
            }
        }
        Ok(count)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let count = self.backing.delete(table, predicate)?;
        if self.config.enabled && count > 0 {
            if let Some(key) = extract_key(Some(predicate)) {
                self.state.lock().unwrap().evict_present(&RowHandle::new(table, key));
                self.invalidate_parent_chain(table, key);
            } else {
                self.state.lock().unwrap().evict_all_present_for_table(table);
            }
        }
        Ok(count)
    }

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        self.temporal_query(table, predicate, order_by, limit, offset, AsOfCoordinate::Present)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        self.backing.count(table, predicate)
    }

    fn query_as_of(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
        as_of: Option<AsOfCoordinate>,
    ) -> StorageResult<Vec<StorageRow>> {
        let coordinate = as_of.unwrap_or(AsOfCoordinate::Present);
        self.temporal_query(table, predicate, order_by, limit, offset, coordinate)
    }

    // ----------------------------------------------------------------
    // Explicit transaction boundary (GLK_BATCH1)
    // ----------------------------------------------------------------

    /// Open a write transaction on the backing store.
    ///
    /// Explicitly delegates to `backing.begin_transaction()` rather than
    /// relying on the `RowStore` trait's no-op default. Live GLK estates wrap
    /// `SqliteRowStore` in a `CachingRowStore`; the no-op default would
    /// silently swallow the transaction boundary, defeating the batch API.
    fn begin_transaction(&self) -> StorageResult<()> {
        self.backing.begin_transaction()
    }

    /// Commit the current transaction on the backing store.
    fn commit_transaction(&self) -> StorageResult<()> {
        self.backing.commit_transaction()
    }

    /// Roll back the current transaction on the backing store.
    fn rollback_transaction(&self) -> StorageResult<()> {
        self.backing.rollback_transaction()
    }
}

impl CachingRowStore {
    /// Shared implementation for both present and as-of queries with
    /// temporal cache key isolation.
    fn temporal_query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
        as_of: AsOfCoordinate,
    ) -> StorageResult<Vec<StorageRow>> {
        if self.config.enabled {
            if let Some(key) = extract_key(predicate) {
                let handle = RowHandle::new(table, key);
                let cache_key = TemporalCacheKey::new(handle, as_of);
                let cached = self.state.lock().unwrap().get(&cache_key);
                if let Some(row) = cached {
                    return Ok(vec![row]);
                }
                // Cache miss: query backing store with temporal coordinate.
                let rows = match as_of {
                    AsOfCoordinate::Present => {
                        self.backing.query(table, predicate, order_by, limit, offset)?
                    }
                    AsOfCoordinate::AsOf(_) => {
                        self.backing.query_as_of(table, predicate, order_by, limit, offset, Some(as_of))?
                    }
                };
                if rows.len() == 1 {
                    self.state
                        .lock()
                        .unwrap()
                        .admit(cache_key, rows[0].clone(), &self.config);
                }
                return Ok(rows);
            }
        }
        // All other predicates pass through; no query-result caching.
        match as_of {
            AsOfCoordinate::Present => {
                self.backing.query(table, predicate, order_by, limit, offset)
            }
            AsOfCoordinate::AsOf(_) => {
                self.backing.query_as_of(table, predicate, order_by, limit, offset, Some(as_of))
            }
        }
    }
}
