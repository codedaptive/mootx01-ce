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
//! Platform note: model inference is host-supplied on BOTH ports. The
//! Swift `EmbeddingModel` cases `miniLM`/`mpNet`/`embeddingGemma` accept
//! an inference closure (CoreML on Apple); `EmbeddingModelConfig` here
//! carries the SAME named cases over an inference closure the host wraps
//! around whatever runtime it chooses on Windows/Linux (the kit bundles
//! no model weights and links no ML-runtime crate — external deps are
//! prohibited). The seam payload is identical to Swift: token IDs in,
//! pooled float vector out. The kit owns the FNV-1a tokenization and the
//! FloatSimHash projection on both ports; for any shared (text -> pooled
//! vector) the engram is bit-identical Swift/Rust (SPEC § 8.2).

use crate::basis_store::{BasisStore, PersistedBasis};
use crate::bm25_index::BM25Index;
use crate::bundle_store::BundleStore;
use crate::chunk::{Chunk, ScoredChunk};
use crate::chunker::{chunk_with_default_hlc, ChunkerConfiguration};
use crate::error::{CorpusKitError, CorpusKitResult};
use crate::hybrid_recall::{recall as hybrid_recall, HybridRecallConfiguration};
use crate::tokenizer::{default_keyword_tokens, Tokenizer};
use crate::trainable_embedding_basis::TrainableEmbeddingBasis;
use engram_lib::Engram;
use intellectus_lib::{report, StatSample};
use std::sync::{Arc, Mutex};
use substrate_ml::float_simhash;
use vectorkit::simhash_embedding_provider::FloatSimHashEmbeddingProvider;
use vectorkit::vector_store::VectorStore;
use vectorkit::EmbeddingProvider;
use vectorkit::VectorKitError;
use vectorkit::VectorPayload;
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
use persistence_kit::Storage;

// MARK: - FloatLaneOutcome

/// Observable outcome of a `Corpus::float_nearest` call.
///
/// Mirrors Swift `FloatLaneOutcome`. Dark outcomes are EXPECTED degradations;
/// the caller degrades gracefully. `StoreError` is NOT expected: the error
/// description is emitted via `eprintln!` (Rust has no OSLog equivalent) and
/// counted via `corpus.float_lane.store_error` so failures are never swallowed.
///
/// Callers must never treat a dark outcome as a failure. A dark dense lane
/// means the query continues on other lanes only.
#[derive(Debug)]
pub enum FloatLaneOutcome {
    /// Lane ran and returned at least one ranked hit.
    ///
    /// Contains `(item_id, cosine_similarity)` pairs nearest-first.
    /// `item_id` == `source_id` at ingest time (drawer ID in the GLK context).
    /// Similarity ∈ \[−1, 1\], 1.0 = identical direction.
    Hits(Vec<(String, f32)>),

    /// Provider opted out — expected, not an error.
    ///
    /// The provider's `embed_float` errored (it has no float lane). This is
    /// the normal outcome for `EmbeddingModelConfig::Deterministic` on
    /// providers that do not override `embed_float`. The dense lane is dark;
    /// all other lanes are unaffected.
    UnavailableProviderOptOut,

    /// No float rows stored — expected when ingest has not run with a
    /// float-capable provider. Dense lane is dark; other lanes unaffected.
    UnavailableNoFloatRows,

    /// Query was empty or `limit` was zero — the call was a no-op.
    ///
    /// No telemetry emitted: the guard fired before any store access.
    EmptyQuery,

    /// Vector store threw during `find_nearest_float`.
    ///
    /// NOT an expected degradation. The error is printed via `eprintln!`
    /// (Rust has no OSLog; this mirrors Swift's `corpusLog.error`) and
    /// counted via `corpus.float_lane.store_error` so dashboards surface it.
    /// The query continues on other lanes — this degrades, never fails.
    StoreError(String),
}

// MARK: - EmbeddingModelConfig

/// Host-supplied inference seam for the named model cases: FNV-1a
/// token IDs in, pooled float vector out. Mirrors the Swift
/// `EmbeddingModel` cases' `([Int32]) async throws -> [Float]`
/// closure; synchronous to match the Rust `EmbeddingProvider` trait
/// (the host adapts any async model pass behind this boundary).
pub type NamedInferenceFn = Box<dyn Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static>;

/// Selects the embedding model the `Corpus` struct uses internally.
///
/// Rust counterpart to Swift's `EmbeddingModel`. Model inference is
/// host-supplied on every platform, so the named cases each carry an
/// inference closure the host injects — exactly as the Swift cases do.
/// The kit owns FNV-1a tokenization and the FloatSimHash projection;
/// the host owns the model pass (CoreML on Apple, a host-chosen runtime
/// on Windows/Linux). No model weights are bundled and no ML-runtime
/// crate is linked.
///
/// Use `Deterministic` (the default) for tests and offline contexts.
/// Use `RandomIndexing` for a self-contained distributional provider
/// that captures co-occurrence semantics from the estate's own content.
#[derive(Default)]
pub enum EmbeddingModelConfig {
    /// Deterministic hash embedding — no model bundle required.
    ///
    /// Uses FNV-1a 64-bit hashing through FloatSimHash with a fixed
    /// seed. Consistent across calls and across Swift/Rust ports, but
    /// not semantically meaningful. Suitable for tests and offline use.
    #[default]
    Deterministic,

    /// Random Indexing distributional-semantics provider.
    ///
    /// The caller constructs and trains a `RandomIndexingProvider` from
    /// `corpus-kit-providers`, then wraps it in a `Box<dyn EmbeddingProvider>`
    /// and passes it here. The trained provider is self-contained: it
    /// requires no host inference seam, no CoreML model bundle, and no
    /// ML-runtime crate. Distributional co-occurrence semantics are captured
    /// from the estate's own content during training.
    ///
    /// Unlike the named model cases, `RandomIndexing` carries the fully-built
    /// provider rather than a construction closure, because the provider state
    /// (the trained vocabulary) is built externally by the caller before
    /// opening the Corpus.
    ///
    /// See ADR-010 Decision B for the rationale and `RandomIndexingProvider`
    /// in `corpus-kit-providers` for the full training API.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>` (mission 6a-ii-α) rather
    /// than a bare `Box<dyn EmbeddingProvider>`: a trained distributional
    /// provider IS an embedding provider (supertrait) and additionally exposes
    /// the trainable-basis seam, so `reconstruct` can route a basis blob back
    /// to it with no downcast.
    RandomIndexing { provider: Box<dyn TrainableEmbeddingBasis> },

    /// PPMI distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes a `PpmiProvider` from
    /// `corpus-kit-providers`, then wraps it in a `Box<dyn EmbeddingProvider>`
    /// and passes it here.  Unlike RI, PPMI requires a two-phase training:
    /// `train` accumulates counts, `finalize` computes PPMI weights.
    ///
    /// PPMI differs from RI: each context term's contribution is weighted by
    /// `max(0, log(P(t,c)/(P(t)·P(c))))`.  Stopword-like co-occurrences are
    /// down-weighted toward zero; genuinely informative associations dominate.
    ///
    /// See ADR-010 Decision B and `PpmiProvider` in `corpus-kit-providers`.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>` (mission 6a-ii-α).
    Ppmi { provider: Box<dyn TrainableEmbeddingBasis> },

    /// LSA (Latent Semantic Analysis) distributional-semantics provider.
    ///
    /// The caller constructs and trains an `LsaProvider` (term-document matrix +
    /// deterministic Jacobi SVD truncated to k dimensions) and passes it here.
    ///
    /// See ADR-010 Decision B and `LsaProvider` in `corpus-kit-providers`.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>` (mission 6a-ii-α).
    Lsa { provider: Box<dyn TrainableEmbeddingBasis> },

    /// NMF (Non-Negative Matrix Factorization) distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes an `NmfProvider` (TF-weighted
    /// term-document matrix factorized via SubstrateML's NMFAlternatingLeastSquares
    /// with tolerance=0 for fixed iteration count / bit-identical output) and
    /// passes it here.
    ///
    /// See ADR-010 Decision B and `NmfProvider` in `corpus-kit-providers`.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>` (mission 6a-ii-α).
    Nmf { provider: Box<dyn TrainableEmbeddingBasis> },

    /// FDC (Frame Decimal Classification) co-classification provider.
    ///
    /// The caller constructs an `FDCProvider` from `corpus-kit-providers` and
    /// passes it here as a `Box<dyn EmbeddingProvider>`. The provider is
    /// stateless — no training step is required. It encodes text to a
    /// deterministic float vector derived from the text's FDC classification
    /// code, such that codes sharing a longer prefix (more common ancestors in
    /// the FDC taxonomy) have higher cosine similarity.
    ///
    /// Unlike the distributional providers (RI/PPMI/LSA/NMF), FDCProvider
    /// requires no corpus training — it is ready to use immediately. The float
    /// lane is dark (returns `vec![]`) for texts the FDC engine cannot classify
    /// (UNRESOLVED). This is the expected opt-out, not an error.
    ///
    /// See ADR-010 Decision B (FDC lattice co-classification) and `FDCProvider`
    /// in `corpus-kit-providers` for the encoding details.
    Fdc { provider: Box<dyn EmbeddingProvider> },

    /// MiniLM v6 text embedding (384-dim pooled output). The kit
    /// tokenizes (FNV-1a, vocab 30522, max 128 tokens) and projects
    /// through FloatSimHash with the canonical MiniLM seed; the host
    /// closure runs the model pass on the token IDs.
    MiniLM { inference: NamedInferenceFn },

    /// MPNet base v2 text embedding (768-dim pooled output). FNV-1a
    /// tokenization (vocab 30522, max 128 tokens), MPNet projection seed.
    MPNet { inference: NamedInferenceFn },

    /// Embedding-Gemma 300M (768-dim pooled output). FNV-1a tokenization
    /// (vocab 256000, max 2048 tokens), EmbeddingGemma projection seed.
    EmbeddingGemma { inference: NamedInferenceFn },
}

impl EmbeddingModelConfig {
    /// Whether this model's provider can be trained on a corpus and
    /// reconstructed from a serialized basis.
    ///
    /// True only for the distributional cases (RI/PPMI/LSA/NMF), which carry a
    /// `Box<dyn TrainableEmbeddingBasis>`. FDC carries an embedding provider but
    /// is stateless and is NOT trainable; the deterministic and named-model
    /// cases carry no trainable basis. Mirrors Swift's `EmbeddingModel.isTrainable`.
    ///
    /// Changes no runtime behaviour on its own — it is the capability-detection
    /// helper the Corpus will use (β mission) before driving the seam.
    pub fn is_trainable(&self) -> bool {
        matches!(
            self,
            EmbeddingModelConfig::RandomIndexing { .. }
                | EmbeddingModelConfig::Ppmi { .. }
                | EmbeddingModelConfig::Lsa { .. }
                | EmbeddingModelConfig::Nmf { .. }
        )
    }

    /// Reconstruct the provider for this model from a serialized basis blob.
    ///
    /// Dispatched by the enum case. The distributional cases carry a
    /// `Box<dyn TrainableEmbeddingBasis>`, so reconstruction routes through that
    /// trait object's `reconstruct_basis` — which delegates to the right concrete
    /// type's `from_serialized_basis` (mission 6a-i) without core naming it.
    ///
    /// The deterministic and named-model cases, and the stateless FDC case, have
    /// no trained basis to restore and return `CorpusKitError::NotTrainable`
    /// rather than panicking or returning a wrong provider. Mirrors Swift's
    /// `EmbeddingModel.reconstruct(from:)`.
    ///
    /// - `basis`: the serialized basis blob (from `serialize_basis`).
    /// - Returns a reconstructed `Box<dyn EmbeddingProvider>`, or
    ///   `CorpusKitError::NotTrainable` / `CorpusKitError::DecodingFailure`.
    pub fn reconstruct(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError> {
        match self {
            EmbeddingModelConfig::RandomIndexing { provider }
            | EmbeddingModelConfig::Ppmi { provider }
            | EmbeddingModelConfig::Lsa { provider }
            | EmbeddingModelConfig::Nmf { provider } => provider.reconstruct_basis(basis),
            EmbeddingModelConfig::Deterministic
            | EmbeddingModelConfig::Fdc { .. }
            | EmbeddingModelConfig::MiniLM { .. }
            | EmbeddingModelConfig::MPNet { .. }
            | EmbeddingModelConfig::EmbeddingGemma { .. } => Err(CorpusKitError::NotTrainable(
                "embedding model is not a trainable-basis provider; reconstruction \
                 from a serialized basis is only supported for RI/PPMI/LSA/NMF"
                    .to_string(),
            )),
        }
    }
}

// Model-specific projection seeds. Byte-identical to the Swift
// `EmbeddingModel` seeds and to CorpusKitProviders' provider seeds, so a
// vector stored under either surface keys identically. Changing a seed
// re-keys all stored vectors for that model.
const MINILM_SEED: u64 = 0x4D49_4E4C_4D5F_7631; // "MINLM_v1"
const MPNET_SEED: u64 = 0x4D50_4E45_545F_7631; // "MPNET_v1"
const EMBEDDING_GEMMA_SEED: u64 = 0x454D_4247_4D5F_7631; // "EMBGM_v1"

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

// MARK: - ProviderHandle

/// The corpus's embedding provider, retaining its trainability capability.
///
/// ## Why this enum exists (the load-bearing cross-port design)
///
/// Swift's `Corpus` holds `any EmbeddingProvider` and probes trainability at
/// runtime with `as? any TrainableEmbeddingBasis`. Rust has no runtime
/// cross-cast between unrelated trait objects, AND a `Box<dyn EmbeddingProvider>`
/// upcast from a `Box<dyn TrainableEmbeddingBasis>` (as the α `open` did) has
/// PERMANENTLY LOST the trainable capability — there is no way to recover the
/// `train_on_corpus`/`serialize_basis` methods from the upcast box. `reindex`
/// and first-ingest auto-train need to retrain the live provider, so the corpus
/// must RETAIN the `Box<dyn TrainableEmbeddingBasis>` rather than upcast it
/// away. This enum is that retention: `Trainable` keeps the full trainable box;
/// `Plain` holds a non-trainable provider. `provider()` upcasts a reference to
/// `&dyn EmbeddingProvider` for the embed surface (stable trait upcasting),
/// `trainable_mut()` hands back the trainable box for an in-place retrain.
enum ProviderHandle {
    /// A trainable distributional provider (RI/PPMI/LSA/NMF). Retains the
    /// `TrainableEmbeddingBasis` capability so the corpus can retrain it.
    Trainable(Box<dyn TrainableEmbeddingBasis>),
    /// A non-trainable provider (deterministic / named-model / FDC). Carries
    /// only the embed surface; never retrained.
    Plain(Box<dyn EmbeddingProvider>),
}

impl ProviderHandle {
    /// Borrow the embed surface. For `Trainable`, upcasts the trainable box to
    /// `&dyn EmbeddingProvider` (the Rust mirror of Swift's type-erased carried
    /// provider) since `EmbeddingProvider` is a supertrait of
    /// `TrainableEmbeddingBasis`.
    fn provider(&self) -> &dyn EmbeddingProvider {
        match self {
            ProviderHandle::Trainable(b) => b.as_ref() as &dyn EmbeddingProvider,
            ProviderHandle::Plain(b) => b.as_ref(),
        }
    }

    /// Borrow the trainable box (to call `serialize_basis` /
    /// `reconstruct_trainable_basis`), or `None` when the provider is not
    /// trainable. Mirrors Swift's `provider as? any TrainableEmbeddingBasis`
    /// capability probe.
    fn as_trainable(&self) -> Option<&dyn TrainableEmbeddingBasis> {
        match self {
            ProviderHandle::Trainable(b) => Some(b.as_ref()),
            ProviderHandle::Plain(_) => None,
        }
    }
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
///
/// `chunk_source_map` is an in-memory reverse map from chunk UUID to
/// source_id (drawer ID). It is maintained in lockstep with the BM25
/// index during `ingest` and `remove`, mirroring the Swift `Corpus` actor's
/// `chunkSourceMap` dictionary. This allows `bm25_top_k_by_source` to
/// aggregate chunk-level BM25 scores to source (drawer) level without
/// a secondary storage query, matching the Swift path exactly.
pub struct Corpus {
    bundle_store: BundleStore,
    /// Mutex guards mutable BM25 index operations (index_documents / remove).
    bm25: Mutex<BM25Index>,
    /// In-memory reverse map: chunk UUID → source_id (drawer ID).
    /// Maintained in lockstep with the BM25 index during ingest and remove.
    /// Mirrors Swift's `chunkSourceMap: [UUID: String]` on the Corpus actor.
    chunk_source_map: Mutex<std::collections::HashMap<uuid::Uuid, String>>,
    vector_store: VectorStore,
    basis_store: BasisStore,
    /// Cached provider modelID. Stable for the corpus's lifetime — training
    /// mutates the basis, not the identity, and a reopened-from-blob provider is
    /// keyed by the same modelID. Caching it lets `model_id()` return `&str`
    /// without locking the provider Mutex (a Mutex-guarded `&str` cannot outlive
    /// the guard), preserving the existing `-> &str` signature and its callers.
    /// (modelVersion is read inside locked sections from the provider directly,
    /// so it is not cached.)
    model_id: String,
    /// The embedding provider, behind a `Mutex` so `reindex`/first-ingest can
    /// swap in a freshly-trained provider through a shared `&self` (the Rust
    /// mirror of Swift's actor serialization — `reindex` mutates the provider but
    /// the corpus is owned as `Arc<Corpus>` and cannot give `&mut self`). The
    /// `bm25` field already uses the same `Mutex` discipline for the same reason.
    /// A `ProviderHandle`, not a bare box, so the trainable capability survives
    /// (see `ProviderHandle`).
    provider: Mutex<ProviderHandle>,
    /// The serialized basis of a FRESH (untrained) trainable provider, captured
    /// ONLY when the corpus was built from a fresh trainable provider with no
    /// persisted basis. Each training pass (`reindex` / first-ingest)
    /// reconstructs a FRESH trainable provider from this empty-basis blob
    /// (`reconstruct_trainable_basis`), trains it from scratch, and installs it.
    /// Required because `train_on_corpus` is ADDITIVE — retraining an
    /// already-trained provider would double-count. `None` for non-trainable
    /// providers and for a reopened-from-basis corpus (already trained; not
    /// retrained). Mirrors Swift's `freshBasisBlob`.
    fresh_basis_blob: Option<Vec<u8>>,
    /// Test-only seam: when `Some`, `float_nearest` returns `StoreError(this)` on the
    /// next call, consuming the value. Never set in production code.
    ///
    /// Available only when the `test-seams` feature is enabled (declared in
    /// [dev-dependencies] by any crate that needs force-testing). Mirrors the
    /// Swift `_forcedFloatError: Error?` seam on the `Corpus` actor (gate-2).
    /// Production builds have no knowledge of this field.
    #[cfg(any(test, feature = "test-seams"))]
    pub forced_float_error: Mutex<Option<String>>,
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
        // Additive basis-persistence table (mission 6a-ii-β). Applied via
        // migrate so the table is created regardless of the other schemas'
        // version gates, exactly like the BundleStore/VectorStore pair above.
        storage
            .migrate(&BasisStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let bundle_store = BundleStore::new(Arc::clone(&storage));
        // No sidecar path for the CorpusKit Rust path — memory-only resident array.
        // The SQLite table remains the durable source of truth; the resident array
        // is rebuilt from the table on first find_nearest call.
        let vector_store = VectorStore::new(Arc::clone(&storage), None);
        let basis_store = BasisStore::new(Arc::clone(&storage));

        let bm25 = BM25Index::new(Arc::new(CorpusBm25Tokenizer));
        // Build the ProviderHandle. The trainable distributional cases are kept
        // as `Trainable(Box<dyn TrainableEmbeddingBasis>)` — NOT upcast to a
        // plain box — so `reindex`/first-ingest can retrain them in place. The
        // non-trainable cases become `Plain`. Load-on-open (below) may replace a
        // trainable handle with a reconstructed-from-basis one.
        let handle: ProviderHandle = match model {
            EmbeddingModelConfig::Deterministic => {
                ProviderHandle::Plain(Box::new(make_deterministic_provider()))
            }
            // RandomIndexing: the caller built and trained the provider externally.
            // Retain the trainable box (the distributional cases carry a
            // Box<dyn TrainableEmbeddingBasis>, mission 6a-ii-α) so the trainable
            // capability survives for reindex/first-ingest retrain.
            EmbeddingModelConfig::RandomIndexing { provider } => {
                ProviderHandle::Trainable(provider)
            }
            // Ppmi: the caller built, trained, and finalized the PpmiProvider
            // externally. Retain the trainable box.
            EmbeddingModelConfig::Ppmi { provider } => ProviderHandle::Trainable(provider),
            // Lsa: the caller built and trained the LsaProvider externally (term-
            // document matrix + Jacobi SVD). Retain the trainable box.
            EmbeddingModelConfig::Lsa { provider } => ProviderHandle::Trainable(provider),
            // Nmf: the caller built, trained, and finalized the NmfProvider externally
            // (TF matrix + NMF factorization via SubstrateML, tolerance=0 for
            // fixed iteration count / bit-identical output). Retain the trainable box.
            EmbeddingModelConfig::Nmf { provider } => ProviderHandle::Trainable(provider),
            // Fdc: the caller constructed an FDCProvider externally. FDCProvider is
            // stateless (no training required) — not trainable.
            EmbeddingModelConfig::Fdc { provider } => ProviderHandle::Plain(provider),
            EmbeddingModelConfig::MiniLM { inference } => {
                ProviderHandle::Plain(Box::new(CorpusTextProvider::new(
                    "minilm-v6",
                    "1.0.0",
                    MINILM_SEED,
                    30522,
                    128,
                    inference,
                )))
            }
            EmbeddingModelConfig::MPNet { inference } => {
                ProviderHandle::Plain(Box::new(CorpusTextProvider::new(
                    "mpnet-base-v2",
                    "1.0.0",
                    MPNET_SEED,
                    30522,
                    128,
                    inference,
                )))
            }
            EmbeddingModelConfig::EmbeddingGemma { inference } => {
                ProviderHandle::Plain(Box::new(CorpusTextProvider::new(
                    "embedding-gemma-300m",
                    "1.0.0",
                    EMBEDDING_GEMMA_SEED,
                    256_000,
                    2048,
                    inference,
                )))
            }
        };

        // Load-on-open: if the provider is trainable AND a basis was previously
        // persisted for its (model_id, model_version), reconstruct the trained
        // provider from that blob so the dense lane is trained-ready immediately
        // after restart, without re-running training on every open. A
        // non-trainable provider, or a trainable provider with no persisted
        // basis, keeps the freshly-built handle. Mirrors Swift's
        // `loadTrainedProviderIfAvailable`.
        let handle = Self::load_trained_provider_if_available(handle, &basis_store)?;

        // Cache the (stable) provider modelID for `model_id()` without locking.
        let model_id = handle.provider().model_id().to_string();

        // Capture the FRESH (untrained) basis blob when the handle is still
        // Trainable — i.e. no persisted basis was loaded (load makes it Plain).
        // reindex/first-ingest reconstruct a fresh trainable provider from this
        // blob and train from scratch (train_on_corpus is additive). A loaded /
        // non-trainable handle has no fresh-basis blob.
        let fresh_basis_blob = handle.as_trainable().map(|t| t.serialize_basis());

        Ok(Corpus {
            bundle_store,
            bm25: Mutex::new(bm25),
            chunk_source_map: Mutex::new(std::collections::HashMap::new()),
            vector_store,
            basis_store,
            model_id,
            provider: Mutex::new(handle),
            fresh_basis_blob,
            #[cfg(any(test, feature = "test-seams"))]
            forced_float_error: Mutex::new(None),
        })
    }

    /// Reconstruct a trained provider from a persisted basis on open, or return
    /// the handle unchanged. Used by both constructors.
    ///
    /// The basis is loaded only when the handle is trainable AND a row exists
    /// for its provider's (model_id, model_version). Reconstruction routes
    /// through the `TrainableEmbeddingBasis::reconstruct_basis` witness on the
    /// trainable box — core never names the concrete provider type, so layering
    /// (providers → core) is preserved. The reconstructed provider is a plain
    /// `Box<dyn EmbeddingProvider>` (a trait object cannot return `Self`), so it
    /// is held as `Plain`: it is fully trained and serves the dense lane, but a
    /// subsequent `reindex` will rebuild from a freshly-constructed trainable
    /// provider rather than mutating this restored one. (A restored-from-blob
    /// provider that needs retraining is reconstructed fresh by the caller; the
    /// β scope retrain triggers are first-ingest — which only fires when NO
    /// basis exists — and explicit `reindex`, which trains whatever trainable
    /// handle is present at open. See the reindex note for the follow-up knob.)
    fn load_trained_provider_if_available(
        handle: ProviderHandle,
        basis_store: &BasisStore,
    ) -> CorpusKitResult<ProviderHandle> {
        let trainable = match &handle {
            ProviderHandle::Trainable(b) => b,
            ProviderHandle::Plain(_) => return Ok(handle),
        };
        let model_id = trainable.model_id().to_string();
        let model_version = trainable.model_version().to_string();
        match basis_store.load(&model_id, &model_version)? {
            Some(persisted) => {
                // A basis exists — reconstruct it through the seam witness.
                // reconstruct_basis errors on a corrupt/version-mismatched blob;
                // propagate rather than silently serving an untrained provider.
                let restored = trainable.reconstruct_basis(&persisted.basis)?;
                Ok(ProviderHandle::Plain(restored))
            }
            None => Ok(handle),
        }
    }

    // MARK: - Test seams (not part of the production surface)

    /// Test-only constructor that accepts an `EmbeddingProvider` directly.
    ///
    /// Mirrors Swift's internal `init(storage:provider:)` seam. Allows test suites
    /// to inject a custom provider (e.g. one whose `embed_float` always errors) so
    /// the `UnavailableProviderOptOut` path can be force-tested without modifying
    /// production code. Available only when the `test-seams` feature is enabled.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn open_with_provider(
        storage: Arc<dyn Storage>,
        provider: Box<dyn EmbeddingProvider>,
    ) -> CorpusKitResult<Self> {
        storage
            .migrate(&BundleStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        storage
            .migrate(&BasisStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let bundle_store = BundleStore::new(Arc::clone(&storage));
        let vector_store = VectorStore::new(Arc::clone(&storage), None);
        let basis_store = BasisStore::new(Arc::clone(&storage));
        let bm25 = BM25Index::new(Arc::new(CorpusBm25Tokenizer));

        // The test seam receives a plain Box<dyn EmbeddingProvider>; Rust has no
        // runtime downcast to a trait object, so an injected provider is always
        // held as Plain (non-trainable). Load-on-open does not apply here. Cache
        // the provider modelID for `model_id()`.
        let model_id = provider.model_id().to_string();

        Ok(Corpus {
            bundle_store,
            bm25: Mutex::new(bm25),
            chunk_source_map: Mutex::new(std::collections::HashMap::new()),
            vector_store,
            basis_store,
            model_id,
            provider: Mutex::new(ProviderHandle::Plain(provider)),
            // The injected test provider is Plain (non-trainable) — no fresh blob.
            fresh_basis_blob: None,
            #[cfg(any(test, feature = "test-seams"))]
            forced_float_error: Mutex::new(None),
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

        // Maintain the chunk→source_id reverse map in lockstep with the BM25
        // index. This mirrors Swift's chunkSourceMap update in Corpus.ingest.
        // The map allows bm25_top_k_by_source to aggregate chunk-level scores
        // to source (drawer) level without a secondary storage query.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            for chunk in &chunks {
                csm.insert(chunk.id, source_id.to_string());
            }
        }

        let filed_at_secs = now_millis / 1000;

        // First-ingest auto-train (mission 6a-ii-β): when a fresh-basis blob is
        // present (trainable provider) AND no basis has been persisted yet, train
        // a fresh basis on the CURRENT corpus snapshot (which now includes the
        // just-inserted chunks) and re-embed every chunk under the trained basis.
        // This is the ONLY implicit train trigger. Subsequent ingests (once a
        // basis exists) take the fold-in path below: `embed_float` projects new
        // chunks onto the FROZEN basis without retraining — LSA/NMF cannot
        // incrementally refactor a basis, so a per-ingest retrain would be both
        // wrong and wasteful. Explicit `reindex` retrains on growth. A
        // reopened-from-blob corpus has no fresh-basis blob, so it always takes
        // the fold-in path here (already trained on open). Mirrors Swift's
        // first-ingest branch.
        if self.fresh_basis_blob.is_some() {
            let has_basis = self.basis_store.load(&self.model_id, &self.model_version()?)?.is_some();
            if !has_basis {
                let all_chunks = self.bundle_store.all_chunks()?;
                // Train a fresh basis + persist, then re-embed the whole corpus
                // under the freshly-trained basis so chunks ingested before this
                // first-ingest train share the same basis.
                self.train_and_persist_basis(&all_chunks, filed_at_secs)?;
                self.reembed_chunks(&all_chunks, filed_at_secs)?;
                return Ok(());
            }
        }

        // Fold-in path: a basis already exists (or the provider is not
        // trainable). Embed only the NEW chunks; for a trainable provider
        // `embed_float` projects them onto the frozen basis (no retrain).
        //
        // Fan-out: embed each chunk and store the vector. The
        // chunk.id == vector.drawer_id join is maintained here;
        // the caller never sees it (sealed-vector principle).
        let guard = self
            .provider
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        let provider = guard.provider();
        for chunk in &chunks {
            let engram = provider
                .embed(&chunk.text)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?;
            self.vector_store
                .add_vector(
                    &chunk.id.to_string(),
                    &engram,
                    provider.model_id(),
                    provider.model_version(),
                    filed_at_secs,
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;

            // Float lane (Lane D): RETAIN, don't recompute. The provider's
            // float vector is the SAME pooled embedding `embed` already ran
            // through the SimHash projection for the binary engram — one
            // inference pass, two stored rows. The float row is a SECOND row
            // per chunk under the same item_id at vector_index=1 (the binary
            // engram is vector_index=0), tagged kind=float32. Written only when
            // the provider supports embed_float; the default provider opts out
            // by erroring, so a non-float provider stores the binary lane only
            // and the dense float lane stays dark for it. Cosine over this true
            // embedding ranks an answer above a near-duplicate of the question,
            // which the 256-bit SimHash projection cannot.
            if let Ok(floats) = provider.embed_float(&chunk.text) {
                if !floats.is_empty() {
                    self.vector_store
                        .add_payload(
                            &chunk.id.to_string(),
                            1,
                            &VectorPayload::from_f32(&floats),
                            provider.model_id(),
                            provider.model_version(),
                            filed_at_secs,
                        )
                        .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
                }
            }
        }
        Ok(())
    }

    /// Retrain the embedding basis on the full corpus and re-embed every chunk.
    ///
    /// Rust mirror of Swift `Corpus.reindex(now:)`. When the provider is
    /// trainable (RI/PPMI/LSA/NMF):
    ///   1. gathers ALL chunk texts from the BundleStore,
    ///   2. trains the basis through the `TrainableEmbeddingBasis` seam
    ///      (`train_on_corpus`, which runs the provider's own train+finalize),
    ///   3. persists the serialized basis blob (UPSERT, one row per provider
    ///      key) with `now_millis` and the trained chunk count, and
    ///   4. re-embeds every chunk (binary lane v0 + float lane v1), REPLACING
    ///      stale vectors in place (delete-all then re-add — no duplicate rows).
    ///
    /// When the provider is NOT trainable, or the corpus was reopened from a
    /// persisted basis (Plain handle), no basis is persisted; the chunks are
    /// simply (re)embedded so the call is a well-defined vector refresh.
    ///
    /// Deterministic: `now_millis` is the only clock source — never reads the
    /// system clock. Training is a pure function of the corpus texts and the
    /// provider's fixed seeds (the seam contract).
    ///
    /// `reindex` is the EXPLICIT retrain trigger. The only other train trigger
    /// is the first-ingest auto-train in `ingest`. A growth-threshold
    /// auto-retrain (retraining once the live chunk count grows materially past
    /// `trained_chunk_count`) is a DOCUMENTED FOLLOW-UP KNOB, NOT wired here:
    /// LSA/NMF cannot incrementally refactor a frozen basis, so an automatic
    /// mid-stream retrain policy needs its own decision. The staleness anchor
    /// (`trained_chunk_count`) is persisted so future policy can compute the delta.
    ///
    /// `now_millis`: Unix epoch in milliseconds for the basis `trained_at` stamp
    /// (converted to seconds) and the re-embedded vectors' filing timestamps.
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()> {
        let chunks = self.bundle_store.all_chunks()?;
        let filed_at_secs = now_millis / 1000;

        if self.fresh_basis_blob.is_some() {
            // Train a FRESH basis on the full corpus snapshot and install the
            // trained provider. Training fresh (not in place) is required because
            // train_on_corpus is additive — see fresh_basis_blob.
            self.train_and_persist_basis(&chunks, filed_at_secs)?;
        }

        // Re-embed every chunk under the (now possibly retrained) provider,
        // replacing stale vectors. Done whether or not a retrain occurred: for a
        // non-trainable provider — or a reopened-from-blob corpus with no
        // fresh-basis blob — reindex is a vector refresh under the current basis.
        self.reembed_chunks(&chunks, filed_at_secs)?;
        Ok(())
    }

    /// Train a FRESH provider on the given chunks' texts and persist the
    /// serialized basis. Shared by `reindex` and the first-ingest auto-train.
    ///
    /// Reconstructs a fresh (untrained) trainable provider from `fresh_basis_blob`
    /// via the seam's `reconstruct_trainable_basis`, trains it from scratch on the
    /// chunk texts, installs it as the live provider, and UPSERTs the resulting
    /// basis keyed by (model_id, model_version). Training fresh — not in place —
    /// guarantees the additive `train_on_corpus` starts from scratch, so the
    /// basis is the canonical from-scratch one and reindex is idempotent
    /// (byte-for-byte parity with the Swift port). Precondition:
    /// `fresh_basis_blob` is `Some` (the caller checks this).
    fn train_and_persist_basis(&self, chunks: &[Chunk], now_secs: i64) -> CorpusKitResult<()> {
        let Some(fresh_blob) = self.fresh_basis_blob.as_ref() else {
            // Defensive: only invoked when fresh_basis_blob is Some. Nothing to
            // train otherwise.
            return Ok(());
        };
        // Reconstruct a fresh trainable provider from the empty-basis blob, train
        // it from scratch, then install it as the live serving provider.
        let mut trained = {
            let guard = self
                .provider
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
            let trainable = guard.as_trainable().ok_or_else(|| {
                CorpusKitError::NotTrainable(
                    "provider is not trainable — basis seam invariant violated".into(),
                )
            })?;
            trainable.reconstruct_trainable_basis(fresh_blob)?
        };
        let texts: Vec<&str> = chunks.iter().map(|c| c.text.as_str()).collect();
        trained.train_on_corpus(&texts);
        let blob = trained.serialize_basis();
        let model_id = trained.model_id().to_string();
        let model_version = trained.model_version().to_string();
        // Install the trained provider as the live serving provider.
        {
            let mut guard = self
                .provider
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
            *guard = ProviderHandle::Trainable(trained);
        }
        self.basis_store.upsert(&PersistedBasis {
            model_id,
            model_version,
            basis: blob,
            trained_at_secs: now_secs,
            trained_chunk_count: chunks.len(),
        })
    }

    /// Re-embed every chunk (binary v0 + float v1) under the current provider,
    /// replacing any stale vectors so no duplicate rows accumulate. Mirrors
    /// Swift `Corpus.reembedChunks`. Re-acquires the provider lock internally.
    fn reembed_chunks(&self, chunks: &[Chunk], filed_at_secs: i64) -> CorpusKitResult<()> {
        let guard = self
            .provider
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        let provider = guard.provider();
        let model_id = provider.model_id().to_string();
        for chunk in chunks {
            // Delete-all before re-adding so a chunk that already had vectors
            // under a previous basis ends up with exactly the new vectors, not a
            // mix. delete_all_vectors clears both lanes (v0 binary + v1 float).
            self.vector_store
                .delete_all_vectors(&chunk.id.to_string(), &model_id)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
            let engram = provider
                .embed(&chunk.text)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?;
            self.vector_store
                .add_vector(
                    &chunk.id.to_string(),
                    &engram,
                    provider.model_id(),
                    provider.model_version(),
                    filed_at_secs,
                )
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
            if let Ok(floats) = provider.embed_float(&chunk.text) {
                if !floats.is_empty() {
                    self.vector_store
                        .add_payload(
                            &chunk.id.to_string(),
                            1,
                            &VectorPayload::from_f32(&floats),
                            provider.model_id(),
                            provider.model_version(),
                            filed_at_secs,
                        )
                        .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
                }
            }
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
        let probe = {
            let guard = self
                .provider
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
            guard
                .provider()
                .embed(query)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?
        };

        let bm25 = self
            .bm25
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("BM25 lock poisoned".into()))?;

        hybrid_recall(
            &probe,
            query,
            &self.model_id,
            limit,
            &self.vector_store,
            &bm25,
            &self.bundle_store,
            HybridRecallConfiguration::default(),
        )
    }

    /// Embed `text` using the corpus's configured embedding model.
    ///
    /// Exposes the embedding surface so GeniusLocusKit's RecallDirector
    /// can produce a probe `Engram` for the vector lane without accessing
    /// the provider directly. Mirrors Swift `Corpus.embed(_:)`.
    ///
    /// Returns an error when the embedding provider fails (e.g. empty input
    /// routed to a model that requires non-empty text).
    pub fn embed(&self, text: &str) -> CorpusKitResult<engram_lib::Engram> {
        let guard = self
            .provider
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        guard
            .provider()
            .embed(text)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))
    }

    /// Return the model identifier this corpus was configured with.
    ///
    /// Used by the GLK vector lane to match stored vectors to the correct
    /// model so cross-model Hamming comparisons cannot occur.
    /// Mirrors Swift `Corpus.modelID`.
    pub fn model_id(&self) -> &str {
        // Returns the cached identity (stable for the corpus lifetime) so the
        // signature stays `-> &str` without locking the provider Mutex.
        &self.model_id
    }

    /// The provider's modelVersion, read under the provider lock. Used to key
    /// the basis row (model_id, model_version). Stable for the corpus lifetime;
    /// not cached because it is only needed on the basis-store paths.
    fn model_version(&self) -> CorpusKitResult<String> {
        let guard = self
            .provider
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        Ok(guard.provider().model_version().to_string())
    }

    /// Embed the query text into the pooled dense float vector (Lane D) — the
    /// probe for the dense float recall lane. Delegates to the provider's
    /// `embed_float`. Providers without a float lane error; the caller treats
    /// that as "this corpus has no float lane" and skips the dense lane rather
    /// than failing the whole recall. Empty input returns `[]`. Mirrors Swift
    /// `Corpus.embedFloat(_:)`.
    pub fn embed_float(&self, text: &str) -> CorpusKitResult<Vec<f32>> {
        let guard = self
            .provider
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        guard
            .provider()
            .embed_float(text)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))
    }

    /// Dense float nearest-neighbour recall (Lane D): embed `query` to its
    /// pooled float vector and rank stored chunks by cosine over the in-house
    /// `FloatBruteForceIndex`. Returns a `FloatLaneOutcome` that is always
    /// observable — dark lanes carry a typed reason, store errors are printed
    /// and counted via telemetry, never swallowed.
    ///
    /// Mirrors Swift `Corpus.floatNearest(query:limit:)`.
    ///
    /// **Degradation contract:** this method never panics. A dark lane is
    /// represented as `UnavailableProviderOptOut`, `UnavailableNoFloatRows`,
    /// or `EmptyQuery` — all expected. `StoreError` is NOT expected: the
    /// error is printed via `eprintln!` and emitted as
    /// `corpus.float_lane.store_error` telemetry so the failure is always
    /// observable. The query continues on other lanes.
    ///
    /// **Telemetry** (off by default — single `AtomicBool::load(Acquire)` when disabled):
    /// - `corpus.float_lane.hit`           — lane ran and returned ≥1 result.
    /// - `corpus.float_lane.dark_provider` — provider opted out.
    /// - `corpus.float_lane.dark_no_rows`  — no float rows stored.
    /// - `corpus.float_lane.store_error`   — unexpected store failure.
    pub fn float_nearest(&self, query: &str, limit: usize) -> FloatLaneOutcome {
        if limit == 0 || query.is_empty() {
            // Empty query or zero limit — no telemetry: this is a no-op call.
            return FloatLaneOutcome::EmptyQuery;
        }

        // Test-only hook: if a forced error is installed, consume it and return
        // StoreError immediately — mirrors the Swift `_forcedFloatError` seam.
        // Compiled in only when the `test-seams` feature is active; the block
        // is completely absent from production builds.
        #[cfg(any(test, feature = "test-seams"))]
        {
            let mut guard = self.forced_float_error.lock()
                .unwrap_or_else(|p| p.into_inner());
            if let Some(err_str) = guard.take() {
                drop(guard);
                eprintln!("corpus.float_nearest: find_nearest_float failed (forced) — {}", err_str);
                report!(StatSample::metric(
                    "corpus.float_lane.store_error".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::StoreError(err_str);
            }
        }

        // Attempt to embed the query via the float lane. A provider without a
        // float lane will error here — this is the expected opt-out path (not a
        // store error). Emit the dark_provider counter so callers can observe it.
        // float_nearest returns a FloatLaneOutcome (no Result), so the provider
        // Mutex is locked with a poison-tolerant fallback rather than `?`.
        let probe_result = {
            let guard = self
                .provider
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            guard.provider().embed_float(query)
        };
        let probe = match probe_result {
            Ok(p) if !p.is_empty() => p,
            Ok(_) => {
                // Provider returned an empty vector — treat as opt-out.
                report!(StatSample::metric(
                    "corpus.float_lane.dark_provider".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::UnavailableProviderOptOut;
            }
            Err(_) => {
                // Provider threw — expected opt-out (no float lane).
                // Log nothing; emit the dark_provider counter only.
                report!(StatSample::metric(
                    "corpus.float_lane.dark_provider".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::UnavailableProviderOptOut;
            }
        };

        // Over-fetch 4× at CHUNK granularity so after source-level aggregation
        // we still have at least `limit` sources — mirrors bm25_top_k_by_source.
        let matches = match self.vector_store.find_nearest_float(
            &probe,
            &self.model_id,
            limit.saturating_mul(4),
        ) {
            Ok(m) => m,
            Err(e) => {
                // Store threw — NOT expected. Print so the error is never
                // silent (mirrors Swift's corpusLog.error via OSLog). Emit
                // the store_error counter so dashboards surface the failure.
                let err_str = format!("{:?}", e);
                eprintln!("corpus.float_nearest: find_nearest_float failed — {}", err_str);
                report!(StatSample::metric(
                    "corpus.float_lane.store_error".to_string(),
                    1.0,
                    [("kit".to_string(), "CorpusKit".to_string())]
                        .into_iter().collect(),
                    {
                        use std::time::{SystemTime, UNIX_EPOCH};
                        SystemTime::now().duration_since(UNIX_EPOCH)
                            .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                    },
                ));
                return FloatLaneOutcome::StoreError(err_str);
            }
        };

        // Empty matches — no float rows stored. Expected dark outcome.
        if matches.is_empty() {
            report!(StatSample::metric(
                "corpus.float_lane.dark_no_rows".to_string(),
                1.0,
                [("kit".to_string(), "CorpusKit".to_string())]
                    .into_iter().collect(),
                {
                    use std::time::{SystemTime, UNIX_EPOCH};
                    SystemTime::now().duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                },
            ));
            return FloatLaneOutcome::UnavailableNoFloatRows;
        }

        // Aggregate chunk-level cosine to SOURCE (drawer) level via the in-memory
        // reverse map: the vector item_id is the chunk uuid string;
        // chunk_source_map resolves it to the sourceID ingested under (the drawer
        // id in the GLK context), exactly as bm25_top_k_by_source does, so float
        // hits hydrate back to the real Drawer row. A source's similarity is its
        // best (max) chunk cosine. VectorMatch.distance is the cosine DISTANCE
        // (1 − sim) ×10_000; recover sim = 1 − dist/10_000.
        let csm = match self.chunk_source_map.lock() {
            Ok(guard) => guard,
            Err(_) => return FloatLaneOutcome::UnavailableNoFloatRows,
        };
        let mut by_source: std::collections::HashMap<String, f32> =
            std::collections::HashMap::new();
        for m in &matches {
            let chunk_uuid = match uuid::Uuid::parse_str(&m.item_id) {
                Ok(u) => u,
                Err(_) => continue,
            };
            if let Some(source_id) = csm.get(&chunk_uuid) {
                let similarity = 1.0 - m.distance as f32 / 10_000.0;
                let entry = by_source
                    .entry(source_id.clone())
                    .or_insert(f32::NEG_INFINITY);
                *entry = entry.max(similarity);
            }
        }
        drop(csm);

        // After aggregation: empty by_source means no chunks in the reverse
        // map (all chunks removed). Treat as no-rows dark.
        if by_source.is_empty() {
            report!(StatSample::metric(
                "corpus.float_lane.dark_no_rows".to_string(),
                1.0,
                [("kit".to_string(), "CorpusKit".to_string())]
                    .into_iter().collect(),
                {
                    use std::time::{SystemTime, UNIX_EPOCH};
                    SystemTime::now().duration_since(UNIX_EPOCH)
                        .map(|d| d.as_secs_f64()).unwrap_or(0.0)
                },
            ));
            return FloatLaneOutcome::UnavailableNoFloatRows;
        }

        // Sort by similarity descending, source_id ascending on tie — the
        // universal deterministic tie-break — and return the top `limit`.
        let mut ranked: Vec<(String, f32)> = by_source.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });
        ranked.truncate(limit);

        // Happy path — lane ran. Emit hit counter.
        let hit_count = ranked.len();
        report!(StatSample::metric(
            "corpus.float_lane.hit".to_string(),
            hit_count as f64,
            [("kit".to_string(), "CorpusKit".to_string())]
                .into_iter().collect(),
            {
                use std::time::{SystemTime, UNIX_EPOCH};
                SystemTime::now().duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs_f64()).unwrap_or(0.0)
            },
        ));
        FloatLaneOutcome::Hits(ranked)
    }

    /// Whether this corpus's embedding provider supports the dense float lane
    /// (Lane D). True when `embed_float` returns a vector rather than erroring.
    /// Probes with a single non-empty token so the answer reflects provider
    /// capability, not input. Mirrors Swift `Corpus.supportsFloat`.
    pub fn supports_float(&self) -> bool {
        let guard = match self.provider.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        matches!(guard.provider().embed_float("x"), Ok(v) if !v.is_empty())
    }

    /// BM25 keyword top-k by source (drawer) ID.
    ///
    /// Runs the BM25 index over `query`, aggregates chunk-level scores to
    /// source (drawer) level by taking the maximum chunk score per source,
    /// and returns up to `limit` `(source_id, score)` pairs sorted descending
    /// by score (source_id ascending on tie, for determinism).
    ///
    /// The `source_id` is the value passed as `source_id` to `Corpus::ingest`.
    /// For the GLK hybrid-recall path the caller ingests with
    /// `source_id = drawer_id`, so the returned IDs are drawer IDs directly.
    ///
    /// The chunk→source reverse lookup uses the in-memory `chunk_source_map`
    /// maintained in lockstep with the BM25 index during `ingest` and `remove`,
    /// mirroring Swift's `chunkSourceMap` dictionary on the `Corpus` actor.
    ///
    /// Returns an empty Vec when the query produces no tokens, the BM25
    /// index is empty, or `limit` is zero. Never returns an error.
    ///
    /// Mirrors Swift `Corpus.bm25TopKBySource(query:limit:)`.
    pub fn bm25_top_k_by_source(&self, query: &str, limit: usize) -> Vec<(String, f32)> {
        if limit == 0 || query.is_empty() {
            return vec![];
        }

        // Chunk-level BM25 hits: (chunk_uuid, bm25_score). Over-fetch by 4×
        // before source-level aggregation so after deduplication we still have
        // at least `limit` distinct sources. Mirrors Swift's 4× over-fetch.
        // Pre-tokenise query before releasing the lock so top_k receives
        // compatible tokens from the index's own tokenizer vocabulary.
        let chunk_hits = {
            let bm25 = match self.bm25.lock() {
                Ok(guard) => guard,
                Err(_) => return vec![],
            };
            let tokens = bm25.tokenize_query(query);
            bm25.top_k(limit.saturating_mul(4), &tokens)
        };

        if chunk_hits.is_empty() {
            return vec![];
        }

        // Aggregate chunk-level scores to source level using the in-memory
        // reverse map. Take max chunk score per source (same as Swift).
        let csm = match self.chunk_source_map.lock() {
            Ok(guard) => guard,
            Err(_) => return vec![],
        };
        let mut source_scores: std::collections::HashMap<String, f32> =
            std::collections::HashMap::new();
        for (chunk_uuid, score) in &chunk_hits {
            if let Some(source_id) = csm.get(chunk_uuid) {
                let entry = source_scores.entry(source_id.clone()).or_insert(0.0_f32);
                *entry = entry.max(*score as f32);
            }
        }
        drop(csm);

        // Sort descending by score, source_id ascending on tie (deterministic).
        let mut ranked: Vec<(String, f32)> = source_scores.into_iter().collect();
        ranked.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });
        ranked.truncate(limit);
        ranked
    }

    // MARK: - Lifecycle (GLK_PROVISION_001)

    /// Destroy the entire recall index — clear BM25, chunk_source_map, and all
    /// vectors.
    ///
    /// Called by `EstateCoordinator::destroy` as part of the coordinated estate
    /// teardown path. After this call the corpus has no recall capability: BM25
    /// scores zero for all queries and the vector lane returns no results.
    ///
    /// BundleStore rows (chunks) are NOT deleted — BundleStore is append-only per
    /// PersistenceKit schema invariant. The verbatim content survives for audit;
    /// the recall capability is destroyed. Mirrors Swift `Corpus.destroyRecallIndex()`.
    pub fn destroy_recall_index(&self) -> CorpusKitResult<()> {
        // Step 1: Collect all chunk IDs and clear BM25 index.
        let all_chunks = self.bundle_store.all_chunks()?;
        let mut bm25 = self
            .bm25
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("BM25 lock poisoned".into()))?;
        for chunk in &all_chunks {
            bm25.remove(chunk.id);
        }

        // Step 2: Clear the chunk_source_map.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            csm.clear();
        }

        // Step 3: Delete all vector rows.
        self.vector_store
            .destroy_all_vectors()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("destroy_recall_index vector teardown failed: {:?}", e)))?;

        // Step 4: Wipe the persisted trained basis (mission 6a-ii-β). A
        // destroyed corpus must leave no orphaned basis row: the next open would
        // otherwise reconstruct a trained provider whose basis no longer matches
        // any stored vectors. The basis table is not append-only, so deletion is
        // permitted. Mirrors Swift `Corpus.destroyRecallIndex` step 3.
        self.basis_store.delete_all()?;

        Ok(())
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
            // Delete ALL vector_index rows for this chunk, not just the binary
            // engram at vector_index=0: the float lane (Lane D) stores a second
            // row at vector_index=1 under the same item_id. delete_all_vectors
            // removes both and invalidates the float index so a removed source
            // cannot resurface through the dense float lane.
            self.vector_store
                .delete_all_vectors(&chunk.id.to_string(), &self.model_id)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        }
        // Remove chunk entries from the reverse map so bm25_top_k_by_source
        // does not return stale source IDs for removed chunks.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            for chunk in &chunks {
                csm.remove(&chunk.id);
            }
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

    /// Return the set of drawer IDs that have at least one chunk in the store —
    /// i.e. every source_id that has been ingested. Used by `reindex_missing`
    /// to identify already-indexed drawers and skip them in the backfill.
    /// Mirrors Swift `CorpusKit.indexedSourceIDs()`.
    pub fn indexed_source_ids(&self) -> CorpusKitResult<std::collections::HashSet<String>> {
        self.bundle_store.all_source_ids()
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

// MARK: - CorpusTextProvider (named model cases)

/// `EmbeddingProvider` adapter for the named `EmbeddingModelConfig`
/// cases (MiniLM, MPNet, EmbeddingGemma). Rust mirror of Swift's
/// private `CorpusTextProvider`. Tokenizes text with the model's FNV-1a
/// vocabulary, runs the host-supplied inference closure on the token
/// IDs, and projects the resulting float vector through FloatSimHash
/// with the model's canonical seed.
///
/// Private to corpus-kit; it never appears on a public method
/// signature. Callers select a model through `EmbeddingModelConfig`.
/// The FNV-1a token fold matches Swift's `CorpusDefaultTokenizer`
/// (offset basis `2_166_136_261`, prime `1_677_619`, ids in
/// `[2, vocab_size)`), so for a shared (text -> pooled vector) the
/// engram is bit-identical to the Swift named-case path.
struct CorpusTextProvider {
    model_id: String,
    model_version: String,
    projection_seed: u64,
    /// vocab_size - 2; token ids live in [2, vocab_size).
    vocab_range: u32,
    max_tokens: usize,
    inference: NamedInferenceFn,
}

impl CorpusTextProvider {
    fn new(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
        vocab_size: u32,
        max_tokens: usize,
        inference: NamedInferenceFn,
    ) -> Self {
        CorpusTextProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            projection_seed,
            vocab_range: vocab_size - 2,
            max_tokens,
            inference,
        }
    }

    /// FNV-1a token fold matching Swift `CorpusDefaultTokenizer.tokenize`.
    fn tokenize(&self, text: &str) -> Vec<i32> {
        default_keyword_tokens(text)
            .iter()
            .take(self.max_tokens)
            .map(|word| {
                let h = word
                    .bytes()
                    .fold(2_166_136_261u32, |acc, b| (acc ^ u32::from(b)).wrapping_mul(1_677_619));
                2 + (h % self.vocab_range) as i32
            })
            .collect()
    }
}

impl EmbeddingProvider for CorpusTextProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }
    fn model_version(&self) -> &str {
        &self.model_version
    }
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        // Empty-input contract: Engram::ZERO without touching the seam.
        if text.is_empty() {
            return Ok(Engram::ZERO);
        }
        let tokens = self.tokenize(text);
        let pooled = (self.inference)(&tokens).map_err(VectorKitError::EmbeddingFailed)?;
        Ok(float_simhash::project(&pooled, self.projection_seed))
    }

    /// Float lane source (Lane D): the pooled vector `embed` projects,
    /// returned unprojected. This is the production float-lane path for
    /// the named models; without it they would have NO float lane (the
    /// trait default opts out by erroring). Empty input returns `vec![]`.
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
        let tokens = self.tokenize(text);
        (self.inference)(&tokens).map_err(VectorKitError::EmbeddingFailed)
    }
}
