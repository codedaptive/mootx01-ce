//! In-memory backend. Mirror of Swift's PersistenceKitInMemory.
//!
//! Stored in a single Mutex<State> for simplicity; the Swift
//! side uses an actor for the same purpose. RowStore, BlobStore,
//! VectorIndex, AuditLog, and StorageObserver views are thin
//! Arc<InMemoryStorage> wrappers that lock the same state.
//!
//! No persistence between process runs; this backend exists for
//! tests and rapid iteration. The SQLite backend (deferred to a
//! follow-on R-mission) shares the same trait surface.

use crate::audit_log::{AuditEvent, AuditLog};
use crate::blob_store::BlobStore;
use crate::error::{StorageError, StorageResult};
use crate::generated_column::GeneratedColumn;
use crate::observer::{ObserverHub, StorageEvent, StorageObserver, TableChange};
use crate::predicate::{OrderClause, OrderDirection, StoragePredicate};
use crate::caching_row_store::CachingRowStore;
use crate::row_store::RowStore;
use crate::schema::{SchemaDeclaration, SchemaOperation, TableDeclaration};
use crate::storage::{
    BackendConfiguration, EstateConfiguration, IsolationLevel, Storage, StorageTransaction,
};
use crate::types::{Column, RowHandle, RowKey, StorageRow, TypedValue};
use crate::vector_index::{
    DistanceMetric, IndexParameters, SearchParameters, VectorIndex, VectorSearchResult,
};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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
    tables: BTreeMap<String, Table>,
    blobs: BTreeMap<String, Vec<u8>>,
    vectors: BTreeMap<RowKey, VectorEntry>,
    audit_events: Vec<AuditEvent>,
}

#[derive(Clone)]
struct Table {
    declaration: TableDeclaration,
    rows: BTreeMap<RowKey, BTreeMap<String, TypedValue>>,
}

#[derive(Clone)]
struct VectorEntry {
    vector: Vec<f32>,
    metadata: BTreeMap<String, TypedValue>,
}

// ----- public storage type -----

pub struct InMemoryStorage {
    configuration: EstateConfiguration,
    state: Arc<Mutex<State>>,
    hub: Arc<ObserverHub>,
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
        })
    }

    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Arc::new(InMemoryVectorIndex {
            state: self.state.clone(),
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
        })
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        let mut state = self.state.lock().unwrap();
        if state.schema_version < schema.version {
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

    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        let mut state = self.state.lock().unwrap();
        apply_migrations_inner(&mut state, schema)
    }

    fn transaction(
        &self,
        _isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        // No native transaction: snapshot the whole state and restore it if
        // the block rolls back. (Single-threaded transaction semantics.)
        let snapshot = self.state.lock().unwrap().clone();
        match block(self) {
            Ok(()) => Ok(()),
            Err(e) => {
                *self.state.lock().unwrap() = snapshot;
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
    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Storage::vector_index(self)
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Storage::audit_log(self)
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
    // Apply migrations in order.
    let mut pending: Vec<_> = schema
        .migrations
        .iter()
        .filter(|m| m.from_version >= state.schema_version && m.to_version <= schema.version)
        .cloned()
        .collect();
    pending.sort_by_key(|m| m.from_version);
    for migration in pending {
        for op in migration.operations {
            apply_operation(state, op)?;
        }
        state.schema_version = migration.to_version;
    }
    if state.schema_version < schema.version {
        state.schema_version = schema.version;
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
    fn resolve_key(table: &Table, values: &BTreeMap<String, TypedValue>) -> RowKey {
        if table.declaration.primary_key.len() == 1 {
            let pk = &table.declaration.primary_key[0];
            if let Some(TypedValue::Uuid(u)) = values.get(pk) {
                return *u;
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
        let (key, stored) = {
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
            (key, stored)
        };
        self.hub.emit(TableChange {
            table: table.to_string(),
            event: StorageEvent::Insert,
            row_key: Some(key),
            values: Some(stored),
            hlc: None,
        });
        Ok(RowHandle::new(table, key))
    }

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle> {
        let (key, event, emitted_values) = {
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
            if let Some(k) = existing_key {
                let row = t.rows.get_mut(&k).unwrap();
                for (col, v) in values.into_iter() {
                    row.insert(col, v);
                }
                materialize_generated(&generated, row);
                let merged = row.clone();
                (k, StorageEvent::Update, merged)
            } else {
                let key = Self::resolve_key(t, &values);
                let mut stored = values;
                materialize_generated(&generated, &mut stored);
                t.rows.insert(key, stored.clone());
                (key, StorageEvent::Insert, stored)
            }
        };
        self.hub.emit(TableChange {
            table: table.to_string(),
            event,
            row_key: Some(key),
            values: Some(emitted_values),
            hlc: None,
        });
        Ok(RowHandle::new(table, key))
    }

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize> {
        let mut notifications: Vec<(RowKey, BTreeMap<String, TypedValue>)> = Vec::new();
        let count = {
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
                for (col, v) in values.iter() {
                    row.insert(col.clone(), v.clone());
                }
                materialize_generated(&generated, row);
                notifications.push((k, row.clone()));
                count += 1;
            }
            count
        };
        for (key, row) in notifications {
            self.hub.emit(TableChange {
                table: table.to_string(),
                event: StorageEvent::Update,
                row_key: Some(key),
                values: Some(row),
                hlc: None,
            });
        }
        Ok(count)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let mut notifications: Vec<(RowKey, BTreeMap<String, TypedValue>)> = Vec::new();
        let count = {
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
            matching.len()
        };
        for (key, row) in notifications {
            self.hub.emit(TableChange {
                table: table.to_string(),
                event: StorageEvent::Delete,
                row_key: Some(key),
                values: Some(row),
                hlc: None,
            });
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
}

impl BlobStore for InMemoryBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        self.state
            .lock()
            .unwrap()
            .blobs
            .insert(key.to_string(), bytes.to_vec());
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        Ok(self.state.lock().unwrap().blobs.get(key).cloned())
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        self.state.lock().unwrap().blobs.remove(key);
        Ok(())
    }
    fn exists(&self, key: &str) -> StorageResult<bool> {
        Ok(self.state.lock().unwrap().blobs.contains_key(key))
    }
    fn size(&self, key: &str) -> StorageResult<Option<usize>> {
        Ok(self.state.lock().unwrap().blobs.get(key).map(|b| b.len()))
    }
}

// ----- VectorIndex -----

struct InMemoryVectorIndex {
    state: Arc<Mutex<State>>,
}

impl VectorIndex for InMemoryVectorIndex {
    fn add(
        &self,
        key: RowKey,
        vector: &[f32],
        metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()> {
        self.state.lock().unwrap().vectors.insert(
            key,
            VectorEntry {
                vector: vector.to_vec(),
                metadata,
            },
        );
        Ok(())
    }

    fn update(
        &self,
        key: RowKey,
        vector: &[f32],
        metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()> {
        self.add(key, vector, metadata)
    }

    fn delete(&self, key: RowKey) -> StorageResult<()> {
        self.state.lock().unwrap().vectors.remove(&key);
        Ok(())
    }

    fn knn(
        &self,
        query: &[f32],
        k: usize,
        metric: DistanceMetric,
        _filter: Option<&StoragePredicate>,
        _search_parameters: Option<SearchParameters>,
    ) -> StorageResult<Vec<VectorSearchResult>> {
        let state = self.state.lock().unwrap();
        let mut scored: Vec<VectorSearchResult> = state
            .vectors
            .iter()
            .map(|(key, entry)| {
                let distance = compute_distance(query, &entry.vector, metric);
                VectorSearchResult {
                    key: *key,
                    distance,
                    metadata: entry.metadata.clone(),
                }
            })
            .collect();
        scored.sort_by(|a, b| {
            a.distance
                .partial_cmp(&b.distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        scored.truncate(k);
        Ok(scored)
    }

    fn reindex(&self, _parameters: IndexParameters) -> StorageResult<()> {
        Ok(())
    }

    fn count(&self) -> StorageResult<usize> {
        Ok(self.state.lock().unwrap().vectors.len())
    }
}

fn compute_distance(a: &[f32], b: &[f32], metric: DistanceMetric) -> f32 {
    match metric {
        DistanceMetric::L2 => {
            let mut sum = 0.0_f32;
            for i in 0..a.len().min(b.len()) {
                let d = a[i] - b[i];
                sum += d * d;
            }
            sum.sqrt()
        }
        DistanceMetric::Dot => {
            let mut sum = 0.0_f32;
            for i in 0..a.len().min(b.len()) {
                sum += a[i] * b[i];
            }
            -sum // smaller = closer; negate so larger dot products win
        }
        DistanceMetric::Cosine => {
            let mut dot = 0.0_f32;
            let mut norm_a = 0.0_f32;
            let mut norm_b = 0.0_f32;
            for i in 0..a.len().min(b.len()) {
                dot += a[i] * b[i];
                norm_a += a[i] * a[i];
                norm_b += b[i] * b[i];
            }
            let denom = norm_a.sqrt() * norm_b.sqrt();
            if denom < f32::EPSILON {
                1.0
            } else {
                1.0 - dot / denom
            }
        }
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
}

impl StorageObserver for InMemoryObserver {
    fn observe(
        &self,
        table: &str,
        events: BTreeSet<StorageEvent>,
    ) -> StorageResult<std::sync::mpsc::Receiver<TableChange>> {
        Ok(self.hub.subscribe(table.to_string(), events))
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
