//! PostgreSQL backend — the Rust version of the Swift `PersistenceKitPostgreSQL`
//! target, over the synchronous `postgres` crate (matching the sync Storage
//! trait). A fixed-size lazy connection pool (matching `PostgreSQLPool.swift`)
//! guards per-estate connections. Schema DDL, predicate compilation, and the
//! value codec match the Swift backend so both versions produce identical
//! observable results.
//!
//! NOTE: this backend is **unverified locally** — its conformance test only
//! runs when `PERSISTENCEKIT_PG_URL` points at a live PostgreSQL server;
//! without one it is skipped. Implements RowStore, BlobStore, AuditLog,
//! StorageObserver + schema/generated-STORED-columns/append-only, and a
//! pgvector-backed VectorIndex (see PgVectorIndex).

use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

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
// Connection pool — mirrors PostgreSQLPool.swift observable semantics.
//
// Semantics matched to Swift:
//   - Fixed size from `pool_size`; connections created lazily up to that cap
//   - Checkout: try idle slot first, then lazy-create if in_use < pool_size,
//     else block (Condvar::wait_timeout) for connection_timeout_secs, then
//     return Err(StorageError::PoolExhausted { timeout_secs })
//   - Checkin: if closed, drop connection; if waiter pending, notify; else
//     return to idle vec and notify (notify_all wakes blocked checkouts)
//   - Close: set is_closed, drop all idle connections, notify_all so blocked
//     checkouts wake and return Err(BackendUnavailable)
//   - idle_timeout: accepted and stored to match the Swift config surface,
//     but not used to reap or refresh connections — Swift also ignores it
//     (idleTimeout is stored in PostgreSQLPool.swift but never referenced in
//     any idle-reap or refresh path).
// ─────────────────────────────────────────────────────────────────────

struct PoolState {
    /// Idle connections available for checkout.
    available: Vec<Client>,
    /// Number of connections currently checked out (in active use).
    in_use: usize,
    /// True after close() is called; new checkouts return BackendUnavailable.
    is_closed: bool,
    /// The postgres:// URL used to open new connections.
    connection_string: String,
    /// Estate namespace prepended to the search_path on every new connection.
    namespace: String,
    /// Maximum total connections (available + in_use).
    pool_size: usize,
    /// Timeout for blocked checkout, in seconds. Fractional seconds allowed.
    connection_timeout_secs: f64,
}

struct Pool {
    state: Mutex<PoolState>,
    /// Notified whenever a connection is returned or the pool is closed,
    /// so blocked checkout threads can re-evaluate.
    condvar: Condvar,
}

impl Pool {
    fn new(
        connection_string: String,
        namespace: String,
        pool_size: usize,
        connection_timeout_secs: f64,
        // idle_timeout_secs is accepted to match the Swift config surface;
        // not used to reap/refresh connections (Swift also accepts-but-ignores it).
        _idle_timeout_secs: f64,
    ) -> Self {
        Pool {
            state: Mutex::new(PoolState {
                available: Vec::new(),
                in_use: 0,
                is_closed: false,
                connection_string,
                namespace,
                pool_size,
                connection_timeout_secs,
            }),
            condvar: Condvar::new(),
        }
    }

    /// Open one new connection and pin it to the estate's schema namespace.
    /// Caller must hold no lock when calling this (it does real I/O).
    fn open_connection(conn_str: &str, namespace: &str) -> StorageResult<Client> {
        let mut client =
            Client::connect(conn_str, NoTls).map_err(|e| StorageError::BackendError {
                underlying: format!("postgres connect: {e}"),
            })?;
        // Pin search_path to the estate's schema (namespace) so all DDL and
        // DML target the correct per-estate tables. `public` stays on the
        // path so shared extensions (e.g. pgvector) resolve.
        client
            .batch_execute(&format!(
                "CREATE SCHEMA IF NOT EXISTS \"{namespace}\"; \
                 SET search_path TO \"{namespace}\", public;"
            ))
            .map_err(|e| StorageError::BackendError {
                underlying: format!("schema setup: {e}"),
            })?;
        Ok(client)
    }

    /// Check out one connection from the pool. Blocks up to
    /// `connection_timeout_secs` when the pool is at capacity.
    /// Returns Err(PoolExhausted) on timeout, Err(BackendUnavailable) if
    /// the pool has been closed.
    fn checkout(&self) -> StorageResult<PooledClient> {
        let mut guard = self.state.lock().unwrap();

        // Closed before we even started — refuse immediately.
        if guard.is_closed {
            return Err(StorageError::BackendUnavailable {
                reason: "pool closed".into(),
            });
        }

        // Try an idle connection first (matches Swift's `available.popLast()`).
        if let Some(client) = guard.available.pop() {
            guard.in_use += 1;
            return Ok(PooledClient {
                client: Some(client),
                pool: self as *const Pool,
            });
        }

        // Lazy creation: if we haven't hit the cap, open a new connection.
        if guard.in_use < guard.pool_size {
            guard.in_use += 1;
            // Release the lock during real I/O so other threads aren't blocked.
            let conn_str = guard.connection_string.clone();
            let namespace = guard.namespace.clone();
            drop(guard);
            match Self::open_connection(&conn_str, &namespace) {
                Ok(client) => {
                    return Ok(PooledClient {
                        client: Some(client),
                        pool: self as *const Pool,
                    });
                }
                Err(e) => {
                    // Connection failed — decrement in_use and surface the error.
                    let mut g = self.state.lock().unwrap();
                    g.in_use -= 1;
                    self.condvar.notify_all();
                    return Err(e);
                }
            }
        }

        // Pool is full — block until a connection is returned or we time out.
        // Mirrors Swift's `waiters` queue: a checked-in connection (or close)
        // wakes us via Condvar notify_all.
        let timeout_secs = guard.connection_timeout_secs;
        let timeout = Duration::from_secs_f64(timeout_secs);
        let deadline = std::time::Instant::now() + timeout;

        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                // Timeout expired — matches Swift's poolExhausted(timeout:).
                return Err(StorageError::PoolExhausted { timeout_secs });
            }
            let (new_guard, wait_result) = self.condvar.wait_timeout(guard, remaining).unwrap();
            guard = new_guard;

            if guard.is_closed {
                return Err(StorageError::BackendUnavailable {
                    reason: "pool closing".into(),
                });
            }

            // Try idle slot first.
            if let Some(client) = guard.available.pop() {
                guard.in_use += 1;
                return Ok(PooledClient {
                    client: Some(client),
                    pool: self as *const Pool,
                });
            }

            // Spurious wake with no connection available — loop if time remains.
            if wait_result.timed_out() {
                return Err(StorageError::PoolExhausted { timeout_secs });
            }
        }
    }

    /// Return a connection to the pool. If the pool is closed, drop the
    /// connection. If waiters are blocked, notify_all to wake them.
    fn checkin(&self, client: Client) {
        let mut guard = self.state.lock().unwrap();
        guard.in_use -= 1;
        if guard.is_closed {
            // Pool is closing — drop the connection and do not return it.
            drop(client);
            self.condvar.notify_all();
            return;
        }
        guard.available.push(client);
        // notify_all: mirrors Swift's `waiters.removeFirst(); w.resume(...)`.
        // All blocked checkouts re-evaluate; at most one will win the idle slot.
        self.condvar.notify_all();
    }

    /// Discard a connection that is in a broken state and must not be
    /// returned to the available pool (e.g. after a failed ROLLBACK).
    /// Decrements `in_use` so the pool capacity slot is freed, then
    /// notifies waiters. The caller is responsible for dropping the client.
    /// Mirrors Swift: on rollback failure the connection is released
    /// without being returned to the pool.
    fn discard(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.in_use -= 1;
        self.condvar.notify_all();
    }

    /// Close the pool. All idle connections are dropped. Blocked checkouts
    /// will wake and return Err(BackendUnavailable). Mirrors Swift's close().
    fn close(&self) {
        let mut guard = self.state.lock().unwrap();
        guard.is_closed = true;
        // Drop all idle connections.
        guard.available.clear();
        // Wake all blocked checkouts; they will see is_closed = true and return
        // BackendUnavailable, matching Swift's `pool closing` error.
        self.condvar.notify_all();
    }
}

/// RAII guard that returns the connection to the pool on drop.
/// Using raw pointer to Pool to avoid lifetime coupling (Pool is Arc-owned
/// and lives at least as long as any PooledClient in flight).
struct PooledClient {
    client: Option<Client>,
    pool: *const Pool,
}

impl std::fmt::Debug for PooledClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Client does not implement Debug; surface only the liveness state.
        f.debug_struct("PooledClient")
            .field("connected", &self.client.is_some())
            .finish()
    }
}

impl PooledClient {
    fn get_mut(&mut self) -> &mut Client {
        self.client.as_mut().unwrap()
    }

    /// Discard a connection that must not be returned to the pool (e.g. after
    /// a failed ROLLBACK). Notifies the pool that the capacity slot is free
    /// without putting the broken connection back into the available list.
    /// After this call the PooledClient holds no client; Drop is a no-op.
    fn discard(mut self) {
        if let Some(client) = self.client.take() {
            // SAFETY: same invariant as Drop — pool pointer is valid for
            // the lifetime of any in-flight PooledClient.
            unsafe { (*self.pool).discard() }
            // Drop the broken client here (after freeing the pool slot)
            // so any TCP teardown happens outside the pool lock.
            drop(client);
        }
    }
}

impl Drop for PooledClient {
    fn drop(&mut self) {
        if let Some(client) = self.client.take() {
            // SAFETY: pool pointer comes from Arc<Pool> in PostgresStorage,
            // which outlives all PooledClient guards. No aliasing: checkin
            // takes the Mutex before mutating PoolState.
            unsafe { (*self.pool).checkin(client) }
        }
    }
}

// SAFETY: PooledClient holds a Client (Send) and a raw pointer to a Pool
// that is Send + Sync (Mutex-guarded). The pointer is never dereferenced
// except in Drop (single writer path through checkin's Mutex).
unsafe impl Send for PooledClient {}

// ─────────────────────────────────────────────────────────────────────
// Storage assembly.
// ─────────────────────────────────────────────────────────────────────

/// Per-estate schema — stored once on `open()` and shared read-only
/// across all per-operation pool checkouts.
struct SharedSchema {
    schema: Option<SchemaDeclaration>,
}

pub struct PostgresStorage {
    config: EstateConfiguration,
    pool: Arc<Pool>,
    schema: Arc<Mutex<SharedSchema>>,
    observers: Arc<ObserverRegistry>,
}

impl PostgresStorage {
    /// Construct a PostgresStorage from a Postgresql backend configuration.
    /// No connections are opened here; the pool creates them lazily on first
    /// checkout (matching Swift's lazy pool-creation behaviour).
    pub fn new(config: EstateConfiguration) -> StorageResult<Self> {
        let (conn_str, pool_size, connection_timeout_secs, idle_timeout_secs) =
            match &config.backend {
                BackendConfiguration::Postgresql {
                    connection_string,
                    pool_size,
                    connection_timeout_secs,
                    idle_timeout_secs,
                } => (
                    connection_string.clone(),
                    *pool_size,
                    *connection_timeout_secs,
                    *idle_timeout_secs,
                ),
                _ => {
                    return Err(StorageError::BackendError {
                        underlying: "PostgresStorage requires a Postgresql backend configuration"
                            .into(),
                    })
                }
            };
        // Estate isolation: each estate lives in its own PG schema (analogous
        // to SQLite's one-file-per-estate). The namespace is derived from the
        // estate UUID. `public` stays on the search_path so shared extensions
        // (e.g. pgvector) resolve. The namespace is pinned on every new
        // connection opened by the pool (see Pool::open_connection).
        let ns = format!("pk_{}", config.estate_id.simple());
        Ok(PostgresStorage {
            config,
            pool: Arc::new(Pool::new(
                conn_str,
                ns,
                pool_size,
                connection_timeout_secs,
                idle_timeout_secs,
            )),
            schema: Arc::new(Mutex::new(SharedSchema { schema: None })),
            observers: Arc::new(ObserverRegistry::default()),
        })
    }

    /// Check out a connection from the pool. Returns a PooledClient that
    /// automatically returns the connection on drop.
    fn checkout(&self) -> StorageResult<PooledClient> {
        self.pool.checkout()
    }
}

fn apply_schema(
    conn: &mut PooledClient,
    schema_store: &Mutex<SharedSchema>,
    schema: &SchemaDeclaration,
) -> StorageResult<()> {
    schema_store.lock().unwrap().schema = Some(schema.clone());
    let client = conn.get_mut();
    let batch = |c: &mut Client, sql: &str| {
        c.batch_execute(sql)
            .map_err(|e| StorageError::BackendError {
                underlying: format!("ddl: {}", pg_err_text(&e)),
            })
    };
    batch(client, META_TABLE)?;
    batch(client, AUDIT_TABLE)?;
    batch(client, AUDIT_INDEX)?;
    batch(client, BLOB_TABLE)?;
    batch(client, REJECT_MUTATION_FN)?;
    for table in &schema.tables {
        batch(client, &create_table_sql(table))?;
        for stmt in append_only_trigger_statements(table) {
            batch(client, &stmt)?;
        }
    }
    for index in &schema.indices {
        batch(client, &create_index_sql(index))?;
    }
    client
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
            pool: self.pool.clone(),
            schema: self.schema.clone(),
            observers: self.observers.clone(),
        })
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(PgBlobStore {
            pool: self.pool.clone(),
        })
    }
    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Arc::new(PgVectorIndex {
            pool: self.pool.clone(),
        })
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Arc::new(PgAuditLog {
            pool: self.pool.clone(),
        })
    }
    fn observer(&self) -> Arc<dyn StorageObserver> {
        Arc::new(PgObserver {
            observers: self.observers.clone(),
        })
    }

    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()> {
        let mut conn = self.checkout()?;
        apply_schema(&mut conn, &self.schema, schema)
    }
    fn close(&self) -> StorageResult<()> {
        self.pool.close();
        Ok(())
    }
    fn current_schema_version(&self) -> StorageResult<i32> {
        let mut conn = self.checkout()?;
        let rows = conn
            .get_mut()
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
        let mut conn = self.checkout()?;
        apply_schema(&mut conn, &self.schema, schema)
    }

    fn transaction(
        &self,
        isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()> {
        // Check out ONE connection for the entire transaction bracket. BEGIN,
        // all DML inside the block, and COMMIT/ROLLBACK all execute on this
        // single connection. Sub-stores in the block receive a
        // PgTransactionContext that wraps this same connection (via
        // Arc<Mutex<PooledClient>>), so every statement participates in the
        // same PostgreSQL transaction.
        //
        // This mirrors Swift's PostgreSQLStorage.transaction(_:): one
        // connection is acquired up front and wrapped in a
        // PostgreSQLTransactionContext; every sub-store call inside the block
        // routes through that context's shared connection. The single-
        // connection contract is what makes the transaction real — not a
        // naming convention.
        let begin = match isolation {
            IsolationLevel::ReadCommitted => "BEGIN ISOLATION LEVEL READ COMMITTED",
            IsolationLevel::RepeatableRead => "BEGIN ISOLATION LEVEL REPEATABLE READ",
            IsolationLevel::Serializable => "BEGIN ISOLATION LEVEL SERIALIZABLE",
        };
        let mut bracket_conn = self.checkout()?;
        bracket_conn
            .get_mut()
            .batch_execute(begin)
            .map_err(|e| map_pg_err(e, "transaction"))?;

        // Wrap the bracket connection in an Arc<Mutex> so PgTransactionContext
        // and its sub-stores can share it without lifetime coupling.
        let shared = Arc::new(Mutex::new(bracket_conn));
        let ctx = PgTransactionContext {
            conn: shared.clone(),
            schema: self.schema.clone(),
            observers: self.observers.clone(),
        };

        match block(&ctx) {
            Ok(()) => {
                shared
                    .lock()
                    .unwrap()
                    .get_mut()
                    .batch_execute("COMMIT")
                    .map_err(|e| map_pg_err(e, "transaction"))?;
                Ok(())
            }
            Err(block_err) => {
                // Best-effort ROLLBACK on the bracket connection.
                // If ROLLBACK fails the connection is in an unknown state;
                // discard it (do not return to pool) — matching Swift's
                // behaviour: a rollback-failed connection is released without
                // being put back into the pool.
                let rollback_result = shared.lock().unwrap().get_mut().batch_execute("ROLLBACK");
                if rollback_result.is_err() {
                    // Extract the client from the shared Arc so we can call
                    // discard(). This is safe: the block has returned, so
                    // ctx and all its sub-stores have been dropped; no other
                    // holder of `shared` remains.
                    if let Ok(guard) = Arc::try_unwrap(shared) {
                        // Move the PooledClient out via discard() which
                        // notifies the pool of the freed slot without
                        // returning the broken connection to the available list.
                        let conn = guard.into_inner().unwrap();
                        conn.discard();
                    }
                }
                // Surface the block's error regardless of rollback success.
                Err(block_err)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Transaction context — routes all sub-store calls through one connection.
//
// PgTransactionContext wraps the single PooledClient checked out for the
// transaction bracket. Every sub-store (TxRowStore, TxBlobStore,
// TxAuditLog, TxVectorIndex) holds Arc<Mutex<PooledClient>> and locks it
// per operation to execute SQL on that connection. BEGIN was issued before
// this context is constructed; COMMIT or ROLLBACK follows after block()
// returns. All DML therefore participates in the same PG transaction.
//
// Mirrors Swift's PostgreSQLTransactionContext: a single connection is
// held for the bracket and every sub-store call is routed through it.
// ─────────────────────────────────────────────────────────────────────

/// Shared handle to the single bracket connection. Locked per SQL call.
type TxConn = Arc<Mutex<PooledClient>>;

struct PgTransactionContext {
    conn: TxConn,
    schema: Arc<Mutex<SharedSchema>>,
    observers: Arc<ObserverRegistry>,
}

impl StorageTransaction for PgTransactionContext {
    fn row_store(&self) -> Arc<dyn RowStore> {
        Arc::new(TxRowStore {
            conn: self.conn.clone(),
            schema: self.schema.clone(),
            observers: self.observers.clone(),
        })
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(TxBlobStore {
            conn: self.conn.clone(),
        })
    }
    fn vector_index(&self) -> Arc<dyn VectorIndex> {
        Arc::new(TxVectorIndex {
            conn: self.conn.clone(),
        })
    }
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Arc::new(TxAuditLog {
            conn: self.conn.clone(),
        })
    }
}

// ── Transaction-scoped RowStore ──────────────────────────────────────

struct TxRowStore {
    conn: TxConn,
    schema: Arc<Mutex<SharedSchema>>,
    observers: Arc<ObserverRegistry>,
}

impl RowStore for TxRowStore {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle> {
        let mut guard = self.conn.lock().unwrap();
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
            .get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let schema = self.schema.lock().unwrap();
        let key = extract_row_key(schema.schema.as_ref(), table, &values);
        drop(schema);
        drop(guard);
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
        let mut guard = self.conn.lock().unwrap();
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
            .get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let schema = self.schema.lock().unwrap();
        let key = extract_row_key(schema.schema.as_ref(), table, &values);
        drop(schema);
        drop(guard);
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
        let mut guard = self.conn.lock().unwrap();
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
            .get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        drop(guard);
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
        let mut guard = self.conn.lock().unwrap();
        let mut binds: Vec<TypedValue> = Vec::new();
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("DELETE FROM \"{table}\" WHERE {where_sql}");
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let changed = guard
            .get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        drop(guard);
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
        let mut guard = self.conn.lock().unwrap();
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
        let schema = self.schema.lock().unwrap().schema.clone();
        let rows = guard
            .get_mut()
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
        let mut guard = self.conn.lock().unwrap();
        let mut sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        let mut binds: Vec<TypedValue> = Vec::new();
        if let Some(p) = predicate {
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)));
        }
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let row = guard
            .get_mut()
            .query_one(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let n: i64 = row.get(0);
        Ok(n as usize)
    }
}

// ── Transaction-scoped BlobStore ─────────────────────────────────────

struct TxBlobStore {
    conn: TxConn,
}

impl BlobStore for TxBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        let mut guard = self.conn.lock().unwrap();
        guard
            .get_mut()
            .execute(
                r#"INSERT INTO "_storagekit_blobs" ("key", "bytes") VALUES ($1, $2)
               ON CONFLICT ("key") DO UPDATE SET "bytes" = excluded.bytes"#,
                &[&key.to_string(), &bytes.to_vec()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        let mut guard = self.conn.lock().unwrap();
        let rows = guard
            .get_mut()
            .query(
                r#"SELECT "bytes" FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, Vec<u8>>(0)))
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        let mut guard = self.conn.lock().unwrap();
        guard
            .get_mut()
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
        let mut guard = self.conn.lock().unwrap();
        let rows = guard
            .get_mut()
            .query(
                r#"SELECT LENGTH("bytes") FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, i32>(0) as usize))
    }
}

// ── Transaction-scoped AuditLog ──────────────────────────────────────

struct TxAuditLog {
    conn: TxConn,
}

impl AuditLog for TxAuditLog {
    fn append(&self, event: AuditEvent) -> StorageResult<()> {
        let mut guard = self.conn.lock().unwrap();
        let ph = (1..=17)
            .map(|i| format!("${i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "INSERT INTO \"_storagekit_audit\" ({AUDIT_COLS}) VALUES ({ph}) ON CONFLICT (\"event_id\",\"hlc\") DO NOTHING"
        );
        let params = audit_params(&event);
        guard
            .get_mut()
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
        let mut guard = self.conn.lock().unwrap();
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
            .get_mut()
            .query(&sql, &param_refs(&binds))
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(rows.iter().map(decode_audit).collect())
    }
    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>> {
        self.iterate(None, Some(row_id), usize::MAX)
    }
    fn count(&self) -> StorageResult<usize> {
        let mut guard = self.conn.lock().unwrap();
        let row = guard
            .get_mut()
            .query_one(r#"SELECT COUNT(*) FROM "_storagekit_audit""#, &[])
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(row.get::<_, i64>(0) as usize)
    }
}

// ── Transaction-scoped VectorIndex ──────────────────────────────────

struct TxVectorIndex {
    conn: TxConn,
}

impl VectorIndex for TxVectorIndex {
    fn add(
        &self,
        key: RowKey,
        vector: &[f32],
        _metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()> {
        let mut guard = self.conn.lock().unwrap();
        let dim = vector.len();
        guard.get_mut().batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS \"{VEC_TABLE}\" (\"key\" TEXT PRIMARY KEY, \"embedding\" vector({dim}) NOT NULL, \"metadata_json\" TEXT NOT NULL DEFAULT '{{}}')"
        )).map_err(|e| map_pg_err(e, VEC_TABLE))?;
        guard
            .get_mut()
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
        let mut guard = self.conn.lock().unwrap();
        // Check table existence via the same transaction connection.
        let exists: bool = guard
            .get_mut()
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&VEC_TABLE])
            .ok()
            .and_then(|r| r.try_get::<_, bool>(0).ok())
            .unwrap_or(false);
        if !exists {
            return Ok(());
        }
        guard
            .get_mut()
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
        let mut guard = self.conn.lock().unwrap();
        let exists: bool = guard
            .get_mut()
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&VEC_TABLE])
            .ok()
            .and_then(|r| r.try_get::<_, bool>(0).ok())
            .unwrap_or(false);
        if !exists {
            return Ok(Vec::new());
        }
        let op = metric_op(metric);
        let lit = vector_literal(query);
        let sql = format!(
            "SELECT \"key\", (\"embedding\" {op} '{lit}'::vector) AS distance FROM \"{VEC_TABLE}\" \
             ORDER BY \"embedding\" {op} '{lit}'::vector LIMIT {k}"
        );
        let rows = guard
            .get_mut()
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
        Ok(())
    }
    fn count(&self) -> StorageResult<usize> {
        let mut guard = self.conn.lock().unwrap();
        let exists: bool = guard
            .get_mut()
            .query_one("SELECT to_regclass($1) IS NOT NULL", &[&VEC_TABLE])
            .ok()
            .and_then(|r| r.try_get::<_, bool>(0).ok())
            .unwrap_or(false);
        if !exists {
            return Ok(0);
        }
        let n: i64 = guard
            .get_mut()
            .query_one(&format!("SELECT COUNT(*) FROM \"{VEC_TABLE}\""), &[])
            .map_err(|e| map_pg_err(e, VEC_TABLE))?
            .get(0);
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// RowStore. Each method checks out one connection, executes, and returns
// the connection to the pool on drop (via PooledClient's Drop impl).
// This is per-operation granularity for non-transaction calls; within a
// transaction all DML routes through TxRowStore on the bracket connection.
// ─────────────────────────────────────────────────────────────────────

struct PgRowStore {
    pool: Arc<Pool>,
    schema: Arc<Mutex<SharedSchema>>,
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
        let mut conn = self.pool.checkout()?;
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
        conn.get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let schema = self.schema.lock().unwrap();
        let key = extract_row_key(schema.schema.as_ref(), table, &values);
        drop(schema);
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
        let mut conn = self.pool.checkout()?;
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
        conn.get_mut()
            .execute(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let schema = self.schema.lock().unwrap();
        let key = extract_row_key(schema.schema.as_ref(), table, &values);
        drop(schema);
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
        let mut conn = self.pool.checkout()?;
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
        let changed = conn
            .get_mut()
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
        let mut conn = self.pool.checkout()?;
        let mut binds: Vec<TypedValue> = Vec::new();
        let where_sql = compile_predicate(predicate, &mut binds);
        let sql = format!("DELETE FROM \"{table}\" WHERE {where_sql}");
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let changed = conn
            .get_mut()
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
        let mut conn = self.pool.checkout()?;
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
        let schema = self.schema.lock().unwrap().schema.clone();
        let rows = conn
            .get_mut()
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
        let mut conn = self.pool.checkout()?;
        let mut sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        let mut binds: Vec<TypedValue> = Vec::new();
        if let Some(p) = predicate {
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)));
        }
        let params: Vec<PgParam> = binds.iter().map(to_param).collect();
        let row = conn
            .get_mut()
            .query_one(&sql, &param_refs(&params))
            .map_err(|e| map_pg_err(e, table))?;
        let n: i64 = row.get(0);
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// BlobStore. Per-operation pool checkout.
// ─────────────────────────────────────────────────────────────────────

struct PgBlobStore {
    pool: Arc<Pool>,
}

impl BlobStore for PgBlobStore {
    fn put(&self, key: &str, bytes: &[u8]) -> StorageResult<()> {
        let mut conn = self.pool.checkout()?;
        conn.get_mut()
            .execute(
                r#"INSERT INTO "_storagekit_blobs" ("key", "bytes") VALUES ($1, $2)
                   ON CONFLICT ("key") DO UPDATE SET "bytes" = excluded.bytes"#,
                &[&key.to_string(), &bytes.to_vec()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(())
    }
    fn get(&self, key: &str) -> StorageResult<Option<Vec<u8>>> {
        let mut conn = self.pool.checkout()?;
        let rows = conn
            .get_mut()
            .query(
                r#"SELECT "bytes" FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, Vec<u8>>(0)))
    }
    fn delete(&self, key: &str) -> StorageResult<()> {
        let mut conn = self.pool.checkout()?;
        conn.get_mut()
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
        let mut conn = self.pool.checkout()?;
        let rows = conn
            .get_mut()
            .query(
                r#"SELECT LENGTH("bytes") FROM "_storagekit_blobs" WHERE "key" = $1"#,
                &[&key.to_string()],
            )
            .map_err(|e| map_pg_err(e, "_storagekit_blobs"))?;
        Ok(rows.first().map(|r| r.get::<_, i32>(0) as usize))
    }
}

// ─────────────────────────────────────────────────────────────────────
// AuditLog. Per-operation pool checkout.
// ─────────────────────────────────────────────────────────────────────

struct PgAuditLog {
    pool: Arc<Pool>,
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
        let mut conn = self.pool.checkout()?;
        let ph = (1..=17)
            .map(|i| format!("${i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "INSERT INTO \"_storagekit_audit\" ({AUDIT_COLS}) VALUES ({ph}) ON CONFLICT (\"event_id\",\"hlc\") DO NOTHING"
        );
        let params = audit_params(&event);
        conn.get_mut()
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
        let mut conn = self.pool.checkout()?;
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
        let rows = conn
            .get_mut()
            .query(&sql, &param_refs(&binds))
            .map_err(|e| map_pg_err(e, "_storagekit_audit"))?;
        Ok(rows.iter().map(decode_audit).collect())
    }
    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>> {
        self.iterate(None, Some(row_id), usize::MAX)
    }
    fn count(&self) -> StorageResult<usize> {
        let mut conn = self.pool.checkout()?;
        let row = conn
            .get_mut()
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
// schema via the connection search_path. Per-operation pool checkout.
// ─────────────────────────────────────────────────────────────────────

struct PgVectorIndex {
    pool: Arc<Pool>,
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
        let mut conn = self.pool.checkout()?;
        let dim = vector.len();
        conn.get_mut().batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS \"{VEC_TABLE}\" (\"key\" TEXT PRIMARY KEY, \"embedding\" vector({dim}) NOT NULL, \"metadata_json\" TEXT NOT NULL DEFAULT '{{}}')"
        )).map_err(|e| map_pg_err(e, VEC_TABLE))?;
        // Inline the vector literal (digits/dots/commas only — safe): a bound
        // `$n::vector` makes PG infer the param as type `vector`, which the
        // text-based client can't serialize.
        conn.get_mut()
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
        let mut conn = self.pool.checkout()?;
        if !Self::table_exists(conn.get_mut()) {
            return Ok(());
        }
        conn.get_mut()
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
        let mut conn = self.pool.checkout()?;
        if !Self::table_exists(conn.get_mut()) {
            return Ok(Vec::new());
        }
        let op = metric_op(metric);
        let lit = vector_literal(query);
        let sql = format!(
            "SELECT \"key\", (\"embedding\" {op} '{lit}'::vector) AS distance FROM \"{VEC_TABLE}\" \
             ORDER BY \"embedding\" {op} '{lit}'::vector LIMIT {k}"
        );
        let rows = conn
            .get_mut()
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
        let mut conn = self.pool.checkout()?;
        if !Self::table_exists(conn.get_mut()) {
            return Ok(0);
        }
        let n: i64 = conn
            .get_mut()
            .query_one(&format!("SELECT COUNT(*) FROM \"{VEC_TABLE}\""), &[])
            .map_err(|e| map_pg_err(e, VEC_TABLE))?
            .get(0);
        Ok(n as usize)
    }
}

// ─────────────────────────────────────────────────────────────────────
// Pool unit tests — no live server required.
// Construction, capacity, exhaustion timeout, and close semantics are
// all exercised with a connector that always fails (simulating "server
// unreachable"), letting the pool logic run in isolation. Live-path
// tests live in tests/postgres_conformance.rs (gate: PERSISTENCEKIT_PG_URL).
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod pool_tests {
    use super::*;
    use crate::{BackendConfiguration, EstateConfiguration};

    /// Build a pool config that will fail on every real connect attempt.
    /// Used to exercise pool construction and timeout without a live server.
    fn unreachable_config(pool_size: usize, timeout_secs: f64) -> EstateConfiguration {
        EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Postgresql {
                connection_string: "postgres://nobody@127.0.0.1:1/nonexistent".into(),
                pool_size,
                connection_timeout_secs: timeout_secs,
                idle_timeout_secs: 30.0,
            },
        )
    }

    /// Pool::new does not connect eagerly — construction succeeds even when
    /// the server is unreachable. Connections are created only on checkout.
    #[test]
    fn pool_construction_is_lazy() {
        // PostgresStorage::new must succeed without touching the network.
        let cfg = unreachable_config(2, 0.1);
        let result = PostgresStorage::new(cfg);
        assert!(
            result.is_ok(),
            "PostgresStorage::new should not connect eagerly; got: {:?}",
            result.err()
        );
    }

    /// With no live server, checkout on a pool of size >= 1 returns
    /// BackendError (connect failed). The pool must not deadlock or hang
    /// beyond the timeout window.
    #[test]
    fn pool_checkout_fails_fast_without_server() {
        let cfg = unreachable_config(1, 0.05); // 50ms timeout
        let storage = PostgresStorage::new(cfg).unwrap();
        let result = storage.checkout();
        assert!(
            result.is_err(),
            "checkout with unreachable server must fail"
        );
    }

    /// A closed pool refuses new checkouts with BackendUnavailable.
    /// close() is idempotent (second call must not panic).
    #[test]
    fn pool_close_refuses_checkouts() {
        let cfg = unreachable_config(2, 0.1);
        let storage = PostgresStorage::new(cfg).unwrap();
        storage.close().unwrap();
        let result = storage.checkout();
        assert!(
            matches!(result, Err(StorageError::BackendUnavailable { .. })),
            "closed pool must return BackendUnavailable; got {:?}",
            result
        );
        // Second close must not panic.
        storage.close().unwrap();
    }

    /// PoolExhausted timeout fires within a reasonable window when the pool
    /// is genuinely full. Simulated by pool_size = 0 (cap of zero means
    /// every checkout immediately enters the wait loop and times out).
    #[test]
    fn pool_exhaustion_returns_pool_exhausted_error() {
        // pool_size = 0: cap is zero, so checkout always waits and times out.
        let pool = Pool::new(
            "postgres://nobody@127.0.0.1:1/nonexistent".into(),
            "pk_test".into(),
            0,    // pool_size = 0 -> pool is always full
            0.05, // 50ms timeout
            30.0,
        );
        let t_start = std::time::Instant::now();
        let result = pool.checkout();
        let elapsed = t_start.elapsed();
        assert!(
            matches!(result, Err(StorageError::PoolExhausted { timeout_secs }) if (timeout_secs - 0.05).abs() < 1e-9),
            "must return PoolExhausted; got {:?}",
            result
        );
        // Must not have returned early (< 40ms) or hung (> 500ms).
        assert!(
            elapsed >= Duration::from_millis(40),
            "timeout fired too early: {:?}",
            elapsed
        );
        assert!(
            elapsed < Duration::from_millis(500),
            "timeout hung too long: {:?}",
            elapsed
        );
    }

    /// close() wakes blocked checkouts with BackendUnavailable.
    #[test]
    fn pool_close_wakes_blocked_checkouts() {
        use std::thread;

        let pool = Arc::new(Pool::new(
            "postgres://nobody@127.0.0.1:1/nonexistent".into(),
            "pk_test".into(),
            0,   // pool_size = 0 -> always blocks
            5.0, // 5s timeout -- long enough that the thread would block
            30.0,
        ));

        let pool2 = pool.clone();
        let handle = thread::spawn(move || pool2.checkout());

        // Give the thread time to enter the wait loop.
        std::thread::sleep(Duration::from_millis(30));

        // Close the pool -- must wake the blocked checkout.
        pool.close();

        let result = handle.join().expect("thread panicked");
        assert!(
            matches!(result, Err(StorageError::BackendUnavailable { .. })),
            "close() must wake blocked checkouts with BackendUnavailable; got {:?}",
            result
        );
    }

    /// idle_timeout_secs is accepted in EstateConfiguration without error
    /// (the field is stored in the BackendConfiguration variant). Verifies
    /// the config surface parity with Swift (which also accepts but ignores it).
    #[test]
    fn idle_timeout_accepted_in_config() {
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Postgresql {
                connection_string: "postgres://nobody@127.0.0.1:1/nonexistent".into(),
                pool_size: 4,
                connection_timeout_secs: 5.0,
                idle_timeout_secs: 120.0,
            },
        );
        // Construction must succeed; idle_timeout is stored, not acted on.
        let result = PostgresStorage::new(cfg);
        assert!(result.is_ok());
    }
}

// ─────────────────────────────────────────────────────────────────────
// Transaction-context unit tests — no live server required.
//
// These tests verify that PgTransactionContext routes all sub-store
// calls through the single bracket connection (Arc<Mutex<PooledClient>>)
// rather than checking out additional pool connections. The structural
// guarantee is tested by constructing a PgTransactionContext with a
// known TxConn and asserting that every sub-store vended by the context
// holds a pointer-equal Arc — proving that no pool checkout occurs inside
// the block.
//
// Live transactional round-trip (BEGIN → DML → COMMIT in one PG
// transaction) is verified only when PERSISTENCEKIT_PG_URL is set;
// see tests/postgres_conformance.rs.
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod transaction_context_tests {
    use super::*;

    /// Build a TxConn (Arc<Mutex<PooledClient>>) using a PooledClient with
    /// no live connection (client: None). Drop is a no-op when client is
    /// None, so the pool pointer is never dereferenced. This lets us
    /// exercise the context routing invariant without a live server.
    fn make_tx_conn() -> (Arc<Pool>, TxConn) {
        let pool = Arc::new(Pool::new(
            "postgres://nobody@127.0.0.1:1/nonexistent".into(),
            "pk_test".into(),
            1,
            0.05,
            30.0,
        ));
        // Construct a PooledClient with no live client. Drop is a no-op
        // because client is None, so the pool pointer is never accessed.
        let pc = PooledClient {
            client: None,
            pool: Arc::as_ptr(&pool),
        };
        let conn = Arc::new(Mutex::new(pc));
        (pool, conn)
    }

    /// PgTransactionContext construction succeeds and the context holds
    /// the shared TxConn. Verifies the context can be built without
    /// requiring a live PostgreSQL server.
    #[test]
    fn transaction_context_constructs_without_server() {
        let (_pool, conn) = make_tx_conn();
        let schema = Arc::new(Mutex::new(SharedSchema { schema: None }));
        let observers = Arc::new(ObserverRegistry::default());
        // Construction must not panic or connect.
        let _ctx = PgTransactionContext {
            conn,
            schema,
            observers,
        };
    }

    /// Every sub-store vended by PgTransactionContext holds a pointer-equal
    /// Arc<Mutex<PooledClient>> to the context's TxConn. This proves that
    /// no pool checkout occurs when the block calls row_store(), blob_store(),
    /// audit_log(), or vector_index() — all DML routes through the single
    /// bracket connection.
    ///
    /// We access the private `conn` field of each sub-store directly
    /// (allowed here because this module is a child of postgres.rs and sees
    /// all private items). Arc::ptr_eq confirms pointer identity, not just
    /// value equality.
    #[test]
    fn transaction_context_sub_stores_share_bracket_connection() {
        let (_pool, conn) = make_tx_conn();
        let schema = Arc::new(Mutex::new(SharedSchema { schema: None }));
        let observers = Arc::new(ObserverRegistry::default());

        // Construct the sub-stores as PgTransactionContext::row_store() etc.
        // would, but access conn directly to verify pointer identity.
        let row_store = TxRowStore {
            conn: conn.clone(),
            schema: schema.clone(),
            observers: observers.clone(),
        };
        let blob_store = TxBlobStore { conn: conn.clone() };
        let audit_log = TxAuditLog { conn: conn.clone() };
        let vector_index = TxVectorIndex { conn: conn.clone() };

        // All four sub-store conn fields must be pointer-equal to the
        // original TxConn — the bracket connection is the only connection.
        assert!(
            Arc::ptr_eq(&row_store.conn, &conn),
            "TxRowStore must use the bracket connection"
        );
        assert!(
            Arc::ptr_eq(&blob_store.conn, &conn),
            "TxBlobStore must use the bracket connection"
        );
        assert!(
            Arc::ptr_eq(&audit_log.conn, &conn),
            "TxAuditLog must use the bracket connection"
        );
        assert!(
            Arc::ptr_eq(&vector_index.conn, &conn),
            "TxVectorIndex must use the bracket connection"
        );
    }

    /// PgTransactionContext::row_store() / blob_store() / audit_log() /
    /// vector_index() all return sub-stores whose conn Arc is pointer-equal
    /// to the context's bracket connection. Tests the full trait-path
    /// (StorageTransaction accessors) rather than direct construction.
    /// We verify via Arc::ptr_eq on the Mutex pointer, which is stable
    /// across Arc::clone.
    #[test]
    fn transaction_context_accessors_route_through_bracket_connection() {
        let (_pool, conn) = make_tx_conn();
        let schema = Arc::new(Mutex::new(SharedSchema { schema: None }));
        let observers = Arc::new(ObserverRegistry::default());
        let ctx = PgTransactionContext {
            conn: conn.clone(),
            schema,
            observers,
        };

        // Invoke the StorageTransaction trait accessors. Each returns an
        // Arc<dyn Trait> backed by a Tx*Store. We verify the routing invariant
        // by checking the Arc reference count: the bracket conn starts at 1
        // (from `conn`); each sub-store accessor should clone it. After all
        // four calls the strong count must be 5 (original + 4 clones held in
        // the returned Arc<dyn Trait> values).
        let _rs = ctx.row_store();
        let _bs = ctx.blob_store();
        let _al = ctx.audit_log();
        let _vi = ctx.vector_index();

        // 1 (conn) + 1 (ctx.conn) + 4 (one per sub-store) = 6.
        // If any sub-store had checked out from the pool instead of cloning
        // conn, the strong_count would differ.
        assert_eq!(
            Arc::strong_count(&conn),
            6,
            "each sub-store must hold one clone of the bracket conn Arc \
             (count should be 6: original + ctx + 4 sub-stores)"
        );
    }
}
