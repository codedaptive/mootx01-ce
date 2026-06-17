//! Incremental replication dirty-set (§6).
//!
//! Mirrors Swift's `IncrementalReplicationSession` in PersistenceKitReplication.
//!
//! DESIGN CHOICE — watermark + re-scan (not a durable dirty table):
//!
//!   Two approaches exist:
//!   A) Durable dirty table: write (table, pk) to a separate table on each observer
//!      event; drain on sync; delete drained rows.
//!   B) In-memory accumulation + watermark: accumulate (table, pkValues) in a
//!      Mutex-guarded set while the session is alive; re-scan dirty rows from the
//!      source on sync; persist only the HLC watermark in the cursor.
//!
//!   We chose (B) for three reasons:
//!   1. The cursor already carries an HLC watermark; extending it to own the
//!      dirty-set is a natural fit and requires no new schema.
//!   2. A durable dirty table would bind this module to a specific backend schema,
//!      violating the module's backend-agnostic design.
//!   3. Re-read on sync is O(dirty count) — cheap.
//!
//!   RESTART SEMANTICS: the dirty-set is in-memory. On process restart, the
//!   caller falls back to a full snapshot. Correct: full snapshot is always a
//!   valid substitute.
//!
//! FAIL-LOUD CONTRACT:
//!   A StorageError encountered during a dirty-row read aborts the entire sync
//!   run immediately with the error surfaced. No partial destination state is
//!   committed — the destination transaction rolls back. Skipping corrupt rows
//!   would silently poison the destination. See §15 fail-loud read-back.
//!
//! RUST NOTES:
//!   Swift uses AsyncStream for the observer channel; Rust uses
//!   `std::sync::mpsc::Receiver<TableChange>`. The session drains the channel
//!   via `try_recv` in a non-blocking loop before each sync run, accumulating
//!   all pending changes into the dirty-set. This is the synchronous equivalent
//!   of Swift's `for await change in stream { ... }` task.

use crate::audit_log::AuditEvent;
use crate::blob_store::BlobKey;
// StorageError and StorageResult are used transitively via ReplicationError::from.
use crate::observer::{BlobChange, BlobEvent, StorageEvent, TableChange};
use crate::predicate::StoragePredicate;
use crate::replication::{ReplicationCursor, ReplicationError};
use crate::schema::SchemaDeclaration;
use crate::storage::{IsolationLevel, Storage};
use crate::types::{Column, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::Receiver;
use std::sync::Mutex;
use substrate_types::hlc::HLC;

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

// MARK: - DirtyKey

/// A (table, primary-key-values) pair that identifies exactly one row.
/// Ordering is (table, pk_encoded) — deterministic sync ordering.
///
/// Manual PartialOrd/Ord/Hash/PartialEq/Eq impls use only (table, pk_encoded)
/// because TypedValue does not implement Ord/Hash. pk_values is carried for the
/// re-scan predicate and is logically redundant with pk_encoded.
#[derive(Debug, Clone)]
pub struct DirtyKey {
    pub table: String,
    /// Canonically encoded PK: "col1=Debug(val1),col2=Debug(val2)" in column-name order.
    /// Stable equality and ordering; not human-readable but deterministic.
    pub pk_encoded: String,
    /// Raw PK column values for the re-scan predicate.
    pub pk_values: BTreeMap<String, TypedValue>,
}

impl PartialEq for DirtyKey {
    fn eq(&self, other: &Self) -> bool {
        self.table == other.table && self.pk_encoded == other.pk_encoded
    }
}

impl Eq for DirtyKey {}

impl std::hash::Hash for DirtyKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.table.hash(state);
        self.pk_encoded.hash(state);
    }
}

impl PartialOrd for DirtyKey {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for DirtyKey {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (&self.table, &self.pk_encoded).cmp(&(&other.table, &other.pk_encoded))
    }
}

impl DirtyKey {
    /// Construct a DirtyKey from the table name and PK column values.
    pub fn new(table: impl Into<String>, pk_values: BTreeMap<String, TypedValue>) -> Self {
        let table = table.into();
        let pk_encoded = pk_values
            .iter()
            .map(|(k, v)| format!("{}={:?}", k, v))
            .collect::<Vec<_>>()
            .join(",");
        DirtyKey {
            table,
            pk_encoded,
            pk_values,
        }
    }
}

// MARK: - DirtySet

/// Thread-safe accumulator for dirty (table, pk) pairs.
///
/// Populated by the observer-consumer thread via `accumulate`; drained
/// before each sync run via `drain`.
pub struct DirtySet {
    entries: Mutex<BTreeSet<DirtyKey>>,
    /// Primary-key column names per table, from the schema at session start.
    primary_keys: BTreeMap<String, Vec<String>>,
}

impl DirtySet {
    pub fn new(schema: &SchemaDeclaration) -> Self {
        let primary_keys = schema
            .tables
            .iter()
            .map(|t| (t.name.clone(), t.primary_key.clone()))
            .collect();
        DirtySet {
            entries: Mutex::new(BTreeSet::new()),
            primary_keys,
        }
    }

    /// Record a change for replication.
    ///
    /// Inserts and updates both dirty the row. Deletes are recorded as a
    /// tombstone sentinel (same DirtyKey) — the sync path issues a delete
    /// on the destination for the given PK when the re-scan finds no row.
    ///
    /// If the TableChange's values dict does not contain all PK columns,
    /// the change is silently skipped (defensive; a conforming backend always
    /// emits the PK columns).
    pub fn accumulate(&self, change: &TableChange) {
        let pk_cols = match self.primary_keys.get(&change.table) {
            Some(cols) => cols,
            None => return, // table not in schema, skip
        };
        let values = match &change.values {
            Some(v) => v,
            None => return, // no values, cannot extract PK
        };
        let mut pk_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        for col in pk_cols {
            match values.get(col) {
                Some(v) => { pk_values.insert(col.clone(), v.clone()); }
                None => return, // PK column missing, skip
            }
        }
        let key = DirtyKey::new(change.table.clone(), pk_values);
        self.entries.lock().unwrap().insert(key);
    }

    /// Drain all accumulated dirty keys sorted for deterministic ordering.
    /// The dirty-set is cleared atomically.
    pub fn drain(&self) -> Vec<DirtyKey> {
        let mut guard = self.entries.lock().unwrap();
        let drained: Vec<DirtyKey> = guard.iter().cloned().collect();
        guard.clear();
        drained
    }

    /// Restore previously-drained keys into the dirty-set after a failed sync run.
    ///
    /// RETRY-PRESERVATION CONTRACT: when sync aborts after a drain, the caller
    /// restores the drained keys so a subsequent retry re-attempts the same rows.
    ///
    /// Union semantics: keys dirtied DURING the failed run (accumulated between
    /// the drain and the restore call) are preserved unchanged. `BTreeSet::insert`
    /// is a no-op when the element already exists, so newer dirt for the same row
    /// is never overwritten by a stale restored key. This is correct: the newer
    /// event subsumes the restored one, and retrying with it is safe and sufficient.
    pub fn restore(&self, keys: &[DirtyKey]) {
        let mut guard = self.entries.lock().unwrap();
        for key in keys {
            guard.insert(key.clone());
        }
    }

    /// Current count — for tests.
    pub fn count(&self) -> usize {
        self.entries.lock().unwrap().len()
    }
}

// MARK: - BlobDirtyAccumulator

/// Thread-safe accumulator for dirty blob keys with last-write-wins semantics.
///
/// Mirrors Swift's `BlobDirtySet` actor. Populated via `accumulate` when the
/// observer channel delivers a `BlobChange`; drained before each sync run via
/// `drain`.
///
/// LAST-WRITE-WINS: a subsequent `Put` for the same key replaces an earlier
/// `Put` or `Delete`. A `Delete` after a `Put` for the same key records the
/// deletion — the destination will delete it on next sync.
///
/// `entries` is a BTreeMap keyed on BlobKey for deterministic drain ordering.
pub struct BlobDirtyAccumulator {
    entries: Mutex<BTreeMap<BlobKey, BlobDirtyEntry>>,
}

/// One entry in the blob dirty accumulator.
#[derive(Clone)]
pub(crate) struct BlobDirtyEntry {
    pub event: BlobEvent,
    /// Payload for Put events; None for Delete events.
    pub bytes: Option<Vec<u8>>,
}

impl BlobDirtyAccumulator {
    pub fn new() -> Self {
        BlobDirtyAccumulator {
            entries: Mutex::new(BTreeMap::new()),
        }
    }

    /// Record a blob change. Last-write-wins: a later event for the same key
    /// always replaces the earlier one.
    pub fn accumulate(&self, change: &BlobChange) {
        let mut guard = self.entries.lock().unwrap();
        guard.insert(change.key.clone(), BlobDirtyEntry {
            event: change.event,
            bytes: change.bytes.clone(),
        });
    }

    /// Drain all accumulated entries. The accumulator is cleared atomically.
    /// Returns entries in sorted key order for deterministic sync ordering.
    pub(crate) fn drain(&self) -> Vec<(BlobKey, BlobDirtyEntry)> {
        let mut guard = self.entries.lock().unwrap();
        let drained: Vec<(BlobKey, BlobDirtyEntry)> = guard
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        guard.clear();
        drained
    }

    /// Restore previously-drained entries after a failed sync run.
    ///
    /// RETRY-PRESERVATION: union semantics — keys dirtied DURING the failed run
    /// (already in the accumulator) are never overwritten by stale restored entries.
    /// Only entries whose key is NOT yet in the accumulator are inserted.
    pub(crate) fn restore(&self, entries: &[(BlobKey, BlobDirtyEntry)]) {
        let mut guard = self.entries.lock().unwrap();
        for (key, entry) in entries {
            guard.entry(key.clone()).or_insert_with(|| entry.clone());
        }
    }

    /// Current count — for tests.
    pub fn count(&self) -> usize {
        self.entries.lock().unwrap().len()
    }

    /// Insert a Put entry with nil bytes directly into the accumulator.
    ///
    /// Used only in tests to trigger the fail-loud nil-bytes path in
    /// `sync()` without going through the observer channel.
    /// The production `accumulate()` API always carries real bytes for
    /// Put events, so this path is unreachable from non-test code.
    #[cfg(test)]
    pub(crate) fn inject_nil_bytes_put(&self, key: BlobKey) {
        let mut guard = self.entries.lock().unwrap();
        guard.insert(key, BlobDirtyEntry { event: BlobEvent::Put, bytes: None });
    }
}

// MARK: - IncrementalReplicationSession

/// An active incremental replication session for one source storage.
///
/// Lifecycle:
///   1. Create with `IncrementalReplicationSession::start`.
///   2. Keep alive while the process is running.
///   3. Call `sync` to push dirty rows to a destination.
///   4. Drop to release observer channel.
///
/// The session holds a `Receiver<TableChange>` per table. Before each sync
/// run, `drain_channels()` pulls all pending messages from every channel into
/// the DirtySet. This is the synchronous parity of Swift's async stream task.
///
/// Thread safety: `IncrementalReplicationSession` is `Send + Sync` because
/// all mutable state lives inside `Mutex`-guarded fields (`DirtySet.entries`,
/// `channels`).
pub struct IncrementalReplicationSession {
    pub dirty_set: DirtySet,
    /// Blob dirty accumulator: receives put/delete events from the blob observer.
    pub blob_dirty: BlobDirtyAccumulator,
    schema: SchemaDeclaration,
    /// One channel receiver per table subscribed via `observer.observe`.
    channels: Mutex<Vec<Receiver<TableChange>>>,
    /// Channel receiver for blob changes from `observer.observe_blobs()`.
    blob_channel: Mutex<Receiver<BlobChange>>,
}

impl IncrementalReplicationSession {
    // MARK: - Factory

    /// Start an incremental replication session on `source`.
    ///
    /// Subscribes to all schema-declared tables for insert, update, and delete
    /// events, and to blob events via `observe_blobs()`. Changes are accumulated
    /// in the session's DirtySet/BlobDirtyAccumulator until
    /// `sync(source, destination, from_cursor)` is called.
    pub fn start(source: &dyn Storage, schema: &SchemaDeclaration) -> Self {
        let dirty = DirtySet::new(schema);
        let mut channels: Vec<Receiver<TableChange>> = Vec::new();

        let observer = source.observer();
        for table in &schema.tables {
            let mut events = BTreeSet::new();
            events.insert(StorageEvent::Insert);
            events.insert(StorageEvent::Update);
            events.insert(StorageEvent::Delete);
            if let Ok(rx) = observer.observe(&table.name, events) {
                channels.push(rx);
            }
        }

        // Subscribe to blob changes. observe_blobs() returns a disconnected
        // receiver for backends that don't support blob observation (e.g. SQLite,
        // NoOp). In that case drain_blob_channel() produces no events, which is
        // correct — full-snapshot handles those backends on restart.
        let blob_rx = observer.observe_blobs();

        IncrementalReplicationSession {
            dirty_set: dirty,
            blob_dirty: BlobDirtyAccumulator::new(),
            schema: schema.clone(),
            channels: Mutex::new(channels),
            blob_channel: Mutex::new(blob_rx),
        }
    }

    // MARK: - Channel drain

    /// Pull all pending TableChange messages from every subscribed channel into
    /// the DirtySet. Channels return `TryRecvError::Empty` when no messages are
    /// pending (normal) and `TryRecvError::Disconnected` when the sender is gone
    /// (storage closed — silently ignore, the session is torn down soon).
    pub fn drain_channels(&self) {
        use std::sync::mpsc::TryRecvError;
        let channels = self.channels.lock().unwrap();
        for rx in channels.iter() {
            loop {
                match rx.try_recv() {
                    Ok(change) => self.dirty_set.accumulate(&change),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => break,
                }
            }
        }
    }

    /// Pull all pending BlobChange messages from the blob channel into the
    /// BlobDirtyAccumulator. Disconnected receiver (SQLite, NoOp backends) is
    /// silently ignored — those backends rely on full-snapshot on restart.
    pub fn drain_blob_channel(&self) {
        use std::sync::mpsc::TryRecvError;
        let rx = self.blob_channel.lock().unwrap();
        loop {
            match rx.try_recv() {
                Ok(change) => self.blob_dirty.accumulate(&change),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }
    }

    // MARK: - Sync

    /// Replicate all dirty rows to `destination`.
    ///
    /// Drains the observer channels, then drains the dirty-set, reads each
    /// dirty row from `source`, and upserts (or deletes) it into `destination`
    /// inside a single serializable transaction.
    ///
    /// FAIL-LOUD: if any dirty row read encounters a StorageError (including
    /// corruptStoredValue), the error is wrapped in `ReplicationError::StorageFailure`
    /// and returned immediately. The destination transaction rolls back, leaving
    /// it in its last clean state. No partial state is committed.
    ///
    /// RETRY-PRESERVATION: if sync returns an error after the dirty-set is drained,
    /// the drained keys are restored before the error is returned. A subsequent
    /// retry will re-attempt the same rows. Keys dirtied DURING the failed run are
    /// preserved alongside the restored keys (union, no overwrite of newer dirt for
    /// the same row). This ensures no row silently escapes replication after a
    /// transient failure or a corrupt-value abort.
    ///
    /// DETERMINISTIC ORDERING: dirty keys are sorted (table, pk_encoded) before
    /// processing, producing the same upsert order for the same dirty-set across runs.
    ///
    /// AUDIT EVENTS: only events with HLC strictly after `from_cursor.hlc_watermark`
    /// are copied (`audit_log.iterate(after=watermark)` — exclusive lower bound).
    ///
    /// - `source`: Source storage to read dirty rows from.
    /// - `destination`: Storage to write dirty rows to.
    /// - `from_cursor`: Watermark from the previous sync run. Pass a zero-watermark
    ///   cursor for the first incremental sync.
    /// - Returns: Updated `ReplicationCursor` with new watermark.
    pub fn sync(
        &self,
        source: &dyn Storage,
        destination: &dyn Storage,
        from_cursor: ReplicationCursor,
    ) -> Result<ReplicationCursor, ReplicationError> {
        // Schema gate: both backends must be at the same schema version.
        let src_version = source
            .current_schema_version()
            .map_err(ReplicationError::from)?;
        let dst_version = destination
            .current_schema_version()
            .map_err(ReplicationError::from)?;
        if src_version != dst_version || src_version != self.schema.version {
            return Err(ReplicationError::SchemaMismatch {
                source_version: src_version,
                destination_version: dst_version,
                kit_id: self.schema.kit_id.clone(),
            });
        }

        // Pull pending observer messages into the dirty-set and blob accumulator.
        self.drain_channels();
        self.drain_blob_channel();

        // Drain the dirty-set and blob accumulator. Sorted for deterministic ordering.
        // RETRY-PRESERVATION: we capture the drained keys before any fallible work.
        // Both dirty_keys and dirty_blobs are restored on every error path so the
        // next retry re-attempts the same rows and blobs.
        let dirty_keys = self.dirty_set.drain();
        let dirty_blobs = self.blob_dirty.drain();

        if dirty_keys.is_empty() && dirty_blobs.is_empty() {
            // Nothing dirty — return the cursor unchanged.
            return Ok(from_cursor);
        }

        // Build a per-table index for PK columns and generated column names.
        let table_index: BTreeMap<&str, &crate::schema::TableDeclaration> = self
            .schema
            .tables
            .iter()
            .map(|t| (t.name.as_str(), t))
            .collect();

        // Snapshot dirty rows from source BEFORE opening the destination transaction.
        // On error: restore drained keys (and blobs) before propagating so retry sees them.
        let payload = self.snapshot_dirty_rows(source, &dirty_keys, &table_index, &from_cursor)
            .map_err(|e| {
                self.dirty_set.restore(&dirty_keys);
                self.blob_dirty.restore(&dirty_blobs);
                e
            })?;

        // Write destination inside a serializable transaction.
        let mut rows_written: usize = 0;
        let mut deletes_written: usize = 0;
        let mut audit_events_written: usize = 0;
        let mut blobs_written: usize = 0;
        let mut max_hlc: Option<HLC> = from_cursor.hlc_watermark;

        let payload_ref = &payload;
        let dirty_blobs_ref = &dirty_blobs;
        let rows_written_ref = &mut rows_written;
        let deletes_written_ref = &mut deletes_written;
        let audit_events_written_ref = &mut audit_events_written;
        let blobs_written_ref = &mut blobs_written;
        let max_hlc_ref = &mut max_hlc;

        // On transaction error: restore drained keys AND blob ops so retry re-attempts them.
        destination
            .transaction(IsolationLevel::Serializable, &mut |txn| {
                let row_store = txn.row_store();
                let audit_log = txn.audit_log();
                let blob_store = txn.blob_store();

                // 1. Row upserts and deletes.
                for op in &payload_ref.row_ops {
                    match op {
                        RowOp::Upsert { table, primary_key, values } => {
                            // Track HLC values from row columns for watermark.
                            for value in values.values() {
                                if let TypedValue::Hlc(h) = value {
                                    match *max_hlc_ref {
                                        None => *max_hlc_ref = Some(*h),
                                        Some(ref current) if h > current => {
                                            *max_hlc_ref = Some(*h)
                                        }
                                        _ => {}
                                    }
                                }
                            }
                            row_store.upsert(table, values.clone(), primary_key)?;
                            *rows_written_ref += 1;
                        }
                        RowOp::Delete { table, predicate } => {
                            row_store.delete(table, predicate)?;
                            *deletes_written_ref += 1;
                        }
                    }
                }

                // 2. Audit events after the previous watermark.
                if !payload_ref.audit_events.is_empty() {
                    audit_log.append_batch(payload_ref.audit_events.clone())?;
                    *audit_events_written_ref = payload_ref.audit_events.len();
                    for event in &payload_ref.audit_events {
                        match *max_hlc_ref {
                            None => *max_hlc_ref = Some(event.hlc),
                            Some(ref current) if &event.hlc > current => {
                                *max_hlc_ref = Some(event.hlc)
                            }
                            _ => {}
                        }
                    }
                }

                // 3. Blob ops from the BlobDirtyAccumulator.
                // Put: write the captured bytes to the destination (fail-loud if bytes
                // are None — that would be a programmer error, not a runtime condition,
                // since accumulate always stores bytes for Put events).
                // Delete: remove the blob from the destination.
                for (key, entry) in dirty_blobs_ref {
                    match entry.event {
                        BlobEvent::Put => {
                            let bytes = entry.bytes.as_deref().ok_or_else(|| {
                                // BlobDirtyAccumulator invariant: a Put entry always
                                // carries bytes. A None here indicates a corrupt
                                // in-memory accumulator state.
                                crate::error::StorageError::BackendError {
                                    underlying: format!(
                                        "BlobDirtyAccumulator Put for key '{}' has no bytes",
                                        key
                                    ),
                                }
                            })?;
                            blob_store.put(key, bytes)?;
                            *blobs_written_ref += 1;
                        }
                        BlobEvent::Delete => {
                            blob_store.delete(key)?;
                            *blobs_written_ref += 1;
                        }
                    }
                }

                Ok(())
            })
            .map_err(|e| {
                // Transaction rolled back — restore drained keys AND blob ops so
                // retry re-attempts all of them.
                self.dirty_set.restore(&dirty_keys);
                self.blob_dirty.restore(&dirty_blobs);
                ReplicationError::from(e)
            })?;

        Ok(ReplicationCursor {
            hlc_watermark: max_hlc,
            rows_written: rows_written + deletes_written,
            audit_events_written,
            blobs_written,
        })
    }

    // MARK: - Dirty-row snapshot

    /// Snapshot dirty rows from source before opening the destination transaction.
    /// Errors during read surface immediately (fail-loud) — no row is skipped.
    fn snapshot_dirty_rows(
        &self,
        source: &dyn Storage,
        dirty_keys: &[DirtyKey],
        table_index: &BTreeMap<&str, &crate::schema::TableDeclaration>,
        from_cursor: &ReplicationCursor,
    ) -> Result<IncrementalPayload, ReplicationError> {
        let row_store = source.row_store();
        let audit_log = source.audit_log();
        let mut row_ops: Vec<RowOp> = Vec::new();

        for key in dirty_keys {
            let table_decl = match table_index.get(key.table.as_str()) {
                Some(t) => t,
                None => continue, // Table not in schema.
            };
            let generated_names: BTreeSet<String> = table_decl
                .generated_columns
                .iter()
                .map(|g| g.name.clone())
                .collect();

            let predicate = pk_predicate(&key.pk_values, &key.table);

            // Query the source for this specific row. StorageError (including
            // corruptStoredValue) surfaces immediately — fail-loud.
            let rows = row_store
                .query(&key.table, Some(&predicate), &[], None, None)
                .map_err(ReplicationError::from)?;

            if rows.is_empty() {
                // Row was deleted in source between observer event and re-scan.
                // Issue a delete on the destination.
                row_ops.push(RowOp::Delete {
                    table: key.table.clone(),
                    predicate,
                });
            } else {
                // Filter generated columns before staging for upsert.
                let filtered: BTreeMap<String, TypedValue> = rows[0]
                    .values
                    .iter()
                    .filter(|(k, _)| !generated_names.contains(*k))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                row_ops.push(RowOp::Upsert {
                    table: key.table.clone(),
                    primary_key: table_decl.primary_key.clone(),
                    values: filtered,
                });
            }
        }

        // Audit events after the previous watermark. iterate(after=watermark) is
        // an exclusive lower bound — events at or before the watermark were already
        // delivered in a previous sync run.
        // iterate(after) is an exclusive lower bound (HLC > watermark).
        // Pass the watermark directly; HLC is Copy.
        let audit_events = audit_log
            .iterate(from_cursor.hlc_watermark, None, usize::MAX)
            .map_err(ReplicationError::from)?;

        Ok(IncrementalPayload { row_ops, audit_events })
    }
}

// MARK: - Predicate builder

/// Build a predicate selecting a row by its exact primary-key values.
/// Multiple PK columns are combined with And.
fn pk_predicate(pk_values: &BTreeMap<String, TypedValue>, table: &str) -> StoragePredicate {
    let clauses: Vec<StoragePredicate> = pk_values
        .iter()
        .map(|(col, val)| {
            StoragePredicate::Eq(
                Column::new(table.to_string(), col.clone()),
                val.clone(),
            )
        })
        .collect();

    match clauses.len() {
        0 => StoragePredicate::IsTrue,
        1 => clauses.into_iter().next().unwrap(),
        _ => StoragePredicate::And(clauses),
    }
}

// MARK: - Internal types

/// A row operation to apply during the incremental sync transaction.
enum RowOp {
    Upsert {
        table: String,
        primary_key: Vec<String>,
        values: BTreeMap<String, TypedValue>,
    },
    Delete {
        table: String,
        predicate: StoragePredicate,
    },
}

/// Payload holding dirty-row operations and new audit events.
struct IncrementalPayload {
    row_ops: Vec<RowOp>,
    audit_events: Vec<AuditEvent>,
}

// MARK: - Tests

#[cfg(test)]
mod incremental_replication_tests {
    use super::*;
    use crate::generated_column::{GeneratedColumn, GeneratedExpression};
    use crate::inmemory::InMemoryStorage;
    use crate::replication;
    use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    use crate::types::{ColumnType, TypedValue};
    // BackendConfiguration and EstateConfiguration used transitively by make_storage.
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    // ── Synthetic schema ────────────────────────────────────────────────

    fn synthetic_schema() -> SchemaDeclaration {
        let items_table = TableDeclaration {
            name: "items".into(),
            columns: vec![
                ColumnDeclaration { name: "id".into(), column_type: ColumnType::Uuid, nullable: false, default_value: None },
                ColumnDeclaration { name: "adjective_bitmap".into(), column_type: ColumnType::Bitmap, nullable: false, default_value: None },
                ColumnDeclaration { name: "payload".into(), column_type: ColumnType::Blob, nullable: false, default_value: None },
                ColumnDeclaration { name: "tombstoned_at".into(), column_type: ColumnType::Timestamp, nullable: true, default_value: None },
            ],
            primary_key: vec!["id".into()],
            unique_constraints: vec![],
            generated_columns: vec![GeneratedColumn {
                name: "state_cluster".into(),
                column_type: ColumnType::Int,
                expression: GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("adjective_bitmap".into())),
                    Box::new(GeneratedExpression::Literal(0xF)),
                ),
            }],
            append_only: false,
        };

        let events_table = TableDeclaration {
            name: "events".into(),
            columns: vec![
                ColumnDeclaration { name: "topic_id".into(), column_type: ColumnType::Uuid, nullable: false, default_value: None },
                ColumnDeclaration { name: "seq".into(), column_type: ColumnType::Int, nullable: false, default_value: None },
                ColumnDeclaration { name: "hlc_stamp".into(), column_type: ColumnType::Hlc, nullable: false, default_value: None },
                ColumnDeclaration { name: "content".into(), column_type: ColumnType::Text, nullable: false, default_value: None },
            ],
            primary_key: vec!["topic_id".into(), "seq".into()],
            unique_constraints: vec![],
            generated_columns: vec![],
            append_only: true,
        };

        SchemaDeclaration {
            kit_id: "RustIncrementalTestKit".into(),
            version: 1,
            tables: vec![items_table, events_table],
            indices: vec![],
            migrations: vec![],
        }
    }

    fn make_storage(schema: &SchemaDeclaration) -> InMemoryStorage {
        let storage = InMemoryStorage::with_estate(Uuid::new_v4());
        storage.open(schema).expect("open failed");
        storage
    }

    fn item_row(id: Uuid, bitmap: i64) -> BTreeMap<String, TypedValue> {
        let mut m = BTreeMap::new();
        m.insert("id".into(), TypedValue::Uuid(id));
        m.insert("adjective_bitmap".into(), TypedValue::Bitmap(bitmap));
        m.insert("payload".into(), TypedValue::Blob(vec![0xDE, 0xAD]));
        m.insert("tombstoned_at".into(), TypedValue::Null);
        m
    }

    fn event_row(topic_id: Uuid, seq: i64, hlc: HLC) -> BTreeMap<String, TypedValue> {
        let mut m = BTreeMap::new();
        m.insert("topic_id".into(), TypedValue::Uuid(topic_id));
        m.insert("seq".into(), TypedValue::Int(seq));
        m.insert("hlc_stamp".into(), TypedValue::Hlc(hlc));
        m.insert("content".into(), TypedValue::Text("test".into()));
        m
    }

    // ── §10.1 Only dirty rows replicated ─────────────────────────────────

    /// §10.1 — Write 100 rows to source (no session), full-flush baseline to
    /// destination, start session, update 3 rows → only 3 replicated.
    #[test]
    fn only_dirty_rows_replicated() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert 100 rows — session not started yet, so these won't dirty.
        let mut all_ids: Vec<Uuid> = Vec::new();
        for _ in 0..100 {
            let id = Uuid::new_v4();
            all_ids.push(id);
            source.row_store()
                .upsert("items", item_row(id, 0b0101), &["id".to_string()])
                .expect("upsert failed");
        }

        // Full-flush baseline.
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 100, "Baseline should copy 100 rows");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update exactly 3 rows — these 3 become dirty.
        let dirty_ids: Vec<Uuid> = all_ids[..3].to_vec();
        for &id in &dirty_ids {
            source.row_store()
                .upsert("items", item_row(id, 0b1111), &["id".to_string()])
                .expect("upsert dirty failed");
        }

        // Drain channels: pull the 3 update events from the observer.
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 3, "Should have exactly 3 dirty rows");

        // Incremental sync.
        let inc_cursor = session.sync(&source, &destination, full_cursor.clone())
            .expect("incremental sync failed");
        assert_eq!(inc_cursor.rows_written, 3, "Incremental sync should write only 3 dirty rows");

        // Destination must still have 100 rows.
        let dst_count = destination.row_store().count("items", None).expect("count failed");
        assert_eq!(dst_count, 100, "Destination must still have 100 rows");

        // The 3 dirty rows must have updated bitmap value.
        for &id in &dirty_ids {
            let predicate = StoragePredicate::Eq(
                Column::new("items", "id"),
                TypedValue::Uuid(id),
            );
            let rows = destination.row_store()
                .query("items", Some(&predicate), &[], None, None)
                .expect("query failed");
            assert_eq!(rows.len(), 1);
            assert_eq!(
                rows[0].values.get("adjective_bitmap"),
                Some(&TypedValue::Bitmap(0b1111)),
                "Dirty row should have updated bitmap"
            );
        }
    }

    // ── §10.2 Delete propagation ──────────────────────────────────────────

    /// §10.2 — Delete a row on source → destination deletes it on next sync.
    #[test]
    fn delete_propagation() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert one row, full-flush baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0101), &["id".to_string()])
            .expect("upsert failed");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 1);

        // Start session.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Delete the row from source.
        let del_pred = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Uuid(row_id),
        );
        source.row_store().delete("items", &del_pred).expect("delete failed");

        // Drain channels.
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Delete should dirty 1 key");

        // Sync — re-scan finds no row → delete issued to destination.
        let del_cursor = session.sync(&source, &destination, full_cursor)
            .expect("sync failed");
        assert_eq!(del_cursor.rows_written, 1, "Delete sync should record 1 operation");

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 0, "Destination must not have the deleted row");
    }

    // ── §10.3 Restart-resume from watermark ──────────────────────────────

    /// §10.3 — New session with saved cursor; only new audit events after watermark.
    #[test]
    fn restart_resume_from_watermark() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // Insert row 1 + audit event 1, full-flush baseline.
        let id1 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id1, 0b0001), &["id".to_string()])
            .expect("upsert r1");
        let ae1 = tests_helpers::make_audit_event(estate_id, id1, 1_000);
        source.audit_log().append(ae1.clone()).expect("append ae1");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        let watermark = full_cursor.hlc_watermark;
        assert!(watermark.is_some(), "Watermark should be non-nil");

        // Start new session (simulates restart with saved cursor).
        let session2 = IncrementalReplicationSession::start(&source, &schema);

        // Insert row 2 + audit event 2 with HLC strictly after the watermark.
        let id2 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id2, 0b1010), &["id".to_string()])
            .expect("upsert r2");
        let ae2 = tests_helpers::make_audit_event(estate_id, id2, 2_000);
        source.audit_log().append(ae2).expect("append ae2");

        // Drain channels.
        session2.drain_channels();

        let cursor2 = session2.sync(&source, &destination, full_cursor)
            .expect("sync2 failed");

        assert_eq!(cursor2.rows_written, 1, "Second session should sync only the new row");
        assert_eq!(cursor2.audit_events_written, 1,
            "Second session should sync only the new audit event (after watermark)");

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 2, "Destination must have both rows");
    }

    // ── §10.4 Empty dirty-set returns cursor unchanged ────────────────────

    /// §10.4 — Empty dirty-set sync returns the fromCursor unchanged.
    #[test]
    fn empty_dirty_set_returns_cursor_unchanged() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        let hlc = HLC::new(42_000, 7, 3);
        let input_cursor = ReplicationCursor {
            hlc_watermark: Some(hlc),
            rows_written: 17,
            audit_events_written: 5,
            blobs_written: 0,
        };

        // No writes → empty dirty-set (after drain_channels).
        let output_cursor = session.sync(&source, &destination, input_cursor.clone())
            .expect("sync failed");

        assert_eq!(output_cursor.hlc_watermark, Some(hlc));
        assert_eq!(output_cursor.rows_written, 17);
        assert_eq!(output_cursor.audit_events_written, 5);
    }

    // ── §10.5 Session observes multiple tables ────────────────────────────

    /// §10.5 — Session subscribes to all tables; dirty keys from each accumulate.
    #[test]
    fn session_observes_multiple_tables() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Insert one item + one event.
        let item_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(item_id, 0b0110), &["id".to_string()])
            .expect("upsert item");

        let topic_id = Uuid::new_v4();
        let hlc = HLC::new(5_000, 0, 1);
        source.row_store()
            .upsert("events", event_row(topic_id, 1, hlc), &["topic_id".to_string(), "seq".to_string()])
            .expect("upsert event");

        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 2,
            "Session should have 2 dirty keys: 1 item + 1 event");

        let zero_cursor = ReplicationCursor { hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0 };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed");
        assert_eq!(cursor.rows_written, 2);

        let item_count = destination.row_store().count("items", None).expect("count items");
        let event_count = destination.row_store().count("events", None).expect("count events");
        assert_eq!(item_count, 1);
        assert_eq!(event_count, 1);
    }

    // ── §10.6 Audit event delta ────────────────────────────────────────────

    /// §10.6 — Only audit events after the watermark are sent on incremental sync.
    #[test]
    fn audit_event_delta_only_new_events_after_watermark() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // Append 2 audit events + 1 row; full-flush as baseline.
        let ae1 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 1_000);
        let ae2 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 2_000);
        source.audit_log().append_batch(vec![ae1, ae2]).expect("append batch");

        let id1 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id1, 0b0001), &["id".to_string()])
            .expect("upsert");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        let dst_audit_after_full = destination.audit_log().count().expect("count");
        assert_eq!(dst_audit_after_full, 2, "Baseline flush should deliver both audit events");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Append event 3 with HLC strictly after watermark.
        let ae3 = tests_helpers::make_audit_event(estate_id, Uuid::new_v4(), 3_000);
        source.audit_log().append(ae3).expect("append ae3");

        // Insert another row so dirty-set is non-empty.
        let id2 = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(id2, 0b1000), &["id".to_string()])
            .expect("upsert2");

        session.drain_channels();

        let cursor2 = session.sync(&source, &destination, full_cursor)
            .expect("sync2 failed");
        assert_eq!(cursor2.audit_events_written, 1,
            "Incremental sync should deliver only the new audit event");

        let dst_audit_total = destination.audit_log().count().expect("count total");
        assert_eq!(dst_audit_total, 3, "Destination must have all 3 audit events");
    }

    // ── §10.7 Full-snapshot path unchanged ────────────────────────────────

    /// §10.7 — Full-snapshot flush still works alongside an active session.
    #[test]
    fn full_snapshot_path_unchanged_beside_session() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Insert 5 rows.
        for _ in 0..5 {
            source.row_store()
                .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
                .expect("upsert");
        }

        // Full flush.
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 5);

        let dst_count = destination.row_store().count("items", None).expect("count");
        assert_eq!(dst_count, 5);

        // Second full flush — idempotent.
        let full_cursor2 = replication::flush(&source, &destination, &schema).expect("flush2");
        assert_eq!(full_cursor2.rows_written, 5);
        let dst_count2 = destination.row_store().count("items", None).expect("count2");
        assert_eq!(dst_count2, 5, "Second full flush must not duplicate rows");

        let _ = session; // session still usable
    }

    // ── §10.8 Abort-then-retry restores dirty keys ────────────────────────

    /// §10.8 — Abort-then-retry: drain the dirty-set (simulating what sync does
    /// before any fallible work), call restore (simulating the error-path restore),
    /// verify the keys survive, then do a clean sync that replicates them.
    ///
    /// This is the gate-return criterion from commit 654418f7:
    ///   1. Dirty rowA.
    ///   2. Drain the dirty-set into a local (simulates sync draining before work).
    ///   3. Call restore with the drained keys (simulates the error path).
    ///   4. Dirty-set must still contain rowA.
    ///   5. Clean sync → rowA replicates successfully.
    #[test]
    fn abort_then_retry_restores_dirty_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert one row and full-flush as baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0001), &["id".to_string()])
            .expect("upsert failed");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 1, "Baseline should copy 1 row");

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update the row to make it dirty.
        source.row_store()
            .upsert("items", item_row(row_id, 0b1111), &["id".to_string()])
            .expect("upsert dirty failed");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Should have exactly 1 dirty row");

        // Simulate a failed sync: drain the keys, then restore them (as the error
        // path does). This verifies the restore mechanism without requiring a
        // concrete FailingStorage implementation.
        let drained = session.dirty_set.drain();
        assert_eq!(drained.len(), 1, "Drain should return 1 key");
        assert_eq!(session.dirty_set.count(), 0, "After drain, dirty-set must be empty");

        // Restore — simulates what sync does when it encounters an error.
        session.dirty_set.restore(&drained);
        assert_eq!(session.dirty_set.count(), 1,
            "After restore, dirty-set must contain the drained key again");

        // Now do a real sync — it should replicate the restored dirty key.
        let cursor = session.sync(&source, &destination, full_cursor)
            .expect("retry sync failed");
        assert_eq!(cursor.rows_written, 1, "Retry sync must replicate the restored dirty row");

        // Verify the updated bitmap value arrived at destination.
        let predicate = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Uuid(row_id),
        );
        let rows = destination.row_store()
            .query("items", Some(&predicate), &[], None, None)
            .expect("query failed");
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b1111)),
            "Retry sync must have written the updated row"
        );
    }

    // ── §10.9 Keys dirtied during failed run survive alongside restored keys ──

    /// §10.9 — Keys dirtied DURING a failed sync run survive in the dirty-set
    /// alongside the restored drained keys (union, no overwrite of newer dirt).
    ///
    /// Setup:
    ///   1. Dirty rowA (will be drained).
    ///   2. Drain rowA into a local, then accumulate rowB (simulates new observer
    ///      event arriving DURING the failed run, after the drain).
    ///   3. Restore rowA — dirty-set now has both rowA and rowB.
    ///   4. Sync → both rowA and rowB replicate.
    #[test]
    fn keys_dirtied_during_failed_run_survive_alongside_restored_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let row_a_id = Uuid::new_v4();
        let row_b_id = Uuid::new_v4();

        source.row_store()
            .upsert("items", item_row(row_a_id, 0b0001), &["id".to_string()])
            .expect("upsert rowA");
        source.row_store()
            .upsert("items", item_row(row_b_id, 0b0010), &["id".to_string()])
            .expect("upsert rowB");

        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush failed");
        assert_eq!(full_cursor.rows_written, 2, "Baseline should copy 2 rows");

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Update rowA — it gets dirtied.
        source.row_store()
            .upsert("items", item_row(row_a_id, 0b1001), &["id".to_string()])
            .expect("update rowA");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "Only rowA dirtied so far");

        // Drain (simulates sync draining before fallible work).
        let drained = session.dirty_set.drain();
        assert_eq!(drained.len(), 1, "Drain must yield 1 key (rowA)");

        // Accumulate rowB AFTER drain (simulates observer event during inflight sync).
        source.row_store()
            .upsert("items", item_row(row_b_id, 0b1010), &["id".to_string()])
            .expect("update rowB");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1, "rowB accumulated after drain");

        // Restore rowA — dirty-set must now have both rowA and rowB (union).
        session.dirty_set.restore(&drained);
        assert_eq!(session.dirty_set.count(), 2,
            "After restore, dirty-set must contain both rowA (restored) and rowB (new)");

        // Sync must replicate both rows.
        let cursor = session.sync(&source, &destination, full_cursor)
            .expect("sync failed");
        assert_eq!(cursor.rows_written, 2,
            "Sync must replicate both rowA (restored) and rowB (new dirty)");

        // Verify updated values at destination.
        let pred_a = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_a_id));
        let rows_a = destination.row_store()
            .query("items", Some(&pred_a), &[], None, None).expect("query rowA");
        assert_eq!(rows_a[0].values.get("adjective_bitmap"), Some(&TypedValue::Bitmap(0b1001)));

        let pred_b = StoragePredicate::Eq(Column::new("items", "id"), TypedValue::Uuid(row_b_id));
        let rows_b = destination.row_store()
            .query("items", Some(&pred_b), &[], None, None).expect("query rowB");
        assert_eq!(rows_b[0].values.get("adjective_bitmap"), Some(&TypedValue::Bitmap(0b1010)));
    }

    // ── §10.B Blob propagation via incremental replication ────────────────

    /// §10.B1 — Blob write propagates on next incremental sync, byte-identical.
    #[test]
    fn incremental_blob_write_propagates() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Start session before any blobs exist.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob on source — the blob observer delivers a Put event.
        let blob_key = "incremental-blob-key";
        let blob_bytes: Vec<u8> = vec![0xFE, 0xED, 0xFA, 0xCE];
        source.blob_store().put(blob_key, &blob_bytes).expect("put blob");

        // Insert a row so the dirty-set is non-empty; drain both channels.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0101), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event");

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("incremental sync failed");
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob put");

        let actual = destination.blob_store().get(blob_key).expect("get blob")
            .expect("blob must be present at destination");
        assert_eq!(actual, blob_bytes, "Blob must be byte-identical at destination");
    }

    /// §10.B2 — Blob delete propagates on next incremental sync.
    #[test]
    fn incremental_blob_delete_propagates() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Pre-populate blob on both source and destination (simulates prior full flush).
        let blob_key = "delete-me-blob";
        let blob_bytes: Vec<u8> = vec![0x11, 0x22, 0x33];
        source.blob_store().put(blob_key, &blob_bytes).expect("put src");
        destination.blob_store().put(blob_key, &blob_bytes).expect("put dst");

        // Start session AFTER pre-population.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Delete the blob from source.
        source.blob_store().delete(blob_key).expect("delete");

        // Insert a row so the dirty-set is non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b1010), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed");
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob delete");

        let result = destination.blob_store().get(blob_key).expect("get blob");
        assert!(result.is_none(),
            "Deleted blob must be absent from destination after sync");
    }

    // ── §10.B4 InMemory observer emits real blob events ───────────────────

    /// §10.B4 — InMemoryStorage delivers real BlobChange events through
    /// observe_blobs(). drain_blob_channel() accumulates them into BlobDirtyAccumulator;
    /// sync propagates the blob to the destination.
    ///
    /// This proves the observer mechanism is live for the InMemory backend.
    /// The SQLite backend mirrors this via putBlob/deleteBlob calling
    /// registry.notify_blob() directly (see SQLiteObserver.swift).
    #[test]
    fn inmemory_observer_delivers_real_blob_events() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Start session before any blobs are written.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob — InMemoryStorage emits the event through BlobObserverHub.
        let blob_key = "real-event-blob";
        let blob_bytes: Vec<u8> = vec![0x10, 0x20, 0x30, 0x40];
        source.blob_store().put(blob_key, &blob_bytes).expect("put blob");

        // Drain the blob channel — must pick up the live event.
        session.drain_blob_channel();

        // BlobDirtyAccumulator must contain the put event — proving the observer
        // delivered a real event rather than a disconnected (no-op) channel.
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event after drain_blob_channel");

        // Insert a row so the row dirty-set is non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();

        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("sync failed");
        assert!(cursor.blobs_written >= 1,
            "Incremental sync must propagate the blob put via real observer events");

        let actual = destination.blob_store().get(blob_key).expect("get")
            .expect("blob must be at destination");
        assert_eq!(actual, blob_bytes, "Blob must be byte-identical at destination");
    }

    // ── §10.B5 Real-abort restores dirty blob keys alongside row keys ────

    /// §10.B5 — A real sync failure (nil-bytes Put — fail-loud path in the transaction
    /// closure) after blob ops are drained from BlobDirtyAccumulator restores both the
    /// row dirty-set and the blob dirty-set before returning the error.
    /// A subsequent retry (after fixing the bad entry) replicates the blob.
    ///
    /// This is the mirror of the row-side §10.9 abort-then-retry test.
    /// It proves the REAL restore path rather than a manual drain/restore simulation:
    ///
    ///   1. Accumulate a real blob put (via InMemory observer + drain_blob_channel).
    ///   2. Accumulate a real row dirty key.
    ///   3. Inject a nil-bytes Put for a second key (fail-loud trigger).
    ///   4. sync() → drains both sets → snapshotDirtyRows OK → transaction closure
    ///      hits the nil-bytes Put → BackendError → rollback → catch → restore BOTH
    ///      dirty_keys and dirty_blobs → return Err.
    ///   5. After the error: blob_dirty.count() >= 1 (real blob restored), dirty_set.count() >= 1.
    ///   6. Remove the nil-bytes entry; retry → real blob replicates.
    #[test]
    fn real_abort_restores_dirty_blobs_alongside_rows() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        // Insert a row and full-flush as baseline.
        let row_id = Uuid::new_v4();
        source.row_store()
            .upsert("items", item_row(row_id, 0b0001), &["id".to_string()])
            .expect("upsert baseline");
        let full_cursor = replication::flush(&source, &destination, &schema).expect("flush");
        assert_eq!(full_cursor.rows_written, 1);

        // Start session AFTER baseline.
        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a real blob — InMemory observer delivers the event.
        let real_key = "real-blob-key";
        let real_bytes: Vec<u8> = vec![0xDE, 0xAD, 0xBE, 0xEF];
        source.blob_store().put(real_key, &real_bytes).expect("put real blob");

        // Drain blob channel: accumulates the real Put event.
        session.drain_blob_channel();
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must hold the real Put before inject");

        // Inject a second blob key with nil bytes to trigger the fail-loud path
        // in the transaction closure (BlobEvent::Put with bytes: None).
        let poison_key = "poison-blob-key";
        session.blob_dirty.inject_nil_bytes_put(poison_key.to_string());
        assert!(session.blob_dirty.count() >= 2,
            "BlobDirtyAccumulator must hold both the real Put and the nil-bytes poison entry");

        // Dirty the row so it is also in the dirty-set.
        source.row_store()
            .upsert("items", item_row(row_id, 0b1111), &["id".to_string()])
            .expect("update row");
        session.drain_channels();
        assert_eq!(session.dirty_set.count(), 1,
            "dirty_set must hold the updated row before the failing sync");

        // --- First sync must fail on the nil-bytes Put. ---
        let result = session.sync(&source, &destination, full_cursor.clone());
        assert!(result.is_err(),
            "sync must fail when a blob Put entry has nil bytes (fail-loud contract)");

        // Destination blob must not have been written (transaction rolled back).
        assert!(destination.blob_store().get(real_key).expect("get after abort").is_none(),
            "real blob must not be at destination after the failed sync");

        // RETRY-PRESERVATION: both the real blob and the row dirty key must be restored.
        // No sleep: the restore in the Rust sync error path is synchronous (map_err runs
        // inline, not in a spawned task), so the restore is complete when sync() returns.
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must be restored after abort (got {})", session.blob_dirty.count());
        assert!(session.dirty_set.count() >= 1,
            "Row dirty-set must be restored after abort (got {})", session.dirty_set.count());

        // Remove the poison entry by draining and re-accumulating only the real blob.
        // (In production, the caller would fix the underlying issue — here we can't
        // easily re-accumulate via the public API, so we drain and re-accumulate.)
        let drained = session.blob_dirty.drain();
        let real_entries: Vec<_> = drained.into_iter()
            .filter(|(k, _)| k.as_str() != poison_key)
            .collect();
        session.blob_dirty.restore(&real_entries);

        // Drain the row dirty-set too so it survives for the retry.
        // (drain was NOT called by the abort — the restore brought it back; confirm count.)
        assert!(session.dirty_set.count() >= 1,
            "Row dirty-set must still be non-empty for retry");

        // --- Retry sync: real blob must replicate. ---
        let retry_cursor = session.sync(&source, &destination, full_cursor)
            .expect("retry sync must succeed after removing the poison entry");
        assert!(retry_cursor.blobs_written >= 1,
            "Retry must replicate the real blob that was drain-restored (got {})", retry_cursor.blobs_written);
        assert!(retry_cursor.rows_written >= 1,
            "Retry must replicate the row that was drain-restored (got {})", retry_cursor.rows_written);

        let actual = destination.blob_store().get(real_key).expect("get after retry")
            .expect("real blob must be at destination after retry");
        assert_eq!(actual, real_bytes, "Real blob must be byte-identical at destination after retry");
    }

    /// §10.B3 — Abort-then-retry restores dirty blob keys.
    #[test]
    fn abort_then_retry_restores_dirty_blob_keys() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let destination = make_storage(&schema);

        let session = IncrementalReplicationSession::start(&source, &schema);

        // Put a blob on source.
        let blob_key = "retry-blob";
        let blob_bytes: Vec<u8> = vec![0xAB, 0xCD, 0xEF];
        source.blob_store().put(blob_key, &blob_bytes).expect("put");

        // Insert a row to make dirty-set non-empty.
        source.row_store()
            .upsert("items", item_row(Uuid::new_v4(), 0b0001), &["id".to_string()])
            .expect("upsert");
        session.drain_channels();
        session.drain_blob_channel();

        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must contain the put event");

        // Drain the blob accumulator (simulates what sync does before fallible work).
        let drained = session.blob_dirty.drain();
        assert!(!drained.is_empty(), "Drain must return at least 1 entry");

        // Blob must not be in destination yet.
        assert!(destination.blob_store().get(blob_key).expect("get").is_none(),
            "Blob must not be in destination before sync");

        // Restore the drained blobs (simulates the error-path restore).
        session.blob_dirty.restore(&drained);
        assert!(session.blob_dirty.count() >= 1,
            "BlobDirtyAccumulator must still contain the key after restore");

        // Clean sync — blob must propagate.
        let zero_cursor = ReplicationCursor {
            hlc_watermark: None, rows_written: 0, audit_events_written: 0, blobs_written: 0
        };
        let cursor = session.sync(&source, &destination, zero_cursor)
            .expect("retry sync failed");
        assert!(cursor.blobs_written >= 1, "Retry sync must replicate the blob");

        let actual = destination.blob_store().get(blob_key).expect("get")
            .expect("blob must be present after retry sync");
        assert_eq!(actual, blob_bytes,
            "Blob must be byte-identical at destination after retry sync");
    }
}

/// Test helpers for use in this module and replication module tests.
/// Not pub(crate) — the replication module's test uses its own helper.
/// This module has its own copy to be self-contained.
#[cfg(test)]
pub(crate) mod tests_helpers {
    use crate::audit_log::AuditEvent;
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    pub fn make_audit_event(estate_id: Uuid, row_id: Uuid, physical_time: i64) -> AuditEvent {
        AuditEvent {
            event_id: Uuid::new_v4(),
            estate_uuid: estate_id,
            row_id,
            hlc: HLC::new(physical_time, 0, 1),
            verb: "capture".into(),
            before_adjective: None,
            before_operational: None,
            before_provenance: None,
            after_adjective: 0,
            after_operational: 0,
            after_provenance: 0,
            before_lattice_anchor: None,
            after_lattice_anchor: 0,
            actor: "test".into(),
            reason: None,
        }
    }
}
