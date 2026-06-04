//! `Corpus` — the unified RAG entry point for corpus-kit.
//!
//! Mirrors Swift's `Corpus` actor. Composes `BundleStore`, `BM25Index`,
//! `VectorStore`, and an `EmbeddingProvider` internally; no VectorKit
//! type appears in the public API. Callers see documents and queries
//! only.
//!
//! Concurrency: `Corpus` wraps the in-memory `BM25Index` in a `Mutex`
//! because BM25Index requires `&mut self` for mutations. `VectorStore`
//! and `BundleStore` handle their own interior mutability through
//! `Arc<dyn Storage>`. The struct is `Send + Sync`.
//!
//! Platform note: CoreML is Apple-only. The Swift port ships `miniLM`,
//! `mpNet`, and `embeddingGemma` `EmbeddingModel` cases that accept
//! CoreML inference closures. The Rust `EmbeddingModelConfig` ships only
//! `Deterministic`; ONNX/Candle-backed named models land in a follow-on
//! mission once model bundles are wired in (SPEC § 9).

use crate::bm25_index::BM25Index;
use crate::bundle_store::BundleStore;
use crate::chunk::ScoredChunk;
use crate::chunker::{chunk_with_default_hlc, ChunkerConfiguration};
use crate::error::{CorpusKitError, CorpusKitResult};
use crate::hybrid_recall::{recall as hybrid_recall, HybridRecallConfiguration};
use crate::tokenizer::{default_keyword_tokens, Tokenizer};
use std::sync::{Arc, Mutex};
use vectorkit::simhash_embedding_provider::FloatSimHashEmbeddingProvider;
use vectorkit::vector_store::VectorStore;
use vectorkit::EmbeddingProvider;
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
use persistence_kit::Storage;

// MARK: - EmbeddingModelConfig

/// Selects the embedding model the `Corpus` struct uses internally.
///
/// Rust counterpart to Swift's `EmbeddingModel`. Because CoreML is
/// Apple-only, the named model cases (MiniLM, MPNet, EmbeddingGemma)
/// are not available in this port; they land in a follow-on mission
/// once ONNX/Candle-backed providers are wired in.
///
/// Use `Deterministic` (the default) for tests and offline contexts.
#[derive(Default)]
pub enum EmbeddingModelConfig {
    /// Deterministic hash embedding — no model bundle required.
    ///
    /// Uses FNV-1a 64-bit hashing through FloatSimHash with a fixed
    /// seed. Consistent across calls and across Swift/Rust ports, but
    /// not semantically meaningful. Suitable for tests and offline use.
    #[default]
    Deterministic,
}

// Seed is distinct from all model-specific seeds and matches the Swift
// EmbeddingModel.deterministicSeed for cross-port consistency.
const DETERMINISTIC_SEED: u64 = 0xC05B_D15C_A15D_1B00;

/// FNV-1a 64-bit constants.
const FNV_OFFSET_BASIS: u64 = 14_695_981_039_346_656_037;
const FNV_PRIME_64: u64 = 1_099_511_628_211;
/// LCG constants (Knuth multiplicative + Brown increment).
const LCG_MULTIPLIER: u64 = 6_364_136_223_846_793_005;
const LCG_INCREMENT: u64 = 1_442_695_040_888_963_407;

fn make_deterministic_provider() -> FloatSimHashEmbeddingProvider {
    // FNV-1a 64-bit hash of the input text, then LCG for 32 floats in
    // [-1, 1]. Mirrors the Swift EmbeddingModel.deterministic closure
    // exactly (same constants, same LCG, same float mapping).
    FloatSimHashEmbeddingProvider::new(
        "corpus-deterministic-v1",
        "1.0.0",
        DETERMINISTIC_SEED,
        |text: &str| {
            let mut h = text
                .bytes()
                .fold(FNV_OFFSET_BASIS, |acc, b| (acc ^ u64::from(b)).wrapping_mul(FNV_PRIME_64));
            let floats: Vec<f32> = (0..32)
                .map(|_| {
                    h = h.wrapping_mul(LCG_MULTIPLIER).wrapping_add(LCG_INCREMENT);
                    // High 24 bits as a mantissa in [0, 1), scaled to [-1, 1].
                    let mantissa = (h >> 40) as f32 / (1u64 << 24) as f32;
                    mantissa * 2.0 - 1.0
                })
                .collect();
            Ok(floats)
        },
    )
}

// MARK: - Corpus

/// Unified RAG entry point for corpus-kit.
///
/// Rust mirror of Swift's `Corpus` actor. Composes `BundleStore`,
/// `BM25Index`, `VectorStore`, and an `EmbeddingProvider` internally.
/// No VectorKit type appears in any public method signature.
///
/// Lifecycle: construct via `Corpus::open`, then call `ingest` to add
/// documents and `recall` to query. `BundleStore` is append-only, so
/// `remove` clears the recall index without deleting content rows.
pub struct Corpus {
    bundle_store: BundleStore,
    /// Mutex guards mutable BM25 index operations (index_documents / remove).
    bm25: Mutex<BM25Index>,
    vector_store: VectorStore,
    provider: Box<dyn EmbeddingProvider>,
}

impl Corpus {
    /// Construct a Corpus against a PersistenceKit Storage.
    ///
    /// Opens the BundleStore and VectorStore schemas on the supplied
    /// storage via their respective `::open` constructors (which apply
    /// schemas and return the store). Both schemas are applied to the
    /// same underlying storage; subsequent calls with the same storage
    /// are idempotent.
    ///
    /// - `storage`: A `Arc<dyn Storage>` instance.
    /// - `model`: Embedding model configuration. Defaults to
    ///   `EmbeddingModelConfig::Deterministic`.
    pub fn open(storage: Arc<dyn Storage>, model: EmbeddingModelConfig) -> CorpusKitResult<Self> {
        // Apply both schemas via `migrate` (which always runs `apply_migrations_inner`
        // regardless of current version). Using `open` for both would version-gate the
        // second schema away when both kits are version 1, leaving the vectors table
        // unregistered in InMemory storage. `migrate` bypasses that gate.
        storage
            .migrate(&BundleStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;

        let bundle_store = BundleStore::new(Arc::clone(&storage));
        let vector_store = VectorStore::new(Arc::clone(&storage));

        let bm25 = BM25Index::new(Arc::new(CorpusBm25Tokenizer));
        let provider: Box<dyn EmbeddingProvider> = match model {
            EmbeddingModelConfig::Deterministic => Box::new(make_deterministic_provider()),
        };

        Ok(Corpus {
            bundle_store,
            bm25: Mutex::new(bm25),
            vector_store,
            provider,
        })
    }

    // MARK: - Public API

    /// Ingest text from a source document.
    ///
    /// The text is chunked, stored in the BundleStore (idempotent on
    /// content-addressed ids), indexed in BM25, and embedded + stored as
    /// vectors. Re-ingesting the same text for the same `source_id` is a
    /// no-op: content-addressed ids make every layer idempotent.
    ///
    /// `now_millis`: Unix epoch in milliseconds. Supplied by the caller
    /// for determinism; never call `SystemTime::now()` inside engines.
    pub fn ingest(&self, text: &str, source_id: &str, now_millis: i64) -> CorpusKitResult<()> {
        let chunks =
            chunk_with_default_hlc(text, source_id, ChunkerConfiguration::default(), now_millis);
        if chunks.is_empty() {
            return Ok(());
        }

        self.bundle_store.insert(&chunks)?;

        {
            let mut bm25 = self
                .bm25
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("BM25 lock poisoned".into()))?;
            bm25.index_documents(chunks.iter().map(|c| (c.id, c.text.as_str())));
        }

        // Fan-out: embed each chunk and store the vector. The
        // chunk.id == vector.drawer_id join is maintained here;
        // the caller never sees it (sealed-vector principle).
        //
        // `filed_at` is in Unix seconds; convert from millis.
        let filed_at_secs = now_millis / 1000;
        for chunk in &chunks {
            let engram = self
                .provider
                .embed(&chunk.text)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?;
            self.vector_store
                .add_vector(
                    &chunk.id.to_string(),
                    &engram,
                    self.provider.model_id(),
                    self.provider.model_version(),
                    filed_at_secs,
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        }
        Ok(())
    }

    /// Recall the top-k chunks relevant to a query.
    ///
    /// Embeds the query and fuses vector kNN hits + BM25 keyword hits
    /// via Reciprocal Rank Fusion (SPEC § 5, B-4). Both passes are
    /// filtered to the model id this Corpus was configured with.
    ///
    /// `_now_millis`: Reserved; included for API symmetry with `ingest`
    /// and determinism discipline.
    pub fn recall(
        &self,
        query: &str,
        limit: usize,
        _now_millis: i64,
    ) -> CorpusKitResult<Vec<ScoredChunk>> {
        let probe = self
            .provider
            .embed(query)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?;

        let bm25 = self
            .bm25
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("BM25 lock poisoned".into()))?;

        hybrid_recall(
            &probe,
            query,
            self.provider.model_id(),
            limit,
            &self.vector_store,
            &bm25,
            &self.bundle_store,
            HybridRecallConfiguration::default(),
        )
    }

    /// Remove a source document from the recall index.
    ///
    /// Removes the source's chunks from BM25 and deletes their vectors
    /// from VectorStore. BundleStore is append-only so content rows are
    /// preserved; the source will no longer appear in recall results.
    pub fn remove(&self, source_id: &str) -> CorpusKitResult<()> {
        let chunks = self.bundle_store.chunks_for_source(source_id)?;
        let mut bm25 = self
            .bm25
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("BM25 lock poisoned".into()))?;
        for chunk in &chunks {
            bm25.remove(chunk.id);
            self.vector_store
                .delete_vector(&chunk.id.to_string(), self.provider.model_id())
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        }
        Ok(())
    }

    /// Count the total chunks in the bundle store across all sources.
    ///
    /// Because BundleStore is append-only, this count does not decrease
    /// when `remove` is called — removed chunks are still stored but no
    /// longer appear in recall results.
    pub fn count(&self) -> CorpusKitResult<usize> {
        self.bundle_store.count()
    }
}

// MARK: - BM25 tokenizer

/// FNV-1a keyword tokenizer for the BM25 index. Uses the default
/// `keyword_tokens` function (lowercase + Unicode word split), matching
/// the Swift CorpusDefaultTokenizer's keyword token behavior.
struct CorpusBm25Tokenizer;

impl Tokenizer for CorpusBm25Tokenizer {
    fn vocab_id(&self) -> &str {
        "corpus-bm25-v1"
    }
    fn max_tokens(&self) -> usize {
        128
    }
    fn pad_token_id(&self) -> i32 {
        0
    }
    fn unknown_token_id(&self) -> i32 {
        1
    }
    fn tokenize(&self, text: &str) -> Vec<i32> {
        // FNV-1a 32-bit fold into [2, 30520). Only called if a caller
        // requests raw token ids; BM25Index calls keyword_tokens instead.
        const VOCAB_RANGE: u32 = 30520;
        self.keyword_tokens(text)
            .iter()
            .take(self.max_tokens())
            .map(|word| {
                let h = word
                    .bytes()
                    .fold(2_166_136_261u32, |acc, b| (acc ^ u32::from(b)).wrapping_mul(1_677_619));
                2 + (h % VOCAB_RANGE) as i32
            })
            .collect()
    }
    fn keyword_tokens(&self, text: &str) -> Vec<String> {
        default_keyword_tokens(text)
    }
}
