//! The standalone canonical document store (GLK shared-content 1.1, P1).
//! Rust twin of Swift `CorpusDocumentStore.swift`.
//!
//! In standalone mode CorpusKit is a complete RAG database that OWNS its
//! canonical documents: `corpus_documents` (the ONLY place standalone
//! CorpusKit persists verbatim text) plus the `corpus_content_changes`
//! journal backing the cursor contract (identity/revision/digest rows,
//! never text). Neither table exists in attached mode.

use crate::content::{
    content_digest, CorpusContentChange, CorpusContentChangeBatch, CorpusContentId,
    CorpusContentRecord, CorpusContentSource, CorpusContentStore,
};
use crate::error::CorpusKitError;
use persistence_kit::{
    Column, ColumnDeclaration, IndexDeclaration, Migration, OrderClause, OrderDirection,
    SchemaDeclaration, SchemaOperation, Storage, StoragePredicate, TableDeclaration, TypedValue,
};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

const CHANGE_KIND_UPSERT: i64 = 0;
const CHANGE_KIND_REMOVE: i64 = 1;

/// Standalone canonical content authority over `corpus_documents`.
pub struct CorpusDocumentStore {
    storage: Arc<dyn Storage>,
    /// Next journal sequence; loaded lazily from MAX(seq)+1 on first write
    /// so a reopened store continues the feed without gaps or reuse.
    next_seq: Mutex<Option<i64>>,
}

impl CorpusDocumentStore {
    /// The standalone canonical-content schema — the STANDALONE profile only.
    /// Mirrors Swift `CorpusDocumentStore.schemaDeclaration`.
    ///
    /// Version history:
    ///   v1 — Initial layout: (content_id, revision, digest, text,
    ///        created_at, updated_at) + corpus_content_changes journal.
    ///   v2 — Dual-text indexing (MISSION_11X_RECALL_GAP_01 Stream A):
    ///        adds `dense_text TEXT NULL` to corpus_documents. NULL means
    ///        "use the lexical `text` column for dense embedding too" —
    ///        the default for all standalone consumers that do not supply a
    ///        separate dense-composition representation. The migration is
    ///        purely additive; existing rows behave identically (NULL dense
    ///        text falls back to the lexical text everywhere).
    ///
    /// NOTE: the SQLite backend creates every table at the latest schema on
    /// open (CREATE TABLE IF NOT EXISTS) and does not replay Migration.operations
    /// for fresh DBs — the InMemory backend replays them (idempotently).
    /// Migration entries mirror the Swift declaration for cross-port parity.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitDocuments",
            2,
            vec![
                TableDeclaration::new(
                    "corpus_documents",
                    vec![
                        ColumnDeclaration::text("content_id"),
                        ColumnDeclaration::int("revision"),
                        ColumnDeclaration::text("digest"),
                        ColumnDeclaration::text("text"),
                        // Dense-composition text for the float vector lane. NULL
                        // means fall back to `text` for both BM25 and dense
                        // embedding. Non-NULL lets a caller supply a distinct
                        // representation while keeping the original text for
                        // BM25 and as the returned ranked payload.
                        ColumnDeclaration::text("dense_text").nullable(),
                        ColumnDeclaration::timestamp("created_at"),
                        ColumnDeclaration::timestamp("updated_at"),
                    ],
                    vec!["content_id".to_string()],
                ),
                TableDeclaration::new(
                    "corpus_content_changes",
                    vec![
                        ColumnDeclaration::int("seq"),
                        ColumnDeclaration::text("content_id"),
                        ColumnDeclaration::int("revision"),
                        // Digest of the upserted revision; NULL for removes.
                        ColumnDeclaration::text("digest").nullable(),
                        ColumnDeclaration::int("kind"),
                        ColumnDeclaration::timestamp("changed_at"),
                    ],
                    vec!["seq".to_string()],
                ),
            ],
        )
        .with_indices(vec![IndexDeclaration::new(
            "idx_corpus_content_changes_content",
            "corpus_content_changes",
            vec!["content_id".to_string()],
        )])
        .with_migrations(vec![
            // v1 → v2: add dense_text column (additive; NULL = use lexical text).
            // Existing rows see NULL for dense_text, which falls back to the
            // lexical `text` column in effective_dense_text() — zero behavior change
            // for all pre-dual-text content.
            Migration {
                from_version: 1,
                to_version: 2,
                operations: vec![SchemaOperation::AddColumn {
                    table: "corpus_documents".to_string(),
                    column: ColumnDeclaration::text("dense_text").nullable(),
                }],
            },
        ])
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusDocumentStore {
            storage,
            next_seq: Mutex::new(None),
        }
    }

    fn journal(
        &self,
        kind: i64,
        id: &str,
        revision: i64,
        digest: Option<&str>,
        now_millis: i64,
    ) -> Result<(), CorpusKitError> {
        let mut guard = self
            .next_seq
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("document store mutex poisoned".into()))?;
        let seq = match *guard {
            Some(next) => next,
            None => {
                let rows = self
                    .storage
                    .row_store()
                    .query(
                        "corpus_content_changes",
                        None,
                        &[OrderClause {
                            column: Column::new("corpus_content_changes", "seq"),
                            direction: OrderDirection::Descending,
                        }],
                        Some(1),
                        None,
                    )
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
                match rows.first().and_then(|r| r.get("seq")) {
                    Some(TypedValue::Int(max_seq)) => max_seq + 1,
                    _ => 1,
                }
            }
        };
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("seq".into(), TypedValue::Int(seq));
        values.insert("content_id".into(), TypedValue::Text(id.to_string()));
        values.insert("revision".into(), TypedValue::Int(revision));
        values.insert(
            "digest".into(),
            match digest {
                Some(d) => TypedValue::Text(d.to_string()),
                None => TypedValue::Null,
            },
        );
        values.insert("kind".into(), TypedValue::Int(kind));
        values.insert("changed_at".into(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .insert("corpus_content_changes", values)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        *guard = Some(seq + 1);
        Ok(())
    }
}

impl CorpusContentSource for CorpusDocumentStore {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_documents",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_documents", "content_id"),
                    TypedValue::Text(id.to_string()),
                )),
                &[],
                Some(1),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        let (Some(TypedValue::Int(revision)), Some(TypedValue::Text(digest)), Some(TypedValue::Text(text))) =
            (row.get("revision"), row.get("digest"), row.get("text"))
        else {
            return Ok(None);
        };
        // dense_text is NULL when not set (existing rows and all puts that did not
        // supply a dense-composition text). None → effective_dense_text() falls back
        // to text, preserving identical behavior for existing callers.
        let dense_composition_text = match row.get("dense_text") {
            Some(TypedValue::Text(dt)) => Some(dt.clone()),
            _ => None,
        };
        Ok(Some(CorpusContentRecord {
            id: id.to_string(),
            revision: *revision,
            digest: digest.clone(),
            text: text.clone(),
            dense_composition_text,
        }))
    }

    /// Optimized batch fetch using a single WHERE…IN query. Overrides the
    /// trait default (N serial reads) for the standalone store path.
    fn records_for(
        &self,
        ids: &[&str],
    ) -> Result<HashMap<String, CorpusContentRecord>, CorpusKitError> {
        if ids.is_empty() {
            return Ok(HashMap::new());
        }
        let values: Vec<TypedValue> = ids
            .iter()
            .map(|id| TypedValue::Text(id.to_string()))
            .collect();
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_documents",
                Some(&StoragePredicate::In(
                    Column::new("corpus_documents", "content_id"),
                    values,
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut result = HashMap::new();
        for row in &rows {
            let (
                Some(TypedValue::Text(content_id)),
                Some(TypedValue::Int(revision)),
                Some(TypedValue::Text(digest)),
                Some(TypedValue::Text(text)),
            ) = (
                row.get("content_id"),
                row.get("revision"),
                row.get("digest"),
                row.get("text"),
            )
            else {
                continue;
            };
            let dense_composition_text = match row.get("dense_text") {
                Some(TypedValue::Text(dt)) => Some(dt.clone()),
                _ => None,
            };
            result.insert(
                content_id.clone(),
                CorpusContentRecord {
                    id: content_id.clone(),
                    revision: *revision,
                    digest: digest.clone(),
                    text: text.clone(),
                    dense_composition_text,
                },
            );
        }
        Ok(result)
    }

    fn changes(
        &self,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        if limit == 0 {
            return Ok(CorpusContentChangeBatch::empty());
        }
        let after: i64 = match cursor {
            Some(c) => c.parse().map_err(|_| {
                CorpusKitError::DecodingFailure(format!(
                    "corpus content cursor is not a journal sequence: {c}"
                ))
            })?,
            None => 0,
        };
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_content_changes",
                Some(&StoragePredicate::Gt(
                    Column::new("corpus_content_changes", "seq"),
                    TypedValue::Int(after),
                )),
                &[OrderClause {
                    column: Column::new("corpus_content_changes", "seq"),
                    direction: OrderDirection::Ascending,
                }],
                Some(limit),
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut changes = Vec::with_capacity(rows.len());
        let mut last_seq = after;
        for row in &rows {
            let (Some(TypedValue::Int(seq)), Some(TypedValue::Text(content_id)), Some(TypedValue::Int(revision)), Some(TypedValue::Int(kind))) =
                (row.get("seq"), row.get("content_id"), row.get("revision"), row.get("kind"))
            else {
                continue;
            };
            last_seq = *seq;
            match *kind {
                CHANGE_KIND_UPSERT => {
                    let Some(TypedValue::Text(digest)) = row.get("digest") else {
                        continue;
                    };
                    changes.push(CorpusContentChange::Upsert {
                        id: content_id.clone(),
                        revision: *revision,
                        digest: digest.clone(),
                    });
                }
                CHANGE_KIND_REMOVE => {
                    changes.push(CorpusContentChange::Remove {
                        id: content_id.clone(),
                        revision: *revision,
                    });
                }
                _ => continue,
            }
        }
        let next_cursor = if changes.is_empty() {
            None
        } else {
            Some(last_seq.to_string())
        };
        Ok(CorpusContentChangeBatch {
            changes,
            next_cursor,
        })
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query("corpus_documents", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut out: Vec<String> = rows
            .iter()
            .filter_map(|row| match row.get("content_id") {
                Some(TypedValue::Text(id)) => Some(id.clone()),
                _ => None,
            })
            .collect();
        out.sort();
        Ok(out)
    }
}

impl CorpusDocumentStore {
    /// Insert or update canonical content with an optional dense-composition
    /// text for the float vector lane. The `dense_composition_text` is stored
    /// in `corpus_documents.dense_text` (NULL when None) and returned in every
    /// subsequent `record()` call so the engine can recompose the dense vector
    /// on any retrain or reindex without external input.
    ///
    /// Idempotence: if BOTH `text` AND `dense_composition_text` are unchanged
    /// from the persisted row, the call is a no-op (same record, no revision
    /// bump, no journal entry). A change to either bumps the revision.
    pub fn put_with_dense_text(
        &self,
        text: &str,
        dense_composition_text: Option<&str>,
        id: &str,
        now_millis: i64,
    ) -> Result<CorpusContentRecord, CorpusKitError> {
        let digest = content_digest(text);
        if let Some(existing) = self.record(id)? {
            // Idempotence anchor: both lexical text (same digest) AND dense text
            // must match for a no-op. A changed dense text without a changed lexical
            // text still bumps the revision — the dense vector must be recomposed
            // and the coverage row invalidated.
            if existing.digest == digest
                && existing.dense_composition_text.as_deref() == dense_composition_text
            {
                return Ok(existing);
            }
            let bumped = CorpusContentRecord {
                id: id.to_string(),
                revision: existing.revision + 1,
                digest: digest.clone(),
                text: text.to_string(),
                dense_composition_text: dense_composition_text.map(|s| s.to_string()),
            };
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("revision".into(), TypedValue::Int(bumped.revision));
            values.insert("digest".into(), TypedValue::Text(digest.clone()));
            values.insert("text".into(), TypedValue::Text(text.to_string()));
            values.insert(
                "dense_text".into(),
                match dense_composition_text {
                    Some(d) => TypedValue::Text(d.to_string()),
                    None => TypedValue::Null,
                },
            );
            values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
            self.storage
                .row_store()
                .update(
                    "corpus_documents",
                    values,
                    &StoragePredicate::Eq(
                        Column::new("corpus_documents", "content_id"),
                        TypedValue::Text(id.to_string()),
                    ),
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            self.journal(CHANGE_KIND_UPSERT, id, bumped.revision, Some(&digest), now_millis)?;
            return Ok(bumped);
        }
        let fresh = CorpusContentRecord {
            id: id.to_string(),
            revision: 1,
            digest: digest.clone(),
            text: text.to_string(),
            dense_composition_text: dense_composition_text.map(|s| s.to_string()),
        };
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("content_id".into(), TypedValue::Text(id.to_string()));
        values.insert("revision".into(), TypedValue::Int(1));
        values.insert("digest".into(), TypedValue::Text(digest.clone()));
        values.insert("text".into(), TypedValue::Text(text.to_string()));
        values.insert(
            "dense_text".into(),
            match dense_composition_text {
                Some(d) => TypedValue::Text(d.to_string()),
                None => TypedValue::Null,
            },
        );
        values.insert("created_at".into(), TypedValue::Timestamp(now_millis));
        values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .insert("corpus_documents", values)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.journal(CHANGE_KIND_UPSERT, id, 1, Some(&digest), now_millis)?;
        Ok(fresh)
    }
}

impl CorpusContentStore for CorpusDocumentStore {
    fn put(
        &self,
        text: &str,
        id: &str,
        now_millis: i64,
    ) -> Result<CorpusContentRecord, CorpusKitError> {
        // Delegate to put_with_dense_text with None — no dense-composition text.
        // Existing callers see zero behavior change: dense_text is NULL, and
        // effective_dense_text() falls back to text for both BM25 and embedding.
        self.put_with_dense_text(text, None, id, now_millis)
    }

    fn remove(&self, id: &str, now_millis: i64) -> Result<(), CorpusKitError> {
        let Some(existing) = self.record(id)? else {
            return Ok(());
        };
        self.storage
            .row_store()
            .delete(
                "corpus_documents",
                &StoragePredicate::Eq(
                    Column::new("corpus_documents", "content_id"),
                    TypedValue::Text(id.to_string()),
                ),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.journal(CHANGE_KIND_REMOVE, id, existing.revision, None, now_millis)?;
        Ok(())
    }
}
