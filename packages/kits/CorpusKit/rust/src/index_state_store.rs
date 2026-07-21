//! The revision/digest/cursor checkpoint lane (GLK shared-content 1.1, P1).
//! Rust twin of Swift `CorpusIndexStateStore.swift`.
//!
//! `corpus_index_state` records, per canonical content ID, which
//! (revision, digest, index_version) the derived indexes currently
//! reflect and the last applied source cursor. It carries NO text, is
//! rebuildable derived state, and is present in BOTH schema profiles.

use crate::content::CorpusContentId;
use crate::error::CorpusKitError;
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, StorageRow,
    TableDeclaration, TypedValue,
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
}

/// Durable store over `corpus_index_state`.
pub struct CorpusIndexStateStore {
    storage: Arc<dyn Storage>,
}

impl CorpusIndexStateStore {
    /// Additive checkpoint schema — separate kit ID like the other sidecar
    /// stores; included in both profiles by the schema profile module.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitIndexState",
            1,
            vec![TableDeclaration::new(
                "corpus_index_state",
                vec![
                    ColumnDeclaration::text("content_id"),
                    ColumnDeclaration::int("revision"),
                    ColumnDeclaration::text("digest"),
                    ColumnDeclaration::int("index_version"),
                    ColumnDeclaration::text("applied_cursor").nullable(),
                    ColumnDeclaration::timestamp("updated_at"),
                ],
                vec!["content_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusIndexStateStore { storage }
    }

    /// Upsert the checkpoint for one content ID. Idempotent.
    pub fn advance(&self, state: &CorpusIndexState) -> Result<(), CorpusKitError> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("content_id".into(), TypedValue::Text(state.content_id.clone()));
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
        values.insert("updated_at".into(), TypedValue::Timestamp(state.updated_at_millis));
        self.storage
            .row_store()
            .upsert("corpus_index_state", values, &["content_id".to_string()])
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

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

    /// Every checkpointed state, ascending by content ID — the
    /// reconciliation set migration verification compares against the
    /// canonical ID set.
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

    /// Clear one content ID's checkpoint (the remove path).
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

    /// Clear every checkpoint (index rebuild from scratch).
    pub fn clear_all(&self) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete(
                "corpus_index_state",
                &StoragePredicate::Like(Column::new("corpus_index_state", "content_id"), "%".into()),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    fn decode(content_id: &str, row: &StorageRow) -> Option<CorpusIndexState> {
        let (Some(TypedValue::Int(revision)), Some(TypedValue::Text(digest)), Some(TypedValue::Int(index_version))) =
            (row.get("revision"), row.get("digest"), row.get("index_version"))
        else {
            return None;
        };
        let applied_cursor = match row.get("applied_cursor") {
            Some(TypedValue::Text(c)) => Some(c.clone()),
            _ => None,
        };
        // Both Rust backends hand TIMESTAMP back as Timestamp(millis) —
        // the SQLite backend parses its ISO8601 TEXT on read (unlike the
        // Swift SQLite backend, which returns the TEXT primitive).
        let updated_at_millis = match row.get("updated_at") {
            Some(TypedValue::Timestamp(millis)) => *millis,
            _ => return None,
        };
        Some(CorpusIndexState {
            content_id: content_id.to_string(),
            revision: *revision,
            digest: digest.clone(),
            index_version: *index_version,
            applied_cursor,
            updated_at_millis,
        })
    }
}
