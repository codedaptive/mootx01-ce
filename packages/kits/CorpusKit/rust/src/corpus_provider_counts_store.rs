//! CorpusProviderCountsStore: persistence-kit-backed `corpus_provider_counts`
//! table. Rust mirror of Swift's `CorpusProviderCountsStore`.
//!
//! Persists a trainable provider's INCREMENTALLY-MAINTAINED statistics
//! ("counts") — the raw accumulated state a distributional provider
//! (RI/PPMI/LSA/NMF) builds from the corpus (vocabulary, document-frequencies,
//! co-occurrence counts, RI context vectors) — as an opaque per-provider blob
//! plus two cheap, queryable trigger columns. See the Swift file and
//! the maintainer CorpusKit incremental-counts changeset for the
//! rationale: the counts are additive, so they can be MAINTAINED on write
//! instead of rebuilt from scratch (re-read + re-tokenize) on every reindex.
//!
//! Schema (one row per (model_id, model_version)):
//!   corpus_provider_counts (
//!     model_id      TEXT NOT NULL,
//!     model_version TEXT NOT NULL,
//!     counts        BLOB NOT NULL,    -- opaque per-provider serialized counts
//!     doc_count     INTEGER NOT NULL, -- documents (chunks) folded in
//!     vocab_size    INTEGER NOT NULL, -- distinct vocabulary terms
//!     updated_at    TIMESTAMP NOT NULL, -- TEXT ISO8601 at SQLite layer; never REAL
//!     ext           JSON              -- forward-compat slot (ADR-012); nullable
//!   )  PRIMARY KEY (model_id, model_version)
//!
//! `doc_count`/`vocab_size` are surfaced as their own columns (not just inside
//! the blob) so the vocab-growth retrain trigger reads them with one cheap query
//! without deserializing the counts blob. NOT append-only: an incremental update
//! UPSERTs the row in place. Layering: core `corpus-kit`, depends only on
//! persistence-kit; never depends on `corpus-kit-providers` (counts bytes opaque).

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
// This store persists and returns opaque counts bytes produced by the
// provider's own serializer. It computes nothing.
// ─────────────────────────────────────────────────────────────────

/// A persisted provider-counts row: the opaque accumulated-statistics blob plus
/// the metadata that keys it and the two cheap trigger anchors. Rust mirror of
/// Swift's `PersistedCounts`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedCounts {
    /// The provider model_id the counts were accumulated for.
    pub model_id: String,
    /// The provider model_version the counts were accumulated for.
    pub model_version: String,
    /// The provider-serialized accumulated counts (opaque to this store).
    pub counts: Vec<u8>,
    /// Documents (chunks) folded into the counts — growth-trigger anchor.
    pub document_count: usize,
    /// Distinct vocabulary terms — growth-trigger anchor.
    pub vocab_size: usize,
    /// When the counts were last persisted, in Unix seconds (the caller's
    /// `now`). Stored as TEXT ISO8601 at the SQLite layer per the schema
    /// invariant; the TypedValue carries the i64 seconds form.
    pub updated_at_secs: i64,
}

/// The growth anchors for a provider key — read without deserializing the blob.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CountsGrowthAnchor {
    pub document_count: usize,
    pub vocab_size: usize,
}

/// Storage for a trainable embedding provider's maintained counts.
///
/// One row per (model_id, model_version). `upsert` writes/replaces it; `load`
/// reads the full row; `growth_anchor` reads only the cheap doc/vocab counts for
/// the retrain trigger; `delete_all` wipes every row. The store interprets none
/// of the bytes.
pub struct CorpusProviderCountsStore {
    storage: Arc<dyn Storage>,
}

impl CorpusProviderCountsStore {
    /// Additive schema declaration for the maintained-counts table. Mirrors the
    /// Swift `CorpusProviderCountsStore.schemaDeclaration`. Not append-only: an
    /// incremental update UPSERTs the (model_id, model_version) row.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKitCounts",
            1,
            vec![TableDeclaration::new(
                "corpus_provider_counts",
                vec![
                    ColumnDeclaration::text("model_id"),
                    ColumnDeclaration::text("model_version"),
                    // BLOB: the provider-serialized raw counts bytes.
                    ColumnDeclaration::blob("counts"),
                    // INTEGER growth anchors — NOT Bool flags.
                    ColumnDeclaration::int("doc_count"),
                    ColumnDeclaration::int("vocab_size"),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    ColumnDeclaration::timestamp("updated_at"),
                    // ADR-012 forward-compat slot; nullable JSON; omitted on upsert in 1.0.
                    ColumnDeclaration::json("ext").nullable(),
                ],
                vec!["model_id".to_string(), "model_version".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        CorpusProviderCountsStore { storage }
    }

    /// Insert or replace the counts row for a provider key. Keyed by the
    /// composite primary key: an incremental update replaces the prior counts in
    /// place. `updated_at_secs` is the caller's `now` (determinism).
    pub fn upsert(&self, row: &PersistedCounts) -> CorpusKitResult<()> {
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("model_id".into(), TypedValue::Text(row.model_id.clone()));
        values.insert(
            "model_version".into(),
            TypedValue::Text(row.model_version.clone()),
        );
        values.insert("counts".into(), TypedValue::Blob(row.counts.clone()));
        values.insert("doc_count".into(), TypedValue::Int(row.document_count as i64));
        values.insert("vocab_size".into(), TypedValue::Int(row.vocab_size as i64));
        values.insert("updated_at".into(), TypedValue::Timestamp(row.updated_at_secs));
        self.storage
            .row_store()
            .upsert(
                "corpus_provider_counts",
                values,
                &["model_id".to_string(), "model_version".to_string()],
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    /// Load the full persisted counts for a provider key, or `None` if none.
    pub fn load(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<PersistedCounts>> {
        let rows = self.query_key(model_id, model_version)?;
        Ok(rows.first().and_then(decode_counts))
    }

    /// Read only the growth anchors (doc/vocab counts) for a provider key,
    /// without deserializing the counts blob — the cheap read the vocab-growth
    /// retrain trigger uses each time it evaluates staleness.
    pub fn growth_anchor(
        &self,
        model_id: &str,
        model_version: &str,
    ) -> CorpusKitResult<Option<CountsGrowthAnchor>> {
        let rows = self.query_key(model_id, model_version)?;
        Ok(rows.first().and_then(|row| {
            let document_count = match row.get("doc_count") {
                Some(TypedValue::Int(i)) => *i as usize,
                _ => return None,
            };
            let vocab_size = match row.get("vocab_size") {
                Some(TypedValue::Int(i)) => *i as usize,
                _ => return None,
            };
            Some(CountsGrowthAnchor {
                document_count,
                vocab_size,
            })
        }))
    }

    /// Delete every counts row. Used by `Corpus::destroy_recall_index` so a
    /// destroyed corpus leaves no orphaned counts behind.
    pub fn delete_all(&self) -> CorpusKitResult<()> {
        self.storage
            .row_store()
            .delete("corpus_provider_counts", &StoragePredicate::IsTrue)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(())
    }

    fn query_key(&self, model_id: &str, model_version: &str) -> CorpusKitResult<Vec<StorageRow>> {
        let predicate = StoragePredicate::And(vec![
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_id"),
                TypedValue::Text(model_id.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new("corpus_provider_counts", "model_version"),
                TypedValue::Text(model_version.to_string()),
            ),
        ]);
        self.storage
            .row_store()
            .query("corpus_provider_counts", Some(&predicate), &[], Some(1), None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }
}

/// Decode a counts row, tolerant of BOTH the semantic `Timestamp(i64)` form a
/// migrate-aware connection returns AND the raw `Text` ISO8601 form a fresh
/// connection returns on read — the same primitive-tolerance discipline
/// `basis_store::decode_basis` uses, so maintained counts are not silently
/// dropped on reopen. A row failing any field match yields `None`.
fn decode_counts(row: &StorageRow) -> Option<PersistedCounts> {
    let model_id = match row.get("model_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let model_version = match row.get("model_version") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let counts = match row.get("counts") {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => return None,
    };
    let document_count = match row.get("doc_count") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let vocab_size = match row.get("vocab_size") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let updated_at_secs = decode_updated_at_secs(row.get("updated_at"))?;
    Some(PersistedCounts {
        model_id,
        model_version,
        counts,
        document_count,
        vocab_size,
        updated_at_secs,
    })
}

/// Decode `updated_at` to epoch seconds, tolerant of `Timestamp(i64)` and `Text`
/// ISO8601 — mirrors `basis_store::decode_trained_at_secs` (same SQLite re-parse
/// caveat). Reuses the basis store's inline civil-date parser.
fn decode_updated_at_secs(value: Option<&TypedValue>) -> Option<i64> {
    match value {
        Some(TypedValue::Timestamp(secs)) => Some(*secs),
        Some(TypedValue::Text(s)) => crate::basis_store::parse_iso8601_utc(s),
        _ => None,
    }
}
