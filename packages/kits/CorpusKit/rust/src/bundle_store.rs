//! BundleStore: persistence-kit-backed chunks table. Mirror of
//! Swift's `BundleStore`. Schema mirrors the Swift declaration
//! exactly.

use crate::chunk::Chunk;
use crate::error::{CorpusKitError, CorpusKitResult};
use std::collections::BTreeMap;
use std::sync::Arc;
use persistence_kit::{
    Column, ColumnDeclaration, IndexDeclaration, OrderClause, OrderDirection, SchemaDeclaration,
    Storage, StorageError, StoragePredicate, StorageRow, TableDeclaration, TypedValue,
};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_lib::hlc::HLC;
use uuid::Uuid;

pub struct BundleStore {
    storage: Arc<dyn Storage>,
}

impl BundleStore {
    /// Schema declaration consumed by `Storage::open`. Mirrors
    /// the Swift `BundleStore.schemaDeclaration` exactly.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "CorpusKit",
            1,
            vec![TableDeclaration::new(
                "chunks",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("source_id"),
                    ColumnDeclaration::int("start_offset"),
                    ColumnDeclaration::int("length"),
                    ColumnDeclaration::text("text"),
                    ColumnDeclaration::hlc("hlc"),
                    ColumnDeclaration::json("metadata"),
                    ColumnDeclaration::timestamp("created_at"),
                ],
                vec!["id".to_string()],
            )
            .append_only()],
        )
        .with_indices(vec![
            IndexDeclaration::new("idx_chunks_source", "chunks", vec!["source_id".to_string()]),
            IndexDeclaration::new("idx_chunks_hlc", "chunks", vec!["hlc".to_string()]),
        ])
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        BundleStore { storage }
    }

    /// Convenience: open the storage with the bundle-store schema
    /// and return the store.
    pub fn open(storage: Arc<dyn Storage>) -> CorpusKitResult<Self> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(BundleStore::new(storage))
    }

    /// Insert a batch of chunks. Idempotent on primary key:
    /// re-inserting a chunk with the same id is a no-op. The chunks
    /// table is append-only, so the idempotent path is a plain insert
    /// that tolerates a duplicate-key rejection rather than an upsert.
    /// An upsert would compile to an update on conflict, which the
    /// append-only triggers reject; a plain insert hits the primary
    /// key instead and surfaces StorageError::DuplicateKey, caught
    /// here as the documented no-op. The first write of a given id
    /// wins; chunks are immutable and content-addressed.
    pub fn insert(&self, chunks: &[Chunk]) -> CorpusKitResult<()> {
        let row_store = self.storage.row_store();
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        for chunk in chunks {
            let metadata_json = serde_json::to_vec(&chunk.metadata)
                .map_err(|e| CorpusKitError::EncodingFailure(format!("metadata: {}", e)))?;
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("id".into(), TypedValue::Uuid(chunk.id));
            values.insert("source_id".into(), TypedValue::Text(chunk.source_id.clone()));
            values.insert("start_offset".into(), TypedValue::Int(chunk.start_offset as i64));
            values.insert("length".into(), TypedValue::Int(chunk.length as i64));
            values.insert("text".into(), TypedValue::Text(chunk.text.clone()));
            values.insert("hlc".into(), TypedValue::Hlc(chunk.hlc));
            values.insert("metadata".into(), TypedValue::Json(metadata_json));
            values.insert("created_at".into(), TypedValue::Timestamp(now_secs));
            match row_store.insert("chunks", values) {
                Ok(_) => {}
                // Idempotent no-op: the chunk is already stored. Chunks
                // are immutable, so there is nothing to reconcile.
                Err(StorageError::DuplicateKey { .. }) => {}
                Err(e) => return Err(CorpusKitError::StoreUnavailable(e.to_string())),
            }
        }
        Ok(())
    }

    pub fn get(&self, id: Uuid) -> CorpusKitResult<Option<Chunk>> {
        let predicate = StoragePredicate::Eq(
            Column::new("chunks", "id"),
            TypedValue::Uuid(id),
        );
        let rows = self
            .storage
            .row_store()
            .query("chunks", Some(&predicate), &[], Some(1), None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => Ok(decode_chunk(row)),
        }
    }

    pub fn get_many(&self, ids: &[Uuid]) -> CorpusKitResult<Vec<Chunk>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let values: Vec<TypedValue> = ids.iter().map(|u| TypedValue::Uuid(*u)).collect();
        let predicate = StoragePredicate::In(Column::new("chunks", "id"), values);
        let rows = self
            .storage
            .row_store()
            .query("chunks", Some(&predicate), &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }

    pub fn chunks_for_source(&self, source_id: &str) -> CorpusKitResult<Vec<Chunk>> {
        let predicate = StoragePredicate::Eq(
            Column::new("chunks", "source_id"),
            TypedValue::Text(source_id.to_string()),
        );
        let order = vec![OrderClause::new(
            Column::new("chunks", "start_offset"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query("chunks", Some(&predicate), &order, None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }

    pub fn count(&self) -> CorpusKitResult<usize> {
        self.storage
            .row_store()
            .count("chunks", None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }

    pub fn all_chunks(&self) -> CorpusKitResult<Vec<Chunk>> {
        // Order by hlc using physical_time ascending (persistence-kit
        // compares HLCs via the impl in inmemory.rs).
        let order = vec![OrderClause::new(
            Column::new("chunks", "hlc"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query("chunks", None, &order, None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }
}

fn decode_chunk(row: &StorageRow) -> Option<Chunk> {
    let id = match row.get("id") {
        Some(TypedValue::Uuid(u)) => *u,
        _ => return None,
    };
    let source_id = match row.get("source_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let start_offset = match row.get("start_offset") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let length = match row.get("length") {
        Some(TypedValue::Int(i)) => *i as usize,
        _ => return None,
    };
    let text = match row.get("text") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let hlc: HLC = match row.get("hlc") {
        Some(TypedValue::Hlc(h)) => *h,
        _ => return None,
    };
    let metadata: BTreeMap<String, String> = match row.get("metadata") {
        Some(TypedValue::Json(bytes)) => {
            serde_json::from_slice(bytes).unwrap_or_default()
        }
        _ => BTreeMap::new(),
    };
    Some(Chunk::new(
        id,
        source_id,
        start_offset,
        length,
        text,
        hlc,
        metadata,
    ))
}
