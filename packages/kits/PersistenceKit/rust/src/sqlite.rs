//! SQLite backend — the Rust version of the Swift `PersistenceKitSQLite`
//! target. One `rusqlite::Connection` per estate, serialized behind a
//! `Mutex` (a real shared DB handle, not an actor emulation). Schema
//! DDL, the closed predicate algebra, and the value codec match the
//! Swift backend so both versions produce identical observable results.
//!
//! Phase 1 implements RowStore, BlobStore, AuditLog, and StorageObserver
//! plus schema/migrations/generated-columns/append-only. VectorIndex is
//! a placeholder pending the sqlite-vec follow-on.

use std::collections::{BTreeMap, BTreeSet};
use std::str;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, Once};
use std::time::Duration;

use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{params_from_iter, Connection, OptionalExtension};
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
// Value codec — TypedValue <-> SQLite. Mirrors SQLiteConnection.swift's
// bind/readColumn. UUIDs bind as uppercase TEXT (matching Swift's
// `uuidString`); timestamps bind as ISO-8601 TEXT (the date invariant).
// ─────────────────────────────────────────────────────────────────────

fn native_type(t: ColumnType) -> &'static str {
    match t {
        ColumnType::Uuid | ColumnType::Text | ColumnType::Timestamp => "TEXT",
        ColumnType::Bitmap | ColumnType::Int | ColumnType::Bool | ColumnType::Hlc => "INTEGER",
        ColumnType::Float => "REAL",
        ColumnType::Blob | ColumnType::Json | ColumnType::Fingerprint => "BLOB",
    }
}

fn iso8601(secs: i64) -> String {
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())
        .unwrap_or_default()
}

fn parse_iso8601(s: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.timestamp())
        .unwrap_or(0)
}

fn to_sql(value: &TypedValue) -> SqlValue {
    match value {
        TypedValue::Null => SqlValue::Null,
        TypedValue::Bool(b) => SqlValue::Integer(if *b { 1 } else { 0 }),
        TypedValue::Int(i) => SqlValue::Integer(*i),
        TypedValue::Bitmap(i) => SqlValue::Integer(*i),
        TypedValue::Float(f) => SqlValue::Real(*f),
        TypedValue::Text(s) => SqlValue::Text(s.clone()),
        TypedValue::Blob(b) => SqlValue::Blob(b.clone()),
        TypedValue::Json(b) => SqlValue::Blob(b.clone()),
        TypedValue::Uuid(u) => SqlValue::Text(u.to_string().to_uppercase()),
        TypedValue::Timestamp(secs) => SqlValue::Text(iso8601(*secs)),
        TypedValue::Hlc(h) => SqlValue::Integer(h.packed() as i64),
        // Not exercised by Phase-1 conformance; bound as NULL until the
        // fingerprint/array column paths are needed.
        TypedValue::Fingerprint(_) | TypedValue::Array(_) => SqlValue::Null,
    }
}

/// Reconstruct an HLC from its packed integer (inverse of HLC::packed),
/// matching the Swift unpack layout (physical << 16 | logical << 4 | node).
fn unpack_hlc(packed: u64) -> HLC {
    HLC {
        physical_time: ((packed >> 16) & 0xFFFF_FFFF_FFFF) as i64,
        logical_count: ((packed >> 4) & 0xFFF) as i32,
        node_id: (packed & 0xF) as i32,
    }
}

/// Read a SQLite value back into a TypedValue, using the column's declared
/// ColumnType to disambiguate INTEGER (int/bitmap/bool/hlc) and TEXT
/// (text/uuid/timestamp). Mirrors SQLiteStorage.readColumn.
fn read_value(vref: ValueRef, kit: Option<ColumnType>) -> TypedValue {
    match vref {
        ValueRef::Null => TypedValue::Null,
        ValueRef::Integer(i) => match kit {
            Some(ColumnType::Bitmap) => TypedValue::Bitmap(i),
            Some(ColumnType::Bool) => TypedValue::Bool(i != 0),
            Some(ColumnType::Hlc) => TypedValue::Hlc(unpack_hlc(i as u64)),
            _ => TypedValue::Int(i),
        },
        ValueRef::Real(f) => TypedValue::Float(f),
        ValueRef::Text(b) => {
            let s = str::from_utf8(b).unwrap_or("");
            match kit {
                Some(ColumnType::Uuid) => {
                    TypedValue::Uuid(Uuid::parse_str(s).unwrap_or(Uuid::nil()))
                }
                Some(ColumnType::Timestamp) => TypedValue::Timestamp(parse_iso8601(s)),
                _ => TypedValue::Text(s.to_string()),
            }
        }
        ValueRef::Blob(b) => match kit {
            Some(ColumnType::Json) => TypedValue::Json(b.to_vec()),
            _ => TypedValue::Blob(b.to_vec()),
        },
    }
}

fn map_sql_err(e: rusqlite::Error, table: &str) -> StorageError {
    let msg = e.to_string();
    if msg.contains("append-only") {
        StorageError::AppendOnlyViolation {
            table: table.to_string(),
        }
    } else if msg.contains("UNIQUE") {
        StorageError::DuplicateKey {
            table: table.to_string(),
            key: "(unique constraint)".into(),
        }
    } else {
        StorageError::BackendError { underlying: msg }
    }
}

// ─────────────────────────────────────────────────────────────────────
// DDL — mirrors SQLiteSchema.swift.
// ─────────────────────────────────────────────────────────────────────

const MIGRATIONS_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_migrations" (
  "kit_id" TEXT NOT NULL,
  "version" INTEGER NOT NULL,
  "applied_at" TEXT NOT NULL,
  PRIMARY KEY ("kit_id")
)"#;

const BLOB_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_blobs" (
  "key" TEXT PRIMARY KEY NOT NULL,
  "bytes" BLOB NOT NULL
)"#;

// Rust-shaped audit table: holds the Rust AuditEvent fields. `hlc` is the
// packed integer (PK + ordering, order-preserving by HLC); the three
// component columns let events reconstruct without an unpack dependency.
const AUDIT_TABLE: &str = r#"CREATE TABLE IF NOT EXISTS "_storagekit_audit" (
  "event_id" TEXT NOT NULL,
  "hlc" INTEGER NOT NULL,
  "physical_time" INTEGER NOT NULL,
  "logical_count" INTEGER NOT NULL,
  "node_id" INTEGER NOT NULL,
  "estate_uuid" TEXT NOT NULL,
  "row_id" TEXT NOT NULL,
  "verb" TEXT NOT NULL,
  "before_adjective" INTEGER,
  "before_operational" INTEGER,
  "before_provenance" INTEGER,
  "after_adjective" INTEGER NOT NULL,
  "after_operational" INTEGER NOT NULL,
  "after_provenance" INTEGER NOT NULL,
  "before_lattice_anchor" INTEGER,
  "after_lattice_anchor" INTEGER NOT NULL,
  "actor" TEXT NOT NULL,
  PRIMARY KEY ("event_id", "hlc")
)"#;

const AUDIT_INDEX: &str = r#"CREATE INDEX IF NOT EXISTS "_storagekit_audit_row_hlc" ON "_storagekit_audit" ("row_id", "hlc")"#;

fn create_table_sql(decl: &TableDeclaration) -> String {
    let mut parts: Vec<String> = Vec::new();
    for col in &decl.columns {
        let mut line = format!("\"{}\" {}", col.name, native_type(col.column_type));
        if !col.nullable {
            line.push_str(" NOT NULL");
        }
        parts.push(line);
    }
    // Generated columns — always STORED for cross-backend parity.
    for gen in &decl.generated_columns {
        parts.push(format!(
            "\"{}\" {} GENERATED ALWAYS AS ({}) STORED",
            gen.name,
            native_type(gen.column_type),
            gen.expression.render_sql()
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

fn append_only_triggers(decl: &TableDeclaration) -> Vec<String> {
    if !decl.append_only {
        return Vec::new();
    }
    let t = &decl.name;
    vec![
        format!(
            "CREATE TRIGGER IF NOT EXISTS \"trg_{t}_no_update\" BEFORE UPDATE ON \"{t}\" \
             BEGIN SELECT RAISE(ABORT, 'table {t} is append-only'); END"
        ),
        format!(
            "CREATE TRIGGER IF NOT EXISTS \"trg_{t}_no_delete\" BEFORE DELETE ON \"{t}\" \
             BEGIN SELECT RAISE(ABORT, 'table {t} is append-only'); END"
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
// Predicate compilation — mirrors SQLitePredicateCompiler.swift.
// ─────────────────────────────────────────────────────────────────────

fn compile_predicate(p: &StoragePredicate, binds: &mut Vec<SqlValue>) -> String {
    match p {
        StoragePredicate::IsTrue => "1=1".into(),
        StoragePredicate::IsFalse => "1=0".into(),
        StoragePredicate::And(preds) => {
            if preds.is_empty() {
                return "1=1".into();
            }
            let parts: Vec<String> = preds.iter().map(|x| compile_predicate(x, binds)).collect();
            format!("({})", parts.join(" AND "))
        }
        StoragePredicate::Or(preds) => {
            if preds.is_empty() {
                return "1=0".into();
            }
            let parts: Vec<String> = preds.iter().map(|x| compile_predicate(x, binds)).collect();
            format!("({})", parts.join(" OR "))
        }
        StoragePredicate::Not(inner) => format!("NOT ({})", compile_predicate(inner, binds)),
        StoragePredicate::Eq(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" = ?", c.name)
        }
        StoragePredicate::Neq(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" != ?", c.name)
        }
        StoragePredicate::Lt(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" < ?", c.name)
        }
        StoragePredicate::Lte(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" <= ?", c.name)
        }
        StoragePredicate::Gt(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" > ?", c.name)
        }
        StoragePredicate::Gte(c, v) => {
            binds.push(to_sql(v));
            format!("\"{}\" >= ?", c.name)
        }
        StoragePredicate::IsNull(c) => format!("\"{}\" IS NULL", c.name),
        StoragePredicate::IsNotNull(c) => format!("\"{}\" IS NOT NULL", c.name),
        StoragePredicate::In(c, values) => {
            if values.is_empty() {
                return "1=0".into();
            }
            let ph = vec!["?"; values.len()].join(", ");
            for v in values {
                binds.push(to_sql(v));
            }
            format!("\"{}\" IN ({ph})", c.name)
        }
        StoragePredicate::Like(c, pattern) => {
            binds.push(SqlValue::Text(pattern.clone()));
            format!("\"{}\" LIKE ?", c.name)
        }
        StoragePredicate::BitmaskAll { column, mask } => {
            binds.push(SqlValue::Integer(*mask));
            binds.push(SqlValue::Integer(*mask));
            format!("(\"{}\" & ?) = ?", column.name)
        }
        StoragePredicate::BitmaskAny { column, mask } => {
            binds.push(SqlValue::Integer(*mask));
            format!("(\"{}\" & ?) != 0", column.name)
        }
        StoragePredicate::BitmaskNone { column, mask } => {
            binds.push(SqlValue::Integer(*mask));
            format!("(\"{}\" & ?) = 0", column.name)
        }
        StoragePredicate::BitwiseEq {
            column,
            expected,
            mask,
        } => {
            binds.push(SqlValue::Integer(*mask));
            binds.push(SqlValue::Integer(*expected));
            format!("(\"{}\" & ?) = ?", column.name)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Observer registry — mirrors SQLiteObserverRegistry. Not conformance-
// gated; emits on row mutations so downstream watchers wake.
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
    conn: Connection,
    schema: Option<SchemaDeclaration>,
}

pub struct SqliteStorage {
    config: EstateConfiguration,
    inner: Arc<Mutex<Inner>>,
    observers: Arc<ObserverRegistry>,
}

/// Register the sqlite-vec extension (vec0 virtual table) with every SQLite
/// connection opened in this process, so the VectorIndex's vec0 tables work.
/// Idempotent; must run before opening a connection that uses vectors.
fn register_sqlite_vec() {
    static REGISTER: Once = Once::new();
    REGISTER.call_once(|| unsafe {
        // Cast sqlite3_vec_init to the entry-point signature
        // sqlite3_auto_extension expects; the explicit annotation pins
        // the source/target types (clippy missing_transmute_annotations).
        rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute::<
            *const (),
            unsafe extern "C" fn(
                *mut rusqlite::ffi::sqlite3,
                *mut *const i8,
                *const rusqlite::ffi::sqlite3_api_routines,
            ) -> i32,
        >(
            sqlite_vec::sqlite3_vec_init as *const ()
        )));
    });
}

impl SqliteStorage {
    /// Open (creating if absent) the SQLite database named by the
    /// configuration's `Sqlite` backend variant.
    pub fn new(config: EstateConfiguration) -> StorageResult<Self> {
        register_sqlite_vec();
        let (path, busy) = match &config.backend {
            BackendConfiguration::Sqlite {
                path,
                busy_timeout_secs,
            } => (path.clone(), *busy_timeout_secs),
            _ => {
                return Err(StorageError::BackendError {
                    underlying: "SqliteStorage requires a Sqlite backend configuration".into(),
                })
            }
        };
        let conn = Connection::open(&path).map_err(|e| StorageError::BackendError {
            underlying: format!("sqlite open: {e}"),
        })?;
        let _ = conn.busy_timeout(Duration::from_secs_f64(busy));
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;",
        )
        .map_err(|e| StorageError::BackendError {
            underlying: format!("sqlite pragmas: {e}"),
        })?;
        Ok(SqliteStorage {
            config,
            inner: Arc::new(Mutex::new(Inner { conn, schema: None })),
            observers: Arc::new(ObserverRegistry::default()),
        })
    }
}

/// Apply the full schema (idempotent CREATE-IF-NOT-EXISTS) and record the
/// version. Shared by `open` and `migrate`.
fn apply_schema(inner: &mut Inner, schema: &SchemaDeclaration) -> StorageResult<()> {
    inner.schema = Some(schema.clone());
    let conn = &inner.conn;
    let exec = |sql: &str| {
        conn.execute_batch(sql)
            .map_err(|e| StorageError::BackendError {
                underlying: format!("ddl: {e}"),
            })
    };
    exec(MIGRATIONS_TABLE)?;
    exec(AUDIT_TABLE)?;
    exec(AUDIT_INDEX)?;
    exec(BLOB_TABLE)?;
    for table in &schema.tables {
        exec(&create_table_sql(table))?;
        for trigger in append_only_triggers(table) {
            exec(&trigger)?;
        }
    }
    for index in &schema.indices {
        exec(&create_index_sql(index))?;
    }
    // Record the schema version (kit-scoped).
    conn.execute(
        r#"INSERT INTO "_storagekit_migrations" ("kit_id", "version", "applied_at") VALUES (?, ?, ?)
           ON CONFLICT("kit_id") DO UPDATE SET "version" = excluded.version, "applied_at" = excluded.applied_at"#,
        params_from_iter(vec![
            SqlValue::Text(schema.kit_id.clone()),
            SqlValue::Integer(schema.version as i64),
            SqlValue::Text(iso8601(0)),
        ]),
    )
    .map_err(|e| StorageError::BackendError { underlying: format!("record version: {e}") })?;
    Ok(())
}

impl Storage for SqliteStorage {
    fn configuration(&self) -> &EstateConfiguration {
        &self.config
    }
    fn row_store(&self) -> Arc<dyn RowStore> {
        Arc::new(SqliteRowStore {
            inner: self.inner.clone(),
            observers: self.observers.clone(),
        })
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(SqliteBlobStore {
            inner: self.inner.clone(),
        })
    }
    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Arc::new(SqliteVectorIndex {
            inner: self.inner.clone(),
        })
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Arc::new(SqliteAuditLog {
            inner: self.inner.clone(),
        })
    }
    fn observer(&self) -> Arc<dyn StorageObserver> {
        Arc::new(SqliteObserver {
            observers: self.observers.clone(),
        })
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        apply_schema(&mut self.inner.lock().unwrap(), schema)
    }
    fn close(&self) -> StorageResult<()> {
        Ok(()) // connection drops with the storage; nothing buffered.
    }
    fn current_schema_version(&self) -> StorageResult<i32> {
        let guard = self.inner.lock().unwrap();
        let v: i64 = guard
            .conn
            .query_row(
                r#"SELECT MAX("version") FROM "_storagekit_migrations""#,
                [],
                |r| r.get::<_, Option<i64>>(0).map(|o| o.unwrap_or(0)),
            )
            .map_err(|e| StorageError::BackendError {
                underlying: format!("schema version: {e}"),
            })?;
        Ok(v as i32)
    }
    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        apply_schema(&mut self.inner.lock().unwrap(), schema)
    }

    fn transaction(
        &self,
        _isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        // BEGIN IMMEDIATE takes the write lock up front so the block's first
        // mutation can't fail on a busy DB mid-transaction. The lock on
        // `inner` is taken only to issue each bracket statement and released
        // before the block runs — the block's sub-stores re-lock per call, so
        // holding it across `block` would deadlock against them.
        self.inner
            .lock()
            .unwrap()
            .conn
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| map_sql_err(e, "transaction"))?;
        match block(self) {
            Ok(()) => {
                self.inner
                    .lock()
                    .unwrap()
                    .conn
                    .execute_batch("COMMIT")
                    .map_err(|e| map_sql_err(e, "transaction"))?;
                Ok(())
            }
            Err(e) => {
                // Best-effort rollback; surface the block's error regardless.
                let _ = self.inner.lock().unwrap().conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }
}

impl StorageTransaction for SqliteStorage {
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

struct SqliteRowStore {
    inner: Arc<Mutex<Inner>>,
    observers: Arc<ObserverRegistry>,
}

/// Resolve the row's primary key: a single-column UUID primary key reads
/// the UUID from the row; anything else gets a fresh v4.
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

impl RowStore for SqliteRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let cols = keys
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let ph = vec!["?"; keys.len()].join(", ");
        let sql = format!("INSERT INTO \"{table}\" ({cols}) VALUES ({ph})");
        let binds: Vec<SqlValue> = keys.iter().map(|k| to_sql(&values[*k])).collect();
        guard
            .conn
            .execute(&sql, params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
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
        let guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let cols = keys
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let ph = vec!["?"; keys.len()].join(", ");
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
            sql.push_str(&format!(" ON CONFLICT({conflict})"));
            if updates.is_empty() {
                sql.push_str(" DO NOTHING");
            } else {
                sql.push_str(&format!(" DO UPDATE SET {}", updates.join(", ")));
            }
        }
        let binds: Vec<SqlValue> = keys.iter().map(|k| to_sql(&values[*k])).collect();
        guard
            .conn
            .execute(&sql, params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
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
        let guard = self.inner.lock().unwrap();
        let keys: Vec<&String> = values.keys().collect();
        let set_clause = keys
            .iter()
            .map(|k| format!("\"{k}\" = ?"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut binds: Vec<SqlValue> = keys.iter().map(|k| to_sql(&values[*k])).collect();
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("UPDATE \"{table}\" SET {set_clause} WHERE {where_sql}");
        let changed = guard
            .conn
            .execute(&sql, params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
        if changed > 0 {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Update,
                row_key: None,
                values: None,
                hlc: None,
            });
        }
        Ok(changed)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        let guard = self.inner.lock().unwrap();
        let mut binds: Vec<SqlValue> = Vec::new();
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("DELETE FROM \"{table}\" WHERE {where_sql}");
        let changed = guard
            .conn
            .execute(&sql, params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
        if changed > 0 {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Delete,
                row_key: None,
                values: None,
                hlc: None,
            });
        }
        Ok(changed)
    }

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT * FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
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

        let mut stmt = guard
            .conn
            .prepare(&sql)
            .map_err(|e| map_sql_err(e, table))?;
        let col_names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = stmt
            .query(params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
        let mut out: Vec<StorageRow> = Vec::new();
        while let Some(row) = rows.next().map_err(|e| map_sql_err(e, table))? {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            for (i, name) in col_names.iter().enumerate() {
                let vref = row.get_ref(i).map_err(|e| map_sql_err(e, table))?;
                let kit = table_column_type(guard.schema.as_ref(), table, name);
                values.insert(name.clone(), read_value(vref, kit));
            }
            out.push(StorageRow::new(values));
        }
        Ok(out)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)));
        }
        let n: i64 = guard
            .conn
            .query_row(&sql, params_from_iter(binds), |r| r.get(0))
            .map_err(|e| map_sql_err(e, table))?;
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// BlobStore.
// ─────────────────────────────────────────────────────────────────────

struct SqliteBlobStore {
    inner: Arc<Mutex<Inner>>,
}

impl BlobStore for SqliteBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .execute(
                r#"INSERT INTO "_storagekit_blobs" ("key", "bytes") VALUES (?, ?)
                   ON CONFLICT("key") DO UPDATE SET "bytes" = excluded.bytes"#,
                params_from_iter(vec![
                    SqlValue::Text(key.to_string()),
                    SqlValue::Blob(bytes.to_vec()),
                ]),
            )
            .map_err(|e| map_sql_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .query_row(
                r#"SELECT "bytes" FROM "_storagekit_blobs" WHERE "key" = ?"#,
                params_from_iter(vec![SqlValue::Text(key.to_string())]),
                |r| r.get::<_, Vec<u8>>(0),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(map_sql_err(other, "_storagekit_blobs")),
            })
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .execute(
                r#"DELETE FROM "_storagekit_blobs" WHERE "key" = ?"#,
                params_from_iter(vec![SqlValue::Text(key.to_string())]),
            )
            .map_err(|e| map_sql_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn exists(&self, key: &str) -> StorageResult<bool> {
        Ok(self.size(key)?.is_some())
    }
    fn size(&self, key: &str) -> StorageResult<Option<usize>> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .query_row(
                r#"SELECT LENGTH("bytes") FROM "_storagekit_blobs" WHERE "key" = ?"#,
                params_from_iter(vec![SqlValue::Text(key.to_string())]),
                |r| r.get::<_, i64>(0),
            )
            .map(|n| Some(n as usize))
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(map_sql_err(other, "_storagekit_blobs")),
            })
    }
}

// ─────────────────────────────────────────────────────────────────────
// AuditLog.
// ─────────────────────────────────────────────────────────────────────

struct SqliteAuditLog {
    inner: Arc<Mutex<Inner>>,
}

fn opt_int(v: Option<i64>) -> SqlValue {
    v.map(SqlValue::Integer).unwrap_or(SqlValue::Null)
}

fn audit_binds(e: &AuditEvent) -> Vec<SqlValue> {
    vec![
        SqlValue::Text(e.event_id.to_string().to_uppercase()),
        SqlValue::Integer(e.hlc.packed() as i64),
        SqlValue::Integer(e.hlc.physical_time),
        SqlValue::Integer(e.hlc.logical_count as i64),
        SqlValue::Integer(e.hlc.node_id as i64),
        SqlValue::Text(e.estate_uuid.to_string().to_uppercase()),
        SqlValue::Text(e.row_id.to_string().to_uppercase()),
        SqlValue::Text(e.verb.clone()),
        opt_int(e.before_adjective),
        opt_int(e.before_operational),
        opt_int(e.before_provenance),
        SqlValue::Integer(e.after_adjective),
        SqlValue::Integer(e.after_operational),
        SqlValue::Integer(e.after_provenance),
        opt_int(e.before_lattice_anchor.map(|v| v as i64)),
        SqlValue::Integer(e.after_lattice_anchor as i64),
        SqlValue::Text(e.actor.clone()),
    ]
}

const AUDIT_COLS: &str = r#""event_id","hlc","physical_time","logical_count","node_id","estate_uuid","row_id","verb","before_adjective","before_operational","before_provenance","after_adjective","after_operational","after_provenance","before_lattice_anchor","after_lattice_anchor","actor""#;

fn decode_audit(row: &rusqlite::Row) -> rusqlite::Result<AuditEvent> {
    let parse_uuid = |s: String| Uuid::parse_str(&s).unwrap_or(Uuid::nil());
    Ok(AuditEvent {
        event_id: parse_uuid(row.get::<_, String>(0)?),
        hlc: HLC {
            physical_time: row.get(2)?,
            logical_count: row.get::<_, i64>(3)? as i32,
            node_id: row.get::<_, i64>(4)? as i32,
        },
        estate_uuid: parse_uuid(row.get::<_, String>(5)?),
        row_id: parse_uuid(row.get::<_, String>(6)?),
        verb: row.get(7)?,
        before_adjective: row.get(8)?,
        before_operational: row.get(9)?,
        before_provenance: row.get(10)?,
        after_adjective: row.get(11)?,
        after_operational: row.get(12)?,
        after_provenance: row.get(13)?,
        before_lattice_anchor: row.get::<_, Option<i64>>(14)?.map(|v| v as u64),
        after_lattice_anchor: row.get::<_, i64>(15)? as u64,
        actor: row.get(16)?,
    })
}

impl AuditLog for SqliteAuditLog {
    fn append(&self, event: AuditEvent) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        let sql = format!(
            "INSERT INTO \"_storagekit_audit\" ({AUDIT_COLS}) VALUES ({}) ON CONFLICT(\"event_id\",\"hlc\") DO NOTHING",
            vec!["?"; 17].join(", ")
        );
        guard
            .conn
            .execute(&sql, params_from_iter(audit_binds(&event)))
            .map_err(|e| map_sql_err(e, "_storagekit_audit"))?;
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
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT {AUDIT_COLS} FROM \"_storagekit_audit\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        let mut clauses: Vec<String> = Vec::new();
        if let Some(h) = after {
            clauses.push("\"hlc\" > ?".into());
            binds.push(SqlValue::Integer(h.packed() as i64));
        }
        if let Some(r) = row_id {
            clauses.push("\"row_id\" = ?".into());
            binds.push(SqlValue::Text(r.to_string().to_uppercase()));
        }
        if !clauses.is_empty() {
            sql.push_str(&format!(" WHERE {}", clauses.join(" AND ")));
        }
        // SQLite LIMIT is an i64; usize::MAX (the "unbounded" sentinel from
        // events_for_row) overflows it, so map any out-of-range limit to the
        // SQLite "no limit" form (-1).
        let lim: i64 = if limit > i64::MAX as usize {
            -1
        } else {
            limit as i64
        };
        sql.push_str(&format!(" ORDER BY \"hlc\" ASC LIMIT {lim}"));
        let mut stmt = guard
            .conn
            .prepare(&sql)
            .map_err(|e| map_sql_err(e, "_storagekit_audit"))?;
        let events = stmt
            .query_map(params_from_iter(binds), decode_audit)
            .map_err(|e| map_sql_err(e, "_storagekit_audit"))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| map_sql_err(e, "_storagekit_audit"))?;
        Ok(events)
    }
    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>> {
        self.iterate(None, Some(row_id), usize::MAX)
    }
    fn count(&self) -> StorageResult<usize> {
        let guard = self.inner.lock().unwrap();
        let n: i64 = guard
            .conn
            .query_row(r#"SELECT COUNT(*) FROM "_storagekit_audit""#, [], |r| {
                r.get(0)
            })
            .map_err(|e| map_sql_err(e, "_storagekit_audit"))?;
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// StorageObserver.
// ─────────────────────────────────────────────────────────────────────

struct SqliteObserver {
    observers: Arc<ObserverRegistry>,
}

impl StorageObserver for SqliteObserver {
    fn observe(
        &self,
        table: &str,
        events: BTreeSet<StorageEvent>,
    ) -> StorageResult<Receiver<TableChange>> {
        Ok(self.observers.observe(table, events))
    }
}

// ─────────────────────────────────────────────────────────────────────
// VectorIndex — sqlite-vec backed (vec0 virtual table). Mirrors the Swift
// SQLiteVectorIndex: a vec0 table holds embeddings keyed by rowid, and a
// `_storagekit_vector_meta` table maps the caller's RowKey ↔ rowid.
// Embeddings are little-endian f32 blobs (vec0's native format). Lazily
// created on first add (dimension fixed from the first vector). vec0 uses
// L2 by default.
// ─────────────────────────────────────────────────────────────────────

struct SqliteVectorIndex {
    inner: Arc<Mutex<Inner>>,
}

const SVEC_TABLE: &str = "_storagekit_vectors";
const SVEC_META: &str = "_storagekit_vector_meta";

fn vec_blob(v: &[f32]) -> Vec<u8> {
    let mut b = Vec::with_capacity(v.len() * 4);
    for f in v {
        b.extend_from_slice(&f.to_le_bytes());
    }
    b
}

impl SqliteVectorIndex {
    fn meta_exists(conn: &Connection) -> bool {
        conn.query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
            [SVEC_META],
            |_| Ok(()),
        )
        .optional()
        .map(|o| o.is_some())
        .unwrap_or(false)
    }

    fn rowid_for(conn: &Connection, key: RowKey) -> StorageResult<Option<i64>> {
        conn.query_row(
            &format!("SELECT \"vec_rowid\" FROM \"{SVEC_META}\" WHERE \"key\" = ?1"),
            params_from_iter(vec![SqlValue::Text(key.to_string().to_uppercase())]),
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .map_err(|e| map_sql_err(e, SVEC_META))
    }
}

impl VectorIndex for SqliteVectorIndex {
    fn add(
        &self,
        key: RowKey,
        vector: &[f32],
        _metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        let dim = vector.len();
        guard
            .conn
            .execute_batch(&format!(
                "CREATE VIRTUAL TABLE IF NOT EXISTS \"{SVEC_TABLE}\" USING vec0(embedding float[{dim}]);\n\
                 CREATE TABLE IF NOT EXISTS \"{SVEC_META}\" (\"key\" TEXT PRIMARY KEY, \"vec_rowid\" INTEGER NOT NULL, \"metadata_json\" TEXT NOT NULL DEFAULT '{{}}');"
            ))
            .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
        let blob = vec_blob(vector);
        match Self::rowid_for(&guard.conn, key)? {
            Some(rowid) => {
                guard
                    .conn
                    .execute(
                        &format!("UPDATE \"{SVEC_TABLE}\" SET embedding = ?1 WHERE rowid = ?2"),
                        params_from_iter(vec![SqlValue::Blob(blob), SqlValue::Integer(rowid)]),
                    )
                    .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
            }
            None => {
                guard
                    .conn
                    .execute(
                        &format!("INSERT INTO \"{SVEC_TABLE}\" (embedding) VALUES (?1)"),
                        params_from_iter(vec![SqlValue::Blob(blob)]),
                    )
                    .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
                let rowid = guard.conn.last_insert_rowid();
                guard
                    .conn
                    .execute(
                        &format!(
                            "INSERT INTO \"{SVEC_META}\" (\"key\", \"vec_rowid\") VALUES (?1, ?2)"
                        ),
                        params_from_iter(vec![
                            SqlValue::Text(key.to_string().to_uppercase()),
                            SqlValue::Integer(rowid),
                        ]),
                    )
                    .map_err(|e| map_sql_err(e, SVEC_META))?;
            }
        }
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
        let guard = self.inner.lock().unwrap();
        if !Self::meta_exists(&guard.conn) {
            return Ok(());
        }
        if let Some(rowid) = Self::rowid_for(&guard.conn, key)? {
            guard
                .conn
                .execute(
                    &format!("DELETE FROM \"{SVEC_TABLE}\" WHERE rowid = ?1"),
                    params_from_iter(vec![SqlValue::Integer(rowid)]),
                )
                .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
            guard
                .conn
                .execute(
                    &format!("DELETE FROM \"{SVEC_META}\" WHERE \"key\" = ?1"),
                    params_from_iter(vec![SqlValue::Text(key.to_string().to_uppercase())]),
                )
                .map_err(|e| map_sql_err(e, SVEC_META))?;
        }
        Ok(())
    }

    fn knn(
        &self,
        query: &[f32],
        k: usize,
        _metric: DistanceMetric,
        _filter: Option<&StoragePredicate>,
        _search_parameters: Option<SearchParameters>,
    ) -> StorageResult<Vec<VectorSearchResult>> {
        let guard = self.inner.lock().unwrap();
        if !Self::meta_exists(&guard.conn) {
            return Ok(Vec::new());
        }
        // vec0 KNN: the `k = ?` constraint is required (not just LIMIT); the
        // `distance` column is exposed on the match. L2 by default.
        let sql = format!(
            "SELECT m.\"key\", v.distance FROM \"{SVEC_TABLE}\" v \
             JOIN \"{SVEC_META}\" m ON m.\"vec_rowid\" = v.rowid \
             WHERE v.embedding MATCH ?1 AND k = ?2 ORDER BY v.distance"
        );
        let mut stmt = guard
            .conn
            .prepare(&sql)
            .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
        let out = stmt
            .query_map(
                params_from_iter(vec![
                    SqlValue::Blob(vec_blob(query)),
                    SqlValue::Integer(k as i64),
                ]),
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)),
            )
            .map_err(|e| map_sql_err(e, SVEC_TABLE))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| map_sql_err(e, SVEC_TABLE))?;
        Ok(out
            .into_iter()
            .map(|(key, distance)| VectorSearchResult {
                key: Uuid::parse_str(&key).unwrap_or(Uuid::nil()),
                distance: distance as f32,
                metadata: BTreeMap::new(),
            })
            .collect())
    }

    fn reindex(&self, _parameters: IndexParameters) -> StorageResult<()> {
        // vec0 is updated incrementally; no separate build step.
        Ok(())
    }

    fn count(&self) -> StorageResult<usize> {
        let guard = self.inner.lock().unwrap();
        if !Self::meta_exists(&guard.conn) {
            return Ok(0);
        }
        let n: i64 = guard
            .conn
            .query_row(&format!("SELECT COUNT(*) FROM \"{SVEC_META}\""), [], |r| {
                r.get(0)
            })
            .map_err(|e| map_sql_err(e, SVEC_META))?;
        Ok(n as usize)
    }
}
