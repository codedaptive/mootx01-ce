//! Per-provider coverage checkpoints (GLK shared-content 1.1 corrective
//! pass). Rust twin of Swift `CorpusProviderCoverageStore.swift`.
//!
//! The content checkpoint (`corpus_index_state`) records that a Drawer's
//! structural derivations reflect a (revision, digest, index_version); it
//! says NOTHING about which embedding providers cover the Drawer under
//! which basis generation. This table is that missing dimension: one row
//! per (content, provider) recording the BASIS DIGEST the provider's
//! stored vectors were produced under.
//!
//! Contracts:
//!   - a coverage row is written AFTER the provider's vector rows for that
//!     content are durably upserted — a cursor/progress figure may LAG
//!     coverage, but coverage never overstates the vectors table;
//!   - coverage is the resume authority for provider backfill: the missing
//!     set is (indexed content) minus (covered under the CURRENT basis
//!     digest), so a crashed backfill continues exactly where the durable
//!     rows stopped, and a basis-digest mismatch re-covers precisely the
//!     stale (content, provider) pairs;
//!   - rows carry NO text and are rebuildable derived state.

use crate::content::CorpusContentId;
use crate::error::CorpusKitError;
use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

/// Durable store over `corpus_provider_coverage`.
pub struct CorpusProviderCoverageStore {
    storage: Arc<dyn Storage>,
}

impl CorpusProviderCoverageStore {
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitProviderCoverage",
            1,
            vec![TableDeclaration::new(
                "corpus_provider_coverage",
                vec![
                    ColumnDeclaration::text("content_id"),
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("basis_digest"),
                    ColumnDeclaration::timestamp("updated_at"),
                ],
                vec!["content_id".to_string(), "model_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusProviderCoverageStore { storage }
    }

    /// Upsert one batch of coverage rows. Idempotent; call AFTER the
    /// corresponding vector rows are durably written.
    pub fn mark_covered(
        &self,
        entries: &[(CorpusContentId, String, String)],
        now_millis: i64,
    ) -> Result<(), CorpusKitError> {
        let rows = self.storage.row_store();
        for (content_id, model_id, basis_digest) in entries {
            let mut values = BTreeMap::new();
            values.insert("content_id".into(), TypedValue::Text(content_id.clone()));
            values.insert("model_id".into(), TypedValue::Text(model_id.clone()));
            values.insert("basis_digest".into(), TypedValue::Text(basis_digest.clone()));
            values.insert("updated_at".into(), TypedValue::Timestamp(now_millis));
            rows.upsert(
                "corpus_provider_coverage",
                values,
                &["content_id".to_string(), "model_id".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        }
        Ok(())
    }

    /// Content IDs covered by `model_id` under EXACTLY `basis_digest`.
    /// Rows under a different digest are stale coverage and excluded, so
    /// the caller's missing-set arithmetic re-covers them.
    pub fn covered_content_ids(
        &self,
        model_id: &str,
        basis_digest: &str,
    ) -> Result<HashSet<CorpusContentId>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_coverage",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_provider_coverage", "model_id"),
                    TypedValue::Text(model_id.to_string()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut out = HashSet::with_capacity(rows.len());
        for row in rows {
            let (Some(TypedValue::Text(id)), Some(TypedValue::Text(digest))) =
                (row.get("content_id"), row.get("basis_digest"))
            else {
                continue;
            };
            if digest == basis_digest {
                out.insert(id.clone());
            }
        }
        Ok(out)
    }

    /// Count of content IDs covered by `model_id` under `basis_digest` —
    /// the verification-gate figure.
    pub fn covered_count(
        &self,
        model_id: &str,
        basis_digest: &str,
    ) -> Result<usize, CorpusKitError> {
        Ok(self.covered_content_ids(model_id, basis_digest)?.len())
    }

    /// This content's coverage rows (model_id → basis_digest).
    pub fn coverage_for(
        &self,
        content_id: &str,
    ) -> Result<HashMap<String, String>, CorpusKitError> {
        let rows = self
            .storage
            .row_store()
            .query(
                "corpus_provider_coverage",
                Some(&StoragePredicate::Eq(
                    Column::new("corpus_provider_coverage", "content_id"),
                    TypedValue::Text(content_id.to_string()),
                )),
                &[],
                None,
                None,
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut out = HashMap::new();
        for row in rows {
            let (Some(TypedValue::Text(model)), Some(TypedValue::Text(digest))) =
                (row.get("model_id"), row.get("basis_digest"))
            else {
                continue;
            };
            out.insert(model.clone(), digest.clone());
        }
        Ok(out)
    }

    /// Remove one content's coverage rows (the removal/expunge path).
    pub fn clear(&self, content_id: &str) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete(
                "corpus_provider_coverage",
                &StoragePredicate::Eq(
                    Column::new("corpus_provider_coverage", "content_id"),
                    TypedValue::Text(content_id.to_string()),
                ),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Remove every coverage row (recall-index destruction).
    pub fn clear_all(&self) -> Result<(), CorpusKitError> {
        self.storage
            .row_store()
            .delete("corpus_provider_coverage", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }
}
