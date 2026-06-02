//! PostgreSQL backend — the Rust version of the Swift `PersistenceKitPostgreSQL`
//! target, over the synchronous `postgres` crate (matching the sync Storage
//! trait). One `Client` per estate behind a `Mutex` (a real shared DB
//! handle). Schema DDL, predicate compilation, and the value codec match the
//! Swift backend so both versions produce identical observable results.
//!
//! NOTE: this backend is **unverified locally** — its conformance test only
//! runs when `PERSISTENCEKIT_PG_URL` points at a live PostgreSQL server;
//! without one it is skipped. Phase 1 implements RowStore, BlobStore,
//! AuditLog, StorageObserver + schema/generated-STORED-columns/append-only.
//! VectorIndex is a placeholder pending the follow-on. A single connection
//! is used; the configured `pool_size` is accepted but not yet pooled.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use postgres::types::ToSql;
use postgres::{Client, NoTls};
use substrate_types::hlc::HLC;
use uuid::Uuid;

use crate::{
    AuditEvent, AuditLog, BackendConfiguration, BlobStore, ColumnType, DistanceMetric,
    EstateConfiguration, IndexDeclaration, IndexParameters, IsolationLevel, OrderClause,
    OrderDirection, RowHandle, RowKey, RowStore, SchemaDeclaration, SearchParameters, Storage,
    StorageError, StorageEvent, StorageObserver, StoragePredicate, StorageResult, StorageRow,
    StorageTransaction, TableChange, TableDeclaration, TypedValue, VectorIndex, VectorSearchResult,
};

// ─────────────────────────────────────────────────────────────────────
// Value codec — TypedValue -> boxed postgres parameter. Native PG types
// (UUID, TIMESTAMPTZ, BOOLEAN) bind from uuid::Uuid / DateTime<Utc> / bool.
// ─────────────────────────────────────────────────────────────────────

type PgParam = Box<dyn ToSql + Sync>;

fn to_param(v: &TypedValue) -> PgParam {
    match v {
        TypedValue::Null => Box::new(Option::<i64>::None),
        TypedValue::Bool(b) => Box::new(*b),
        TypedValue::Int(i) => Box::new(*i),
        TypedValue::Bitmap(i) => Box::new(*i),
        TypedValue::Float(f) => Box::new(*f),
        TypedValue::Text(s) => Box::new(s.clone()),
        TypedValue::Blob(b) => Box::new(b.clone()),
        TypedValue::Json(b) => Box::new(b.clone()),
        TypedValue::Uuid(u) => Box::new(*u),
        TypedValue::Timestamp(secs) => Box::new(
            DateTime::<Utc>::from_timestamp(*secs, 0)
                .unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap()),
        ),
        TypedValue::Hlc(h) => Box::new(h.packed() as i64),
        // Not exercised by Phase-1 conformance.
        TypedValue::Fingerprint(_) | TypedValue::Array(_) => Box::new(Option::<i64>::None),
    }
}

fn param_refs(params: &[PgParam]) -> Vec<&(dyn ToSql + Sync)> {
    params.iter().map(|p| p.as_ref()).collect()
}

fn native_type(t: ColumnType) -> &'static str {
    match t {
        ColumnType::Uuid => "UUID",
        ColumnType::Bitmap | ColumnType::Int | ColumnType::Hlc => "BIGINT",
        ColumnType::Text => "TEXT",
        ColumnType::Timestamp => "TIMESTAMPTZ",
        ColumnType::Float => "DOUBLE PRECISION",
        ColumnType::Bool => "BOOLEAN",
        ColumnType::Blob | ColumnType::Fingerprint => "BYTEA",
        ColumnType::Json => "JSONB",
    }
}

fn unpack_hlc(packed: u64) -> HLC {
    HLC {
        physical_time: ((packed >> 16) & 0xFFFF_FFFF_FFFF) as i64,
        logical_count: ((packed >> 4) & 0xFFF) as i32,
        node_id: (packed & 0xF) as i32,
    }
}

/// Decode one column of a result row into a TypedValue using the declared
/// ColumnType (which drives the native Rust getter type).
fn read_value(row: &postgres::Row, idx: usize, kit: Option<ColumnType>) -> TypedValue {
    match kit {
        Some(ColumnType::Uuid) => row
            .try_get::<_, Option<Uuid>>(idx)
            .ok()
            .flatten()
            .map(TypedValue::Uuid)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Timestamp) => row
            .try_get::<_, Option<DateTime<Utc>>>(idx)
            .ok()
            .flatten()
            .map(|dt| TypedValue::Timestamp(dt.timestamp()))
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Bool) => row
            .try_get::<_, Option<bool>>(idx)
            .ok()
            .flatten()
            .map(TypedValue::Bool)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Float) => row
            .try_get::<_, Option<f64>>(idx)
            .ok()
            .flatten()
            .map(TypedValue::Float)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Text) => row
            .try_get::<_, Option<String>>(idx)
            .ok()
            .flatten()
            .map(TypedValue::Text)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Blob) | Some(ColumnType::Json) | Some(ColumnType::Fingerprint) => row
            .try_get::<_, Option<Vec<u8>>>(idx)
            .ok()
            .flatten()
            .map(TypedValue::Blob)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Bitmap) => int_col(row, idx)
            .map(TypedValue::Bitmap)
            .unwrap_or(TypedValue::Null),
        Some(ColumnType::Hlc) => int_col(row, idx)
            .map(|i| TypedValue::Hlc(unpack_hlc(i as u64)))
            .unwrap_or(TypedValue::Null),
        // Default (Int or unknown): read as BIGINT.
        _ => int_col(row, idx)
            .map(TypedValue::Int)
            .unwrap_or(TypedValue::Null),
    }
}

fn int_col(row: &postgres::Row, idx: usize) -> Option<i64> {
    row.try_get::<_, Option<i64>>(idx).ok().flatten()
}

/// tokio-postgres `Error`'s Display is only the error *kind* ("db error");
/// the SQLSTATE message lives on the DbError. Extract it so callers can
/// match on it (append-only / unique) and surface a useful message.
fn pg_err_text(e: &postgres::Error) -> String {
    match e.as_db_error() {
        Some(db) => db.message().to_string(),
        None => e.to_string(),
    }
}

fn map_pg_err(e: postgres::Error, table: &str) -> StorageError {
    let msg = pg_err_text(&e);
    if msg.contains("append-only") {
        StorageError::AppendOnlyViolation {
            table: table.to_string(),
        }
    } else if msg.contains("duplicate key") || msg.contains("unique constraint") {
        StorageError::DuplicateKey {
            table: table.to_string(),
            key: "(unique constraint)".into(),
        }
    } else {
        StorageError::BackendError { underlying: msg }
    }
}

// ─────────────────────────────────────────────────────────────────────
// DDL — mirrors PostgreSQLSchema.swift.
// ─────────────────────────────────────────────────────────────────────

const META_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_meta" (
  "key" TEXT PRIMARY KEY,
  "value" TEXT NOT NULL
)"#;

const BLOB_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_blobs" (
  "key" TEXT PRIMARY KEY NOT NULL,
  "bytes" BYTEA NOT NULL
)"#;

const AUDIT_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_audit" (
  "event_id" TEXT NOT NULL,
  "hlc" BIGINT NOT NULL,
  "physical_time" BIGINT NOT NULL,
  "logical_count" BIGINT NOT NULL,
  "node_id" BIGINT NOT NULL,
  "estate_uuid" TEXT NOT NULL,
  "row_id" TEXT NOT NULL,
  "verb" TEXT NOT NULL,
  "before_adjective" BIGINT,
  "before_operational" BIGINT,
  "before_provenance" BIGINT,
  "after_adjective" BIGINT NOT NULL,
  "after_operational" BIGINT NOT NULL,
  "after_provenance" BIGINT NOT NULL,
  "before_lattice_anchor" BIGINT,
  "after_lattice_anchor" BIGINT NOT NULL,
  "actor" TEXT NOT NULL,
  PRIMARY KEY ("event_id", "hlc")
)"#;

const AUDIT_INDEX: &str = r#"CREATE INDEX IF NOT EXISTS "_storagekit_audit_row_hlc" ON "_storagekit_audit" ("row_id", "hlc")"#;

const REJECT_MUTATION_FN: &str = r#"CREATE OR REPLACE FUNCTION "_storagekit_reject_mutation"()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql"#;

fn create_table_sql(decl: &TableDeclaration) -> String {
    let mut parts: Vec<String> = Vec::new();
    for col in &decl.columns {
        let mut line = format!("\"{}\" {}", col.name, native_type(col.column_type));
        if !col.nullable {
            line.push_str(" NOT NULL");
        }
        parts.push(line);
    }
    for gen in &decl.generated_columns {
        // render_sql emits an integer expression (booleans as 0/1, shared
        // with InMemory/SQLite). A Bool-typed generated column maps to PG
        // BOOLEAN, which won't accept an integer default — cast it.
        let expr = gen.expression.render_sql();
        let expr = if matches!(gen.column_type, ColumnType::Bool) {
            format!("({expr})::boolean")
        } else {
            expr
        };
        parts.push(format!(
            "\"{}\" {} GENERATED ALWAYS AS ({}) STORED",
            gen.name,
            native_type(gen.column_type),
            expr
        ));
    }
    if !decl.primary_key.is_empty() {
        let cols = decl
            .primary_key
            .iter()
            .map(|c| format!("\"{c}\""))
            .collect::<Vec<_>>()
            .join(", ");
        parts.push(format!("PRIMARY KEY ({cols})"));
    }
    for unique in &decl.unique_constraints {
        let cols = unique
            .iter()
            .map(|c| format!("\"{c}\""))
            .collect::<Vec<_>>()
            .join(", ");
        parts.push(format!("UNIQUE ({cols})"));
    }
    format!(
        "CREATE TABLE IF NOT EXISTS \"{}\" (\n  {}\n)",
        decl.name,
        parts.join(",\n  ")
    )
}

fn append_only_trigger_statements(decl: &TableDeclaration) -> Vec<String> {
    if !decl.append_only {
        return Vec::new();
    }
    let t = &decl.name;
    let name = format!("trg_{t}_append_only");
    vec![
        format!("DROP TRIGGER IF EXISTS \"{name}\" ON \"{t}\""),
        format!(
            "CREATE TRIGGER \"{name}\" BEFORE UPDATE OR DELETE ON \"{t}\" \
             FOR EACH ROW EXECUTE FUNCTION \"_storagekit_reject_mutation\"()"
        ),
    ]
}

fn create_index_sql(decl: &IndexDeclaration) -> String {
    let unique = if decl.unique { "UNIQUE " } else { "" };
    let cols = decl
        .columns
        .iter()
        .map(|c| format!("\"{c}\""))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "CREATE {unique}INDEX IF NOT EXISTS \"{}\" ON \"{}\" ({cols})",
        decl.name, decl.table
    )
}

// ─────────────────────────────────────────────────────────────────────
// Predicate compilation — PostgreSQL $N placeholders.
// ─────────────────────────────────────────────────────────────────────

fn compile_predicate(p: &StoragePredicate, binds: &mut Vec<TypedValue>) -> String {
    // Each pushed bind takes the next positional placeholder ($len).
    match p {
        StoragePredicate::IsTrue => "TRUE".into(),
        StoragePredicate::IsFalse => "FALSE".into(),
        StoragePredicate::And(preds) => {
            if preds.is_empty() {
                return "TRUE".into();
            }
            format!(
                "({})",
                preds
                    .iter()
                    .map(|x| compile_predicate(x, binds))
                    .collect::<Vec<_>>()
                    .join(" AND ")
            )
        }
        StoragePredicate::Or(preds) => {
            if preds.is_empty() {
                return "FALSE".into();
            }
            format!(
                "({})",
                preds
                    .iter()
                    .map(|x| compile_predicate(x, binds))
                    .collect::<Vec<_>>()
                    .join(" OR ")
            )
        }
        StoragePredicate::Not(inner) => format!("NOT ({})", compile_predicate(inner, binds)),
        StoragePredicate::Eq(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" = ${}", c.name, binds.len())
        }
        StoragePredicate::Neq(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" != ${}", c.name, binds.len())
        }
        StoragePredicate::Lt(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" < ${}", c.name, binds.len())
        }
        StoragePredicate::Lte(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" <= ${}", c.name, binds.len())
        }
        StoragePredicate::Gt(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" > ${}", c.name, binds.len())
        }
        StoragePredicate::Gte(c, v) => {
            binds.push(v.clone());
            format!("\"{}\" >= ${}", c.name, binds.len())
        }
        StoragePredicate::IsNull(c) => format!("\"{}\" IS NULL", c.name),
        StoragePredicate::IsNotNull(c) => format!("\"{}\" IS NOT NULL", c.name),
        StoragePredicate::In(c, values) => {
            if values.is_empty() {
                return "FALSE".into();
            }
            let ph = values
                .iter()
                .map(|v| {
                    binds.push(v.clone());
                    format!("${}", binds.len())
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!("\"{}\" IN ({ph})", c.name)
        }
        StoragePredicate::Like(c, pattern) => {
            binds.push(TypedValue::Text(pattern.clone()));
            format!("\"{}\" LIKE ${}", c.name, binds.len())
        }
        StoragePredicate::BitmaskAll { column, mask } => {
            binds.push(TypedValue::Int(*mask));
            let a = binds.len();
            binds.push(TypedValue::Int(*mask));
            format!("(\"{}\" & ${a}) = ${}", column.name, binds.len())
        }
        StoragePredicate::BitmaskAny { column, mask } => {
            binds.push(TypedValue::Int(*mask));
            format!("(\"{}\" & ${}) != 0", column.name, binds.len())
        }
        StoragePredicate::BitmaskNone { column, mask } => {
            binds.push(TypedValue::Int(*mask));
            format!("(\"{}\" & ${}) = 0", column.name, binds.len())
        }
        StoragePredicate::BitwiseEq {
            column,
            expected,
            mask,
        } => {
            binds.push(TypedValue::Int(*mask));
            let a = binds.len();
            binds.push(TypedValue::Int(*expected));
            format!("(\"{}\" & ${a}) = ${}", column.name, binds.len())
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Observer registry (same shape as the SQLite backend).
// ─────────────────────────────────────────────────────────────────────

#[derive(Default)]
struct ObserverRegistry {
    subs: Mutex<Vec<Subscription>>,
}

struct Subscription {
    table: String,
    events: BTreeSet<StorageEvent>,
    tx: Sender<TableChange>,
}

impl ObserverRegistry {
    fn observe(&self, table: &str, events: BTreeSet<StorageEvent>) -> Receiver<TableChange> {
        let (tx, rx) = channel();
        self.subs.lock().unwrap().push(Subscription {
            table: table.to_string(),
            events,
            tx,
        });
        rx
    }
    fn emit(&self, change: &TableChange) {
        self.subs.lock().unwrap().retain(|s| {
            if s.table == change.table && s.events.contains(&change.event) {
                s.tx.send(change.clone()).is_ok()
            } else {
                true
            }
        });
    }
}

// ─────────────────────────────────────────────────────────────────────
// Storage assembly.
// ─────────────────────────────────────────────────────────────────────

struct Inner {
    client: Client,
    schema: Option<SchemaDeclaration>,
}

pub struct PostgresStorage {
    config: EstateConfiguration,
    inner: Arc<Mutex<Inner>>,
    observers: Arc<ObserverRegistry>,
}

impl PostgresStorage {
    /// Connect to the PostgreSQL server named by the configuration's
    /// `Postgresql` backend variant. (Single connection at Phase 1.)
    pub fn new(config: EstateConfiguration) -> StorageResult<Self> {
        let conn_str = match &config.backend {
            BackendConfiguration::Postgresql {
                connection_string, ..
            } => connection_string.clone(),
            _ => {
                return Err(StorageError::BackendError {
                    underlying: "PostgresStorage requires a Postgresql backend configuration"
                        .into(),
                })
            }
        };
        let mut client =
            Client::connect(&conn_str, NoTls).map_err(|e| StorageError::BackendError {
                underlying: format!("postgres connect: {e}"),
            })?;
        // Estate isolation: each estate lives in its own schema (the PG
        // analogue of SQLite's one-file-per-estate). The connection's
        // search_path is pinned to it for this storage's lifetime, so a
        // shared database holds many estates without table collisions.
        // `public` stays on the path so shared extensions (e.g. pgvector)
        // resolve.
        let ns = format!("pk_{}", config.estate_id.simple());
        client
            .batch_execute(&format!(
                "CREATE SCHEMA IF NOT EXISTS \"{ns}\"; SET search_path TO \"{ns}\", public;"
            ))
            .map_err(|e| StorageError::BackendError {
                underlying: format!("schema setup: {e}"),
            })?;
        Ok(PostgresStorage {
            config,
            inner: Arc::new(Mutex::new(Inner {
                client,
                schema: None,
            })),
            observers: Arc::new(ObserverRegistry::default()),
        })
    }
}

fn apply_schema(inner: &mut Inner, schema: &SchemaDeclaration) -> StorageResult<()> {
    inner.schema = Some(schema.clone());
    let batch = |c: &mut Client, sql: &str| {
        c.batch_execute(sql)
            .map_err(|e| StorageError::BackendError {
                underlying: format!("ddl: {}", pg_err_text(&e)),
            })
    };
    batch(&mut inner.client, META_TABLE)?;
    batch(&mut inner.client, AUDIT_TABLE)?;
    batch(&mut inner.client, AUDIT_INDEX)?;
    batch(&mut inner.client, BLOB_TABLE)?;
    batch(&mut inner.client, REJECT_MUTATION_FN)?;
    for table in &schema.tables {
        batch(&mut inner.client, &create_table_sql(table))?;
        for stmt in append_only_trigger_statements(table) {
            batch(&mut inner.client, &stmt)?;
        }
    }
    for index in &schema.indices {
        batch(&mut inner.client, &create_index_sql(index))?;
    }
    inner
        .client
        .execute(
            r#"INSERT INTO "_storagekit_meta" ("key", "value") VALUES ('schema_version', $1)
               ON CONFLICT ("key") DO UPDATE SET "value" = excluded.value"#,
            &[&schema.version.to_string()],
        )
        .map_err(|e| StorageError::BackendError {
            underlying: format!("record version: {e}"),
        })?;
    Ok(())
}

impl Storage for PostgresStorage {
    fn configuration(&self) -> &EstateConfiguration {
        &self.config
    }
    fn row_store(&self) -> Arc<dyn RowStore> {
        Arc::new(PgRowStore {
            inner: self.inner.clone(),
            observers: self.observers.clone(),
        })
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(PgBlobStore {
            inner: self.inner.clone(),
        })
    }
    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Arc::new(PgVectorIndex {
            inner: self.inner.clone(),
        })
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Arc::new(PgAuditLog {
            inner: self.inner.clone(),
        })
    }
    fn observer(&self) -> Arc<dyn StorageObserver> {
        Arc::new(PgObserver {
            observers: self.observers.clone(),
        })
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        apply_schema(&mut self.inner.lock().unwrap(), schema)
    }
    fn close(&self) -> StorageResult<()> {
        Ok(())
    }
    fn current_schema_version(&self) -> StorageResult<i32> {
        let mut guard = self.inner.lock().unwrap();
        let rows = guard
            .client
            .query(
                r#"SELECT "value" FROM "_storagekit_meta" WHERE "key" = 'schema_version'"#,
                &[],
            )
            .map_err(|e| StorageError::BackendError {
                underlying: format!("schema version: {e}"),
            })?;
        Ok(rows
            .first()
            .and_then(|r| r.try_get::<_, String>(0).ok())
            .and_then(|s| s.parse::<i32>().ok())
            .unwrap_or(0))
    }
    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        apply_schema(&mut self.inner.lock().unwrap(), schema)
    }

    fn transaction(
        &self,
        isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        // The single pooled connection serializes all sub-store access, so the
        // BEGIN…COMMIT bracket here and the block's per-call statements run on
        // the same session in order. The `inner` lock is held only to issue
        // each bracket statement and released before the block runs — the
        // block's sub-stores re-lock per call, so holding it across `block`
        // would deadlock against them.
        let begin = match isolation {
            IsolationLevel::ReadCommitted => "BEGIN ISOLATION LEVEL READ COMMITTED",
            IsolationLevel::RepeatableRead => "BEGIN ISOLATION LEVEL REPEATABLE READ",
            IsolationLevel::Serializable => "BEGIN ISOLATION LEVEL SERIALIZABLE",
        };
        self.inner
            .lock()
            .unwrap()
            .client
            .batch_execute(begin)
            .map_err(|e| map_pg_err(e, "transaction"))?;
        match block(self) {
            Ok(()) => {
                self.inner
                    .lock()
                    .unwrap()
                    .client
                    .batch_execute("COMMIT")
                    .map_err(|e| map_pg_err(e, "transaction"))?;
                Ok(())
            }
            Err(e) => {
                // Best-effort rollback; surface the block's error regardless.
                let _ = self.inner.lock().unwrap().client.batch_execute("ROLLBACK");
                Err(e)
            }
        }
    }
}

impl StorageTransaction for PostgresStorage {
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

// ─────────────────────────────────────────────────────────────────────
// RowStore.
// ─────────────────────────────────────────────────────────────────────

struct PgRowStore {
    inner: Arc<Mutex<Inner>>,
    observers: Arc<ObserverRegistry>,
}

fn extract_row_key(
    schema: Option<&SchemaDeclaration>,
    table: &str,
    values: &BTreeMap<String, TypedValue>,
) -> RowKey {
    if let Some(decl) = schema.and_then(|s| s.tables.iter().find(|t| t.name == table)) {
        if decl.primary_key.len() == 1 {
            if let Some(TypedValue::Uuid(u)) = values.get(&decl.primary_key[0]) {
                return *u;
            }
        }
    }
    Uuid::new_v4()
}

fn table_column_type(
    schema: Option<&SchemaDeclaration>,
    table: &str,
    column: &str,
) -> Option<ColumnType> {
    let decl = schema?.tables.iter().find(|t| t.name == table)?;
    decl.columns
        .iter()
        .find(|c| c.name == column)
        .map(|c| c.column_type)
        .or_else(|| {
            decl.generated_columns
                .iter()
                .find(|g| g.name == column)
                .map(|g| g.column_type)
        })
}

impl RowStore for PgRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let mut guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let cols = keys
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let ph = (1..=keys.len())
            .map(|i| format!("${i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!("INSERT INTO \"{table}\" ({cols}) VALUES ({ph})");
        let params: Vec<PgParam> = keys.iter().map(|k| to_param(&values[*k])).collect();
        guard
            .client
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let key = extract_row_key(guard.schema.as_ref(), table, &values);
        self.observers.emit(&TableChange {
            table: table.to_string(),
            event: StorageEvent::Insert,
            row_key: Some(key),
            values: Some(values),
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
        let mut guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let cols = keys
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let ph = (1..=keys.len())
            .map(|i| format!("${i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut sql = format!("INSERT INTO \"{table}\" ({cols}) VALUES ({ph})");
        if !conflict_columns.is_empty() {
            let conflict = conflict_columns
                .iter()
                .map(|c| format!("\"{c}\""))
                .collect::<Vec<_>>()
                .join(", ");
            let updates: Vec<String> = keys
                .iter()
                .filter(|k| !conflict_columns.contains(k))
                .map(|k| format!("\"{k}\" = excluded.\"{k}\""))
                .collect();
            sql.push_str(&format!(" ON CONFLICT ({conflict})"));
            if updates.is_empty() {
                sql.push_str(" DO NOTHING");
            } else {
                sql.push_str(&format!(" DO UPDATE SET {}", updates.join(", ")));
            }
        }
        let params: Vec<PgParam> = keys.iter().map(|k| to_param(&values[*k])).collect();
        guard
            .client
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let key = extract_row_key(guard.schema.as_ref(), table, &values);
        self.observers.emit(&TableChange {
            table: table.to_string(),
            event: StorageEvent::Update,
            row_key: Some(key),
            values: Some(values),
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
        let mut guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let mut binds: Vec<TypedValue> = Vec::new();
        let set_clause = keys
            .iter()
            .map(|k| {
                binds.push(values[*k].clone());
                format!("\"{k}\" = ${}", binds.len())
            })
            .collect::<Vec<_>>()
            .join(", ");
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("UPDATE \"{table}\" SET {set_clause} WHERE {where_sql}");
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let changed = guard
            .client
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        if changed > 0 {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Update,
                row_key: None,
                values: None,
                hlc: None,
            });
        }
        Ok(changed as usize)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let mut guard = self.inner.lock().unwrap();
        let mut binds: Vec<TypedValue> = Vec::new();
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("DELETE FROM \"{table}\" WHERE {where_sql}");
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let changed = guard
            .client
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        if changed > 0 {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Delete,
                row_key: None,
                values: None,
                hlc: None,
            });
        }
        Ok(changed as usize)
    }

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        let mut guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT * FROM \"{table}\"");
        let mut binds: Vec<TypedValue> = Vec::new();
        if let Some(p) = predicate {
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)));
        }
        if !order_by.is_empty() {
            let parts: Vec<String> = order_by
                .iter()
                .map(|c| {
                    let dir = match c.direction {
                        OrderDirection::Ascending => "ASC",
                        OrderDirection::Descending => "DESC",
                    };
                    format!("\"{}\" {dir}", c.column.name)
                })
                .collect();
            sql.push_str(&format!(" ORDER BY {}", parts.join(", ")));
        }
        if let Some(l) = limit {
            sql.push_str(&format!(" LIMIT {l}"));
        }
        if let Some(o) = offset {
            if o > 0 {
                sql.push_str(&format!(" OFFSET {o}"));
            }
        }
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let schema = guard.schema.clone();
        let rows = guard
            .client
            .query(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            for (i, col) in row.columns().iter().enumerate() {
                let name = col.name().to_string();
                let kit = table_column_type(schema.as_ref(), table, &name);
                values.insert(name, read_value(row, i, kit));
            }
            out.push(StorageRow::new(values));
        }
        Ok(out)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        let mut guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        let mut binds: Vec<TypedValue> = Vec::new();
        if let Some(p) = predicate {
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)));
        }
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let row = guard
            .client
            .query_one(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let n: i64 = row.get(0);
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// BlobStore.
// ─────────────────────────────────────────────────────────────────────

struct PgBlobStore {
    inner: Arc<Mutex<Inner>>,
}

impl BlobStore for PgBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        let mut guard = self.inner.lock().unwrap();
        guard
            .client
            .execute(
                r#"INSERT INTO "_storagekit_blobs" ("key", "bytes") VALUES ($1, $2)
                   ON CONFLICT ("key") DO UPDATE SET "bytes" = excluded.bytes"#,
                &[&key.to_string(), &bytes.to_vec()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        let mut guard = self.inner.lock().unwrap();
        let rows = guard
            .client
            .query(
                r#"SELECT "bytes" FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, Vec<u8>>(0)))
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        let mut guard = self.inner.lock().unwrap();
        guard
            .client
            .execute(
                r#"DELETE FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn exists(&self, key: &str) -> StorageResult<bool> {
        Ok(self.size(key)?.is_some())
    }
    fn size(&self, key: &str) -> StorageResult<Option<usize>> {
        let mut guard = self.inner.lock().unwrap();
        let rows = guard
            .client
            .query(
                r#"SELECT LENGTH("bytes") FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, i32>(0) as usize))
    }
}

// ─────────────────────────────────────────────────────────────────────
// AuditLog.
// ─────────────────────────────────────────────────────────────────────

struct PgAuditLog {
    inner: Arc<Mutex<Inner>>,
}

const AUDIT_COLS: &str = r#""event_id","hlc","physical_time","logical_count","node_id","estate_uuid","row_id","verb","before_adjective","before_operational","before_provenance","after_adjective","after_operational","after_provenance","before_lattice_anchor","after_lattice_anchor","actor""#;

fn audit_params(e: &AuditEvent) -> Vec<PgParam> {
    vec![
        Box::new(e.event_id.to_string().to_uppercase()),
        Box::new(e.hlc.packed() as i64),
        Box::new(e.hlc.physical_time),
        Box::new(e.hlc.logical_count as i64),
        Box::new(e.hlc.node_id as i64),
        Box::new(e.estate_uuid.to_string().to_uppercase()),
        Box::new(e.row_id.to_string().to_uppercase()),
        Box::new(e.verb.clone()),
        Box::new(e.before_adjective),
        Box::new(e.before_operational),
        Box::new(e.before_provenance),
        Box::new(e.after_adjective),
        Box::new(e.after_operational),
        Box::new(e.after_provenance),
        Box::new(e.before_lattice_anchor.map(|v| v as i64)),
        Box::new(e.after_lattice_anchor as i64),
        Box::new(e.actor.clone()),
    ]
}

fn decode_audit(row: &postgres::Row) -> AuditEvent {
    let parse_uuid = |s: String| Uuid::parse_str(&s).unwrap_or(Uuid::nil());
    AuditEvent {
        event_id: parse_uuid(row.get::<_, String>(0)),
        hlc: HLC {
            physical_time: row.get::<_, i64>(2),
            logical_count: row.get::<_, i64>(3) as i32,
            node_id: row.get::<_, i64>(4) as i32,
        },
        estate_uuid: parse_uuid(row.get::<_, String>(5)),
        row_id: parse_uuid(row.get::<_, String>(6)),
        verb: row.get(7),
        before_adjective: row.get(8),
        before_operational: row.get(9),
        before_provenance: row.get(10),
        after_adjective: row.get(11),
        after_operational: row.get(12),
        after_provenance: row.get(13),
        before_lattice_anchor: row.get::<_, Option<i64>>(14).map(|v| v as u64),
        after_lattice_anchor: row.get::<_, i64>(15) as u64,
        actor: row.get(16),
    }
}

impl AuditLog for PgAuditLog {
    fn append(&self, event: AuditEvent) -> StorageResult<()> {
        let mut guard = self.inner.lock().unwrap();
        let ph = (1..=17)
            .map(|i| format!("${i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "INSERT INTO \"_storagekit_audit\" ({AUDIT_COLS}) VALUES ({ph}) ON CONFLICT (\"event_id\",\"hlc\") DO NOTHING"
        );
        let params = audit_params(&event);
        guard
            .client
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(())
    }
    fn append_batch(&self, events: Vec<AuditEvent>) -> StorageResult<()> {
        for e in events {
            self.append(e)?;
        }
        Ok(())
    }
    fn iterate(
        &self,
        after: Option<HLC>,
        row_id: Option<RowKey>,
        limit: usize,
    ) -> StorageResult<Vec<AuditEvent>> {
        let mut guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT {AUDIT_COLS} FROM \"_storagekit_audit\"");
        let mut binds: Vec<PgParam> = Vec::new();
        let mut clauses: Vec<String> = Vec::new();
        if let Some(h) = after {
            binds.push(Box::new(h.packed() as i64));
            clauses.push(format!("\"hlc\" > ${}", binds.len()));
        }
        if let Some(r) = row_id {
            binds.push(Box::new(r.to_string().to_uppercase()));
            clauses.push(format!("\"row_id\" = ${}", binds.len()));
        }
        if !clauses.is_empty() {
            sql.push_str(&format!(" WHERE {}", clauses.join(" AND ")));
        }
        let lim: i64 = if limit > i64::MAX as usize {
            -1
        } else {
            limit as i64
        };
        if lim >= 0 {
            sql.push_str(&format!(" ORDER BY \"hlc\" ASC LIMIT {lim}"));
        } else {
            sql.push_str(" ORDER BY \"hlc\" ASC");
        }
        let rows = guard
            .client
            .query(&sql, &param_refs(&binds))
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(rows.iter().map(decode_audit).collect())
    }
    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>> {
        self.iterate(None, Some(row_id), usize::MAX)
    }
    fn count(&self) -> StorageResult<usize> {
        let mut guard = self.inner.lock().unwrap();
        let row = guard
            .client
            .query_one(r#"SELECT COUNT(*) FROM "_storagekit_audit""#, &[])
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(row.get::<_, i64>(0) as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// StorageObserver.
// ─────────────────────────────────────────────────────────────────────

struct PgObserver {
    observers: Arc<ObserverRegistry>,
}

impl StorageObserver for PgObserver {
    fn observe(
        &self,
        table: &str,
        events: BTreeSet<StorageEvent>,
    ) -> StorageResult<Receiver<TableChange>> {
        Ok(self.observers.observe(table, events))
    }
}

// ─────────────────────────────────────────────────────────────────────
// VectorIndex — pgvector-backed. Lazily creates "_storagekit_vectors" on
// first add (dimension fixed from the first vector), mirroring the Swift
// PostgreSQLVectorIndex. Vectors bind as text cast to `::vector`, so no
// pgvector client crate is needed. The `vector` extension must already be
// installed in the database (a DB-admin step; not created per-call since a
// least-privilege role may lack CREATE EXTENSION). Lives in the estate's
// schema via the connection search_path.
// ─────────────────────────────────────────────────────────────────────

struct PgVectorIndex {
    inner: Arc<Mutex<Inner>>,
}

const VEC_TABLE: &str = "_storagekit_vectors";

fn vector_literal(v: &[f32]) -> String {
    format!(
        "[{}]",
        v.iter()
            .map(|x| x.to_string())
            .collect::<Vec<_>>()
            .join(",")
    )
}

fn metric_op(m: DistanceMetric) -> &'static str {
    match m {
        DistanceMetric::Cosine => "<=>",
        DistanceMetric::L2 => "<->",
        DistanceMetric::Dot => "<#>",
    }
}

impl PgVectorIndex {
    fn table_exists(client: &mut Client) -> bool {
        client
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&VEC_TABLE])
            .ok()
            .and_then(|r| r.try_get::<_, bool>(0).ok())
            .unwrap_or(false)
    }
}

impl VectorIndex for PgVectorIndex {
    fn add(
        &self,
        key: RowKey,
        vector: &[f32],
        _metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()> {
        let mut guard = self.inner.lock().unwrap();
        let dim = vector.len();
        guard.client.batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS \"{VEC_TABLE}\" (\"key\" TEXT PRIMARY KEY, \"embedding\" vector({dim}) NOT NULL, \"metadata_json\" TEXT NOT NULL DEFAULT '{{}}')"
        )).map_err(|e| map_pg_err(e, VEC_TABLE))?;
        // Inline the vector literal (digits/dots/commas only — safe): a bound
        // `$n::vector` makes PG infer the param as type `vector`, which the
        // text-based client can't serialize.
        guard
            .client
            .execute(
                &format!(
                "INSERT INTO \"{VEC_TABLE}\" (\"key\", \"embedding\") VALUES ($1, '{}'::vector) \
                 ON CONFLICT (\"key\") DO UPDATE SET \"embedding\" = excluded.embedding",
                vector_literal(vector)
            ),
                &[&key.to_string().to_uppercase()],
            )
            .map_err(|e| map_pg_err(e, VEC_TABLE))?;
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
        let mut guard = self.inner.lock().unwrap();
        if !Self::table_exists(&mut guard.client) {
            return Ok(());
        }
        guard
            .client
            .execute(
                &format!("DELETE FROM \"{VEC_TABLE}\" WHERE \"key\" = $1"),
                &[&key.to_string().to_uppercase()],
            )
            .map_err(|e| map_pg_err(e, VEC_TABLE))?;
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
        let mut guard = self.inner.lock().unwrap();
        if !Self::table_exists(&mut guard.client) {
            return Ok(Vec::new());
        }
        let op = metric_op(metric);
        let lit = vector_literal(query);
        let sql = format!(
            "SELECT \"key\", (\"embedding\" {op} '{lit}'::vector) AS distance FROM \"{VEC_TABLE}\" \
             ORDER BY \"embedding\" {op} '{lit}'::vector LIMIT {k}"
        );
        let rows = guard
            .client
            .query(&sql, &[])
            .map_err(|e| map_pg_err(e, VEC_TABLE))?;
        Ok(rows
            .iter()
            .map(|r| VectorSearchResult {
                key: Uuid::parse_str(&r.get::<_, String>(0)).unwrap_or(Uuid::nil()),
                distance: r.get::<_, f64>(1) as f32,
                metadata: BTreeMap::new(),
            })
            .collect())
    }
    fn reindex(&self, _parameters: IndexParameters) -> StorageResult<()> {
        // Flat/sequential scan — no secondary index built at Phase 1.
        Ok(())
    }
    fn count(&self) -> StorageResult<usize> {
        let mut guard = self.inner.lock().unwrap();
        if !Self::table_exists(&mut guard.client) {
            return Ok(0);
        }
        let n: i64 = guard
            .client
            .query_one(&format!("SELECT COUNT(*) FROM \"{VEC_TABLE}\""), &[])
            .map_err(|e| map_pg_err(e, VEC_TABLE))?
            .get(0);
        Ok(n as usize)
    }
}
