//! `RemovedSourceStore` — the set of source ids (drawer ids) whose recall has
//! been REMOVED from a Corpus.
//!
//! `BundleStore.chunks` is append-only: `remove(source_id)` deletes the source's
//! vector rows and clears it from the in-memory BM25 index, but cannot delete the
//! chunk rows. A reindex (or a BM25 rebuild on open) reads `all_chunks()` and
//! would re-embed / re-index the removed source's chunks, resurrecting it in
//! recall — and the autonomic governor's auto-reindex makes that automatic. This
//! store records which sources are removed so every rebuild path EXCLUDES them.
//! Re-ingesting a source clears its row (reactivation).
//!
//! Schema (one row per removed source): `removed_sources(source_id TEXT PK,
//! removed_at TIMESTAMP)`. Presence marks removal; NO Bool column
//! (schema-invariants rule). Swift twin:
//! packages/kits/CorpusKit/Sources/CorpusKit/RemovedSourceStore.swift

use crate::error::{CorpusKitError, CorpusKitResult};
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

/// Storage for the set of removed (recall-suppressed) source ids.
///
/// `mark_removed` records a removal; `clear_removed` reactivates a source on
/// re-ingest; `removed_ids` reads the full set for the active-chunk filter;
/// `delete_all` wipes every row as part of `Corpus::destroy_recall_index`.
pub struct RemovedSourceStore {
    storage: Arc<dyn Storage>,
}

impl RemovedSourceStore {
    /// Additive schema declaration for the removed-sources table. Mirrors the
    /// Swift `RemovedSourceStore.schemaDeclaration` (its own kitID so it is
    /// created via `migrate` regardless of other schemas' version gates). Not
    /// append-only: a reactivation deletes the row.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitRemovedSources",
            1,
            vec![TableDeclaration::new(
                "removed_sources",
                vec![
                    ColumnDeclaration::text("source_id"),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    ColumnDeclaration::timestamp("removed_at"),
                ],
                vec!["source_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        RemovedSourceStore { storage }
    }

    /// Mark a source removed (recall-suppressed). Idempotent: UPSERT on the
    /// source_id primary key. `now_secs` is the caller's instant (audit-only
    /// metadata — presence is what the active-chunk filter reads).
    pub fn mark_removed(&self, source_id: &str, now_secs: i64) -> CorpusKitResult<()> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("source_id".into(), TypedValue::Text(source_id.to_string()));
        values.insert("removed_at".into(), TypedValue::Timestamp(now_secs));
        self.storage
            .row_store()
            .upsert("removed_sources", values, &["source_id".to_string()])
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Reactivate a source: delete its removed-row so subsequent rebuilds include
    /// it again. No-op when the source was not removed.
    pub fn clear_removed(&self, source_id: &str) -> CorpusKitResult<()> {
        let predicate = StoragePredicate::Eq(
            Column::new("removed_sources", "source_id"),
            TypedValue::Text(source_id.to_string()),
        );
        self.storage
            .row_store()
            .delete("removed_sources", &predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// The full set of removed source ids — the active-chunk filter reads this to
    /// exclude removed sources from reindex / BM25-rebuild / count.
    pub fn removed_ids(&self) -> CorpusKitResult<HashSet<String>> {
        let rows = self
            .storage
            .row_store()
            .query("removed_sources", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut ids = HashSet::new();
        for row in rows {
            if let Some(TypedValue::Text(source_id)) = row.get("source_id") {
                ids.insert(source_id.clone());
            }
        }
        Ok(ids)
    }

    /// Delete every removed-source row. Used by `Corpus::destroy_recall_index` so
    /// a destroyed corpus leaves no orphaned removal records behind.
    pub fn delete_all(&self) -> CorpusKitResult<()> {
        self.storage
            .row_store()
            .delete("removed_sources", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}
