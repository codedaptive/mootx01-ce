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
    Column, ColumnDeclaration, IndexDeclaration, OrderClause, OrderDirection, SchemaDeclaration,
    Storage, StoragePredicate, TableDeclaration, TypedValue,
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
    /// The standalone canonical-content schema — the STANDALONE profile
    /// only. Version 1: a NEW lane, not an evolution of the legacy
    /// `chunks` layout. Mirrors Swift `CorpusDocumentStore.schemaDeclaration`.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitDocuments",
            1,
            vec![
                TableDeclaration::new(
                    "corpus_documents",
                    vec![
                        ColumnDeclaration::text("content_id"),
                        ColumnDeclaration::int("revision"),
                        ColumnDeclaration::text("digest"),
                        ColumnDeclaration::text("text"),
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
        Ok(Some(CorpusContentRecord {
            id: id.to_string(),
            revision: *revision,
            digest: digest.clone(),
            text: text.clone(),
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
            result.insert(
                content_id.clone(),
                CorpusContentRecord {
                    id: content_id.clone(),
                    revision: *revision,
                    digest: digest.clone(),
                    text: text.clone(),
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

impl CorpusContentStore for CorpusDocumentStore {
    fn put(
        &self,
        text: &str,
        id: &str,
        now_millis: i64,
    ) -> Result<CorpusContentRecord, CorpusKitError> {
        let digest = content_digest(text);
        if let Some(existing) = self.record(id)? {
            // Idempotence anchor: identical text is a no-op.
            if existing.digest == digest {
                return Ok(existing);
            }
            let bumped = CorpusContentRecord {
                id: id.to_string(),
                revision: existing.revision + 1,
                digest: digest.clone(),
                text: text.to_string(),
            };
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("revision".into(), TypedValue::Int(bumped.revision));
            values.insert("digest".into(), TypedValue::Text(digest.clone()));
            values.insert("text".into(), TypedValue::Text(text.to_string()));
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
        };
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("content_id".into(), TypedValue::Text(id.to_string()));
        values.insert("revision".into(), TypedValue::Int(1));
        values.insert("digest".into(), TypedValue::Text(digest.clone()));
        values.insert("text".into(), TypedValue::Text(text.to_string()));
        values.insert("created_at".into(), TypedValue::Timestamp(now_millis));
        values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
        self.storage
            .row_store()
            .insert("corpus_documents", values)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        self.journal(CHANGE_KIND_UPSERT, id, 1, Some(&digest), now_millis)?;
        Ok(fresh)
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
