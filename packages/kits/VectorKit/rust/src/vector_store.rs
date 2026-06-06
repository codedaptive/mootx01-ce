//! VectorStore — persistence-kit-backed CRUD over the `vectors` table.
//!
//! Refactored 2026-05-19 (Rust mission 6) per
//! DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md section 4.6: replaced
//! direct rusqlite + FTS5 I/O with `persistence_kit::RowStore`. The
//! application picks the PersistenceKit backend (InMemory today,
//! SQLite + PostgreSQL in follow-on R-missions); the kit does not
//! see backend selection.
//!
//! Mirrors the Swift VectorStore actor: same public API surface
//! (`add_vector`, `get_vector`, `vectors_for_drawer`,
//! `find_nearest`, `find_by_keyword`, `delete_vector`); `find_nearest`
//! runs a linear Hamming scan over rows tagged with the matching
//! `model_id` (sqlite-vec / pgvector ANN is a follow-on);
//! `find_by_keyword` is a coarse substring LIKE on `drawer_id`
//! (full BM25 lives in CorpusKit).
//!
//! VECTORKIT_REPORT_001 (2026-06-06): added IntellectusLib self-report
//! telemetry to `add_vector`, `find_nearest`, and `find_by_keyword`.
//! Emit calls are at operation boundaries, after results are computed,
//! so mathematical behavior and return values are unchanged.
//! When monitoring is disabled (the default) the `report!` macro body
//! is never evaluated — off-path cost is one AtomicBool load + branch.
//! The start-time `Instant` capture is unconditional per operation;
//! this is the only overhead added on the normal (non-monitoring) path.

use crate::error::VectorKitError;
use engram_lib::{Engram, EngramLib};
use intellectus_lib::{StatSample, report};
use std::collections::BTreeMap;
use std::sync::Arc;
use persistence_kit::{
    Column, ColumnDeclaration, IndexDeclaration, OrderClause, OrderDirection, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use uuid::Uuid;

/// One row of the `vectors` table. Parallel to the Swift
/// `StoredVector`. `filed_at` is preserved as the timestamp the
/// caller supplied so the round-trip is exact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredVector {
    pub id: String,
    pub drawer_id: String,
    pub model_id: String,
    pub model_version: String,
    pub engram: Engram,
    /// Unix epoch seconds. Mirrors persistence-kit's
    /// `TypedValue::Timestamp(i64)`.
    pub filed_at: i64,
}

/// Result of a `VectorStore::find_nearest` call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorMatch {
    pub drawer_id: String,
    /// Hamming distance over the 256-bit engram. Range 0..=256.
    pub distance: i32,
    pub model_id: String,
}

impl Ord for VectorMatch {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.distance
            .cmp(&other.distance)
            .then(self.drawer_id.cmp(&other.drawer_id))
    }
}

impl PartialOrd for VectorMatch {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// persistence-kit-backed CRUD over the `vectors` table.
///
/// Emits `vectorkit.*` metrics via IntellectusLib when monitoring is
/// enabled. Off by default; off-path cost is one AtomicBool load.
pub struct VectorStore {
    storage: Arc<dyn Storage>,
}

impl VectorStore {
    /// Schema declaration consumed by `Storage::open`. Mirrors the
    /// Swift `VectorStore.schemaDeclaration` (kit id, table layout,
    /// indices, unique constraint on (drawer_id, model_id)).
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "VectorKit",
            1,
            vec![TableDeclaration::new(
                "vectors",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("drawer_id"),
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("model_version"),
                    ColumnDeclaration::blob("engram"),
                    ColumnDeclaration::timestamp("filed_at"),
                ],
                vec!["id".to_string()],
            )
            .with_unique_constraints(vec![vec![
                "drawer_id".to_string(),
                "model_id".to_string(),
            ]])],
        )
        .with_indices(vec![
            IndexDeclaration::new(
                "idx_vectors_drawer",
                "vectors",
                vec!["drawer_id".to_string()],
            ),
            IndexDeclaration::new(
                "idx_vectors_model_drawer",
                "vectors",
                vec!["model_id".to_string(), "drawer_id".to_string()],
            ),
        ])
    }

    /// Construct against an already-opened `Storage`. The caller is
    /// responsible for calling `storage.open(&schema_declaration())`
    /// before using the store.
    pub fn new(storage: Arc<dyn Storage>) -> Self {
        VectorStore { storage }
    }

    /// Convenience: open the storage's schema and return the store.
    pub fn open(storage: Arc<dyn Storage>) -> Result<Self, VectorKitError> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(VectorStore::new(storage))
    }

    /// Insert or update the vector for `(drawer_id, model_id)`. The
    /// row's `id` is generated on first insert and preserved across
    /// updates (persistence-kit's upsert on the unique constraint
    /// updates in place).
    ///
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` (wall time
    /// for the upsert) when monitoring is enabled. Emitted at the
    /// operation boundary, after the upsert completes; does not affect
    /// the stored value or any error returned.
    pub fn add_vector(
        &self,
        drawer_id: &str,
        engram: &Engram,
        model_id: &str,
        model_version: &str,
        filed_at_unix_secs: i64,
    ) -> Result<(), VectorKitError> {
        // Capture start instant before the I/O. One monotonic clock
        // read per call; the elapsed is computed inside report! only
        // when monitoring is enabled.
        let start = std::time::Instant::now();

        let mut values = BTreeMap::new();
        values.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        values.insert("drawer_id".to_string(), TypedValue::Text(drawer_id.to_string()));
        values.insert("model_id".to_string(), TypedValue::Text(model_id.to_string()));
        values.insert(
            "model_version".to_string(),
            TypedValue::Text(model_version.to_string()),
        );
        values.insert(
            "engram".to_string(),
            TypedValue::Blob(engram.wire_bytes().to_vec()),
        );
        values.insert("filed_at".to_string(), TypedValue::Timestamp(filed_at_unix_secs));

        let row_store = self.storage.row_store();
        row_store
            .upsert(
                "vectors",
                values,
                &["drawer_id".to_string(), "model_id".to_string()],
            )
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

        // Emit insert latency at the operation boundary.
        // The model_id tag identifies which embedding model indexed
        // this vector, so per-model insert cost is queryable.
        // Off-path: single AtomicBool load when monitoring is disabled.
        let model_id_owned = model_id.to_string();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric(
                "vectorkit.index.insert_latency_ms".to_string(),
                elapsed_ms,
                tags,
                ts,
            )
        });

        Ok(())
    }

    /// Fetch the engram stored under `(drawer_id, model_id)`, or
    /// `None` if no row exists.
    pub fn get_vector(
        &self,
        drawer_id: &str,
        model_id: &str,
    ) -> Result<Option<Engram>, VectorKitError> {
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "drawer_id"),
                TypedValue::Text(drawer_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
        ]);
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &[], Some(1), None)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => match row.get("engram") {
                Some(TypedValue::Blob(bytes)) => Some(decode_engram(bytes)).transpose(),
                _ => Ok(None),
            },
        }
    }

    /// Return every row for `drawer_id`, ordered by `filed_at` ASC.
    pub fn vectors_for_drawer(
        &self,
        drawer_id: &str,
    ) -> Result<Vec<StoredVector>, VectorKitError> {
        let predicate = StoragePredicate::Eq(
            Column::new("vectors", "drawer_id"),
            TypedValue::Text(drawer_id.to_string()),
        );
        let order = vec![OrderClause::new(
            Column::new("vectors", "filed_at"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &order, None, None)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let mut out = Vec::new();
        for row in rows {
            if let Some(sv) = decode_stored_vector(&row)? {
                out.push(sv);
            }
        }
        Ok(out)
    }

    /// Hamming-distance nearest-neighbour over rows under `model_id`.
    /// Returns up to `k` matches sorted by distance ascending. Linear
    /// scan today; ANN via `persistence_kit::VectorIndex` is a follow-on.
    ///
    /// Telemetry: emits `vectorkit.search.latency_ms` (wall time for
    /// the full scan + top-K) and `vectorkit.search.result_count`
    /// (number of matches returned) when monitoring is enabled.
    /// Both are emitted at the operation boundary, after the result is
    /// computed; the return value is unchanged.
    pub fn find_nearest(
        &self,
        probe: &Engram,
        model_id: &str,
        k: usize,
    ) -> Result<Vec<VectorMatch>, VectorKitError> {
        if k == 0 {
            return Ok(Vec::new());
        }

        // Capture start instant before the I/O and scan.
        let start = std::time::Instant::now();

        let predicate = StoragePredicate::Eq(
            Column::new("vectors", "model_id"),
            TypedValue::Text(model_id.to_string()),
        );
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &[], None, None)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;

        let mut drawer_ids: Vec<String> = Vec::new();
        let mut engrams: Vec<Engram> = Vec::new();
        for row in rows {
            let drawer_id = match row.get("drawer_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let bytes = match row.get("engram") {
                Some(TypedValue::Blob(b)) => b.clone(),
                _ => continue,
            };
            drawer_ids.push(drawer_id);
            engrams.push(decode_engram(&bytes)?);
        }
        if engrams.is_empty() {
            return Ok(Vec::new());
        }
        let raw = EngramLib::find_nearest(probe, &engrams, k);
        let out: Vec<VectorMatch> = raw
            .into_iter()
            .map(|m| VectorMatch {
                drawer_id: drawer_ids[m.index].clone(),
                distance: m.distance as i32,
                model_id: model_id.to_string(),
            })
            .collect();

        // Emit search metrics at the operation boundary.
        // latency_ms: full operation (row fetch + Hamming top-K).
        // result_count: final result set size (≤ k).
        let result_count = out.len();
        let model_id_owned = model_id.to_string();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric(
                "vectorkit.search.latency_ms".to_string(),
                elapsed_ms,
                tags.clone(),
                ts,
            )
        });
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "VectorKit".to_string());
            tags.insert("model_id".to_string(), model_id_owned.clone());
            StatSample::metric(
                "vectorkit.search.result_count".to_string(),
                result_count as f64,
                tags,
                ts,
            )
        });

        Ok(out)
    }

    /// Coarse keyword pre-filter: returns distinct drawer IDs whose
    /// `drawer_id` contains the query as a substring. Mirrors the
    /// Swift refactor — full BM25 is CorpusKit's responsibility per the
    /// kit graph.
    ///
    /// Telemetry: emits `vectorkit.search.keyword_result_count`
    /// (number of distinct drawer IDs returned) when monitoring is
    /// enabled. Emitted at the operation boundary, after deduplication.
    pub fn find_by_keyword(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<String>, VectorKitError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let pattern = format!("%{}%", query);
        let predicate = StoragePredicate::Like(Column::new("vectors", "drawer_id"), pattern);
        let order = vec![OrderClause::new(
            Column::new("vectors", "drawer_id"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query("vectors", Some(&predicate), &order, Some(limit), None)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        for row in rows {
            if let Some(TypedValue::Text(drawer_id)) = row.get("drawer_id") {
                if seen.insert(drawer_id.clone()) {
                    out.push(drawer_id.clone());
                }
            }
        }

        // Emit keyword search result count at the operation boundary.
        // Off-path: single AtomicBool load when monitoring is disabled.
        let count = out.len();
        report!({
            use std::time::{SystemTime, UNIX_EPOCH};
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let mut tags = std::collections::HashMap::new();
            tags.insert("kit".to_string(), "VectorKit".to_string());
            StatSample::metric(
                "vectorkit.search.keyword_result_count".to_string(),
                count as f64,
                tags,
                ts,
            )
        });

        Ok(out)
    }

    // Lifecycle (GLK_PROVISION_001)

    /// Destroy all vector rows in this store.
    ///
    /// Deletes every row from the `vectors` table. Called by
    /// `EstateCoordinator::destroy` as part of the coordinated estate teardown
    /// path (GLK_PROVISION_001). After this call the backing storage still exists
    /// (schema intact) but contains no vector data.
    ///
    /// The caller (GLK coordinator) is responsible for closing the estate through
    /// LocusKit before calling this method. This method does not close or remove
    /// the backing storage — that is the caller's responsibility.
    ///
    /// Mirrors Swift `VectorStore.destroyAllVectors()`.
    pub fn destroy_all_vectors(&self) -> Result<(), VectorKitError> {
        // StoragePredicate::IsTrue matches every row — used as an always-true
        // predicate to delete all rows without needing a column-specific condition.
        self.storage
            .row_store()
            .delete("vectors", &StoragePredicate::IsTrue)
            .map_err(|e| VectorKitError::StoreUnavailable(format!("destroy_all_vectors failed: {e}")))?;
        Ok(())
    }

    /// Remove the row for `(drawer_id, model_id)`. Idempotent.
    pub fn delete_vector(
        &self,
        drawer_id: &str,
        model_id: &str,
    ) -> Result<(), VectorKitError> {
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new("vectors", "drawer_id"),
                TypedValue::Text(drawer_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
        ]);
        self.storage
            .row_store()
            .delete("vectors", &predicate)
            .map_err(|e| VectorKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}

// ---- row decode helpers ----

fn decode_engram(bytes: &[u8]) -> Result<Engram, VectorKitError> {
    if bytes.len() != 32 {
        return Err(VectorKitError::StoreUnavailable(format!(
            "expected 32-byte engram BLOB, got {} bytes",
            bytes.len()
        )));
    }
    Engram::from_wire_bytes(bytes)
        .map_err(|e| VectorKitError::StoreUnavailable(format!("engram decode failed: {e}")))
}

fn decode_stored_vector(
    row: &persistence_kit::StorageRow,
) -> Result<Option<StoredVector>, VectorKitError> {
    let id = match row.get("id") {
        Some(TypedValue::Uuid(u)) => u.to_string(),
        _ => return Ok(None),
    };
    let drawer_id = match row.get("drawer_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return Ok(None),
    };
    let bytes = match row.get("engram") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return Ok(None),
    };
    let filed_at = match row.get("filed_at") {
        Some(TypedValue::Timestamp(t)) => *t,
        _ => return Ok(None),
    };
    let engram = decode_engram(&bytes)?;
    Ok(Some(StoredVector {
        id,
        drawer_id,
        model_id,
        model_version,
        engram,
        filed_at,
    }))
}
