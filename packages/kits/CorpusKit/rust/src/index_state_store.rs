//! The revision/digest/cursor checkpoint lane (GLK shared-content 1.1, P1).
//! Rust twin of Swift `CorpusIndexStateStore.swift`.
//!
//! v2 (bitmap adoption): adds `operational_bitmap BITMAP NOT NULL DEFAULT 0`
//! and the `corpus_bitmap_generation` singleton table for the global
//! basis-generation counter. See `index_state_operational.rs` for the
//! full bit layout and registry.

use crate::content::CorpusContentId;
use crate::error::CorpusKitError;
use crate::index_state_operational::{
    clearing_coverage_and_generation, is_lexically_indexed, is_removed, soft_removed_bitmap,
    INDEX_GENERATION_MODULUS,
};
use persistence_kit::{
    Column, ColumnDeclaration, Migration, SchemaDeclaration, SchemaOperation, Storage,
    StoragePredicate, StorageRow, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;

/// One checkpoint row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusIndexState {
    pub content_id: CorpusContentId,
    /// The content revision the derived rows currently reflect.
    pub revision: i64,
    /// The content digest the derived rows currently reflect.
    pub digest: String,
    /// The engine/index layout version the rows were produced under.
    pub index_version: i64,
    /// The last applied source cursor for feed-driven writes; None for
    /// direct indexing.
    pub applied_cursor: Option<String>,
    /// Epoch milliseconds (caller-supplied instant, never the system clock).
    pub updated_at_millis: i64,
    /// Per-row state cache bitmap (see `index_state_operational.rs`).
    /// Default 0 — no lifecycle bits, no coverage, no generation.
    pub operational_bitmap: i64,
}

impl CorpusIndexState {
    /// True when this row represents soft-deleted content.
    pub fn is_removed(&self) -> bool {
        is_removed(self.operational_bitmap)
    }

    /// True when BM25 term frequencies and a checkpoint exist for this row.
    pub fn is_lexically_indexed(&self) -> bool {
        is_lexically_indexed(self.operational_bitmap)
    }
}

/// Durable store over `corpus_index_state` and the `corpus_bitmap_generation`
/// singleton (the global basis-generation counter for coverage invalidation).
pub struct CorpusIndexStateStore {
    storage: Arc<dyn Storage>,
}

impl CorpusIndexStateStore {
    /// Checkpoint schema — v2 adds `operational_bitmap` and the
    /// `corpus_bitmap_generation` singleton.
    ///
    /// Version history:
    ///   v1 — Initial layout (content_id, revision, digest, index_version,
    ///        applied_cursor, updated_at) + PK on content_id.
    ///   v2 — Bitmap adoption: adds `operational_bitmap BITMAP NOT NULL DEFAULT 0`
    ///        to corpus_index_state; creates corpus_bitmap_generation singleton.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitIndexState",
            2,
            vec![
                TableDeclaration::new(
                    "corpus_index_state",
                    vec![
                        ColumnDeclaration::text("content_id"),
                        ColumnDeclaration::int("revision"),
                        ColumnDeclaration::text("digest"),
                        ColumnDeclaration::int("index_version"),
                        ColumnDeclaration::text("applied_cursor").nullable(),
                        ColumnDeclaration::timestamp("updated_at"),
                        // Per-row state cache bitmap. Layout in index_state_operational.rs.
                        ColumnDeclaration::bitmap("operational_bitmap"),
                    ],
                    vec!["content_id".to_string()],
                ),
                // Singleton table for the global basis-generation counter (0–15).
                TableDeclaration::new(
                    "corpus_bitmap_generation",
                    vec![
                        ColumnDeclaration::int("singleton_id"),
                        ColumnDeclaration::int("basis_generation")
                            .with_default(TypedValue::Int(0)),
                    ],
                    vec!["singleton_id".to_string()],
                ),
            ],
        )
        .with_migrations(vec![Migration {
            from_version: 1,
            to_version: 2,
            operations: vec![
                SchemaOperation::AddColumn {
                    table: "corpus_index_state".to_string(),
                    column: ColumnDeclaration::bitmap("operational_bitmap"),
                },
                SchemaOperation::CreateTable(TableDeclaration::new(
                    "corpus_bitmap_generation",
                    vec![
                        ColumnDeclaration::int("singleton_id"),
                        ColumnDeclaration::int("basis_generation")
                            .with_default(TypedValue::Int(0)),
                    ],
                    vec!["singleton_id".to_string()],
                )),
            ],
        }])
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusIndexStateStore { storage }
    }

    /// Upsert the checkpoint for one content ID. Idempotent.
    /// The engine supplies the complete `operational_bitmap`; the store stores it verbatim.
    pub fn advance(&self, state: &CorpusIndexState) -> Result<(), CorpusKitError> {
        self.advance_into(state, &self.storage.row_store())
    }

    /// Transaction-scoped checkpoint write. Queue batches use this to commit
    /// their maintained-counts snapshot and every content/cursor checkpoint in
    /// one last-write transaction.
    pub fn advance_into(
        &self,
        state: &CorpusIndexState,
        row_store: &Arc<dyn persistence_kit::RowStore>,
    ) -> Result<(), CorpusKitError> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert(
            "content_id".into(),
            TypedValue::Text(state.content_id.clone()),
        );
        values.insert("revision".into(), TypedValue::Int(state.revision));
        values.insert("digest".into(), TypedValue::Text(state.digest.clone()));
        values.insert("index_version".into(), TypedValue::Int(state.index_version));
        values.insert(
            "applied_cursor".into(),
            match &state.applied_cursor {
                Some(c) => TypedValue::Text(c.clone()),
                None => TypedValue::Null,
            },
        );
        values.insert(
            "updated_at".into(),
            TypedValue::Timestamp(state.updated_at_millis),
        );
        values.insert(
            "operational_bitmap".into(),
            TypedValue::Bitmap(state.operational_bitmap),
        );
        row_store
            .upsert("corpus_index_state", values, &["content_id".to_string()])
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    // MARK: - Soft-remove path

    /// Soft-delete a content row: set `removed=1` and clear all other lifecycle
    /// and coverage bits. The row is retained as a tombstone. No-op when absent.
    pub fn soft_remove(
        &self,
        content_id: &str,
        updated_at_millis: i64,
    ) -> Result<(), CorpusKitError> {
        // Read current row to preserve applied_cursor.
        let existing = self.state(content_id)?;
        let Some(existing) = existing else { return Ok(()) };
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("content_id".into(), TypedValue::Text(content_id.to_string()));
        // Reset revision/digest so the idempotence gate fires on re-ingest.
        values.insert("revision".into(), TypedValue::Int(0));
        values.insert("digest".into(), TypedValue::Text(String::new()));
        values.insert("index_version".into(), TypedValue::Int(0));
        values.insert(
            "applied_cursor".into(),
            match &existing.applied_cursor {
                Some(c) => TypedValue::Text(c.clone()),
                None => TypedValue::Null,
            },
        );
        values.insert("updated_at".into(), TypedValue::Timestamp(updated_at_millis));
        // removed=1; all other bits cleared.
        values.insert(
            "operational_bitmap".into(),
            TypedValue::Bitmap(soft_removed_bitmap()),
        );
        self.storage
            .row_store()
            .upsert("corpus_index_state", values, &["content_id".to_string()])
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    // MARK: - Bitmap update

    /// Update only the `operational_bitmap` for an existing row.
    /// No-op when the row does not exist.
    pub fn update_bitmap(&self, content_id: &str, bitmap: i64) -> Result<(), CorpusKitError> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert(
            "operational_bitmap".into(),
            TypedValue::Bitmap(bitmap),
        );
        self.storage
            .row_store()
            .update(
                "corpus_index_state",
                values,
                &StoragePredicate::Eq(
                    Column::new("corpus_index_state", "content_id"),
                    TypedValue::Text(content_id.to_string()),
                ),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    // MARK: - Queries

    /// The checkpoint for one content ID, or None when never indexed.
    pub fn state(&self, content_id: &str) -> Result<Option<CorpusIndexState>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_index_state",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_index_state", "content_id"),
                    TypedValue::Text(content_id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.first().and_then(|row| Self::decode(content_id, row)))
    }

    /// Every checkpointed state, ascending by content ID.
    pub fn all_states(&self) -> Result<Vec<CorpusIndexState>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query("corpus_index_state", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut out: Vec<CorpusIndexState> = rows
            .iter()
            .filter_map(|row| {
                let content_id = match row.get("content_id") {
                    Some(TypedValue::Text(id)) => id.clone(),
                    _ => return None,
                };
                Self::decode(&content_id, row)
            })
            .collect();
        out.sort_by(|a, b| a.content_id.cmp(&b.content_id));
        Ok(out)
    }

    /// Every state row where `is_lexically_indexed() == true` and
    /// `is_removed() == false`. This is the active-content set.
    pub fn active_indexed_states(&self) -> Result<Vec<CorpusIndexState>, CorpusKitError> {
        Ok(self
            .all_states()?
            .into_iter()
            .filter(|s| s.is_lexically_indexed() && !s.is_removed())
            .collect())
    }

    // MARK: - Deletions (hard expunge only)

    /// Hard-delete one content ID's checkpoint (expunge path).
    /// The normal remove path is `soft_remove`.
    pub fn clear(&self, content_id: &str) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete(
                "corpus_index_state",
                &StoragePredicate::Eq(
                    Column::new("corpus_index_state", "content_id"),
                    TypedValue::Text(content_id.to_string()),
                ),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Hard-delete every checkpoint (index rebuild from scratch).
    pub fn clear_all(&self) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete("corpus_index_state", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    // MARK: - Global basis-generation counter

    /// Read the current global basis-generation value (0–15).
    /// Returns 0 when the singleton row does not exist yet.
    pub fn basis_generation(&self) -> Result<i64, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_bitmap_generation",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_bitmap_generation", "singleton_id"),
                    TypedValue::Int(1),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        match rows.first().and_then(|r| r.get("basis_generation")) {
            Some(TypedValue::Int(gen)) => Ok(*gen),
            _ => Ok(0),
        }
    }

    /// Increment the global basis-generation counter, wrapping at 16.
    /// Returns the NEW generation value.
    pub fn increment_basis_generation(&self) -> Result<i64, CorpusKitError> {
        let current = self.basis_generation()?;
        let next = (current + 1) % INDEX_GENERATION_MODULUS;
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("singleton_id".into(), TypedValue::Int(1));
        values.insert("basis_generation".into(), TypedValue::Int(next));
        self.storage
            .row_store()
            .upsert(
                "corpus_bitmap_generation",
                values,
                &["singleton_id".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(next)
    }

    /// Reset the global basis-generation counter to 0 and clear all coverage
    /// bits and generation stamps from every content row (the wraparound sweep).
    pub fn reset_generation_sweep(&self) -> Result<(), CorpusKitError> {
        // Reset the singleton counter to 0.
        let mut gen_values: BTreeMap<String, TypedValue> = BTreeMap::new();
        gen_values.insert("singleton_id".into(), TypedValue::Int(1));
        gen_values.insert("basis_generation".into(), TypedValue::Int(0));
        self.storage
            .row_store()
            .upsert(
                "corpus_bitmap_generation",
                gen_values,
                &["singleton_id".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // Clear coverage_mask (bits 4–11) and basis_generation (bits 12–15) from
        // every content row. O(n) scan; rare in practice.
        let all = self.all_states()?;
        for state in &all {
            let cleared = clearing_coverage_and_generation(state.operational_bitmap);
            if cleared != state.operational_bitmap {
                self.update_bitmap(&state.content_id, cleared)?;
            }
        }
        Ok(())
    }

    // MARK: - Decoding

    fn decode(content_id: &str, row: &StorageRow) -> Option<CorpusIndexState> {
        let (
            Some(TypedValue::Int(revision)),
            Some(TypedValue::Text(digest)),
            Some(TypedValue::Int(index_version)),
        ) = (
            row.get("revision"),
            row.get("digest"),
            row.get("index_version"),
        )
        else {
            return None;
        };
        let applied_cursor = match row.get("applied_cursor") {
            Some(TypedValue::Text(c)) => Some(c.clone()),
            _ => None,
        };
        // Both Rust backends return TIMESTAMP as Timestamp(millis).
        let updated_at_millis = match row.get("updated_at") {
            Some(TypedValue::Timestamp(millis)) => *millis,
            _ => return None,
        };
        // Decode operational_bitmap; tolerate Int (InMemory DEFAULT path) and
        // Bitmap (SQLite) variants — both carry an i64 payload.
        let operational_bitmap = match row.get("operational_bitmap") {
            Some(TypedValue::Bitmap(bm)) => *bm,
            Some(TypedValue::Int(bm)) => *bm,
            _ => 0,
        };
        Some(CorpusIndexState {
            content_id: content_id.to_string(),
            revision: *revision,
            digest: digest.clone(),
            index_version: *index_version,
            applied_cursor,
            updated_at_millis,
            operational_bitmap,
        })
    }
}
