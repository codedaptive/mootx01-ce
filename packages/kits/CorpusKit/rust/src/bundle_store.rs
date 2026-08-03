//! BundleStore: persistence-kit-backed chunks table. Mirror of
//! Swift's `BundleStore`. Schema mirrors the Swift declaration
//! exactly. v3 adds hash-on-write via HashingRowStore.
//!
//! CORPUSKIT_REPORT_001 (cp-corpuskit-report): added IntellectusLib
//! self-report telemetry to `insert`. The `report!` macro calls are
//! placed at the operation boundary, after the batch completes,
//! so storage behaviour is unchanged. `insert` unconditionally reads
//! SystemTime::now() for start_ts, now_secs per chunk, and end_ts
//! before the `report!` calls; the disabled-monitoring path does not
//! short-circuit these clock reads.

use crate::chunk::Chunk;
use crate::error::{CorpusKitError, CorpusKitResult};
use intellectus_lib::{report, StatSample};
use persistence_kit::{
    Column, ColumnDeclaration, HashOnWriteConfig, HashingRowStore, IndexDeclaration, OrderClause,
    OrderDirection, RowStore, SchemaDeclaration, Storage, StorageError, StoragePredicate,
    StorageRow, TableDeclaration, TypedValue,
};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::sha256;
use substrate_lib::merkle_hash;
use substrate_types::content_hash::ContentHash;
use substrate_types::merkle_root::MerkleRoot;
use substrate_types::AsOfCoordinate;
use substrate_types::hlc::HLC;
use uuid::Uuid;

/// Thread-safe cache mapping chunk UUIDs to their Merkle containment
/// parent chain. Populated by `BundleStore::insert` before each
/// `HashingRowStore` write so the synchronous `HashParentChainProvider`
/// callback can look up the corpus-level parent.
#[derive(Default)]
struct ParentChainCache {
    cache: Mutex<HashMap<Uuid, (Uuid, Uuid)>>,
}

impl ParentChainCache {
    fn set(&self, key: Uuid, parent: Uuid, grandparent: Uuid) {
        self.cache.lock().unwrap().insert(key, (parent, grandparent));
    }

    fn get(&self, key: Uuid) -> Option<(Uuid, Uuid)> {
        self.cache.lock().unwrap().get(&key).copied()
    }

    fn clear(&self) {
        self.cache.lock().unwrap().clear();
    }
}

/// Fixed UUID representing the corpus-level root node (grandparent
/// in the chunk → corpus → root containment chain). Deterministic
/// across Swift and Rust — SHA-256 of a fixed seed, first 16 bytes.
fn corpus_root_uuid() -> Uuid {
    let digest = sha256::hash(b"CorpusKit.corpusRoot");
    Uuid::from_bytes([
        digest[0], digest[1], digest[2], digest[3],
        digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15],
    ])
}

/// Derives a deterministic UUID for a corpus from its source_id.
/// SHA-256 of a fixed namespace prefix + source_id, first 16 bytes.
/// Both Swift and Rust ports use identical derivation for
/// byte-identical Merkle containment chains.
fn corpus_uuid(source_id: &str) -> Uuid {
    let mut input = b"CorpusKit.corpusNamespace:".to_vec();
    input.extend_from_slice(source_id.as_bytes());
    let digest = sha256::hash(&input);
    Uuid::from_bytes([
        digest[0], digest[1], digest[2], digest[3],
        digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15],
    ])
}

pub struct BundleStore {
    storage: Arc<dyn Storage>,
    /// The hashing decorator wrapping the raw row store. Intercepts
    /// inserts to hashable tables, computes ContentHash via
    /// MerkleHash::leaf, and emits DirtyChainEvents for Merkle rollup.
    hashing_row_store: Arc<HashingRowStore>,
    /// Pre-insert cache for the HashParentChainProvider callback.
    parent_chain_cache: Arc<ParentChainCache>,
}

impl BundleStore {
    /// Schema declaration consumed by `Storage::open`. Mirrors
    /// the Swift `BundleStore.schemaDeclaration` exactly.
    pub fn schema_declaration() -> SchemaDeclaration {
        // v2 adds the nullable `.json` `ext` forward-compat slot.
        // v3 adds `content_hash` BLOB column and marks the table `hashable`
        // for hash-on-write via HashingRowStore (node-tree integrity, NT-C1).
        // The `content_hash` column is nullable: NULL for rows inserted
        // before v3 (backward-compatible migration, no backfill required).
        SchemaDeclaration::new(
            "CorpusKit",
            3,
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
                    // nullable entity ext slots forward-compat slot (v2). Nullable JSON; distinct
                    // from `metadata`. 1.0 omits it on insert and never reads it.
                    ColumnDeclaration::json("ext").nullable(),
                    // NT-C1 (v3): SHA-256 content hash computed by
                    // HashingRowStore on write via MerkleHash::leaf.
                    // Nullable for backward compat with pre-v3 rows.
                    ColumnDeclaration::blob("content_hash").nullable(),
                ],
                vec!["id".to_string()],
            )
            // append_only removed (secfix/ws2-coredelete): chunks table must be
            // updatable so scrub_text() can zero verbatim text on expunge.
            // The idempotent insert path is unaffected — duplicate-key rejection
            // happens at the primary-key constraint level, not via triggers.
            .hashable(),
            // Per-corpus Merkle root: MerkleHash::interior over the
            // content_hashes of all chunks sharing a source_id.
            // Updated incrementally after each insert batch (NT-C1 Part 3).
            TableDeclaration::new(
                "corpus_metadata",
                vec![
                    ColumnDeclaration::text("source_id"),
                    // MerkleRoot bytes (32-byte SHA-256). NULL until the
                    // first rollup computes it.
                    ColumnDeclaration::blob("merkle_root").nullable(),
                ],
                vec!["source_id".to_string()],
            )],
        )
        .with_indices(vec![
            IndexDeclaration::new("idx_chunks_source", "chunks", vec!["source_id".to_string()]),
            IndexDeclaration::new("idx_chunks_hlc", "chunks", vec!["hlc".to_string()]),
        ])
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        let parent_cache = Arc::new(ParentChainCache::default());
        let cache_ref = Arc::clone(&parent_cache);

        let mut hashable_tables = HashSet::new();
        hashable_tables.insert("chunks".to_string());

        let config = HashOnWriteConfig {
            hashable_tables,
            hash_provider: Box::new(|_table, row_key, values| {
                // Extract chunk text for hashing. Vectors live in
                // VectorKit (not inline), so vector input is empty.
                let content_bytes: Vec<u8> = match values.get("text") {
                    Some(TypedValue::Text(t)) => t.as_bytes().to_vec(),
                    _ => Vec::new(),
                };
                let id_bytes = *row_key.as_bytes();
                merkle_hash::leaf(&id_bytes, &content_bytes, &[])
            }),
            parent_chain_provider: Box::new(move |_table, row_key| {
                cache_ref.get(row_key)
            }),
        };

        let hashing_store = Arc::new(HashingRowStore::new(
            storage.row_store(),
            config,
            None,
        ));

        BundleStore {
            storage,
            hashing_row_store: hashing_store,
            parent_chain_cache: parent_cache,
        }
    }

    /// Convenience: open the storage with the bundle-store schema
    /// and return the store.
    pub fn open(storage: Arc<dyn Storage>) -> CorpusKitResult<Self> {
        let schema = Self::schema_declaration();
        storage
            .open(&schema)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let store = BundleStore::new(storage);
        // WS2-F3: backfill corpus_metadata rows for any existing chunks.
        // After a v2→v3 schema upgrade the corpus_metadata table is empty
        // even though chunks exist; global_corpus_merkle_root() would return
        // EMPTY until the next insert triggered rollup_corpus_merkle_root.
        // This call is idempotent (upsert on conflict) and runs once at open.
        store.recompute_all_corpus_merkle_roots()?;
        Ok(store)
    }

    /// Insert a batch of chunks. Idempotent on primary key:
    /// re-inserting a chunk with the same id is a no-op. The idempotent
    /// path is a plain insert that tolerates a duplicate-key rejection
    /// rather than an upsert — a plain insert hits the primary key
    /// constraint and surfaces StorageError::DuplicateKey, caught here
    /// as the documented no-op. The first write of a given id wins;
    /// chunks are immutable and content-addressed.
    ///
    /// Note: the chunks table is NOT append-only, enabling `scrub_text()`
    /// to zero verbatim text on expunge (secfix/ws2-coredelete).
    ///
    /// Telemetry: emits `corpuskit.ingest.latency_ms` and
    /// `corpuskit.ingest.chunk_count` when monitoring is enabled.
    /// Both are emitted at the operation boundary after the last insert
    /// attempt completes. Off-path: single `AtomicBool::load + branch`
    /// per call via the `report!` macro. Mirrors Swift's
    /// `BundleStore.insert` telemetry exactly.
    /// Insert a batch of chunks. Idempotent on primary key (re-inserting a chunk
    /// with the same id is a no-op). Returns the subset ACTUALLY inserted (new
    /// ids), in input order — duplicate-key no-ops are excluded — so callers that
    /// maintain derived per-chunk state (the maintained provider counts) fold only
    /// over the new chunks and do not double-count on re-ingest. Mirrors the Swift
    /// `BundleStore.insert` return.
    pub fn insert(&self, chunks: &[Chunk]) -> CorpusKitResult<Vec<Chunk>> {
        if chunks.is_empty() {
            return Ok(Vec::new());
        }
        let mut inserted: Vec<Chunk> = Vec::with_capacity(chunks.len());
        // Capture start time before the I/O. The computed latency is
        // forwarded to the sink only when monitoring is enabled (inside
        // the report! macro's if-enabled guard).
        let start_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);

        // Epoch MILLISECONDS — `TypedValue::Timestamp` is a millisecond codec
        // (`persistence_kit::sqlite`). Seconds here files every chunk as 1970.
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let root_uuid = corpus_root_uuid();
        for chunk in chunks {
            let metadata_json = serde_json::to_vec(&chunk.metadata)
                .map_err(|e| CorpusKitError::EncodingFailure(format!("metadata: {}", e)))?;
            let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
            values.insert("id".into(), TypedValue::Uuid(chunk.id));
            values.insert(
                "source_id".into(),
                TypedValue::Text(chunk.source_id.clone()),
            );
            values.insert(
                "start_offset".into(),
                TypedValue::Int(chunk.start_offset as i64),
            );
            values.insert("length".into(), TypedValue::Int(chunk.length as i64));
            values.insert("text".into(), TypedValue::Text(chunk.text.clone()));
            values.insert("hlc".into(), TypedValue::Hlc(chunk.hlc));
            values.insert("metadata".into(), TypedValue::Json(metadata_json));
            values.insert("created_at".into(), TypedValue::Timestamp(now_ms));
            // Pre-populate parent chain cache so the synchronous
            // HashParentChainProvider callback can map this chunk
            // to its corpus-level parent in the Merkle tree.
            let c_uuid = corpus_uuid(&chunk.source_id);
            self.parent_chain_cache.set(chunk.id, c_uuid, root_uuid);
            match self.hashing_row_store.insert("chunks", values) {
                Ok(_) => inserted.push(chunk.clone()),
                // Idempotent no-op: the chunk is already stored. Chunks
                // are immutable, so there is nothing to reconcile. NOT pushed to
                // `inserted` — derived per-chunk state must not double-count it.
                Err(StorageError::DuplicateKey { .. }) => {}
                Err(e) => return Err(CorpusKitError::StoreUnavailable(e.to_string())),
            }
        }
        self.parent_chain_cache.clear();

        // Recompute per-corpus Merkle roots for all affected sources.
        let affected_sources: HashSet<String> = chunks.iter().map(|c| c.source_id.clone()).collect();
        for source_id in &affected_sources {
            self.rollup_corpus_merkle_root(source_id)?;
        }

        // Emit ingest telemetry at the operation boundary, after all
        // insert attempts complete (including idempotent no-ops). The
        // report! macro evaluates its argument only when monitoring is
        // enabled; when disabled it is a single AtomicBool load + branch.
        //
        // corpuskit.ingest.latency_ms: wall time for the full batch insert.
        // corpuskit.ingest.chunk_count: chunks in the batch (incl. no-ops).
        // Mirrors the two Swift emit sites in BundleStore.insert.
        let end_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let chunk_count = chunks.len();
        report!(StatSample::metric(
            "corpuskit.ingest.latency_ms".to_string(),
            (end_ts - start_ts) * 1000.0,
            [("kit".to_string(), "CorpusKit".to_string())]
                .into_iter().collect(),
            end_ts,
        ));
        report!(StatSample::metric(
            "corpuskit.ingest.chunk_count".to_string(),
            chunk_count as f64,
            [("kit".to_string(), "CorpusKit".to_string())]
                .into_iter().collect(),
            end_ts,
        ));

        Ok(inserted)
    }

    pub fn get(&self, id: Uuid, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Option<Chunk>> {
        let predicate = StoragePredicate::Eq(Column::new("chunks", "id"), TypedValue::Uuid(id));
        let rows = self
            .storage
            .row_store()
            .query_as_of("chunks", Some(&predicate), &[], Some(1), None, as_of)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => Ok(decode_chunk(row)),
        }
    }

    pub fn get_many(&self, ids: &[Uuid], as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let values: Vec<TypedValue> = ids.iter().map(|u| TypedValue::Uuid(*u)).collect();
        let predicate = StoragePredicate::In(Column::new("chunks", "id"), values);
        let rows = self
            .storage
            .row_store()
            .query_as_of("chunks", Some(&predicate), &[], None, None, as_of)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }

    pub fn chunks_for_source(&self, source_id: &str, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>> {
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
            .query_as_of("chunks", Some(&predicate), &order, None, None, as_of)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }

    /// Return the set of distinct `source_id` values present in the chunks table.
    ///
    /// Used by `reindex_missing` to identify which drawers are already BM25/vector-
    /// indexed so the backfill only enqueues the un-indexed subset. Full-table scan
    /// (no DISTINCT support through the PersistenceKit row abstraction); acceptable
    /// for a maintenance/admin path, not a hot path. Mirrors Swift
    /// `BundleStore.allSourceIDs()`.
    pub fn all_source_ids(&self, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<std::collections::HashSet<String>> {
        let rows = self
            .storage
            .row_store()
            .query_as_of("chunks", None, &[], None, None, as_of)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut ids = std::collections::HashSet::new();
        for row in &rows {
            if let Some(TypedValue::Text(source_id)) = row.get("source_id") {
                ids.insert(source_id.clone());
            }
        }
        Ok(ids)
    }

    /// Return a compact `(chunk_uuid, source_id)` projection of the chunks table —
    /// no body text is loaded.
    ///
    /// Used during Corpus::open to warm-load `chunk_source_map` without paying
    /// the O(N·body) cost of `all_chunks`. Mirrors Swift `BundleStore.chunkSourcePairs()`.
    pub fn chunk_source_pairs(&self) -> CorpusKitResult<Vec<(uuid::Uuid, String)>> {
        let rows = self
            .storage
            .row_store()
            .query("chunks", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut pairs = Vec::with_capacity(rows.len());
        for row in &rows {
            // UUID may arrive as .Uuid (InMemory) or .Text (SQLite) — same
            // primitive-tolerance discipline as decode_chunk.
            let uuid = match row.get("id") {
                Some(TypedValue::Uuid(u)) => Some(*u),
                Some(TypedValue::Text(s)) => uuid::Uuid::parse_str(s).ok(),
                _ => None,
            };
            let source_id = match row.get("source_id") {
                Some(TypedValue::Text(s)) => Some(s.clone()),
                _ => None,
            };
            if let (Some(u), Some(s)) = (uuid, source_id) {
                pairs.push((u, s));
            }
        }
        Ok(pairs)
    }

    // as_of accepted for API parity but not forwarded: RowStore::count has no
    // as_of variant. Count includes all rows regardless of snapshot coordinate.
    pub fn count(&self, _as_of: Option<AsOfCoordinate>) -> CorpusKitResult<usize> {
        self.storage
            .row_store()
            .count("chunks", None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }

    pub fn all_chunks(&self, as_of: Option<AsOfCoordinate>) -> CorpusKitResult<Vec<Chunk>> {
        let order = vec![OrderClause::new(
            Column::new("chunks", "hlc"),
            OrderDirection::Ascending,
        )];
        let rows = self
            .storage
            .row_store()
            .query_as_of("chunks", None, &order, None, None, as_of)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        Ok(rows.iter().filter_map(decode_chunk).collect())
    }

    // ── Hard-delete erasure (secfix/ws2-coredelete) ──

    /// Zero the verbatim text of every chunk belonging to `source_id`.
    ///
    /// Updates `chunks` SET `text` = "" WHERE `source_id` = source_id.
    /// This is the corpus layer's contribution to the hard-delete
    /// destruction contract — the counterpart to Swift's
    /// `BundleStore.scrubText(sourceID:)`.
    ///
    /// Called by `Corpus::expunge(source_id)` as part of the two-phase
    /// expunge flow: scrub text first, then remove from recall.
    /// The content_hash column is left stale intentionally — the data
    /// is being destroyed; Merkle chain accuracy for a destroyed corpus
    /// is not a requirement.
    ///
    /// Returns the number of chunk rows whose text was zeroed.
    pub fn scrub_text(&self, source_id: &str) -> CorpusKitResult<usize> {
        let mut values = BTreeMap::new();
        values.insert("text".to_string(), TypedValue::Text(String::new()));
        let predicate = StoragePredicate::Eq(
            Column::new("chunks", "source_id"),
            TypedValue::Text(source_id.to_string()),
        );
        self.storage
            .row_store()
            .update("chunks", values, &predicate)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))
    }

    // ── Per-corpus Merkle root (NT-C1 Part 3) ──

    /// Recompute the Merkle root for one corpus (source_id) from the
    /// content_hashes of its chunks. Stores the result in the
    /// Recompute Merkle roots for all existing corpora.
    ///
    /// Called by `open()` after schema migration to backfill any existing
    /// chunks that were inserted before the `corpus_metadata` table was
    /// introduced (schema v3). Without this call, `global_corpus_merkle_root`
    /// returns `MerkleRoot::EMPTY` for any estate upgraded from v2, even
    /// though chunks exist (WS2-F3, fixed 2026-06-28).
    ///
    /// Idempotent: upsert on conflict, so re-running on an already-populated
    /// corpus_metadata table is a harmless no-op per-row.
    fn recompute_all_corpus_merkle_roots(&self) -> CorpusKitResult<()> {
        let source_ids = self.all_source_ids(None)?;
        for source_id in source_ids {
            self.rollup_corpus_merkle_root(&source_id)?;
        }
        Ok(())
    }

    /// `corpus_metadata` table via upsert.
    ///
    /// For chunks without a stored content_hash (pre-v3 data), a leaf
    /// hash is computed on-demand from the chunk text. Called after
    /// every insert batch for each affected source_id.
    fn rollup_corpus_merkle_root(&self, source_id: &str) -> CorpusKitResult<()> {
        let predicate = StoragePredicate::Eq(
            Column::new("chunks", "source_id"),
            TypedValue::Text(source_id.to_string()),
        );
        let rows = self
            .storage
            .row_store()
            .query("chunks", Some(&predicate), &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let mut child_hashes: Vec<([u8; 16], ContentHash)> = Vec::new();
        for row in &rows {
            let chunk_id = match row.get("id") {
                Some(TypedValue::Uuid(u)) => *u,
                Some(TypedValue::Text(s)) => match Uuid::parse_str(s) {
                    Ok(u) => u,
                    Err(_) => continue,
                },
                _ => continue,
            };

            let content_hash = match row.get("content_hash") {
                Some(TypedValue::Blob(data)) if data.len() == 32 => {
                    let mut bytes = [0u8; 32];
                    bytes.copy_from_slice(data);
                    ContentHash::new(bytes)
                }
                _ => {
                    // No stored hash (pre-v3 row) — compute on-demand.
                    let text = match row.get("text") {
                        Some(TypedValue::Text(t)) => t.as_bytes().to_vec(),
                        _ => Vec::new(),
                    };
                    merkle_hash::leaf(chunk_id.as_bytes(), &text, &[])
                }
            };
            child_hashes.push((*chunk_id.as_bytes(), content_hash));
        }

        let root = merkle_hash::interior(&child_hashes);
        let mut values = BTreeMap::new();
        values.insert("source_id".into(), TypedValue::Text(source_id.to_string()));
        values.insert("merkle_root".into(), TypedValue::Blob(root.bytes().to_vec()));
        self.storage
            .row_store()
            .upsert("corpus_metadata", values, &["source_id".to_string()])
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        Ok(())
    }

    /// Returns the current per-corpus Merkle root for the given source.
    /// Returns `MerkleRoot::EMPTY` if the corpus has no metadata row yet.
    pub fn corpus_merkle_root(&self, source_id: &str) -> CorpusKitResult<MerkleRoot> {
        let predicate = StoragePredicate::Eq(
            Column::new("corpus_metadata", "source_id"),
            TypedValue::Text(source_id.to_string()),
        );
        let rows = self
            .storage
            .row_store()
            .query("corpus_metadata", Some(&predicate), &[], Some(1), None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        match rows.first() {
            Some(row) => match row.get("merkle_root") {
                Some(TypedValue::Blob(data)) if data.len() == 32 => {
                    let mut bytes = [0u8; 32];
                    bytes.copy_from_slice(data);
                    Ok(MerkleRoot::new(bytes))
                }
                _ => Ok(MerkleRoot::EMPTY),
            },
            None => Ok(MerkleRoot::EMPTY),
        }
    }

    /// Returns the estate-level corpus Merkle root — the interior hash
    /// over all per-corpus roots. Returns `MerkleRoot::EMPTY` when no
    /// corpora exist.
    pub fn global_corpus_merkle_root(&self) -> CorpusKitResult<MerkleRoot> {
        let rows = self
            .storage
            .row_store()
            .query("corpus_metadata", None, &[], None, None)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        let mut child_hashes: Vec<([u8; 16], ContentHash)> = Vec::new();
        for row in &rows {
            let source_id = match row.get("source_id") {
                Some(TypedValue::Text(s)) => s.clone(),
                _ => continue,
            };
            let c_uuid = corpus_uuid(&source_id);
            let root_bytes = match row.get("merkle_root") {
                Some(TypedValue::Blob(data)) if data.len() == 32 => {
                    let mut bytes = [0u8; 32];
                    bytes.copy_from_slice(data);
                    bytes
                }
                _ => *MerkleRoot::EMPTY.bytes(),
            };
            child_hashes.push((*c_uuid.as_bytes(), ContentHash::new(root_bytes)));
        }
        Ok(merkle_hash::interior(&child_hashes))
    }
}

fn decode_chunk(row: &StorageRow) -> Option<Chunk> {
    // The `id` column is TEXT in SQLite (no native UUID column type), so the
    // SQLite backend hands it back as `Text` on read, while the InMemory backend
    // preserves the inserted `Uuid`. Accept BOTH: decoding `Uuid` only silently
    // dropped every persisted chunk on reopen, so the BM25 rebuild indexed
    // nothing and semantic recall went dark on any restored estate. Mirrors the
    // Swift BundleStore.decodeRowUUID fix (parity-is-absolute).
    let id = match row.get("id") {
        Some(TypedValue::Uuid(u)) => *u,
        Some(TypedValue::Text(s)) => match Uuid::parse_str(s) {
            Ok(u) => u,
            Err(_) => return None,
        },
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
    // hlc: an HLC column stores the packed u64; SQLite has no native HLC type so
    // it round-trips as `Int`, while the InMemory backend preserves `Hlc`. Accept
    // both — decoding only `Hlc` dropped every persisted chunk on reopen (see the
    // Swift BundleStore.decodeRowHLC fix, parity-is-absolute).
    let hlc: HLC = match row.get("hlc") {
        Some(TypedValue::Hlc(h)) => *h,
        Some(TypedValue::Int(i)) => HLC::from_packed(*i as u64),
        _ => return None,
    };
    // metadata: a JSON column reads back as `Json` on InMemory and `Blob` (raw
    // JSON bytes) on SQLite. Accept both; absent/unparseable is an empty map.
    let metadata: BTreeMap<String, String> = match row.get("metadata") {
        Some(TypedValue::Json(bytes)) | Some(TypedValue::Blob(bytes)) => {
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
