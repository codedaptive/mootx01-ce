//! BasisStore: persistence-kit-backed `corpus_provider_basis` table.
//! Rust mirror of Swift's `BasisStore` (mission 6a-ii-β). Persists a trained
//! distributional provider's serialized basis blob so the dense lane is
//! trained-ready immediately after a process restart, without re-running
//! training on every open.
//!
//! Schema (single table, one row per (model_id, model_version)):
//!   corpus_provider_basis (
//!     model_id            TEXT NOT NULL,
//!     model_version       TEXT NOT NULL,
//!     basis               BLOB NOT NULL,
//!     trained_at          TIMESTAMP NOT NULL,   -- TEXT ISO8601, never REAL
//!     trained_chunk_count INTEGER NOT NULL
//!   )  PRIMARY KEY (model_id, model_version)
//!
//! ## Why each column (mirrors the Swift rationale exactly)
//!
//!   - model_id / model_version: the basis is valid only for the exact provider
//!     it was trained for; keying the row by this tuple makes the load query
//!     unambiguous and matches the (model_id, model_version) every vector row is
//!     keyed under.
//!   - basis: the 6a-i serialized blob — raw little-endian bytes, so BLOB (not
//!     TEXT) avoids a lossy encoding round-trip.
//!   - trained_at: WHEN the basis was last (re)trained. TIMESTAMP maps to TEXT
//!     ISO8601 at the SQLite layer (schema invariant: human readability, string
//!     sortability, timezone correctness) — NEVER REAL/Unix-timestamp on disk.
//!     The value is the caller's `now` (determinism), never `SystemTime::now()`.
//!   - trained_chunk_count: chunks the basis was trained on — the staleness
//!     anchor for the DOCUMENTED FOLLOW-UP growth-threshold auto-retrain knob
//!     (β scope stops at first-ingest + explicit reindex). INTEGER, not a Bool
//!     flag — there are no Bool stored columns in this schema.
//!
//! The table is NOT append-only: `reindex` UPSERTs the basis row in place on a
//! retrain, so there is exactly one basis row per provider key — no row
//! accumulation, no orphans.
//!
//! Layering: this store lives in core `corpus-kit` and depends only on
//! persistence-kit, exactly like `BundleStore`. It never depends on
//! `corpus-kit-providers` — the blob bytes are opaque here; only the trainable
//! provider (reached through the `TrainableEmbeddingBasis` seam) interprets them.

use crate::error::{CorpusKitError, CorpusKitResult};
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, StorageRow,
    TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The basis blob is produced by the 6a-i codec via the
// TrainableEmbeddingBasis seam; this store only persists and returns
// the opaque bytes. It computes nothing.
// ─────────────────────────────────────────────────────────────────

/// A persisted trained-basis row: the serialized blob plus the metadata that
/// keys and dates it. Rust mirror of Swift's `PersistedBasis`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedBasis {
    /// The provider model_id the basis was trained for.
    pub model_id: String,
    /// The provider model_version the basis was trained for.
    pub model_version: String,
    /// The 6a-i serialized basis blob.
    pub basis: Vec<u8>,
    /// When the basis was last (re)trained, in Unix seconds (the caller's
    /// `now`). Stored as TEXT ISO8601 at the SQLite layer per the schema
    /// invariant; the TypedValue carries the i64 seconds form.
    pub trained_at_secs: i64,
    /// How many chunks the basis was trained on (staleness anchor).
    pub trained_chunk_count: usize,
}

/// Storage for a trained embedding provider's serialized basis blob.
///
/// One row per (model_id, model_version). `upsert` writes/replaces the row;
/// `load` reads it back; `delete_all` wipes every basis row as part of
/// `Corpus::destroy_recall_index`. The store interprets none of the bytes —
/// only the trainable provider does, via the `TrainableEmbeddingBasis` seam.
pub struct BasisStore {
    storage: Arc<dyn Storage>,
}

impl BasisStore {
    /// Additive schema declaration for the basis-persistence table. Mirrors the
    /// Swift `BasisStore.schemaDeclaration`. Not append-only: a retrain UPSERTs
    /// the (model_id, model_version) row, so the table holds at most one basis
    /// per provider key.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitBasis",
            1,
            vec![TableDeclaration::new(
                "corpus_provider_basis",
                vec![
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("model_version"),
                    // BLOB: the raw little-endian 6a-i basis bytes.
                    ColumnDeclaration::blob("basis"),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    ColumnDeclaration::timestamp("trained_at"),
                    // INTEGER staleness anchor — NOT a Bool flag.
                    ColumnDeclaration::int("trained_chunk_count"),
                ],
                vec!["model_id".to_string(), "model_version".to_string()],
            )],
            // appendOnly defaults to off: a retrain UPSERTs the row in place.
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        BasisStore { storage }
    }

    /// Insert or replace the basis row for a provider key.
    ///
    /// Keyed by the composite primary key (model_id, model_version): a retrain
    /// replaces the prior basis in place rather than accumulating rows. The
    /// `trained_at_secs` is the caller's `now` (determinism) and
    /// `trained_chunk_count` is the chunk count the basis was trained on.
    pub fn upsert(&self, row: &PersistedBasis) -> CorpusKitResult<()> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert(
            "model_version".into(),
            TypedValue::Text(row.model_version.clone()),
        );
        values.insert("basis".into(), TypedValue::Blob(row.basis.clone()));
        values.insert("trained_at".into(), TypedValue::Timestamp(row.trained_at_secs));
        values.insert(
            "trained_chunk_count".into(),
            TypedValue::Int(row.trained_chunk_count as i64),
        );
        // ON CONFLICT (model_id, model_version) DO UPDATE: upsert replaces the
        // non-conflict columns of the existing row for the same provider key,
        // so a retrain overwrites the prior basis in place.
        self.storage
            .row_store()
            .upsert(
                "corpus_provider_basis",
                values,
                &["model_id".to_string(), "model_version".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Load the persisted basis for a provider key, or `None` if none is stored.
    pub fn load(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<PersistedBasis>> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_basis", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_basis", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query("corpus_provider_basis", Some(&predicate), &[], Some(1), None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.first().and_then(decode_basis))
    }

    /// Delete every basis row. Used by `Corpus::destroy_recall_index` so a
    /// destroyed corpus leaves no orphaned trained basis behind. `IsTrue` is the
    /// always-match predicate (delete requires a predicate).
    pub fn delete_all(&self) -> CorpusKitResult<()> {
        self.storage
            .row_store()
            .delete("corpus_provider_basis", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}

/// Decode a basis row, tolerant of BOTH the semantic TypedValue forms a
/// migrate-aware connection returns AND the primitive forms a fresh connection
/// returns on read. This is the same primitive-tolerance discipline
/// `bundle_store::decode_chunk` uses: the SQLite backend re-parses a TIMESTAMP
/// column to `Timestamp(i64)` ONLY when the connection's column-type registry is
/// populated (i.e. the connection ran `migrate`); a SECOND connection that
/// merely opens the existing file returns the raw `Text` ISO8601 form. A
/// semantic-only reader silently drops every persisted basis on reopen — exactly
/// the trap that made persisted recall go dark — so `trained_at` is decoded
/// tolerant of both forms. Per-column:
///   - model_id / model_version: `Text` on both.
///   - basis: `Blob` on both.
///   - trained_at: `Timestamp(i64)` (migrate-aware) or `Text` ISO8601 (fresh
///     connection); parsed by `decode_trained_at_secs`.
///   - trained_chunk_count: `Int` on both.
/// A row that fails any field match yields `None` rather than a fabricated basis.
fn decode_basis(row: &StorageRow) -> Option<PersistedBasis> {
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let basis = match row.get("basis") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return None,
    };
    let trained_at_secs = decode_trained_at_secs(row.get("trained_at"))?;
    let trained_chunk_count = match row.get("trained_chunk_count") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    Some(PersistedBasis {
        model_id,
        model_version,
        basis,
        trained_at_secs,
        trained_chunk_count,
    })
}

/// Decode the trained_at column to epoch seconds, tolerant of `Timestamp(i64)`
/// (a migrate-aware connection) and `Text` ISO8601 (a fresh connection that did
/// not run migrate). The ISO8601 form is the kit-canonical
/// "YYYY-MM-DDTHH:MM:SS[.fff]Z" UTC string the SQLite backend writes. Parsed by
/// the inline `parse_iso8601_utc` (C-1: no external date crate in corpus-kit).
fn decode_trained_at_secs(value: Option<&TypedValue>) -> Option<i64> {
    match value {
        Some(TypedValue::Timestamp(secs)) => Some(*secs),
        Some(TypedValue::Text(s)) => parse_iso8601_utc(s),
        _ => None,
    }
}

/// Parse a kit-canonical ISO8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SS[.fff]Z")
/// into seconds-since-epoch. Inline (no external date crate, C-1). Only the UTC
/// 'Z' form the SQLite backend writes is supported; any fractional part is
/// ignored (the kit stores whole-second precision). Returns `None` on a
/// malformed string.
fn parse_iso8601_utc(s: &str) -> Option<i64> {
    // Expected shape: YYYY-MM-DDTHH:MM:SS optionally followed by .fff and 'Z'.
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| -> Option<i64> { s.get(a..b)?.parse::<i64>().ok() };
    // Separators must be exactly where ISO8601 puts them.
    if bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T'
        || bytes[13] != b':' || bytes[16] != b':'
    {
        return None;
    }
    let year = num(0, 4)?;
    let month = num(5, 7)?;
    let day = num(8, 10)?;
    let hour = num(11, 13)?;
    let minute = num(14, 16)?;
    let second = num(17, 19)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Days since the Unix epoch via the standard civil-from-days algorithm
    // (Howard Hinnant's date arithmetic), valid for the proleptic Gregorian
    // calendar across all years the kit will ever store.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    let days = era * 146_097 + doe - 719_468; // days since 1970-01-01
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}
