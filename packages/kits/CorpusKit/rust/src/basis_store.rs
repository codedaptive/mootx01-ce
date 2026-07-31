//! BasisStore: persistence-kit-backed `corpus_provider_basis` table.
//! Rust mirror of Swift's `BasisStore` (mission 6a-ii-β, MXE-BB). Persists
//! a trained distributional provider's serialized basis blob so the dense
//! lane is trained-ready immediately after a process restart, without
//! re-running training on every open.
//!
//! ## Why chunked storage
//!
//! SQLite's `SQLITE_LIMIT_LENGTH` caps a single bound value at ~1 GB. A
//! large-vocabulary (≥122 k term) corpus produces a basis blob that
//! approaches or exceeds this cap. Binding one giant blob to
//! `sqlite3_bind_blob` therefore fails with `SQLITE_TOOBIG`, which surfaces
//! as `backendError("bind blob")`. Chunking splits the blob into parts of at
//! most `CHUNK_SIZE_LIMIT` bytes before storage and reassembles them on load.
//! Part identity is carried by `part_index` (0-based), which is also the
//! third component of the composite primary key.
//!
//! ## Schema (one row per (model_id, model_version, part_index))
//!
//!   corpus_provider_basis (
//!     model_id            TEXT NOT NULL,
//!     model_version       TEXT NOT NULL,
//!     part_index          INTEGER NOT NULL DEFAULT 0,  -- chunk sequence number
//!     basis               BLOB NOT NULL,               -- chunk bytes
//!     trained_at          TIMESTAMP NOT NULL,          -- TEXT ISO8601, never REAL
//!     trained_chunk_count INTEGER NOT NULL,
//!     ext                 JSON                         -- forward-compat slot (nullable, v2); NULL in 1.0
//!   )  PRIMARY KEY (model_id, model_version, part_index)
//!
//! ## Why each column (mirrors the Swift rationale exactly)
//!
//!   - model_id / model_version: the basis is valid only for the exact provider
//!     it was trained for; keying the row by this tuple makes the load query
//!     unambiguous and matches the (model_id, model_version) every vector row
//!     is keyed under.
//!   - part_index: 0-based chunk sequence number. All parts for the same
//!     provider key are loaded in ascending part_index order and concatenated.
//!     A single-chunk basis has exactly one row at index 0.
//!   - basis: one chunk of the 6a-i serialized blob — raw little-endian bytes,
//!     so BLOB (not TEXT) avoids a lossy encoding round-trip.
//!   - trained_at: WHEN the basis was last (re)trained. TIMESTAMP maps to TEXT
//!     ISO8601 at the SQLite layer (schema invariant: human readability, string
//!     sortability, timezone correctness) — NEVER REAL/Unix-timestamp on disk.
//!     The value is the caller's `now` (determinism), never `SystemTime::now()`.
//!     Stored identically on every part row for the same provider key.
//!   - trained_chunk_count: chunks the basis was trained on — the staleness
//!     anchor for the DOCUMENTED FOLLOW-UP growth-threshold auto-retrain knob
//!     (β scope stops at first-ingest + explicit reindex). INTEGER, not a Bool
//!     flag — there are no Bool stored columns in this schema. Stored
//!     identically on every part row for the same provider key.
//!
//! ## Write path
//!
//! `upsert` deletes all existing part rows for the provider key, then inserts
//! fresh part rows for each chunk — all within one serializable transaction.
//! This delete-then-insert pattern ensures:
//!   (a) No orphaned part rows from a prior basis persist on retrain.
//!   (b) The new basis becomes visible atomically (no torn read).
//!
//! ## Read path
//!
//! `load` queries all rows for (model_id, model_version) ordered by
//! part_index ascending and concatenates the `basis` columns. Metadata
//! (trained_at, trained_chunk_count) is read from the first part row.
//!
//! ## Schema history
//!
//!   v2: single-blob row; PRIMARY KEY (model_id, model_version). Added
//!       nullable ext JSON column for forward-compat.
//!   v3: adds part_index; PRIMARY KEY becomes (model_id, model_version,
//!       part_index). Removes the 1 GB single-bind ceiling (ee#49).
//!       NO DATA EXISTS TO MIGRATE — the v2→v3 migration is present for
//!       schema protocol correctness only and will never run on a real estate.
//!
//! Layering: this store lives in core `corpus-kit` and depends only on
//! persistence-kit, exactly like `BundleStore`. It never depends on
//! `corpus-kit-providers` — the blob bytes are opaque here; only the
//! trainable provider (reached through the `TrainableEmbeddingBasis` seam)
//! interprets them.

use crate::error::{CorpusKitError, CorpusKitResult};
use persistence_kit::{
    Column, ColumnDeclaration, IsolationLevel, Migration, OrderClause, RowStore,
    SchemaDeclaration, SchemaOperation, StorageError, StoragePredicate, StorageRow,
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

/// Maximum bytes per storage part. 256 MB keeps each SQLite bind well
/// below the 1 GB SQLITE_LIMIT_LENGTH ceiling even after WAL overhead.
/// Overridden via `with_chunk_limit` for test seaming (pass a small value
/// to exercise the multi-part path without allocating a real 256 MB blob).
pub const CHUNK_SIZE_LIMIT: usize = 256 * 1024 * 1024;

/// A persisted trained-basis row: the serialized blob plus the metadata that
/// keys and dates it. Rust mirror of Swift's `PersistedBasis`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedBasis {
    /// The provider model_id the basis was trained for.
    pub model_id: String,
    /// The provider model_version the basis was trained for.
    pub model_version: String,
    /// The 6a-i serialized basis blob (all parts reassembled into one Vec).
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
/// Blobs are split into parts of at most `chunk_byte_limit` bytes to avoid
/// SQLite's `SQLITE_LIMIT_LENGTH` ceiling (~1 GB per bound value). Each part
/// is one row; `load` reassembles them in `part_index` order.
///
/// One logical basis per (model_id, model_version). `upsert` writes/replaces
/// all parts; `load` reads them back reassembled; `delete_all` wipes every
/// basis row as part of `Corpus::destroy_recall_index`. The store interprets
/// none of the bytes — only the trainable provider does, via the
/// `TrainableEmbeddingBasis` seam.
pub struct BasisStore {
    storage: Arc<dyn persistence_kit::Storage>,
    /// Per-instance chunk ceiling. Defaults to `CHUNK_SIZE_LIMIT`; tests pass
    /// a small value (e.g. 64 bytes) to exercise multi-part paths cheaply.
    chunk_byte_limit: usize,
}

impl BasisStore {
    /// Additive schema declaration for the basis-persistence table. Mirrors the
    /// Swift `BasisStore.schemaDeclaration`.
    ///
    /// v3 adds `part_index` as the third component of the primary key, lifting
    /// the single-blob 1 GB ceiling by chunking large bases into multiple rows
    /// (ee#49). Not append-only: a retrain replaces all parts in place.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitBasis",
            3,
            vec![TableDeclaration::new(
                "corpus_provider_basis",
                vec![
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("model_version"),
                    // 0-based chunk sequence number. All rows for the same
                    // (model_id, model_version) are loaded in this order and
                    // concatenated to reconstruct the full basis blob.
                    ColumnDeclaration::int("part_index")
                        .with_default(TypedValue::Int(0)),
                    // BLOB: one chunk of the raw little-endian 6a-i basis bytes.
                    ColumnDeclaration::blob("basis"),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    // Stored identically on every part row for the same provider key.
                    ColumnDeclaration::timestamp("trained_at"),
                    // INTEGER staleness anchor — NOT a Bool flag.
                    // Stored identically on every part row for the same provider key.
                    ColumnDeclaration::int("trained_chunk_count"),
                    // Nullable forward-compat JSON slot (introduced in v2). 1.0
                    // omits it on upsert and never reads it.
                    ColumnDeclaration::json("ext").nullable(),
                ],
                vec![
                    "model_id".to_string(),
                    "model_version".to_string(),
                    "part_index".to_string(),
                ],
                // appendOnly defaults to off: a retrain replaces all parts.
            )],
        )
        .with_migrations(vec![
            // v2 → v3: add the part_index column (default 0 preserves existing
            // single-blob rows as part 0 of a 1-part basis). The PK constraint
            // cannot be changed via ALTER TABLE in SQLite; since NO DATA EXISTS
            // TO MIGRATE this is acceptable — all real estates start at v3.
            Migration {
                from_version: 2,
                to_version: 3,
                operations: vec![SchemaOperation::AddColumn {
                    table: "corpus_provider_basis".to_string(),
                    column: ColumnDeclaration::int("part_index")
                        .with_default(TypedValue::Int(0)),
                }],
            },
        ])
    }

    /// Create a `BasisStore` backed by `storage`.
    ///
    /// Uses `CHUNK_SIZE_LIMIT` (256 MB) as the per-part ceiling. For tests,
    /// use [`with_chunk_limit`] to exercise the multi-part path cheaply.
    pub fn new(storage: Arc<dyn persistence_kit::Storage>) -> Self {
        BasisStore {
            storage,
            chunk_byte_limit: CHUNK_SIZE_LIMIT,
        }
    }

    /// Create a `BasisStore` with a custom per-part byte ceiling.
    ///
    /// Pass a small value (e.g. 64 bytes) in tests to exercise the multi-part
    /// path without allocating a real 256 MB blob.
    pub fn with_chunk_limit(storage: Arc<dyn persistence_kit::Storage>, chunk_byte_limit: usize) -> Self {
        assert!(chunk_byte_limit > 0, "chunk_byte_limit must be positive");
        BasisStore { storage, chunk_byte_limit }
    }

    /// Insert or replace the basis for a provider key.
    ///
    /// The blob is split into chunks of at most `chunk_byte_limit` bytes. All
    /// existing parts for (model_id, model_version) are deleted, then fresh
    /// parts are inserted — within a single serializable transaction so the
    /// basis becomes visible atomically.
    pub fn upsert(&self, row: &PersistedBasis) -> CorpusKitResult<()> {
        let limit = self.chunk_byte_limit;
        self.storage
            .transaction(IsolationLevel::Serializable, &mut |txn| {
                let rows = txn.row_store();
                write_parts_into(&rows, row, limit)
                    .map_err(|e| StorageError::BackendError {
                        underlying: format!("{e:?}"),
                    })
            })
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }

    /// Transaction-scoped variant: write through the CALLER's row store so
    /// the basis parts commit atomically with sibling writes (e.g. the
    /// corrective pass's basis+counts atomic commit). The caller is responsible
    /// for transaction scoping.
    pub fn upsert_into(
        &self,
        row: &PersistedBasis,
        row_store: &Arc<dyn RowStore>,
    ) -> CorpusKitResult<()> {
        write_parts_into(row_store, row, self.chunk_byte_limit)
    }

    /// Load the persisted basis for a provider key, or `None` if none is stored.
    ///
    /// Queries all part rows in part_index ascending order and concatenates
    /// their `basis` columns. Metadata (trained_at, trained_chunk_count) is
    /// taken from the first part row — all parts carry identical metadata.
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
        // Load all part rows ordered by part_index ascending so concatenation
        // yields the correct byte order.
        let order_by = [OrderClause::ascending(Column::new(
            "corpus_provider_basis",
            "part_index",
        ))];
        let rows = self
            .storage
            .row_store()
            .query("corpus_provider_basis", Some(&predicate), &order_by, None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let first = match rows.first() {
            Some(r) => r,
            None => return Ok(None),
        };

        // Read metadata from the first part row (all parts carry the same values).
        let stored_model_id = match first.get("model_id") {
            Some(TypedValue::Text(s)) => s.clone(),
            _ => return Ok(None),
        };
        let stored_model_version = match first.get("model_version") {
            Some(TypedValue::Text(s)) => s.clone(),
            _ => return Ok(None),
        };
        let trained_at_secs = match decode_trained_at_secs(first.get("trained_at")) {
            Some(s) => s,
            // A missing or malformed trained_at is a data-integrity failure.
            None => return Ok(None),
        };
        let trained_chunk_count = match first.get("trained_chunk_count") {
            Some(TypedValue::Int(i)) => *i as usize,
            _ => return Ok(None),
        };

        // Concatenate all part blobs in ascending part_index order.
        let mut assembled = Vec::new();
        for row in &rows {
            match row.get("basis") {
                Some(TypedValue::Blob(b)) => assembled.extend_from_slice(b),
                // A missing or malformed basis column on any part is a
                // data-integrity failure — the reassembled basis would be truncated.
                _ => return Ok(None),
            }
        }

        Ok(Some(PersistedBasis {
            model_id: stored_model_id,
            model_version: stored_model_version,
            basis: assembled,
            trained_at_secs,
            trained_chunk_count,
        }))
    }

    /// Delete every basis row. Used by `Corpus::destroy_recall_index` so a
    /// destroyed corpus leaves no orphaned trained basis behind. `IsTrue` is
    /// the always-match predicate (delete requires a predicate).
    pub fn delete_all(&self) -> CorpusKitResult<()> {
        self.storage
            .row_store()
            .delete("corpus_provider_basis", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────

/// Delete all existing part rows for a provider key, then insert fresh parts.
///
/// Extracted as a free function so both the transaction-wrapping `upsert`
/// and the caller-scoped `upsert_into` share the same logic.
fn write_parts_into(
    row_store: &Arc<dyn RowStore>,
    row: &PersistedBasis,
    chunk_byte_limit: usize,
) -> CorpusKitResult<()> {
    let key_pred = StoragePredicate::And(vec![
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_id"),
            TypedValue::Text(row.model_id.clone()),
        ),
        StoragePredicate::Eq(
            Column::new("corpus_provider_basis", "model_version"),
            TypedValue::Text(row.model_version.clone()),
        ),
    ]);

    // Delete all existing parts for this provider key before inserting the
    // new ones. This is the "upsert by replace" pattern: since the new basis
    // may have a different number of parts than the old one, a targeted
    // upsert on part_index would leave orphaned parts from the old basis.
    row_store
        .delete("corpus_provider_basis", &key_pred)
        .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

    // Split the basis blob into parts of at most chunk_byte_limit bytes.
    // An empty basis is stored as a single empty row (part_index 0) so that
    // `load` returns Some(PersistedBasis { basis: vec![], .. }) rather than None.
    let basis = &row.basis;
    if basis.is_empty() {
        // Single empty part row preserves the "any upsert → at least one row"
        // invariant that `load` relies on to distinguish "no basis" (zero rows)
        // from "empty basis" (one row with zero bytes).
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert("model_version".into(), TypedValue::Text(row.model_version.clone()));
        values.insert("part_index".into(), TypedValue::Int(0));
        values.insert("basis".into(), TypedValue::Blob(Vec::new()));
        values.insert("trained_at".into(), TypedValue::Timestamp(row.trained_at_secs));
        values.insert("trained_chunk_count".into(), TypedValue::Int(row.trained_chunk_count as i64));
        row_store
            .insert("corpus_provider_basis", values)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        return Ok(());
    }

    // Split the blob and insert one row per chunk.
    // Each part carries the full metadata so that a load from any contiguous
    // prefix is unambiguous (though a load always reads all parts).
    for (index, chunk) in basis.chunks(chunk_byte_limit).enumerate() {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert("model_version".into(), TypedValue::Text(row.model_version.clone()));
        values.insert("part_index".into(), TypedValue::Int(index as i64));
        values.insert("basis".into(), TypedValue::Blob(chunk.to_vec()));
        values.insert("trained_at".into(), TypedValue::Timestamp(row.trained_at_secs));
        values.insert("trained_chunk_count".into(), TypedValue::Int(row.trained_chunk_count as i64));
        row_store
            .insert("corpus_provider_basis", values)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
    }
    Ok(())
}

/// Decode a basis row's trained_at field to Unix seconds, tolerant of BOTH
/// the semantic `Timestamp(i64)` form a migrate-aware connection returns AND
/// the `Text` ISO8601 form a fresh connection returns on read.
///
/// A migrate-aware connection populates its column-type registry from the
/// schema and re-parses TIMESTAMP columns to `Timestamp(i64)`. A SECOND
/// connection that merely opens the existing file returns the raw `Text`
/// ISO8601 form. Tolerating both forms prevents silently dropping every
/// persisted basis on reopen — the same resilience discipline that
/// `bundle_store::decode_chunk` uses.
fn decode_trained_at_secs(value: Option<&TypedValue>) -> Option<i64> {
    match value {
        Some(TypedValue::Timestamp(secs)) => Some(*secs),
        Some(TypedValue::Text(s)) => parse_iso8601_utc(s),
        _ => None,
    }
}

/// Parse a kit-canonical ISO8601 UTC timestamp ("YYYY-MM-DDTHH:MM:SS[.fff]Z")
/// into seconds-since-epoch. Inline (no external date crate, C-1). Only the
/// UTC 'Z' form the SQLite backend writes is supported; any fractional part
/// is ignored (the kit stores whole-second precision). Returns `None` on a
/// malformed string.
pub(crate) fn parse_iso8601_utc(s: &str) -> Option<i64> {
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
