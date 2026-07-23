//! In-memory backend. Mirror of Swift's PersistenceKitInMemory.
//!
//! Stored in a single Mutex<State> for simplicity; the Swift
//! side uses an actor for the same purpose. RowStore, BlobStore,
//! AuditLog, and StorageObserver views are thin
//! Arc<InMemoryStorage> wrappers that lock the same state.
//!
//! No persistence between process runs; this backend exists for
//! tests and rapid iteration. The SQLite and PostgreSQL backends
//! (sqlite.rs, postgres.rs) share the same trait surface and are
//! fully shipped alongside InMemory.

use crate::audit_log::{AuditEvent, AuditLog};
use crate::blob_store::BlobStore;
use crate::error::{StorageError, StorageResult};
use crate::generated_column::GeneratedColumn;
use crate::observer::{BlobChange, BlobEvent, BlobObserverHub, ChangeOrigin, ObserverHub, StorageEvent, StorageObserver, TableChange};
use crate::predicate::{OrderClause, OrderDirection, StoragePredicate};
use crate::caching_row_store::CachingRowStore;
use crate::row_store::RowStore;
use crate::schema::{SchemaDeclaration, SchemaOperation, TableDeclaration};
use crate::storage::{
    BackendConfiguration, EstateConfiguration, IsolationLevel, Storage, StorageTransaction,
};
use crate::types::{Column, RowHandle, RowKey, StorageRow, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

// ----- internal state -----

#[derive(Clone, Default)]
struct State {
    schema_version: i32,
    /// Per-kit schema versions (for `current_schema_version_for`).
    kit_schema_versions: BTreeMap<String, i32>,
    tables: BTreeMap<String, Table>,
    blobs: BTreeMap<String, Vec<u8>>,
    audit_events: Vec<AuditEvent>,
    // Notification isolation (SECFIX-WS2-PK F2/F4): buffer notifications during
    // a transaction so rolled-back writes never reach observers.
    //
    // `in_transaction` is part of State so the snapshot taken before the
    // transaction (when `in_transaction = false`) automatically resets this
    // field on rollback — no separate cleanup needed on the error path.
    in_transaction: bool,
    /// Row change events buffered while `in_transaction = true`. Drained and
    /// emitted to the hub on commit; discarded on rollback via snapshot restore.
    pending_row_events: Vec<TableChange>,
    /// Blob change events buffered while `in_transaction = true`. Mirrors
    /// `pending_row_events` for the blob hub.
    pending_blob_events: Vec<BlobChange>,
}

#[derive(Clone)]
struct Table {
    declaration: TableDeclaration,
    rows: BTreeMap<RowKey, BTreeMap<String, TypedValue>>,
}

// ----- public storage type -----

pub struct InMemoryStorage {
    configuration: EstateConfiguration,
    state: Arc<Mutex<State>>,
    hub: Arc<ObserverHub>,
    /// Blob observer hub: fans out blob put/delete events to all active
    /// incremental replication sessions. Separate from the row hub because
    /// blob changes do not filter by table name — every subscriber gets every
    /// blob event (same pattern as Swift's `ObserverRegistry.notifyBlob`).
    blob_hub: Arc<BlobObserverHub>,
    /// Single shared dataset store for this storage's lifetime. A per-call
    /// fresh instance would hand each caller an independent empty store —
    /// two `dataset_store()` calls must observe the same tables (parity
    /// with Swift's stored `let datasetStore`).
    dataset_store: Arc<crate::dataset_store::InMemoryDatasetStore>,
    /// Monotone counter of transaction rollbacks. Stored separately from
    /// `state` because `state` is snapshot/restored on rollback — putting the
    /// counter there would reset it on every rollback, losing the history.
    rollback_count: Arc<Mutex<i64>>,
}

impl InMemoryStorage {
    pub fn new(configuration: EstateConfiguration) -> Self {
        assert!(
            matches!(configuration.backend, BackendConfiguration::InMemory),
            "InMemoryStorage requires BackendConfiguration::InMemory"
        );
        InMemoryStorage {
            configuration,
            state: Arc::new(Mutex::new(State::default())),
            hub: Arc::new(ObserverHub::new()),
            blob_hub: Arc::new(BlobObserverHub::new()),
            dataset_store: Arc::new(crate::dataset_store::InMemoryDatasetStore::new()),
            rollback_count: Arc::new(Mutex::new(0)),
        }
    }

    /// Convenience constructor for tests.
    pub fn with_estate(estate_id: uuid::Uuid) -> Self {
        Self::new(EstateConfiguration::new(
            estate_id,
            BackendConfiguration::InMemory,
        ))
    }
}

impl Storage for InMemoryStorage {
    /// The in-memory backend has no page model and no on-disk footprint:
    /// nothing is ever reclaimable (explicit per-backend contract, mirrors
    /// the Swift `InMemoryStorage: StorageMaintenance` conformance).
    fn estimated_reclaimable_bytes(
        &self,
    ) -> Result<i64, crate::maintenance::MaintenanceError> {
        Ok(0)
    }

    /// Explicit no-op (per the maintenance backend table). The report says
    /// `performed: false` so callers can distinguish "ran and freed
    /// nothing" from "nothing to run".
    fn perform_maintenance(
        &self,
        _progress: Option<&(dyn Fn(crate::maintenance::MaintenanceProgress) + Send + Sync)>,
        _should_cancel: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> Result<crate::maintenance::MaintenanceReport, crate::maintenance::MaintenanceError>
    {
        Ok(crate::maintenance::MaintenanceReport::no_op(
            "inmemory",
            "in-memory backend holds no pages; nothing to reclaim",
        ))
    }

    fn configuration(&self) -> &EstateConfiguration {
        &self.configuration
    }

    fn row_store(&self) -> Arc<dyn RowStore> {
        let backing: Arc<dyn RowStore> = Arc::new(InMemoryRowStore {
            state: self.state.clone(),
            hub: self.hub.clone(),
        });
        // When cache is enabled, wrap with an LRU hot tier. Disabled (the
        // default) is a zero-change passthrough — identical to pre-mission
        // behavior.
        if self.configuration.cache_config.enabled {
            Arc::new(CachingRowStore::new(
                backing,
                self.configuration.cache_config.clone(),
            ))
        } else {
            backing
        }
    }

    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(InMemoryBlobStore {
            state: self.state.clone(),
            blob_hub: self.blob_hub.clone(),
        })
    }

    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Arc::new(InMemoryAuditLog {
            state: self.state.clone(),
        })
    }

    fn observer(&self) -> Arc<dyn StorageObserver> {
        Arc::new(InMemoryObserver {
            hub: self.hub.clone(),
            blob_hub: self.blob_hub.clone(),
        })
    }

    /// Dataset store override: returns the storage's single shared
    /// `InMemoryDatasetStore` instance — every call sees the same dataset
    /// state, mirroring the Swift leg's stored `let datasetStore` property.
    /// Note: InMemory dataset state is separate from `InMemoryStorage.state`
    /// (it does not participate in `transaction()` rollbacks). This is
    /// acceptable for a test double — individual operation correctness is
    /// what MX-TAB-1 tests verify.
    fn dataset_store(&self) -> StorageResult<Arc<dyn crate::dataset_store::DatasetStore>> {
        Ok(self.dataset_store.clone())
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        let mut state = self.state.lock().unwrap();
        // Gate on per-kit version so a second kit opening on this storage
        // does not skip migration because another kit advanced the global
        // schema_version counter above this kit's target version.
        let kit_current = state.kit_schema_versions.get(&schema.kit_id).copied().unwrap_or(0);
        if kit_current < schema.version {
            apply_migrations_inner(&mut state, schema)?;
        }
        Ok(())
    }

    fn close(&self) -> StorageResult<()> {
        Ok(())
    }

    fn current_schema_version(&self) -> StorageResult<i32> {
        Ok(self.state.lock().unwrap().schema_version)
    }

    fn current_schema_version_for(&self, kit_id: &str) -> StorageResult<i32> {
        Ok(self.state.lock().unwrap().kit_schema_versions.get(kit_id).copied().unwrap_or(0))
    }

    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        let mut state = self.state.lock().unwrap();
        apply_migrations_inner(&mut state, schema)
    }

    fn transaction(
        &self,
        _isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        // Notification isolation (SECFIX-WS2-PK F2/F4): take the snapshot
        // BEFORE marking in_transaction so the snapshot carries
        // `in_transaction = false` and empty pending event lists. On rollback,
        // restoring the snapshot automatically resets those fields — no
        // separate cleanup needed on the error path.
        //
        // ISOLATION INVARIANT: this method does not self-serialize concurrent
        // callers, and — unlike the SQLite backend — there is no connection
        // write lock to fall back on. Rollback restores the whole
        // pre-transaction snapshot, which would REVERT any concurrent
        // non-transactional write that completed during the block. Callers must
        // guarantee no other caller holds the same InMemoryStorage concurrently
        // during a transaction block; production provides this by serializing
        // all estate access behind the coordinator lock.
        let snapshot = self.state.lock().unwrap().clone();
        // Mark transaction open: writes will buffer notifications.
        {
            let mut state = self.state.lock().unwrap();
            state.in_transaction = true;
            state.pending_row_events.clear();
            state.pending_blob_events.clear();
        }
        match block(self) {
            Ok(()) => {
                // Commit: drain pending events and emit them now that the
                // writes are committed to the live state.
                let (row_events, blob_events) = {
                    let mut state = self.state.lock().unwrap();
                    state.in_transaction = false;
                    (
                        std::mem::take(&mut state.pending_row_events),
                        std::mem::take(&mut state.pending_blob_events),
                    )
                };
                for ev in row_events { self.hub.emit(ev); }
                for ev in blob_events { self.blob_hub.emit(ev); }
                Ok(())
            }
            Err(e) => {
                // Restore the pre-transaction snapshot. The snapshot has
                // `in_transaction = false` and empty pending event lists, so
                // rolled-back notifications are automatically discarded.
                *self.state.lock().unwrap() = snapshot;
                // Record the rollback for introspection. The counter lives
                // outside `state` so it is not itself rolled back.
                *self.rollback_count.lock().unwrap() += 1;
                Err(e)
            }
        }
    }
}

impl StorageTransaction for InMemoryStorage {
    fn row_store(&self) -> Arc<dyn RowStore> {
        Storage::row_store(self)
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Storage::blob_store(self)
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Storage::audit_log(self)
    }
}

// ─────────────────────────────────────────────────────────────────────
// StorageIntrospection — DB-layer health statistics for InMemory.
// ─────────────────────────────────────────────────────────────────────

impl crate::introspection::StorageIntrospection for InMemoryStorage {
    /// Capture a point-in-time snapshot of InMemory backend health.
    ///
    /// logical_size_bytes: approximate in-memory footprint. Estimated as
    /// 256 bytes per row (a conservative average for BTreeMap<String, TypedValue>
    /// overhead per row) plus the exact byte count of stored blobs. This is a
    /// relative health signal, not a precise allocator measurement.
    ///
    /// row_count: sum of all row counts across all tables.
    /// blob_count: number of blob entries.
    /// transaction_rollback_count: incremented by `transaction()` on error.
    ///
    /// All SQLite- and PostgreSQL-specific fields are None.
    fn stats(&self, now_secs: i64) -> crate::error::StorageResult<crate::introspection::StorageStats> {
        use crate::introspection::StorageStats;

        let state = self.state.lock().unwrap();

        let row_count: usize = state.tables.values().map(|t| t.rows.len()).sum();
        let blob_count: usize = state.blobs.len();

        // Approximate size: 256 B average per row + exact blob bytes.
        let blob_bytes: i64 = state.blobs.values().map(|b| b.len() as i64).sum();
        let approx_bytes: i64 = row_count as i64 * 256 + blob_bytes;

        let rollback = *self.rollback_count.lock().unwrap();

        Ok(StorageStats {
            logical_size_bytes: approx_bytes,
            page_size: None,
            page_count: None,
            freelist_page_count: None,
            wal_frame_count: None,
            cache_hit_ratio: None,
            transaction_commit_count: None,
            transaction_rollback_count: Some(rollback),
            deadlock_count: None,
            lock_contention: None,
            row_count: Some(row_count),
            blob_count: Some(blob_count),
            captured_at_secs: now_secs,
        })
    }
}

fn apply_migrations_inner(state: &mut State, schema: &SchemaDeclaration) -> StorageResult<()> {
    // Create tables that don't exist yet.
    for table in &schema.tables {
        state
            .tables
            .entry(table.name.clone())
            .or_insert_with(|| Table {
                declaration: table.clone(),
                rows: BTreeMap::new(),
            });
    }
    // Per-kit version is the source of truth for the migration gate.
    // The global `schema_version` is updated in parallel so the no-arg
    // `current_schema_version()` still returns a sensible value (the max
    // across all kits that have opened on this storage instance).
    let kit_current = state.kit_schema_versions.get(&schema.kit_id).copied().unwrap_or(0);
    let mut pending: Vec<_> = schema
        .migrations
        .iter()
        .filter(|m| m.from_version >= kit_current && m.to_version <= schema.version)
        .cloned()
        .collect();
    pending.sort_by_key(|m| m.from_version);
    for migration in pending {
        for op in migration.operations {
            apply_operation(state, op)?;
        }
        state.kit_schema_versions.insert(schema.kit_id.clone(), migration.to_version);
        state.schema_version = std::cmp::max(state.schema_version, migration.to_version);
    }
    if state.kit_schema_versions.get(&schema.kit_id).copied().unwrap_or(0) < schema.version {
        state.kit_schema_versions.insert(schema.kit_id.clone(), schema.version);
        state.schema_version = std::cmp::max(state.schema_version, schema.version);
    }
    Ok(())
}

fn apply_operation(state: &mut State, op: SchemaOperation) -> StorageResult<()> {
    match op {
        SchemaOperation::CreateTable(decl) => {
            state.tables.insert(
                decl.name.clone(),
                Table {
                    declaration: decl,
                    rows: BTreeMap::new(),
                },
            );
            Ok(())
        }
        SchemaOperation::DropTable { name } => {
            state.tables.remove(&name);
            Ok(())
        }
        SchemaOperation::AddColumn { table, column } => {
            let t = state
                .tables
                .get_mut(&table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("addColumn: table {} not found", table),
                })?;
            // Idempotent (mirrors CREATE TABLE IF NOT EXISTS): the fresh-DB path
            // creates the table at the latest schema before replaying migrations
            // from version 0, so the column may already be present. Skip in that
            // case to avoid a duplicate column entry in the declaration.
            if t.declaration.columns.iter().any(|c| c.name == column.name) {
                return Ok(());
            }
            t.declaration.columns.push(column);
            Ok(())
        }
        SchemaOperation::DropColumn { table, column_name } => {
            let t = state
                .tables
                .get_mut(&table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("dropColumn: table {} not found", table),
                })?;
            t.declaration.columns.retain(|c| c.name != column_name);
            for row in t.rows.values_mut() {
                row.remove(&column_name);
            }
            Ok(())
        }
        SchemaOperation::RenameColumn { .. }
        | SchemaOperation::AddIndex(_)
        | SchemaOperation::DropIndex { .. }
        | SchemaOperation::Custom { .. } => Ok(()),
    }
}

// ----- RowStore -----

struct InMemoryRowStore {
    state: Arc<Mutex<State>>,
    hub: Arc<ObserverHub>,
}

impl InMemoryRowStore {
    /// Resolve the internal `RowKey` for a row about to be written.
    ///
    /// Single-column PK only (composite/multi-column PKs fall through to
    /// the random-mint default below — unchanged, out of gap-5's scope).
    /// For a `.uuid`-typed PK, the value itself IS the key (unchanged fast
    /// path). For a `.text`-typed PK, gap 5: derive the key
    /// DETERMINISTICALLY from the PK's content via
    /// `row_key_derivation::deterministic_row_key` instead of minting a
    /// fresh random UUID. Before this fix, two storage instances (e.g. two
    /// federation spokes) writing the same logical row (same `.text` PK
    /// value) resolved two unrelated random `RowKey`s, so ConvergenceKit's
    /// HLC-ordering gates — keyed by `RowKey` — compared against mismatched
    /// side-table entries and ordering silently degraded to pull-order
    /// instead of HLC-order. See `row_key_derivation.rs` for the full
    /// rationale and the sibling relationship to `deterministic_uuid`
    /// (LocusKit's `merkle_rollup.rs`).
    fn resolve_key(table: &Table, values: &BTreeMap<String, TypedValue>) -> RowKey {
        if table.declaration.primary_key.len() == 1 {
            let pk = &table.declaration.primary_key[0];
            match values.get(pk) {
                Some(TypedValue::Uuid(u)) => return *u,
                Some(TypedValue::Text(s)) => return crate::row_key_derivation::deterministic_row_key(s),
                _ => {}
            }
        }
        uuid::Uuid::new_v4()
    }
}

impl RowStore for InMemoryRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let (key, stored, changed, in_txn) = {
            let mut state = self.state.lock().unwrap();
            let t = state
                .tables
                .get_mut(table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("insert: table {} not found", table),
                })?;
            let key = Self::resolve_key(t, &values);
            if t.rows.contains_key(&key) {
                return Err(StorageError::DuplicateKey {
                    table: table.to_string(),
                    key: key.to_string(),
                });
            }
            let generated = t.declaration.generated_columns.clone();
            let mut stored = values;
            materialize_generated(&generated, &mut stored);
            t.rows.insert(key, stored.clone());
            // changedColumns for insert = all stored column names (CVK-WB4).
            let changed: std::collections::HashSet<String> = stored.keys().cloned().collect();
            // Buffer notification if in a transaction (SECFIX-WS2-PK F2).
            let in_txn = state.in_transaction;
            if in_txn {
                state.pending_row_events.push(TableChange {
                    table: table.to_string(),
                    event: StorageEvent::Insert,
                    row_key: Some(key),
                    values: Some(stored.clone()),
                    hlc: None,
                    origin: ChangeOrigin::Local,
                    changed_columns: Some(changed.clone()),
                });
            }
            (key, stored, changed, in_txn)
        };
        if !in_txn {
            self.hub.emit(TableChange {
                table: table.to_string(),
                event: StorageEvent::Insert,
                row_key: Some(key),
                values: Some(stored),
                hlc: None,
                origin: ChangeOrigin::Local,
                changed_columns: Some(changed),
            });
        }
        Ok(RowHandle::new(table, key))
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        let (key, event, emitted_values, changed_cols, in_txn) = {
            let mut state = self.state.lock().unwrap();
            let t = state
                .tables
                .get_mut(table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("upsert: table {} not found", table),
                })?;
            // Find existing row matching all conflict columns.
            let existing_key = t
                .rows
                .iter()
                .find(|(_, row)| {
                    conflict_columns
                        .iter()
                        .all(|col| match (row.get(col), values.get(col)) {
                            (Some(a), Some(b)) => a == b,
                            _ => false,
                        })
                })
                .map(|(k, _)| *k);
            let generated = t.declaration.generated_columns.clone();
            let (key, ev, vals, changed) = if let Some(k) = existing_key {
                let row = t.rows.get_mut(&k).unwrap();
                // Capture old values before mutation for changedColumns diff (CVK-WB4).
                let old_row = row.clone();
                for (col, v) in values.into_iter() {
                    row.insert(col, v);
                }
                materialize_generated(&generated, row);
                let merged = row.clone();
                // changedColumns = columns whose value differs from the pre-upsert row.
                let changed: std::collections::HashSet<String> = merged
                    .keys()
                    .filter(|col| old_row.get(*col) != merged.get(*col))
                    .cloned()
                    .collect();
                (k, StorageEvent::Update, merged, changed)
            } else {
                let key = Self::resolve_key(t, &values);
                let mut stored = values;
                materialize_generated(&generated, &mut stored);
                t.rows.insert(key, stored.clone());
                // changedColumns for upsert-as-insert = all stored column names.
                let changed: std::collections::HashSet<String> = stored.keys().cloned().collect();
                (key, StorageEvent::Insert, stored, changed)
            };
            // Buffer notification if in a transaction (SECFIX-WS2-PK F2).
            let in_txn = state.in_transaction;
            if in_txn {
                state.pending_row_events.push(TableChange {
                    table: table.to_string(),
                    event: ev,
                    row_key: Some(key),
                    values: Some(vals.clone()),
                    hlc: None,
                    origin: ChangeOrigin::Local,
                    changed_columns: Some(changed.clone()),
                });
            }
            (key, ev, vals, changed, in_txn)
        };
        if !in_txn {
            self.hub.emit(TableChange {
                table: table.to_string(),
                event,
                row_key: Some(key),
                values: Some(emitted_values),
                hlc: None,
                origin: ChangeOrigin::Local,
                changed_columns: Some(changed_cols),
            });
        }
        Ok(RowHandle::new(table, key))
    }

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize> {
        // Notification payload: (key, merged_row, changed_columns) — CVK-WB4.
        let mut notifications: Vec<(RowKey, BTreeMap<String, TypedValue>, std::collections::HashSet<String>)> = Vec::new();
        let (count, in_txn) = {
            let mut state = self.state.lock().unwrap();
            let t = state
                .tables
                .get_mut(table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("update: table {} not found", table),
                })?;
            if t.declaration.append_only {
                return Err(StorageError::AppendOnlyViolation {
                    table: table.to_string(),
                });
            }
            let generated = t.declaration.generated_columns.clone();
            let mut count = 0;
            let matching_keys: Vec<RowKey> = t
                .rows
                .iter()
                .filter(|(_, row)| evaluate_predicate(predicate, row))
                .map(|(k, _)| *k)
                .collect();
            for k in matching_keys {
                let row = t.rows.get_mut(&k).unwrap();
                // Capture old values before mutation for changedColumns diff (CVK-WB4).
                // The pre-update row is available here without an extra read.
                let old_row = row.clone();
                for (col, v) in values.iter() {
                    row.insert(col.clone(), v.clone());
                }
                materialize_generated(&generated, row);
                let merged = row.clone();
                let changed: std::collections::HashSet<String> = merged
                    .keys()
                    .filter(|col| old_row.get(*col) != merged.get(*col))
                    .cloned()
                    .collect();
                notifications.push((k, merged, changed));
                count += 1;
            }
            // Buffer notifications when inside a transaction (SECFIX-WS2-PK F2).
            let in_txn = state.in_transaction;
            if in_txn {
                for (key, row, changed) in &notifications {
                    state.pending_row_events.push(TableChange {
                        table: table.to_string(),
                        event: StorageEvent::Update,
                        row_key: Some(*key),
                        values: Some(row.clone()),
                        hlc: None,
                        origin: ChangeOrigin::Local,
                        changed_columns: Some(changed.clone()),
                    });
                }
            }
            (count, in_txn)
        };
        if !in_txn {
            for (key, row, changed) in notifications {
                self.hub.emit(TableChange {
                    table: table.to_string(),
                    event: StorageEvent::Update,
                    row_key: Some(key),
                    values: Some(row),
                    hlc: None,
                    origin: ChangeOrigin::Local,
                    changed_columns: Some(changed),
                });
            }
        }
        Ok(count)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let mut notifications: Vec<(RowKey, BTreeMap<String, TypedValue>)> = Vec::new();
        let (count, in_txn) = {
            let mut state = self.state.lock().unwrap();
            let t = state
                .tables
                .get_mut(table)
                .ok_or_else(|| StorageError::InvalidQuery {
                    detail: format!("delete: table {} not found", table),
                })?;
            if t.declaration.append_only {
                return Err(StorageError::AppendOnlyViolation {
                    table: table.to_string(),
                });
            }
            let matching: Vec<(RowKey, BTreeMap<String, TypedValue>)> = t
                .rows
                .iter()
                .filter(|(_, row)| evaluate_predicate(predicate, row))
                .map(|(k, v)| (*k, v.clone()))
                .collect();
            for (k, row) in &matching {
                t.rows.remove(k);
                notifications.push((*k, row.clone()));
            }
            // Buffer notifications when inside a transaction (SECFIX-WS2-PK F2).
            let in_txn = state.in_transaction;
            if in_txn {
                for (key, row) in &notifications {
                    state.pending_row_events.push(TableChange {
                        table: table.to_string(),
                        event: StorageEvent::Delete,
                        row_key: Some(*key),
                        values: Some(row.clone()),
                        hlc: None,
                        origin: ChangeOrigin::Local,
                        // changedColumns for delete = None (CVK-WB4).
                        changed_columns: None,
                    });
                }
            }
            (matching.len(), in_txn)
        };
        if !in_txn {
            for (key, row) in notifications {
                self.hub.emit(TableChange {
                    table: table.to_string(),
                    event: StorageEvent::Delete,
                    row_key: Some(key),
                    values: Some(row),
                    hlc: None,
                    origin: ChangeOrigin::Local,
                    // changedColumns for delete = None (CVK-WB4).
                    changed_columns: None,
                });
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
        let state = self.state.lock().unwrap();
        let t = state
            .tables
            .get(table)
            .ok_or_else(|| StorageError::InvalidQuery {
                detail: format!("query: table {} not found", table),
            })?;
        let mut results: Vec<StorageRow> = t
            .rows
            .values()
            .filter(|row| match predicate {
                Some(p) => evaluate_predicate(p, row),
                None => true,
            })
            .map(|row| StorageRow::new(row.clone()))
            .collect();
        if !order_by.is_empty() {
            results.sort_by(|a, b| {
                for clause in order_by {
                    let lv = a
                        .get(&clause.column.name)
                        .cloned()
                        .unwrap_or(TypedValue::Null);
                    let rv = b
                        .get(&clause.column.name)
                        .cloned()
                        .unwrap_or(TypedValue::Null);
                    let cmp = compare_typed_values(&lv, &rv);
                    if let Some(order) = cmp {
                        if order != std::cmp::Ordering::Equal {
                            return match clause.direction {
                                OrderDirection::Ascending => order,
                                OrderDirection::Descending => order.reverse(),
                            };
                        }
                    }
                }
                std::cmp::Ordering::Equal
            });
        }
        if let Some(o) = offset {
            results = results.into_iter().skip(o).collect();
        }
        if let Some(l) = limit {
            results.truncate(l);
        }
        Ok(results)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        let state = self.state.lock().unwrap();
        let t = state
            .tables
            .get(table)
            .ok_or_else(|| StorageError::InvalidQuery {
                detail: format!("count: table {} not found", table),
            })?;
        Ok(match predicate {
            Some(p) => t
                .rows
                .values()
                .filter(|row| evaluate_predicate(p, row))
                .count(),
            None => t.rows.len(),
        })
    }
}

// ----- BlobStore -----

struct InMemoryBlobStore {
    state: Arc<Mutex<State>>,
    /// Blob observer hub for emitting put/delete events to incremental
    /// replication sessions. Mirrors Swift's `ObserverRegistry.notifyBlob`.
    blob_hub: Arc<BlobObserverHub>,
}

impl BlobStore for InMemoryBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        let bytes_vec = bytes.to_vec();
        let in_txn = {
            let mut state = self.state.lock().unwrap();
            state.blobs.insert(key.to_string(), bytes_vec.clone());
            // Buffer the notification when inside a transaction (SECFIX-WS2-PK F4).
            // The blob is written to the in-memory store but the transaction has not
            // committed; emitting now would deliver a phantom put to replication
            // sessions if the transaction is rolled back.
            let in_txn = state.in_transaction;
            if in_txn {
                state.pending_blob_events.push(BlobChange {
                    key: key.to_string(),
                    event: BlobEvent::Put,
                    bytes: Some(bytes_vec.clone()),
                });
            }
            in_txn
        };
        if !in_txn {
            self.blob_hub.emit(BlobChange {
                key: key.to_string(),
                event: BlobEvent::Put,
                bytes: Some(bytes_vec),
            });
        }
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        Ok(self.state.lock().unwrap().blobs.get(key).cloned())
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        let in_txn = {
            let mut state = self.state.lock().unwrap();
            state.blobs.remove(key);
            // Buffer the notification when inside a transaction (SECFIX-WS2-PK F4).
            let in_txn = state.in_transaction;
            if in_txn {
                state.pending_blob_events.push(BlobChange {
                    key: key.to_string(),
                    event: BlobEvent::Delete,
                    bytes: None,
                });
            }
            in_txn
        };
        if !in_txn {
            self.blob_hub.emit(BlobChange {
                key: key.to_string(),
                event: BlobEvent::Delete,
                bytes: None,
            });
        }
        Ok(())
    }
    fn exists(&self, key: &str) -> StorageResult<bool> {
        Ok(self.state.lock().unwrap().blobs.contains_key(key))
    }
    fn size(&self, key: &str) -> StorageResult<Option<usize>> {
        Ok(self.state.lock().unwrap().blobs.get(key).map(|b| b.len()))
    }
    fn list_keys(&self) -> StorageResult<Vec<String>> {
        Ok(self.state.lock().unwrap().blobs.keys().cloned().collect())
    }
}

// ----- AuditLog -----

struct InMemoryAuditLog {
    state: Arc<Mutex<State>>,
}

impl InMemoryAuditLog {
    fn idempotent_key(event: &AuditEvent) -> (RowKey, i64, i32, i32) {
        (
            event.event_id,
            event.hlc.physical_time,
            event.hlc.logical_count,
            event.hlc.node_id,
        )
    }
}

impl AuditLog for InMemoryAuditLog {
    fn append(&self, event: AuditEvent) -> StorageResult<()> {
        let mut state = self.state.lock().unwrap();
        let key = Self::idempotent_key(&event);
        let already_present = state
            .audit_events
            .iter()
            .any(|e| Self::idempotent_key(e) == key);
        if !already_present {
            state.audit_events.push(event);
        }
        Ok(())
    }

    fn append_batch(&self, events: Vec<AuditEvent>) -> StorageResult<()> {
        for event in events {
            self.append(event)?;
        }
        Ok(())
    }

    fn iterate(
        &self,
        after: Option<HLC>,
        row_id: Option<RowKey>,
        limit: usize,
    ) -> StorageResult<Vec<AuditEvent>> {
        let state = self.state.lock().unwrap();
        let mut events: Vec<AuditEvent> = state.audit_events.clone();
        if let Some(a) = after {
            events.retain(|e| hlc_gt(&e.hlc, &a));
        }
        if let Some(r) = row_id {
            events.retain(|e| e.row_id == r);
        }
        events.sort_by(|x, y| hlc_cmp(&x.hlc, &y.hlc));
        events.truncate(limit);
        Ok(events)
    }

    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>> {
        let state = self.state.lock().unwrap();
        let mut events: Vec<AuditEvent> = state
            .audit_events
            .iter()
            .filter(|e| e.row_id == row_id)
            .cloned()
            .collect();
        events.sort_by(|x, y| hlc_cmp(&x.hlc, &y.hlc));
        Ok(events)
    }

    fn row_ids_with_audit_verbs(
        &self,
        row_ids: &[RowKey],
        verbs: &[&str],
    ) -> StorageResult<std::collections::HashSet<RowKey>> {
        if row_ids.is_empty() || verbs.is_empty() {
            return Ok(std::collections::HashSet::new());
        }
        // Build look-up sets for O(1) membership tests inside the scan loop.
        let id_set: std::collections::HashSet<RowKey> = row_ids.iter().copied().collect();
        let verb_set: std::collections::HashSet<&str> = verbs.iter().copied().collect();
        let state = self.state.lock().unwrap();
        // Scan the event vec once: collect row_ids that are in the requested
        // set AND have a matching verb. This is the InMemory equivalent of:
        //   SELECT DISTINCT row_id FROM _storagekit_audit
        //   WHERE row_id IN (...) AND verb IN (...)
        let covered: std::collections::HashSet<RowKey> = state
            .audit_events
            .iter()
            .filter(|e| id_set.contains(&e.row_id) && verb_set.contains(e.verb.as_str()))
            .map(|e| e.row_id)
            .collect();
        Ok(covered)
    }

    fn count(&self) -> StorageResult<usize> {
        Ok(self.state.lock().unwrap().audit_events.len())
    }
}

fn hlc_cmp(a: &HLC, b: &HLC) -> std::cmp::Ordering {
    a.physical_time
        .cmp(&b.physical_time)
        .then(a.logical_count.cmp(&b.logical_count))
        .then(a.node_id.cmp(&b.node_id))
}

fn hlc_gt(a: &HLC, b: &HLC) -> bool {
    hlc_cmp(a, b) == std::cmp::Ordering::Greater
}

// ----- StorageObserver -----

struct InMemoryObserver {
    hub: Arc<ObserverHub>,
    /// Blob change hub: delivers put/delete events to incremental replication
    /// sessions via `observe_blobs()`. Mirrors Swift's `InMemoryObserver`
    /// calling `registry.registerBlobs()`.
    blob_hub: Arc<BlobObserverHub>,
}

impl StorageObserver for InMemoryObserver {
    fn observe(
        &self,
        table: &str,
        events: BTreeSet<StorageEvent>,
    ) -> StorageResult<std::sync::mpsc::Receiver<TableChange>> {
        Ok(self.hub.subscribe(table.to_string(), events))
    }

    fn observe_blobs(&self) -> std::sync::mpsc::Receiver<BlobChange> {
        self.blob_hub.subscribe()
    }
}

// ----- Generated column materialization -----

/// Materialize a table's generated columns into a row map. Each
/// expression is evaluated against the row's other values and the
/// integer result is wrapped in the column's declared TypedValue
/// variant. Mirrors what SQLite and PostgreSQL compute in their
/// STORED generated columns, so a query against any backend returns
/// the same materialized value.
fn materialize_generated(generated: &[GeneratedColumn], row: &mut BTreeMap<String, TypedValue>) {
    for gen in generated {
        let raw = gen.expression.evaluate(row);
        let value = match gen.column_type {
            crate::types::ColumnType::Bitmap => TypedValue::Bitmap(raw),
            crate::types::ColumnType::Bool => TypedValue::Bool(raw != 0),
            _ => TypedValue::Int(raw),
        };
        row.insert(gen.name.clone(), value);
    }
}

// ----- Predicate evaluation -----

fn evaluate_predicate(predicate: &StoragePredicate, row: &BTreeMap<String, TypedValue>) -> bool {
    match predicate {
        StoragePredicate::And(preds) => preds.iter().all(|p| evaluate_predicate(p, row)),
        StoragePredicate::Or(preds) => preds.iter().any(|p| evaluate_predicate(p, row)),
        StoragePredicate::Not(inner) => !evaluate_predicate(inner, row),
        StoragePredicate::IsTrue => true,
        StoragePredicate::IsFalse => false,
        StoragePredicate::Eq(col, value) => row.get(&col.name) == Some(value),
        StoragePredicate::Neq(col, value) => row.get(&col.name).is_some_and(|v| v != value),
        StoragePredicate::Lt(col, value) => {
            compare(row.get(&col.name), value, std::cmp::Ordering::Less)
        }
        StoragePredicate::Lte(col, value) => compare_le(row.get(&col.name), value),
        StoragePredicate::Gt(col, value) => {
            compare(row.get(&col.name), value, std::cmp::Ordering::Greater)
        }
        StoragePredicate::Gte(col, value) => compare_ge(row.get(&col.name), value),
        StoragePredicate::IsNull(col) => row
            .get(&col.name)
            .map_or(true, |v| matches!(v, TypedValue::Null)),
        StoragePredicate::IsNotNull(col) => row
            .get(&col.name)
            .is_some_and(|v| !matches!(v, TypedValue::Null)),
        StoragePredicate::In(col, values) => row
            .get(&col.name)
            .is_some_and(|v| values.iter().any(|x| x == v)),
        StoragePredicate::Like(col, pattern) => match row.get(&col.name) {
            Some(TypedValue::Text(s)) => like_match(s, pattern),
            _ => false,
        },
        StoragePredicate::BitmaskAll { column, mask } => match row.get(&column.name) {
            Some(TypedValue::Bitmap(b)) | Some(TypedValue::Int(b)) => (b & mask) == *mask,
            _ => false,
        },
        StoragePredicate::BitmaskAny { column, mask } => match row.get(&column.name) {
            Some(TypedValue::Bitmap(b)) | Some(TypedValue::Int(b)) => (b & mask) != 0,
            _ => false,
        },
        StoragePredicate::BitmaskNone { column, mask } => match row.get(&column.name) {
            Some(TypedValue::Bitmap(b)) | Some(TypedValue::Int(b)) => (b & mask) == 0,
            _ => false,
        },
        StoragePredicate::BitwiseEq {
            column,
            expected,
            mask,
        } => match row.get(&column.name) {
            Some(TypedValue::Bitmap(b)) | Some(TypedValue::Int(b)) => (b & mask) == *expected,
            _ => false,
        },
    }
}

fn compare(actual: Option<&TypedValue>, expected: &TypedValue, target: std::cmp::Ordering) -> bool {
    match actual.and_then(|a| compare_typed_values(a, expected)) {
        Some(ord) => ord == target,
        None => false,
    }
}

fn compare_le(actual: Option<&TypedValue>, expected: &TypedValue) -> bool {
    match actual.and_then(|a| compare_typed_values(a, expected)) {
        Some(ord) => ord != std::cmp::Ordering::Greater,
        None => false,
    }
}

fn compare_ge(actual: Option<&TypedValue>, expected: &TypedValue) -> bool {
    match actual.and_then(|a| compare_typed_values(a, expected)) {
        Some(ord) => ord != std::cmp::Ordering::Less,
        None => false,
    }
}

fn compare_typed_values(a: &TypedValue, b: &TypedValue) -> Option<std::cmp::Ordering> {
    match (a, b) {
        (TypedValue::Int(x), TypedValue::Int(y)) => Some(x.cmp(y)),
        (TypedValue::Bitmap(x), TypedValue::Bitmap(y)) => Some(x.cmp(y)),
        (TypedValue::Float(x), TypedValue::Float(y)) => x.partial_cmp(y),
        (TypedValue::Text(x), TypedValue::Text(y)) => Some(x.cmp(y)),
        (TypedValue::Bool(x), TypedValue::Bool(y)) => Some(x.cmp(y)),
        (TypedValue::Uuid(x), TypedValue::Uuid(y)) => Some(x.as_bytes().cmp(y.as_bytes())),
        (TypedValue::Timestamp(x), TypedValue::Timestamp(y)) => Some(x.cmp(y)),
        (TypedValue::Hlc(x), TypedValue::Hlc(y)) => Some(hlc_cmp(x, y)),
        (TypedValue::Blob(x), TypedValue::Blob(y)) => {
            // Byte-wise lexicographic order — mirrors Swift Data.lexicographicallyPrecedes
            // and SQLite BLOB affinity ordering. Equality predicates (.Eq/.Neq/.In) use
            // TypedValue PartialEq directly (already correct for Blob); these arms
            // additionally enable consistent ordering predicates and sort on blob columns.
            Some(x.cmp(y))
        }
        (TypedValue::Json(x), TypedValue::Json(y)) => {
            // json is pre-encoded bytes; compare byte-wise, same as Blob.
            // Byte identity, not JSON semantic equivalence — mirrors Swift leg.
            Some(x.cmp(y))
        }
        (TypedValue::Fingerprint(x), TypedValue::Fingerprint(y)) => {
            // Block-wise compare in declaration order (block0 … block3 = bits 0–255).
            // Mirrors Swift leg's block-by-block comparison over the same wire layout.
            Some(
                x.block0.cmp(&y.block0)
                    .then(x.block1.cmp(&y.block1))
                    .then(x.block2.cmp(&y.block2))
                    .then(x.block3.cmp(&y.block3)),
            )
        }
        (TypedValue::Array(xs), TypedValue::Array(ys)) => {
            // Element-wise recursive compare; length is the tiebreak.
            // Returns None if any element pair is incomparable (mismatched variants),
            // propagating None upward consistent with the overall comparator contract.
            // Mirrors the Swift leg's array arm.
            for (xe, ye) in xs.iter().zip(ys.iter()) {
                match compare_typed_values(xe, ye) {
                    Some(ord) if ord != std::cmp::Ordering::Equal => return Some(ord),
                    None => return None,
                    _ => {}
                }
            }
            Some(xs.len().cmp(&ys.len()))
        }
        _ => None,
    }
}

fn like_match(s: &str, pattern: &str) -> bool {
    // Simplified LIKE: supports % wildcards only; case-insensitive
    // for ASCII to match SQLite's NOCASE default.
    let s_lower = s.to_lowercase();
    let p_lower = pattern.to_lowercase();
    if p_lower == "%" {
        return true;
    }
    if !p_lower.contains('%') {
        return s_lower == p_lower;
    }
    // Anchor parts.
    let parts: Vec<&str> = p_lower.split('%').collect();
    let mut idx = 0;
    for (i, part) in parts.iter().enumerate() {
        if part.is_empty() {
            continue;
        }
        if i == 0 {
            // First part must match start unless pattern begins with %.
            if !p_lower.starts_with('%') {
                if !s_lower[idx..].starts_with(part) {
                    return false;
                }
                idx += part.len();
                continue;
            }
        }
        if i == parts.len() - 1 && !p_lower.ends_with('%') {
            return s_lower[idx..].ends_with(part);
        }
        match s_lower[idx..].find(part) {
            Some(pos) => idx += pos + part.len(),
            None => return false,
        }
    }
    true
}

// Unused field warning suppression: `Column` is held by predicate
// variants and required for trait bounds; the lint fires falsely.
#[allow(dead_code)]
fn _column_marker(_c: &Column) {}
