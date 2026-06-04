//! CachingRowStore: in-memory LRU hot tier wrapping any RowStore.
//!
//! Mirrors Swift's `CachingRowStore`. Synchronous throughout (the Rust
//! `RowStore` trait is synchronous; Swift is async because actors require
//! it, not because of real I/O). Thread-safety is achieved via
//! `Arc<CachingRowStore>` with `Mutex<CacheState>` for mutable hot-tier
//! state — equivalent to Swift's actor isolation of `CacheActor`.
//!
//! Sensitivity gate: rows whose `provenance` column encodes a sensitivity
//! level above the configured threshold — or equal to Secret (level 3) —
//! are never admitted. Absent column → admit; unparseable value → reject
//! (fail closed). Encoding per ARIA adjective contract:
//!   level = (raw_i64 >> 4) & 0x7   (bits [6:4])
//!   0 = Normal, 1 = Elevated, 2 = Restricted, 3 = Secret
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

// ─────────────────────────────────────────────────────────────────
// Internal cache state
// ─────────────────────────────────────────────────────────────────

struct CacheEntry {
    row: StorageRow,
    access_order: u64, // higher = more recently used
    byte_size: usize,
}

struct CacheState {
    entries: HashMap<RowHandle, CacheEntry>,
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

    /// Return the cached row for `handle`, updating its LRU position.
    fn get(&mut self, handle: &RowHandle) -> Option<StorageRow> {
        let entry = self.entries.get_mut(handle)?;
        self.access_counter += 1;
        entry.access_order = self.access_counter;
        Some(entry.row.clone())
    }

    /// Admit `row` under `handle` subject to the sensitivity gate and byte
    /// budget. Evicts LRU entries as needed.
    fn admit(&mut self, handle: RowHandle, row: StorageRow, config: &EstateCacheConfig) {
        if !config.enabled {
            return;
        }
        if !is_admissible(&row, config) {
            return;
        }
        let size = estimated_bytes(&row);
        // Remove any stale entry before budget accounting.
        if let Some(existing) = self.entries.remove(&handle) {
            self.total_bytes -= existing.byte_size;
        }
        // When a ceiling is set, evict LRU entries to make room.
        // ceiling_bytes == 0 means unlimited (enabled=false is guarded above).
        if config.ceiling_bytes > 0 {
            let ceiling = config.ceiling_bytes as usize;
            while !self.entries.is_empty() && self.total_bytes + size > ceiling {
                self.evict_lru();
            }
            // Skip admission if the row is larger than the entire ceiling.
            if self.total_bytes + size > ceiling {
                return;
            }
        }
        self.access_counter += 1;
        self.total_bytes += size;
        self.entries.insert(
            handle,
            CacheEntry {
                row,
                access_order: self.access_counter,
                byte_size: size,
            },
        );
    }

    /// Remove the entry for `handle`.
    fn evict(&mut self, handle: &RowHandle) {
        if let Some(entry) = self.entries.remove(handle) {
            self.total_bytes -= entry.byte_size;
        }
    }

    /// Remove all entries whose `RowHandle::table` matches `table`.
    fn evict_all_for_table(&mut self, table: &str) {
        let to_remove: Vec<RowHandle> = self
            .entries
            .keys()
            .filter(|h| h.table == table)
            .cloned()
            .collect();
        for handle in to_remove {
            if let Some(entry) = self.entries.remove(&handle) {
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
            .map(|(h, _)| h.clone());
        if let Some(handle) = lru {
            if let Some(entry) = self.entries.remove(&handle) {
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
/// `provenance` encodes sensitivity in bits [6:4]: `level = (raw >> 4) & 0x7`.
///
///   - Column absent           → admit
///   - level > threshold       → reject
///   - level == 3 (Secret)     → reject always regardless of threshold
///   - Unparseable value       → reject (fail closed)
fn is_admissible(row: &StorageRow, config: &EstateCacheConfig) -> bool {
    match row.get("provenance") {
        None => true,
        Some(TypedValue::Int(raw)) | Some(TypedValue::Bitmap(raw)) => {
            let level = ((raw >> 4) & 0x7) as i32;
            // Hard Secret exclusion is defence-in-depth: threshold is already
            // clamped to ≤2 by EstateCacheConfig, but the guard is correct
            // even if that clamp were bypassed.
            if level == 3 {
                return false;
            }
            level <= config.sensitivity_threshold
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
    // Mutex satisfies Send + Sync; poison on panic is propagated to callers.
    state: Mutex<CacheState>,
}

impl CachingRowStore {
    /// Wrap `backing` with an in-memory LRU hot tier governed by `config`.
    pub fn new(backing: Arc<dyn RowStore>, config: EstateCacheConfig) -> Self {
        CachingRowStore {
            backing,
            config,
            state: Mutex::new(CacheState::new()),
        }
    }

    /// Invalidate a cached entry. Called by `CacheInvalidator` when an
    /// external write arrives via `StorageObserver`. Pass `key: None` to
    /// evict all entries for `table` (bulk-update semantics).
    pub fn invalidate(&self, table: &str, key: Option<RowKey>) {
        if !self.config.enabled {
            return;
        }
        let mut state = self.state.lock().unwrap();
        match key {
            Some(k) => state.evict(&RowHandle::new(table, k)),
            None => state.evict_all_for_table(table),
        }
    }
}

impl RowStore for CachingRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        // Insert always goes to the backing store. The returned handle is new,
        // so there is no prior cache entry to invalidate.
        self.backing.insert(table, values)
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        let handle = self.backing.upsert(table, values, conflict_columns)?;
        // Upsert may have updated an existing cached row; evict so the next
        // read falls through to the backing store.
        if self.config.enabled {
            self.state.lock().unwrap().evict(&handle);
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
            let mut state = self.state.lock().unwrap();
            if let Some(key) = extract_key(Some(predicate)) {
                state.evict(&RowHandle::new(table, key));
            } else {
                state.evict_all_for_table(table);
            }
        }
        Ok(count)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let count = self.backing.delete(table, predicate)?;
        if self.config.enabled && count > 0 {
            let mut state = self.state.lock().unwrap();
            if let Some(key) = extract_key(Some(predicate)) {
                state.evict(&RowHandle::new(table, key));
            } else {
                state.evict_all_for_table(table);
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
        if self.config.enabled {
            if let Some(key) = extract_key(predicate) {
                let handle = RowHandle::new(table, key);
                // Check cache first; release the lock before calling the
                // backing store to avoid holding it across a potentially
                // slow operation.
                let cached = self.state.lock().unwrap().get(&handle);
                if let Some(row) = cached {
                    return Ok(vec![row]);
                }
                // Cache miss: query backing store and admit the result.
                let rows = self.backing.query(table, predicate, order_by, limit, offset)?;
                if rows.len() == 1 {
                    self.state
                        .lock()
                        .unwrap()
                        .admit(handle, rows[0].clone(), &self.config);
                }
                return Ok(rows);
            }
        }
        // All other predicates pass through; no query-result caching.
        self.backing.query(table, predicate, order_by, limit, offset)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        self.backing.count(table, predicate)
    }
}
