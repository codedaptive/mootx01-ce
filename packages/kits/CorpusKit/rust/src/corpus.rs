//! `Corpus` — the unified RAG entry point for corpus-kit.
//!
//! Mirrors Swift's `Corpus` actor. Composes `BundleStore`,
//! `InvertedIndexStore` (SQLite-backed BM25 keyword recall), `VectorStore`,
//! and an `EmbeddingProvider` internally; no SynapseKit type appears in
//! the public API. Callers see documents and queries only.
//!
//! Concurrency: `InvertedIndexStore` wraps its own internal `Mutex<State>`;
//! `VectorStore` and `BundleStore` handle their own interior mutability
//! through `Arc<dyn Storage>`. The struct is `Send + Sync`.
//!
//! Platform note: a host-supplied provider rides in `CandleNL` on this port
//! and in the Apple NL cases on the Swift port; the kit bundles no model
//! weights and links no ML-runtime crate (external deps are prohibited).
//! The distributional cases (`RandomIndexing`, `Lsa`) are trained on the
//! estate's own content and carry their provider. The kit owns the FNV-1a
//! tokenization and the FloatSimHash projection on both ports; for any
//! shared (text -> pooled vector) the engram is bit-identical Swift/Rust
//! (SPEC § 8.2).

use crate::basis_store::{BasisStore, PersistedBasis};
use crate::corpus_provider_counts_store::CorpusProviderCountsStore;
use crate::removed_source_store::RemovedSourceStore;
use crate::bundle_store::BundleStore;
use crate::engine::inverted_index::Algorithm;
use crate::engine::inverted_index_store::InvertedIndexStore;
use crate::chunk::{Chunk, ScoredChunk};
use crate::chunker::{chunk_with_default_hlc, ChunkerConfiguration};
use crate::corpus_ingest_queue::{IngestQueueState, OnEncoded};
#[cfg(any(test, feature = "test-seams"))]
use crate::corpus_ingest_queue::IngestFailureHook;
use crate::error::{CorpusKitError, CorpusKitResult};
use crate::hybrid_recall::{recall as hybrid_recall, HybridRecallConfiguration};
use crate::tokenizer::default_keyword_tokens;
use crate::trainable_embedding_basis::{RetrainingBudget, RetrainingOutcome, RetrainingSkipReason, TrainableEmbeddingBasis};
use engram_lib::Engram;
use substrate_types::merkle_root::MerkleRoot;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use substrate_ml::float_simhash;
use synapsekit::simhash_embedding_provider::FloatSimHashEmbeddingProvider;
use synapsekit::vector_store::{VectorPayloadInput, VectorStore};
use synapsekit::EmbeddingProvider;
use synapsekit::SynapseKitError;
use synapsekit::VectorPayload;
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

/// The whole-record dense float query surface (nearest and farthest per
/// signal, the discrimination signal) and its outcome types. Compiled only
/// via the whole-record float lane.
/// float query surface and writes no float rows. Swift twin: the
/// The `CorpusKitWholeRecordDense` sidecar target exposes this surface in Swift.
pub mod float_lane;
pub use float_lane::{FloatDiscriminationSignal, FloatLaneOutcome};
pub(crate) use float_lane::discrimination_signal_from_outcome;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CorpusRetrainingReport {
    pub completed_model_ids: Vec<String>,
    pub skipped_model_ids: BTreeMap<String, RetrainingSkipReason>,
}

/// Selects the embedding model the `Corpus` struct uses internally.
///
// MARK: - Training path decision seam (Part 3)

/// Why a particular retrain slot fell back to the full corpus path instead of
/// using the maintained-counts shortcut. Recorded per modelID in the engine's
/// `training_path_decisions` seam so tests can assert the BRANCH, not just
/// the digest. Mirrors Swift `CorpusPathReason`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CorpusPathReason {
    /// No persisted basis row exists for the provider key — a genuine first
    /// training, forced or not. An untrained slot on a non-force call also
    /// records `Corpus(FirstTrain)` when it trains via the corpus path.
    /// Counts path cannot restore what was never written.
    FirstTrain,
    /// No persisted counts row exists for this provider generation.
    NoCountsRow,
    /// The provider's `finalize_from_counts()` returned `false` — counts-only
    /// basis derivation is not supported for this provider type (LSA).
    NotCountsCapable,
    /// The provider's `counts_delta_fold_safe()` returned `false` and there are
    /// pending (unsubsumed) reference deltas — folding those deltas into a restored
    /// basis would violate order-sensitivity (RI). Empty-delta restore is still
    /// available for RI; this reason fires only when a non-empty delta exists.
    /// Used exclusively by the ATTACHED engine path (ContentEngine).
    DeltaNotFoldSafe,
    /// The provider's accumulation is order-sensitive and the maintained counts'
    /// fold-order provenance cannot be proven equal to the canonical training order
    /// (standalone RI: live counts fold in ingest-arrival order; from-scratch trains
    /// in active-chunk order). Used exclusively by the STANDALONE path (Corpus).
    FoldOrderProvenanceUnknown,
    /// trainedChunkCount + |pending| != |activeIDs|: the counts snapshot plus
    /// outstanding deltas do not cover the full active population. A removed or
    /// revised identity broke the additive chain; the corpus path heals it.
    PopulationMismatch,
    /// A pending reference's contentID could not be resolved by the source. The
    /// counts path discards the attempt; the corpus path immediately heals by
    /// deleting all refs and re-publishing.
    PendingUnresolvable,
}

/// Which path the engine took for a given retrain slot. Recorded per modelID in
/// `training_path_decisions` after each `train_trainable_slots` /
/// `Corpus::reindex` call. Reset at the start of each pass.
/// Mirrors Swift `TrainingPathDecision`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrainingPathDecision {
    /// Counts path: restored the basis from the persisted counts snapshot with
    /// NO outstanding delta to fold (empty pending set). Zero corpus reads.
    CountsRestore,
    /// Counts path: restored the basis from the persisted counts snapshot AND
    /// folded `folded` pending reference bodies into the restored counts before
    /// finalizing. Exactly `folded` `source.record()` calls were made.
    CountsDeltaFold { folded: usize },
    /// Corpus path: read every active chunk text and retrained from scratch.
    /// The inner value names why the counts path was not taken.
    Corpus(CorpusPathReason),
}

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
    /// See honest semantic fusion for the rationale and `RandomIndexingProvider`
    /// in `corpus-kit-providers` for the full training API.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>` rather
    /// than a bare `Box<dyn EmbeddingProvider>`: a trained distributional
    /// provider IS an embedding provider (supertrait) and additionally exposes
    /// the trainable-basis seam, so `reconstruct` can route a basis blob back
    /// to it with no downcast.
    RandomIndexing { provider: Box<dyn TrainableEmbeddingBasis> },

    /// LSA (Latent Semantic Analysis) distributional-semantics provider.
    ///
    /// The caller constructs and trains an `LsaProvider` (term-document matrix +
    /// deterministic Jacobi SVD truncated to k dimensions) and passes it here.
    ///
    /// See honest semantic fusion and `LsaProvider` in `corpus-kit-providers`.
    ///
    /// Carries a `Box<dyn TrainableEmbeddingBasis>`.
    Lsa { provider: Box<dyn TrainableEmbeddingBasis> },

    /// Candle NL in-process inference provider (all-MiniLM-L6-v2, 384-dim).
    ///
    /// The caller loads a `CandleNLProvider` from `corpus-kit-providers`
    /// (requires model weights on disk; fetch via the provider's
    /// `fetch-model.sh`) and passes it here as a `Box<dyn EmbeddingProvider>`.
    /// No host inference seam is needed — the provider carries its own BERT
    /// model weights via the `candle` ML crate.
    ///
    /// Unlike the distributional cases, this provider is NOT trainable: it
    /// carries fixed model weights and produces embeddings without any
    /// corpus-specific training pass.
    ///
    /// # Important: GeniusLocusKit compatibility note
    ///
    /// GeniusLocusKit's `SharedContentMigration::has_trainable_provider`
    /// check uses a `matches!` pattern that does not name this variant. A
    /// pure-CandleNL ensemble (no RI/LSA) will be incorrectly
    /// classified as "has trainable provider", causing an over-eager capacity
    /// pre-check. This is benign (false-positive only) and correct for the
    /// expected use case of adding CandleNL to the default two-signal
    /// ensemble (CANDLE-ADOPT Blast Radius Report §1, INTENTIONALLY_LEFT).
    CandleNL { provider: Box<dyn EmbeddingProvider> },
}

impl EmbeddingModelConfig {
    /// Whether this model's provider can be trained on a corpus and
    /// reconstructed from a serialized basis.
    ///
    /// True only for the distributional cases (RI/LSA), which carry a
    /// `Box<dyn TrainableEmbeddingBasis>`. The deterministic and
    /// CandleNL cases carry no trainable basis.
    /// Mirrors Swift's `EmbeddingModel.isTrainable`.
    ///
    /// Changes no runtime behaviour on its own — it is the capability-detection
    /// helper the Corpus will use (β mission) before driving the seam.
    pub fn is_trainable(&self) -> bool {
        matches!(
            self,
            EmbeddingModelConfig::RandomIndexing { .. }
                | EmbeddingModelConfig::Lsa { .. }
        )
    }

    /// Reconstruct the provider for this model from a serialized basis blob.
    ///
    /// Dispatched by the enum case. The distributional cases carry a
    /// `Box<dyn TrainableEmbeddingBasis>`, so reconstruction routes through that
    /// trait object's `reconstruct_basis` — which delegates to the right concrete
    /// type's `from_serialized_basis` without core naming it.
    ///
    /// The deterministic case and the stateless CandleNL case have
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
            | EmbeddingModelConfig::Lsa { provider } => provider.reconstruct_basis(basis),
            // CandleNL carries fixed model weights loaded at provider
            // construction time; there is no corpus-trained basis to
            // reconstruct. Not trainable (CANDLE-ADOPT §1, is_trainable).
            EmbeddingModelConfig::Deterministic
            | EmbeddingModelConfig::CandleNL { .. } => Err(CorpusKitError::NotTrainable(
                "embedding model is not a trainable-basis provider; reconstruction \
                 from a serialized basis is only supported for RI/LSA"
                    .to_string(),
            )),
        }
    }
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

// ingest_batch transaction-window sizes. The corpus shares the estate's primary
// SQLite connection (single-writer at the file level), so the per-chunk commits
// bound how long a `BEGIN IMMEDIATE` holds the write lock — long enough to
// amortise the fsync/WAL-checkpoint cost ~chunk-fold, short enough not to starve
// concurrent LocusKit captures / the governor. Items are coarser than rows
// (~providers × lanes × sub-chunks per item), so the row window is larger.
// Mirrored by the Swift twin's COMMIT_CHUNK_ITEMS / COMMIT_CHUNK_ROWS.
const COMMIT_CHUNK_ITEMS: usize = 512;
const COMMIT_CHUNK_ROWS: usize = 4096;

pub(crate) fn make_deterministic_provider() -> FloatSimHashEmbeddingProvider {
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
pub(crate) enum ProviderHandle {
    /// A trainable distributional provider (RI/LSA). Retains the
    /// `TrainableEmbeddingBasis` capability so the corpus can retrain it.
    Trainable(Box<dyn TrainableEmbeddingBasis>),
    /// A non-trainable provider (deterministic / CandleNL). Carries
    /// only the embed surface; never retrained.
    Plain(Box<dyn EmbeddingProvider>),
}

impl ProviderHandle {
    /// Borrow the embed surface. For `Trainable`, upcasts the trainable box to
    /// `&dyn EmbeddingProvider` (the Rust mirror of Swift's type-erased carried
    /// provider) since `EmbeddingProvider` is a supertrait of
    /// `TrainableEmbeddingBasis`.
    pub(crate) fn provider(&self) -> &dyn EmbeddingProvider {
        match self {
            ProviderHandle::Trainable(b) => b.as_ref() as &dyn EmbeddingProvider,
            ProviderHandle::Plain(b) => b.as_ref(),
        }
    }

    /// Borrow the trainable box (to call `serialize_basis` /
    /// `reconstruct_trainable_basis`), or `None` when the provider is not
    /// trainable. Mirrors Swift's `provider as? any TrainableEmbeddingBasis`
    /// capability probe.
    pub(crate) fn as_trainable(&self) -> Option<&dyn TrainableEmbeddingBasis> {
        match self {
            ProviderHandle::Trainable(b) => Some(b.as_ref()),
            ProviderHandle::Plain(_) => None,
        }
    }
}

// MARK: - ProviderSlot

/// One held embedding provider plus its fresh-basis blob and cached modelID.
///
/// The per-provider unit the N-provider corpus fans operations over. Rust mirror of Swift's `Corpus.ProviderSlot`. `handle` is
/// behind its OWN `Mutex` so a slot's `reindex`/first-ingest can swap in a
/// freshly-trained provider through a shared `&self` without locking the other
/// slots (same actor-serialization mirror the single-provider corpus used).
/// `fresh_basis_blob` is the EMPTY (untrained) serialized basis captured ONLY
/// for a fresh trainable provider with no persisted basis (see Swift's
/// `ProviderSlot.fresh_basis_blob` doc). `model_id` is cached so `model_id()`
/// can return `&str` for the DEFAULT slot without locking. For N=1 the corpus
/// holds exactly one slot and every fan-out loop runs once — byte-identical to
/// the single-provider path.
pub(crate) struct ProviderSlot {
    /// The serving provider, behind a `Mutex` so a per-slot retrain can swap in
    /// a freshly-trained provider through `&self`. A `ProviderHandle`, not a
    /// bare box, so the trainable capability survives (see `ProviderHandle`).
    pub(crate) handle: Mutex<ProviderHandle>,
    /// The serialized EMPTY (untrained) basis of a trainable provider — the
    /// from-scratch factory. `Some` for EVERY trainable slot, whether built fresh
    /// OR reopened from a persisted basis; `None` only for non-trainable slots.
    /// Each training pass reconstructs a FRESH provider from this blob and trains
    /// from scratch (`train_on_corpus` is additive). Keeping it for a reopened-
    /// from-basis slot (rather than dropping it) is the frozen-after-restart fix:
    /// a restarted corpus can retrain on `reindex`. Mirrors Swift's
    /// `ProviderSlot.freshBasisBlob`.
    pub(crate) fresh_basis_blob: Option<Vec<u8>>,
    /// The dedicated maintained-counts accumulator for a trainable slot (P3),
    /// held SEPARATELY from `handle` behind its own `Mutex` so it can be folded
    /// through `&self`. `None` for non-trainable slots. It must NOT be the serving
    /// provider: for LSA, growing the maintained vocabulary would desync the
    /// serving provider's basis-aligned vocab from its frozen factors. Mirrors
    /// Swift's `ProviderSlot.countsAccumulator` + `countsDocumentCount`.
    pub(crate) counts: Mutex<Option<CountsState>>,
    /// Cached provider modelID. Stable for the corpus's lifetime (training
    /// mutates the basis, not the identity). Lets the corpus key the float lane
    /// and basis rows without locking the handle Mutex.
    pub(crate) model_id: String,
    /// Basis-generation anchor for coverage rows (corrective pass):
    /// stateless slots derive it from the model version; trainable slots
    /// carry the SHA-256 of the persisted basis blob (empty while
    /// untrained). Swapped alongside the handle on retrain.
    pub(crate) basis_digest: Mutex<String>,
}

/// A trainable slot's maintained-counts state: the accumulator plus its
/// document-count growth anchor. The doc count is tracked here (not read off the
/// provider) so it is uniform across RI/LSA, whose providers track
/// document count inconsistently. Mirrors the two Swift slot fields.
pub(crate) struct CountsState {
    pub(crate) accumulator: Box<dyn TrainableEmbeddingBasis>,
    pub(crate) document_count: usize,
    /// The governor-facing vocabulary-growth anchor. Persisted on the counts
    /// row in the same transaction as every reference mutation, so the
    /// threshold decision is identical before and after a process restart.
    pub(crate) vocab_anchor: usize,
    /// Hashes of terms first observed after the published counts generation.
    /// ContentEngine persists these in identity-scoped references; standalone
    /// Corpus leaves the set empty and keeps its historical accumulator path.
    pub(crate) growth_term_digests: std::collections::BTreeSet<String>,
}

// MARK: - Corpus

/// Unified RAG entry point for corpus-kit.
///
/// Rust mirror of Swift's `Corpus` actor. Composes `BundleStore`,
/// `InvertedIndexStore` (SQLite-backed BM25), `VectorStore`, and an
/// `EmbeddingProvider` internally. No SynapseKit type appears in any
/// public method signature.
///
/// Lifecycle: construct via `Corpus::open`, then call `ingest` to add
/// documents and `recall` to query. `BundleStore` is append-only, so
/// `remove` clears the recall index without deleting content rows.
///
/// `chunk_source_map` is an in-memory reverse map from chunk UUID to
/// source_id (drawer ID). It is warm-loaded from a compact (id, source_id)
/// projection on open (no body text loaded) and maintained in lockstep
/// with InvertedIndexStore during ingest and remove. This allows
/// `bm25_top_k_by_source` to aggregate chunk-level BM25 scores to source
/// (drawer) level without a secondary storage query.

/// The encode SPEED a corpus's ingest drain runs its embedding work at — the
/// user/AI-declared knob. SPEED axis ONLY; the write strategy (bulk transaction
/// vs stream) is chosen automatically by source size, never by this. Mirrors
/// Swift `EncodeSpeed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncodeSpeed {
    /// Push the cores: the embed fan-out uses all logical cores. Default — the
    /// user is waiting for content to become searchable.
    Foreground,
    /// Yield to the machine: the embed fan-out is capped to ~a quarter of cores,
    /// for very large imports where draining hard would saturate the host.
    Background,
}

pub struct Corpus {
    /// The estate's backing storage, retained so the ingest queue can choose a
    /// durable on-disk maildir backend when the estate is file-backed (SQLite)
    /// versus a transient in-memory queue when the estate is in-memory. See
    /// `mount_ingest_queue`. `pub(crate)` so the `corpus_ingest_queue` module can
    /// read the backend kind.
    pub(crate) storage: Arc<dyn Storage>,
    bundle_store: BundleStore,
    /// SQLite-backed durable inverted index — replaces the former in-memory
    /// BM25Index. Shares its own internal Mutex for thread-safety; state
    /// persists across process restarts via the iix_termfreqs + iix_doclens
    /// tables in the same SQLite file as the rest of the estate.
    inverted_index: InvertedIndexStore,
    /// In-memory reverse map: chunk UUID → source_id (drawer ID).
    /// Warm-loaded on every open via a compact (id, source_id) projection —
    /// no body text is scanned. Maintained in lockstep with InvertedIndexStore
    /// during ingest and remove. Mirrors Swift's `chunkSourceMap: [UUID: String]`.
    chunk_source_map: Mutex<std::collections::HashMap<uuid::Uuid, String>>,
    /// The estate's single dense vector store, held behind `Arc` so the
    /// composition layer (GeniusLocusKit) can BORROW this exact instance for its
    /// scored-recall vector lane via `shared_vector_store()` rather than
    /// constructing a second `VectorStore` over the same `vectors` table. One
    /// store, one resident array, one on-disk sidecar kept in sync by every write.
    vector_store: Arc<VectorStore>,
    basis_store: BasisStore,
    /// Persisted, incrementally-maintained per-provider statistics (the counts
    /// table) — Rust twin of Swift `Corpus.countsStore`. Durable home for each
    /// trainable provider's additive state (grown on write, read at refactor).
    counts_store: CorpusProviderCountsStore,
    /// Records which source ids are removed (recall-suppressed) — Rust twin of
    /// Swift `Corpus.removedSourceStore`. The chunks table is append-only, so
    /// `remove` cannot delete chunk rows; this lets every rebuild path (reindex,
    /// BM25-rebuild-on-open, first-ingest train, count) exclude removed sources
    /// so they cannot resurface. Re-ingest clears the row (reactivation).
    removed_source_store: RemovedSourceStore,
    /// The ordered per-provider slots, one per held `EmbeddingModelConfig`, in
    /// construction order. `slots[0]` is the DEFAULT signal
    /// that the single-signal entry points (`recall`, `float_nearest`, `embed`,
    /// `embed_float`, `model_id`, `supports_float`) delegate to. Never empty:
    /// every constructor builds at least one slot. For N=1 this holds exactly one
    /// slot and every fan-out loop runs once — byte-identical to the
    /// single-provider corpus. Each slot owns its handle Mutex, fresh-basis blob,
    /// and cached modelID; the VectorStore/BasisStore — already keyed by
    /// (model_id, model_version) — hold the N providers' rows side by side with
    /// no schema change. Mirrors Swift's `Corpus.slots`.
    slots: Vec<ProviderSlot>,
    /// Test-only seam: when `Some`, `float_nearest` returns `StoreError(this)` on the
    /// next call, consuming the value. Never set in production code.
    ///
    /// Available only when the `test-seams` feature is enabled (declared in
    /// [dev-dependencies] by any crate that needs force-testing). Mirrors the
    /// Swift `_forcedFloatError: Error?` seam on the `Corpus` actor (gate-2).
    /// Production builds have no knowledge of this field.
    /// The Corpus-owned ingest queue + drain worker pool. `None` until
    /// `mount_ingest_queue`. Behind a Mutex because both `&self` enqueue/drain
    /// and the background drain thread touch it. Mirrors Swift's
    /// `Corpus.ingestQueue` + `ingestDrainWorker`. See corpus_ingest_queue.rs.
    pub(crate) ingest_queue: Mutex<Option<IngestQueueState>>,
    /// Invoked AFTER each drained batch finishes ingesting, with the sourceIDs
    /// encoded. `None` when the corpus runs standalone; the orchestrator
    /// (GeniusLocusKit) sets it to roll up the touched LocusKit rooms —
    /// coordination only; CorpusKit never reaches into LocusKit itself. Mirrors
    /// Swift's `Corpus.onEncoded`.
    pub(crate) on_encoded: Mutex<Option<OnEncoded>>,
    /// The encode drain's SPEED (user/AI-declared via the import `mode`).
    /// Foreground embeds across all cores; background caps to ~a quarter (see
    /// `embed_concurrency_cap`) so a very large import leaves the machine
    /// headroom. SPEED axis only — write strategy is size-gated, not set here.
    /// Behind a Mutex for `&self` interior mutation via `set_encode_speed`.
    /// Mirrors Swift `Corpus.encodeSpeed`.
    pub(crate) encode_speed: Mutex<EncodeSpeed>,
    /// Test-only ingest failure hook (exercises the at-least-once retry path).
    /// `None` in production. Mirrors Swift's `_ingestFailureHook`; gated like
    /// `forced_float_error` so production builds carry no knowledge of it.
    #[cfg(any(test, feature = "test-seams"))]
    pub(crate) ingest_failure_hook: Mutex<Option<IngestFailureHook>>,
    #[cfg(any(test, feature = "test-seams"))]
    pub forced_float_error: Mutex<Option<String>>,
    /// Training path decisions recorded per modelID on the last
    /// `reindex` pass. Reset at the start of each pass. External tests
    /// read this via `training_path_decisions()` to assert the BRANCH taken,
    /// not only the basis digest — the gate the wave process requires.
    training_path_decisions: Mutex<BTreeMap<String, TrainingPathDecision>>,
}

impl Corpus {
    /// Set the drain's encode SPEED. Called by the import path mapping the `mode`
    /// arg of `moot_palace_import`; affects embed fan-outs sized after this call.
    /// Mirrors Swift `Corpus.setEncodeSpeed`.
    pub fn set_encode_speed(&self, speed: EncodeSpeed) {
        if let Ok(mut guard) = self.encode_speed.lock() {
            *guard = speed;
        }
    }

    /// Read-only snapshot of the training path decisions recorded on the last
    /// `reindex` pass (reset at the start of each pass). External tests read
    /// this to assert the BRANCH (CountsRestore / CountsDeltaFold / Corpus) taken
    /// for each provider, not only the resulting basis digest.
    /// Mirrors the Swift `_trainingPathDecisions` test-seam accessor.
    pub fn training_path_decisions(&self) -> BTreeMap<String, TrainingPathDecision> {
        self.training_path_decisions
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    /// Max concurrent embed operations for the current `encode_speed` (T1 QoS
    /// throttle). Foreground uses all logical cores (push hard); background uses
    /// `cores / 4` (floor 1) so a large background import leaves ~75% of the
    /// machine free for the resident daemon / the user. Uniform across
    /// Windows/Linux via `available_parallelism`; identical formula to the Swift
    /// port. The `/ 4` divisor (x=4) is the one tuning knob.
    fn embed_concurrency_cap(&self) -> usize {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1);
        let speed = self
            .encode_speed
            .lock()
            .map(|g| *g)
            .unwrap_or(EncodeSpeed::Foreground);
        match speed {
            EncodeSpeed::Foreground => cores.max(1),
            EncodeSpeed::Background => (cores / 4).max(1),
        }
    }

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
    ///
    /// This is the N=1 entry point: it delegates to `open_many` with a
    /// one-element vec, so a single-provider corpus is the degenerate case of
    /// the N-provider corpus — ONE code path, not two — and behaves
    /// byte-identically to the single-provider corpus. The signature
    /// is PRESERVED so every existing `Corpus::open` call site compiles
    /// unchanged (the N-provider back-compat mandate).
    pub fn open(storage: Arc<dyn Storage>, model: EmbeddingModelConfig) -> CorpusKitResult<Self> {
        Self::open_many(storage, vec![model])
    }

    /// Construct an N-provider Corpus against a PersistenceKit Storage.
    ///
    /// Builds one ordered provider slot per element of `models`, each keyed by
    /// its `model_id`. `models[0]` becomes the DEFAULT signal that the
    /// single-signal entry points delegate to. Every fan-out operation (ingest
    /// embed, reindex train, remove, destroy) runs across all slots, each under
    /// its own model_id — the VectorStore/BasisStore are already keyed by
    /// (model_id, model_version), so N providers' rows coexist with no schema
    /// change. Mirrors Swift's `Corpus.init(storage:models:)`.
    ///
    /// - `storage`: A `Arc<dyn Storage>` instance (schemas applied here).
    /// - `models`: One or more embedding model configurations, in priority
    ///   order. Must be non-empty; `models[0]` is the default signal. Distinct
    ///   `model_id`s are expected — two slots with the same model_id would key
    ///   the same vector/basis rows and is a caller error.
    pub fn open_many(
        storage: Arc<dyn Storage>,
        models: Vec<EmbeddingModelConfig>,
    ) -> CorpusKitResult<Self> {
        if models.is_empty() {
            return Err(CorpusKitError::StoreUnavailable(
                "Corpus requires at least one embedding model".into(),
            ));
        }

        // Apply both schemas via `migrate` (which always runs `apply_migrations_inner`
        // regardless of current version). Using `open` for both would version-gate the
        // second schema away when both kits are version 1, leaving the vectors table
        // unregistered in InMemory storage. `migrate` bypasses that gate.
        storage
            .migrate(&BundleStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // SECURITY: a populated estate opened before the VectorKit → SynapseKit
        // rename keys its vector ledger row by the old id; migrating under the
        // new id without moving that row replays the ladder from version 0
        // and folds every row's generation to 0. The rename runs first; a
        // conflicted ledger (rows under both ids) is left as it is with one
        // warning and the estate still opens — the migrate below reads its
        // ladder position from the current-id row, so nothing replays.
        VectorStore::prepare_schema_ledger(storage.as_ref())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        // Additive basis-persistence table. Applied via
        // migrate so the table is created regardless of the other schemas'
        // version gates, exactly like the BundleStore/VectorStore pair above.
        storage
            .migrate(&BasisStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // Additive maintained-counts table (P3): created via migrate like the
        // BasisStore pair so it exists regardless of the other schemas' gates.
        storage
            .migrate(&CorpusProviderCountsStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // Additive removed-sources table: created via migrate like the others.
        storage
            .migrate(&RemovedSourceStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let bundle_store = BundleStore::new(Arc::clone(&storage));
        // The binary resident array persists in the conventional `.vectors.vec`
        // sidecar beside the SQLite file (`default_sidecar_path`; None for
        // non-file backends, which then hold the array in memory only). The
        // SQLite table remains the durable source of truth: on open the sidecar
        // is loaded when its live_count matches the serving-generation binary
        // row count, otherwise rebuilt from the table on the first find_nearest.
        let vector_store = Arc::new(VectorStore::new(
            Arc::clone(&storage),
            VectorStore::default_sidecar_path(&storage),
        ));
        let basis_store = BasisStore::new(Arc::clone(&storage));
        let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
        let removed_source_store = RemovedSourceStore::new(Arc::clone(&storage));

        // Open the durable InvertedIndexStore. For SQLite backends this connects
        // to the same on-disk file and loads persisted term-freq rows — O(terms +
        // docs) cold start, no chunk body scan. For InMemory backends the connection
        // is ephemeral (InMemory storage itself does not persist across restarts).
        let inverted_index = InvertedIndexStore::open_for_storage(&storage)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        // Warm-load chunk_source_map via a compact (id, source_id) projection —
        // no body text is fetched. O(N) rows instead of O(N·body).
        let pairs = bundle_store.chunk_source_pairs()?;
        let mut initial_csm = std::collections::HashMap::with_capacity(pairs.len());
        for (uuid, source_id) in pairs {
            initial_csm.insert(uuid, source_id);
        }

        // Build one slot per model. The per-slot build is exactly the
        // single-provider construction (handle + load-on-open + fresh-blob +
        // cached modelID), so a one-element `models` produces the byte-identical
        // single-slot state.
        let mut slots: Vec<ProviderSlot> = Vec::with_capacity(models.len());
        for model in models {
            slots.push(Self::build_slot(model, &basis_store, &counts_store)?);
        }

        let corpus = Corpus {
            storage: Arc::clone(&storage),
            bundle_store,
            inverted_index,
            chunk_source_map: Mutex::new(initial_csm),
            vector_store,
            basis_store,
            counts_store,
            removed_source_store,
            slots,
            ingest_queue: Mutex::new(None),
            encode_speed: Mutex::new(EncodeSpeed::Foreground),
            on_encoded: Mutex::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            ingest_failure_hook: Mutex::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            forced_float_error: Mutex::new(None),
            training_path_decisions: Mutex::new(BTreeMap::new()),
        };

        Ok(corpus)
    }

    /// Build one `ProviderSlot` from a model config, resolving load-on-open and
    /// capturing the fresh-basis blob. Shared by `open_many` per element; the
    /// per-slot logic is exactly the single-provider construction.
    pub(crate) fn build_slot(
        model: EmbeddingModelConfig,
        basis_store: &BasisStore,
        counts_store: &CorpusProviderCountsStore,
    ) -> CorpusKitResult<ProviderSlot> {
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
            // Box<dyn TrainableEmbeddingBasis>) so the trainable
            // capability survives for reindex/first-ingest retrain.
            EmbeddingModelConfig::RandomIndexing { provider } => {
                ProviderHandle::Trainable(provider)
            }
            // Lsa: the caller built and trained the LsaProvider externally (term-
            // document matrix + Jacobi SVD). Retain the trainable box.
            EmbeddingModelConfig::Lsa { provider } => ProviderHandle::Trainable(provider),
            // CandleNL: the caller loaded a CandleNLProvider from disk and passed
            // it in as a Box<dyn EmbeddingProvider>. The provider owns its weights;
            // no training step is needed or possible (not trainable).
            EmbeddingModelConfig::CandleNL { provider } => ProviderHandle::Plain(provider),
        };

        // Capture the FRESH (untrained) basis factory and build the maintained-
        // counts accumulator BEFORE load-on-open: load converts a trainable handle
        // to Plain, so the trainable capability must be harvested here.
        //   - factory blob: captured for EVERY trainable slot (frozen-after-restart
        //     fix) so reindex can always retrain from scratch.
        //   - accumulator: a SEPARATE fresh trainable provider (reconstructed from
        //     the factory, retaining trainability), restored from the counts table
        //     if a row exists. Held apart from the serving handle so growing the
        //     maintained vocabulary never desyncs an LSA serving basis.
        let mut fresh_basis_blob: Option<Vec<u8>> = None;
        let mut counts: Option<CountsState> = None;
        if let Some(trainable) = handle.as_trainable() {
            let factory = trainable.serialize_basis();
            let mut accumulator = trainable.reconstruct_trainable_basis(&factory)?;
            let mut document_count = 0usize;
            let mut vocab_anchor = 0usize;
            if let Some(persisted) =
                counts_store.load(trainable.model_id(), trainable.model_version())?
            {
                // restore_counts_into preference order: migration-invalidation
                // sentinel → v4 integer-keyed term pair → v3 text-keyed vocab
                // rows → legacy single blob.
                //
                // Sentinel case (empty blob written by the upgrade migration):
                // restore_counts_into returns Ok(false), leaving the accumulator
                // fresh. The persisted.doc_count / vocab_size anchors are still
                // adopted from the row below (they survive the migration intact).
                // The reindex latch set by the migration then rebuilds the counts
                // on the next open-and-train cycle.
                //
                // Legacy estate case (no term table): the blob is read exactly as
                // before and the provider converts to term rows on its next persist.
                // Nothing transforms data inside the open path.
                counts_store.restore_counts_into(
                    accumulator.as_mut(),
                    trainable.model_id(),
                    trainable.model_version(),
                )?;
                document_count = persisted.document_count;
                vocab_anchor = persisted.vocab_size;
            }
            fresh_basis_blob = Some(factory);
            counts = Some(CountsState {
                accumulator,
                document_count,
                vocab_anchor,
                growth_term_digests: std::collections::BTreeSet::new(),
            });
        }

        // Load-on-open: if the provider is trainable AND a CURRENT basis is
        // persisted for its (model_id, model_version), reconstruct the trained
        // provider from that blob so the dense lane is trained-ready
        // immediately after restart, without re-running training on every
        // open. A non-trainable provider, or a trainable provider with
        // no persisted basis, keeps the freshly-built handle.
        //
        // Format-version skew is recognised BEFORE decoding: a persisted blob
        // carrying this provider's magic under another format version was
        // written by an earlier codec. It is neither decoded nor served — the
        // slot opens UNTRAINED (empty digest; the log names both versions) so
        // the open-time reconcile / `mootx01 upgrade` retrain publishes a
        // current basis over it. Mirrors Swift `Corpus.resolveProvider`.
        let served_basis: Option<PersistedBasis> = match (&fresh_basis_blob, handle.as_trainable()) {
            (Some(factory), Some(trainable)) => {
                match basis_store.load(trainable.model_id(), trainable.model_version())? {
                    Some(persisted)
                        if crate::basis_blob_frame::is_stale_version(&persisted.basis, factory) =>
                    {
                        eprintln!(
                            "[corpus] basis for {}@{} is format v{}; this build writes v{}. Serving the slot untrained until a retrain publishes a current basis.",
                            trainable.model_id(),
                            trainable.model_version(),
                            crate::basis_blob_frame::format_version(&persisted.basis).unwrap_or(0),
                            crate::basis_blob_frame::format_version(factory).unwrap_or(0)
                        );
                        None
                    }
                    other => other,
                }
            }
            _ => None,
        };
        let handle = Self::load_trained_provider(handle, served_basis.as_ref())?;

        // Cache the (stable) provider modelID for `model_id()` without locking.
        let model_id = handle.provider().model_id().to_string();

        // Basis-generation digest (corrective pass): stateless slots use a
        // version-derived constant; trainable slots the digest of the
        // PERSISTED basis blob the slot was reconstructed from (empty string
        // until trained, and empty when the persisted blob was refused for
        // format-version skew — coverage is never written untrained, so the
        // retrain re-covers every row).
        let basis_digest = if fresh_basis_blob.is_some() {
            match &served_basis {
                Some(persisted) => crate::content::content_digest_bytes(&persisted.basis),
                None => String::new(),
            }
        } else {
            format!("stateless@{}", handle.provider().model_version())
        };

        Ok(ProviderSlot {
            handle: Mutex::new(handle),
            fresh_basis_blob,
            counts: Mutex::new(counts),
            model_id,
            basis_digest: Mutex::new(basis_digest),
        })
    }

    /// Reconstruct a trained provider from the persisted basis the caller
    /// resolved for this slot, or return the handle unchanged when there is
    /// none (untrained, or refused for format-version skew) or the handle is
    /// not trainable.
    ///
    /// Reconstruction routes through the `TrainableEmbeddingBasis::reconstruct_basis`
    /// witness on the trainable box — core never names the concrete provider
    /// type, so layering (providers → core) is preserved. The reconstructed
    /// provider is a plain `Box<dyn EmbeddingProvider>` (a trait object cannot
    /// return `Self`), so it is held as `Plain`: it is fully trained and serves
    /// the dense lane, but a subsequent `reindex` rebuilds from a
    /// freshly-constructed trainable provider (the empty factory blob) rather
    /// than mutating this restored one. A corrupt blob errors here; propagate
    /// rather than silently serving an untrained provider.
    fn load_trained_provider(
        handle: ProviderHandle,
        persisted: Option<&PersistedBasis>,
    ) -> CorpusKitResult<ProviderHandle> {
        let trainable = match &handle {
            ProviderHandle::Trainable(b) => b,
            ProviderHandle::Plain(_) => return Ok(handle),
        };
        match persisted {
            Some(persisted) => {
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
        // SECURITY: same ledger rename as `open_many` — the legacy VectorKit
        // row moves to SynapseKit before the vector ladder runs.
        VectorStore::prepare_schema_ledger(storage.as_ref())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        storage
            .migrate(&VectorStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        storage
            .migrate(&BasisStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // Additive maintained-counts table (P3): created via migrate like the
        // BasisStore pair so it exists regardless of the other schemas' gates.
        storage
            .migrate(&CorpusProviderCountsStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        // Additive removed-sources table: created via migrate like the others.
        storage
            .migrate(&RemovedSourceStore::schema_declaration())
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        let bundle_store = BundleStore::new(Arc::clone(&storage));
        let vector_store = Arc::new(VectorStore::new(
            Arc::clone(&storage),
            VectorStore::default_sidecar_path(&storage),
        ));
        let basis_store = BasisStore::new(Arc::clone(&storage));
        let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
        let removed_source_store = RemovedSourceStore::new(Arc::clone(&storage));

        // Open the durable InvertedIndexStore (same pattern as open_many).
        let inverted_index = InvertedIndexStore::open_for_storage(&storage)
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        // Warm-load chunk_source_map via compact (id, source_id) projection.
        let pairs = bundle_store.chunk_source_pairs()?;
        let mut initial_csm = std::collections::HashMap::with_capacity(pairs.len());
        for (uuid, source_id) in pairs {
            initial_csm.insert(uuid, source_id);
        }

        // The test seam receives a plain Box<dyn EmbeddingProvider>; Rust has no
        // runtime downcast to a trait object, so an injected provider is always
        // held as Plain (non-trainable). Load-on-open does not apply here. Cache
        // the provider modelID for `model_id()`. The injected provider becomes
        // the corpus's single (default) slot — N=1.
        let model_id = provider.model_id().to_string();

        let corpus = Corpus {
            storage: Arc::clone(&storage),
            bundle_store,
            inverted_index,
            chunk_source_map: Mutex::new(initial_csm),
            vector_store,
            basis_store,
            counts_store,
            removed_source_store,
            slots: vec![ProviderSlot {
                handle: Mutex::new(ProviderHandle::Plain(provider)),
                // The injected test provider is Plain (non-trainable) — no fresh
                // blob, no maintained-counts accumulator.
                fresh_basis_blob: None,
                counts: Mutex::new(None),
                model_id,
                basis_digest: Mutex::new("stateless@test".to_string()),
            }],
            ingest_queue: Mutex::new(None),
            encode_speed: Mutex::new(EncodeSpeed::Foreground),
            on_encoded: Mutex::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            ingest_failure_hook: Mutex::new(None),
            #[cfg(any(test, feature = "test-seams"))]
            forced_float_error: Mutex::new(None),
            training_path_decisions: Mutex::new(BTreeMap::new()),
        };

        Ok(corpus)
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

        // (Re-)ingesting a source reactivates it: clear any prior removed-row so
        // it returns to the active set (its vectors + BM25 postings are restored
        // by this ingest). No-op when the source was never removed.
        self.removed_source_store.clear_removed(source_id)?;

        // Idempotent insert returns only the newly-inserted chunks (dedups by
        // id) so derived per-chunk state does not double-count on re-ingest.
        let inserted_chunks = self.bundle_store.insert(&chunks)?;

        // Index each chunk into the durable InvertedIndexStore (SQLite-backed).
        // Idempotent: re-indexing an existing chunk replaces its term frequencies
        // atomically. Uses the same default_keyword_tokens vocabulary as ingest
        // time so queries produce byte-identical BM25 scores.
        let now_iso = {
            let secs = now_millis / 1000;
            let dt = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs as u64);
            let secs_since_epoch = dt.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs();
            format!("{}", secs_since_epoch) // ISO-style timestamp string for the IIX API
        };
        for chunk in &chunks {
            let tokens = default_keyword_tokens(&chunk.text);
            self.inverted_index.index(&chunk.id.to_string(), &tokens, &now_iso)
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
        }

        // Maintain the chunk→source_id reverse map in lockstep with
        // InvertedIndexStore. Mirrors Swift's chunkSourceMap update in
        // Corpus.ingest. Allows bm25_top_k_by_source to aggregate chunk-level
        // scores to source (drawer) level without a secondary storage query.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            for chunk in &chunks {
                csm.insert(chunk.id, source_id.to_string());
            }
        }

        // Maintained-counts write path (P3): fold only the NEWLY-inserted chunks
        // into each trainable slot's accumulator — folding a re-ingested duplicate
        // would inflate the additive counts and the vocab-growth anchor.
        // Independent of the embed fan-out (the accumulator is separate from the
        // serving provider); persisted once at the end of this ingest.
        self.fold_chunks_into_counts(&inserted_chunks)?;

        let filed_at_secs = now_millis / 1000;

        // Fan out the embedding work across every held provider slot. For N=1
        // this loop runs once over the default slot — byte-identical to the
        // single-provider ingest. Each slot embeds independently under
        // its own model_id; the VectorStore/BasisStore keys keep the N providers'
        // rows apart. `all_chunks` is loaded lazily and shared across slots that
        // take the first-ingest or growth-retrain path (the corpus snapshot is
        // identical for every provider). Mirrors Swift's `Corpus.ingest` per-slot loop.

        // Kinsta-verified per-doc ingest degeneracy fix (2026-07-26):
        //
        // The original code trained the basis on the FIRST document only
        // (checking `!has_basis`). Any per-document ingest thereafter folded
        // new chunks onto the frozen rank-1 SVD, so all subsequent document
        // and query vectors collapsed to the same direction. Recall dropped
        // from 0.853 to 0.56 any@5 (LongMemEval 50q).
        //
        // The fix uses three-state basis logic that mirrors Swift's growth-retrain
        // approach (see `CorpusKit.swift` for the full explanation):
        //
        //   (1) No basis persisted          → first-ingest train on current corpus.
        //   (2) Basis exists, young corpus  → retrain if corpus grew to ≥ 2×
        //       (trained_chunk_count < PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD
        //        AND current_chunks >= trained_chunk_count * 2). Stops once the
        //        corpus is stable. Maximum ⌊log₂(THRESHOLD)⌋ retrains.
        //   (3) Basis stable (trained_chunk_count ≥ THRESHOLD) → fold-in only.
        //        Above the threshold only explicit `reindex` retrains.
        //
        // The constant is chosen to give ~6 auto-retrains max before the basis
        // stabilises (2^6 = 64 > 50), keeping the impatient path from re-training
        // indefinitely on large corpora while ensuring dense coverage on small ones.
        const PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD: usize = 50;

        let mut cached_all_chunks: Option<Vec<Chunk>> = None;
        // Fold-in slots are deferred to a concurrent compute phase (phase 2);
        // training (first-ingest and growth-retrain) stays serial in phase 1.
        let mut fold_in_slots: Vec<usize> = Vec::new();
        for slot_index in 0..self.slots.len() {
            // Three-state basis decision for trainable providers.
            //
            // The fresh_basis_blob presence is the trainability gate: only
            // providers that carry a factory blob (RI, LSA) enter
            // the training path. Dense-only and deterministic providers skip
            // directly to fold_in_slots.
            //
            // Borrow-checker note: model_id and model_version are extracted as
            // owned Strings in a scoped block so the slot borrow is released
            // before calling active_chunks() or train_and_persist_basis(), both
            // of which take &mut self.
            if self.slots[slot_index].fresh_basis_blob.is_some() {
                let (model_id, model_version) = {
                    let slot = &self.slots[slot_index];
                    (slot.model_id.clone(), Self::slot_model_version(slot)?)
                };

                let persisted = self
                    .basis_store
                    .load(&model_id, &model_version)?;

                let needs_retrain: bool = if persisted.is_none() {
                    // Case (1): no basis yet — first-ingest train.
                    true
                } else if let Some(ref basis) = persisted {
                    if basis.trained_chunk_count < PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD {
                        // Case (2): young basis — check 2× growth.
                        // Load corpus lazily (shared across slots for this ingest).
                        if cached_all_chunks.is_none() {
                            cached_all_chunks = Some(self.active_chunks()?);
                        }
                        let current_count = cached_all_chunks
                            .as_ref()
                            .expect("just populated")
                            .len();
                        current_count >= basis.trained_chunk_count * 2
                    } else {
                        // Case (3): stable basis — fold-in only.
                        false
                    }
                } else {
                    // persisted.is_some() but the if-let arm didn't match —
                    // impossible in safe Rust, but satisfies the exhaustiveness check.
                    false
                };

                if needs_retrain {
                    if cached_all_chunks.is_none() {
                        // Active chunks only — exclude removed sources from the train.
                        cached_all_chunks = Some(self.active_chunks()?);
                    }
                    let all_chunks = cached_all_chunks.as_ref().expect("just populated");
                    // Train a fresh basis + persist, then re-embed the whole
                    // corpus under the freshly-trained basis so all chunks share
                    // the same basis direction space.
                    self.train_and_persist_basis(slot_index, all_chunks, filed_at_secs)?;
                    self.reembed_chunks(slot_index, all_chunks, filed_at_secs)?;
                    continue;
                }
            }

            // Fold-in path: basis is stable or provider is not trainable. Embed
            // only the NEW chunks; deferred to the concurrent compute phase below
            // (`embed_float` projects new chunks onto the frozen basis — no retrain
            // — for trainable providers).
            fold_in_slots.push(slot_index);
        }

        // Phase 2: compute the fold-in slots CONCURRENTLY via scoped threads.
        // Each provider slot is independent (its own handle Mutex, model_id, and
        // rows), so one thread per slot holds that slot's lock and runs embed_pair
        // — the dominant CPU cost — in parallel. Providers are Send + Sync. The
        // WRITES stay serial: add_payloads locks the VectorStore's internal Mutex
        // and SQLite is single-writer. Determinism: each slot's rows are built in
        // chunk order (binary v0 then float v1) and written in slot order, so
        // stored rows are byte-identical to the serial path. The chunk.id ==
        // vector.item_id join is maintained here (sealed-vector principle).
        // Mirrors Swift's TaskGroup-per-fold-in-slot phase.
        if !fold_in_slots.is_empty() {
            let chunks_ref = &chunks;
            let slots_ref = &self.slots;
            let cap = self.embed_concurrency_cap();
            // Embed fold-in slots concurrently, throttled to `cap` (T1): foreground
            // fans across all cores, background to ~a quarter. Slots are processed in
            // contiguous batches of `cap` (a barrier between batches), preserving slot
            // order so the flattened write stays deterministic. Mirrors Swift's
            // boundedConcurrentMap.
            let mut per_slot_rows: Vec<Vec<VectorPayloadInput>> =
                Vec::with_capacity(fold_in_slots.len());
            for batch in fold_in_slots.chunks(cap) {
                let batch_rows: Vec<Vec<VectorPayloadInput>> = std::thread::scope(
                    |scope| -> Result<Vec<Vec<VectorPayloadInput>>, CorpusKitError> {
                        let handles: Vec<_> = batch
                            .iter()
                            .map(|&slot_index| {
                                scope.spawn(move || -> Result<Vec<VectorPayloadInput>, CorpusKitError> {
                                    let guard = slots_ref[slot_index].handle.lock().map_err(|_| {
                                        CorpusKitError::StoreUnavailable("provider lock poisoned".into())
                                    })?;
                                    let provider = guard.provider();
                                    let mut rows: Vec<VectorPayloadInput> =
                                        Vec::with_capacity(chunks_ref.len() * 2);
                                    for chunk in chunks_ref {
                                        // Single inference pass: embed_pair computes the
                                        // provider's pooled vector ONCE and returns both
                                        // the binary engram and the dense float vector.
                                        let (engram, floats) =
                                            provider.embed_pair(&chunk.text).map_err(|e| {
                                                CorpusKitError::EmbeddingFailed(format!("{:?}", e))
                                            })?;
                                        // The default build stores the engram only; the pooled float is
                                        // computed for the projection and dropped (whole-record dense rows
                                        // are a whole-record float lane write).
                                        // Binary engram row (vector_index=0) — always written.
                                        rows.push(VectorPayloadInput {
                                            item_id: chunk.id.to_string(),
                                            vector_index: 0,
                                            payload: VectorPayload::from_engram(&engram),
                                            model_id: provider.model_id().to_string(),
                                            model_version: provider.model_version().to_string(),
                                            filed_at_unix_secs: filed_at_secs,
                                        });
                                        {
                                            // Float lane (Lane D): vector_index=1 (kind=float32),
                                            // present only when the provider's float lane is live
                                            // and the chunk resolved (`floats` non-empty).
                                            if !floats.is_empty() {
                                                rows.push(VectorPayloadInput {
                                                    item_id: chunk.id.to_string(),
                                                    vector_index: 1,
                                                    payload: VectorPayload::from_f32(&floats),
                                                    model_id: provider.model_id().to_string(),
                                                    model_version: provider.model_version().to_string(),
                                                    filed_at_unix_secs: filed_at_secs,
                                                });
                                            }
                                        }
                                    }
                                    Ok(rows)
                                })
                            })
                            .collect();
                        handles
                            .into_iter()
                            .map(|h| h.join().expect("embed worker thread panicked"))
                            .collect()
                    },
                )?;
                per_slot_rows.extend(batch_rows);
            }
            // One batched write for the whole document (all provider slots
            // flattened). A single add_payloads call means a single resident-index
            // rebuild for the document instead of one per slot; under the drain's
            // deferred-index window the rebuild is deferred to burst end entirely.
            let all_rows: Vec<VectorPayloadInput> =
                per_slot_rows.into_iter().flatten().collect();
            if !all_rows.is_empty() {
                self.vector_store
                    .add_payloads(&all_rows)
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
            }
        }

        // Batch boundary: persist the maintained counts + growth anchors once for
        // this document (not per chunk).
        self.persist_maintained_counts(filed_at_secs)?;
        Ok(())
    }

    /// All chunks EXCLUDING those of removed (recall-suppressed) sources. Every
    /// chunk-replay path — reindex, the first-ingest basis train — reads this
    /// instead of `bundle_store.all_chunks` so a source cleared
    /// by `remove` cannot resurface (the chunks table is append-only, so removed
    /// chunks remain stored for audit but are filtered out here). Re-ingesting a
    /// source clears its removed-row, returning it to the active set. Mirrors
    /// Swift's `Corpus.activeChunks`.
    fn active_chunks(&self) -> CorpusKitResult<Vec<Chunk>> {
        let removed = self.removed_source_store.removed_ids()?;
        let all = self.bundle_store.all_chunks(None)?;
        if removed.is_empty() {
            return Ok(all);
        }
        Ok(all
            .into_iter()
            .filter(|c| !removed.contains(&c.source_id))
            .collect())
    }

    // MARK: - Maintained counts (incremental-counts change set, P3)

    /// Fold the written chunks into every trainable slot's maintained-counts
    /// accumulator — the per-chunk "increment as we go" write path
    /// (`add_to_counts`). Cheap (O(chunk·vocab)); non-trainable slots are skipped.
    /// Does NOT persist: persistence batches at the caller's boundary
    /// (`persist_maintained_counts`), because re-serializing the whole counts blob
    /// per chunk would be O(N·vocab) over an import. Mirrors Swift's
    /// `foldChunksIntoCounts`.
    fn fold_chunks_into_counts(&self, chunks: &[Chunk]) -> CorpusKitResult<()> {
        if chunks.is_empty() {
            return Ok(());
        }
        for slot in &self.slots {
            let mut guard = slot.counts.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("counts accumulator lock poisoned".into())
            })?;
            if let Some(state) = guard.as_mut() {
                for chunk in chunks {
                    state.accumulator.add_to_counts(&chunk.text);
                }
                state.document_count += chunks.len();
            }
        }
        Ok(())
    }

    /// The maximum maintained vocabulary size across all trainable slots — the
    /// cheap anchor the autonomic governor's vocab-growth retrain trigger reads
    /// (P3, item 5). Returns 0 when no trainable slot is present, so the trigger
    /// never fires for a non-trainable corpus. Reads the in-memory accumulators
    /// (current as of the last folded chunk). Mirrors Swift's
    /// `Corpus.maintainedVocabAnchor`.
    pub fn maintained_vocab_anchor(&self) -> CorpusKitResult<usize> {
        let mut max_vocab = 0usize;
        for slot in &self.slots {
            let guard = slot.counts.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("counts accumulator lock poisoned".into())
            })?;
            if let Some(state) = guard.as_ref() {
                max_vocab = max_vocab.max(state.accumulator.counts_vocabulary_size());
            }
        }
        Ok(max_vocab)
    }

    /// Persist every trainable slot's maintained counts + growth anchors to the
    /// counts table. Called at BATCH boundaries (end of ingest / ingest_batch /
    /// reindex), never per chunk. Keyed by the slot's serving (model_id,
    /// model_version) — the accumulator shares that key. `now_secs` is the
    /// caller's instant (determinism). Mirrors Swift's `persistMaintainedCounts`.
    fn persist_maintained_counts(&self, now_secs: i64) -> CorpusKitResult<()> {
        for slot in &self.slots {
            let guard = slot.counts.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("counts accumulator lock poisoned".into())
            })?;
            let Some(state) = guard.as_ref() else { continue };
            let model_version = Self::slot_model_version(slot)?;
            // Same layout decision as the other write paths — see
            // CorpusProviderCountsStore::persist_counts_into. This is the path
            // whose cost the batching exists to amortize: re-serializing the
            // whole counts blob per chunk is O(N*vocab) over an import, which
            // term rows remove.
            self.counts_store.persist_counts_into(
                state.accumulator.as_ref(),
                &slot.model_id,
                &model_version,
                state.document_count,
                state.accumulator.counts_vocabulary_size(),
                now_secs,
                &self.storage.row_store(),
                // Maintained-counts persist: never clears the sentinel.
                false,
            )?;
        }
        Ok(())
    }

    /// Batch ingest for the drain worker pool: ingest many sources with the
    /// embedding COMPUTE parallelized across documents (the CPU-bound cost) while
    /// the chunk/BM25/bundle/vector WRITES stay serial (single-writer). Output is
    /// identical to calling `ingest` once per item — same chunks, same vectors,
    /// same content-addressed idempotency. This is the cross-document parallelism
    /// the per-corpus ingest drain drives (the 1.0 separate-pump fix; the global
    /// cross-estate cap is the 1.1 central drain master,
    /// the deferred process-global drain master). Rust mirror of Swift
    /// `Corpus.ingestBatch`.
    ///
    /// First-ingest training cannot run concurrently (it mutates a slot's basis),
    /// so when a trainable slot still lacks a persisted basis the batch trains it
    /// ONCE on the full just-chunked corpus (Phase 1b) before the parallel embed —
    /// not item-by-item, which would train on a single document and yield a
    /// degenerate basis. Every subsequent batch (basis frozen) skips the bootstrap.
    ///
    /// Each item is `(text, source_id, now_millis)`.
    /// IMPORT-ONLY ingest — the DISCRETE bulk-import drain path, kept separate
    /// from `ingest_batch` (which the near-realtime daily-driving encode drain
    /// uses for live single captures). This does ONLY chunk + bundle + BM25 +
    /// source-map + maintained-counts (Windows 1 & 2 of `ingest_batch`). It does
    /// NOT bootstrap-train the basis (Phase 1b) and does NOT embed (Phase 2 /
    /// add_payloads): a bulk import re-trains the basis on the WHOLE corpus and
    /// embeds every chunk ONCE at the end (`Corpus::reindex`), so the encode
    /// drain's embed-now / bootstrap-train-as-you-go work — correct for a single
    /// live capture — is pure repeated waste for an import. Keeping the two paths
    /// discrete leaves daily-driving `ingest_batch` untouched.
    pub fn ingest_batch_import(&self, items: &[(String, String, i64)]) -> CorpusKitResult<()> {
        if items.is_empty() {
            return Ok(());
        }
        // EXT-4 SHARDED PIPELINE (durable SQLite estates): parallelize the
        // compute AND the postings writes, serialize only the estate writer.
        //
        //   Phase P (parallel workers, ~IMPORT_SHARD_ITEMS items each): chunk +
        //   tokenize (the CPU compute) and write each slice's BM25 postings into
        //   a PRIVATE shard SQLite file beside the estate (encrypted with the
        //   same install key — the sibling db.key applies). No writer contention:
        //   N shards = N concurrent writers on N files.
        //
        //   Phase S (single writer): bundle rows through the estate connection
        //   (unchanged — content-addressing/row-crypto/counts machinery), then
        //   ONE attach+INSERT..SELECT..ORDER BY merge per shard into the durable
        //   iix tables (SQLite copies internally, key-ordered → append-locality)
        //   and one in-memory fold of the worker-computed tf maps.
        //
        // The serial per-item path remains for in-memory estates (no shard files;
        // the IIX connection is ephemeral :memory: and cannot ATTACH across).
        let shard_target = match &self.storage.configuration().backend {
            persistence_kit::BackendConfiguration::Sqlite { path, .. } => {
                let p = std::path::Path::new(path);
                match (p.parent(), p.file_stem()) {
                    // Estate db stem stamps every shard name so two estates
                    // sharing one directory can never collide on a shard path
                    // (codex b92be5bc).
                    (Some(dir), Some(stem)) => {
                        Some((dir.to_path_buf(), stem.to_string_lossy().to_string()))
                    }
                    _ => None,
                }
            }
            _ => None,
        };
        if let Some((dir, stem)) = shard_target {
            return self.ingest_batch_import_sharded(items, &dir, &stem);
        }
        self.ingest_batch_import_serial(items)
    }

    /// Items per import work slice. Fixed (not n/cores) so a 10k pass yields
    /// more slices than workers — better load balancing, same rationale as
    /// REEMBED_BATCH_SIZE. Slice COUNT scales with import size; worker/thread
    /// count does NOT — it is capped at available_parallelism() in
    /// `ingest_batch_import_sharded` (each worker owns ONE shard file and pulls
    /// slices from a shared counter).
    const IMPORT_SHARD_ITEMS: usize = 2500;

    /// The EXT-4 sharded import body — see `ingest_batch_import`.
    /// `estate_stem` is the estate db filename stem; it stamps shard names.
    fn ingest_batch_import_sharded(
        &self,
        items: &[(String, String, i64)],
        shard_dir: &std::path::Path,
        estate_stem: &str,
    ) -> CorpusKitResult<()> {
        use crate::engine::inverted_index_store::IngestPostingsShard;

        // Sweep stale shards from a CRASHED prior import of THIS estate (name
        // prefix carries the estate stem, so other estates' live shards in a
        // shared directory are never touched). Safe under the import drain
        // lease, which serializes imports per estate; a concurrent same-estate
        // import is a caller bug that the exclusive create below surfaces.
        let stale_prefix = format!("import-shard-{estate_stem}-");
        if let Ok(entries) = std::fs::read_dir(shard_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with(&stale_prefix) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }

        // Phase P — parallel, BOUNDED: chunk + tokenize + shard-write on a pool
        // of at most available_parallelism() workers (full width — import is a
        // batch job). Each worker owns ONE estate-stamped shard file, created
        // with exclusive semantics, and pulls slice INDICES from a shared atomic
        // counter (work-stealing). The earlier shape spawned one thread AND one
        // shard file per 2500-item slice — thread count scaled with import size
        // (unbounded, same local-DoS class as codex 3399b904) and shard names
        // were `import-shard-{i}.sqlite`, predictable and estate-agnostic
        // (codex b92be5bc). Slice outputs carry their index and are reassembled
        // in slice order, so bundle rows and postings folds are byte-identical
        // to the serial loop (chunk_with_default_hlc is a pure function of its
        // arguments — fresh HLC generator per call).
        type SlicePostings = Vec<(String, std::collections::HashMap<String, usize>, usize)>;
        type SliceOut = (usize, Vec<Vec<Chunk>>, SlicePostings);
        type WorkerOut = (Option<String>, Vec<SliceOut>);
        let slices: Vec<&[(String, String, i64)]> =
            items.chunks(Self::IMPORT_SHARD_ITEMS).collect();
        let n_slices = slices.len();
        let workers = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .min(n_slices.max(1));
        let slices_ref = &slices;
        let next_slice = std::sync::atomic::AtomicUsize::new(0);
        let next_ref = &next_slice;
        let worker_outs: Vec<WorkerOut> = std::thread::scope(
            |scope| -> CorpusKitResult<Vec<WorkerOut>> {
                let handles: Vec<_> = (0..workers)
                    .map(|w| {
                        let shard_path = shard_dir
                            .join(format!("import-shard-{estate_stem}-w{w}.sqlite"))
                            .to_string_lossy()
                            .to_string();
                        scope.spawn(move || -> Result<WorkerOut, rusqlite::Error> {
                            // Lazy shard creation: a worker that never claims a
                            // slice leaves no file behind.
                            let mut shard: Option<IngestPostingsShard> = None;
                            let mut outs: Vec<SliceOut> = Vec::new();
                            loop {
                                let i = next_ref
                                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                if i >= slices_ref.len() {
                                    break;
                                }
                                if shard.is_none() {
                                    shard = Some(IngestPostingsShard::create(&shard_path)?);
                                }
                                let slice = slices_ref[i];
                                let mut per_item: Vec<Vec<Chunk>> =
                                    Vec::with_capacity(slice.len());
                                let mut postings: SlicePostings = Vec::new();
                                for (text, source_id, now_millis) in slice.iter() {
                                    let chunks = chunk_with_default_hlc(
                                        text,
                                        source_id,
                                        ChunkerConfiguration::default(),
                                        *now_millis,
                                    );
                                    for chunk in &chunks {
                                        let tokens = default_keyword_tokens(&chunk.text);
                                        if tokens.is_empty() {
                                            continue;
                                        }
                                        let mut tf: std::collections::HashMap<String, usize> =
                                            std::collections::HashMap::new();
                                        for t in &tokens {
                                            *tf.entry(t.clone()).or_insert(0) += 1;
                                        }
                                        let chunk_id = chunk.id.to_string();
                                        shard
                                            .as_mut()
                                            .expect("shard created on first claimed slice")
                                            .add(&chunk_id, &tf, tokens.len());
                                        postings.push((chunk_id, tf, tokens.len()));
                                    }
                                    per_item.push(chunks);
                                }
                                outs.push((i, per_item, postings));
                            }
                            let finished = match shard {
                                Some(s) => Some(s.finish()?),
                                None => None,
                            };
                            Ok((finished, outs))
                        })
                    })
                    .collect();
                let mut outs = Vec::with_capacity(handles.len());
                for h in handles {
                    match h.join() {
                        Ok(res) => outs.push(res.map_err(|e| {
                            CorpusKitError::StoreUnavailable(format!("import shard: {e:?}"))
                        })?),
                        Err(_) => {
                            return Err(CorpusKitError::StoreUnavailable(
                                "import shard worker panicked".into(),
                            ))
                        }
                    }
                }
                Ok(outs)
            },
        )?;

        // Reassemble slice outputs in slice order (workers claim slices in
        // arbitrary interleave; the index restores the serial-loop order) and
        // collect the per-worker shard paths for the merge pass.
        let mut shard_paths: Vec<String> = Vec::new();
        let mut slice_slots: Vec<Option<(Vec<Vec<Chunk>>, SlicePostings)>> =
            (0..n_slices).map(|_| None).collect();
        for (path, outs) in worker_outs {
            if let Some(p) = path {
                shard_paths.push(p);
            }
            for (i, per_item, postings) in outs {
                slice_slots[i] = Some((per_item, postings));
            }
        }
        let slice_outs: Vec<(Vec<Vec<Chunk>>, SlicePostings)> = slice_slots
            .into_iter()
            .enumerate()
            .map(|(i, slot)| {
                slot.ok_or_else(|| {
                    CorpusKitError::StoreUnavailable(format!(
                        "import slice {i} was never produced (worker exited early)"
                    ))
                })
            })
            .collect::<CorpusKitResult<_>>()?;

        // Phase S — single writer. Window 1: bundle rows through the estate
        // connection, committed per COMMIT_CHUNK_ITEMS (same bracket + same
        // side-effects as the serial path: reactivation, source map, counts).
        let row_store = self.storage.row_store();
        let all_chunks: Vec<(&str, &Vec<Chunk>)> = slice_outs
            .iter()
            .zip(slices.iter())
            .flat_map(|((per_item, _), slice)| {
                slice
                    .iter()
                    .map(|(_, source_id, _)| source_id.as_str())
                    .zip(per_item.iter())
            })
            .collect();
        for window in all_chunks.chunks(COMMIT_CHUNK_ITEMS) {
            row_store
                .begin_transaction()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> CorpusKitResult<()> {
                for (source_id, chunks) in window {
                    if chunks.is_empty() {
                        continue;
                    }
                    self.removed_source_store.clear_removed(source_id)?;
                    let inserted_chunks = self.bundle_store.insert(chunks)?;
                    if let Ok(mut csm) = self.chunk_source_map.lock() {
                        for chunk in chunks.iter() {
                            csm.insert(chunk.id, source_id.to_string());
                        }
                    }
                    self.fold_chunks_into_counts(&inserted_chunks)?;
                }
                Ok(())
            })();
            match res {
                Ok(()) => row_store
                    .commit_transaction()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = row_store.rollback_transaction();
                    return Err(e);
                }
            }
        }

        // Shard merges: one attach + sorted INSERT..SELECT per worker shard
        // (durable tables), then one in-memory fold of the worker-computed
        // postings in slice order. Merge order does not affect the durable
        // tables (keyed INSERT OR REPLACE); the fold is per-chunk keyed, folded
        // in slice order for exact serial-path equivalence.
        for path in &shard_paths {
            self.inverted_index
                .merge_shard(path)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("shard merge: {e:?}")))?;
            IngestPostingsShard::remove_file(path);
        }
        for (_, postings) in &slice_outs {
            self.inverted_index
                .fold_postings(postings)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("postings fold: {e:?}")))?;
        }
        // NO bootstrap train, NO embed — Corpus::reindex trains on the full
        // corpus and embeds every chunk ONCE after coverage completes.
        Ok(())
    }

    /// The serial import body — in-memory estates only (no shard files; the IIX
    /// connection is ephemeral and cannot ATTACH across connections).
    fn ingest_batch_import_serial(&self, items: &[(String, String, i64)]) -> CorpusKitResult<()> {
        // BM25 index work deferred to window 2: (chunk_id, tokens, now_secs_str).
        let mut index_jobs: Vec<(String, Vec<String>, String)> = Vec::new();

        // Window 1 — storage connection (bundle insert + source reactivation +
        // maintained-counts fold), committed per COMMIT_CHUNK_ITEMS so the held
        // write lock stays bounded (same rationale as ingest_batch Window 1).
        let row_store = self.storage.row_store();
        for item_chunk in items.chunks(COMMIT_CHUNK_ITEMS) {
            row_store
                .begin_transaction()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> CorpusKitResult<()> {
                for (text, source_id, now_millis) in item_chunk {
                    let chunks = chunk_with_default_hlc(
                        text,
                        source_id,
                        ChunkerConfiguration::default(),
                        *now_millis,
                    );
                    if !chunks.is_empty() {
                        self.removed_source_store.clear_removed(source_id)?;
                        let inserted_chunks = self.bundle_store.insert(&chunks)?;
                        let now_str = format!("{}", now_millis / 1000);
                        for chunk in &chunks {
                            let tokens = default_keyword_tokens(&chunk.text);
                            index_jobs.push((chunk.id.to_string(), tokens, now_str.clone()));
                        }
                        if let Ok(mut csm) = self.chunk_source_map.lock() {
                            for chunk in &chunks {
                                csm.insert(chunk.id, source_id.clone());
                            }
                        }
                        self.fold_chunks_into_counts(&inserted_chunks)?;
                    }
                }
                Ok(())
            })();
            match res {
                Ok(()) => row_store
                    .commit_transaction()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = row_store.rollback_transaction();
                    return Err(e);
                }
            }
        }

        // Window 2 — BM25 sidecar (private connection), committed per chunk.
        for job_chunk in index_jobs.chunks(COMMIT_CHUNK_ITEMS) {
            self.inverted_index
                .begin_batch()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> Result<(), rusqlite::Error> {
                for (chunk_id, tokens, now_str) in job_chunk {
                    self.inverted_index.index(chunk_id, tokens, now_str)?;
                }
                Ok(())
            })();
            match res {
                Ok(()) => self
                    .inverted_index
                    .commit_batch()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = self.inverted_index.rollback_batch();
                    return Err(CorpusKitError::StoreUnavailable(e.to_string()));
                }
            }
        }
        // NO bootstrap train, NO embed — Corpus::reindex trains on the full corpus
        // and embeds every chunk ONCE after coverage completes.
        Ok(())
    }

    pub fn ingest_batch(&self, items: &[(String, String, i64)]) -> CorpusKitResult<()> {
        if items.is_empty() {
            return Ok(());
        }

        // Phase 1 (serial): chunk + bundle + BM25 + source map per item. Two
        // sequential transaction windows so a bulk batch commits PER CHUNK
        // instead of autocommitting per item/chunk. Live driving a ~49.5k-drawer
        // drain showed the worker thread pinned in sqlite3_step →
        // PagerCommitPhaseOne + WalCheckpoint (per-statement commits +
        // WAL-checkpoint storms), idling the cores regardless of embed
        // parallelism.
        //
        // The window is CHUNKED, not one transaction over the whole batch: the
        // corpus shares the estate's PRIMARY SQLite connection (provision passes
        // corpus_storage = None), and SQLite is single-writer at the file level,
        // so a `BEGIN IMMEDIATE` held across thousands of rows would starve
        // concurrent LocusKit captures / the governor (busy_timeout → BUSY).
        // Committing every COMMIT_CHUNK_ITEMS bounds the held write lock to a few
        // milliseconds while still amortising the fsync/checkpoint ~chunk-fold.
        //
        // Window 1 brackets the storage-connection writes (bundle insert + source
        // reactivation + maintained-counts fold); window 2 brackets the BM25
        // sidecar's PRIVATE connection. They run sequentially — two held write
        // locks on the two connections (same file) on one thread would deadlock.
        let mut per_item_chunks: Vec<Vec<Chunk>> = Vec::with_capacity(items.len());
        // BM25 index work deferred to window 2: (chunk_id, tokens, now_secs_str).
        let mut index_jobs: Vec<(String, Vec<String>, String)> = Vec::new();

        // Window 1 — storage connection, committed per item-chunk.
        let row_store = self.storage.row_store();
        for item_chunk in items.chunks(COMMIT_CHUNK_ITEMS) {
            row_store
                .begin_transaction()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> CorpusKitResult<()> {
                for (text, source_id, now_millis) in item_chunk {
                    let chunks = chunk_with_default_hlc(
                        text,
                        source_id,
                        ChunkerConfiguration::default(),
                        *now_millis,
                    );
                    if !chunks.is_empty() {
                        // (Re-)ingesting reactivates the source (clears any removed-row).
                        self.removed_source_store.clear_removed(source_id)?;
                        // Idempotent insert returns only newly-inserted chunks; fold
                        // counts over those (a re-ingested duplicate must not inflate them).
                        let inserted_chunks = self.bundle_store.insert(&chunks)?;
                        // Defer the durable BM25 writes to window 2 (separate
                        // connection): collect each chunk's tokens now while we hold
                        // its text.
                        let now_str = format!("{}", now_millis / 1000);
                        for chunk in &chunks {
                            let tokens = default_keyword_tokens(&chunk.text);
                            index_jobs.push((chunk.id.to_string(), tokens, now_str.clone()));
                        }
                        if let Ok(mut csm) = self.chunk_source_map.lock() {
                            for chunk in &chunks {
                                csm.insert(chunk.id, source_id.clone());
                            }
                        }
                        // Maintained-counts write path (P3): fold this item's NEWLY-inserted
                        // chunks into each trainable slot's accumulator. Persisted ONCE at
                        // the end of the batch (the batch boundary) — never per chunk.
                        self.fold_chunks_into_counts(&inserted_chunks)?;
                    }
                    per_item_chunks.push(chunks);
                }
                Ok(())
            })();
            match res {
                Ok(()) => row_store
                    .commit_transaction()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = row_store.rollback_transaction();
                    return Err(e);
                }
            }
        }

        // Window 2 — BM25 sidecar (private connection), committed per chunk.
        // Runs after window 1 has committed and released the storage write lock.
        for job_chunk in index_jobs.chunks(COMMIT_CHUNK_ITEMS) {
            self.inverted_index
                .begin_batch()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> Result<(), rusqlite::Error> {
                for (chunk_id, tokens, now_str) in job_chunk {
                    self.inverted_index.index(chunk_id, tokens, now_str)?;
                }
                Ok(())
            })();
            match res {
                Ok(()) => self
                    .inverted_index
                    .commit_batch()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = self.inverted_index.rollback_batch();
                    return Err(CorpusKitError::StoreUnavailable(e.to_string()));
                }
            }
        }

        // Phase 1b — batch-aware first-basis bootstrap (mirror Swift). When a
        // trainable slot (RI/LSA) still has no persisted basis, train it
        // ONCE on the FULL corpus now in the bundle store — every chunk just
        // inserted, not the first item alone. The prior per-item serial fallback
        // trained on item 1's chunks (often a single document) → a degenerate
        // basis (e.g. a rank-1 LSA SVD that folds in to zero). Training is serial
        // (it mutates the slot handle) and runs BEFORE the parallel embed below,
        // which then folds every chunk onto the trained basis. A subsequent
        // full-corpus reindex still retrains on the complete corpus once a bulk
        // import has drained — this only fixes first-batch quality.
        let needs_bootstrap = self.slots.iter().try_fold(false, |acc, slot| {
            if acc {
                return Ok::<bool, CorpusKitError>(true);
            }
            if slot.fresh_basis_blob.is_some() {
                let has_basis = self
                    .basis_store
                    .load(&slot.model_id, &Self::slot_model_version(slot)?)?
                    .is_some();
                Ok(!has_basis)
            } else {
                Ok(false)
            }
        })?;
        if needs_bootstrap {
            // Active chunks only — exclude removed sources from the first-basis train.
            let all_chunks = self.active_chunks()?;
            if !all_chunks.is_empty() {
                let now_secs = items[0].2 / 1000;
                for slot_index in 0..self.slots.len() {
                    if self.slots[slot_index].fresh_basis_blob.is_none() {
                        continue;
                    }
                    let already = self
                        .basis_store
                        .load(
                            &self.slots[slot_index].model_id,
                            &Self::slot_model_version(&self.slots[slot_index])?,
                        )?
                        .is_some();
                    if !already {
                        // Trains on the full chunk set and installs the trained
                        // provider into the slot handle, so the embed phase folds in.
                        self.train_and_persist_basis(slot_index, &all_chunks, now_secs)?;
                    }
                }
            }
        }

        // Lock every slot handle ONCE up front and collect the provider refs.
        // Locking inside each item-thread would serialize on each slot's handle
        // Mutex (the documented trap); locking once and sharing the Send + Sync
        // `&dyn EmbeddingProvider` lets the per-item threads run truly parallel.
        let guards: Vec<_> = self
            .slots
            .iter()
            .map(|s| {
                s.handle.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable("provider lock poisoned".into())
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let providers: Vec<&dyn EmbeddingProvider> =
            guards.iter().map(|g| g.provider()).collect();
        let providers_ref = &providers;

        // Phase 2 (parallel across items): fan the embeds over `cap` worker
        // threads, each taking ONE CONTIGUOUS SLICE of ~len/cap items.
        //
        // The earlier model spawned one short-lived scoped thread PER ITEM in
        // cap-sized barriered batches; profiling a bulk drain showed ~⅓ of the
        // phase spent in thread spawn/join and only ~2.8 effective cores of 18 —
        // each thread did a single cheap item's embed and joined before the batch
        // siblings overlapped. Here `cap` threads are spawned ONCE for the whole
        // batch and each embeds its slice serially, so the spawn cost is paid
        // `cap` times total and every worker runs continuously. Slices are
        // contiguous and joined in spawn order, so the flattened rows are
        // byte-identical to the per-item serial path (determinism preserved).
        let cap = self.embed_concurrency_cap();
        let n = per_item_chunks.len();
        // Items per worker: ceil(n / cap) → at most `cap` contiguous slices.
        let slice_len = ((n + cap - 1) / cap).max(1);
        let per_item_rows: Vec<Vec<VectorPayloadInput>> = std::thread::scope(
            |scope| -> Result<Vec<Vec<VectorPayloadInput>>, CorpusKitError> {
                let handles: Vec<_> = per_item_chunks
                    .chunks(slice_len)
                    .enumerate()
                    .map(|(s, slice)| {
                        let base = s * slice_len;
                        scope.spawn(
                            move || -> Result<Vec<Vec<VectorPayloadInput>>, CorpusKitError> {
                                let mut slice_rows: Vec<Vec<VectorPayloadInput>> =
                                    Vec::with_capacity(slice.len());
                                for (local, chunks) in slice.iter().enumerate() {
                                    let filed_at_secs = items[base + local].2 / 1000;
                                    let mut rows: Vec<VectorPayloadInput> = Vec::with_capacity(
                                        chunks.len() * providers_ref.len() * 2,
                                    );
                                    for provider in providers_ref.iter() {
                                        for chunk in chunks {
                                            // Single inference pass: embed_pair computes the
                                            // provider's pooled vector ONCE and returns both
                                            // the binary engram and the dense float vector.
                                            let (engram, floats) = provider
                                                .embed_pair(&chunk.text)
                                                .map_err(|e| {
                                                    CorpusKitError::EmbeddingFailed(format!(
                                                        "{:?}", e
                                                    ))
                                                })?;
                                            // The default build stores the engram only; the pooled float is
                                            // computed for the projection and dropped (whole-record dense rows
                                            // are a whole-record float lane write).
                                            rows.push(VectorPayloadInput {
                                                item_id: chunk.id.to_string(),
                                                vector_index: 0,
                                                payload: VectorPayload::from_engram(&engram),
                                                model_id: provider.model_id().to_string(),
                                                model_version: provider.model_version().to_string(),
                                                filed_at_unix_secs: filed_at_secs,
                                            });
                                            {
                                                if !floats.is_empty() {
                                                    rows.push(VectorPayloadInput {
                                                        item_id: chunk.id.to_string(),
                                                        vector_index: 1,
                                                        payload: VectorPayload::from_f32(&floats),
                                                        model_id: provider.model_id().to_string(),
                                                        model_version: provider
                                                            .model_version()
                                                            .to_string(),
                                                        filed_at_unix_secs: filed_at_secs,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                    slice_rows.push(rows);
                                }
                                Ok(slice_rows)
                            },
                        )
                    })
                    .collect();
                // Join in spawn order → slices reassemble in item order.
                let mut all: Vec<Vec<VectorPayloadInput>> = Vec::with_capacity(n);
                for h in handles {
                    all.extend(h.join().expect("embed worker thread panicked")?);
                }
                Ok(all)
            },
        )?;
        drop(guards);

        // Phase 3 (serial): ONE batched write for the whole drain batch (every
        // item's rows flattened, preserving item-then-chunk order). A single
        // add_payloads call collapses the per-item resident-index rebuilds into
        // one; under the drain's deferred-index window even that one rebuild is
        // deferred to burst end (publish_resident_index), so a bulk import pays
        // O(N) total index work instead of O(N²).
        let all_rows: Vec<VectorPayloadInput> = per_item_rows.into_iter().flatten().collect();

        // Phase 3 write window — storage connection: the batch's vector upserts
        // (~providers × lanes × chunks rows), committed per row-chunk instead of
        // every row autocommitting. Chunked for the same shared-connection reason
        // as Phase 1 (bound the held write lock). The resident vector-index
        // rebuild stays deferred to publish_vector_index() at burst end, so each
        // window pays only the row writes; add_payloads in deferred mode appends
        // to the resident array across calls and is safe to call per chunk.
        let write_store = self.storage.row_store();
        for row_chunk in all_rows.chunks(COMMIT_CHUNK_ROWS) {
            write_store
                .begin_transaction()
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            let res = (|| -> CorpusKitResult<()> {
                self.vector_store
                    .add_payloads(row_chunk)
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))
            })();
            match res {
                Ok(()) => write_store
                    .commit_transaction()
                    .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?,
                Err(e) => {
                    let _ = write_store.rollback_transaction();
                    return Err(e);
                }
            }
        }

        // Batch boundary: persist the maintained counts + growth anchors once for
        // the whole drained batch (a single counts-blob write; autocommits).
        // `items[0].2` (first item's now) matches the first-basis bootstrap's
        // training instant above.
        self.persist_maintained_counts(items[0].2 / 1000)?;
        Ok(())
    }

    /// Enter deferred-index mode on the vector store for a drain burst. The
    /// ingest drain (corpus_ingest_queue) calls this before ingesting a drained
    /// batch so the burst's resident-index rebuilds collapse into a single rebuild
    /// at `publish_vector_index()` — O(N) bulk import instead of O(N²). `vector_store`
    /// is module-private, so the ingest-queue module reaches it through this seam.
    /// Mirrors the Swift `Corpus.beginDeferredVectorIndex`.
    pub(crate) fn begin_deferred_vector_index(&self) -> CorpusKitResult<()> {
        self.vector_store
            .begin_deferred_index()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))
    }

    /// Publish the deferred resident vector index (one rebuild) at the end of a
    /// drain burst / drain barrier. No-op when nothing was deferred. Mirrors the
    /// Swift `Corpus.publishVectorIndex`.
    pub(crate) fn publish_vector_index(&self) -> CorpusKitResult<()> {
        self.vector_store
            .publish_resident_index()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))
    }

    /// Retrain the embedding basis on the full corpus and re-embed every chunk.
    ///
    /// Rust mirror of Swift `Corpus.reindex(now:)`. When the provider is
    /// trainable (RI/LSA):
    ///   1. gathers ALL chunk texts from the BundleStore,
    ///   2. trains the basis through the `TrainableEmbeddingBasis` seam
    ///      (`train_on_corpus`, which runs the provider's own train+finalize),
    ///   3. persists the serialized basis blob (UPSERT, one row per provider
    ///      key) with `now_millis` and the trained chunk count, and
    ///   4. re-embeds every chunk (binary lane v0 + float lane v1), REPLACING
    ///      stale vectors in place (delete-all then re-add — no duplicate rows).
    ///
    /// When the provider is NOT trainable, no basis is persisted; the chunks are
    /// simply (re)embedded so the call is a well-defined vector refresh. A
    /// trainable slot ALWAYS retrains from its empty-basis factory here, including
    /// after a restart (the frozen-after-restart fix: the factory is retained on
    /// reopen, so a restarted corpus is no longer stuck serving its loaded basis).
    ///
    /// Deterministic: `now_millis` is the only clock source — never reads the
    /// system clock. Training is a pure function of the corpus texts and the
    /// provider's fixed seeds (the seam contract).
    ///
    /// `reindex` is the EXPLICIT retrain trigger. Implicit train triggers in
    /// `ingest` are:
    ///   (a) first-ingest: no basis persisted yet → train on the current corpus.
    ///   (b) growth retrain (Kinsta-fix): basis is young (trained_chunk_count below
    ///       `PER_DOC_AUTO_RETRAIN_STABLE_CHUNK_THRESHOLD`) AND corpus has grown to
    ///       ≥ 2× trained_chunk_count → retrain on the full corpus. Stops once the
    ///       basis is stable. Prevents a rank-1 LSA SVD on a 1-doc first-ingest corpus.
    ///
    /// Above the stability threshold, `ingest` only folds new chunks onto the
    /// frozen basis; this method is the only way to retrain for a mature corpus.
    ///
    /// `now_millis`: Unix epoch in milliseconds for the basis `trained_at` stamp
    /// (converted to seconds) and the re-embedded vectors' filing timestamps.
    pub fn reindex(&self, now_millis: i64) -> CorpusKitResult<()> {
        self.reindex_with_budget(now_millis, &RetrainingBudget::unbounded()).map(|_| ())
    }

    pub fn reindex_with_budget(&self, now_millis: i64, budget: &RetrainingBudget) -> CorpusKitResult<CorpusRetrainingReport> {
        let mut report = CorpusRetrainingReport::default();
        // Active chunks only: a source cleared by `remove` must NOT be re-embedded
        // back into recall by a (possibly auto-triggered) reindex.
        let chunks = self.active_chunks()?;
        let filed_at_secs = now_millis / 1000;

        // Phase logging throughout: on a large corpus this call legitimately
        // runs tens of minutes (full basis retrain + full re-embed); without
        // log lines that is indistinguishable from a hang (the v1.0.13 vault
        // import triage required sampling the process to prove it was alive).
        // Swift twin logs the same phases via corpusLog.
        eprintln!(
            "[corpus] reindex: start — {} active chunks, {} provider slots",
            chunks.len(),
            self.slots.len()
        );

        // Reset the training-path decision seam at the start of each pass so
        // prior reindex decisions do not bleed through to subsequent calls.
        {
            let mut decisions = self.training_path_decisions.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("training_path_decisions mutex poisoned".into())
            })?;
            decisions.clear();
        }

        // Phase 1 — train/restore each trainable slot.
        //
        // Two paths per slot:
        //
        //   COUNTS PATH: available when
        //     (a) finalizeFromCounts() on a fresh empty instance returns true, AND
        //     (b) countsDeltaFoldSafe() returns true (RI returns false because f32
        //         running sums are not commutative, and ingest-arrival order cannot
        //         be proven equal to activeChunks() order; LSA returns false).
        //   When both hold AND the population guard passes, we restore from the
        //   persisted counts snapshot without re-reading any corpus text. Neither
        //   default provider opts in, so every slot takes the corpus path.
        //   CORPUS PATH (RI / LSA always; a counts-capable slot when a guard rejects):
        //   Trains a fresh basis on the full active-chunk text snapshot (same as
        //   before this wave). Adds the F-2 heal: rebuilds the counts accumulator
        //   from the same active texts so `persist_maintained_counts` persists an
        //   exact snapshot rather than a stale monotonic accumulator.
        //
        // Counts-path slots are processed sequentially (fast — DB reads only).
        // Corpus-path slots are fanned out to parallel threads (same as before).
        let mut corpus_path_indices: Vec<(usize, CorpusPathReason)> = Vec::new();

        for slot_index in 0..self.slots.len() {
            let slot = &self.slots[slot_index];
            let Some(fresh_blob) = slot.fresh_basis_blob.as_ref() else {
                continue; // non-trainable — skip
            };

            // Read model_version from the slot handle FIRST (before the counts
            // lock) to avoid acquiring both locks simultaneously.
            let model_version = Self::slot_model_version(slot)?;

            // Probe capability and population from the counts accumulator.
            //
            // Two conditions must BOTH hold for the counts path:
            //   (a) finalizeFromCounts() on an empty fresh instance returns true.
            //       Checked via a throwaway reconstruction so the accumulator is
            //       not mutated. (RI → true; LSA → false.)
            //   (b) countsDeltaFoldSafe() returns true.
            //       (RI → false — RI fold order is not commutative; LSA → false.)
            let (capable, fold_safe, doc_count) = {
                let guard = slot.counts.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator lock poisoned in reindex probe".into(),
                    )
                })?;
                let state = match guard.as_ref() {
                    Some(s) => s,
                    None => {
                        corpus_path_indices
                            .push((slot_index, CorpusPathReason::NoCountsRow));
                        continue;
                    }
                };
                // Probe via throwaway fresh instance — does not touch the accumulator.
                let mut probe = state.accumulator.reconstruct_trainable_basis(fresh_blob)?;
                let capable = probe.finalize_from_counts();
                let fold_safe = probe.counts_delta_fold_safe();
                (capable, fold_safe, state.document_count)
            };

            if !capable {
                corpus_path_indices.push((slot_index, CorpusPathReason::NotCountsCapable));
                continue;
            }
            if !fold_safe {
                // RI: the live accumulator folds counts in ingest-arrival order;
                // a from-scratch train uses activeChunks() order. RI is float-
                // order-sensitive, so these two fold orders cannot be proven
                // equivalent — the standalone path cannot safely restore from the
                // live accumulator. No pending delta exists here; the issue is
                // provenance of the maintained counts' fold order.
                corpus_path_indices.push((slot_index, CorpusPathReason::FoldOrderProvenanceUnknown));
                continue;
            }

            // Population guard (standalone):
            //   LHS: state.document_count — monotonic fold anchor, incremented by
            //        corpus.rs fold_chunks_into_counts (`state.document_count += chunks.len()`),
            //        never decremented; restored across reopen from the persisted row
            //        written by persist_maintained_counts.
            //   RHS: active_chunks() count — excludes removed sources.
            //   These are DIFFERENT populations whose every divergence is reject-safe:
            //   a removed-after-fold source drives LHS > RHS → corpus path heals;
            //   a removed-then-reingested source also drives LHS > RHS → corpus path.
            //   Do NOT describe them as the same population.
            if doc_count != chunks.len() {
                corpus_path_indices
                    .push((slot_index, CorpusPathReason::PopulationMismatch));
                continue;
            }

            // ── Counts path ───────────────────────────────────────────────────
            // Step 1: flush the live accumulator to storage so the subsequent
            // store-read sees a consistent snapshot.
            {
                let guard = slot.counts.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator lock poisoned at flush".into(),
                    )
                })?;
                let state = guard.as_ref().ok_or_else(|| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator vanished between probe and flush".into(),
                    )
                })?;
                self.counts_store.persist_counts_into(
                    state.accumulator.as_ref(),
                    &slot.model_id,
                    &model_version,
                    state.document_count,
                    state.accumulator.counts_vocabulary_size(),
                    filed_at_secs,
                    &self.storage.row_store(),
                    // Reindex slot commit: leaves clearing the sentinel to the
                    // full-corpus retrain path.
                    false,
                )?;
            }

            // Step 2: reconstruct a fresh provider and restore counts from the
            // STORE. The restore path prefers v4 term rows and falls back to the
            // blob — we do not reimplement that choice.
            let mut serving = {
                let guard = slot.counts.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator lock poisoned at restore".into(),
                    )
                })?;
                let state = guard.as_ref().ok_or_else(|| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator vanished before restore".into(),
                    )
                })?;
                state.accumulator.reconstruct_trainable_basis(fresh_blob)?
            };
            let restored = self.counts_store.restore_counts_into(
                serving.as_mut(),
                &slot.model_id,
                &model_version,
            )?;
            if !restored {
                // Two causes for restored == false:
                //   1. The counts row was deleted between flush and restore
                //      (a race or a concurrent upgrade).
                //   2. The row exists but carries the migration-invalidation
                //      sentinel (an empty blob written by `mootx01 upgrade` to
                //      signal that the stale per-provider blob has been cleared).
                //      The upgrade also sets the reindex latch, so the next
                //      open-and-train cycle will rebuild the counts.
                // In both cases, CorpusPathReason::NoCountsRow is the correct
                // report: the provider has no usable counts. No new variant is
                // added because this enum mirrors the Swift CorpusPathReason,
                // and a Rust-only variant would be a dual-port divergence.
                corpus_path_indices.push((slot_index, CorpusPathReason::NoCountsRow));
                continue;
            }

            // Step 3: finalize the serving basis from the restored counts.
            if !serving.finalize_from_counts() {
                // Defensive: probe said true; guard against a corrupted blob.
                corpus_path_indices
                    .push((slot_index, CorpusPathReason::NotCountsCapable));
                continue;
            }

            // Step 4: serialize before moving serving into the handle.
            let basis_blob = serving.serialize_basis();
            let basis_digest =
                crate::content::content_digest_bytes(&basis_blob);

            // Step 5: install the finalized provider.
            {
                let mut handle = slot.handle.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "provider handle lock poisoned at install".into(),
                    )
                })?;
                *handle = ProviderHandle::Trainable(serving);
            }
            // Update the cached basis digest so backfill coverage reads it correctly.
            *slot.basis_digest.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("basis digest lock poisoned".into())
            })? = basis_digest;

            // Step 6: persist basis with trainedChunkCount = active chunk count.
            self.basis_store.upsert(&PersistedBasis {
                model_id: slot.model_id.clone(),
                model_version: model_version.clone(),
                basis: basis_blob,
                trained_at_secs: filed_at_secs,
                trained_chunk_count: chunks.len(),
            })?;

            // Record decision: CountsRestore. Standalone reindex has no pending
            // delta refs (the live accumulator IS the full folded history).
            {
                let mut decisions = self.training_path_decisions.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "training_path_decisions lock poisoned".into(),
                    )
                })?;
                decisions.insert(
                    slot.model_id.clone(),
                    TrainingPathDecision::CountsRestore,
                );
            }

            eprintln!(
                "[corpus] reindex: slot {} took counts path (restore), {} chunks",
                slot.model_id,
                chunks.len()
            );
            report.completed_model_ids.push(slot.model_id.clone());
        }

        // Corpus-path slots: fan out to parallel training threads (same as the
        // pre-Part-3 path). Each thread trains a FRESH basis from scratch so
        // train_on_corpus's additive semantics start clean.
        let corpus_indices_only: Vec<usize> =
            corpus_path_indices.iter().map(|(i, _)| *i).collect();
        if !corpus_indices_only.is_empty() {
            let attempts = std::thread::scope(|scope| -> CorpusKitResult<Vec<(String, RetrainingOutcome)>> {
                let chunks_ref = &chunks;
                let mut handles = Vec::new();
                for &slot_index in &corpus_indices_only {
                    handles.push(scope.spawn(move || {
                        let outcome = self.train_and_persist_basis_with_budget(slot_index, chunks_ref, filed_at_secs, budget)?;
                        Ok((self.slots[slot_index].model_id.clone(), outcome))
                    }));
                }
                eprintln!(
                    "[corpus] reindex: training {} corpus-path slots concurrently over {} texts",
                    handles.len(),
                    chunks_ref.len()
                );
                let mut outcomes = Vec::new();
                for h in handles { outcomes.push(h.join().expect("slot train thread panicked")?); }
                Ok(outcomes)
            })?;
            for (model_id, outcome) in attempts {
                match outcome {
                    RetrainingOutcome::Completed => report.completed_model_ids.push(model_id),
                    RetrainingOutcome::Skipped(reason) => { report.skipped_model_ids.insert(model_id, reason); }
                }
            }
        }

        // F-2 heal: for every corpus-path slot, rebuild a FRESH counts
        // accumulator by folding the active chunk texts in activeChunks() order.
        // This replaces a potentially-stale monotonic accumulator (which includes
        // removed-source counts) with an exact snapshot matching the retrained
        // basis. The tail `persist_maintained_counts` call then persists this
        // healed exact state. Without this heal, a reindex after a source removal
        // would persist accumulator counts that included the removed source's
        // contributions — the next reindex's population guard would pass
        // incorrectly and the restored basis would mismatch the corpus.
        for (slot_index, reason) in &corpus_path_indices {
            let slot = &self.slots[*slot_index];
            if report.skipped_model_ids.contains_key(&slot.model_id) { continue; }
            let Some(fresh_blob) = slot.fresh_basis_blob.as_ref() else {
                continue;
            };
            // Reconstruct a fresh accumulator and fold all active chunk texts.
            let mut fresh_acc = {
                let guard = slot.counts.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator lock poisoned at F-2 heal".into(),
                    )
                })?;
                let state = guard.as_ref().ok_or_else(|| {
                    CorpusKitError::StoreUnavailable(
                        "counts accumulator absent at F-2 heal".into(),
                    )
                })?;
                state.accumulator.reconstruct_trainable_basis(fresh_blob)?
            };
            for chunk in &chunks {
                fresh_acc.add_to_counts(&chunk.text);
            }
            let fresh_vocab = fresh_acc.counts_vocabulary_size();
            // Replace the slot's counts state with the healed accumulator.
            let mut guard = slot.counts.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable(
                    "counts accumulator lock poisoned at F-2 heal replace".into(),
                )
            })?;
            *guard = Some(CountsState {
                accumulator: fresh_acc,
                document_count: chunks.len(),
                vocab_anchor: fresh_vocab,
                growth_term_digests: std::collections::BTreeSet::new(),
            });

            // Record decision: Corpus(reason).
            {
                let mut decisions = self.training_path_decisions.lock().map_err(|_| {
                    CorpusKitError::StoreUnavailable(
                        "training_path_decisions lock poisoned at record".into(),
                    )
                })?;
                decisions.insert(
                    slot.model_id.clone(),
                    TrainingPathDecision::Corpus(reason.clone()),
                );
            }
        }

        eprintln!("[corpus] reindex: training complete — bases persisted");

        // Phase 2 — re-embed every TRAINABLE slot's chunks under the just-retrained
        // provider. Non-trainable providers (deterministic, CandleNL) are skipped for
        // re-embedding: their vectors are item-local and invariant to basis retraining
        // — the same embedding function applied to the same text always produces the
        // same vector regardless of which distributional basis the trainable slots
        // carry. Serial per slot: each re-embed already fans its embed compute across
        // all cores and funnels one bulk single-writer transaction (replace_model_vectors).
        //
        // STALE-VECTOR CLEANUP FOR NON-TRAINABLE SLOTS: Because non-trainable slots
        // never reach reembed_chunks (which calls replace_model_vectors and thus clears
        // the model's whole vector set before re-inserting), their rows for REMOVED
        // sources must be pruned here, before the loop. Without this step, vectors for
        // sources removed while the non-trainable slot was not held (or removed via a
        // corpus opened without this slot) survive indefinitely — the hard-delete
        // contract would be broken. Trainable slots self-clean via replace_model_vectors
        // (which inserts only active chunks), so this cleanup is non-trainable-only.
        let non_trainable_model_ids: Vec<String> = self
            .slots
            .iter()
            .filter(|s| s.fresh_basis_blob.is_none())
            .map(|s| s.model_id.clone())
            .collect();
        if !non_trainable_model_ids.is_empty() {
            let removed_ids = self.removed_source_store.removed_ids()?;
            for source_id in &removed_ids {
                let removed_chunks = self.bundle_store.chunks_for_source(source_id, None)?;
                for chunk in &removed_chunks {
                    for model_id in &non_trainable_model_ids {
                        self.vector_store
                            .delete_all_vectors(&chunk.id.to_string(), model_id)
                            .map_err(|e| CorpusKitError::StoreUnavailable(format!(
                                "reindex: non-trainable stale-vector cleanup failed \
                                 for chunk {} model {}: {:?}",
                                chunk.id, model_id, e
                            )))?;
                    }
                }
            }
            eprintln!(
                "[corpus] reindex: pruned stale vectors for {} removed sources \
                 across {} non-trainable slot(s)",
                removed_ids.len(),
                non_trainable_model_ids.len(),
            );
        }

        for slot_index in 0..self.slots.len() {
            if report.skipped_model_ids.contains_key(&self.slots[slot_index].model_id) { continue; }
            // Skip non-trainable providers: fresh_basis_blob.is_none() means no
            // factory blob → item-local deterministic output → basis-invariant vectors.
            // Re-embedding them on every reindex is wasted work (~20% of per-chunk
            // embed cost in the 5-provider default ensemble). Stale-vector cleanup for
            // removed sources was already handled above, before this loop.
            if self.slots[slot_index].fresh_basis_blob.is_none() {
                eprintln!(
                    "[corpus] reindex: skipping re-embed for non-trainable slot {} \
                     (vectors are basis-invariant; stale rows already pruned above)",
                    self.slots[slot_index].model_id,
                );
                continue;
            }
            eprintln!(
                "[corpus] reindex: re-embedding {} chunks (slot {}/{})",
                chunks.len(),
                slot_index + 1,
                self.slots.len()
            );
            self.reembed_chunks(slot_index, &chunks, filed_at_secs)?;
        }

        // Persist the maintained counts + growth anchors after the refresh. The
        // accumulators were kept current by the ingest fold path; persisting here
        // re-anchors the growth trigger to the just-reindexed state.
        self.persist_maintained_counts(filed_at_secs)?;

        // NOTE: release_basis was here but is REMOVED because the serving providers
        // have no on-demand reconstruction path. Calling it clears the live vocab,
        // making subsequent embeds return zero vectors. The ~2GB vocab RAM stays
        // resident until a lazy-load-from-BasisStore mechanism is implemented.

        eprintln!(
            "[corpus] reindex: complete — {} chunks re-embedded across {} slots",
            chunks.len(),
            self.slots.len()
        );
        report.completed_model_ids.sort();
        Ok(report)
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
    fn train_and_persist_basis(
        &self,
        slot_index: usize,
        chunks: &[Chunk],
        now_secs: i64,
    ) -> CorpusKitResult<()> {
        self.train_and_persist_basis_with_budget(slot_index, chunks, now_secs, &RetrainingBudget::unbounded()).map(|_| ())
    }

    fn train_and_persist_basis_with_budget(
        &self, slot_index: usize, chunks: &[Chunk], now_secs: i64, budget: &RetrainingBudget,
    ) -> CorpusKitResult<RetrainingOutcome> {
        let Some(fresh_blob) = self.slots[slot_index].fresh_basis_blob.as_ref() else {
            // Defensive: only invoked when this slot's fresh_basis_blob is Some.
            // Nothing to train otherwise.
            return Ok(RetrainingOutcome::Completed);
        };
        // Reconstruct a fresh trainable provider from the empty-basis blob, train
        // it from scratch, then install it as this slot's live serving provider.
        // Reconstruct via the maintained-counts ACCUMULATOR, not the serving
        // handle: after a reopen the serving handle is `Plain` (Rust cannot
        // downcast a `Box<dyn EmbeddingProvider>` back to trainable, unlike
        // Swift's `as?`), so harvesting trainability from it would fail. The
        // accumulator is always trainable for a slot whose `fresh_basis_blob` is
        // Some, so it is the reliable trainable witness — and using it here is the
        // frozen-after-restart fix's Rust leg.
        let mut trained = {
            let guard = self.slots[slot_index]
                .counts
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("counts accumulator lock poisoned".into()))?;
            let state = guard.as_ref().ok_or_else(|| {
                CorpusKitError::NotTrainable(
                    "slot has no counts accumulator — basis seam invariant violated".into(),
                )
            })?;
            state.accumulator.reconstruct_trainable_basis(fresh_blob)?
        };
        let texts: Vec<&str> = chunks.iter().map(|c| c.text.as_str()).collect();
        let outcome = trained.train_on_corpus_with_budget(&texts, budget);
        if outcome != RetrainingOutcome::Completed { return Ok(outcome); }
        let blob = trained.serialize_basis();
        let model_id = trained.model_id().to_string();
        let model_version = trained.model_version().to_string();
        // Install the trained provider as this slot's live serving provider.
        {
            let mut guard = self.slots[slot_index]
                .handle
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
        })?;
        Ok(RetrainingOutcome::Completed)
    }

    /// Re-embed every chunk (binary v0 + float v1) under the GIVEN SLOT's
    /// provider, replacing any stale vectors so no duplicate rows accumulate.
    /// Mirrors Swift `Corpus.reembedChunks`. Re-acquires the slot's provider lock
    /// internally. Other slots' rows (keyed by a different model_id) are
    /// untouched.
    fn reembed_chunks(
        &self,
        slot_index: usize,
        chunks: &[Chunk],
        filed_at_secs: i64,
    ) -> CorpusKitResult<()> {
        // Batch size for the PARALLEL re-embed. Fixed (not n/cap) on purpose: it
        // makes a corpus produce MORE batches than workers, so a slow batch cannot
        // stall the pool the way exact per-core slices can (better load balancing).
        // ~3000 amortizes per-batch overhead while a realistic import (tens of
        // thousands of chunks) still keeps every worker busy. Also the natural unit
        // for a future chunked-commit write. Batch COUNT scales with corpus size;
        // thread count does NOT — it is capped at embed_concurrency_cap() below
        // (parity with Swift boundedConcurrentMap(batches, cap:)).
        const REEMBED_BATCH_SIZE: usize = 3000;

        let guard = self.slots[slot_index]
            .handle
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        let provider = guard.provider();
        let model_id = provider.model_id().to_string();
        let model_version = provider.model_version().to_string();
        // Shared, thread-safe refs captured by the embed workers. `provider` is
        // `&dyn EmbeddingProvider` (Send + Sync — embed_pair is a pure function of
        // (text, fixed basis), so concurrent &self calls are safe); the model
        // strings are borrowed read-only. Same sharing pattern as ingest_batch's
        // parallel embed phase.
        let provider_ref = provider;
        let model_id_ref = &model_id;
        let model_version_ref = &model_version;

        // Phase 1 (PARALLEL, BOUNDED): embed the fixed-size CONTIGUOUS batches on
        // a pool of at most embed_concurrency_cap() persistent workers. Workers
        // pull batch INDICES from a shared atomic counter (work-stealing), so a
        // slow batch never stalls the others; results carry their batch index and
        // are reassembled in batch order, so the flattened payload vector is
        // byte-identical to the serial path — determinism / cross-port conformance
        // preserved. The earlier shape spawned one scoped thread PER BATCH
        // (ceil(len / REEMBED_BATCH_SIZE) threads, unbounded — a very large corpus
        // could exhaust OS threads/stacks: local DoS, codex 3399b904); the pool
        // caps live threads exactly like ingest_batch and Swift's
        // boundedConcurrentMap(batches, cap: embedConcurrencyCap).
        let batches: Vec<&[Chunk]> = chunks.chunks(REEMBED_BATCH_SIZE).collect();
        let n_batches = batches.len();
        let workers = self.embed_concurrency_cap().min(n_batches.max(1));
        let batches_ref = &batches;
        let next_batch = std::sync::atomic::AtomicUsize::new(0);
        let next_ref = &next_batch;
        // Progress counter: on a large corpus this phase runs many minutes; a
        // line every ~5k chunks keeps the daemon log distinguishable from a
        // hang. Atomic (batches complete concurrently); logging order may
        // interleave but counts are exact. Swift twin: the Mutex-guarded
        // counter in Corpus.reembedChunks.
        const PROGRESS_STRIDE: usize = 5_000;
        let total_chunks = chunks.len();
        let embedded = std::sync::atomic::AtomicUsize::new(0);
        let embedded_ref = &embedded;
        let batch_rows: Vec<Vec<VectorPayloadInput>> = std::thread::scope(
            |scope| -> Result<Vec<Vec<VectorPayloadInput>>, CorpusKitError> {
                let handles: Vec<_> = (0..workers)
                    .map(|_| {
                        scope.spawn(
                            move || -> Result<Vec<(usize, Vec<VectorPayloadInput>)>, CorpusKitError> {
                                let mut out: Vec<(usize, Vec<VectorPayloadInput>)> = Vec::new();
                                loop {
                                    // Claim the next unprocessed batch index; exit when done.
                                    let i = next_ref
                                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                    if i >= batches_ref.len() {
                                        break;
                                    }
                                    let batch = batches_ref[i];
                                    let mut rows: Vec<VectorPayloadInput> =
                                        Vec::with_capacity(batch.len() * 2);
                                    for chunk in batch {
                                        // Single inference pass: embed_pair returns the engram
                                        // and float vector from ONE computation.
                                        let (engram, floats) =
                                            provider_ref.embed_pair(&chunk.text).map_err(|e| {
                                                CorpusKitError::EmbeddingFailed(format!("{:?}", e))
                                            })?;
                                        // The default build stores the engram only; the pooled float is
                                        // computed for the projection and dropped (whole-record dense rows
                                        // are a whole-record float lane write).
                                        rows.push(VectorPayloadInput {
                                            item_id: chunk.id.to_string(),
                                            vector_index: 0,
                                            payload: VectorPayload::from_engram(&engram),
                                            model_id: model_id_ref.clone(),
                                            model_version: model_version_ref.clone(),
                                            filed_at_unix_secs: filed_at_secs,
                                        });
                                        {
                                            if !floats.is_empty() {
                                                rows.push(VectorPayloadInput {
                                                    item_id: chunk.id.to_string(),
                                                    vector_index: 1,
                                                    payload: VectorPayload::from_f32(&floats),
                                                    model_id: model_id_ref.clone(),
                                                    model_version: model_version_ref.clone(),
                                                    filed_at_unix_secs: filed_at_secs,
                                                });
                                            }
                                        }
                                    }
                                    let done = embedded_ref.fetch_add(
                                        batch.len(),
                                        std::sync::atomic::Ordering::Relaxed,
                                    ) + batch.len();
                                    if done / PROGRESS_STRIDE
                                        > (done - batch.len()) / PROGRESS_STRIDE
                                    {
                                        eprintln!(
                                            "[corpus] reindex: reembed {done}/{total_chunks} ({model_id_ref})"
                                        );
                                    }
                                    out.push((i, rows));
                                }
                                Ok(out)
                            },
                        )
                    })
                    .collect();
                // Reassemble by batch index → chunk order, independent of which
                // worker embedded which batch. A worker panic surfaces as an
                // error instead of aborting the join.
                let mut all: Vec<Option<Vec<VectorPayloadInput>>> =
                    (0..n_batches).map(|_| None).collect();
                for h in handles {
                    match h.join() {
                        Ok(Ok(pairs)) => {
                            for (i, rows) in pairs {
                                all[i] = Some(rows);
                            }
                        }
                        Ok(Err(e)) => return Err(e),
                        Err(_) => {
                            return Err(CorpusKitError::EmbeddingFailed(
                                "re-embed worker thread panicked".into(),
                            ))
                        }
                    }
                }
                all.into_iter()
                    .enumerate()
                    .map(|(i, slot)| {
                        slot.ok_or_else(|| {
                            CorpusKitError::EmbeddingFailed(format!(
                                "re-embed batch {i} was never produced (worker exited early)"
                            ))
                        })
                    })
                    .collect()
            },
        )?;
        drop(guard);

        // Phase 2 (SERIAL — single-writer): clear the model's ENTIRE vector set in
        // ONE bulk pass — one DB delete + one O(n) resident-array sweep — then add
        // the freshly-embedded batch under a single transaction. The old per-chunk
        // delete_all_vectors scanned the whole resident array on EVERY chunk, so
        // re-embedding a corpus was O(n²) (the dominant cost of a large reindex);
        // clearing the whole model once is O(n). A full clear + re-add also ends
        // each chunk with exactly the new vectors (no stale rows from a prior basis
        // in either lane), preserving the delete-first invariant.
        let batch: Vec<VectorPayloadInput> = batch_rows.into_iter().flatten().collect();
        self.vector_store
            .replace_model_vectors(&model_id, &batch)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
        Ok(())
    }

    /// The DEFAULT signal's slot — `slots[0]`. The single-signal entry points
    /// read through this so existing callers see exactly the first held
    /// provider, identical to the single-provider behaviour. `slots`
    /// is never empty (every constructor builds at least one slot), so the index
    /// cannot panic. Mirrors Swift's `Corpus.defaultProvider`.
    fn default_slot(&self) -> &ProviderSlot {
        &self.slots[0]
    }

    /// A slot's provider modelVersion, read under that slot's handle lock. Used
    /// to key the basis row (model_id, model_version). Stable for the corpus
    /// lifetime; not cached because it is only needed on the basis-store paths.
    fn slot_model_version(slot: &ProviderSlot) -> CorpusKitResult<String> {
        let guard = slot
            .handle
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        Ok(guard.provider().model_version().to_string())
    }

    /// Recall the top-k chunks relevant to a query.
    ///
    /// Embeds the query and fuses vector kNN hits + BM25 keyword hits
    /// via Reciprocal Rank Fusion (SPEC § 5, B-4). Both passes are
    /// filtered to the DEFAULT signal's model id. Per-signal fan-out is exposed
    /// additively via `float_nearest_per_signal` (the 6b RRF seam); this method
    /// is unchanged for existing callers.
    ///
    /// `_now_millis`: Reserved; included for API symmetry with `ingest`
    /// and determinism discipline.
    pub fn recall(
        &self,
        query: &str,
        limit: usize,
        _now_millis: i64,
    ) -> CorpusKitResult<Vec<ScoredChunk>> {
        let slot = self.default_slot();
        let probe = {
            let guard = slot
                .handle
                .lock()
                .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
            guard
                .provider()
                .embed(query)
                .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))?
        };

        hybrid_recall(
            &probe,
            query,
            &slot.model_id,
            limit,
            &self.vector_store,
            &self.inverted_index,
            &self.bundle_store,
            HybridRecallConfiguration::default(),
        )
    }

    /// Embed `text` using the corpus's DEFAULT signal.
    ///
    /// Exposes the embedding surface so GeniusLocusKit's RecallDirector
    /// can produce a probe `Engram` for the vector lane without accessing
    /// the provider directly. Mirrors Swift `Corpus.embed(_:)`.
    ///
    /// Returns an error when the embedding provider fails (e.g. empty input
    /// routed to a model that requires non-empty text).
    pub fn embed(&self, text: &str) -> CorpusKitResult<engram_lib::Engram> {
        let guard = self
            .default_slot()
            .handle
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        guard
            .provider()
            .embed(text)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))
    }

    /// Return the DEFAULT signal's model identifier.
    ///
    /// Used by the GLK vector lane to match stored vectors to the correct
    /// model so cross-model Hamming comparisons cannot occur. For an N-provider
    /// corpus this is the first held provider's model_id; the other signals'
    /// model_ids are reachable through `float_nearest_per_signal`.
    /// Mirrors Swift `Corpus.modelID`.
    pub fn model_id(&self) -> &str {
        // Returns the default slot's cached identity (stable for the corpus
        // lifetime) so the signature stays `-> &str` without locking the handle
        // Mutex.
        &self.default_slot().model_id
    }

    /// The estate's single dense vector store (binary Engram + float32 lanes),
    /// owned by this Corpus. The composition layer (GeniusLocusKit) borrows THIS
    /// instance for its scored-recall vector lane instead of constructing a second
    /// `VectorStore` over the same `vectors` table — one store, one resident array,
    /// one on-disk sidecar. CorpusKit owns the dense vector lane; the orchestrator
    /// reaches it through this accessor rather than reaching around the kit.
    /// Mirrors Swift `Corpus.sharedVectorStore`.
    pub fn shared_vector_store(&self) -> Arc<VectorStore> {
        Arc::clone(&self.vector_store)
    }

    /// Embed the query text into the pooled dense float vector (Lane D) — the
    /// probe for the dense float recall lane. Delegates to the DEFAULT signal's
    /// `embed_float`. Providers without a float lane error; the caller treats
    /// that as "this corpus has no float lane" and skips the dense lane rather
    /// than failing the whole recall. Empty input returns `[]`. Mirrors Swift
    /// `Corpus.embedFloat(_:)`.
    pub fn embed_float(&self, text: &str) -> CorpusKitResult<Vec<f32>> {
        let guard = self
            .default_slot()
            .handle
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("provider lock poisoned".into()))?;
        guard
            .provider()
            .embed_float(text)
            .map_err(|e| CorpusKitError::EmbeddingFailed(format!("{:?}", e)))
    }

    /// Compute sub-span max-cosine scores for a source ID set under a budget.
    ///
    /// Rust twin of Swift `Corpus.scoreSubSpans(query:sourceIDs:budget:)`. Uses
    /// the chunk-based path: for each source ID, in the caller's order, fetches
    /// all chunks from `bundle_store`, concatenates their text in
    /// `start_offset` order, cuts the body at `budget.max_record_bytes` on a
    /// scalar boundary, and scores its sub-spans while the aggregate window
    /// budget lasts (`sub_span_scoring::SubSpanBudget`).
    ///
    /// This is the older chunk-based Corpus path. The `CorpusContentEngine`
    /// path (`score_sub_spans` on the engine) is preferred for GLK usage and
    /// gets `effective_dense_text` (dual-text capability). The Corpus path
    /// uses raw chunk text.
    ///
    /// Candidates absent from the bundle store, providers that return Err on
    /// `embed_float`, and sources with no alphanumeric tokens are not included
    /// in the returned scores; sources the aggregate window budget did not
    /// reach are listed in `unscored_ids`.
    ///
    /// Mission: MISSION_11X_RECALL_GAP_01 Item 1 — transient sub-span scoring.
    pub fn score_sub_spans(
        &self,
        query: &str,
        source_ids: &[&str],
        budget: crate::sub_span_scoring::SubSpanBudget,
    ) -> crate::sub_span_scoring::SubSpanScoringOutcome {
        use crate::sub_span_scoring::SubSpanScoringOutcome;
        if query.is_empty() || source_ids.is_empty() {
            return SubSpanScoringOutcome::default();
        }

        // Embed the query once. If the provider has no float lane, return empty.
        let default_slot = self.default_slot();
        let guard = match default_slot.handle.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        let query_vec = match guard.provider().embed_float(query) {
            Ok(v) if !v.is_empty() => v,
            _ => return SubSpanScoringOutcome::default(),
        };

        let mut outcome = SubSpanScoringOutcome {
            scores: HashMap::with_capacity(source_ids.len()),
            ..SubSpanScoringOutcome::default()
        };
        for &source_id in source_ids {
            // Fetch chunks, sort by start_offset (the natural ingest order).
            let mut chunks = match self.bundle_store.chunks_for_source(source_id, None) {
                Ok(cs) => cs,
                Err(_) => continue,
            };
            if chunks.is_empty() {
                continue;
            }
            chunks.sort_by_key(|c| c.start_offset);

            // Concatenate chunk texts. Each chunk already contributes its own
            // text boundary; separate with a single space so sub-spans don't
            // run across chunk junctions unexpectedly. The Swift twin uses
            // the same concatenation-in-offset-order approach.
            let combined: String = chunks
                .iter()
                .map(|c| c.text.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            let combined =
                crate::sub_span_scoring::capped_text(&combined, budget.max_record_bytes);

            if combined.is_empty() {
                continue;
            }
            if outcome.windows_embedded >= budget.max_windows {
                // Budget exhausted by an earlier source: this one keeps its
                // stored signals.
                outcome.truncated = true;
                outcome.unscored_ids.push(source_id.to_string());
                continue;
            }

            let ranges = crate::sub_span_scoring::sub_span_ranges(
                combined,
                crate::sub_span_scoring::DEFAULT_WINDOW_TOKENS,
                crate::sub_span_scoring::DEFAULT_OVERLAP_TOKENS,
            );
            if ranges.is_empty() {
                continue;
            }

            let combined_bytes = combined.as_bytes();
            let mut max_norm: f32 = 0.0;
            let mut embedded_here = 0usize;
            for (span_start, span_length) in &ranges {
                if outcome.windows_embedded >= budget.max_windows {
                    outcome.truncated = true;
                    break;
                }
                let lo = *span_start;
                let hi = lo + span_length;
                if hi > combined_bytes.len() {
                    continue;
                }
                let span_text = match std::str::from_utf8(&combined_bytes[lo..hi]) {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                outcome.windows_embedded += 1;
                embedded_here += 1;
                let span_vec = match guard.provider().embed_float(span_text) {
                    Ok(v) if !v.is_empty() => v,
                    _ => continue,
                };
                let cosine = crate::sub_span_scoring::cosine_similarity(&query_vec, &span_vec);
                let norm = f32::max(0.0, f32::min(1.0, (cosine + 1.0) / 2.0));
                if norm > max_norm {
                    max_norm = norm;
                }
            }
            if embedded_here == 0 {
                outcome.unscored_ids.push(source_id.to_string());
                continue;
            }
            if max_norm > 0.0 {
                outcome.scores.insert(source_id.to_string(), max_norm);
            }
        }
        outcome
    }

    /// Whether this corpus's DEFAULT signal supports the dense float lane
    /// (Lane D). True when `embed_float` returns a vector rather than erroring.
    /// Probes with a single non-empty token so the answer reflects provider
    /// capability, not input. Mirrors Swift `Corpus.supportsFloat`.
    pub fn supports_float(&self) -> bool {
        let guard = match self.default_slot().handle.lock() {
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

        // Tokenise using the same vocabulary as the indexed chunks.
        // `default_keyword_tokens` is the canonical tokenizer shared by
        // InvertedIndexStore.index calls at ingest time.
        let tokens = default_keyword_tokens(query);
        if tokens.is_empty() {
            return vec![];
        }

        // Chunk-level BM25 hits via the durable InvertedIndexStore. Over-fetch
        // by 4× before source-level aggregation (same as Swift).
        // Returns SparseHit (item_id: String, impact: f32) sorted by score DESC.
        let sparse_hits = self.inverted_index.top_k(
            &tokens,
            limit.saturating_mul(4),
            Default::default(),  // BM25Parameters::default()
            Algorithm::BlockMaxWand,
        );

        if sparse_hits.is_empty() {
            return vec![];
        }

        // Aggregate chunk-level scores to source level using the in-memory
        // reverse map. Take max chunk score per source (same as Swift).
        // chunk_source_map is keyed by uuid::Uuid; SparseHit.item_id is a
        // UUID string — parse it before the lookup.
        let csm = match self.chunk_source_map.lock() {
            Ok(guard) => guard,
            Err(_) => return vec![],
        };
        let mut source_scores: std::collections::HashMap<String, f32> =
            std::collections::HashMap::new();
        for hit in &sparse_hits {
            let uuid = match uuid::Uuid::parse_str(&hit.item_id) {
                Ok(u) => u,
                Err(_) => continue,
            };
            if let Some(source_id) = csm.get(&uuid) {
                let entry = source_scores.entry(source_id.clone()).or_insert(0.0_f32);
                *entry = entry.max(hit.impact);
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

    /// Destroy the recall index — clear BM25, chunk_source_map, and this
    /// corpus's own vector rows (ownership-scoped: its chunk IDs under its
    /// held models — never rows other lanes wrote to shared storage).
    ///
    /// Called by `EstateCoordinator::destroy` as part of the coordinated estate
    /// teardown path. After this call the corpus has no recall capability: BM25
    /// scores zero for all queries and the vector lane returns no results.
    ///
    /// BundleStore rows (chunks) are NOT deleted — BundleStore is append-only per
    /// PersistenceKit schema invariant. The verbatim content survives for audit;
    /// the recall capability is destroyed. Mirrors Swift `Corpus.destroyRecallIndex()`.
    pub fn destroy_recall_index(&self) -> CorpusKitResult<()> {
        // Step 1: Clear the durable InvertedIndexStore in one call — no per-chunk
        // iteration needed. Mirrors Swift `InvertedIndexStore.deleteAll()`.
        self.inverted_index.clear_all()
            .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;

        // Step 2: Clear the chunk_source_map.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            csm.clear();
        }

        // Step 3: Delete THIS CORPUS'S vector rows — OWNERSHIP-SCOPED
        // (shared-content 1.1 P5). The corpus owns exactly the rows keyed by
        // its own chunk IDs under its held models' model_ids; on shared
        // storage the vectors table can also hold rows written by other
        // lanes, and destroying the corpus's recall index must never delete
        // those. The chunk inventory comes from the append-only chunks
        // table, so it covers every chunk this corpus ever wrote vectors for
        // (already-removed sources' deletes are no-ops). Whole-table
        // teardown (`destroy_all_vectors`) is reserved for the whole-estate
        // destruction path in EstateCoordinator::destroy. Mirrors the Swift
        // `Corpus.destroyRecallIndex` scoping.
        let held_model_ids: Vec<String> =
            self.slots.iter().map(|s| s.model_id.clone()).collect();
        let source_ids = self.bundle_store.all_source_ids(None)?;
        for source_id in &source_ids {
            let chunks = self.bundle_store.chunks_for_source(source_id, None)?;
            for chunk in &chunks {
                for model_id in &held_model_ids {
                    self.vector_store
                        .delete_all_vectors(&chunk.id.to_string(), model_id)
                        .map_err(|e| CorpusKitError::StoreUnavailable(format!(
                            "destroy_recall_index vector teardown failed: {:?}", e)))?;
                }
            }
        }

        // Step 4: Wipe the persisted trained basis. A
        // destroyed corpus must leave no orphaned basis row: the next open would
        // otherwise reconstruct a trained provider whose basis no longer matches
        // any stored vectors. The basis table is not append-only, so deletion is
        // permitted. Mirrors Swift `Corpus.destroyRecallIndex` step 3.
        self.basis_store.delete_all()?;
        self.counts_store.delete_all()?;
        self.removed_source_store.delete_all()?;

        Ok(())
    }

    /// Remove a source document from the recall index.
    ///
    /// Removes the source's chunks from BM25 and deletes their vectors
    /// from VectorStore. Content rows are preserved in the chunks table;
    /// the source will no longer appear in recall results. To erase
    /// verbatim chunk content, use `expunge(source_id)` instead.
    pub fn remove(&self, source_id: &str) -> CorpusKitResult<()> {
        let chunks = self.bundle_store.chunks_for_source(source_id, None)?;
        // Vector deletion fans out across every held provider's model_id so no
        // slot leaves orphan rows for a removed source. For N=1 this inner loop
        // runs once. model_ids are gathered once up front (stable for the corpus
        // lifetime) so the per-chunk loop does not re-borrow `slots`.
        let model_ids: Vec<&str> = self.slots.iter().map(|s| s.model_id.as_str()).collect();
        for chunk in &chunks {
            // Remove from the durable InvertedIndexStore.
            self.inverted_index.remove(&chunk.id.to_string())
                .map_err(|e| CorpusKitError::StoreUnavailable(e.to_string()))?;
            // Delete ALL vector_index rows for this chunk under EVERY held
            // model_id, not just the binary engram at vector_index=0: the float
            // lane (Lane D) stores a second row at vector_index=1 under the same
            // item_id. delete_all_vectors removes both and invalidates the float
            // index so a removed source cannot resurface through any signal's
            // dense float lane.
            for model_id in &model_ids {
                self.vector_store
                    .delete_all_vectors(&chunk.id.to_string(), model_id)
                    .map_err(|e| CorpusKitError::StoreUnavailable(format!("{:?}", e)))?;
            }
        }
        // Remove chunk entries from the reverse map so bm25_top_k_by_source
        // does not return stale source IDs for removed chunks.
        if let Ok(mut csm) = self.chunk_source_map.lock() {
            for chunk in &chunks {
                csm.remove(&chunk.id);
            }
        }
        // Record the source as removed so a subsequent reindex / BM25-rebuild /
        // first-ingest train (incl. the auto-triggered governor reindex) does NOT
        // re-embed it back into recall from the chunks table.
        // `removed_at` is audit-only metadata — mirrors BundleStore's `created_at`
        // SystemTime stamp; not a deterministic computation input. Epoch
        // MILLISECONDS: it lands in a `TypedValue::Timestamp`, a millisecond codec.
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.removed_source_store.mark_removed(source_id, now_ms)?;
        Ok(())
    }

    // ── Hard-delete erasure (secfix/ws2-coredelete) ──

    /// Zero all verbatim chunk text for `source_id` and remove it from recall.
    ///
    /// Hard-delete variant of `remove()`. `remove()` suppresses recall but
    /// leaves chunk text in the chunks table. `expunge()` additionally zeroes
    /// the `text` column for every chunk of this source via
    /// `BundleStore::scrub_text()`, ensuring content is unrecoverable.
    ///
    /// Call sequence: scrub text first so content is gone even if the
    /// subsequent remove steps fail. Mirrors Swift `Corpus.expunge(sourceID:)`.
    /// (secfix/ws2-coredelete: hard-delete destruction contract)
    pub fn expunge(&self, source_id: &str) -> CorpusKitResult<()> {
        // Step 1: zero verbatim text in the chunks table.
        self.bundle_store.scrub_text(source_id)?;
        // Step 2: remove from recall — invertedIndex, vectorStore, removedSourceStore.
        self.remove(source_id)
    }

    /// Count the chunks in the bundle store across all ACTIVE sources.
    ///
    /// A removed source's chunks remain stored; they are excluded here so the
    /// count reflects live recall content. Fast path (a plain row count) when
    /// nothing is removed.
    pub fn count(&self) -> CorpusKitResult<usize> {
        let removed = self.removed_source_store.removed_ids()?;
        if removed.is_empty() {
            return self.bundle_store.count(None);
        }
        let all = self.bundle_store.all_chunks(None)?;
        Ok(all.iter().filter(|c| !removed.contains(&c.source_id)).count())
    }

    /// Return the set of drawer IDs that have at least one chunk in the store —
    /// i.e. every source_id that has been ingested. Used by `reindex_missing`
    /// to identify already-indexed drawers and skip them in the backfill.
    /// Mirrors Swift `CorpusKit.indexedSourceIDs()`.
    pub fn indexed_source_ids(&self) -> CorpusKitResult<std::collections::HashSet<String>> {
        self.bundle_store.all_source_ids(None)
    }

    /// Resolve chunk IDs to the source (drawer) IDs that own them.
    ///
    /// Reads the warm in-memory `chunk_source_map` (chunk id → source_id)
    /// that `open()` loads and every ingest maintains — no table scan, no
    /// body decode. IDs with no mapping are simply absent from the result.
    ///
    /// Used by `EstateCoordinator::hunt_contradictions` to map vector rows —
    /// which the encode pipeline keys by CHUNK UUID — back to the drawers
    /// whose content they embed. Mirrors Swift
    /// `CorpusKit.sourceIDs(forChunkIDs:)`.
    pub fn source_ids_for_chunks(
        &self,
        ids: &[uuid::Uuid],
    ) -> std::collections::HashMap<uuid::Uuid, String> {
        let map = self.chunk_source_map.lock().unwrap();
        let mut out = std::collections::HashMap::with_capacity(ids.len());
        for id in ids {
            if let Some(source) = map.get(id) {
                out.insert(*id, source.clone());
            }
        }
        out
    }

    // -- Merkle attestation (NT-C1) --

    /// Per-corpus Merkle root for a given source.
    /// Returns `MerkleRoot::empty()` when no metadata row exists.
    pub fn corpus_merkle_root(&self, source_id: &str) -> CorpusKitResult<MerkleRoot> {
        self.bundle_store.corpus_merkle_root(source_id)
    }

    /// Estate-level corpus Merkle root — interior hash over all per-corpus roots.
    /// Returns `MerkleRoot::empty()` when no corpora exist.
    pub fn global_corpus_merkle_root(&self) -> CorpusKitResult<MerkleRoot> {
        self.bundle_store.global_corpus_merkle_root()
    }
}
