//! Storage replication primitive — §5 full-snapshot flush/hydrate.
//!
//! Mirrors the Swift `PersistenceKitReplication` module.
//!
//! CONTRACT:
//!   - Schema gate: source and destination must be at the same schema version.
//!     No auto-migration. The Rust Storage trait exposes only a global
//!     `current_schema_version()` (no per-kit version); the gate checks the
//!     global version against the schema's declared version for both sides.
//!   - Atomicity: the entire destination write is wrapped in a serializable
//!     transaction. A failure mid-flush leaves the destination at its prior
//!     consistent state (the InMemory backend snapshot-restores on error;
//!     the SQLite backend rolls back via ROLLBACK; PostgreSQL rolls back via
//!     ROLLBACK).
//!   - Row snapshot: all rows in schema.tables are copied verbatim (including
//!     tombstoned and append-only rows). Generated columns are FILTERED OUT
//!     before upsert — the destination backend recomputes them from the base
//!     columns. Writing a generated column would error in SQLite/PostgreSQL.
//!   - Idempotent upsert: conflict_columns is table.primary_key, NOT the
//!     RowHandle.key (which is a random UUID differing between runs).
//!   - Audit copy: _storagekit_audit is NOT in schema.tables. It is copied
//!     via a separate audit_log().iterate() → append_batch() path.
//!   - Blob copy: not implemented. No GLK kit uses blobStore for content as
//!     of 2026-06-05 (confirmed by REPLICATION_GROUND_TRUTH.md). BlobStore
//!     also lacks a list_keys() method; enumeration is impossible without it.
//!     A future mission adding GLK blob usage must also add BlobStore::list_keys()
//!     and a blob copy step here.
//!   - TypedValue is copied verbatim (no coercion).
//!   - HLC watermark: the max HLC seen across all row HLC columns and audit
//!     events is returned in ReplicationCursor.
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

use crate::audit_log::AuditEvent;
use crate::error::{StorageError, StorageResult};
use crate::schema::SchemaDeclaration;
use crate::storage::{IsolationLevel, Storage};
use crate::types::TypedValue;
use std::collections::BTreeMap;
use substrate_types::hlc::HLC;

// MARK: - ReplicationMode

/// Controls the scope of a single replicate() call.
///
/// Only `Full` is implemented (§5). `Incremental` throws
/// `ReplicationError::NotImplemented` — §6 is a separate track.
///
/// NOTE: The §6 incremental path MUST drive its dirty-set off
/// `StorageObserver.observe`, NOT `AuditLog::iterate`. The GLK
/// AuditGate is drawer-only today; several noun inserts bypass it,
/// so an audit-driven incremental flush would silently miss them.
#[derive(Debug, Clone)]
pub enum ReplicationMode {
    /// Full snapshot: copy all rows, all audit events. Atomic.
    Full,
    /// Incremental delta driven by a StorageObserver dirty-set.
    /// NOT YET IMPLEMENTED — returns `ReplicationError::NotImplemented`.
    Incremental { cursor: ReplicationCursor },
}

// MARK: - ReplicationCursor

/// Watermark returned from `replicate()`. Records the maximum HLC
/// observed across all copied rows and audit events.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplicationCursor {
    /// Highest HLC observed. `None` when source was empty.
    pub hlc_watermark: Option<HLC>,
    /// Total rows written across all tables.
    pub rows_written: usize,
    /// Total audit events copied.
    pub audit_events_written: usize,
}

// MARK: - ReplicationError

/// Errors specific to the replication primitive.
#[derive(Debug, PartialEq)]
pub enum ReplicationError {
    /// Source and destination schema versions differ.
    /// Upgrade both to the same version before replicating.
    SchemaMismatch {
        source_version: i32,
        destination_version: i32,
        kit_id: String,
    },
    /// The requested mode is not yet implemented.
    NotImplemented { reason: String },
    /// A storage error surfaced during source reads or destination writes.
    StorageFailure { detail: String },
}

impl From<StorageError> for ReplicationError {
    fn from(e: StorageError) -> Self {
        ReplicationError::StorageFailure {
            detail: format!("{:?}", e),
        }
    }
}

// MARK: - replicate

/// Copy the full projected state of `source` into `destination`.
///
/// - `source`: Storage to read from (must be open).
/// - `destination`: Storage to write to (must be open).
/// - `schema`: Schema declaration governing which tables to copy.
/// - `mode`: `Full` copies all rows and audit events atomically.
///   `Incremental` returns `ReplicationError::NotImplemented`.
///
/// Returns a `ReplicationCursor` with HLC watermark and row/event counts.
pub fn replicate(
    source: &dyn Storage,
    destination: &dyn Storage,
    schema: &SchemaDeclaration,
    mode: ReplicationMode,
) -> Result<ReplicationCursor, ReplicationError> {
    match mode {
        ReplicationMode::Full => replicate_full(source, destination, schema),
        ReplicationMode::Incremental { .. } => Err(ReplicationError::NotImplemented {
            reason: "§6 incremental replication is not yet implemented. \
                     The dirty-set must be driven by StorageObserver.observe, \
                     not AuditLog::iterate — several noun inserts bypass the AuditGate."
                .to_string(),
        }),
    }
}

/// Flush a source storage into a destination storage (full mode).
///
/// Convenience wrapper: `replicate(source, destination, schema, Full)`.
pub fn flush(
    source: &dyn Storage,
    destination: &dyn Storage,
    schema: &SchemaDeclaration,
) -> Result<ReplicationCursor, ReplicationError> {
    replicate(source, destination, schema, ReplicationMode::Full)
}

/// Hydrate a fresh storage from a durable source.
///
/// Convenience wrapper: `replicate(durable, in_memory, schema, Full)`.
/// Call on a freshly-opened InMemoryStorage instance.
pub fn hydrate(
    in_memory: &dyn Storage,
    durable: &dyn Storage,
    schema: &SchemaDeclaration,
) -> Result<ReplicationCursor, ReplicationError> {
    replicate(durable, in_memory, schema, ReplicationMode::Full)
}

// MARK: - Full-snapshot implementation

fn replicate_full(
    source: &dyn Storage,
    destination: &dyn Storage,
    schema: &SchemaDeclaration,
) -> Result<ReplicationCursor, ReplicationError> {

    // ── Step 1: Schema gate ────────────────────────────────────────
    // The Rust Storage trait exposes only a global `current_schema_version()`.
    // We compare both backends against the schema's declared version. This is
    // correct for the single-kit-per-storage case common in tests. Multi-kit
    // storage would need per-kit gating (a future Storage trait extension).
    let src_version = source
        .current_schema_version()
        .map_err(ReplicationError::from)?;
    let dst_version = destination
        .current_schema_version()
        .map_err(ReplicationError::from)?;

    if src_version != dst_version || src_version != schema.version {
        return Err(ReplicationError::SchemaMismatch {
            source_version: src_version,
            destination_version: dst_version,
            kit_id: schema.kit_id.clone(),
        });
    }

    // ── Step 2: Snapshot source data ──────────────────────────────
    // All source reads happen before the destination transaction opens
    // to avoid holding the destination transaction open during slow I/O.
    let payload = snapshot_source(source, schema)?;

    // ── Step 3: Write destination inside a serializable transaction ─
    // The transaction block must return `StorageResult<()>` (Rust's
    // object-safe constraint). Results are captured via mutable references
    // through the closure environment.
    let mut rows_written: usize = 0;
    let mut audit_events_written: usize = 0;
    let mut max_hlc: Option<HLC> = None;

    let payload_ref = &payload;
    let rows_written_ref = &mut rows_written;
    let audit_events_written_ref = &mut audit_events_written;
    let max_hlc_ref = &mut max_hlc;

    destination
        .transaction(
            IsolationLevel::Serializable,
            &mut |txn| -> StorageResult<()> {
                let row_store = txn.row_store();
                let audit_log = txn.audit_log();

                // 3a. Row copy: upsert each table's snapshot.
                for snapshot in &payload_ref.table_snapshots {
                    for row_values in &snapshot.rows {
                        // Track HLC values from row columns for watermark.
                        for value in row_values.values() {
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

                        row_store.upsert(
                            &snapshot.table_name,
                            row_values.clone(),
                            &snapshot.primary_key,
                        )?;
                        *rows_written_ref += 1;
                    }
                }

                // 3b. Audit copy: append all events idempotently.
                if !payload_ref.audit_events.is_empty() {
                    audit_log.append_batch(payload_ref.audit_events.clone())?;
                    *audit_events_written_ref = payload_ref.audit_events.len();

                    // Track HLC from audit events for watermark.
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

                Ok(())
            },
        )
        .map_err(ReplicationError::from)?;

    Ok(ReplicationCursor {
        hlc_watermark: max_hlc,
        rows_written,
        audit_events_written,
    })
}

// MARK: - Source snapshot helper

/// Intermediate payload holding source data captured before the destination
/// transaction opens.
struct ReplicationPayload {
    /// Per-table snapshots. Generated columns have been filtered from each row's
    /// values; the destination backend recomputes them from the base columns.
    table_snapshots: Vec<TableSnapshot>,
    /// All audit events from _storagekit_audit (via AuditLog::iterate).
    audit_events: Vec<AuditEvent>,
}

struct TableSnapshot {
    table_name: String,
    /// The table's declared primaryKey — used as the conflict_columns for upsert.
    primary_key: Vec<String>,
    /// Rows with generated columns filtered out.
    rows: Vec<BTreeMap<String, TypedValue>>,
}

fn snapshot_source(
    source: &dyn Storage,
    schema: &SchemaDeclaration,
) -> Result<ReplicationPayload, ReplicationError> {
    let row_store = source.row_store();
    let audit_log = source.audit_log();

    let mut table_snapshots: Vec<TableSnapshot> = Vec::new();

    for table in &schema.tables {
        // Collect generated column names so we can filter them out before upsert.
        let generated_names: std::collections::BTreeSet<String> = table
            .generated_columns
            .iter()
            .map(|g| g.name.clone())
            .collect();

        // Query all rows (nil predicate = all rows, including tombstoned).
        let rows = row_store
            .query(&table.name, None, &[], None, None)
            .map_err(ReplicationError::from)?;

        // Filter generated columns from each row.
        let filtered: Vec<BTreeMap<String, TypedValue>> = rows
            .into_iter()
            .map(|row| {
                row.values
                    .into_iter()
                    .filter(|(k, _)| !generated_names.contains(k))
                    .collect()
            })
            .collect();

        table_snapshots.push(TableSnapshot {
            table_name: table.name.clone(),
            primary_key: table.primary_key.clone(),
            rows: filtered,
        });
    }

    // Audit snapshot: _storagekit_audit is NOT in schema.tables.
    // usize::MAX as the Rust equivalent of Int.max (iterate all events).
    let audit_events = audit_log
        .iterate(None, None, usize::MAX)
        .map_err(ReplicationError::from)?;

    Ok(ReplicationPayload {
        table_snapshots,
        audit_events,
    })
}

// MARK: - Tests

#[cfg(test)]
mod replication_tests {
    use super::*;
    use crate::generated_column::{GeneratedColumn, GeneratedExpression};
    use crate::inmemory::InMemoryStorage;
    use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    use crate::types::{ColumnType, TypedValue};
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    // ── Synthetic schema ─────────────────────────────────────────────────

    fn synthetic_schema() -> SchemaDeclaration {
        // `items` table: adjective bitmap, blob payload, timestamp, nullable tombstone.
        // Single generated column: state_cluster = adjective_bitmap & 0xF.
        // `events` table: append-only with composite PK and HLC column.
        let items_table = TableDeclaration {
            name: "items".into(),
            columns: vec![
                ColumnDeclaration {
                    name: "id".into(),
                    column_type: ColumnType::Uuid,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "adjective_bitmap".into(),
                    column_type: ColumnType::Bitmap,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "payload".into(),
                    column_type: ColumnType::Blob,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "tombstoned_at".into(),
                    column_type: ColumnType::Timestamp,
                    nullable: true,
                    default_value: None,
                },
            ],
            primary_key: vec!["id".into()],
            unique_constraints: vec![],
            // state_cluster = adjective_bitmap & 0xF
            // The replication primitive must NOT write this column; the destination
            // backend recomputes it from adjective_bitmap.
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
                ColumnDeclaration {
                    name: "topic_id".into(),
                    column_type: ColumnType::Uuid,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "seq".into(),
                    column_type: ColumnType::Int,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "hlc_stamp".into(),
                    column_type: ColumnType::Hlc,
                    nullable: false,
                    default_value: None,
                },
                ColumnDeclaration {
                    name: "content".into(),
                    column_type: ColumnType::Text,
                    nullable: false,
                    default_value: None,
                },
            ],
            primary_key: vec!["topic_id".into(), "seq".into()],
            unique_constraints: vec![],
            generated_columns: vec![],
            append_only: true,
        };

        SchemaDeclaration {
            kit_id: "RustReplicationTestKit".into(),
            version: 1,
            tables: vec![items_table, events_table],
            indices: vec![],
            migrations: vec![],
        }
    }

    fn make_storage(schema: &SchemaDeclaration) -> InMemoryStorage {
        let estate_id = Uuid::new_v4();
        let storage = InMemoryStorage::with_estate(estate_id);
        storage.open(schema).expect("open failed");
        storage
    }

    fn make_audit_event(estate_id: Uuid, row_id: Uuid, physical_time: i64) -> AuditEvent {
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
        }
    }

    // ── §9.1 Round-trip identity (InMemory → InMemory) ──────────────────

    /// §9.1 — Fill source → flush to destination → verify projected-state equality.
    #[test]
    fn round_trip_identity_in_memory_to_in_memory() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        // Insert a live item row.
        let item_id = Uuid::new_v4();
        let mut item_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        item_values.insert("id".into(), TypedValue::Uuid(item_id));
        item_values.insert("adjective_bitmap".into(), TypedValue::Bitmap(0b0101));
        item_values.insert("payload".into(), TypedValue::Blob(vec![0xDE, 0xAD]));
        item_values.insert("tombstoned_at".into(), TypedValue::Null);
        source
            .row_store()
            .upsert("items", item_values, &["id".to_string()])
            .expect("upsert failed");

        // Insert an append-only event (composite PK).
        let topic_id = Uuid::new_v4();
        let hlc = HLC::new(1_000, 0, 1);
        let mut event_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        event_values.insert("topic_id".into(), TypedValue::Uuid(topic_id));
        event_values.insert("seq".into(), TypedValue::Int(1));
        event_values.insert("hlc_stamp".into(), TypedValue::Hlc(hlc));
        event_values.insert("content".into(), TypedValue::Text("first event".into()));
        source
            .row_store()
            .upsert(
                "events",
                event_values,
                &["topic_id".to_string(), "seq".to_string()],
            )
            .expect("upsert event failed");

        // Append an audit event.
        let audit_event = make_audit_event(estate_id, item_id, 1_000);
        source
            .audit_log()
            .append(audit_event.clone())
            .expect("audit append failed");

        // Flush to destination.
        let destination = make_storage(&schema);
        let cursor = flush(&source, &destination, &schema).expect("flush failed");

        assert_eq!(cursor.rows_written, 2); // 1 item + 1 event
        assert_eq!(cursor.audit_events_written, 1);
        assert!(cursor.hlc_watermark.is_some());

        // Verify items table.
        let dst_items = destination
            .row_store()
            .query("items", None, &[], None, None)
            .expect("query items failed");
        assert_eq!(dst_items.len(), 1);
        assert_eq!(dst_items[0].values.get("id"), Some(&TypedValue::Uuid(item_id)));
        assert_eq!(
            dst_items[0].values.get("adjective_bitmap"),
            Some(&TypedValue::Bitmap(0b0101))
        );
        assert_eq!(
            dst_items[0].values.get("payload"),
            Some(&TypedValue::Blob(vec![0xDE, 0xAD]))
        );

        // Generated column must be present and computed correctly.
        // state_cluster = 0b0101 & 0xF = 5
        assert_eq!(
            dst_items[0].values.get("state_cluster"),
            Some(&TypedValue::Int(5))
        );

        // Verify events table.
        let dst_events = destination
            .row_store()
            .query("events", None, &[], None, None)
            .expect("query events failed");
        assert_eq!(dst_events.len(), 1);
        assert_eq!(
            dst_events[0].values.get("topic_id"),
            Some(&TypedValue::Uuid(topic_id))
        );
        assert_eq!(dst_events[0].values.get("seq"), Some(&TypedValue::Int(1)));
        assert_eq!(
            dst_events[0].values.get("hlc_stamp"),
            Some(&TypedValue::Hlc(hlc))
        );
        assert_eq!(
            dst_events[0].values.get("content"),
            Some(&TypedValue::Text("first event".into()))
        );

        // Verify audit log.
        let dst_audit = destination
            .audit_log()
            .iterate(None, None, usize::MAX)
            .expect("iterate audit failed");
        assert_eq!(dst_audit.len(), 1);
        assert_eq!(dst_audit[0].event_id, audit_event.event_id);
    }

    // ── §9.2 Idempotence ─────────────────────────────────────────────────

    /// §9.2 — Second flush with no change must not create duplicate rows.
    #[test]
    fn idempotence_second_flush_writes_no_new_rows() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let estate_id = source.configuration().estate_id;
        let item_id = Uuid::new_v4();

        let mut item_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        item_values.insert("id".into(), TypedValue::Uuid(item_id));
        item_values.insert("adjective_bitmap".into(), TypedValue::Bitmap(0b1010));
        item_values.insert("payload".into(), TypedValue::Blob(vec![0xFF]));
        item_values.insert("tombstoned_at".into(), TypedValue::Null);
        source
            .row_store()
            .upsert("items", item_values, &["id".to_string()])
            .expect("upsert failed");

        let audit_event = make_audit_event(estate_id, item_id, 2_000);
        source
            .audit_log()
            .append(audit_event)
            .expect("audit append failed");

        let destination = make_storage(&schema);

        // First flush.
        let first = flush(&source, &destination, &schema).expect("first flush failed");
        assert_eq!(first.rows_written, 1);
        assert_eq!(first.audit_events_written, 1);

        // Second flush.
        let second = flush(&source, &destination, &schema).expect("second flush failed");
        assert_eq!(second.rows_written, 1); // primitive still touches 1 row

        // Destination must have exactly 1 row (not duplicated).
        let count = destination
            .row_store()
            .count("items", None)
            .expect("count failed");
        assert_eq!(count, 1, "second flush must not duplicate rows");

        let audit_count = destination
            .audit_log()
            .count()
            .expect("audit count failed");
        assert_eq!(audit_count, 1, "second flush must not duplicate audit events");
    }

    // ── §9.3 Atomicity ───────────────────────────────────────────────────

    /// §9.3 — Schema-gate failure throws before writing any rows.
    #[test]
    fn atomicity_schema_gate_failure_leaves_destination_unchanged() {
        let schema_v1 = synthetic_schema(); // version 1

        let wrong_schema = SchemaDeclaration {
            kit_id: schema_v1.kit_id.clone(),
            version: 99,
            tables: schema_v1.tables.clone(),
            indices: vec![],
            migrations: vec![],
        };

        let source = make_storage(&schema_v1);
        // Destination opened at a different version.
        let estate_id = Uuid::new_v4();
        let destination = InMemoryStorage::with_estate(estate_id);
        destination.open(&wrong_schema).expect("open wrong schema");

        // Insert a row in source.
        let item_id = Uuid::new_v4();
        let mut item_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        item_values.insert("id".into(), TypedValue::Uuid(item_id));
        item_values.insert("adjective_bitmap".into(), TypedValue::Bitmap(0));
        item_values.insert("payload".into(), TypedValue::Blob(vec![]));
        item_values.insert("tombstoned_at".into(), TypedValue::Null);
        source
            .row_store()
            .upsert("items", item_values, &["id".to_string()])
            .expect("upsert failed");

        let result = flush(&source, &destination, &schema_v1);
        assert!(
            matches!(result, Err(ReplicationError::SchemaMismatch { .. })),
            "expected SchemaMismatch, got {:?}",
            result
        );

        // Destination must have 0 audit events (audit table always present).
        let audit_count = destination.audit_log().count().expect("audit count");
        assert_eq!(
            audit_count,
            0,
            "destination must be empty after schema gate failure"
        );
    }

    // ── §9.4 Generated-column safety ──────────────────────────────────────

    /// §9.4 — The replication primitive must NOT write generated columns;
    /// destination computes them correctly from base columns.
    #[test]
    fn generated_column_not_written_destination_computes_correctly() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);

        // adjective_bitmap = 0b1101 → state_cluster = 0b1101 & 0xF = 13
        let adjective_bitmap: i64 = 0b1101;
        let expected_state_cluster: i64 = adjective_bitmap & 0xF;

        let item_id = Uuid::new_v4();
        let mut item_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        item_values.insert("id".into(), TypedValue::Uuid(item_id));
        item_values.insert(
            "adjective_bitmap".into(),
            TypedValue::Bitmap(adjective_bitmap),
        );
        item_values.insert("payload".into(), TypedValue::Blob(vec![0xCA, 0xFE]));
        item_values.insert("tombstoned_at".into(), TypedValue::Null);
        source
            .row_store()
            .upsert("items", item_values, &["id".to_string()])
            .expect("upsert failed");

        let destination = make_storage(&schema);
        flush(&source, &destination, &schema).expect("flush failed");

        let dst_rows = destination
            .row_store()
            .query("items", None, &[], None, None)
            .expect("query failed");
        assert_eq!(dst_rows.len(), 1);

        // Generated column must be present and computed correctly by destination.
        let state_cluster = dst_rows[0].values.get("state_cluster");
        assert_eq!(
            state_cluster,
            Some(&TypedValue::Int(expected_state_cluster)),
            "state_cluster should be {}, got {:?}",
            expected_state_cluster,
            state_cluster
        );
    }

    // ── §9 Hydrate convenience ────────────────────────────────────────────

    /// hydrate() is the inverse of flush(): it replicates from a durable
    /// source (here simulated with InMemory) into a fresh InMemory target.
    #[test]
    fn hydrate_mirrors_flush() {
        let schema = synthetic_schema();
        let durable = make_storage(&schema);
        let item_id = Uuid::new_v4();

        let mut item_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        item_values.insert("id".into(), TypedValue::Uuid(item_id));
        item_values.insert("adjective_bitmap".into(), TypedValue::Bitmap(0b1111));
        item_values.insert(
            "payload".into(),
            TypedValue::Blob(vec![0xAB, 0xCD, 0xEF]),
        );
        item_values.insert("tombstoned_at".into(), TypedValue::Null);
        durable
            .row_store()
            .upsert("items", item_values, &["id".to_string()])
            .expect("upsert failed");

        let restored = make_storage(&schema);
        let cursor = hydrate(&restored, &durable, &schema).expect("hydrate failed");

        assert_eq!(cursor.rows_written, 1);

        let restored_items = restored
            .row_store()
            .query("items", None, &[], None, None)
            .expect("query failed");
        assert_eq!(restored_items.len(), 1);
        assert_eq!(
            restored_items[0].values.get("id"),
            Some(&TypedValue::Uuid(item_id))
        );
    }

    // ── Schema gate ───────────────────────────────────────────────────────

    /// Schema gate rejects when versions differ.
    #[test]
    fn schema_gate_rejects_version_mismatch() {
        let schema_v1 = synthetic_schema();
        let mut schema_v2 = schema_v1.clone();
        schema_v2.version = 2;

        let source = make_storage(&schema_v1);
        let dest_v2 = InMemoryStorage::with_estate(Uuid::new_v4());
        dest_v2.open(&schema_v2).expect("open v2");

        let result = flush(&source, &dest_v2, &schema_v1);
        assert!(
            matches!(result, Err(ReplicationError::SchemaMismatch { .. })),
            "expected SchemaMismatch"
        );
    }

    /// Incremental mode returns NotImplemented.
    #[test]
    fn incremental_mode_not_implemented() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let dest = make_storage(&schema);
        let cursor = ReplicationCursor {
            hlc_watermark: None,
            rows_written: 0,
            audit_events_written: 0,
        };
        let result = replicate(
            &source,
            &dest,
            &schema,
            ReplicationMode::Incremental { cursor },
        );
        assert!(matches!(result, Err(ReplicationError::NotImplemented { .. })));
    }

    // ── Empty source ──────────────────────────────────────────────────────

    /// Empty source produces zero counts and nil watermark.
    #[test]
    fn empty_source_produces_empty_cursor() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let dest = make_storage(&schema);
        let cursor = flush(&source, &dest, &schema).expect("flush failed");
        assert_eq!(cursor.rows_written, 0);
        assert_eq!(cursor.audit_events_written, 0);
        assert_eq!(cursor.hlc_watermark, None);
    }

    // ── HLC watermark ─────────────────────────────────────────────────────

    /// The watermark must be the maximum HLC across rows and audit events.
    #[test]
    fn hlc_watermark_tracks_maximum() {
        let schema = synthetic_schema();
        let source = make_storage(&schema);
        let estate_id = source.configuration().estate_id;

        let topic_id = Uuid::new_v4();
        // Insert events with known HLCs.
        let hlc_low = HLC::new(100, 0, 0);
        let hlc_high = HLC::new(500, 0, 0);

        let mut ev1: BTreeMap<String, TypedValue> = BTreeMap::new();
        ev1.insert("topic_id".into(), TypedValue::Uuid(topic_id));
        ev1.insert("seq".into(), TypedValue::Int(1));
        ev1.insert("hlc_stamp".into(), TypedValue::Hlc(hlc_low));
        ev1.insert("content".into(), TypedValue::Text("a".into()));
        source
            .row_store()
            .upsert(
                "events",
                ev1,
                &["topic_id".to_string(), "seq".to_string()],
            )
            .unwrap();

        let mut ev2: BTreeMap<String, TypedValue> = BTreeMap::new();
        ev2.insert("topic_id".into(), TypedValue::Uuid(topic_id));
        ev2.insert("seq".into(), TypedValue::Int(2));
        ev2.insert("hlc_stamp".into(), TypedValue::Hlc(hlc_high));
        ev2.insert("content".into(), TypedValue::Text("b".into()));
        source
            .row_store()
            .upsert(
                "events",
                ev2,
                &["topic_id".to_string(), "seq".to_string()],
            )
            .unwrap();

        // Audit event with an even higher HLC.
        let hlc_audit_max = HLC::new(2_000, 0, 0);
        let audit_event = make_audit_event(estate_id, Uuid::new_v4(), 2_000);
        // Inject the known-high HLC directly since make_audit_event uses fixed times.
        let audit_event_high = AuditEvent {
            hlc: hlc_audit_max,
            ..audit_event
        };
        source.audit_log().append(audit_event_high).unwrap();

        let dest = make_storage(&schema);
        let cursor = flush(&source, &dest, &schema).unwrap();

        assert_eq!(cursor.hlc_watermark, Some(hlc_audit_max));
    }
}
