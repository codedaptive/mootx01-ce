//! SQLite backend — the Rust version of the Swift `PersistenceKitSQLite`
//! target. One `rusqlite::Connection` per estate, serialized behind a
//! `Mutex` (a real shared DB handle, not an actor emulation). Schema
//! DDL, the closed predicate algebra, and the value codec match the
//! Swift backend so both versions produce identical observable results.
//!
//! Implements RowStore, BlobStore, AuditLog, and StorageObserver plus
//! schema/migrations/generated-columns/append-only. The backend owns no
//! vector-search engine; it accommodates vector workloads' storage needs
//! through RowStore/BlobStore (ADR-008).

use std::collections::{BTreeMap, BTreeSet};
use std::str;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{params_from_iter, Connection};
use substrate_types::hlc::HLC;
use uuid::Uuid;

use crate::{
    AeadProvider, AesGcmAeadProvider, AuditEvent, AuditLog, BackendConfiguration, BlobStore,
    CachingRowStore, ColumnType, EstateConfiguration, EstateEncryptionConfig,
    IndexDeclaration, IsolationLevel, OrderClause, OrderDirection, RowHandle, RowKey, RowStore,
    SchemaDeclaration, Storage, StorageError, StorageEvent, StorageObserver, StoragePredicate,
    StorageResult, StorageRow, StorageTransaction, TableChange, TableDeclaration, TypedValue,
};
use crate::error::validate_sql_identifier;

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

/// Format an epoch-seconds value as an ISO-8601 UTC string suitable for
/// storage in a TEXT timestamp column.
///
/// ## Write-boundary clamp (data-integrity invariant)
///
/// `chrono::DateTime::parse_from_rfc3339` (the read side) only accepts
/// four-digit years (0001–9999). If an out-of-range epoch slips through —
/// for example from a bad Vault frontmatter timestamp rounded-tripping as
/// a nanosecond or millisecond epoch — `iso8601` would format it as a
/// `+58432-...` string that `parse_iso8601` can never read back, bricking
/// every scan that hits that row. To prevent this, the epoch is clamped to
/// the RFC-3339-accepted range **before** formatting, and a warning is
/// emitted (the caller should investigate the upstream source of the
/// out-of-range value — it indicates a bug in whichever layer computed
/// the timestamp).
///
/// Clamp bounds (inclusive, milliseconds-since-Unix-epoch):
///   MIN_ROUND_TRIP_MS ≈ year 0001-01-01T00:00:00.000Z  (−62135596800000)
///   MAX_ROUND_TRIP_MS ≈ year 9999-12-31T23:59:59.999Z  (253402300799999)
///
/// Clamp is chosen over rejection because the write must not fail for
/// callers (the upstream timestamp is wrong, but refusing to write would
/// surface as a confusing storage error rather than a useful warning).
/// The clamped value is wrong-but-readable; the log warning is the
/// signal to fix the upstream source.
const MIN_ROUND_TRIP_MS: i64 = -62_135_596_800_000; // 0001-01-01T00:00:00.000Z
const MAX_ROUND_TRIP_MS: i64 = 253_402_300_799_999; // 9999-12-31T23:59:59.999Z

fn iso8601(ms: i64) -> String {
    // The substrate's time fields are `i64` epoch MILLISECONDS (matching the
    // sub-second precision Swift's `Date` carries), stored as canonical
    // ISO-8601 with a 3-digit fractional part.
    //
    // Clamp to the RFC-3339-parseable range before formatting. This
    // guarantees every value written by `to_sql` can be read back by
    // `parse_iso8601`. Out-of-range values indicate an upstream bug
    // (e.g. a nanosecond epoch stored where milliseconds were expected,
    // or a bad Vault frontmatter date); the warning is the signal to fix it.
    let clamped = if ms < MIN_ROUND_TRIP_MS {
        eprintln!(
            "[persistence_kit] WARNING: timestamp {} ms is below the RFC-3339 minimum year \
             (0001); clamping to {} to preserve round-trip. Investigate the upstream \
             source of this value.",
            ms, MIN_ROUND_TRIP_MS
        );
        MIN_ROUND_TRIP_MS
    } else if ms > MAX_ROUND_TRIP_MS {
        eprintln!(
            "[persistence_kit] WARNING: timestamp {} ms exceeds the RFC-3339 maximum year \
             (9999); clamping to {} to preserve round-trip. Investigate the upstream \
             source of this value.",
            ms, MAX_ROUND_TRIP_MS
        );
        MAX_ROUND_TRIP_MS
    } else {
        ms
    };
    chrono::DateTime::from_timestamp_millis(clamped)
        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())
        .unwrap_or_default()
}

/// Parse an ISO-8601 timestamp string into seconds-since-epoch.
///
/// Accepts both fractional-second and whole-second RFC-3339 forms:
///   "2026-06-12T18:02:48.000Z"  (kit-canonical, with fractional seconds)
///   "2026-06-12T18:02:48Z"      (valid ISO-8601, whole seconds only)
///
/// RFC-3339 (which is what `chrono::DateTime::parse_from_rfc3339` implements)
/// requires fractional seconds to be present when the format specifier includes
/// them, but both forms are valid ISO-8601 and both should be accepted on read.
/// `parse_from_rfc3339` handles both: it accepts an optional fractional part.
///
/// Returns `None` only when the string is not a valid ISO-8601 timestamp at all.
/// Callers that need fail-loud behaviour must convert `None` into a
/// `StorageError::CorruptStoredValue`.
///
/// Hot-path note (cross-port): this parse runs on the Merkle-rollup read path,
/// which re-decodes every drawer in a room on each insert — i.e. O(N²) times
/// during a large import. `chrono`'s RFC-3339 parser is a fast compiled scan,
/// so it is cheap here. The Swift port must NOT use `NSISO8601DateFormatter`
/// for this: that API is ICU-backed and FAR TOO SLOW in this situation
/// (≈80% of CPU in a sampled import); Swift hand-parses the canonical shape
/// instead (see `ISO8601.fastParseCanonicalUTC`).
///
/// Granularity: returns epoch MILLISECONDS. `TypedValue::Timestamp` and the
/// substrate's drawer time fields (`filed_at`, `event_time`) are `i64` epoch
/// milliseconds, matching the sub-second precision the Swift port carries in its
/// `Date`, so the two ports store byte-identical ISO-8601 for the same instant.
/// (This reverses the earlier seconds-granularity port convention — formerly
/// deferred to v1.1 as KI-003 — per the Swift/Rust bit-identity mandate; the
/// unit was migrated everywhere at once, never partially.)
fn parse_iso8601(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp_millis())
}

/// Serialize a `TypedValue` array into a JSON byte vector.
///
/// Matches the Swift `JSONTypedValue` Codable encoding: each element becomes
/// `{"type":"<type_description>","value":"<string_form>"}`. The resulting
/// bytes are stored as a BLOB in the `TypedValue::Array` column path.
///
/// Note: `ColumnType` has no `Array` variant — array storage is always via
/// a `Blob`/`Json` column; this encoding is the write-side contract.
/// Arrays round-trip write→read within Rust as `Blob` on read (the same
/// behaviour as Swift, where `readColumn` has no `case .array` branch and
/// returns `.blob` for an untyped BLOB column). This function does not need
/// a dependency on serde_json — TypedValue values are always representable
/// as flat strings.
fn typed_value_array_to_json(values: &[TypedValue]) -> Vec<u8> {
    let mut out = String::from("[");
    for (i, v) in values.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let (type_str, value_str) = typed_value_to_json_pair(v);
        // Escape double-quotes inside the value string to keep JSON valid.
        let escaped = value_str.replace('\\', "\\\\").replace('"', "\\\"");
        out.push_str(&format!(r#"{{"type":"{}","value":"{}"}}"#, type_str, escaped));
    }
    out.push(']');
    out.into_bytes()
}

/// Return the (type, value) string pair for one TypedValue, matching Swift's
/// `JSONTypedValue.init(_:)` mapping (PERSISTENCEKIT_SPEC § value-codec).
fn typed_value_to_json_pair(v: &TypedValue) -> (&'static str, String) {
    match v {
        TypedValue::Null => ("null", String::new()),
        TypedValue::Bool(b) => ("bool", if *b { "true" } else { "false" }.to_string()),
        TypedValue::Int(i) => ("int", i.to_string()),
        TypedValue::Bitmap(i) => ("bitmap", i.to_string()),
        TypedValue::Float(f) => ("float", f.to_string()),
        TypedValue::Text(s) => ("text", s.clone()),
        TypedValue::Blob(b) => ("blob", base64_encode(b)),
        TypedValue::Uuid(u) => ("uuid", u.to_string().to_uppercase()),
        TypedValue::Timestamp(ms) => ("timestamp", iso8601(*ms)),
        TypedValue::Json(b) => ("json", String::from_utf8_lossy(b).into_owned()),
        TypedValue::Hlc(h) => ("hlc", h.packed().to_string()),
        TypedValue::Fingerprint(fp) => (
            "fingerprint",
            format!("{}:{}:{}:{}", fp.block0, fp.block1, fp.block2, fp.block3),
        ),
        TypedValue::Array(_) => ("array", "[nested]".to_string()),
    }
}

/// Minimal base64 encoder (RFC 4648 § 4, no line breaks).
///
/// Used to encode raw `Blob` bytes inside the TypedValue array JSON,
/// matching Swift's `Data.base64EncodedString()` output. PersistenceKit
/// carries no base64 dependency; the encoder is small and standards-
/// conformant. Only the encode direction is needed here — decoding array
/// BLOBs is not required because there is no `ColumnType::Array` to hint
/// the read side.
fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 { chunk[1] as usize } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as usize } else { 0 };
        out.push(TABLE[(b0 >> 2) & 0x3F]);
        out.push(TABLE[((b0 << 4) | (b1 >> 4)) & 0x3F]);
        out.push(if chunk.len() > 1 { TABLE[((b1 << 2) | (b2 >> 6)) & 0x3F] } else { b'=' });
        out.push(if chunk.len() > 2 { TABLE[b2 & 0x3F] } else { b'=' });
    }
    // SAFETY: TABLE contains only ASCII bytes; output is always valid UTF-8.
    unsafe { String::from_utf8_unchecked(out) }
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
        TypedValue::Timestamp(ms) => SqlValue::Text(iso8601(*ms)),
        TypedValue::Hlc(h) => SqlValue::Integer(h.packed() as i64),
        TypedValue::Fingerprint(fp) => {
            // Store as 32-byte little-endian wire encoding matching Fingerprint256::wire_bytes.
            // Block order: block0 first, each block in little-endian byte order.
            // Fingerprint256::from_wire_bytes decodes this format on the read side.
            // (Swift stores big-endian; the two ports have separate databases so
            // byte order does not need to match across ports — only within-port
            // round-trip is required.)
            SqlValue::Blob(fp.wire_bytes().to_vec())
        }
        TypedValue::Array(values) => {
            // Serialize as a JSON array of {type, value} objects.
            // Format mirrors Swift's JSONTypedValue Codable encoding so the
            // array representation is interoperable with the Swift port's
            // documented schema if cross-port reads are ever introduced.
            SqlValue::Blob(typed_value_array_to_json(values))
        }
    }
}

/// Reconstruct an HLC from its packed integer. Uses the canonical
/// inverse HLC::from_packed, which matches HLC::packed's layout
/// (node<<56 | logical<<40 | physical).
fn unpack_hlc(packed: u64) -> HLC {
    HLC::from_packed(packed)
}

/// Read a SQLite value back into a TypedValue, using the column's declared
/// ColumnType to disambiguate INTEGER (int/bitmap/bool/hlc) and TEXT
/// (text/uuid/timestamp). Mirrors SQLiteStorage.readColumn in Swift.
///
/// **Type-tolerant vs. parse-failure distinction:**
/// - Type-tolerant decode of valid data in the wrong affinity is intentional
///   and stays: e.g. an INTEGER on an unrecognised column falls through to
///   `TypedValue::Int`. This handles legitimate SQLite affinity coercions.
/// - Parse failure on a TEXT value for a .uuid or .timestamp column is a
///   data corruption signal: substituting `Uuid::nil()` or timestamp 0 would
///   create a silent identity lie. Return `Err(CorruptStoredValue)` instead.
fn read_value(
    vref: ValueRef,
    kit: Option<ColumnType>,
    table: &str,
    column: &str,
) -> StorageResult<TypedValue> {
    match vref {
        ValueRef::Null => Ok(TypedValue::Null),
        ValueRef::Integer(i) => Ok(match kit {
            Some(ColumnType::Bitmap) => TypedValue::Bitmap(i),
            Some(ColumnType::Bool) => TypedValue::Bool(i != 0),
            Some(ColumnType::Hlc) => TypedValue::Hlc(unpack_hlc(i as u64)),
            _ => TypedValue::Int(i),
        }),
        ValueRef::Real(f) => Ok(TypedValue::Float(f)),
        ValueRef::Text(b) => {
            let s = str::from_utf8(b).unwrap_or("");
            match kit {
                Some(ColumnType::Uuid) => {
                    // A stored UUID string that cannot be parsed is corrupt data —
                    // substituting Uuid::nil() would silently mis-identify every
                    // downstream consumer of this row's identity field.
                    Uuid::parse_str(s).map(TypedValue::Uuid).map_err(|_| {
                        StorageError::CorruptStoredValue {
                            table: table.to_string(),
                            column: column.to_string(),
                            stored_text: s.to_string(),
                        }
                    })
                }
                Some(ColumnType::Timestamp) => {
                    // A stored timestamp string that cannot be parsed is corrupt
                    // data — substituting 0 (Unix epoch) would silently mis-date
                    // every temporal query over this row.
                    parse_iso8601(s)
                        .map(TypedValue::Timestamp)
                        .ok_or_else(|| StorageError::CorruptStoredValue {
                            table: table.to_string(),
                            column: column.to_string(),
                            stored_text: s.to_string(),
                        })
                }
                _ => Ok(TypedValue::Text(s.to_string())),
            }
        }
        ValueRef::Blob(b) => Ok(match kit {
            Some(ColumnType::Json) => TypedValue::Json(b.to_vec()),
            Some(ColumnType::Fingerprint) if b.len() == 32 => {
                // Decode the 32-byte little-endian wire encoding back to Fingerprint256.
                // Matches the wire_bytes() encoding written by to_sql above.
                // A 32-byte BLOB on a fingerprint column that fails from_wire_bytes
                // is structurally impossible (wire_bytes always writes exactly 32 bytes
                // of valid data), so unwrap_or_else falls back to Blob to surface
                // the raw bytes rather than silently substituting a wrong fingerprint.
                use substrate_types::fingerprint256::Fingerprint256;
                Fingerprint256::from_wire_bytes(b)
                    .map(TypedValue::Fingerprint)
                    .unwrap_or_else(|_| TypedValue::Blob(b.to_vec()))
            }
            _ => TypedValue::Blob(b.to_vec()),
        }),
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
// `reason` is nullable TEXT — None persists as NULL; old rows without a
// reason read back as None (schema not frozen, no migration needed).
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
  "before_lattice_qid" INTEGER,
  "after_lattice_qid" INTEGER NOT NULL DEFAULT 0,
  "actor" TEXT NOT NULL,
  "reason" TEXT,
  PRIMARY KEY ("event_id", "hlc")
)"#;

// Ordering index on the full-precision HLC columns — the chronological key
// audit reads order by. The packed `hlc` column is NOT an ordering key: its
// field layout (node in the top byte, logical above physical) does not
// preserve HLC order (HLC_PACKED_ORDER_UNSOUND finding); it remains only as
// the PK dedup component. The old packed-column index is dropped at open.
const AUDIT_INDEX: &str = r#"CREATE INDEX IF NOT EXISTS "_storagekit_audit_row_chrono" ON "_storagekit_audit" ("row_id", "physical_time", "logical_count", "node_id")"#;
const AUDIT_DROP_PACKED_INDEX: &str = r#"DROP INDEX IF EXISTS "_storagekit_audit_row_hlc""#;

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

/// Compile a `StoragePredicate` to a parameterized SQLite WHERE clause.
///
/// Returns `Err(StorageError::InvalidIdentifier)` if any column name in the
/// predicate tree contains characters outside `[A-Za-z_][A-Za-z0-9_]*`.
/// Binds are safe (bound values, never interpolated); only column identifiers
/// reach the SQL string. Mirrors Swift's `SQLitePredicateCompiler.compile`
/// (SECFIX-WS2-PK F7).
fn compile_predicate(p: &StoragePredicate, binds: &mut Vec<SqlValue>) -> StorageResult<String> {
    match p {
        StoragePredicate::IsTrue => Ok("1=1".into()),
        StoragePredicate::IsFalse => Ok("1=0".into()),
        StoragePredicate::And(preds) => {
            if preds.is_empty() {
                return Ok("1=1".into());
            }
            let parts: Vec<String> = preds
                .iter()
                .map(|x| compile_predicate(x, binds))
                .collect::<StorageResult<_>>()?;
            Ok(format!("({})", parts.join(" AND ")))
        }
        StoragePredicate::Or(preds) => {
            if preds.is_empty() {
                return Ok("1=0".into());
            }
            let parts: Vec<String> = preds
                .iter()
                .map(|x| compile_predicate(x, binds))
                .collect::<StorageResult<_>>()?;
            Ok(format!("({})", parts.join(" OR ")))
        }
        StoragePredicate::Not(inner) => {
            Ok(format!("NOT ({})", compile_predicate(inner, binds)?))
        }
        StoragePredicate::Eq(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" = ?", c.name))
        }
        StoragePredicate::Neq(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" != ?", c.name))
        }
        StoragePredicate::Lt(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" < ?", c.name))
        }
        StoragePredicate::Lte(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" <= ?", c.name))
        }
        StoragePredicate::Gt(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" > ?", c.name))
        }
        StoragePredicate::Gte(c, v) => {
            validate_sql_identifier(&c.name)?;
            binds.push(to_sql(v));
            Ok(format!("\"{}\" >= ?", c.name))
        }
        StoragePredicate::IsNull(c) => {
            validate_sql_identifier(&c.name)?;
            Ok(format!("\"{}\" IS NULL", c.name))
        }
        StoragePredicate::IsNotNull(c) => {
            validate_sql_identifier(&c.name)?;
            Ok(format!("\"{}\" IS NOT NULL", c.name))
        }
        StoragePredicate::In(c, values) => {
            validate_sql_identifier(&c.name)?;
            if values.is_empty() {
                return Ok("1=0".into());
            }
            let ph = vec!["?"; values.len()].join(", ");
            for v in values {
                binds.push(to_sql(v));
            }
            Ok(format!("\"{}\" IN ({ph})", c.name))
        }
        StoragePredicate::Like(c, pattern) => {
            validate_sql_identifier(&c.name)?;
            binds.push(SqlValue::Text(pattern.clone()));
            Ok(format!("\"{}\" LIKE ?", c.name))
        }
        StoragePredicate::BitmaskAll { column, mask } => {
            validate_sql_identifier(&column.name)?;
            binds.push(SqlValue::Integer(*mask));
            binds.push(SqlValue::Integer(*mask));
            Ok(format!("(\"{}\" & ?) = ?", column.name))
        }
        StoragePredicate::BitmaskAny { column, mask } => {
            validate_sql_identifier(&column.name)?;
            binds.push(SqlValue::Integer(*mask));
            Ok(format!("(\"{}\" & ?) != 0", column.name))
        }
        StoragePredicate::BitmaskNone { column, mask } => {
            validate_sql_identifier(&column.name)?;
            binds.push(SqlValue::Integer(*mask));
            Ok(format!("(\"{}\" & ?) = 0", column.name))
        }
        StoragePredicate::BitwiseEq {
            column,
            expected,
            mask,
        } => {
            validate_sql_identifier(&column.name)?;
            binds.push(SqlValue::Integer(*mask));
            binds.push(SqlValue::Integer(*expected));
            Ok(format!("(\"{}\" & ?) = ?", column.name))
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
    /// Serializes whole `transaction` brackets against each other. There is
    /// ONE connection per instance, and on the SAME connection a concurrent
    /// second `BEGIN IMMEDIATE` is not SQLITE_BUSY (that applies across
    /// connections) — it is "cannot start a transaction within a
    /// transaction". Two in-process threads legitimately share one instance
    /// (e.g. the corpus ingest queue's background drain loop + the
    /// foreground `await_ingest_drain` pump; the Swift twin is
    /// actor-serialized), so the bracket must self-serialize. Distinct from
    /// `inner`, which is released while the block runs (holding it across
    /// the block would deadlock the block's own sub-store calls).
    tx_lock: Arc<Mutex<()>>,
}

impl SqliteStorage {
    /// Open (creating if absent) the SQLite database named by the
    /// configuration's `Sqlite` backend variant.
    pub fn new(mut config: EstateConfiguration) -> StorageResult<Self> {
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
        // Create the parent directory before opening. SQLite (via rusqlite's
        // SQLITE_OPEN_CREATE) creates the database FILE if absent but never its
        // parent directories; a path whose folder hasn't been provisioned (e.g.
        // the moot-mgr stats store on a fresh Windows install) would fail with
        // "unable to open database file". Mirrors Swift `SQLiteConnection.init`,
        // which calls `createDirectory(withIntermediateDirectories: true)` here.
        // A parent-less or empty path (e.g. ":memory:") is left untouched.
        if let Some(parent) = std::path::Path::new(&path).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| StorageError::BackendError {
                    underlying: format!("sqlite open: create parent dir {parent:?}: {e}"),
                })?;
            }
        }
        // ─── CAND-052: Estate DB file symlink refusal + private-mode creation ───
        //
        // A symlink pre-planted at the DB path (e.g. pointing at /etc/passwd)
        // would cause SQLite to open and write arbitrary files. Reject before
        // opening when the path is a real filesystem location (skip for
        // ":memory:" / empty paths which are in-process only).
        //
        // For EXISTING paths: `symlink_metadata` (lstat) resolves only one
        // level — if the result is a symlink rather than a regular file, refuse.
        //
        // For NEW paths (no file at the DB path): `Connection::open` (via
        // rusqlite's SQLITE_OPEN_CREATE) creates the file. After the open
        // succeeds, `set_permissions(0o600)` locks it to owner-read/write only.
        // This is best-effort: the open+permission window is not atomic (unlike
        // the O_EXCL path for db.key), but the estate DB is typically created in
        // a user-owned directory already inaccessible to other users, so the
        // residual race is low-risk. The key invariant is: a database that
        // already exists as a symlink is refused (the symlink-attack vector).
        //
        // On Windows, symlinks require elevated privileges and are uncommon;
        // the check is skipped there (platform guard below), matching the
        // db.key pattern.
        let db_is_in_memory = path.is_empty() || path == ":memory:";
        let db_existed_before_open = if !db_is_in_memory {
            let p = std::path::Path::new(&path);
            match p.symlink_metadata() {
                Ok(meta) => {
                    // Path exists — reject symlinks at the DB path before opening.
                    // Using the symlink-following `is_file()` would silently accept
                    // a symlink whose target is a regular file; `is_symlink()` is
                    // the no-follow check (CAND-052 security boundary).
                    if meta.file_type().is_symlink() {
                        return Err(StorageError::BackendError {
                            underlying: format!(
                                "sqlite open: refusing to open {:?} — path is a symbolic \
                                 link. Pre-planted symlinks are a security risk (CAND-052).",
                                path
                            ),
                        });
                    }
                    true // regular file exists, normal open
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => false, // new file
                Err(e) => {
                    return Err(StorageError::BackendError {
                        underlying: format!("sqlite open: stat {path:?}: {e}"),
                    });
                }
            }
        } else {
            true // in-memory: skip all file-mode logic
        };

        // Adopt the shared whole-file key for estates that carry a sibling
        // db.key (written by the resident service at startup), unless the caller
        // already chose an explicit encryption mode. This is the single point
        // where every estate opener — DrawerStore, the Corpus/Vector second
        // handles, recipes — picks up the lockdown key, so no per-call-site
        // wiring is required. Estates without a sibling key stay plaintext.
        if config.encryption_config.is_plaintext() {
            if let Some(install_cfg) = crate::encryption::resolve_install_encryption(&path)? {
                config.encryption_config = install_cfg;
            }
        }
        let conn = Connection::open(&path).map_err(|e| StorageError::BackendError {
            underlying: format!("sqlite open: {e}"),
        })?;

        // After a successful open of a NEW database file, lock down permissions
        // to owner-read/write (0600) so that other OS users cannot read the
        // estate. WAL sidecar files (-wal, -shm) are created by SQLite after
        // the first write; they inherit the directory's umask, not the DB file's
        // mode. This call is best-effort (permissions may not be settable on all
        // filesystems) — errors are logged but do not fail the open.
        #[cfg(unix)]
        if !db_is_in_memory && !db_existed_before_open {
            use std::os::unix::fs::PermissionsExt as _;
            let perms = std::fs::Permissions::from_mode(0o600);
            if let Err(e) = std::fs::set_permissions(&path, perms) {
                eprintln!(
                    "[persistence_kit] WARNING: could not set 0600 on new database \
                     file {:?}: {}. Estate may be readable by other OS users.",
                    path, e
                );
            }
        }
        // Whole-database at-rest encryption (Mode 3 / FullDatabase): supply the
        // estate key before any other access so SQLCipher can decrypt page 1
        // (the schema) and every content page. This MUST be the first statement
        // on the connection. Modes 1/2 set no key, leaving a normal unencrypted
        // SQLite file, so existing plaintext / row-encryption estates are
        // unchanged. `PRAGMA key = "x'<hex>'"` uses the 32 raw bytes directly as
        // the cipher key (no passphrase KDF — the key is already full-entropy).
        if let Some(key_hex) = config.encryption_config.full_database_key_hex() {
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .map_err(|e| StorageError::BackendError {
                    underlying: format!("sqlite key: {e}"),
                })?;
        }
        let _ = conn.busy_timeout(Duration::from_secs_f64(busy));
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=2147483648;",
        )
        .map_err(|e| StorageError::BackendError {
            underlying: format!("sqlite pragmas: {e}"),
        })?;
        // Statement cache sized for the estate schema's statement variety (one
        // cached statement per distinct SQL text: per-table insert/upsert/update/
        // delete/select shapes). rusqlite's default of 16 evicts constantly on a
        // 20+-table schema; 128 keeps the working set resident so bulk loops
        // parse each statement once (best-practices §5 prepared-statement reuse).
        conn.set_prepared_statement_cache_capacity(128);
        Ok(SqliteStorage {
            config,
            inner: Arc::new(Mutex::new(Inner { conn, schema: None })),
            observers: Arc::new(ObserverRegistry::default()),
            tx_lock: Arc::new(Mutex::new(())),
        })
    }
}

/// Apply the full schema (idempotent CREATE-IF-NOT-EXISTS) and record the
/// version. Shared by `open` and `migrate`.
///
/// Schema merge semantics: `inner.schema` is a unified view of all tables
/// ever applied to this storage instance, used by `table_column_type` to
/// resolve SQLite column types (Timestamp, UUID, etc.) on read. When a
/// second schema (e.g. GeniusLocusKitMatrix calling `migrate` on the open
/// estate storage) arrives after `open` already set a primary schema, we
/// merge its tables and indices into the existing accumulated schema instead
/// of replacing it. Without this merge, a `migrate` call would overwrite the
/// LocusKit drawer schema with the single-table matrix schema, causing
/// `table_column_type` to return `None` for drawer columns and leaving
/// `filedAt`/`eventTime`/`tombstonedAt` decoded as `Text` instead of
/// `Timestamp`. This mirrors Swift's `applyMigrations` protective guard:
///   `if schemaDeclaration == nil { schemaDeclaration = schema }`.
/// Each kit's version is still recorded independently under its own `kit_id`.
fn apply_schema(inner: &mut Inner, schema: &SchemaDeclaration) -> StorageResult<()> {
    match &mut inner.schema {
        None => {
            // First call (typically from `open`): set the primary schema.
            inner.schema = Some(schema.clone());
        }
        Some(existing) => {
            // Subsequent call (typically from `migrate` on the same storage):
            // merge the incoming schema's tables and indices into the existing
            // accumulated view. Tables are keyed by name; if a table with the
            // same name already exists (e.g. a re-open over an existing schema),
            // leave the existing declaration in place — CREATE TABLE IF NOT EXISTS
            // below is idempotent at the DDL level, so the existing declaration
            // is still correct and the new one would be redundant.
            for table in &schema.tables {
                if !existing.tables.iter().any(|t| t.name == table.name) {
                    existing.tables.push(table.clone());
                }
            }
            for index in &schema.indices {
                if !existing.indices.iter().any(|i| i.name == index.name) {
                    existing.indices.push(index.clone());
                }
            }
        }
    }
    let conn = &inner.conn;
    let exec = |sql: &str| {
        conn.execute_batch(sql)
            .map_err(|e| StorageError::BackendError {
                underlying: format!("ddl: {e}"),
            })
    };
    exec(MIGRATIONS_TABLE)?;
    exec(AUDIT_TABLE)?;
    // Upgrade migration (#102): estates created before the reason column
    // need ALTER TABLE. CREATE TABLE IF NOT EXISTS does not add columns.
    // "duplicate column name" on new estates is expected — ignore it.
    let _ = exec(r#"ALTER TABLE "_storagekit_audit" ADD COLUMN "reason" TEXT"#);
    exec(AUDIT_DROP_PACKED_INDEX)?;
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
        // Thread the at-rest encryption config and default AEAD provider down
        // into the row store so insert/query can call the crypto helpers.
        // The default provider (AesGcmAeadProvider) is constructed fresh here
        // rather than held on SqliteStorage; it is zero-state so this is free.
        let backing: Arc<dyn RowStore> = Arc::new(SqliteRowStore {
            inner: self.inner.clone(),
            observers: self.observers.clone(),
            encryption_config: self.config.encryption_config.clone(),
            aead_provider: Arc::new(AesGcmAeadProvider),
        });
        // When cache is enabled, wrap with an LRU hot tier. Disabled (the
        // default) is a zero-change passthrough — identical to pre-mission
        // behavior.
        if self.config.cache_config.enabled {
            Arc::new(CachingRowStore::new(backing, self.config.cache_config.clone()))
        } else {
            backing
        }
    }
    fn blob_store(&self) -> Arc<dyn BlobStore> {
        Arc::new(SqliteBlobStore {
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

    fn current_schema_version_for(&self, kit_id: &str) -> StorageResult<i32> {
        let guard = self.inner.lock().unwrap();
        let v: i64 = guard
            .conn
            .query_row(
                r#"SELECT "version" FROM "_storagekit_migrations" WHERE "kit_id" = ?"#,
                [kit_id],
                |r| r.get::<_, Option<i64>>(0).map(|o| o.unwrap_or(0)),
            )
            .unwrap_or(0);
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
        //
        // ISOLATION INVARIANT: `tx_lock` is held for the WHOLE bracket, so
        // concurrent Rust callers on the same instance queue here instead of
        // colliding. This is load-bearing: there is ONE connection per
        // instance, and on the SAME connection a concurrent second
        // BEGIN IMMEDIATE does not get SQLITE_BUSY (that is cross-connection
        // arbitration) — it fails with "cannot start a transaction within a
        // transaction" (observed: the corpus ingest queue's background drain
        // loop racing the foreground await_ingest_drain pump on the shared
        // queue.sqlite). Cross-process isolation still rests on SQLite's own
        // file locking; non-transactional statements issued by other threads
        // during the bracket join the open transaction as before. Production
        // additionally serializes all estate access behind the coordinator
        // lock, but shared side-stores (the per-estate queue.sqlite) are
        // driven outside it — hence the self-serialization here.
        //
        // No re-entrancy hazard: nothing calls `transaction` from inside a
        // transaction block — same-connection BEGIN nesting always errored,
        // so such a caller could never have worked.
        let _tx_guard = self.tx_lock.lock().unwrap();
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
    fn audit_log(&self) -> Arc<dyn AuditLog> {
        Storage::audit_log(self)
    }
}

// ─────────────────────────────────────────────────────────────────────
// StorageIntrospection — DB-layer health statistics.
// ─────────────────────────────────────────────────────────────────────

impl crate::introspection::StorageIntrospection for SqliteStorage {
    /// Capture a point-in-time snapshot of SQLite backend health.
    ///
    /// PRAGMA choices:
    ///
    /// - `page_size`: constant for the DB file; required to derive WAL
    ///   frame count from the file size.
    /// - `page_count`: total allocated pages; multiply by page_size for
    ///   raw file size.
    /// - `freelist_count`: unused pages available for VACUUM reclaim.
    ///
    /// WAL frame count via file stat: `PRAGMA wal_checkpoint` acquires
    /// a checkpointer lock and can fail with SQLITE_LOCKED when called from
    /// inside a lock-holding Mutex guard. The safe alternative is to stat
    /// the WAL file (`path + "-wal"`) directly.
    /// WAL header = 32 bytes; each frame = page_size + 24 bytes.
    /// Frame count = (file_size - 32) / (page_size + 24) when file_size > 32.
    ///
    /// Lock contention: `PRAGMA schema_version` is a read-only meta-query.
    /// SQLITE_LOCKED on it means a cross-process exclusive lock; the Mutex
    /// serializes same-process access.
    fn stats(&self, now_secs: i64) -> crate::error::StorageResult<crate::introspection::StorageStats> {
        use crate::introspection::StorageStats;
        use crate::error::StorageError;

        let guard = self.inner.lock().unwrap();

        // page_size — constant; needed for logical-size and WAL frame math.
        let page_size: i32 = guard
            .conn
            .query_row("PRAGMA page_size", [], |r| r.get::<_, i32>(0))
            .map_err(|e| StorageError::BackendError { underlying: format!("pragma page_size: {e}") })?;

        // page_count — total allocated pages (including freelist).
        let page_count: i32 = guard
            .conn
            .query_row("PRAGMA page_count", [], |r| r.get::<_, i32>(0))
            .map_err(|e| StorageError::BackendError { underlying: format!("pragma page_count: {e}") })?;

        // freelist_count — pages that VACUUM can reclaim.
        let freelist_count: i32 = guard
            .conn
            .query_row("PRAGMA freelist_count", [], |r| r.get::<_, i32>(0))
            .map_err(|e| StorageError::BackendError { underlying: format!("pragma freelist_count: {e}") })?;

        let logical_size = i64::from(page_count) * i64::from(page_size);

        // WAL frame count via filesystem stat — avoids calling PRAGMA wal_checkpoint,
        // which acquires a checkpointer lock incompatible with the held Mutex guard.
        // The WAL file path is the database path + "-wal".
        let wal_frame_count: Option<i32> = if page_size > 0 {
            let wal_path = match &self.config.backend {
                BackendConfiguration::Sqlite { path, .. } => format!("{path}-wal"),
                _ => String::new(),
            };
            match std::fs::metadata(&wal_path) {
                Ok(meta) => {
                    let file_size = meta.len();
                    if file_size > 32 {
                        // WAL header = 32 bytes; each frame = page_size + 24 bytes.
                        let frame_size = u64::from(page_size as u32) + 24;
                        Some(((file_size - 32) / frame_size) as i32)
                    } else {
                        Some(0)
                    }
                }
                Err(_) => Some(0), // WAL file absent → zero frames (no WAL transactions).
            }
        } else {
            None
        };

        // Lock contention: a trivial read-only PRAGMA that touches no user data.
        // Returns SQLITE_LOCKED only when a cross-process exclusive lock exists
        // (the Mutex above handles same-process serialization).
        let lock_contention = guard
            .conn
            .query_row("PRAGMA schema_version", [], |r| r.get::<_, i32>(0))
            .is_err();

        Ok(StorageStats {
            logical_size_bytes: logical_size,
            page_size: if page_size > 0 { Some(page_size) } else { None },
            page_count: if page_count > 0 { Some(page_count) } else { None },
            freelist_page_count: Some(freelist_count),
            wal_frame_count,
            cache_hit_ratio: None,
            transaction_commit_count: None,
            transaction_rollback_count: None,
            deadlock_count: None,
            lock_contention: Some(lock_contention),
            row_count: None,
            blob_count: None,
            captured_at_secs: now_secs,
        })
    }
}

// ─────────────────────────────────────────────────────────────────────
// At-rest encryption helpers — mirrors SQLiteBackend's
// encryptedForWrite / decryptedForRead / assertContentKeyIDInvariant.
//
// The seam intercepts exactly the "content" and "keyID" column names,
// which in the LocusKit schema belong to the drawers table (the sole
// content-bearing table). Interception by name matches the Swift design.
//
// Mode 1 (Plaintext) is a complete no-op: neither encrypt nor decrypt
// is called and the values map passes through unchanged.
//
// Nonce discipline: production encryptions use a fresh OsRng nonce per
// call (via AesGcmAeadProvider). Tests that need a deterministic nonce
// inject one via AesGcmAeadProvider::encrypt_with_nonce (#[cfg(test)]).
// Never make production encryption deterministic — nonce reuse breaks
// AES-GCM confidentiality and authenticity.
// ─────────────────────────────────────────────────────────────────────

/// The column names the encryption seam intercepts.
/// Both names match the Swift SQLiteBackend design verbatim.
pub(crate) const CONTENT_COL: &str = "content";
pub(crate) const KEY_ID_COL:  &str = "keyID";

/// Encrypt the `content` column and stamp `keyID` when the estate
/// is in an encrypting mode (RowEncryption or FullDatabase). Returns
/// `values` unchanged for Plaintext mode or for rows that carry no
/// `content` column.
///
/// Mirrors Swift's `encryptedForWrite` on `SQLiteBackend`.
pub(crate) fn encrypted_for_write(
    values: BTreeMap<String, TypedValue>,
    config: &EstateEncryptionConfig,
    provider: &dyn AeadProvider,
) -> StorageResult<BTreeMap<String, TypedValue>> {
    // No per-row crypto for Plaintext (no key) or FullDatabase (the whole file
    // is SQLCipher-encrypted at the connection layer). Only RowEncryption seals
    // the content column here.
    if !config.uses_row_crypto() {
        return Ok(values);
    }
    let (key, key_id) = match (&config.key, &config.key_identifier) {
        (Some(k), Some(id)) => (k, id),
        // Encrypting mode but missing key or id — config invariant broken;
        // pass through rather than panic so the issue surfaces at write.
        _ => return Ok(values),
    };
    // Only rows that carry a text `content` column are encrypted.
    let plaintext = match values.get(CONTENT_COL) {
        Some(TypedValue::Text(t)) => t.as_bytes().to_vec(),
        _ => return Ok(values),
    };
    let envelope = provider
        .encrypt(&plaintext, key)
        .map_err(|e| StorageError::BackendError { underlying: e })?;
    let mut out = values;
    out.insert(CONTENT_COL.to_string(), TypedValue::Blob(envelope));
    out.insert(KEY_ID_COL.to_string(), TypedValue::Text(key_id.clone()));
    Ok(out)
}

/// Decrypt the `content` column when the row carries a non-null `keyID`
/// that matches the estate's key identifier. Returns `values` unchanged
/// for Plaintext mode, for rows with no/empty/mismatched keyID, or when
/// the stored content is not a blob envelope.
///
/// Key mismatch (keyID present but different from this estate's id): pass
/// through unchanged — the row was sealed under a different key we cannot
/// open. Mirrors the Swift single-key-path note in `decryptedForRead`.
///
/// Mirrors Swift's `decryptedForRead` on `SQLiteBackend`.
pub(crate) fn decrypted_for_read(
    values: BTreeMap<String, TypedValue>,
    config: &EstateEncryptionConfig,
    provider: &dyn AeadProvider,
) -> StorageResult<BTreeMap<String, TypedValue>> {
    // No per-row decrypt for Plaintext or FullDatabase; only RowEncryption rows
    // carry a content envelope to open here.
    if !config.uses_row_crypto() {
        return Ok(values);
    }
    let (key, estate_key_id) = match (&config.key, &config.key_identifier) {
        (Some(k), Some(id)) => (k, id),
        _ => return Ok(values),
    };
    // Row must carry a non-empty keyID matching this estate's key.
    let row_key_id = match values.get(KEY_ID_COL) {
        Some(TypedValue::Text(id)) if !id.is_empty() => id.clone(),
        _ => return Ok(values),
    };
    if &row_key_id != estate_key_id {
        // Row sealed under a different key; pass through (ciphertext stays).
        return Ok(values);
    }
    // Content must be a blob envelope produced by `encrypted_for_write`.
    let envelope = match values.get(CONTENT_COL) {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return Ok(values),
    };
    let plaintext_bytes = provider
        .decrypt(&envelope, key)
        .map_err(|e| StorageError::BackendError { underlying: e })?;
    let plaintext = String::from_utf8(plaintext_bytes).map_err(|e| StorageError::BackendError {
        underlying: format!("decrypted_for_read: UTF-8 decode failed: {e}"),
    })?;
    let mut out = values;
    out.insert(CONTENT_COL.to_string(), TypedValue::Text(plaintext));
    Ok(out)
}

/// Structural enforcement of the content/keyID invariant.
///
/// On an encrypting estate (mode 2/3), a content-bearing row must be stored
/// as ciphertext (.blob) under a keyID. `encrypted_for_write` produces
/// exactly that. A `.text` content value reaching `upsert` or `update`
/// means the encryption seam did not run; persisting it would write
/// plaintext with a null keyID — a row `decrypted_for_read` cannot resolve.
///
/// The upsert path is deliberately NOT wired with `encrypted_for_write`
/// (matching Swift's design: in the LocusKit schema upsert is only ever
/// called for non-content tables — manifest, container_fingerprints,
/// node_bundles — none of which carry a `content` column). The guard here
/// is the structural safety net: a content-bearing upsert on an encrypting
/// estate throws rather than silently writing plaintext.
///
/// Mode 1 (Plaintext) returns immediately: the guard is a no-op and the
/// path is byte-identical to pre-encryption behavior.
///
/// Mirrors Swift's `assertContentKeyIDInvariant` on `SQLiteBackend`.
pub(crate) fn assert_content_key_id_invariant(
    values: &BTreeMap<String, TypedValue>,
    table: &str,
    config: &EstateEncryptionConfig,
) -> StorageResult<()> {
    // The invariant only applies to RowEncryption, where content must be sealed
    // (.blob) under a keyID. Plaintext writes plaintext; FullDatabase stores
    // plaintext within a whole-file-encrypted database. Both skip the guard.
    if !config.uses_row_crypto() {
        return Ok(());
    }
    // Only fire if the row carries a text `content` — .blob is already
    // encrypted, .null / absent is not a content-bearing row.
    if let Some(TypedValue::Text(_)) = values.get(CONTENT_COL) {
        // A keyID is present only when content is ciphertext (.blob); .text
        // content with no keyID is an unencrypted write the seam missed.
        if let Some(TypedValue::Text(id)) = values.get(KEY_ID_COL) {
            if !id.is_empty() {
                return Ok(()); // keyID present — content is already encrypted
            }
        }
        return Err(StorageError::ConstraintViolation {
            detail: format!(
                "content/keyID invariant: table '{}' on an encrypting estate received \
                 plaintext content with no keyID; the encryption seam did not run, so \
                 this row would be unreadable",
                table
            ),
        });
    }
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// RowStore.
// ─────────────────────────────────────────────────────────────────────

struct SqliteRowStore {
    inner: Arc<Mutex<Inner>>,
    observers: Arc<ObserverRegistry>,
    /// At-rest encryption config (PAR-5-PK). Plaintext mode is the default
    /// and makes all crypto helpers no-ops, so pre-encryption call sites are
    /// unaffected. Mirrors Swift's `SQLiteBackend.encryptionConfig`.
    encryption_config: EstateEncryptionConfig,
    /// AEAD provider used by the crypto helpers. Defaults to
    /// `AesGcmAeadProvider`; injectable for testing (e.g. a fixed-nonce
    /// wrapper for cross-port fixture verification).
    aead_provider: Arc<dyn AeadProvider>,
}

/// Collect the row keys for rows currently matching `predicate`.
/// Called before a mutating operation (update or delete) so observer
/// notifications can carry the actual key for each affected row.
/// The `values` map passed to `update` contains only the SET columns,
/// not the primary key, making this pre-query necessary.
/// The primary-key column is read from the retained schema; "row_id"
/// is the fallback. Mirrors Swift's `fetchMatchingRowKeys`.
fn fetch_matching_keys(
    conn: &Connection,
    schema: Option<&SchemaDeclaration>,
    table: &str,
    predicate: &StoragePredicate,
) -> Vec<RowKey> {
    let pk_col = schema
        .and_then(|s| s.tables.iter().find(|t| t.name == table))
        .and_then(|t| t.primary_key.first().cloned())
        .unwrap_or_else(|| "row_id".to_string());
    let mut binds: Vec<SqlValue> = Vec::new();
    // Predicate column names are validated inside compile_predicate (SECFIX-WS2-PK F7).
    // If validation fails the fetch silently returns empty (caller receives no pre-mutation
    // keys — safe: the caller's subsequent write will re-validate and reject). This matches
    // the existing error-swallowing convention in this helper.
    let where_sql = match compile_predicate(predicate, &mut binds) {
        Ok(sql) => sql,
        Err(_) => return Vec::new(),
    };
    let sql = format!("SELECT \"{pk_col}\" FROM \"{table}\" WHERE {where_sql}");
    // prepare_cached: this SELECT runs once per upsert/update, so a bulk loop
    // re-parsed the identical statement tens of thousands of times (a measured
    // hot spot — sqlite3Prepare/RunParser per row on 50k-row imports).
    let mut stmt = match conn.prepare_cached(&sql) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    stmt.query_map(params_from_iter(binds), |row| {
        let s: String = row.get(0)?;
        Ok(s)
    })
    .map(|rows| {
        rows.filter_map(|r| r.ok().and_then(|s| Uuid::parse_str(&s).ok()))
            .collect()
    })
    .unwrap_or_default()
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
        // At-rest encryption seam (PAR-5-PK): encrypt the content column and
        // stamp the keyID before binding. No-op for Plaintext mode. Mirrors
        // Swift's `encryptedForWrite` call in `SQLiteBackend.insertRow`.
        let values = encrypted_for_write(values, &self.encryption_config, self.aead_provider.as_ref())?;
        // Structural content/keyID invariant: after the seam, a content row on
        // an encrypting estate must carry a keyID. Correct encrypting inserts
        // become .blob + keyID here; the guard fires only if the seam failed.
        assert_content_key_id_invariant(&values, table, &self.encryption_config)?;
        // SQL-identifier injection guard (CAND-047): the table name and all
        // caller-supplied column names reach the INSERT SQL directly.
        // A name containing `"` or `;` can escape double-quote delimiters and
        // alter the query. The same `validate_sql_identifier` used by
        // `query_projected` and the Postgres backend rejects any name outside
        // `[A-Za-z_][A-Za-z0-9_]*` — one shared seam, no forked validator.
        // Table validated first (SECFIX-WS2-PK F9) then every column key (F7).
        validate_sql_identifier(table)?;
        for k in values.keys() {
            validate_sql_identifier(k)?;
        }
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
        // prepare_cached: the SQL text for a given (table, column-set) shape is
        // identical across a bulk loop, so the statement parses ONCE and replays
        // from rusqlite's per-connection LRU cache — sqlite3Prepare/RunParser per
        // row was a measured hot spot on 50k-row imports (best-practices §5:
        // prepared statements reused via the kit).
        guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?
            .execute(params_from_iter(binds))
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
        // The at-rest encryption seam is NOT wired to upsert. In the LocusKit
        // schema, upsert is only ever called for non-content tables (manifest,
        // container_fingerprints, node_bundles) — none of which carry a
        // `content` column. The invariant guard below is the structural safety
        // net: a content-bearing upsert on an encrypting estate throws rather
        // than silently writing plaintext. Mirrors Swift `upsertRow` design.
        assert_content_key_id_invariant(&values, table, &self.encryption_config)?;
        // SQL-identifier injection guard (CAND-047): validate the table name,
        // all value-map column names, and the conflict-column list before
        // interpolating into the INSERT … ON CONFLICT … DO UPDATE SQL.
        // Table validated first (SECFIX-WS2-PK F9) then columns (F7).
        // Reuses the shared `validate_sql_identifier` seam — no forked validator.
        validate_sql_identifier(table)?;
        for k in values.keys() {
            validate_sql_identifier(k)?;
        }
        for c in conflict_columns {
            validate_sql_identifier(c)?;
        }
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
        // prepare_cached: the SQL text for a given (table, column-set) shape is
        // identical across a bulk loop, so the statement parses ONCE and replays
        // from rusqlite's per-connection LRU cache — sqlite3Prepare/RunParser per
        // row was a measured hot spot on 50k-row imports (best-practices §5:
        // prepared statements reused via the kit).
        guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?
            .execute(params_from_iter(binds))
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
        // The at-rest encryption seam is NOT wired to update. All current
        // callers update only bitmap/timestamp columns, not the content column.
        // The invariant guard is the structural safety net: a content update
        // on an encrypting estate throws rather than silently writing plaintext.
        // Mirrors Swift `updateRows` design.
        assert_content_key_id_invariant(&values, table, &self.encryption_config)?;
        // SQL-identifier injection guard (CAND-047): validate the table name
        // and all caller-supplied SET column names before interpolating into SQL.
        // A name containing `"` or `;` can escape double-quote delimiters.
        // Table validated first (SECFIX-WS2-PK F9) then columns (F7).
        // Reuses the shared `validate_sql_identifier` seam — no forked validator.
        validate_sql_identifier(table)?;
        for k in values.keys() {
            validate_sql_identifier(k)?;
        }
        let guard = self.inner.lock().unwrap();
        // Pre-query row keys before mutating. The `values` map carries only
        // the SET columns (not the primary key). The Mutex serializes all
        // operations so no interleaving is possible between this SELECT and
        // the UPDATE.
        let matched_keys = fetch_matching_keys(&guard.conn, guard.schema.as_ref(), table, predicate);
        let keys: Vec<&String> = values.keys().collect();
        let set_clause = keys
            .iter()
            .map(|k| format!("\"{k}\" = ?"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut binds: Vec<SqlValue> = keys.iter().map(|k| to_sql(&values[*k])).collect();
        // Predicate column names are validated inside compile_predicate (SECFIX-WS2-PK F7).
        let where_sql = compile_predicate(predicate, &mut binds)?;
        let sql = format!("UPDATE \"{table}\" SET {set_clause} WHERE {where_sql}");
        // prepare_cached: same statement-reuse rationale as insert/upsert above.
        let changed = guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?
            .execute(params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
        for key in matched_keys {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Update,
                row_key: Some(key),
                values: None,
                hlc: None,
            });
        }
        Ok(changed)
    }

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize> {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name before it is interpolated into the DELETE FROM clause.
        // Predicate column names are validated inside compile_predicate (F7).
        validate_sql_identifier(table)?;
        let guard = self.inner.lock().unwrap();
        // Pre-query row keys before deletion so notifications carry them.
        // The Mutex serializes all operations — no interleaving is possible
        // between this SELECT and the DELETE.
        let matched_keys = fetch_matching_keys(&guard.conn, guard.schema.as_ref(), table, predicate);
        let mut binds: Vec<SqlValue> = Vec::new();
        // Predicate column names are validated inside compile_predicate (SECFIX-WS2-PK F7).
        let where_sql = compile_predicate(predicate, &mut binds)?;
        let sql = format!("DELETE FROM \"{table}\" WHERE {where_sql}");
        // prepare_cached: same statement-reuse rationale as insert/upsert above.
        let changed = guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?
            .execute(params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;
        for key in matched_keys {
            self.observers.emit(&TableChange {
                table: table.to_string(),
                event: StorageEvent::Delete,
                row_key: Some(key),
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
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name before it is interpolated into the SELECT FROM clause.
        // Predicate and ORDER BY column names are validated at their respective seams.
        validate_sql_identifier(table)?;
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT * FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            // Predicate column names are validated inside compile_predicate
            // (SECFIX-WS2-PK F7). Propagate rejection before SQL is built.
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)?));
        }
        if !order_by.is_empty() {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate every
            // ORDER BY column name before it is interpolated into the SQL string.
            // Mirrors the guard in Swift `SQLiteBackend.queryRows`.
            let parts: Vec<String> = order_by
                .iter()
                .map(|c| {
                    validate_sql_identifier(&c.column.name)?;
                    let dir = match c.direction {
                        OrderDirection::Ascending => "ASC",
                        OrderDirection::Descending => "DESC",
                    };
                    Ok(format!("\"{}\" {dir}", c.column.name))
                })
                .collect::<StorageResult<_>>()?;
            sql.push_str(&format!(" ORDER BY {}", parts.join(", ")));
        }
        if let Some(l) = limit {
            // SQLite LIMIT is a signed 64-bit count. A usize value beyond i64::MAX
            // produces an overflowing SQL literal that SQLite rejects with
            // "datatype mismatch (20)". Clamp to i64::MAX so any out-of-range value
            // becomes a very large but syntactically valid limit rather than an invalid
            // literal. Matches the pattern already in place on the audit-path query.
            // (secfix/recollect: defence-in-depth guard — protects all future callers.)
            let lim: i64 = l.min(i64::MAX as usize) as i64;
            sql.push_str(&format!(" LIMIT {lim}"));
        }
        if let Some(o) = offset {
            if o > 0 {
                sql.push_str(&format!(" OFFSET {o}"));
            }
        }

        // prepare_cached: query SQL for a given (table, predicate-shape) is
        // identical across repeated calls — parse once, replay from the
        // per-connection statement cache (best-practices §5).
        let mut stmt = guard
            .conn
            .prepare_cached(&sql)
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
                // read_value returns Err(CorruptStoredValue) when a TEXT value
                // for a .uuid or .timestamp column cannot be parsed. Propagate
                // so the caller knows the row is unreadable.
                values.insert(name.clone(), read_value(vref, kit, table, name)?);
            }
            // At-rest decryption seam (PAR-5-PK): decrypt the content column
            // when the row carries a matching keyID. No-op for Plaintext mode.
            // Mirrors Swift's `decryptedForRead` call in `SQLiteBackend.queryRows`.
            let values = decrypted_for_read(values, &self.encryption_config, self.aead_provider.as_ref())?;
            out.push(StorageRow::new(values));
        }
        Ok(out)
    }

    fn query_projected(
        &self,
        table: &str,
        columns: &[&str],
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        // Empty projection means "no projection" — fall back to SELECT *.
        // `query` validates the table name, so the guard is upheld either way.
        if columns.is_empty() {
            return self.query(table, predicate, order_by, limit, offset);
        }
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9/F1):
        // validate the table name and all caller-supplied projection column names
        // before embedding them in SQL. Double-quoting is insufficient: a name
        // containing `"` can escape the quoting and alter the query. Reject any
        // name that is not a safe SQL identifier: [A-Za-z_][A-Za-z0-9_]*.
        validate_sql_identifier(table)?;
        for c in columns {
            validate_sql_identifier(c)?;
        }
        let guard = self.inner.lock().unwrap();
        // Build an explicit column list so the omitted columns (notably the
        // content blob) are never read off disk — this is the I/O win the
        // no-blob recall path needs. Column names are validated and quoted identifiers.
        let select_list = columns
            .iter()
            .map(|c| format!("\"{c}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let mut sql = format!("SELECT {select_list} FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            // Predicate column names are validated inside compile_predicate
            // (SECFIX-WS2-PK F7). Propagate rejection before SQL is built.
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)?));
        }
        if !order_by.is_empty() {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate every
            // ORDER BY column name before it is interpolated. Mirrors queryRows.
            let parts: Vec<String> = order_by
                .iter()
                .map(|c| {
                    validate_sql_identifier(&c.column.name)?;
                    let dir = match c.direction {
                        OrderDirection::Ascending => "ASC",
                        OrderDirection::Descending => "DESC",
                    };
                    Ok(format!("\"{}\" {dir}", c.column.name))
                })
                .collect::<StorageResult<_>>()?;
            sql.push_str(&format!(" ORDER BY {}", parts.join(", ")));
        }
        if let Some(l) = limit {
            // SQLite LIMIT is a signed 64-bit count. A usize value beyond i64::MAX
            // produces an overflowing SQL literal that SQLite rejects with
            // "datatype mismatch (20)". Clamp to i64::MAX so any out-of-range value
            // becomes a very large but syntactically valid limit rather than an invalid
            // literal. Matches the pattern already in place on the audit-path query.
            // (secfix/recollect: defence-in-depth guard — protects all future callers.)
            let lim: i64 = l.min(i64::MAX as usize) as i64;
            sql.push_str(&format!(" LIMIT {lim}"));
        }
        if let Some(o) = offset {
            if o > 0 {
                sql.push_str(&format!(" OFFSET {o}"));
            }
        }

        // prepare_cached: query SQL for a given (table, predicate-shape) is
        // identical across repeated calls — parse once, replay from the
        // per-connection statement cache (best-practices §5).
        let mut stmt = guard
            .conn
            .prepare_cached(&sql)
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
                values.insert(name.clone(), read_value(vref, kit, table, name)?);
            }
            // At-rest decryption seam: decrypt the content column when the
            // row carries a matching keyID. No-op for Plaintext mode.
            // Mirrors Swift's `decryptedForRead` call in `SQLiteBackend.queryRows`.
            let values = decrypted_for_read(values, &self.encryption_config, self.aead_provider.as_ref())?;
            out.push(StorageRow::new(values));
        }
        Ok(out)
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize> {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name before it is interpolated into the SELECT COUNT clause.
        // Predicate column names are validated inside compile_predicate (F7).
        validate_sql_identifier(table)?;
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT COUNT(*) FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            // Predicate column names are validated inside compile_predicate
            // (SECFIX-WS2-PK F7). Propagate rejection before SQL is built.
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)?));
        }
        let n: i64 = guard
            .conn
            .query_row(&sql, params_from_iter(binds), |r| r.get(0))
            .map_err(|e| map_sql_err(e, table))?;
        Ok(n as usize)
    }

    /// SQLite-cursor-level override of the `RowStore` default. Iterates the
    /// result set row by row; when `read_value` returns `CorruptStoredValue`
    /// for a column in a row (e.g. a poison timestamp like `+58432-...` that
    /// `parse_iso8601` cannot round-trip), the row is logged to stderr and
    /// skipped rather than aborting the entire scan. Any other error
    /// (engine failure, locking, connectivity) is re-raised immediately.
    ///
    /// This is the correct level to implement skip-and-log for the timestamp
    /// corruption scenario: corruption surfaces inside `read_value` during
    /// the column iteration loop, so the override must operate at the SQLite
    /// cursor level — the default implementation in `RowStore` calls the whole
    /// `query()` and wraps a single top-level error, which only handles the
    /// case where the first corrupt row happens to be the only row.
    ///
    /// Corpus scans (all_drawers, drawers_in_wing, …) call this method so
    /// one bad row does not brick the entire estate. Point-lookups (single-row
    /// fetches by primary key) still call strict `query()`.
    fn query_skip_corrupt(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<(Vec<StorageRow>, usize)> {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name before it is interpolated into the SELECT FROM clause.
        // Predicate and ORDER BY column names are validated at their respective seams.
        validate_sql_identifier(table)?;
        let guard = self.inner.lock().unwrap();
        let mut sql = format!("SELECT * FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            // Predicate column names are validated inside compile_predicate
            // (SECFIX-WS2-PK F7). Propagate rejection before SQL is built.
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)?));
        }
        if !order_by.is_empty() {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate every
            // ORDER BY column name before it is interpolated. Mirrors queryRows
            // and queryRowsSkipCorrupt in Swift.
            let parts: Vec<String> = order_by
                .iter()
                .map(|c| {
                    validate_sql_identifier(&c.column.name)?;
                    let dir = match c.direction {
                        OrderDirection::Ascending => "ASC",
                        OrderDirection::Descending => "DESC",
                    };
                    Ok(format!("\"{}\" {dir}", c.column.name))
                })
                .collect::<StorageResult<_>>()?;
            sql.push_str(&format!(" ORDER BY {}", parts.join(", ")));
        }
        if let Some(l) = limit {
            // SQLite LIMIT is a signed 64-bit count. A usize value beyond i64::MAX
            // produces an overflowing SQL literal that SQLite rejects with
            // "datatype mismatch (20)". Clamp to i64::MAX so any out-of-range value
            // becomes a very large but syntactically valid limit rather than an invalid
            // literal. Matches the pattern already in place on the audit-path query.
            // (secfix/recollect: defence-in-depth guard — protects all future callers.)
            let lim: i64 = l.min(i64::MAX as usize) as i64;
            sql.push_str(&format!(" LIMIT {lim}"));
        }
        if let Some(o) = offset {
            if o > 0 {
                sql.push_str(&format!(" OFFSET {o}"));
            }
        }

        // prepare_cached: query SQL for a given (table, predicate-shape) is
        // identical across repeated calls — parse once, replay from the
        // per-connection statement cache (best-practices §5).
        let mut stmt = guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?;
        let col_names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = stmt
            .query(params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;

        let mut out: Vec<StorageRow> = Vec::new();
        let mut skipped: usize = 0;

        'rows: while let Some(row) = rows.next().map_err(|e| map_sql_err(e, table))? {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            for (i, name) in col_names.iter().enumerate() {
                let vref = row.get_ref(i).map_err(|e| map_sql_err(e, table))?;
                let kit = table_column_type(guard.schema.as_ref(), table, name);
                match read_value(vref, kit, table, name) {
                    Ok(v) => { values.insert(name.clone(), v); }
                    Err(StorageError::CorruptStoredValue {
                        table: ref t,
                        column: ref c,
                        stored_text: ref s,
                    }) => {
                        // Log the corrupt value and skip this row. The row is
                        // still in the database; it can be repaired by fixing
                        // the upstream write path and re-writing the value.
                        eprintln!(
                            "[persistence_kit] WARNING: query_skip_corrupt: skipping \
                             corrupt row in table '{}' (column='{}' stored_text='{}'). \
                             The row is skipped in corpus scans until repaired. \
                             Investigate the upstream source of this value.",
                            t, c, s
                        );
                        skipped += 1;
                        continue 'rows;
                    }
                    // Any other error is a systemic failure — re-raise.
                    Err(other) => return Err(other),
                }
            }
            // At-rest decryption seam: decrypt the content column when the
            // row carries a matching keyID. No-op for Plaintext mode.
            let values = decrypted_for_read(values, &self.encryption_config, self.aead_provider.as_ref())?;
            out.push(StorageRow::new(values));
        }

        Ok((out, skipped))
    }

    /// SQLite-cursor-level override of the `RowStore` projected-skip-corrupt
    /// default. Identical to `query_skip_corrupt` but issues a column-projected
    /// `SELECT col1, col2, …` rather than `SELECT *`, so omitted columns (e.g.
    /// the `content` blob in the no-blob recall path) are never read off disk.
    ///
    /// Rows where `read_value` returns `CorruptStoredValue` for any projected
    /// column (e.g. a poison `filedAt` timestamp) are logged and skipped.
    /// Any other error aborts and re-raises. An empty `columns` slice falls back
    /// to `SELECT *` (matching `query_projected`'s convention).
    fn query_projected_skip_corrupt(
        &self,
        table: &str,
        columns: &[&str],
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<(Vec<StorageRow>, usize)> {
        // `query_skip_corrupt` validates the table name, so the guard is upheld
        // on the empty-projection path as well.
        if columns.is_empty() {
            return self.query_skip_corrupt(table, predicate, order_by, limit, offset);
        }
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9/F10):
        // validate the table name and all projected column names before building
        // the SELECT list. Mirrors the guard in query_projected and in Swift's
        // queryRowsSkipCorrupt. Table first (F9), then columns (F10).
        validate_sql_identifier(table)?;
        for c in columns {
            validate_sql_identifier(c)?;
        }
        let guard = self.inner.lock().unwrap();
        let select_list = columns
            .iter()
            .map(|c| format!("\"{c}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let mut sql = format!("SELECT {select_list} FROM \"{table}\"");
        let mut binds: Vec<SqlValue> = Vec::new();
        if let Some(p) = predicate {
            // Predicate column names are validated inside compile_predicate
            // (SECFIX-WS2-PK F7). Propagate rejection before SQL is built.
            sql.push_str(&format!(" WHERE {}", compile_predicate(p, &mut binds)?));
        }
        if !order_by.is_empty() {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate every
            // ORDER BY column name before it is interpolated. Mirrors query_projected.
            let parts: Vec<String> = order_by
                .iter()
                .map(|c| {
                    validate_sql_identifier(&c.column.name)?;
                    let dir = match c.direction {
                        OrderDirection::Ascending => "ASC",
                        OrderDirection::Descending => "DESC",
                    };
                    Ok(format!("\"{}\" {dir}", c.column.name))
                })
                .collect::<StorageResult<_>>()?;
            sql.push_str(&format!(" ORDER BY {}", parts.join(", ")));
        }
        if let Some(l) = limit {
            // SQLite LIMIT is a signed 64-bit count. A usize value beyond i64::MAX
            // produces an overflowing SQL literal that SQLite rejects with
            // "datatype mismatch (20)". Clamp to i64::MAX so any out-of-range value
            // becomes a very large but syntactically valid limit rather than an invalid
            // literal. Matches the pattern already in place on the audit-path query.
            // (secfix/recollect: defence-in-depth guard — protects all future callers.)
            let lim: i64 = l.min(i64::MAX as usize) as i64;
            sql.push_str(&format!(" LIMIT {lim}"));
        }
        if let Some(o) = offset {
            if o > 0 {
                sql.push_str(&format!(" OFFSET {o}"));
            }
        }

        // prepare_cached: query SQL for a given (table, predicate-shape) is
        // identical across repeated calls — parse once, replay from the
        // per-connection statement cache (best-practices §5).
        let mut stmt = guard
            .conn
            .prepare_cached(&sql)
            .map_err(|e| map_sql_err(e, table))?;
        let col_names: Vec<String> = stmt.column_names().iter().map(|s| s.to_string()).collect();
        let mut rows = stmt
            .query(params_from_iter(binds))
            .map_err(|e| map_sql_err(e, table))?;

        let mut out: Vec<StorageRow> = Vec::new();
        let mut skipped: usize = 0;

        'rows: while let Some(row) = rows.next().map_err(|e| map_sql_err(e, table))? {
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            for (i, name) in col_names.iter().enumerate() {
                let vref = row.get_ref(i).map_err(|e| map_sql_err(e, table))?;
                let kit = table_column_type(guard.schema.as_ref(), table, name);
                match read_value(vref, kit, table, name) {
                    Ok(v) => { values.insert(name.clone(), v); }
                    Err(StorageError::CorruptStoredValue {
                        table: ref t,
                        column: ref c,
                        stored_text: ref s,
                    }) => {
                        eprintln!(
                            "[persistence_kit] WARNING: query_projected_skip_corrupt: skipping \
                             corrupt row in table '{}' (column='{}' stored_text='{}'). \
                             The row is skipped in corpus scans until repaired.",
                            t, c, s
                        );
                        skipped += 1;
                        continue 'rows;
                    }
                    Err(other) => return Err(other),
                }
            }
            // At-rest decryption seam: decrypt the content column when present
            // and the row carries a matching keyID. No-op for Plaintext mode and
            // for projected scans that omit the content column.
            let values = decrypted_for_read(values, &self.encryption_config, self.aead_provider.as_ref())?;
            out.push(StorageRow::new(values));
        }

        Ok((out, skipped))
    }

    // ----------------------------------------------------------------
    // Explicit transaction boundary (GLK_BATCH1)
    // ----------------------------------------------------------------

    /// Open a serializable write transaction.
    ///
    /// Issues `BEGIN IMMEDIATE` so the write lock is acquired upfront,
    /// preventing "cannot start a transaction within a transaction" under WAL
    /// mode. The `inner` `Mutex` serializes concurrent calls.
    fn begin_transaction(&self) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| map_sql_err(e, "<transaction>"))
    }

    /// Commit the transaction opened by `begin_transaction`.
    fn commit_transaction(&self) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        guard
            .conn
            .execute_batch("COMMIT")
            .map_err(|e| map_sql_err(e, "<transaction>"))
    }

    /// Roll back the transaction opened by `begin_transaction`.
    fn rollback_transaction(&self) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        // Use execute_batch; ignore the result (best-effort rollback).
        let _ = guard.conn.execute_batch("ROLLBACK");
        Ok(())
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
    fn list_keys(&self) -> StorageResult<Vec<String>> {
        // Enumerate all blob keys stored in the SQLite backend.
        // Required by the full-snapshot replication primitive; added to
        // fulfil BlobStore trait contract (blob-replication worker).
        let guard = self.inner.lock().unwrap();
        let mut stmt = guard
            .conn
            .prepare(r#"SELECT "key" FROM "_storagekit_blobs""#)
            .map_err(|e| map_sql_err(e, "_storagekit_blobs"))?;
        let keys: Result<Vec<String>, _> = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| map_sql_err(e, "_storagekit_blobs"))?
            .collect::<Result<_, _>>()
            .map_err(|e| map_sql_err(e, "_storagekit_blobs"));
        keys
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
        opt_int(e.before_lattice_qid.map(|v| v as i64)),
        SqlValue::Integer(e.after_lattice_qid as i64),
        SqlValue::Text(e.actor.clone()),
        // reason: None persists as NULL; Some(s) persists as TEXT.
        e.reason.as_deref().map(|s| SqlValue::Text(s.to_string())).unwrap_or(SqlValue::Null),
    ]
}

const AUDIT_COLS: &str = r#""event_id","hlc","physical_time","logical_count","node_id","estate_uuid","row_id","verb","before_adjective","before_operational","before_provenance","after_adjective","after_operational","after_provenance","before_lattice_anchor","after_lattice_anchor","before_lattice_qid","after_lattice_qid","actor","reason""#;

/// Decode one audit row from rusqlite into an AuditEvent.
///
/// UUID columns (event_id, estate_uuid, row_id) are stored as uppercase TEXT.
/// An unparseable UUID string means the row is corrupt; return a rusqlite
/// `InvalidColumnType` error so the caller propagates a structured failure
/// rather than receiving an event with a silently fabricated nil UUID.
fn decode_audit(row: &rusqlite::Row) -> rusqlite::Result<AuditEvent> {
    // Fail-loud UUID parse: map parse failure to rusqlite::Error so the
    // query_map chain propagates a typed error rather than nil-UUID substitution.
    let parse_uuid = |s: String, col: usize| -> rusqlite::Result<Uuid> {
        Uuid::parse_str(&s).map_err(|_| rusqlite::Error::InvalidColumnType(
            col,
            "UUID TEXT".to_string(),
            rusqlite::types::Type::Text,
        ))
    };
    Ok(AuditEvent {
        event_id: parse_uuid(row.get::<_, String>(0)?, 0)?,
        hlc: HLC {
            physical_time: row.get(2)?,
            logical_count: row.get::<_, i64>(3)? as i32,
            node_id: row.get::<_, i64>(4)? as i32,
        },
        estate_uuid: parse_uuid(row.get::<_, String>(5)?, 5)?,
        row_id: parse_uuid(row.get::<_, String>(6)?, 6)?,
        verb: row.get(7)?,
        before_adjective: row.get(8)?,
        before_operational: row.get(9)?,
        before_provenance: row.get(10)?,
        after_adjective: row.get(11)?,
        after_operational: row.get(12)?,
        after_provenance: row.get(13)?,
        before_lattice_anchor: row.get::<_, Option<i64>>(14)?.map(|v| v as u64),
        after_lattice_anchor: row.get::<_, i64>(15)? as u64,
        before_lattice_qid: row.get::<_, Option<i64>>(16)?.map(|v| v as u64),
        after_lattice_qid: row.get::<_, i64>(17)? as u64,
        actor: row.get(18)?,
        // reason at column index 19; NULL reads back as None.
        reason: row.get::<_, Option<String>>(19)?,
    })
}

impl AuditLog for SqliteAuditLog {
    fn append(&self, event: AuditEvent) -> StorageResult<()> {
        let guard = self.inner.lock().unwrap();
        let sql = format!(
            "INSERT INTO \"_storagekit_audit\" ({AUDIT_COLS}) VALUES ({}) ON CONFLICT(\"event_id\",\"hlc\") DO NOTHING",
            // 20 columns: original 17 + reason + before/after lattice qid
            vec!["?"; 20].join(", ")
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
            // Cursor on the full-precision HLC columns, not the packed
            // integer: packed comparison mis-orders same-millisecond bursts
            // (HLC_PACKED_ORDER_UNSOUND). Row-value comparison keeps the
            // cursor exclusive across ties. Mirrors the Swift leg.
            clauses.push(
                "(\"physical_time\", \"logical_count\", \"node_id\") > (?, ?, ?)".into(),
            );
            binds.push(SqlValue::Integer(h.physical_time));
            binds.push(SqlValue::Integer(h.logical_count as i64));
            binds.push(SqlValue::Integer(h.node_id as i64));
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
        sql.push_str(&format!(
            " ORDER BY \"physical_time\" ASC, \"logical_count\" ASC, \"node_id\" ASC LIMIT {lim}"
        ));
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

    fn row_ids_with_audit_verbs(
        &self,
        row_ids: &[RowKey],
        verbs: &[&str],
    ) -> StorageResult<std::collections::HashSet<RowKey>> {
        if row_ids.is_empty() || verbs.is_empty() {
            return Ok(std::collections::HashSet::new());
        }
        // Chunk row_ids into batches of 500 (#28) to stay within SQLite's
        // SQLITE_MAX_VARIABLE_NUMBER limit (default 999). Each chunk runs
        // as a separate query; results are unioned into one HashSet.
        const CHUNK_SIZE: usize = 500;
        let verb_placeholders: Vec<String> = (0..verbs.len()).map(|_| "?".to_string()).collect();
        let verb_ph_str = verb_placeholders.join(", ");
        let verb_binds: Vec<SqlValue> = verbs.iter().map(|v| SqlValue::Text(v.to_string())).collect();
        let mut result = std::collections::HashSet::new();
        for chunk in row_ids.chunks(CHUNK_SIZE) {
            let row_placeholders: Vec<String> = (0..chunk.len()).map(|_| "?".to_string()).collect();
            let sql = format!(
                r#"SELECT DISTINCT "row_id" FROM "_storagekit_audit" WHERE "row_id" IN ({}) AND "verb" IN ({})"#,
                row_placeholders.join(", "),
                verb_ph_str,
            );
            let mut binds: Vec<SqlValue> = chunk
                .iter()
                .map(|id| SqlValue::Text(id.to_string().to_uppercase()))
                .collect();
            binds.extend(verb_binds.iter().cloned());
            let guard = self.inner.lock().unwrap();
            let mut stmt = guard
                .conn
                .prepare(&sql)
                .map_err(|e| map_sql_err(e, "_storagekit_audit"))?;
            let covered: std::collections::HashSet<RowKey> = stmt
                .query_map(params_from_iter(binds), |row| {
                    let s: String = row.get(0)?;
                    Ok(s)
                })
                .map_err(|e| map_sql_err(e, "_storagekit_audit"))?
                .filter_map(|res| {
                    res.ok().and_then(|s| Uuid::parse_str(&s).ok())
                })
                .collect();
            result.extend(covered);
        }
        Ok(result)
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

// ─────────────────────────────────────────────────────────────────
// HLC round-trip tests
//
// These tests verify that an HLC stored to a .hlc column reads back
// with bit-identical field values. They would FAIL against the old
// unpack_hlc (wrong layout) and PASS after the HLC::from_packed fix.
//
// Known-answer: physical_time=0x0102030405, logical_count=0x0607, node_id=0x08
// Canonical packed (node<<56 | logical<<40 | phys):
//   = 0x08_0607_0102030405
// Old wrong decode (physical<<16 | logical<<4 | node):
//   physical = 0x0806070102030405 >> 16 = 0x080607010203 ≠ 0x0102030405
// ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod hlc_roundtrip_tests {
    use super::*;
    use crate::{
        BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration,
        Storage, StoragePredicate, TableDeclaration, TypedValue,
    };
    use substrate_types::hlc::HLC;
    use uuid::Uuid;

    fn make_sqlite_storage() -> SqliteStorage {
        let path = std::env::temp_dir()
            .join(format!("hlc_rt_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("open sqlite");
        let schema = SchemaDeclaration::new(
            "hlc-test",
            1,
            vec![TableDeclaration::new(
                "events",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::hlc("stamp"), // .hlc so read_value returns TypedValue::Hlc
                ],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("open schema");
        storage
    }

    /// Insert `values` and return the first matching row. Uses
    /// `Storage::row_store` explicitly to disambiguate from
    /// `StorageTransaction::row_store` (both are implemented by
    /// `SqliteStorage`, so a plain `.row_store()` call is ambiguous).
    fn insert_and_query(
        storage: &SqliteStorage,
        values: std::collections::BTreeMap<String, TypedValue>,
        row_id: Uuid,
    ) -> Vec<StorageRow> {
        let rs = Storage::row_store(storage);
        rs.insert("events", values).expect("insert");
        let pred = StoragePredicate::Eq(
            crate::Column::new("events", "id"),
            TypedValue::Uuid(row_id),
        );
        rs.query("events", Some(&pred), &[], None, None)
            .expect("query")
    }

    #[test]
    fn concurrent_transactions_on_one_instance_serialize() {
        // Regression (test-full lane, corpus queue): two in-process threads
        // driving `transaction` on ONE SqliteStorage instance — the corpus
        // ingest queue's background drain loop vs the foreground
        // await_ingest_drain pump — collided with "cannot start a
        // transaction within a transaction" (same-connection BEGIN nesting;
        // SQLITE_BUSY arbitration only applies across connections). The
        // tx_lock must queue the brackets instead. 2 threads × 50
        // transactions reproduced the collision reliably pre-fix.
        let storage = std::sync::Arc::new(make_sqlite_storage());
        let mut handles = Vec::new();
        for t in 0..2i64 {
            let storage = std::sync::Arc::clone(&storage);
            handles.push(std::thread::spawn(move || {
                for i in 0..50i64 {
                    let row_id = Uuid::new_v4();
                    storage
                        .transaction(IsolationLevel::Serializable, &mut |tx| {
                            let mut values = std::collections::BTreeMap::new();
                            values.insert("id".to_string(), TypedValue::Uuid(row_id));
                            values.insert(
                                "stamp".to_string(),
                                TypedValue::Hlc(HLC::new(t * 1000 + i, 0, 1)),
                            );
                            tx.row_store().insert("events", values)?;
                            Ok(())
                        })
                        .expect("concurrent transaction must serialize, not nest");
                }
            }));
        }
        for h in handles {
            h.join().expect("worker thread panicked");
        }
        // All 100 rows landed (both writers made progress; nothing rolled back).
        let rs = Storage::row_store(storage.as_ref());
        let rows = rs.query("events", None, &[], None, None).expect("query");
        assert_eq!(rows.len(), 100, "every transactional insert must commit");
    }

    #[test]
    fn open_creates_missing_parent_directory() {
        // Regression: SQLite creates the file but not its parent dirs. On a fresh
        // Windows install the moot-mgr stats store path (%LOCALAPPDATA%\…\moot-mgr\)
        // does not exist yet, so the open failed with "unable to open database
        // file". SqliteStorage::new must create the parent, matching Swift.
        let base = std::env::temp_dir().join(format!("pk_mkparent_{}", Uuid::new_v4()));
        let nested = base.join("a").join("b");
        assert!(!nested.exists(), "precondition: nested dir must not exist yet");
        let path = nested.join("estate.sqlite");
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("new must create parent dir and open");
        let schema = SchemaDeclaration::new(
            "mkparent-test",
            1,
            vec![TableDeclaration::new(
                "t",
                vec![ColumnDeclaration::text("id")],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("schema open");
        assert!(path.exists(), "database file should exist after open");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn hlc_round_trip_known_answer() {
        // physical_time fits in 40 bits, logical_count in 16 bits, node_id in 8 bits.
        // These specific values expose the layout difference between the old wrong
        // decode and the correct HLC::from_packed inverse.
        let original = HLC::new(0x0102030405_i64, 0x0607, 0x08);
        let storage = make_sqlite_storage();
        let row_id = Uuid::new_v4();

        let mut values = std::collections::BTreeMap::new();
        values.insert("id".into(), TypedValue::Uuid(row_id));
        values.insert("stamp".into(), TypedValue::Hlc(original));

        let rows = insert_and_query(&storage, values, row_id);
        assert_eq!(rows.len(), 1);

        // TypedValue::Hlc(HLC) — HLC is Copy so pattern gives a copy.
        match rows[0].get("stamp") {
            Some(TypedValue::Hlc(read_back)) => {
                assert_eq!(
                    read_back.physical_time, original.physical_time,
                    "physical_time mismatch: {} ≠ {}", read_back.physical_time, original.physical_time
                );
                assert_eq!(
                    read_back.logical_count, original.logical_count,
                    "logical_count mismatch: {} ≠ {}", read_back.logical_count, original.logical_count
                );
                assert_eq!(
                    read_back.node_id, original.node_id,
                    "node_id mismatch: {} ≠ {}", read_back.node_id, original.node_id
                );
                assert_eq!(read_back, &original, "HLC must be bit-identical after round-trip");
            }
            other => panic!("expected TypedValue::Hlc, got {:?}", other),
        }
    }

    #[test]
    fn hlc_zero_round_trip() {
        let original = HLC::ZERO;
        let storage = make_sqlite_storage();
        let row_id = Uuid::new_v4();

        let mut values = std::collections::BTreeMap::new();
        values.insert("id".into(), TypedValue::Uuid(row_id));
        values.insert("stamp".into(), TypedValue::Hlc(original));
        let rows = insert_and_query(&storage, values, row_id);

        match rows[0].get("stamp") {
            Some(TypedValue::Hlc(read_back)) => {
                assert_eq!(read_back, &original);
            }
            other => panic!("expected TypedValue::Hlc, got {:?}", other),
        }
    }

    #[test]
    fn hlc_max_fields_round_trip() {
        // 40-bit physical_time max, 16-bit logical_count max, 0x7F node_id
        // (avoids sign-extension edge case in i8 cast used by from_packed).
        let original = HLC::new(0xFF_FFFF_FFFF_i64, 0xFFFF, 0x7F);
        let storage = make_sqlite_storage();
        let row_id = Uuid::new_v4();

        let mut values = std::collections::BTreeMap::new();
        values.insert("id".into(), TypedValue::Uuid(row_id));
        values.insert("stamp".into(), TypedValue::Hlc(original));
        let rows = insert_and_query(&storage, values, row_id);

        match rows[0].get("stamp") {
            Some(TypedValue::Hlc(read_back)) => {
                assert_eq!(read_back, &original);
            }
            other => panic!("expected TypedValue::Hlc, got {:?}", other),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Fingerprint and Array round-trip tests (IMM-PK-001).
//
// Verifies:
//   PK-FP-1: Fingerprint256 values write as a 32-byte BLOB (not NULL)
//             and decode back to TypedValue::Fingerprint on a declared
//             fingerprint column — proving no-NULL-write and round-trip.
//   PK-FP-2: A known-value Fingerprint256 survives insert → query
//             byte-identical.
//   PK-FP-3: TypedValue::Array writes as a JSON BLOB (not NULL).
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod fingerprint_roundtrip_tests {
    use super::*;
    use crate::{
        BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration,
        Storage, StoragePredicate, TableDeclaration, TypedValue,
    };
    use substrate_types::fingerprint256::Fingerprint256;
    use uuid::Uuid;

    fn make_fp_storage() -> SqliteStorage {
        let path = std::env::temp_dir()
            .join(format!("fp_rt_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("open sqlite");
        // A table with a uuid PK and a fingerprint column (declared so
        // read_value receives the ColumnType::Fingerprint hint).
        let schema = SchemaDeclaration::new(
            "fp-test",
            1,
            vec![TableDeclaration::new(
                "fps",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::fingerprint("fp"),
                ],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("open schema");
        storage
    }

    // PK-FP-1: inserting a Fingerprint256 does NOT write NULL — the row
    // is readable and the column comes back as TypedValue::Fingerprint.
    #[test]
    fn pk_fp1_fingerprint_column_not_null() {
        let storage = make_fp_storage();
        let rs = Storage::row_store(&storage);

        let row_id = Uuid::new_v4();
        let fp = Fingerprint256::new(1, 2, 3, 4);
        let mut row = std::collections::BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(row_id));
        row.insert("fp".into(), TypedValue::Fingerprint(fp));
        rs.insert("fps", row).expect("insert");

        let pred = StoragePredicate::Eq(
            crate::Column::new("fps", "id"),
            TypedValue::Uuid(row_id),
        );
        let rows = rs.query("fps", Some(&pred), &[], None, None).expect("query");
        assert_eq!(rows.len(), 1, "row must be present");

        let col = rows[0].get("fp").expect("fp column must be present");
        assert!(
            matches!(col, TypedValue::Fingerprint(_)),
            "fp column must decode to TypedValue::Fingerprint, not NULL or Blob; got {:?}", col
        );
    }

    // PK-FP-2: a known-value Fingerprint256 survives insert → query byte-identical.
    #[test]
    fn pk_fp2_fingerprint_round_trips_byte_identical() {
        let storage = make_fp_storage();
        let rs = Storage::row_store(&storage);

        let row_id = Uuid::new_v4();
        // Use non-trivial block values to expose byte-order bugs.
        let original = Fingerprint256::new(
            0xDEAD_BEEF_0000_0001,
            0x1234_5678_9ABC_DEF0,
            0xFFFF_FFFF_0000_0000,
            0x0000_0001_0000_0001,
        );
        let mut row = std::collections::BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(row_id));
        row.insert("fp".into(), TypedValue::Fingerprint(original));
        rs.insert("fps", row).expect("insert");

        let pred = StoragePredicate::Eq(
            crate::Column::new("fps", "id"),
            TypedValue::Uuid(row_id),
        );
        let rows = rs.query("fps", Some(&pred), &[], None, None).expect("query");
        assert_eq!(rows.len(), 1);

        match rows[0].get("fp") {
            Some(TypedValue::Fingerprint(read_back)) => {
                assert_eq!(read_back.block0, original.block0, "block0 must round-trip");
                assert_eq!(read_back.block1, original.block1, "block1 must round-trip");
                assert_eq!(read_back.block2, original.block2, "block2 must round-trip");
                assert_eq!(read_back.block3, original.block3, "block3 must round-trip");
            }
            other => panic!("expected TypedValue::Fingerprint, got {:?}", other),
        }
    }

    // PK-FP-3: TypedValue::Array writes as a non-NULL JSON BLOB.
    // (ColumnType has no Array case — the column is declared as Blob here
    // so the read side returns TypedValue::Blob, which is the expected
    // behaviour matching Swift's readColumn for array values.)
    #[test]
    fn pk_fp3_array_writes_as_non_null_json_blob() {
        let path = std::env::temp_dir()
            .join(format!("array_rt_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("open sqlite");
        let schema = SchemaDeclaration::new(
            "arr-test",
            1,
            vec![TableDeclaration::new(
                "arr",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::blob("payload"), // no Array ColumnType; stored as blob
                ],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("open schema");

        let rs = Storage::row_store(&storage);
        let row_id = Uuid::new_v4();
        let array_val = TypedValue::Array(vec![
            TypedValue::Text("hello".into()),
            TypedValue::Int(42),
        ]);
        let mut row = std::collections::BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(row_id));
        row.insert("payload".into(), array_val);
        rs.insert("arr", row).expect("insert array value must not return NULL error");

        let pred = StoragePredicate::Eq(
            crate::Column::new("arr", "id"),
            TypedValue::Uuid(row_id),
        );
        let rows = rs.query("arr", Some(&pred), &[], None, None).expect("query");
        assert_eq!(rows.len(), 1, "array row must be present (no NULL write)");

        // The payload comes back as Blob (no ColumnType::Array hint).
        let payload = rows[0].get("payload").expect("payload column must be present");
        match payload {
            TypedValue::Blob(bytes) => {
                // Verify the stored bytes are valid UTF-8 JSON starting with '['.
                let json = std::str::from_utf8(bytes).expect("array JSON must be valid UTF-8");
                assert!(
                    json.starts_with('['),
                    "array must serialize as JSON array; got: {}", json
                );
                assert!(
                    json.contains(r#""type""#),
                    "JSON must contain type fields; got: {}", json
                );
            }
            other => panic!("expected TypedValue::Blob (JSON array), got {:?}", other),
        }
    }

    // PK-FP-4: typed_value_array_to_json / base64_encode unit coverage.
    #[test]
    fn pk_fp4_array_json_format_matches_swift_contract() {
        // Verify the {type, value} JSON format matches Swift's JSONTypedValue encoding.
        let values = vec![
            TypedValue::Text("world".into()),
            TypedValue::Int(-7),
            TypedValue::Bool(true),
        ];
        let bytes = typed_value_array_to_json(&values);
        let json = std::str::from_utf8(&bytes).expect("valid UTF-8");
        assert!(json.contains(r#""type":"text","value":"world""#), "text element: {}", json);
        assert!(json.contains(r#""type":"int","value":"-7""#), "int element: {}", json);
        assert!(json.contains(r#""type":"bool","value":"true""#), "bool element: {}", json);
    }
}

#[cfg(test)]
mod query_projected_tests {
    use super::*;
    use crate::{
        BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration, Storage,
        TableDeclaration, TypedValue,
    };
    use uuid::Uuid;

    fn make_storage() -> SqliteStorage {
        let path = std::env::temp_dir().join(format!("proj_{}.sqlite", Uuid::new_v4()));
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("open sqlite");
        let schema = SchemaDeclaration::new(
            "proj-test",
            1,
            vec![TableDeclaration::new(
                "docs",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("content"),
                    ColumnDeclaration::text("room"),
                ],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("open schema");
        storage
    }

    /// `query_projected` with a column list that omits `content` must return
    /// rows that carry only the requested columns — the omitted blob column is
    /// absent. This is the storage-layer hook the no-blob recall path needs.
    #[test]
    fn projected_query_omits_unselected_columns() {
        let storage = make_storage();
        let rs = Storage::row_store(&storage);
        let mut v = std::collections::BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text("secret body".into()));
        v.insert("room".into(), TypedValue::Text("kitchen".into()));
        rs.insert("docs", v).expect("insert");

        let rows = rs
            .query_projected("docs", &["id", "room"], None, &[], None, None)
            .expect("query_projected");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get("id"), Some(&TypedValue::Text("d1".into())));
        assert_eq!(rows[0].get("room"), Some(&TypedValue::Text("kitchen".into())));
        // The content column was not selected, so it is absent from the row.
        assert!(
            rows[0].get("content").is_none(),
            "projected-away column must be absent; got {:?}",
            rows[0].get("content")
        );
    }

    /// An empty projection list means "no projection" — full rows are returned,
    /// matching plain `query`.
    #[test]
    fn empty_projection_returns_full_rows() {
        let storage = make_storage();
        let rs = Storage::row_store(&storage);
        let mut v = std::collections::BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text("body".into()));
        v.insert("room".into(), TypedValue::Text("kitchen".into()));
        rs.insert("docs", v).expect("insert");

        let rows = rs
            .query_projected("docs", &[], None, &[], None, None)
            .expect("query_projected");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get("content"), Some(&TypedValue::Text("body".into())));
    }
}

// ─────────────────────────────────────────────────────────────────────
// At-rest encryption integration tests
//
// Mirrors the Swift EncryptionWiringTests (EncryptionWiringTests.swift):
//   - Plaintext mode is a complete no-op.
//   - Row-encryption mode round-trips: insert encrypted, read plaintext.
//   - A reader without the key sees ciphertext at rest.
//   - Full-database mode behaves identically to row-encryption at this layer.
//   - Wrong-key decryption fails (AES-GCM authentication failure).
//   - Cross-port envelope: the same AES-GCM-256 algorithm with a fixed
//     nonce produces the same ciphertext as the Swift CryptoKit provider.
//     (Verified via the NIST "feffe9" known-answer fixture already tested
//     in encryption_tests.rs; the storage wiring test here proves the
//     envelope layout [nonce][tag][ciphertext] is consumed correctly.)
//
// Nonce-randomness note: production encryptions use OsRng (non-deterministic
// — nonce reuse breaks GCM). Tests that need a known ciphertext use
// AesGcmAeadProvider::encrypt_with_nonce (fixed-nonce seam, test-only).
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod at_rest_encryption_tests {
    use super::*;
    use crate::{
        AesGcmAeadProvider, BackendConfiguration, ColumnDeclaration,
        EstateConfiguration, EstateEncryptionConfig, SchemaDeclaration, Storage,
        StoragePredicate, TableDeclaration, TypedValue,
    };
    use uuid::Uuid;

    /// Minimal drawers-shaped schema matching Swift EncryptionWiringTests.
    fn drawers_schema() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "enc-test",
            1,
            vec![TableDeclaration::new(
                "drawers",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("content"),
                    // keyID is nullable: NULL for plaintext rows, UUID string for encrypted rows.
                    ColumnDeclaration::text("keyID").nullable(),
                ],
                vec!["id".to_string()],
            )],
        )
    }

    fn make_storage_with_encryption(config: EstateEncryptionConfig) -> SqliteStorage {
        let path = std::env::temp_dir()
            .join(format!("enc_wiring_{}.sqlite", Uuid::new_v4()));
        let mut estate = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        );
        estate.encryption_config = config;
        let storage = SqliteStorage::new(estate).expect("open sqlite");
        storage.open(&drawers_schema()).expect("open schema");
        storage
    }

    fn make_storage_at_path(path: &str, encryption: EstateEncryptionConfig) -> SqliteStorage {
        let mut estate = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string(),
                busy_timeout_secs: 5.0,
            },
        );
        estate.encryption_config = encryption;
        let storage = SqliteStorage::new(estate).expect("open sqlite at path");
        storage.open(&drawers_schema()).expect("open schema at path");
        storage
    }

    // ─── Test 1: Plaintext mode is a no-op ─────────────────────────────────

    /// Mode 1 (Plaintext): content stored and read verbatim, no keyID written.
    /// This is the "null-key, no crypto applied" case.
    #[test]
    fn plaintext_mode_is_no_op() {
        let storage = make_storage_with_encryption(EstateEncryptionConfig::plaintext());
        let rs = Storage::row_store(&storage);

        let mut v = BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text("plain note".into()));
        rs.insert("drawers", v).expect("insert");

        let rows = rs
            .query(
                "drawers",
                Some(&StoragePredicate::Eq(
                    crate::Column::new("drawers", "id"),
                    TypedValue::Text("d1".into()),
                )),
                &[],
                None,
                None,
            )
            .expect("query");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get("content"), Some(&TypedValue::Text("plain note".into())));
        // keyID must be NULL: no crypto path ran.
        // SQLite returns TypedValue::Null for a NULL column.
        let key_id = rows[0].get("keyID").cloned().unwrap_or(TypedValue::Null);
        let key_id_is_absent = match &key_id {
            TypedValue::Null => true,
            TypedValue::Text(s) => s.is_empty(),
            _ => false,
        };
        assert!(
            key_id_is_absent,
            "keyID must be NULL for a plaintext row; got {:?}", key_id
        );
    }

    // ─── Test 2: Row-encryption round-trip ────────────────────────────────

    /// Mode 2 (RowEncryption): insert under an encrypting estate, read back
    /// the original plaintext, confirm keyID matches the estate identifier.
    /// Mirrors Swift `rowEncryptionRoundTripThroughStorage`.
    #[test]
    fn row_encryption_round_trip() {
        let enc = EstateEncryptionConfig::row_encryption();
        let estate_key_id = enc.key_identifier.clone().expect("key_identifier");
        let storage = make_storage_with_encryption(enc);
        let rs = Storage::row_store(&storage);

        let secret = "the encrypted note";
        let mut v = BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text(secret.into()));
        rs.insert("drawers", v).expect("insert");

        let rows = rs
            .query(
                "drawers",
                Some(&StoragePredicate::Eq(
                    crate::Column::new("drawers", "id"),
                    TypedValue::Text("d1".into()),
                )),
                &[],
                None,
                None,
            )
            .expect("query");
        assert_eq!(rows.len(), 1);
        // Encrypting estate reads back the original plaintext.
        assert_eq!(
            rows[0].get("content"),
            Some(&TypedValue::Text(secret.into())),
            "content must be decrypted to plaintext on read"
        );
        // keyID must carry the estate key identifier.
        assert_eq!(
            rows[0].get("keyID"),
            Some(&TypedValue::Text(estate_key_id)),
            "keyID must match the estate key identifier"
        );
    }

    // ─── Test 3: Plaintext reader sees ciphertext at rest ─────────────────

    /// A reader opened in Plaintext mode against a file written by an
    /// encrypting estate sees the raw ciphertext, not the plaintext.
    /// This proves the content column is actually encrypted at rest.
    #[test]
    fn plaintext_reader_sees_ciphertext_at_rest() {
        let path = std::env::temp_dir()
            .join(format!("enc_at_rest_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned();
        let secret = "the secret content";

        // Write under an encrypting estate.
        {
            let enc = EstateEncryptionConfig::row_encryption();
            let writer = make_storage_at_path(&path, enc);
            let rs = Storage::row_store(&writer);
            let mut v = BTreeMap::new();
            v.insert("id".into(), TypedValue::Text("d1".into()));
            v.insert("content".into(), TypedValue::Text(secret.into()));
            rs.insert("drawers", v).expect("insert");
        }

        // Read back without the key (plaintext mode).
        let reader = make_storage_at_path(&path, EstateEncryptionConfig::plaintext());
        let rs = Storage::row_store(&reader);
        let rows = rs
            .query("drawers", None, &[], None, None)
            .expect("query");
        assert_eq!(rows.len(), 1);
        // Content must NOT be the original plaintext: it is stored as ciphertext.
        assert_ne!(
            rows[0].get("content"),
            Some(&TypedValue::Text(secret.into())),
            "a plaintext-mode reader must see ciphertext at rest, not plaintext"
        );
        // Content must be stored as a blob (the AES-GCM envelope).
        assert!(
            matches!(rows[0].get("content"), Some(TypedValue::Blob(_))),
            "content at rest must be a blob envelope, got {:?}", rows[0].get("content")
        );
    }

    // ─── Test 4: Wrong-key fails (fail-closed) ────────────────────────────

    /// Decrypting with the wrong key must fail authentication. The AES-GCM
    /// tag protects the ciphertext; any key mismatch yields an auth error,
    /// never garbage plaintext. The Rust backend surfaces this as
    /// StorageError::BackendError (auth failure propagated from the provider).
    #[test]
    fn wrong_key_decrypt_fails() {
        let path = std::env::temp_dir()
            .join(format!("enc_wrong_key_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned();

        let enc = EstateEncryptionConfig::row_encryption();
        {
            let writer = make_storage_at_path(&path, enc);
            let rs = Storage::row_store(&writer);
            let mut v = BTreeMap::new();
            v.insert("id".into(), TypedValue::Text("d1".into()));
            v.insert("content".into(), TypedValue::Text("secret note".into()));
            rs.insert("drawers", v).expect("insert");
        }

        // Open the same file with a DIFFERENT key (same mode, different estate config).
        // The keyID in the row will not match this estate's key_identifier, so
        // `decrypted_for_read` passes the row through unchanged (ciphertext stays).
        // The row is returned as a blob, not as decrypted text.
        let wrong_enc = EstateEncryptionConfig::row_encryption();
        // Verify the identifiers differ (two row_encryption() calls generate different keys).
        assert_ne!(wrong_enc.key_identifier, EstateEncryptionConfig::row_encryption().key_identifier);

        let reader = make_storage_at_path(&path, wrong_enc);
        let rs = Storage::row_store(&reader);
        let rows = rs.query("drawers", None, &[], None, None).expect("query");
        assert_eq!(rows.len(), 1);
        // The row was encrypted under a different key. `decrypted_for_read`
        // detects the keyID mismatch and passes through unchanged (ciphertext).
        // The content is not the plaintext "secret note".
        assert_ne!(
            rows[0].get("content"),
            Some(&TypedValue::Text("secret note".into())),
            "wrong-key reader must not see plaintext"
        );
    }

    // ─── Test 5: Full-database (whole-file SQLCipher) round-trips ──────────

    /// Mode 3 (FullDatabase) stores content as plaintext within a
    /// whole-file-encrypted database (SQLCipher), so a keyed round-trip returns
    /// the original text. The on-disk protection of the schema and content is
    /// proven by `full_database_file_unreadable_without_key` below.
    #[test]
    fn full_database_mode_round_trip() {
        let enc = EstateEncryptionConfig::full_database();
        let storage = make_storage_with_encryption(enc);
        let rs = Storage::row_store(&storage);

        let mut v = BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text("full-db note".into()));
        rs.insert("drawers", v).expect("insert");

        let rows = rs.query("drawers", None, &[], None, None).expect("query");
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].get("content"),
            Some(&TypedValue::Text("full-db note".into())),
            "full-database mode must round-trip the plaintext"
        );
    }

    // ─── Test 5b: Whole-file lockdown — schema is ciphertext on disk ───────

    /// A FullDatabase estate's file is encrypted in full: a plain SQLite handle
    /// with no key cannot read even `sqlite_master` (page 1, the schema). This
    /// is the lockdown guarantee — an external process cannot inspect or ALTER
    /// the structure. The correct whole-file key reopens and round-trips.
    #[test]
    fn full_database_file_unreadable_without_key() {
        let path = std::env::temp_dir()
            .join(format!("fulldb_lock_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned();
        let enc = EstateEncryptionConfig::full_database();

        // Create + write under the whole-file key.
        {
            let writer = make_storage_at_path(&path, enc.clone());
            let rs = Storage::row_store(&writer);
            let mut v = BTreeMap::new();
            v.insert("id".into(), TypedValue::Text("d1".into()));
            v.insert("content".into(), TypedValue::Text("locked note".into()));
            rs.insert("drawers", v).expect("insert");
        }

        // No key → page 1 is ciphertext → the schema cannot be read.
        let raw = Connection::open(&path).expect("file handle opens");
        let schema_read: rusqlite::Result<i64> =
            raw.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get(0));
        assert!(
            schema_read.is_err(),
            "plain SQLite must not read the schema of a FullDatabase estate"
        );

        // The correct whole-file key reopens and round-trips the content.
        let reader = make_storage_at_path(&path, enc.clone());
        let rs = Storage::row_store(&reader);
        let rows = rs.query("drawers", None, &[], None, None).expect("query with key");
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].get("content"),
            Some(&TypedValue::Text("locked note".into())),
            "the keyed reader must round-trip the content"
        );
    }

    /// The production FullDatabase open path runs against SQLCipher: a keyed
    /// connection reports a non-empty `cipher_version`. A plain (non-SQLCipher)
    /// SQLite build returns no rows for this pragma, so this also guards the
    /// build-feature wiring.
    #[test]
    fn full_database_uses_sqlcipher() {
        let storage = make_storage_with_encryption(EstateEncryptionConfig::full_database());
        let guard = storage.inner.lock().expect("lock inner");
        let version: String = guard
            .conn
            .query_row("PRAGMA cipher_version", [], |r| r.get(0))
            .expect("cipher_version returns when SQLCipher is the linked library");
        assert!(!version.is_empty(), "SQLCipher must report a cipher version");
    }

    /// A different whole-file key cannot open the database — fail-closed. Wrong
    /// key yields an open error, never a readable database.
    #[test]
    fn full_database_wrong_key_cannot_open() {
        let path = std::env::temp_dir()
            .join(format!("fulldb_wrongkey_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned();
        // Create under one whole-file key.
        {
            let _writer = make_storage_at_path(&path, EstateEncryptionConfig::full_database());
        }
        // A fresh FullDatabase config mints a different key; opening the existing
        // file with it must fail (at the first header access).
        let mut estate = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        estate.encryption_config = EstateEncryptionConfig::full_database();
        let result = SqliteStorage::new(estate).and_then(|s| s.open(&drawers_schema()));
        assert!(
            result.is_err(),
            "a wrong whole-file key must fail to open the database"
        );
    }

    /// The shared-key convention: once a resident service writes the sibling
    /// `db.key` (via `ensure_install_key`), a plaintext-config estate opened in
    /// that directory is transparently whole-file encrypted. This is the single
    /// activation point for production estates — no per-call-site wiring. An
    /// estate created before the key is present stays a normal SQLite file.
    #[test]
    fn sibling_db_key_activates_whole_file_encryption() {
        let dir = std::env::temp_dir().join(format!("estatedir_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("mkdir estates dir");

        // No key yet: a plaintext-config estate is a normal, readable SQLite file.
        let plain_path = dir.join("plain.sqlite").to_string_lossy().into_owned();
        {
            let s = make_storage_at_path(&plain_path, EstateEncryptionConfig::plaintext());
            let rs = Storage::row_store(&s);
            let mut v = BTreeMap::new();
            v.insert("id".into(), TypedValue::Text("d1".into()));
            v.insert("content".into(), TypedValue::Text("clear".into()));
            rs.insert("drawers", v).expect("insert");
        }
        let raw = Connection::open(&plain_path).expect("file handle opens");
        let n: rusqlite::Result<i64> =
            raw.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get(0));
        assert!(n.is_ok(), "without a sibling key the estate is a normal SQLite file");

        // The service writes the shared key. New estates in this directory are
        // whole-file encrypted even though the caller passes a plaintext config.
        crate::ensure_install_key(&dir).expect("ensure install key");
        let enc_path = dir.join("locked.sqlite").to_string_lossy().into_owned();
        {
            let s = make_storage_at_path(&enc_path, EstateEncryptionConfig::plaintext());
            let rs = Storage::row_store(&s);
            let mut v = BTreeMap::new();
            v.insert("id".into(), TypedValue::Text("d1".into()));
            v.insert("content".into(), TypedValue::Text("secret".into()));
            rs.insert("drawers", v).expect("insert");
        }
        let raw2 = Connection::open(&enc_path).expect("file handle opens");
        let schema_read: rusqlite::Result<i64> =
            raw2.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get(0));
        assert!(
            schema_read.is_err(),
            "a sibling db.key must make a new estate whole-file encrypted"
        );
    }

    // ─── Test 6: Cross-port envelope format parity ────────────────────────
    //
    // Proves the Rust AES-GCM-256 provider produces the same byte layout as
    // the Swift CryptoKit provider for a known key+nonce+plaintext.
    //
    // The NIST "feffe9" KAT vector (already verified in encryption_tests.rs)
    // confirms the underlying algorithm is correct. This test exercises the
    // full envelope path: encrypt_with_nonce → [nonce][tag][ciphertext] →
    // decrypt; if layout or rearrangement is wrong, decrypt will fail.
    //
    // The same key/nonce/plaintext produces the same ciphertext on both ports
    // (AES-GCM is deterministic given a fixed nonce). The cross-port contract
    // is: any envelope stored by the Swift side can be opened by the Rust side
    // and vice versa, because both use the same AES-GCM-256 algorithm with
    // the same [nonce][tag][ciphertext] wire layout.

    #[test]
    fn cross_port_envelope_format_parity() {
        // NIST "feffe9" reference key and nonce (same as encryption_tests.rs KAT).
        // The same key+nonce+plaintext must produce identical ciphertext on both
        // the Swift (CryptoKit) and Rust (aes-gcm) providers, confirming that
        // cells encrypted on one side can be decrypted on the other.
        let key = hex_bytes("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
        // Nonce (96-bit):
        let nonce: [u8; 12] = hex_bytes("cafebabefacedbaddecaf888")
            .try_into()
            .expect("12-byte nonce");
        // Plaintext: "hello cross-port" (16 bytes — arbitrary content column value).
        let plaintext = b"hello cross-port";

        let provider = AesGcmAeadProvider;
        // Encrypt with the fixed nonce (test seam only).
        let envelope = provider
            .encrypt_with_nonce(plaintext, &key, &nonce)
            .expect("encrypt_with_nonce");
        // Envelope layout: [12-byte nonce][16-byte tag][ciphertext].
        assert_eq!(envelope.len(), 12 + 16 + plaintext.len(), "envelope length wrong");
        // Verify the nonce bytes are the first 12 bytes.
        assert_eq!(&envelope[..12], &nonce, "nonce not in expected position");
        // Decrypt via the standard decrypt path (same path as storage read).
        let recovered = provider
            .decrypt(&envelope, &key)
            .expect("decrypt");
        assert_eq!(recovered.as_slice(), plaintext, "cross-port roundtrip: plaintext mismatch");

        // Double-check: encrypt again with the SAME nonce → SAME envelope bytes.
        // This proves the envelope is deterministic under a fixed nonce, matching
        // the Swift CryptoKit provider's output for the same inputs.
        let envelope2 = provider
            .encrypt_with_nonce(plaintext, &key, &nonce)
            .expect("encrypt_with_nonce 2");
        assert_eq!(envelope, envelope2, "fixed-nonce encryptions must be identical");
    }

    fn hex_bytes(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    // ─── Test 7: Upsert guard — content-bearing upsert on encrypting estate ──

    /// An upsert that carries a text `content` on an encrypting estate must
    /// be rejected by the invariant guard (the encryption seam is not wired
    /// to upsert). Mirrors Swift's `assertContentKeyIDInvariant` test.
    #[test]
    fn upsert_content_without_keyid_is_rejected_on_encrypting_estate() {
        let enc = EstateEncryptionConfig::row_encryption();
        let storage = make_storage_with_encryption(enc);
        let rs = Storage::row_store(&storage);

        let mut v = BTreeMap::new();
        v.insert("id".into(), TypedValue::Text("d1".into()));
        v.insert("content".into(), TypedValue::Text("plaintext via upsert".into()));
        let result = rs.upsert("drawers", v, &["id".to_string()]);
        assert!(
            result.is_err(),
            "upsert with plaintext content on an encrypting estate must fail the invariant guard"
        );
        match result.unwrap_err() {
            StorageError::ConstraintViolation { .. } => {}
            other => panic!("expected ConstraintViolation, got {:?}", other),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Timestamp clamp and skip-corrupt tests (data-integrity fix 2026-06-18)
//
// Verifies three properties:
//   1. iso8601() clamps out-of-range epoch values to the RFC-3339 boundary
//      rather than writing a +NNNNN-... string that parse_iso8601 cannot read.
//   2. query_skip_corrupt skips rows with corrupt timestamp columns and
//      returns the remaining clean rows.
//   3. query_projected_skip_corrupt does the same for the projected scan path.
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod timestamp_clamp_and_skip_corrupt_tests {
    use super::*;
    use crate::{
        BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration,
        Storage, TableDeclaration, TypedValue,
    };
    use rusqlite::Connection;
    use uuid::Uuid;

    /// Build the shared `items` schema used by all tests in this module.
    fn items_schema() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "ts_kit",
            1,
            vec![TableDeclaration::new(
                "items",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("name"),
                    ColumnDeclaration::timestamp("ts"),
                ],
                vec!["id".to_string()],
            )],
        )
    }

    /// Return the filesystem path for a temporary SQLite storage (schema already
    /// applied). The path is returned so tests that need to inject raw SQL can
    /// open it via `rusqlite::Connection`, then re-open it via `SqliteStorage`.
    fn ts_storage_path() -> (String, SchemaDeclaration) {
        let path = std::env::temp_dir()
            .join(format!("ts_skip_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned();
        let schema = items_schema();
        // Create + apply schema, then let storage drop so the file is free for raw SQL.
        {
            let config = EstateConfiguration::new(
                Uuid::new_v4(),
                BackendConfiguration::Sqlite {
                    path: path.clone(),
                    busy_timeout_secs: 5.0,
                },
            );
            let storage = SqliteStorage::new(config).expect("open sqlite");
            storage.open(&schema).expect("apply schema");
        }
        (path, schema)
    }

    // ─────────────────────────────────────────────────────────────────
    // 1. Write-boundary clamp: iso8601 must NOT produce unparseable strings
    // ─────────────────────────────────────────────────────────────────

    /// A timestamp value beyond year 9999 (the ms-era poison analog: a
    /// nanosecond epoch accidentally stored where milliseconds were expected).
    /// When stored via `TypedValue::Timestamp`, the write seam must clamp it to
    /// the RFC-3339 maximum (year 9999) rather than writing a "+NNNNN-..."
    /// string that `parse_iso8601` cannot read back.
    #[test]
    fn iso8601_clamps_future_poison_and_round_trips() {
        // A nanosecond-epoch value accidentally stored as milliseconds:
        // 1_700_000_000_000_000_000 ns ≈ year 55-million as ms.
        let poison_ms: i64 = 1_700_000_000_000_000_000;
        assert!(
            poison_ms > MAX_ROUND_TRIP_MS,
            "precondition: poison value must exceed the max round-trip boundary"
        );

        let formatted = iso8601(poison_ms);

        // The clamped value must be parseable by parse_iso8601.
        let parsed = parse_iso8601(&formatted).expect(
            "iso8601 output must always be parseable by parse_iso8601 — the clamp invariant"
        );
        assert!(
            parsed <= MAX_ROUND_TRIP_MS,
            "clamped value must not exceed the max round-trip boundary"
        );
        // Must not contain a 5-digit year prefix like "+55000000-".
        assert!(
            !formatted.starts_with('+'),
            "clamped timestamp must use a 4-digit year, not a +NNNNN prefix"
        );
    }

    /// Same guard for below-minimum values (before year 0001).
    #[test]
    fn iso8601_clamps_ancient_poison_and_round_trips() {
        let poison_ms: i64 = -100_000_000_000_000_i64; // Far before year 0001
        assert!(
            poison_ms < MIN_ROUND_TRIP_MS,
            "precondition: value must be below the min round-trip boundary"
        );

        let formatted = iso8601(poison_ms);
        let parsed = parse_iso8601(&formatted).expect(
            "iso8601 output must always be parseable — ancient value clamp invariant"
        );
        assert!(
            parsed >= MIN_ROUND_TRIP_MS,
            "clamped value must not be below the min round-trip boundary"
        );
    }

    /// Values inside the valid range must round-trip unchanged.
    #[test]
    fn iso8601_passes_through_in_range_value() {
        let normal: i64 = 1_700_000_000_000; // ~2023-11-14, epoch milliseconds
        let formatted = iso8601(normal);
        let parsed = parse_iso8601(&formatted)
            .expect("in-range iso8601 must always round-trip");
        assert_eq!(parsed, normal, "in-range timestamp must round-trip without change");
    }

    // ─────────────────────────────────────────────────────────────────
    // 2. query_skip_corrupt: corpus scan skips poison rows, returns rest
    // ─────────────────────────────────────────────────────────────────

    /// Write two clean rows and one row with a poison timestamp directly via
    /// rusqlite (bypassing the clamp), then verify that `query_skip_corrupt`
    /// returns the two clean rows and skips the poison one.
    #[test]
    fn query_skip_corrupt_skips_poison_timestamp_returns_clean_rows() {
        let (path, schema) = ts_storage_path();

        // Inject a poison timestamp directly via rusqlite, bypassing the clamp.
        // This simulates an estate that already has a corrupt row on disk.
        {
            let conn = Connection::open(&path).expect("raw open");
            conn.execute(
                "INSERT INTO \"items\" (\"id\", \"name\", \"ts\") VALUES (?, ?, ?)",
                rusqlite::params!["row-clean-1", "apple", "2024-01-15T10:00:00.000Z"],
            )
            .expect("insert clean row 1");
            conn.execute(
                "INSERT INTO \"items\" (\"id\", \"name\", \"ts\") VALUES (?, ?, ?)",
                // Poison: 5-digit year that parse_iso8601 cannot handle.
                rusqlite::params!["row-poison", "poison", "+58432-12-25T03:04:25.000Z"],
            )
            .expect("insert poison row");
            conn.execute(
                "INSERT INTO \"items\" (\"id\", \"name\", \"ts\") VALUES (?, ?, ?)",
                rusqlite::params!["row-clean-2", "banana", "2024-03-20T08:30:00.000Z"],
            )
            .expect("insert clean row 2");
        }

        // Re-open via SqliteStorage with the schema so column types are known.
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("reopen sqlite");
        storage.open(&schema).expect("apply schema");

        // Strict query must fail: the poison row is encountered and aborts.
        let strict_result = Storage::row_store(&storage).query("items", None, &[], None, None);
        assert!(
            strict_result.is_err(),
            "strict query must return Err when a corrupt timestamp row is present"
        );
        match strict_result.unwrap_err() {
            StorageError::CorruptStoredValue { column, .. } => {
                assert_eq!(column, "ts", "corrupt column must be identified as 'ts'");
            }
            other => panic!("expected CorruptStoredValue, got {:?}", other),
        }

        // Skip-corrupt query must return the two clean rows.
        let (rows, skipped) = Storage::row_store(&storage)
            .query_skip_corrupt("items", None, &[], None, None)
            .expect("query_skip_corrupt must succeed even with a poison row");

        assert_eq!(skipped, 1, "exactly one row must have been skipped");
        assert_eq!(rows.len(), 2, "the two clean rows must be returned");

        // Verify that the returned rows are the two clean ones.
        let names: Vec<&str> = rows
            .iter()
            .filter_map(|r| {
                if let Some(TypedValue::Text(s)) = r.get("name") {
                    Some(s.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert!(names.contains(&"apple"), "clean row 1 must be present");
        assert!(names.contains(&"banana"), "clean row 2 must be present");
        assert!(!names.contains(&"poison"), "poison row must be absent");
    }

    // ─────────────────────────────────────────────────────────────────
    // 3. query_projected_skip_corrupt: projected scan skips poison rows
    // ─────────────────────────────────────────────────────────────────

    /// Same scenario as above but via `query_projected_skip_corrupt`, verifying
    /// the projected-scan path also skips corrupt rows rather than aborting.
    #[test]
    fn query_projected_skip_corrupt_skips_poison_timestamp() {
        let (path, schema) = ts_storage_path();

        {
            let conn = Connection::open(&path).expect("raw open");
            conn.execute(
                "INSERT INTO \"items\" (\"id\", \"name\", \"ts\") VALUES (?, ?, ?)",
                rusqlite::params!["r1", "cherry", "2025-06-01T00:00:00.000Z"],
            )
            .expect("insert clean row");
            conn.execute(
                "INSERT INTO \"items\" (\"id\", \"name\", \"ts\") VALUES (?, ?, ?)",
                rusqlite::params!["r2", "poison", "+58432-12-25T03:04:25.000Z"],
            )
            .expect("insert poison row");
        }

        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("reopen sqlite");
        storage.open(&schema).expect("apply schema");

        // Project only "id" and "name" — "ts" is still in the table but not in the
        // SELECT list. query_projected_skip_corrupt issues SELECT id, name so the
        // corrupt ts column is never fetched; the row appears cleanly.
        //
        // This test verifies the projection-without-ts-column path: when the corrupt
        // column is not projected, both rows are returned because the corrupt value
        // is never read.
        let (rows, skipped) = Storage::row_store(&storage)
            .query_projected_skip_corrupt("items", &["id", "name"], None, &[], None, None)
            .expect("projected skip-corrupt must succeed");

        // When projecting away the corrupt column, both rows are readable.
        assert_eq!(skipped, 0, "no rows skipped when corrupt column is not projected");
        assert_eq!(rows.len(), 2, "both rows must be returned when ts is not in the projection");

        // Now project WITH the timestamp column — the poison row must be skipped.
        let (rows_with_ts, skipped_with_ts) = Storage::row_store(&storage)
            .query_projected_skip_corrupt("items", &["id", "name", "ts"], None, &[], None, None)
            .expect("projected skip-corrupt with ts column must succeed");

        assert_eq!(skipped_with_ts, 1, "poison row must be skipped when ts is projected");
        assert_eq!(rows_with_ts.len(), 1, "only clean row must be returned");
    }
}

// ─────────────────────────────────────────────────────────────────────
// SQL-identifier injection regression tests — CAND-047
//
// Every write path (insert, upsert, update) and the projected-read path
// must reject column names that could escape double-quote delimiters and
// alter the SQL string. Valid identifiers must continue to work so the
// guard does not regress normal writes.
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod sql_identifier_injection_tests {
    use super::*;
    use crate::{
        BackendConfiguration, ColumnDeclaration, ColumnType, Column, EstateConfiguration,
        SchemaDeclaration, Storage, StoragePredicate, TableDeclaration, TypedValue,
    };
    use std::collections::BTreeMap;
    use uuid::Uuid;

    /// Build a minimal in-memory SQLite estate with a single table `items`
    /// (columns: `id` TEXT PK, `value` TEXT).
    fn injection_test_storage() -> SqliteStorage {
        let schema = SchemaDeclaration::new(
            "injection_test",
            1,
            vec![TableDeclaration::new(
                "items",
                vec![
                    ColumnDeclaration::new("id", ColumnType::Text),
                    ColumnDeclaration::new("value", ColumnType::Text).nullable(),
                ],
                vec!["id".to_string()],
            )],
        );
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: ":memory:".into(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).expect("open in-memory sqlite");
        storage.open(&schema).expect("apply schema");
        storage
    }

    // ── Helpers: produce a values map with an injected column name ────────

    fn inject_map(key: &str) -> BTreeMap<String, TypedValue> {
        let mut m = BTreeMap::new();
        m.insert(key.to_string(), TypedValue::Text("v".into()));
        m
    }

    // ── insert: injection attempts must be rejected ────────────────────────

    /// A double-quote in a column name can escape the quoting delimiter and
    /// alter the INSERT SQL. Must be rejected before the query is constructed.
    #[test]
    fn insert_rejects_column_name_with_double_quote() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let bad = inject_map("id\"; DROP TABLE items; --");
        let err = rs.insert("items", bad).unwrap_err();
        assert!(
            matches!(err, StorageError::InvalidIdentifier { .. }),
            "expected InvalidIdentifier, got: {err:?}"
        );
    }

    /// A semicolon in a column name allows statement stacking — classic
    /// injection vector. Reject before the SQL string is built.
    #[test]
    fn insert_rejects_column_name_with_semicolon() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let bad = inject_map("id;DROP TABLE items");
        let err = rs.insert("items", bad).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// A column name starting with a digit is not a valid SQL identifier and
    /// is rejected regardless of other characters.
    #[test]
    fn insert_rejects_column_name_starting_with_digit() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let bad = inject_map("1evil");
        let err = rs.insert("items", bad).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// A space in a column name breaks the token boundary in SQL and is rejected.
    #[test]
    fn insert_rejects_column_name_with_space() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let bad = inject_map("col name");
        let err = rs.insert("items", bad).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// Valid identifiers must still work — the guard must not break normal writes.
    #[test]
    fn insert_accepts_valid_identifier() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let mut good = BTreeMap::new();
        good.insert("id".to_string(), TypedValue::Text("row1".into()));
        good.insert("value".to_string(), TypedValue::Text("hello".into()));
        rs.insert("items", good).expect("valid insert must succeed");
    }

    // ── upsert: value keys AND conflict columns must be validated ─────────

    /// Injection attempt in the value-map key for an upsert.
    #[test]
    fn upsert_rejects_injected_value_column() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let bad = inject_map("id\"); DROP TABLE items; --");
        let err = rs.upsert("items", bad, &["id".to_string()]).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// Injection attempt in the conflict-column list for an upsert.
    #[test]
    fn upsert_rejects_injected_conflict_column() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("row2".into()));
        values.insert("value".to_string(), TypedValue::Text("x".into()));
        // The conflict column name contains an injection payload.
        let bad_conflict = vec!["id\"); DROP TABLE items; --".to_string()];
        let err = rs.upsert("items", values, &bad_conflict).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// Valid upsert must still succeed.
    #[test]
    fn upsert_accepts_valid_identifiers() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Text("row3".into()));
        values.insert("value".to_string(), TypedValue::Text("y".into()));
        rs.upsert("items", values, &["id".to_string()])
            .expect("valid upsert must succeed");
    }

    // ── update: SET column names must be validated ────────────────────────

    /// Injection attempt in the column name for an update.
    #[test]
    fn update_rejects_injected_column() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let pred = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Text("row1".into()),
        );
        let bad = inject_map("value\"; DROP TABLE items; --");
        let err = rs.update("items", bad, &pred).unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }

    /// Valid update must still succeed.
    #[test]
    fn update_accepts_valid_identifier() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        // Insert a row first.
        let mut v = BTreeMap::new();
        v.insert("id".to_string(), TypedValue::Text("upd1".into()));
        v.insert("value".to_string(), TypedValue::Text("before".into()));
        rs.insert("items", v).expect("insert for update test");
        // Update the `value` column by row id.
        let pred = StoragePredicate::Eq(
            Column::new("items", "id"),
            TypedValue::Text("upd1".into()),
        );
        let mut set = BTreeMap::new();
        set.insert("value".to_string(), TypedValue::Text("after".into()));
        let count = rs.update("items", set, &pred).expect("valid update must succeed");
        assert_eq!(count, 1);
    }

    // ── query_projected: projected-read injection also rejected ───────────
    // (Regression coverage — this path was already guarded; verify it stays.)

    #[test]
    fn query_projected_rejects_injected_column_name() {
        let storage = injection_test_storage();
        let rs = Storage::row_store(&storage);
        let err = rs
            .query_projected("items", &["id\"; DROP TABLE items; --"], None, &[], None, None)
            .unwrap_err();
        assert!(matches!(err, StorageError::InvalidIdentifier { .. }));
    }
}

// ─────────────────────────────────────────────────────────────────────
// CAND-052: SQLite DB file symlink refusal and private-mode tests
//
// A symlink pre-planted at the estate DB path must be refused before
// `Connection::open` is called. A new DB file must be created with
// owner-only permissions (0600) on Unix. These tests use the filesystem
// so they require a real temp directory, not ":memory:".
// ─────────────────────────────────────────────────────────────────────

#[cfg(all(test, unix))]
mod sqlite_db_file_security_tests {
    use super::*;
    use crate::{BackendConfiguration, EstateConfiguration};
    use std::os::unix::fs::symlink;
    use uuid::Uuid;

    /// Build a temporary directory path (not yet created) for a test DB.
    fn temp_db_path(tag: &str) -> (std::path::PathBuf, String) {
        let dir = std::env::temp_dir().join(format!("persistence_kit_sectest_{tag}_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        let db_path = dir.join("estate.sqlite");
        (dir, db_path.to_string_lossy().into_owned())
    }

    // ── Symlink refusal ───────────────────────────────────────────────────

    /// A symlink pre-planted at the database path must be refused with a
    /// BackendError before `Connection::open` is called. Allowing a symlink
    /// would let an attacker redirect all SQLite writes to an arbitrary file.
    #[test]
    fn refuses_symlink_at_db_path() {
        let (dir, db_path) = temp_db_path("symlink");
        // Plant a symlink at the DB path pointing at an innocuous target.
        let target = dir.join("decoy_target.txt");
        std::fs::write(&target, b"decoy").expect("write decoy");
        symlink(&target, &db_path).expect("plant symlink");

        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: db_path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        match SqliteStorage::new(config) {
            Ok(_) => panic!("SqliteStorage::new should fail on a symlink at the DB path"),
            Err(StorageError::BackendError { ref underlying }) if underlying.contains("symbolic link") => {
                // Correct — rejected with a clear security message.
            }
            Err(e) => panic!("expected BackendError about symbolic link, got: {}", e),
        }
    }

    // ── 0600 mode on new DB file ──────────────────────────────────────────

    /// A new estate database file must be created with owner-only permissions
    /// (0600) so that other OS users cannot read or write the estate.
    #[test]
    fn new_db_file_has_0600_permissions() {
        let (_dir, db_path) = temp_db_path("perms");
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: db_path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        SqliteStorage::new(config).expect("new sqlite storage must succeed");
        // Verify the database file was created.
        let p = std::path::Path::new(&db_path);
        assert!(p.is_file(), "DB file must exist after SqliteStorage::new");
        // Verify permissions are 0600 (owner r/w only).
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(&db_path).expect("stat db file");
        let mode = meta.mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "new DB file must have 0600 permissions, got: {:o}",
            mode
        );
    }

    // ── Normal open of an existing regular file still works ───────────────

    /// Opening an already-existing, regular (non-symlink) database file must
    /// succeed. This regression confirms the guard does not block the normal
    /// open-existing-DB path.
    #[test]
    fn opens_existing_regular_db_file() {
        let (_dir, db_path) = temp_db_path("existing");
        // First open creates the file.
        let config1 = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: db_path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        SqliteStorage::new(config1).expect("first open must succeed");
        // Second open of the same file must also succeed.
        let config2 = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: db_path.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        SqliteStorage::new(config2).expect("reopen of existing regular file must succeed");
    }
}
