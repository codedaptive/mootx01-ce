// PersistenceKitBackend (Rust) — behaviour-conformant with the Swift
// PersistenceKitBackend per QUEUEKIT_SPEC §10.
//
// This module is gated on the "persistencekit" feature flag so the
// default (Filesystem-only) build carries no dependency on
// persistence-kit.
//
// Schema notes (mirroring Swift PersistenceKitBackend.swift):
//   - Table: "queuekit_jobs"
//   - Columns: id (TEXT PK), stream_id, physical_time, logical_count,
//     node_id, priority (INT DEFAULT 50), status (TEXT), payload (BLOB),
//     extensions (TEXT JSON), signal_status (TEXT nullable),
//     artifacts (TEXT nullable), session_id (TEXT nullable).
//   - Indices: (status), (status, physical_time, logical_count, node_id),
//     (stream_id, status).
//   - append_only MUST be false per spec §10.
//   - Dates stored as TEXT (ISO8601) where relevant; HLC stored as
//     three separate INT columns (physical_time, logical_count, node_id).
//
// Rust-side adaptation notes vs. Swift:
//   - The Swift backend is async (actor-driven); Rust Storage traits are
//     synchronous. All methods return Result synchronously.
//   - Swift `storage.transaction(isolation:_:)` returns a generic value;
//     the Rust trait is object-safe so `transaction` takes a
//     `&mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>`.
//     Results are captured through the closure environment.
//   - watch() subscribes via `storage.observer().observe(table, events)`
//     which returns a std::sync::mpsc::Receiver<TableChange>. Blocking
//     on the receiver is equivalent to Swift's `for await _ in stream`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use persistence_kit::{
    ColumnDeclaration, ColumnType, IndexDeclaration, IsolationLevel, SchemaDeclaration,
    StorageError, StorageEvent, StoragePredicate, TableDeclaration,
    TypedValue,
};
use persistence_kit::storage::{Storage, StorageTransaction};
use persistence_kit::predicate::OrderClause;
use persistence_kit::types::{Column, StorageRow};

use crate::backend::QueueBackend;
use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};

// ---------------------------------------------------------------------------
// Table name constant — mirrors Swift's `queueKitTableName`
// ---------------------------------------------------------------------------

/// The PersistenceKit table used by QueueKit to store jobs.
/// Mirrors Swift's `queueKitTableName = "queuekit_jobs"`.
pub const QUEUE_KIT_TABLE_NAME: &str = "queuekit_jobs";

// ---------------------------------------------------------------------------
// Schema — mirrors Swift's QueueKitSchema enum
// ---------------------------------------------------------------------------

/// Schema declaration for the QueueKit jobs table.
///
/// Mirrors Swift's `QueueKitSchema` enum: same kitID, version, column set,
/// and index set. The table is never append-only (SPEC §10 invariant 5).
pub struct QueueKitSchema;

impl QueueKitSchema {
    /// Kit identifier used in schema versioning.
    pub const KIT_ID: &'static str = "QueueKit";

    /// Schema version. Bumped when a migration is added.
    pub const VERSION: i32 = 1;

    /// Build the full schema declaration for this kit.
    pub fn declaration() -> SchemaDeclaration {
        let table = TableDeclaration::new(
            QUEUE_KIT_TABLE_NAME,
            vec![
                ColumnDeclaration::new("id", ColumnType::Text),
                ColumnDeclaration::new("stream_id", ColumnType::Text),
                // HLC stored as three INT columns (physical_time ms, logical count, node_id).
                ColumnDeclaration::new("physical_time", ColumnType::Int),
                ColumnDeclaration::new("logical_count", ColumnType::Int),
                ColumnDeclaration::new("node_id", ColumnType::Int),
                // Job priority (lower = higher priority per spec §4). Default 50.
                ColumnDeclaration::new("priority", ColumnType::Int)
                    .with_default(TypedValue::Int(50)),
                // Lifecycle status: "new" → "cur" → "done".
                ColumnDeclaration::new("status", ColumnType::Text),
                // Payload is opaque binary; stored as BLOB.
                ColumnDeclaration::new("payload", ColumnType::Blob),
                // Extensions JSON text. Round-trips verbatim per spec §4 I-6.
                ColumnDeclaration::new("extensions", ColumnType::Text),
                // Set at complete() time: the ObservationStatus raw value.
                ColumnDeclaration::new("signal_status", ColumnType::Text).nullable(),
                // JSON array of ArtifactRef objects; set at complete().
                ColumnDeclaration::new("artifacts", ColumnType::Text).nullable(),
                // Session ID assigned at claim time by drainAvailable().
                ColumnDeclaration::new("session_id", ColumnType::Text).nullable(),
            ],
            // "id" is the primary key.
            vec!["id".to_string()],
        );
        // append_only defaults to false — MUST NOT be set true per spec §10.

        let indices = vec![
            // Fast lookup of jobs by lifecycle status.
            IndexDeclaration::new(
                "idx_queuekit_status",
                QUEUE_KIT_TABLE_NAME,
                vec!["status".to_string()],
            ),
            // Ordered claim scan: status filter + HLC order in one index.
            IndexDeclaration::new(
                "idx_queuekit_claim_order",
                QUEUE_KIT_TABLE_NAME,
                vec![
                    "status".to_string(),
                    "physical_time".to_string(),
                    "logical_count".to_string(),
                    "node_id".to_string(),
                ],
            ),
            // Per-stream status queries (completed(streamID:) path).
            IndexDeclaration::new(
                "idx_queuekit_stream",
                QUEUE_KIT_TABLE_NAME,
                vec!["stream_id".to_string(), "status".to_string()],
            ),
        ];

        SchemaDeclaration::new(QueueKitSchema::KIT_ID, QueueKitSchema::VERSION, vec![table])
            .with_indices(indices)
    }
}

// ---------------------------------------------------------------------------
// Backend
// ---------------------------------------------------------------------------

/// PersistenceKit-backed QueueBackend.
///
/// Stores jobs durably in a PersistenceKit `Storage` instance.
/// Behaviour-conformant with the Swift `PersistenceKitBackend`:
/// same invariants, same claim atomicity, same HLC ordering.
///
/// Callers must open the schema before using the backend:
/// ```ignore
/// let schema = QueueKitSchema::declaration();
/// storage.open(&schema)?;
/// let backend = PersistenceKitBackend::new(storage);
/// ```
/// `Clone` shares the SAME underlying `Arc<dyn Storage>` — both handles read
/// and write the one queue table. This lets a background drain worker hold its
/// own backend handle (for `watch`/`drain_available`/`complete`) over the same
/// storage the enqueue side writes to, without moving the original out of the
/// coordinator (GLK near-realtime encode drain).
#[derive(Clone)]
pub struct PersistenceKitBackend {
    storage: Arc<dyn Storage>,
}

impl PersistenceKitBackend {
    /// Mount the backend on an already-opened storage instance.
    pub fn new(storage: Arc<dyn Storage>) -> Self {
        PersistenceKitBackend { storage }
    }

    /// Open the QueueKit schema on `storage`. Convenience that mirrors
    /// Swift's `PersistenceKitBackend.openSchema(on:)`.
    pub fn open_schema(storage: &dyn Storage) -> Result<(), QueueError> {
        let schema = QueueKitSchema::declaration();
        storage.open(&schema).map_err(storage_err)
    }

    /// Drain the queue repeatedly until a pass claims nothing, handing every
    /// claimed job to `handler`. Used by `watch` (see its body for why
    /// draining-until-empty per wake — not once per event — is load-robust). A
    /// claim error ends the pass; the next wake retries. Mirrors the Swift
    /// `PersistenceKitBackend.drainUntilEmpty`.
    fn drain_until_empty<F>(&self, handler: &F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        loop {
            let batch = self.drain_available()?;
            if batch.is_empty() {
                return Ok(());
            }
            for (job, session) in batch {
                handler(job, session)?;
            }
        }
    }

    fn col(name: &str) -> Column {
        Column::new(QUEUE_KIT_TABLE_NAME, name)
    }

    /// Decode a StorageRow into a Job. Returns None if required columns
    /// are absent or have unexpected types (silent skip, matches Swift).
    fn decode_row(row: &StorageRow) -> Option<Job> {
        let id = match row.get("id")? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        let stream_id = match row.get("stream_id")? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        let phys = match row.get("physical_time")? {
            TypedValue::Int(i) => *i,
            _ => return None,
        };
        let logical = match row.get("logical_count")? {
            TypedValue::Int(i) => *i as i32,
            _ => return None,
        };
        let node = match row.get("node_id")? {
            TypedValue::Int(i) => *i as i32,
            _ => return None,
        };
        let priority = match row.get("priority")? {
            TypedValue::Int(i) => *i as i32,
            _ => return None,
        };
        let payload = match row.get("payload")? {
            TypedValue::Blob(b) => b.clone(),
            _ => return None,
        };
        let ext_json = match row.get("extensions")? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };

        use substrate_types::hlc::HLC;
        let hlc = HLC { physical_time: phys, logical_count: logical, node_id: node };

        // Parse extensions JSON; fall back to empty map on failure.
        let extensions = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(
            &ext_json
        ).unwrap_or_default();

        Some(Job {
            id: JobId(id),
            stream_id: StreamId(stream_id),
            submitted_at: hlc,
            priority,
            payload,
            extensions,
        })
    }

    /// Encode ArtifactRef list to JSON text for storage.
    fn encode_artifacts(artifacts: &[ArtifactRef]) -> Result<String, QueueError> {
        let arr: Vec<serde_json::Value> = artifacts.iter().map(|a| {
            let mut m = serde_json::Map::new();
            m.insert("type".to_string(), serde_json::Value::String(a.type_tag().to_string()));
            m.insert("value".to_string(), serde_json::Value::String(a.value().to_string()));
            serde_json::Value::Object(m)
        }).collect();
        serde_json::to_string(&serde_json::Value::Array(arr))
            .map_err(|e| QueueError::WriteFailed(e.to_string()))
    }

    /// List jobs with a given status, optionally filtered by stream_id.
    fn list_jobs(
        &self,
        status: &str,
        stream_id: Option<&StreamId>,
    ) -> Result<Vec<Job>, QueueError> {
        let mut preds = vec![
            StoragePredicate::Eq(Self::col("status"), TypedValue::Text(status.to_string())),
        ];
        if let Some(s) = stream_id {
            preds.push(StoragePredicate::Eq(
                Self::col("stream_id"),
                TypedValue::Text(s.0.clone()),
            ));
        }
        let predicate = StoragePredicate::all(preds);
        let order = vec![
            OrderClause::ascending(Self::col("physical_time")),
            OrderClause::ascending(Self::col("logical_count")),
            OrderClause::ascending(Self::col("node_id")),
        ];
        let rows = self.storage.row_store()
            .query(QUEUE_KIT_TABLE_NAME, Some(&predicate), &order, None, None)
            .map_err(storage_err)?;
        Ok(rows.iter().filter_map(Self::decode_row).collect())
    }
}

// ---------------------------------------------------------------------------
// QueueBackend impl
// ---------------------------------------------------------------------------

impl QueueBackend for PersistenceKitBackend {
    // Bare insert per spec §10 invariant 1 — DO NOT wrap in transaction.
    fn write(&self, job: &Job) -> Result<(), QueueError> {
        let ext_json = serde_json::to_string(
            &serde_json::Value::Object(job.extensions.clone())
        ).map_err(|e| QueueError::WriteFailed(e.to_string()))?;

        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text(job.id.0.clone()));
        values.insert("stream_id".to_string(), TypedValue::Text(job.stream_id.0.clone()));
        values.insert("physical_time".to_string(), TypedValue::Int(job.submitted_at.physical_time));
        values.insert("logical_count".to_string(), TypedValue::Int(job.submitted_at.logical_count as i64));
        values.insert("node_id".to_string(), TypedValue::Int(job.submitted_at.node_id as i64));
        values.insert("priority".to_string(), TypedValue::Int(job.priority as i64));
        values.insert("status".to_string(), TypedValue::Text("new".to_string()));
        values.insert("payload".to_string(), TypedValue::Blob(job.payload.clone()));
        values.insert("extensions".to_string(), TypedValue::Text(ext_json));

        self.storage.row_store()
            .insert(QUEUE_KIT_TABLE_NAME, values)
            .map(|_| ())
            .map_err(|e| QueueError::WriteFailed(e.to_string()))
    }

    // Serializable atomic claim: find all "new" rows ordered by HLC,
    // attempt rename to "cur" with a status guard. Per spec §10 invariant 3.
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
        let mut claimed: Vec<(Job, SessionId)> = Vec::new();

        self.storage.transaction(IsolationLevel::Serializable, &mut |txn: &dyn StorageTransaction| {
            let order = vec![
                OrderClause::ascending(Column::new(QUEUE_KIT_TABLE_NAME, "physical_time")),
                OrderClause::ascending(Column::new(QUEUE_KIT_TABLE_NAME, "logical_count")),
                OrderClause::ascending(Column::new(QUEUE_KIT_TABLE_NAME, "node_id")),
            ];
            let pred = StoragePredicate::Eq(
                Column::new(QUEUE_KIT_TABLE_NAME, "status"),
                TypedValue::Text("new".to_string()),
            );
            let rows = txn.row_store()
                .query(QUEUE_KIT_TABLE_NAME, Some(&pred), &order, None, None)?;

            for row in &rows {
                let row_id = match row.get("id") {
                    Some(TypedValue::Text(s)) => s.clone(),
                    _ => continue,
                };

                // Generate a new session ID for this claim.
                let session = SessionId(uuid::Uuid::new_v4().to_string().to_lowercase());

                let mut update_vals = BTreeMap::new();
                update_vals.insert("status".to_string(), TypedValue::Text("cur".to_string()));
                update_vals.insert("session_id".to_string(), TypedValue::Text(session.0.clone()));

                // Guard: only update if status is still "new" (atomic claim).
                let guard = StoragePredicate::And(vec![
                    StoragePredicate::Eq(
                        Column::new(QUEUE_KIT_TABLE_NAME, "status"),
                        TypedValue::Text("new".to_string()),
                    ),
                    StoragePredicate::Eq(
                        Column::new(QUEUE_KIT_TABLE_NAME, "id"),
                        TypedValue::Text(row_id),
                    ),
                ]);

                let updated = txn.row_store()
                    .update(QUEUE_KIT_TABLE_NAME, update_vals, &guard)?;

                if updated == 1 {
                    if let Some(job) = Self::decode_row(row) {
                        claimed.push((job, session));
                    }
                }
            }
            Ok(())
        }).map_err(storage_err)?;

        // Sort by HLC ascending — matches Swift's claimed.sort.
        claimed.sort_by(|a, b| {
            (a.0.submitted_at.physical_time,
             a.0.submitted_at.logical_count,
             a.0.submitted_at.node_id)
                .cmp(&(b.0.submitted_at.physical_time,
                       b.0.submitted_at.logical_count,
                       b.0.submitted_at.node_id))
        });

        Ok(claimed)
    }

    // Serializable update guarded by status="cur" per spec §10.
    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError> {
        if !status.is_terminal() {
            return Err(QueueError::InvalidTerminalStatus(status.raw().to_string()));
        }

        let artifacts_text = Self::encode_artifacts(&artifacts)?;
        let mut affected: usize = 0;

        self.storage.transaction(IsolationLevel::Serializable, &mut |txn: &dyn StorageTransaction| {
            let mut update_vals = BTreeMap::new();
            update_vals.insert("status".to_string(), TypedValue::Text("done".to_string()));
            update_vals.insert("signal_status".to_string(), TypedValue::Text(status.raw().to_string()));
            update_vals.insert("artifacts".to_string(), TypedValue::Text(artifacts_text.clone()));

            // Guard: only complete a job that is in "cur" state.
            let guard = StoragePredicate::And(vec![
                StoragePredicate::Eq(
                    Column::new(QUEUE_KIT_TABLE_NAME, "id"),
                    TypedValue::Text(job_id.0.clone()),
                ),
                StoragePredicate::Eq(
                    Column::new(QUEUE_KIT_TABLE_NAME, "status"),
                    TypedValue::Text("cur".to_string()),
                ),
            ]);

            affected = txn.row_store()
                .update(QUEUE_KIT_TABLE_NAME, update_vals, &guard)?;
            Ok(())
        }).map_err(storage_err)?;

        if affected == 0 {
            return Err(QueueError::JobNotFound(job_id.0.clone()));
        }
        Ok(())
    }

    fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        self.list_jobs("cur", None)
    }

    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        self.list_jobs("done", stream_id)
    }

    // pendingCount (telemetry depth probe) — Swift parity.
    //
    // COUNT(*) WHERE status = 'new' — a single read, no claim, no cursor
    // advance. Mirrors Swift's `PersistenceKitBackend.pendingCount()`.
    fn pending_count(&self) -> Result<usize, QueueError> {
        let pred = StoragePredicate::Eq(
            Self::col("status"),
            TypedValue::Text("new".to_string()),
        );
        self.storage.row_store()
            .count(QUEUE_KIT_TABLE_NAME, Some(&pred))
            .map_err(storage_err)
    }

    // watch(): subscribe to INSERT events on the jobs table, wake on each
    // event, and re-read through drain_available() (spec §10 invariant 2).
    //
    // The observer event is a wake signal only; never trust event payloads
    // as authoritative job data — they may reflect uncommitted state.
    fn watch<F>(&self, handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        let mut events = BTreeSet::new();
        events.insert(StorageEvent::Insert);

        let rx = self.storage.observer()
            .observe(QUEUE_KIT_TABLE_NAME, events)
            .map_err(|e| QueueError::WatcherFailed(e.to_string()))?;

        // Drain anything already present before we subscribed, until empty.
        self.drain_until_empty(&handler)?;

        // Block until the channel closes or handler errors.
        loop {
            match rx.recv() {
                Ok(_) => {
                    // Wake signal received. Re-drain through the claim path until
                    // the queue is empty — NOT once per event. Draining-until-
                    // empty makes watch LOAD-robust: under a burst the observer
                    // may coalesce inserts (fewer events than rows) or a wake may
                    // be dropped while a serializable claim contends with
                    // concurrent inserts; a once-per-event drain would strand the
                    // rows whose wake was coalesced away. Re-draining until empty
                    // on every wake guarantees no committed job is left behind.
                    self.drain_until_empty(&handler)?;
                }
                Err(_) => {
                    // Channel closed — storage shut down, exit cleanly.
                    return Ok(());
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Map a StorageError to a QueueError. Used at backend boundaries.
fn storage_err(e: StorageError) -> QueueError {
    QueueError::BackendUnavailable(e.to_string())
}
