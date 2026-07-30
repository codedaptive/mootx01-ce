// CorpusKit.swift
//
// Public entry point for CorpusKit: the Corpus actor.
//
// The actor composes BundleStore (chunk persistence), InvertedIndexStore
// (durable SQLite-backed BM25 keyword recall), VectorStore (vector kNN),
// and an EmbeddingProvider (text → engram) behind a sealed surface.
// Callers see only documents and queries — no VectorKit type is exposed
// on the public API.
//
// EmbeddingModel is a CorpusKit-owned enum so the host can select an
// embedding model without importing VectorKit or naming EmbeddingProvider.
// The deterministic default requires no CoreML model bundle; the named
// model cases (miniLM, mpNet, embeddingGemma) accept a host-supplied
// inference closure and handle tokenization + projection internally.
//
// CorpusKitProviders ships concrete text providers for production use.
// The Corpus actor's EmbeddingModel.miniLM / .mpNet / .embeddingGemma
// cases use the same modelID, projectionSeed, and FNV-1a tokenization
// parameters as CorpusKitProviders — callers that supply a CoreML
// inference closure through EmbeddingModel get consistent storage keys
// and can later switch to CorpusKitProviders directly if preferred.

import EngramLib
import Foundation
import IntellectusLib
import OSLog
import PersistenceKit
import PersistenceKitSQLite
import Synchronization
import QueueKit
import SubstrateLib
import SubstrateML
import SubstrateTypes
import VectorKit

// MARK: - FloatLaneOutcome

/// The observable outcome of a `Corpus.floatNearest` call.
///
/// Dark outcomes (`.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
/// `.emptyQuery`) are EXPECTED degradations — the calling lane degrades
/// gracefully and emits an explainer marker. `.storeError` is NOT expected:
/// it is logged via OSLog and emitted as a telemetry counter so that store
/// failures are never swallowed silently. `.hits` is the happy path.
///
/// Callers must never treat a dark outcome as an error — per the softPrior
/// grammar a dark dense lane means the query runs on the other lanes only,
/// not that the query failed.
public enum FloatLaneOutcome: Sendable {
    /// The lane ran and returned at least one ranked hit.
    ///
    /// - Parameter hits: `(itemID, cosineSimilarity)` pairs, nearest first.
    ///   `itemID` is the `sourceID` the caller ingested under (drawer ID in
    ///   the GLK context). Similarity ∈ [−1, 1], 1.0 = identical direction.
    case hits([(itemID: String, similarity: Float)])

    /// Provider opted out of the float lane — expected, not an error.
    ///
    /// The configured `EmbeddingProvider` threw `VectorKitError.embeddingFailed`
    /// on the embed call, indicating it has no float lane at all (structural
    /// opt-out). This is the normal outcome for the default `.deterministic`
    /// provider and for any provider that does not override `embedFloat`. The
    /// dense lane is dark for this corpus; all other lanes are unaffected.
    ///
    /// Distinct from `.unavailableNoVocabHit`: that case indicates a TRAINED
    /// distributional provider where this specific query's tokens are all
    /// out-of-vocabulary. Both produce no float candidates, but the cause
    /// differs — a structural opt-out vs a vocabulary coverage gap.
    case unavailableProviderOptOut

    /// Trained distributional provider returned no float vector because all
    /// query tokens are out-of-vocabulary (OOV) — expected, not an error.
    ///
    /// The provider HAS a trained basis (vocab is non-empty) but none of the
    /// query's tokens appear in it. This is the normal outcome for a query on
    /// a thinly-trained estate or a query using vocabulary the corpus never saw.
    /// The dense lane is dark for this query; recall continues on other lanes.
    ///
    /// Distinct from `.unavailableProviderOptOut` (provider has no float lane
    /// at all) and from `.unavailableNoFloatRows` (provider supports float but
    /// ingest has not run yet or stored no rows).
    ///
    /// Surface string: `dense_lane:dark:vocabMiss`.
    case unavailableNoVocabHit

    /// No float rows are stored — expected when ingest has not run yet or the
    /// provider opted out during ingest. Dense lane is dark; other lanes are
    /// unaffected.
    case unavailableNoFloatRows

    /// Query was empty or `limit` was zero — the call was a no-op.
    ///
    /// Not a store error; the caller supplied a query that cannot produce
    /// results. No telemetry emitted for this case beyond the outcome itself.
    case emptyQuery

    /// The vector store threw an error during `findNearestFloat`.
    ///
    /// This is NOT an expected degradation. CorpusKit logs the error via OSLog
    /// (category "CorpusKit") and emits a `corpus.float_lane.store_error`
    /// telemetry counter so the failure is observable. The query still succeeds
    /// on the other lanes — this outcome degrades, not fails.
    ///
    /// - Parameter error: The underlying store error. Included for logging at
    ///   the call site; not propagated to the caller as a thrown error.
    case storeError(Error)
}

/// CorpusKit OSLog logger (category "CorpusKit").
///
/// Used by `floatNearest` to log store errors so they are never swallowed.
/// Declared at file scope to avoid repeated Logger construction on the hot path
/// (Logger init is not free on older OS versions).
private let corpusLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

// MARK: - EmbeddingModel

/// Selects the embedding model the Corpus actor uses internally.
///
/// The caller names a CorpusKit case; no VectorKit type is required
/// at the call site.
///
/// `.deterministic` is the permanent, federation-grade vector provider
/// present in every version (v1.0+). It uses FNV-1a tokenization +
/// FloatSimHash projection, requires no CoreML model bundle, and produces
/// byte-identical vectors cross-device and cross-port — the reproducibility
/// federation requires. It captures surface/lexical signal, not learned
/// semantic meaning.
///
/// The named model cases (`.miniLM`, `.mpNet`, `.embeddingGemma`) are the
/// ADDITIVE v1.1 on-device learned semantic lane. They produce richer,
/// model-dependent vectors for enhanced on-device search but cannot serve
/// as the federation vector (model weights differ across devices). They do
/// not replace the deterministic lane; both lanes coexist.
public enum EmbeddingModel: Sendable {

    /// Permanent, federation-grade deterministic vector provider.
    ///
    /// Uses FNV-1a tokenization + FloatSimHash projection with a fixed
    /// seed (`0xC05BD15CA15D1B00`). Produces byte-identical 32-element
    /// float vectors across calls, across Swift/Rust ports, and across
    /// devices — the reproducibility federation requires. Captures
    /// surface/lexical signal; not a learned semantic embedding.
    ///
    /// This is NOT a test stand-in or placeholder. It is the vector
    /// representation that every version of the system (v1.0 through
    /// any future version) uses for the federation-synchronized lane.
    case deterministic

    /// MiniLM v6 text embedding (384-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 30522, max 128
    /// tokens) and FloatSimHash projection with the canonical MiniLM
    /// seed. The caller supplies the CoreML inference closure.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 384-element float vector.
    case miniLM(inference: @Sendable ([Int32]) async throws -> [Float])

    /// MPNet base v2 text embedding (768-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 30522, max 128
    /// tokens) and FloatSimHash projection with the canonical MPNet
    /// seed.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 768-element float vector.
    case mpNet(inference: @Sendable ([Int32]) async throws -> [Float])

    /// Embedding-Gemma 300M (768-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 256000, max 2048
    /// tokens) and FloatSimHash projection with the canonical
    /// EmbeddingGemma seed.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 768-element float vector.
    case embeddingGemma(inference: @Sendable ([Int32]) async throws -> [Float])

    /// Random Indexing distributional-semantics provider.
    ///
    /// The caller constructs and trains a `RandomIndexingProvider` from
    /// `CorpusKitProviders`, then passes it here. The trained provider is
    /// self-contained: it requires no CoreML model bundle, no host inference
    /// closure, and captures co-occurrence semantics from the estate's own
    /// content during training.
    ///
    /// Unlike the named model cases, `.randomIndexing` carries the fully-built
    /// provider rather than an inference closure, because the provider state
    /// (the trained vocabulary) is built externally by the caller before
    /// constructing the Corpus.
    ///
    /// See honest semantic fusion for the rationale and `RandomIndexingProvider`
    /// in `CorpusKitProviders` for the full training API.
    case randomIndexing(provider: any EmbeddingProvider & Sendable)

    /// PPMI distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes a `PpmiProvider` from
    /// `CorpusKitProviders`, then passes it here.  Unlike RI, PPMI accumulates
    /// co-occurrence counts in a first pass and then computes PPMI-weighted
    /// context sums in a second pass (via `PpmiProvider.finalize()`).
    ///
    /// PPMI differs from RI in that each context term's contribution is
    /// weighted by its PPMI score (max(0, log(P(t,c)/(P(t)·P(c))))).
    /// Stopword-like co-occurrences are down-weighted toward zero; genuinely
    /// informative associations dominate.  The distinction is real: it is not
    /// an alias for `.randomIndexing`.
    ///
    /// See honest semantic fusion for the rationale and `PpmiProvider`
    /// in `CorpusKitProviders` for the full training API.
    case ppmi(provider: any EmbeddingProvider & Sendable)

    /// LSA (Latent Semantic Analysis) distributional-semantics provider.
    ///
    /// The caller constructs and trains an `LsaProvider` (term-document matrix +
    /// deterministic Jacobi SVD truncated to k dimensions) and passes it here.
    ///
    /// See honest semantic fusion for the rationale and `LsaProvider` in
    /// `CorpusKitProviders` for the full training API.
    case lsa(provider: any EmbeddingProvider & Sendable)

    /// NMF (Non-Negative Matrix Factorization) distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes an `NmfProvider` (TF-weighted
    /// term-document matrix factorized via SubstrateML's NMFAlternatingLeastSquares
    /// with fixed iteration count for determinism) and passes it here.
    ///
    /// Document embeddings are the L2-normalised column vectors of the H factor;
    /// query embeddings use the pseudo-inverse fold-in formula on W.
    ///
    /// See honest semantic fusion for the rationale and `NmfProvider` in
    /// `CorpusKitProviders` for the full training API.
    case nmf(provider: any EmbeddingProvider & Sendable)

    /// FDC (Frame Decimal Classification) co-classification provider.
    ///
    /// The caller constructs an `FDCProvider` from `CorpusKitProviders` and
    /// passes it here. The provider is stateless — no training step is required.
    /// It encodes text to a deterministic float vector derived from the text's
    /// FDC classification code, such that codes sharing a longer prefix (more
    /// common ancestors in the FDC taxonomy) have higher cosine similarity.
    ///
    /// Unlike the distributional providers (RI/PPMI/LSA/NMF), FDCProvider
    /// requires no corpus training — it is ready to use immediately. Its recall
    /// signal reflects taxonomic proximity (class co-membership), not
    /// co-occurrence. The two signal types complement each other: distributional
    /// methods are strong on topical neighbours; FDC is strong on categorical siblings.
    ///
    /// The float lane is dark (returns `[]`) for texts the FDC engine cannot
    /// classify (UNRESOLVED). This is the expected opt-out, not an error.
    ///
    /// See honest semantic fusion (FDC lattice co-classification) and `FDCProvider`
    /// in `CorpusKitProviders` for the encoding details.
    case fdc(provider: any EmbeddingProvider & Sendable)

#if canImport(NaturalLanguage)
    /// Apple NaturalLanguage sentence embedding provider (Swift-only).
    ///
    /// Uses `NLEmbedding.sentenceEmbedding(for:)` — the OS-bundled sentence
    /// similarity model (macOS 12+/iOS 15+). No model asset download, no
    /// CoreML dependency. Lower quality than `NLContextualEmbeddingProvider`
    /// but immediately available on any macOS/iOS device.
    ///
    /// This is an ADDITIVE lane — it does not replace the deterministic or
    /// distributional providers. It is ITEM-LOCAL: the vector is a pure
    /// function of the input text computed once on write; no training step.
    ///
    /// When the OS has no sentence-embedding model for the configured language,
    /// this lane opts out gracefully (`embedFloat` returns `[]` → the corpus
    /// layer maps to `unavailableProviderOptOut`).
    ///
    /// Swift-only: `NaturalLanguage` is an Apple system framework (same
    /// sanctioned divergence as the `.nlTagger` word-class path). Rust has no
    /// counterpart. Recorded in opt-in Apple embedding providers.
    case nlEmbedding(provider: any EmbeddingProvider & Sendable)

    /// Apple NaturalLanguage contextual (transformer) embedding provider (Swift-only).
    ///
    /// Uses `NLContextualEmbedding` — an on-device transformer model that
    /// produces contextual per-token representations, mean-pooled to a sentence
    /// embedding. Higher quality than `.nlEmbedding` at the cost of a
    /// downloadable language asset that may not be present on first use.
    ///
    /// When the asset is unavailable, this lane opts out gracefully (`embedFloat`
    /// returns `[]` → `unavailableProviderOptOut`). The provider NEVER blocks on
    /// a download; asset prefetch is the host app's responsibility via
    /// `NLContextualEmbedding.requestAssets(for:completionHandler:)`.
    ///
    /// This is an ADDITIVE lane — item-local, no training step, no basis.
    ///
    /// Swift-only: same sanctioned divergence as `.nlEmbedding`. Rust has no
    /// counterpart. Recorded in opt-in Apple embedding providers.
    case nlContextualEmbedding(provider: any EmbeddingProvider & Sendable)
#endif // canImport(NaturalLanguage)

    /// Default: deterministic (no CoreML required).
    public static let `default`: EmbeddingModel = .deterministic

    // MARK: - Trainable-basis seam (mission 6a-ii-α)

    /// The provider this model carries, if the case carries one.
    ///
    /// The distributional and FDC cases carry an externally-built provider;
    /// the deterministic and named-model cases carry an inference closure (or
    /// nothing) and construct their provider lazily in `makeProvider()`. This
    /// accessor is the join point for the trainable-basis seam: it returns the
    /// carried provider so `reconstruct(from:)` and `isTrainable` can probe its
    /// `TrainableEmbeddingBasis` conformance without re-running construction.
    private var carriedProvider: (any EmbeddingProvider & Sendable)? {
        switch self {
        case .randomIndexing(let p), .ppmi(let p), .lsa(let p), .nmf(let p), .fdc(let p):
            return p
        // The Apple NL cases carry a provider (EmbeddingProvider & Sendable), but like FDC
        // they are stateless — no TrainableEmbeddingBasis conformance. We return the carried
        // provider here so callers that need the provider instance (e.g. direct inspection)
        // can obtain it, mirroring the FDC pattern. `isTrainable` will still be false
        // because neither NL provider conforms to TrainableEmbeddingBasis.
#if canImport(NaturalLanguage)
        case .nlEmbedding(let p), .nlContextualEmbedding(let p):
            return p
#endif
        case .deterministic, .miniLM, .mpNet, .embeddingGemma:
            return nil
        }
    }

    /// Whether this model's provider can be trained on a corpus and
    /// reconstructed from a serialized basis.
    ///
    /// True only when the carried provider conforms to
    /// `TrainableEmbeddingBasis` (the RI/PPMI/LSA/NMF distributional
    /// providers). FDC carries a provider but is stateless and does NOT
    /// conform, so it reports `false`. The deterministic and named-model
    /// cases carry no provider and report `false`.
    ///
    /// This is the capability-detection helper `Corpus` will use (β mission)
    /// before attempting to drive training/serialization through the seam. It
    /// changes no runtime behaviour on its own.
    public var isTrainable: Bool {
        carriedProvider is TrainableEmbeddingBasis
    }

    /// Reconstruct the provider for this model from a serialized basis blob.
    ///
    /// Dispatched by the enum case, which knows whether its carried provider
    /// is a `TrainableEmbeddingBasis`. A type-erased value cannot reconstruct
    /// itself into its concrete type, so reconstruction is routed through the
    /// `TrainableEmbeddingBasis.reconstructBasis(from:)` witness on the carried
    /// provider — which IS the right concrete type and delegates to that
    /// type's `init(deserializing:)`. CorpusKit core never names the concrete
    /// provider type, so layering (providers → core) is preserved.
    ///
    /// The deterministic and named-model cases, and the stateless FDC case,
    /// have no trained basis to restore and throw `CorpusKitError.notTrainable`
    /// rather than crashing or returning a wrong provider.
    ///
    /// - Parameter basis: the serialized basis blob (from `serializeBasis()`).
    /// - Returns: a reconstructed provider, type-erased.
    /// - Throws: `CorpusKitError.notTrainable` when the model is not a
    ///   trainable-basis conformer; `CorpusKitError.decodingFailure` when the
    ///   blob is truncated, the format version is unknown, or the provider
    ///   magic does not match the carried provider's type.
    public func reconstruct(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        guard let trainable = carriedProvider as? TrainableEmbeddingBasis else {
            throw CorpusKitError.notTrainable(
                "embedding model is not a trainable-basis provider; reconstruction "
                + "from a serialized basis is only supported for RI/PPMI/LSA/NMF")
        }
        return try trainable.reconstructBasis(from: basis)
    }
}

// MARK: - Corpus

/// Unified RAG entry point for CorpusKit.
///
/// Corpus composes BundleStore, InvertedIndexStore, VectorStore, and one OR MORE
/// EmbeddingProviders internally. The public surface exposes only
/// `ingest`, `recall`, `remove`, and `count`. No VectorKit type
/// appears in any public signature — the sealed-vector principle is
/// enforced here, not by the caller.
///
/// ## BM25 persistence (cold-start fix)
///
/// `BM25Index` (the former in-memory-only index) is replaced by `InvertedIndexStore`
/// — a SQLite-backed sidecar that persists term frequencies and document lengths so
/// that keyword recall survives a process restart WITHOUT replaying all chunk bodies.
/// On open, `InvertedIndexStore.open()` loads the compact term-freq rows into RAM;
/// `chunkSourceMap` is warm-loaded via a body-free `(id, source_id)` projection from
/// the chunks table. Neither load touches the `text` column, so cold-start cost is
/// O(terms + docs) rather than O(N·body). `BM25Index` is preserved as a public
/// CorpusKit primitive (other callers may use it) — `Corpus` simply no longer uses it.
///
/// Lifecycle: construct with a PersistenceKit Storage (the actor calls
/// `storage.open(schema:)` for both BundleStore and VectorStore during
/// `init`), then call `ingest` to add documents and `recall` to query.
/// `remove(sourceID:)` clears the recall index (BM25 + vectors) without
/// deleting content rows. `expunge(sourceID:)` additionally zeroes chunk text.
///
/// ## N-provider capability (mission 6a-iii-core)
///
/// Corpus holds an ORDERED collection of provider slots, one per held
/// `EmbeddingModel`, each keyed by its `modelID`. The single-provider
/// `init(storage:model:)` is the N=1 special case: it builds a one-slot
/// corpus that behaves byte-identically to the pre-6a-iii single-provider
/// implementation. Multi-provider `init(storage:models:)` fans every
/// operation (ingest embed, reindex train, remove, destroy) across all slots,
/// each under its own `modelID`, so the VectorStore/BasisStore — already keyed
/// by (modelID, modelVersion) — hold the N providers' rows side by side with
/// no schema change.
///
/// The single-signal entry points (`recall`, `floatNearest`, `embed`,
/// `embedFloat`, `modelID`, `supportsFloat`) delegate to the DEFAULT signal —
/// the first held slot — so existing callers are unaffected. The per-signal
/// fan-out for recall is exposed additively via `floatNearestPerSignal`, the
/// 6b RRF-fusion seam (this mission builds the seam, NOT the fusion).
/// The encode SPEED a corpus's ingest drain runs its embedding work at — the
/// user/AI-declared QoS. This is the SPEED axis ONLY; the write strategy (bulk
/// transaction vs stream) is chosen automatically by source size, never by this
/// setting. Mirrors Rust `EncodeSpeed`.
public enum EncodeSpeed: Sendable {
    /// Push the cores: the embed fan-out uses all logical cores. Default — the
    /// user is waiting for content to become searchable.
    case foreground
    /// Yield to the machine: the embed fan-out is capped to ~a quarter of cores,
    /// for very large imports where draining hard would saturate the host.
    case background
}

public actor Corpus {

    /// `ingestBatch` transaction-window sizes. The corpus shares the estate's
    /// primary SQLite connection (single-writer at the file level), so committing
    /// every `commitChunkItems` items / `commitChunkRows` rows bounds how long a
    /// transaction holds the write lock — long enough to amortise the
    /// fsync/WAL-checkpoint cost ~chunk-fold, short enough not to starve
    /// concurrent LocusKit captures / the governor. Items are coarser than rows
    /// (~providers × lanes × sub-chunks per item), so the row window is larger.
    /// Mirrored by the Rust twin's COMMIT_CHUNK_ITEMS / COMMIT_CHUNK_ROWS.
    static let commitChunkItems = 512
    static let commitChunkRows = 4096

    /// The encode drain's SPEED (user/AI-declared via the import `mode`).
    /// `.foreground` (default) embeds across all logical cores; `.background`
    /// caps embed concurrency to ~a quarter of cores (see `embedConcurrencyCap`)
    /// so a very large import leaves the machine headroom. SPEED axis only — the
    /// write strategy is size-gated, not set here. Read when sizing the embed
    /// fan-out in `ingest` / `ingestBatch`; set via `setEncodeSpeed`.
    private var encodeSpeed: EncodeSpeed = .foreground

    /// Max concurrent embed operations for the current `encodeSpeed` (T1 QoS
    /// throttle). Foreground uses all logical cores (push hard); background uses
    /// `cores / 4` (floor 1) so a large background import leaves ~75% of the
    /// machine free for the resident daemon / the user. Uniform across platforms
    /// via `activeProcessorCount`; identical formula to the Rust port
    /// (`available_parallelism() / 4`). The `/ 4` divisor (x=4) is the one tuning
    /// knob — change it here to adjust background headroom.
    private var embedConcurrencyCap: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch encodeSpeed {
        case .foreground: return max(1, cores)
        case .background: return max(1, cores / 4)
        }
    }

    /// Run `work` over `inputs` with at most `cap` operations in flight, results
    /// returned in input order. Bounds concurrency by processing `inputs` in
    /// contiguous batches of `cap` with a barrier between batches — the embed QoS
    /// throttle (T1). Identical shape to the Rust `thread::scope` chunked
    /// fan-out, so both ports throttle the same way.
    private func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        cap: Int,
        _ work: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(cap >= 1)
        var results = [Output?](repeating: nil, count: inputs.count)
        var start = 0
        while start < inputs.count {
            let end = min(start + cap, inputs.count)
            try await withThrowingTaskGroup(of: (Int, Output).self) { group in
                for i in start..<end {
                    let input = inputs[i]
                    group.addTask { (i, try await work(input)) }
                }
                for try await (i, out) in group { results[i] = out }
            }
            start = end
        }
        return results.map { $0! }
    }

    /// Set the drain's encode SPEED. Called by the import path mapping the `mode`
    /// arg of `moot_palace_import`; affects embed fan-outs sized after this call.
    /// Mirrors Rust `Corpus::set_encode_speed`.
    public func setEncodeSpeed(_ speed: EncodeSpeed) {
        encodeSpeed = speed
    }

    /// One held embedding provider plus its fresh-basis blob.
    ///
    /// A slot is the per-provider unit the N-provider corpus fans operations
    /// over. `provider` is the serving provider (replaced in place by training
    /// or by load-on-open reconstruction — hence `var`); `freshBasisBlob` is
    /// the EMPTY (untrained) serialized basis captured ONLY for a fresh
    /// trainable provider with no persisted basis (see the field doc below).
    /// For N=1 the corpus holds exactly one slot, and every fan-out loop runs
    /// once — byte-identical to the pre-6a-iii single-provider path.
    private struct ProviderSlot {
        /// The serving provider for this signal. `var` because the load-on-open
        /// path and each training pass install a replacement. Never exposed on
        /// the public surface (sealed-vector principle).
        var provider: any EmbeddingProvider
        /// The serialized EMPTY (untrained) basis of a trainable provider — the
        /// from-scratch factory. Non-nil for EVERY trainable slot (RI/PPMI/LSA/
        /// NMF), whether the slot was built fresh OR restored from a persisted
        /// basis on open; nil only for non-trainable slots (deterministic / named
        /// / FDC / NL).
        ///
        /// Each training pass (`reindex` and the first-ingest auto-train)
        /// reconstructs a FRESH provider from this empty-basis blob, trains it on
        /// the full corpus, and installs it as `provider`. This is the only
        /// correct retrain semantics: `trainOnCorpus` is ADDITIVE (it accumulates
        /// over calls), so retraining an already-trained provider would
        /// double-count the corpus. Reconstructing from the empty blob guarantees
        /// every train starts from scratch, so reindex is idempotent and produces
        /// the canonical from-scratch basis (the cross-port conformance contract).
        ///
        /// Keeping the factory for a reopened-from-basis slot (rather than nilling
        /// it as the pre-P3 code did) is the frozen-after-restart fix: a restarted
        /// corpus can now retrain on `reindex` and fold new content into the
        /// basis, instead of being permanently stuck re-embedding under the basis
        /// it loaded. The first-ingest auto-train path is unchanged — it still
        /// gates on "no basis persisted yet", so a reopened corpus does not
        /// auto-train on ingest; only explicit `reindex` retrains.
        let freshBasisBlob: Data?
        /// The dedicated maintained-counts accumulator for a trainable slot (P3),
        /// a fresh trainable provider held SEPARATELY from `provider`. The counts
        /// table is grown by folding each written chunk into this accumulator
        /// (`addToCounts`) and persisted at batch boundaries. It must NOT be the
        /// serving `provider`: for LSA/NMF, growing the maintained vocabulary
        /// would desync the serving provider's basis-aligned vocab from its
        /// frozen SVD/NMF factors. nil for non-trainable slots. `var` because the
        /// on-open path restores persisted counts into it.
        var countsAccumulator: (any TrainableEmbeddingBasis)?
        /// Documents (chunks) folded into `countsAccumulator` — the doc-count
        /// growth anchor persisted alongside the counts blob. Tracked here (not
        /// read off the provider) so it is uniform across RI/PPMI/LSA/NMF whose
        /// providers track document count inconsistently. Restored from the
        /// persisted anchor on open, incremented per folded chunk.
        var countsDocumentCount: Int
    }

    /// The estate's backing storage, retained so the ingest queue can choose a
    /// durable on-disk maildir backend when the estate is file-backed (SQLite)
    /// versus a transient in-memory queue when the estate is in-memory. See
    /// `mountIngestQueue`. Internal (not private) so the `CorpusIngestQueue`
    /// extension in its own file can read the backend kind.
    let storage: any Storage
    private let bundleStore: BundleStore
    /// SQLite-backed durable inverted index — replaces the former in-memory BM25Index
    /// so BM25 keyword state persists across process restarts. Loaded into RAM on open
    /// via `open()` (reads iix_termfreqs + iix_doclens rows; no chunk bodies touched).
    private let invertedIndex: InvertedIndexStore
    private let vectorStore: VectorStore
    private let basisStore: BasisStore
    /// Persisted, incrementally-maintained per-provider statistics (the counts
    /// table). Holds each trainable provider's additive state so it is grown on
    /// write and read at refactor instead of rebuilt from scratch (P3 wiring
    /// lands the write/refactor uses; this store is the durable home).
    private let countsStore: CorpusProviderCountsStore
    /// Records which source IDs have been removed (recall-suppressed). This
    /// store lets every chunk-replay path (reindex, first-ingest train, count)
    /// EXCLUDE removed sources so they cannot resurface — the auto-reindex
    /// resurrection fix. (BM25 is no longer rebuilt from chunks on open — it
    /// loads from the durable InvertedIndexStore and `remove(sourceID:)` deletes
    /// the removed source's rows from it directly.) Re-ingesting a source clears
    /// its row (reactivation).
    private let removedSourceStore: RemovedSourceStore
    /// The ordered per-provider slots, one per held `EmbeddingModel`, in
    /// construction order. `slots[0]` is the DEFAULT signal that the
    /// single-signal entry points delegate to. Never empty: every init builds
    /// at least one slot. For N=1 this holds exactly one slot.
    private var slots: [ProviderSlot]
    private var hlcGenerator: HLCGenerator
    /// Maps chunk UUID → sourceID for the `bm25TopKBySource` and `floatNearest` joins.
    ///
    /// Populated on `init` via a compact `(id, source_id)` projection from the chunks
    /// table (no body text loaded — O(N) row count only). Updated on each `ingest`
    /// call. Cleared per-source on `remove(sourceID:)`. In-memory only; warm-loaded
    /// on every open alongside `InvertedIndexStore.open()` so both stay in sync.
    private var chunkSourceMap: [UUID: String] = [:]

    /// Test-only: when non-nil, `floatNearest` returns `.storeError(this)` immediately,
    /// bypassing the real vector store. Set via `_testForceFloatStoreError(_:)`.
    /// Never set in production code; documented here so future agents do not mistake
    /// this property for production logic.
    var _forcedFloatError: Error? = nil

    // MARK: - Ingest queue (the Corpus-owned encode pipeline)
    //
    // CorpusKit is a standalone database substrate: it owns the encode QUEUE,
    // its DRAIN worker, and the bounded WORKER POOL that feeds `ingestBatch`,
    // talking directly to QueueKit + PersistenceKit. A Corpus queues, drains,
    // and encodes itself with no orchestrator. GeniusLocusKit only COORDINATES
    // — it enqueues work and (via `onEncoded`) rolls up the touched LocusKit
    // rooms — it never performs the encode itself. The state below is the
    // per-corpus ingest pipeline; see CorpusIngestQueue.swift for the methods.

    /// The Corpus-owned ingest queue. nil until `mountIngestQueue()` (mounted at
    /// construction by an orchestrator, or lazily on the first `enqueueIngest`).
    /// Backed by a transient in-memory PersistenceKit backend so it needs no
    /// estate file directory and works for in-memory corpora — the same
    /// substrate the standing-signal scheduler queue uses.
    var ingestQueue: QueueKit?

    /// The background drain worker that pulls every currently-available job off
    /// `ingestQueue` each pass and ingests the whole batch via `ingestBatch`
    /// (cross-document parallel compute, serial batched writes — the bounded
    /// worker pool). Spawned in `mountIngestQueue`, cancelled in
    /// `dropIngestQueue`. The poll loop runs at default priority; the heavy
    /// embedding work it spawns is throttled to the concurrency declared by
    /// `encodeSpeed` — all cores for foreground, ~a quarter for background (see
    /// `embedConcurrencyCap`, applied in `ingest` / `ingestBatch`).
    var ingestDrainWorker: Task<Void, Never>?

    /// Single-drainer lease for a file-backed estate (T2/T4). Non-nil only when the
    /// estate is durable (multiple processes can open it); `nil` for in-memory
    /// estates, which are single-process and need no lease. The drain loop drains
    /// a pass only while it holds this lease, so exactly one process drains the
    /// shared `encode` stream at a time. Stream-keyed (`"encode"`) so the dreaming
    /// drainer can hold its own lease concurrently. Released in
    /// `dropIngestQueue`. Uses the QueueKit-provided `DrainLease` (T2).
    var drainLease: DrainLease?

    /// The discrete bulk-IMPORT drain worker — claims only `"import"` jobs off the
    /// SAME queue and ingests them via `ingestBatchImport` (chunk + BM25 only; no
    /// bootstrap train, no embed — the import cycle retrains + embeds once at the
    /// end via `reindex`). Daily-driving live captures stay on the encode worker
    /// above, untouched. Spawned in `mountIngestQueue`, cancelled in
    /// `dropIngestQueue`.
    var importDrainWorker: Task<Void, Never>?

    /// Single-drainer lease for the `"import"` stream — the import twin of
    /// `drainLease`, so each stream has exactly one cross-process drainer,
    /// independently. Non-nil only for durable estates.
    var importDrainLease: DrainLease?

    /// The import drainer's OWN queue facade over its OWN connection to the same
    /// queue.sqlite (SQLite estates). Both drainers run multi-statement
    /// transactions; sharing one connection lets one worker's BEGIN land inside
    /// the other's open transaction. A second connection moves arbitration to the
    /// file level (WAL + busy timeout) — SQLite's native single-writer contract.
    /// nil → the import worker shares `ingestQueue` (in-memory estates:
    /// transactions are no-ops there, and a second InMemoryStorage would be a
    /// DIFFERENT queue entirely).
    var importQueue: QueueKit?

    /// Per-corpus HLC for stamping ingest-queue submissions. Distinct from
    /// `hlcGenerator` (which sequences chunks within the store): this one orders
    /// only the queue, derived from each item's capture instant so submission
    /// stamps are deterministic (no `Date()` in the engine).
    var ingestHLC = HLCGenerator(nodeID: 1)

    /// Invoked AFTER each drained batch finishes ingesting, with the sourceIDs
    /// that were encoded (drawer ids in the GLK context). nil when the Corpus
    /// runs standalone. The orchestrator (GeniusLocusKit) sets this to roll up
    /// the touched LocusKit rooms for the encoded drawers — coordination only;
    /// CorpusKit never reaches into LocusKit itself (layering: GLK orchestrates).
    public var onEncoded: (@Sendable ([String]) async -> Void)?

    /// The estate's single dense vector store (binary Engram + float32 lanes),
    /// owned by this Corpus. The composition layer (GeniusLocusKit) borrows THIS
    /// instance for its scored-recall vector lane instead of constructing a second
    /// `VectorStore` over the same `vectors` table — one store, one resident array,
    /// one on-disk sidecar. CorpusKit owns the dense vector lane; the orchestrator
    /// reaches it through this accessor rather than reaching around the kit.
    public var sharedVectorStore: VectorStore { vectorStore }

    /// Test-only ingest failure hook. When non-nil, the per-job retry path
    /// invokes it with the job's sourceID BEFORE ingesting; a throw simulates a
    /// transient ingest failure so the at-least-once retry/`.blocked` semantics
    /// are exercisable. nil in production (zero overhead). Set via
    /// `_armIngestFailureHook(_:)`.
    var _ingestFailureHook: (@Sendable (String) throws -> Void)?

    /// Construct a single-provider Corpus against a PersistenceKit Storage.
    ///
    /// This is the N=1 entry point. It delegates to `init(storage:models:)`
    /// with a one-element model set, so a single-provider corpus is just the
    /// degenerate case of the N-provider corpus — ONE code path, not two — and
    /// behaves byte-identically to the pre-6a-iii single-provider
    /// implementation. The production default remains a single provider; this
    /// init's signature is PRESERVED so every existing call site compiles
    /// unchanged (mission 6a-iii-core back-compat mandate).
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance. Both the
    ///     BundleStore and VectorStore schemas are applied here; if the
    ///     same storage is shared with other kits their schemas must be
    ///     applied separately before or after this call.
    ///   - model: Embedding model selection. Defaults to `.deterministic`
    ///     (no CoreML required).
    public init(storage: any Storage, model: EmbeddingModel = .default) async throws {
        try await self.init(storage: storage, models: [model])
    }

    /// Construct an N-provider Corpus against a PersistenceKit Storage.
    ///
    /// Builds one ordered provider slot per element of `models`, each keyed by
    /// its `modelID`. `models[0]` becomes the DEFAULT signal that the
    /// single-signal entry points (`recall`, `floatNearest`, `embed`,
    /// `embedFloat`, `modelID`, `supportsFloat`) delegate to. Every fan-out
    /// operation (ingest embed, reindex train, remove, destroy) runs across all
    /// slots, each under its own modelID — the VectorStore/BasisStore are
    /// already keyed by (modelID, modelVersion), so N providers' rows coexist
    /// with no schema change.
    ///
    /// For each slot: build the fresh provider, then — if it is a trainable
    /// distributional provider AND a basis was previously persisted for its
    /// (modelID, modelVersion) — reconstruct the trained provider from that
    /// blob so the dense lane is trained-ready immediately after restart,
    /// without re-running training on every open. A non-trainable provider, or
    /// a trainable provider with no persisted basis yet, keeps the fresh one.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance (schemas applied here).
    ///   - models: One or more embedding model selections, in priority order.
    ///     Must be non-empty; `models[0]` is the default signal. Distinct
    ///     `modelID`s are expected — two slots with the same modelID would key
    ///     the same vector/basis rows and is a caller error.
    public init(storage: any Storage, models: [EmbeddingModel]) async throws {
        guard !models.isEmpty else {
            throw CorpusKitError.storeUnavailable("Corpus requires at least one embedding model")
        }

        // Apply both schema declarations. `open(schema:)` is version-gated
        // (skips if the schema version is already current). Since both
        // BundleStore and VectorStore are version 1, the second `open` would
        // be skipped when called on the same storage; `migrate(to:)` bypasses
        // the gate and ensures all tables are created regardless of which
        // schema was applied first.
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        // Additive basis-persistence table (mission 6a-ii-β). A separate
        // schema declaration applied via migrate(to:) so the table is created
        // regardless of the other schemas' version gates, exactly like the
        // BundleStore/VectorStore pair above.
        try await storage.migrate(to: BasisStore.schemaDeclaration)
        // Additive maintained-counts table (P3): created via migrate like the
        // BasisStore pair so it exists regardless of the other schemas' gates.
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        // Additive removed-sources table: created via migrate like the others.
        try await storage.migrate(to: RemovedSourceStore.schemaDeclaration)
        // Durable inverted-index sidecar tables (F1 cold-start fix). Additive
        // via migrate so the tables are created alongside the others regardless
        // of which schema was applied first.
        try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)

        self.storage = storage
        self.bundleStore = BundleStore(storage: storage)
        // InvertedIndexStore replaces the former in-memory BM25Index. Shares
        // the same storage backend so iix_termfreqs/iix_doclens live in the
        // same SQLite file as chunk rows — no extra file, no extra connection.
        self.invertedIndex = InvertedIndexStore(storage: storage)
        self.vectorStore = VectorStore(storage: storage, sidecarURL: VectorStore.defaultSidecarURL(for: storage))
        self.basisStore = BasisStore(storage: storage)
        self.countsStore = CorpusProviderCountsStore(storage: storage)
        self.removedSourceStore = RemovedSourceStore(storage: storage)

        // Build one slot per model, resolving each against any persisted basis.
        // The resolution per slot is exactly the single-provider resolve, so a
        // one-element `models` produces the byte-identical single-slot state.
        var built: [ProviderSlot] = []
        built.reserveCapacity(models.count)
        for model in models {
            let freshProvider = model.makeProvider()
            let resolved = try await Self.resolveProvider(
                freshProvider: freshProvider,
                isTrainable: model.isTrainable,
                basisStore: basisStore,
                countsStore: countsStore
            )
            built.append(ProviderSlot(
                provider: resolved.provider,
                freshBasisBlob: resolved.freshBasisBlob,
                countsAccumulator: resolved.countsAccumulator,
                countsDocumentCount: resolved.countsDocumentCount))
        }
        self.slots = built
        // nodeID 1: Corpus is a standalone actor; HLC ordering is for
        // chunk sequencing within one store, not cross-replica ordering.
        self.hlcGenerator = HLCGenerator(nodeID: 1)

        // Open the durable inverted index — loads iix_termfreqs and iix_doclens
        // rows into RAM. No chunk bodies are read; this is O(terms + docs) not
        // O(N·body). The fresh InvertedIndexStore starts empty; `open()` populates
        // it from persisted rows so keyword recall is immediately available without
        // replaying chunk text through BM25Index.
        try await invertedIndex.open()

        // Warm-load chunkSourceMap from a compact (id, source_id) projection of
        // the chunks table — no body text, no removed-source filter needed here
        // because the map is used for source-level aggregation (a removed source
        // that appears in the map but not in the inverted index simply produces no
        // BM25 hits, so its map entry is harmless). The projection avoids the O(N·body)
        // scan that `activeChunks()` + body decode would incur.
        let pairs = try await bundleStore.chunkSourcePairs()
        for pair in pairs {
            chunkSourceMap[pair.id] = pair.sourceID
        }

        // WS2-F3: backfill corpus_metadata rows for any existing chunks.
        // After a v2→v3 schema upgrade the corpus_metadata table is empty even
        // though chunks exist; globalCorpusMerkleRoot() would return empty until
        // the next insert triggered rollupCorpusMerkleRoot. This call is idempotent
        // (upsert on conflict) and is the only correct place to run it: after
        // migrate(to: BundleStore.schemaDeclaration) creates the table and after
        // bundleStore is assigned, but before any recall path can observe the roots.
        try await bundleStore.recomputeAllCorpusMerkleRoots()
    }

    /// Cancel the ingest drain worker and release the drain lease on actor teardown.
    ///
    /// Called by the Swift runtime when the last reference to this `Corpus` is
    /// released. Cancelling the worker Task and releasing the `DrainLease` lets any
    /// in-progress drain loop exit cleanly and lets the next process that opens the
    /// same estate take the lease immediately rather than waiting out the TTL (15 s).
    ///
    /// A plain (non-isolated) `deinit` may read the actor's own stored properties
    /// directly — the runtime guarantees exclusive access at deinit — so the teardown
    /// touches `ingestDrainWorker`/`drainLease` inline rather than calling the
    /// actor-isolated `dropIngestQueue()`. The `isolated deinit` form (SE-0371) tripped
    /// an actor-isolation inference cycle in the cross-module SIL optimizer under
    /// release whole-module optimization (`error: circular reference` with no source
    /// location); inlining the field access avoids the cycle while preserving the exact
    /// teardown effect (cancel worker + release lease). `Task.cancel()` and the
    /// `DrainLease` struct's `release()` are both non-isolated, so neither needs actor
    /// hops. The explicit orchestrated-teardown path still calls `dropIngestQueue()`.
    ///
    /// Idempotent: both calls are no-ops when the queue was never mounted or was
    /// already dropped via an explicit teardown call (the normal path for
    /// orchestrated estates).
    ///
    /// Rust twin: `impl Drop for Corpus { fn drop(&mut self) { self.drop_ingest_queue(); } }`
    deinit {
        ingestDrainWorker?.cancel()
        drainLease?.release()
        importDrainWorker?.cancel()
        importDrainLease?.release()
    }

    /// The default signal's serving provider — `slots[0].provider`.
    ///
    /// The single-signal entry points read through this accessor so existing
    /// callers see exactly the first held provider, identical to the
    /// pre-6a-iii single-provider behaviour. `slots` is never empty (every init
    /// builds at least one slot), so the force-unwrap of `first` cannot trap.
    private var defaultProvider: any EmbeddingProvider {
        // swiftlint:disable:next force_unwrapping — slots is never empty (init invariant)
        slots.first!.provider
    }

    /// Resolve the serving provider, the empty-basis factory, and the maintained-
    /// counts accumulator on open.
    ///
    /// Used by both inits. Outcomes:
    ///   - Not trainable: serve `freshProvider`; no factory, no accumulator.
    ///   - Trainable, no persisted basis: serve `freshProvider` (untrained).
    ///   - Trainable, basis persisted: reconstruct the trained provider from the
    ///     persisted blob and serve THAT (so the dense lane is trained-ready).
    ///
    /// For EVERY trainable slot — both cases — the empty-basis factory is captured
    /// (`freshProvider.serializeBasis()` on the untrained provider) so `reindex`
    /// can always rebuild a from-scratch trainable provider, INCLUDING after a
    /// restart (the frozen-after-restart fix). The dedicated counts accumulator is
    /// a SEPARATE fresh trainable provider, restored from the persisted counts
    /// table if a row exists; it is held apart from the serving provider so
    /// growing the maintained vocabulary never desyncs an LSA/NMF serving basis.
    ///
    /// Reconstruction routes through the carried provider's
    /// `TrainableEmbeddingBasis.reconstructBasis(from:)` witness — CorpusKit core
    /// never names the concrete provider type, so layering (providers → core) is
    /// preserved. A corrupt/version-mismatched blob throws `decodingFailure`
    /// rather than silently serving an untrained provider.
    private static func resolveProvider(
        freshProvider: any EmbeddingProvider,
        isTrainable: Bool,
        basisStore: BasisStore,
        countsStore: CorpusProviderCountsStore
    ) async throws -> (
        provider: any EmbeddingProvider,
        freshBasisBlob: Data?,
        countsAccumulator: (any TrainableEmbeddingBasis)?,
        countsDocumentCount: Int
    ) {
        guard isTrainable, let trainable = freshProvider as? any TrainableEmbeddingBasis else {
            return (freshProvider, nil, nil, 0)
        }
        // The empty-basis factory: the untrained fresh provider's serialized
        // basis, captured for every trainable slot so reindex can always train
        // from scratch (frozen-after-restart fix).
        let factoryBlob = trainable.serializeBasis()

        // The maintained-counts accumulator: a distinct fresh trainable provider,
        // reconstructed from the empty factory, restored from the counts table if
        // a row exists. Distinct from the serving provider (LSA/NMF desync rule).
        guard let accumulator = try trainable.reconstructBasis(from: factoryBlob)
            as? any TrainableEmbeddingBasis else {
            throw CorpusKitError.notTrainable(
                "reconstructed counts accumulator is not trainable — basis seam invariant violated")
        }
        var accumulatorDocCount = 0
        if let counts = try await countsStore.load(
            modelID: freshProvider.modelID,
            modelVersion: freshProvider.modelVersion
        ) {
            try accumulator.restoreCounts(from: counts.counts)
            accumulatorDocCount = counts.documentCount
        }

        // Serving provider: the trained provider when a basis is persisted, else
        // the untrained fresh provider.
        if let persisted = try await basisStore.load(
            modelID: freshProvider.modelID,
            modelVersion: freshProvider.modelVersion
        ) {
            let restored = try trainable.reconstructBasis(from: persisted.basis)
            return (restored, factoryBlob, accumulator, accumulatorDocCount)
        }
        return (freshProvider, factoryBlob, accumulator, accumulatorDocCount)
    }

    // MARK: - Test seams (internal — not part of the public surface)

    /// Test-only init that accepts an `EmbeddingProvider` directly.
    ///
    /// This seam exists so test suites can inject a custom provider (e.g. one that
    /// throws on `embedFloat`) without affecting production code paths. The public
    /// `init(storage:model:)` is the production entry point; this init is `internal`
    /// so `@testable import CorpusKit` tests can reach it while callers outside the
    /// module cannot.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance.
    ///   - provider: A directly-supplied `EmbeddingProvider`. The caller is
    ///     responsible for providing a provider whose `modelID` and `modelVersion`
    ///     are consistent with any pre-existing vectors in `storage`.
    init(storage: any Storage, provider: any EmbeddingProvider) async throws {
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        try await storage.migrate(to: BasisStore.schemaDeclaration)
        // Additive maintained-counts table (P3): created via migrate like the
        // BasisStore pair so it exists regardless of the other schemas' gates.
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        // Additive removed-sources table: created via migrate like the others.
        try await storage.migrate(to: RemovedSourceStore.schemaDeclaration)

        // InvertedIndexStore sidecar schema: ensure tables exist before open().
        try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)

        self.storage = storage
        self.bundleStore = BundleStore(storage: storage)
        // InvertedIndexStore replaces the former in-memory BM25Index for the
        // test seam, matching the production init. Same durability guarantee:
        // keyword state persists in SQLite and is loaded on open without
        // replaying chunk bodies.
        self.invertedIndex = InvertedIndexStore(storage: storage)
        self.vectorStore = VectorStore(storage: storage, sidecarURL: VectorStore.defaultSidecarURL(for: storage))
        self.basisStore = BasisStore(storage: storage)
        self.countsStore = CorpusProviderCountsStore(storage: storage)
        self.removedSourceStore = RemovedSourceStore(storage: storage)

        // This seam receives a directly-built provider rather than an
        // EmbeddingModel. Trainability is probed via the type-erasure cast
        // `as? any TrainableEmbeddingBasis`, then the same resolveProvider path
        // the production init uses applies: load-on-open reconstructs from a
        // persisted basis (capturing no trainable handle), else the fresh
        // trainable handle is captured for first-ingest/reindex. The injected
        // provider becomes the corpus's single (default) slot — N=1.
        let resolved = try await Self.resolveProvider(
            freshProvider: provider,
            isTrainable: provider is any TrainableEmbeddingBasis,
            basisStore: basisStore,
            countsStore: countsStore
        )
        self.slots = [ProviderSlot(
            provider: resolved.provider,
            freshBasisBlob: resolved.freshBasisBlob,
            countsAccumulator: resolved.countsAccumulator,
            countsDocumentCount: resolved.countsDocumentCount)]
        self.hlcGenerator = HLCGenerator(nodeID: 1)

        // Load the durable inverted index from SQLite and warm-load
        // chunkSourceMap via a compact (id, source_id) projection — no bodies.
        try await invertedIndex.open()
        let pairs = try await bundleStore.chunkSourcePairs()
        for pair in pairs {
            chunkSourceMap[pair.id] = pair.sourceID
        }

        // WS2-F3: backfill corpus_metadata rows for any existing chunks (same
        // as production init — idempotent upsert).
        try await bundleStore.recomputeAllCorpusMerkleRoots()
    }

    /// Test-only: force `floatNearest` to return `.storeError(error)` on the next call.
    ///
    /// Intended for tests that need to verify the store-error code path (observable
    /// degradation contract §4). The error is consumed on the first `floatNearest`
    /// call after this is set; subsequent calls behave normally.
    ///
    /// Never call this in production code. Marked `internal` so it is visible to
    /// `@testable import CorpusKit` test suites and invisible to callers outside the module.
    func _testForceFloatStoreError(_ error: Error) {
        _forcedFloatError = error
    }

    // MARK: - Public API

    /// Ingest text from a source document.
    ///
    /// The text is chunked, stored in the BundleStore (idempotent on
    /// content-addressed ids), indexed for keyword recall in BM25, and
    /// embedded + stored in VectorStore. Re-ingesting the same text for
    /// the same `sourceID` is a no-op: content-addressed chunk ids make
    /// duplicate inserts idempotent at every layer.
    ///
    /// - Parameters:
    ///   - text: Document text to ingest.
    ///   - sourceID: Stable identifier for the source document. Use a
    ///     consistent handle (path, URL string, UUID string) across calls.
    ///   - now: Wall-clock time for vector filing timestamps and
    ///     determinism discipline. Never call `Date()` inside engines;
    ///     pass `now` from the caller.
    public func ingest(_ text: String, sourceID: String, now: Date) async throws {
        let chunks = Chunker.chunk(text: text, sourceID: sourceID, hlcGenerator: &hlcGenerator)
        guard !chunks.isEmpty else { return }

        // (Re-)ingesting a source reactivates it: clear any prior removed-row so
        // it returns to the active set (its vectors + BM25 postings are restored
        // by this ingest). No-op when the source was never removed.
        try await removedSourceStore.clearRemoved(sourceID)

        // `insert` is idempotent (dedups by chunk id); it returns only the
        // chunks ACTUALLY inserted so derived per-chunk state does not
        // double-count on re-ingest of the same source.
        let insertedChunks = try await bundleStore.insert(chunks)
        // Index every chunk into the durable InvertedIndexStore (SQLite-backed).
        // BM25 and the source map are provider-INDEPENDENT (one keyword index
        // per corpus), so they are maintained once, outside the per-provider
        // fan-out below. Re-indexing an existing chunk replaces its term
        // frequencies atomically (InvertedIndexStore.index is idempotent).
        for chunk in chunks {
            try await invertedIndex.index(
                itemID: chunk.id.uuidString,
                tokens: CorpusDefaultTokenizer().keywordTokens(chunk.text),
                now: now
            )
            chunkSourceMap[chunk.id] = chunk.sourceID
        }

        // Maintained-counts write path (P3): fold only the NEWLY-inserted chunks
        // into each trainable slot's counts accumulator — folding a duplicate
        // (idempotent no-op in the bundle store) would inflate the additive
        // counts and the vocab-growth anchor on re-ingest. Independent of the
        // embed fan-out (the accumulator is separate from the serving provider);
        // persisted once at the end of this ingest (the single-doc batch boundary).
        foldChunksIntoCounts(insertedChunks)

        // Fan out the embedding work across every held provider slot in two
        // phases. Phase 1 (serial) handles any first-ingest training and collects
        // the fold-in slots. Phase 2 computes the fold-in slots' embeddings
        // CONCURRENTLY (the CPU-bound cost), then writes each slot's batch
        // serially. For N=1 this is byte-identical to the single-provider ingest.
        // Each slot embeds independently under its own modelID; the
        // VectorStore/BasisStore keys keep the N providers' rows apart.
        // `allChunks` is loaded lazily and shared across slots that need it for
        // either first-ingest train or growth retrain (the corpus snapshot is the
        // same for every provider in the same ingest call).
        //
        // Minimum chunk count the per-doc auto-train grows toward before this
        // slot's basis is considered stable. Below this count a 2× corpus growth
        // triggers a retrain, mirroring Phase 1b's full-corpus-first strategy for
        // the impatient encode path.
        //
        // Failure mode prevented: a single-document first ingest produces a
        // rank-1 LSA SVD (degenerate basis). Without growth retrains, every
        // subsequent per-doc ingest folds onto this 1-doc basis, collapsing all
        // query vectors to ~zero cosine — the Kinsta-verified regression where
        // any@5 recall fell from 0.853 to 0.56 on LongMemEval 50q.
        //
        // Growth retrains stop once trainedChunkCount reaches this threshold;
        // above it only explicit reindex(now:) retrains (same contract as before
        // for a mature corpus). The constant matches Phase 1b's design intent and
        // produces at most log₂(50) ≈ 6 retrains before the basis is stable.
        let perDocAutoRetrainStableChunkThreshold = 50

        var cachedAllChunks: [Chunk]?
        var foldInSlotIndices: [Int] = []
        for index in slots.indices {
            // Three-state basis decision (mission fix for Kinsta-verified bug):
            //
            // (1) First-ingest: no persisted basis yet → train from scratch on
            //     the full CURRENT corpus snapshot (which includes just-inserted
            //     chunks) and re-embed. Same as the original first-ingest path.
            //
            // (2) Growth retrain: a basis exists but was trained on too few
            //     chunks (< stableThreshold) AND the live corpus has grown to
            //     ≥ 2× that count → retrain on the full corpus. This prevents
            //     a rank-1 LSA SVD trained on doc-1-only from persisting as the
            //     frozen basis for the entire early-growth phase. Retrains thin
            //     out exponentially (1→2→4→8→…) and stop at the threshold.
            //     Each retrain starts from freshBasisBlob (the empty-basis
            //     factory) so the result is from-scratch, not additive.
            //
            //     NOTE: "per-ingest retrain would be both wrong and wasteful"
            //     (the original comment) refers to retraining on EVERY ingest
            //     after the basis is stable — that still does not happen. Growth
            //     retrains are capped at log₂(stableThreshold) total.
            //
            // (3) Fold-in: basis is stable (≥ stableThreshold) or hasn't grown
            //     2× → project new chunks onto the frozen basis without retrain.
            //     Explicit reindex(now:) retrains on demand.
            //
            // The auto-train gate is the persistedBasis check below, NOT the
            // factory blob's presence: a reopened-from-basis corpus keeps its
            // factory blob (frozen-after-restart fix) and already has a persisted
            // basis with trainedChunkCount ≥ stableThreshold (after reindex), so
            // it falls through to fold-in and does not auto-train. Training stays
            // SERIAL — it mutates the slot's basis and re-embeds the whole corpus;
            // only the fold-in compute (phase 2) is parallelised. Mirrors Phase 1b.
            if slots[index].freshBasisBlob != nil {
                let slotProvider = slots[index].provider
                let persistedBasis = try await basisStore.load(
                    modelID: slotProvider.modelID,
                    modelVersion: slotProvider.modelVersion
                )

                let needsRetrain: Bool
                if persistedBasis == nil {
                    // Case (1): no basis yet — first-ingest train.
                    needsRetrain = true
                } else if let basis = persistedBasis,
                          basis.trainedChunkCount < perDocAutoRetrainStableChunkThreshold {
                    // Case (2): young basis — load corpus (lazily) and check 2× growth.
                    // Active chunks only: a removed source must not resurface.
                    if cachedAllChunks == nil {
                        cachedAllChunks = try await activeChunks()
                    }
                    needsRetrain = (cachedAllChunks?.count ?? 0) >= basis.trainedChunkCount * 2
                } else {
                    // Case (3): stable basis — fold-in only.
                    needsRetrain = false
                }

                if needsRetrain {
                    // Load corpus snapshot if not already loaded above (case 1
                    // skips the young-basis check). Cached so the second slot in
                    // a multi-slot corpus pays zero extra I/O.
                    let allChunks: [Chunk]
                    if let cached = cachedAllChunks {
                        allChunks = cached
                    } else {
                        allChunks = try await activeChunks()
                        cachedAllChunks = allChunks
                    }
                    try await trainAndPersistBasis(slotIndex: index, chunks: allChunks, now: now)
                    // Re-embed the whole corpus under the freshly-trained basis
                    // so chunks ingested before this retrain fold onto the new,
                    // non-degenerate basis. reembedChunks is delete-first, so no
                    // duplicate rows accumulate.
                    try await reembedChunks(slotIndex: index, allChunks, now: now)
                    continue
                }
            }

            // Fold-in path: basis is stable or provider is not trainable. Embed
            // only the NEW chunks; for a trainable provider `embedFloat` projects
            // them onto the frozen basis (no retrain).
            foldInSlotIndices.append(index)
        }

        // Phase 2: compute the fold-in slots CONCURRENTLY. Each provider slot is
        // independent (distinct modelID, own rows), and `embedPair` is a pure
        // function of the text that runs OFF the Corpus actor (the provider is a
        // Sendable value, not actor-isolated state), so the slots' embedding
        // compute — the dominant CPU cost — runs in parallel on the cooperative
        // pool. The WRITES stay serial: VectorStore is an actor and we await its
        // batched `addPayloads` one slot at a time (SQLite is single-writer).
        // Determinism: each slot's rows are built in chunk order (binary v0 then
        // float v1) and the writes are issued in slot order, so stored rows are
        // byte-identical to the serial path. The chunk.id.uuidString ==
        // vector.item_id join is maintained here (sealed-vector principle; column
        // renamed drawer_id → item_id in Lane F, arch spec §4.1).
        if !foldInSlotIndices.isEmpty {
            // Snapshot the providers (Sendable values) and the per-call inputs on
            // the actor before fanning out, so the child tasks touch no isolated
            // state.
            let foldInProviders: [(provider: any EmbeddingProvider, chunks: [Chunk], now: Date)] =
                foldInSlotIndices.map { (provider: slots[$0].provider, chunks: chunks, now: now) }
            // Embed each provider slot, throttled to embedConcurrencyCap (T1):
            // foreground fans across all cores, background to ~a quarter. Results
            // return in slot order, so the flattened write stays deterministic.
            let perSlotRows: [[VectorPayloadInput]] =
                try await boundedConcurrentMap(foldInProviders, cap: embedConcurrencyCap) { fp in
                    var rows: [VectorPayloadInput] = []
                    rows.reserveCapacity(fp.chunks.count * 2)
                    for chunk in fp.chunks {
                        // Single inference pass: embedPair computes the provider's
                        // pooled vector ONCE and returns both the binary engram and
                        // the dense float vector.
                        let (engram, floats) = try await fp.provider.embedPair(chunk.text)
                        // Binary engram row (vectorIndex 0) — always written.
                        rows.append(VectorPayloadInput(
                            itemID: chunk.id.uuidString,
                            vectorIndex: 0,
                            payload: VectorPayload(engram: engram),
                            modelID: fp.provider.modelID,
                            modelVersion: fp.provider.modelVersion,
                            filedAt: fp.now
                        ))
                        // Float lane (Lane D): vectorIndex 1 (kind=float32), present
                        // only when the provider's float lane is live and the chunk
                        // resolved (`floats` non-empty).
                        if !floats.isEmpty {
                            rows.append(VectorPayloadInput(
                                itemID: chunk.id.uuidString,
                                vectorIndex: 1,
                                payload: VectorPayload(floats: floats),
                                modelID: fp.provider.modelID,
                                modelVersion: fp.provider.modelVersion,
                                filedAt: fp.now
                            ))
                        }
                    }
                    return rows
                }
            // One batched write for the whole document (all provider slots
            // flattened). A single addPayloads call means a single resident-index
            // rebuild for the document instead of one per slot; under the drain's
            // deferred-index window the rebuild is deferred to burst end entirely.
            let allRows = perSlotRows.flatMap { $0 }
            if !allRows.isEmpty {
                try await vectorStore.addPayloads(allRows)
            }
        }

        // Batch boundary: persist the maintained counts + growth anchors once for
        // this document (not per chunk).
        try await persistMaintainedCounts(now: now)
    }

    /// IMPORT-ONLY batch ingest — the DISCRETE bulk-import drain path, kept
    /// separate from `ingestBatch` (which the near-realtime daily-driving encode
    /// drain uses for live captures). Does ONLY chunk + bundle + BM25 +
    /// source-map + maintained-counts fold (Window 1 of `ingestBatch`). It does
    /// NOT bootstrap-train the basis (Phase 1b) and does NOT embed (Phase 2): a
    /// bulk import retrains the basis on the WHOLE corpus and embeds every chunk
    /// ONCE at the end (`reindex`), so the encode drain's embed-now /
    /// train-as-you-go work — correct for a single live capture — is pure
    /// repeated waste for an import. Rust twin: `Corpus::ingest_batch_import`.
    func ingestBatchImport(_ items: [(text: String, sourceID: String, now: Date)]) async throws {
        guard !items.isEmpty else { return }
        // EXT-4 SHARDED PIPELINE (durable SQLite estates): parallelize the
        // compute AND the postings writes, serialize only the estate writer.
        // Workers chunk + tokenize their slice OFF the actor and write its BM25
        // postings into a PRIVATE shard file beside the estate (same install
        // key — SQLiteShard applies it from the estate configuration, inside
        // the kit); the single writer then bundles rows as usual and folds each
        // shard in with ONE attach + sorted INSERT..SELECT (SQLiteStorage.mergeShard).
        // The serial per-item path remains for non-SQLite estates.
        if let sqlite = storage as? SQLiteStorage,
           let estateURL = sqlite.configuration.backend.sqliteURLForShards {
            try await ingestBatchImportSharded(items, sqlite: sqlite, estateURL: estateURL)
            return
        }
        try await ingestBatchImportSerial(items)
    }

    /// Items per import shard worker. Fixed (not count/cores) so a 10k pass
    /// yields more shards than cores — better load balancing (same rationale as
    /// the re-embed batch size). Rust twin: `IMPORT_SHARD_ITEMS`.
    private static let importShardItems = 2500

    /// The EXT-4 sharded import body — see `ingestBatchImport`.
    private func ingestBatchImportSharded(
        _ items: [(text: String, sourceID: String, now: Date)],
        sqlite: SQLiteStorage,
        estateURL: URL
    ) async throws {
        let estateDir = estateURL.deletingLastPathComponent()
        let configuration = sqlite.configuration

        // Estate db stem stamps every shard name so two estates sharing one
        // directory can never collide on a shard path (codex b92be5bc).
        let estateStem = estateURL.deletingPathExtension().lastPathComponent
        let shardPrefix = "import-shard-\(estateStem)-"

        // Sweep stale shards from a CRASHED prior import of THIS estate (the
        // prefix carries the estate stem, so other estates' live shards in a
        // shared directory are never touched). Safe under the import drain
        // lease, which serializes imports per estate; a concurrent same-estate
        // import is a caller bug that SQLiteShard's exclusive create surfaces.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: estateDir, includingPropertiesForKeys: nil) {
            for file in entries where file.lastPathComponent.hasPrefix(shardPrefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Phase P — parallel workers: chunk + tokenize + shard-write per slice.
        // Chunking uses a FRESH per-item HLC generator (matching the Rust import
        // path's chunk_with_default_hlc): chunk ids are content-addressed v5
        // UUIDs, so per-item parallel output is identical regardless of worker
        // layout. Each task owns one estate-stamped shard file (exclusive
        // create); live task width is bounded by the cooperative thread pool,
        // so thread count never scales with import size.
        var slices: [[(text: String, sourceID: String, now: Date)]] = []
        var start = 0
        while start < items.count {
            let end = min(start + Self.importShardItems, items.count)
            slices.append(Array(items[start..<end]))
            start = end
        }
        typealias WorkerOut = (
            index: Int,
            shardURL: URL?,
            perItem: [(sourceID: String, chunks: [Chunk])],
            postings: [(itemID: String, tf: [String: Int], docLen: Int)]
        )
        let outs: [WorkerOut] = try await withThrowingTaskGroup(of: WorkerOut.self) { group in
            for (i, slice) in slices.enumerated() {
                group.addTask {
                    let shardURL = estateDir.appendingPathComponent("\(shardPrefix)s\(i).sqlite")
                    let shard = try SQLiteShard(url: shardURL, configuration: configuration)
                    try shard.exec(
                        """
                        CREATE TABLE IF NOT EXISTS iix_termfreqs (
                            term     TEXT NOT NULL,
                            item_id  TEXT NOT NULL,
                            freq     INTEGER NOT NULL,
                            PRIMARY KEY (term, item_id)
                        );
                        CREATE TABLE IF NOT EXISTS iix_doclens (
                            item_id  TEXT NOT NULL PRIMARY KEY,
                            length   INTEGER NOT NULL
                        );
                        """)
                    var perItem: [(sourceID: String, chunks: [Chunk])] = []
                    var postings: [(itemID: String, tf: [String: Int], docLen: Int)] = []
                    var tfRows: [(term: String, itemID: String, freq: Int64)] = []
                    var lenRows: [(itemID: String, len: Int64)] = []
                    let tokenizer = CorpusDefaultTokenizer()
                    for item in slice {
                        var gen = HLCGenerator(nodeID: 1)
                        let chunks = Chunker.chunk(
                            text: item.text, sourceID: item.sourceID, hlcGenerator: &gen)
                        for chunk in chunks {
                            let tokens = tokenizer.keywordTokens(chunk.text)
                            guard !tokens.isEmpty else { continue }
                            var tf = [String: Int]()
                            for t in tokens { tf[t, default: 0] += 1 }
                            let itemID = chunk.id.uuidString
                            for (term, freq) in tf {
                                tfRows.append((term, itemID, Int64(freq)))
                            }
                            lenRows.append((itemID, Int64(tokens.count)))
                            postings.append((itemID, tf, tokens.count))
                        }
                        perItem.append((item.sourceID, chunks))
                    }
                    // Sorted before insert so the shard b-tree builds in append
                    // order and the merge's ORDER BY is a straight index scan.
                    tfRows.sort { ($0.term, $0.itemID) < ($1.term, $1.itemID) }
                    lenRows.sort { $0.itemID < $1.itemID }
                    try shard.insert(
                        table: "iix_termfreqs",
                        columns: ["term", "item_id", "freq"],
                        rows: tfRows.map { [.text($0.term), .text($0.itemID), .int($0.freq)] })
                    try shard.insert(
                        table: "iix_doclens",
                        columns: ["item_id", "length"],
                        rows: lenRows.map { [.text($0.itemID), .int($0.len)] })
                    shard.close()
                    return (i, shardURL, perItem, postings)
                }
            }
            var collected: [WorkerOut] = []
            for try await out in group { collected.append(out) }
            return collected.sorted { $0.index < $1.index }
        }

        // Phase S — single writer. Window 1: bundle rows through the estate
        // connection, committed per commitChunkItems (same bracket + same
        // side-effects as the serial path: reactivation, source map, counts).
        let rowStore = storage.rowStore
        let allItems: [(sourceID: String, chunks: [Chunk])] = outs.flatMap { $0.perItem }
        var offset = 0
        while offset < allItems.count {
            let end = min(offset + Self.commitChunkItems, allItems.count)
            try await rowStore.beginTransaction()
            do {
                for (sourceID, chunks) in allItems[offset..<end] {
                    guard !chunks.isEmpty else { continue }
                    try await removedSourceStore.clearRemoved(sourceID)
                    let insertedChunks = try await bundleStore.insert(chunks)
                    for chunk in chunks {
                        chunkSourceMap[chunk.id] = chunk.sourceID
                    }
                    foldChunksIntoCounts(insertedChunks)
                }
                try await rowStore.commitTransaction()
            } catch {
                try? await rowStore.rollbackTransaction()
                throw error
            }
            offset = end
        }

        // Shard merges: one attach + sorted INSERT..SELECT per shard (durable
        // tables), then one in-memory fold of the worker-computed postings.
        for out in outs {
            if let shardURL = out.shardURL {
                try await sqlite.mergeShard(url: shardURL, copySQL: [
                    """
                    INSERT OR REPLACE INTO iix_termfreqs (term, item_id, freq)
                      SELECT term, item_id, freq FROM shard.iix_termfreqs
                      ORDER BY term, item_id
                    """,
                    """
                    INSERT OR REPLACE INTO iix_doclens (item_id, length)
                      SELECT item_id, length FROM shard.iix_doclens
                      ORDER BY item_id
                    """
                ])
                SQLiteShard.removeFile(at: shardURL)
            }
            await invertedIndex.foldPostings(out.postings)
        }
        // NO bootstrap train, NO embed — `reindex` trains on the full corpus and
        // embeds every chunk ONCE after coverage completes.
    }

    /// The serial import body — non-SQLite estates only.
    private func ingestBatchImportSerial(_ items: [(text: String, sourceID: String, now: Date)]) async throws {
        let rowStore = storage.rowStore
        var offset = 0
        while offset < items.count {
            let end = min(offset + Self.commitChunkItems, items.count)
            try await rowStore.beginTransaction()
            do {
                for item in items[offset..<end] {
                    let chunks = Chunker.chunk(
                        text: item.text, sourceID: item.sourceID, hlcGenerator: &hlcGenerator)
                    guard !chunks.isEmpty else { continue }
                    try await removedSourceStore.clearRemoved(item.sourceID)
                    let insertedChunks = try await bundleStore.insert(chunks)
                    for chunk in chunks {
                        try await invertedIndex.index(
                            itemID: chunk.id.uuidString,
                            tokens: CorpusDefaultTokenizer().keywordTokens(chunk.text),
                            now: item.now
                        )
                        chunkSourceMap[chunk.id] = chunk.sourceID
                    }
                    foldChunksIntoCounts(insertedChunks)
                }
                try await rowStore.commitTransaction()
            } catch {
                try? await rowStore.rollbackTransaction()
                throw error
            }
            offset = end
        }
        // NO bootstrap train, NO embed — `reindex` trains on the full corpus and
        // embeds every chunk ONCE after coverage completes (it also persists the
        // maintained counts at that boundary).
    }

    /// Batch ingest for the drain worker pool: ingest many documents with the
    /// embedding COMPUTE parallelized across documents (the CPU-bound cost) while
    /// the chunk/BM25/bundle/vector WRITES stay serial (single-writer + actor
    /// isolation). Output is identical to calling `ingest` once per item — same
    /// chunks, same vectors, same content-addressed idempotency. This is the
    /// cross-drawer parallelism the per-estate encode drain drives (the 1.0
    /// separate-pump fix; the global cross-estate cap is the 1.1 central drain
    /// master, the deferred process-global drain master).
    ///
    /// First-ingest training cannot run concurrently (it mutates a slot's basis),
    /// so when a trainable slot still lacks a persisted basis the batch trains it
    /// ONCE on the full just-chunked corpus (Phase 1b) before the parallel embed —
    /// not item-by-item, which would train on a single document and yield a
    /// degenerate basis. Every subsequent batch (basis frozen) skips the bootstrap
    /// and takes the parallel fold-in path directly.
    public func ingestBatch(_ items: [(text: String, sourceID: String, now: Date)]) async throws {
        guard !items.isEmpty else { return }

        // Phase 1 (serial, actor-isolated): chunk + bundle + BM25 + source map.
        // Chunking uses the actor's HLC generator and the stores are actor state,
        // so this stays on-actor; it is cheap relative to the embeds.
        var perItemChunks: [[Chunk]] = []
        perItemChunks.reserveCapacity(items.count)
        // Commit the storage writes PER ITEM-CHUNK, not per item: the prior
        // per-item/per-chunk autocommits made a bulk drain I/O-bound on
        // sqlite3_step → commit + WAL checkpoint, idling the cores regardless of
        // embed parallelism. Chunked, NOT one transaction over the whole batch,
        // because the corpus shares the estate's primary SQLite connection
        // (single-writer at the file level); a transaction held across thousands
        // of rows would starve concurrent LocusKit captures / the governor. The
        // per-chunk commit still amortises the fsync/checkpoint ~chunk-fold.
        // (Parity: the Rust twin splits storage and BM25 into two sequential
        // windows because its InvertedIndexStore owns a private connection; here
        // invertedIndex shares storage.rowStore, so one window per chunk covers
        // bundle + BM25 + counts.)
        let rowStore = storage.rowStore
        var offset = 0
        while offset < items.count {
            let end = min(offset + Self.commitChunkItems, items.count)
            try await rowStore.beginTransaction()
            do {
                for item in items[offset..<end] {
                    let chunks = Chunker.chunk(
                        text: item.text, sourceID: item.sourceID, hlcGenerator: &hlcGenerator)
                    perItemChunks.append(chunks)
                    guard !chunks.isEmpty else { continue }
                    // (Re-)ingesting reactivates the source (clears any removed-row).
                    try await removedSourceStore.clearRemoved(item.sourceID)
                    // Idempotent insert returns only the newly-inserted chunks; fold
                    // counts over those (a re-ingested duplicate must not inflate them).
                    let insertedChunks = try await bundleStore.insert(chunks)
                    // Index into the durable InvertedIndexStore; idempotent on re-ingest.
                    for chunk in chunks {
                        try await invertedIndex.index(
                            itemID: chunk.id.uuidString,
                            tokens: CorpusDefaultTokenizer().keywordTokens(chunk.text),
                            now: item.now
                        )
                        chunkSourceMap[chunk.id] = chunk.sourceID
                    }
                    // Maintained-counts write path (P3): fold this item's NEWLY-inserted
                    // chunks into each trainable slot's accumulator. Persisted ONCE at the
                    // end of the batch (Phase 3), the batch boundary — never per chunk.
                    foldChunksIntoCounts(insertedChunks)
                }
                try await rowStore.commitTransaction()
            } catch {
                try? await rowStore.rollbackTransaction()
                throw error
            }
            offset = end
        }

        // Phase 1b — batch-aware first-basis bootstrap. When a trainable slot
        // (RI/PPMI/LSA/NMF) still has no persisted basis, train it ONCE on the
        // FULL corpus now in the bundle store — every chunk just inserted, not
        // the first item alone. The prior per-item serial fallback trained on
        // item 1's chunks (often a single document), producing a degenerate
        // basis (e.g. a rank-1 LSA SVD that folds in to zero); training on the
        // whole batch is the representative corpus these distributional models
        // need. Training is serial (it mutates the slot's basis) and runs BEFORE
        // the parallel embed below, which then folds every chunk onto the trained
        // basis. A subsequent full-corpus reindex still retrains on the complete
        // corpus once a bulk import has fully drained — this only fixes the
        // first-batch quality so interim recall is not embedding onto a 1-doc basis.
        var needsBootstrap = false
        for slot in slots where slot.freshBasisBlob != nil {
            if try await basisStore.load(
                modelID: slot.provider.modelID,
                modelVersion: slot.provider.modelVersion) == nil {
                needsBootstrap = true
                break
            }
        }
        if needsBootstrap {
            // Active chunks only — exclude removed sources from the first-basis train.
            let allChunks = try await activeChunks()
            if !allChunks.isEmpty {
                for index in slots.indices where slots[index].freshBasisBlob != nil {
                    let alreadyTrained = try await basisStore.load(
                        modelID: slots[index].provider.modelID,
                        modelVersion: slots[index].provider.modelVersion) != nil
                    if !alreadyTrained {
                        // Trains on the full chunk set and installs the trained
                        // provider into the slot, so the embed phase folds in.
                        try await trainAndPersistBasis(
                            slotIndex: index, chunks: allChunks, now: items[0].now)
                    }
                }
            }
        }

        // Snapshot the providers (Sendable values) so the compute tasks touch no
        // actor-isolated state.
        let providers: [(provider: any EmbeddingProvider, modelID: String, modelVersion: String)] =
            slots.map { ($0.provider, $0.provider.modelID, $0.provider.modelVersion) }

        // Phase 2 (parallel, OFF the Corpus actor): fan the embeds over
        // `embedConcurrencyCap` tasks, each taking ONE CONTIGUOUS SLICE of
        // ~count/cap items and embedding them serially. The prior model ran one
        // task PER ITEM, which `boundedConcurrentMap` schedules in cap-sized
        // barriered batches — for cheap per-item embeds the task-scheduling churn
        // dominates and cores never fill (the Rust twin measured ~2.8 effective
        // cores of 18 under the equivalent per-item thread::scope). Slicing pays
        // the scheduling cost `cap` times total and keeps each task busy.
        // `embedPair` is a pure provider call (Sendable). Deterministic: each
        // item's rows are built in (provider, chunk, lane) order and scattered
        // back by ORIGINAL item index, so the stored rows are identical to the
        // per-item serial path regardless of task completion order. Mirrors the
        // Rust slice-per-worker fan-out.
        let embedInputs: [(idx: Int, chunks: [Chunk])] =
            perItemChunks.enumerated().compactMap { $0.element.isEmpty ? nil : ($0.offset, $0.element) }
        let provs = providers
        let itemNows = items.map(\.now)
        let cap = embedConcurrencyCap
        // Slice the non-empty items into at most `cap` contiguous groups.
        let sliceLen = max(1, (embedInputs.count + cap - 1) / cap)
        var slices: [[(idx: Int, chunks: [Chunk])]] = []
        var sliceStart = 0
        while sliceStart < embedInputs.count {
            let sliceEnd = min(sliceStart + sliceLen, embedInputs.count)
            slices.append(Array(embedInputs[sliceStart..<sliceEnd]))
            sliceStart = sliceEnd
        }
        // One task per slice (cap slices, cap concurrency → all run together).
        let computedSlices: [[(Int, [VectorPayloadInput])]] =
            try await boundedConcurrentMap(slices, cap: cap) { slice in
                var out: [(Int, [VectorPayloadInput])] = []
                out.reserveCapacity(slice.count)
                for input in slice {
                    var rows: [VectorPayloadInput] = []
                    rows.reserveCapacity(input.chunks.count * provs.count * 2)
                    let nowLocal = itemNows[input.idx]
                    for p in provs {
                        for chunk in input.chunks {
                            let (engram, floats) = try await p.provider.embedPair(chunk.text)
                            rows.append(VectorPayloadInput(
                                itemID: chunk.id.uuidString, vectorIndex: 0,
                                payload: VectorPayload(engram: engram),
                                modelID: p.modelID, modelVersion: p.modelVersion, filedAt: nowLocal))
                            if !floats.isEmpty {
                                rows.append(VectorPayloadInput(
                                    itemID: chunk.id.uuidString, vectorIndex: 1,
                                    payload: VectorPayload(floats: floats),
                                    modelID: p.modelID, modelVersion: p.modelVersion, filedAt: nowLocal))
                            }
                        }
                    }
                    out.append((input.idx, rows))
                }
                return out
            }
        // Scatter the computed rows back to per-item order; skipped (empty) items
        // remain []. Determinism preserved: rows are keyed by original item index.
        var acc = [[VectorPayloadInput]](repeating: [], count: perItemChunks.count)
        for slice in computedSlices {
            for (idx, rows) in slice { acc[idx] = rows }
        }
        let perItemRows = acc

        // Phase 3 (serial, actor-isolated): ONE batched write for the whole drain
        // batch (every item's rows flattened, preserving item-then-chunk order).
        // A single addPayloads call collapses the per-item resident-index rebuilds
        // into one; under the drain's deferred-index window even that one rebuild
        // is deferred to burst end (publishResidentIndex), so a bulk import pays
        // O(N) total index work instead of O(N²).
        let allRows = perItemRows.flatMap { $0 }
        // Commit vector upserts PER ROW-CHUNK (same shared-connection bound as
        // Phase 1). addPayloads under the drain's deferred-index window appends to
        // the resident array across calls; the index rebuild is published once at
        // burst end, so chunking the durable writes is safe.
        var rowOffset = 0
        while rowOffset < allRows.count {
            let rowEnd = min(rowOffset + Self.commitChunkRows, allRows.count)
            try await rowStore.beginTransaction()
            do {
                try await vectorStore.addPayloads(Array(allRows[rowOffset..<rowEnd]))
                try await rowStore.commitTransaction()
            } catch {
                try? await rowStore.rollbackTransaction()
                throw error
            }
            rowOffset = rowEnd
        }

        // Batch boundary: persist the maintained counts + growth anchors once for
        // the whole drained batch (a single counts-blob write; autocommits).
        // `items[0].now` matches the first-basis bootstrap's training instant above.
        try await persistMaintainedCounts(now: items[0].now)
    }

    // MARK: - Maintained counts (incremental-counts change set, P3)

    /// Fold the written chunks into every trainable slot's maintained-counts
    /// accumulator — the per-chunk "increment as we go" write path
    /// (`addToCounts`). Cheap (O(chunk·vocab)); non-trainable slots are skipped.
    /// Does NOT persist: persistence batches at the caller's boundary
    /// (`persistMaintainedCounts`), because re-serializing the whole counts blob
    /// per chunk would be O(N·vocab) over an import.
    private func foldChunksIntoCounts(_ chunks: [Chunk]) {
        guard !chunks.isEmpty else { return }
        for index in slots.indices where slots[index].countsAccumulator != nil {
            for chunk in chunks {
                slots[index].countsAccumulator!.addToCounts(text: chunk.text)
            }
            slots[index].countsDocumentCount += chunks.count
        }
    }

    /// All chunks EXCLUDING those of removed (recall-suppressed) sources.
    ///
    /// Every rebuild path — reindex, the BM25 rebuild on open, the first-ingest
    /// basis train — reads this instead of `bundleStore.allChunks()` so a source
    /// cleared by `remove(sourceID:)` cannot resurface. Re-ingesting a source
    /// clears its removed-row so it returns to the active set. Not a hot path
    /// (rebuild/reindex only).
    private func activeChunks() async throws -> [Chunk] {
        let removed = try await removedSourceStore.removedIDs()
        let all = try await bundleStore.allChunks()
        guard !removed.isEmpty else { return all }
        return all.filter { !removed.contains($0.sourceID) }
    }

    /// The maximum maintained vocabulary size across all trainable slots — the
    /// cheap anchor the autonomic governor's vocab-growth retrain trigger reads
    /// (P3, item 5). Returns 0 when no trainable slot is present, so the trigger
    /// never fires for a non-trainable corpus (correct: nothing to retrain).
    ///
    /// Reads the in-memory accumulators (current as of the last folded chunk),
    /// not the store — the governor runs in-process with the resident corpus, so
    /// this is a cheap field read, not a query.
    public func maintainedVocabAnchor() -> Int {
        slots.compactMap { $0.countsAccumulator?.countsVocabularySize }.max() ?? 0
    }

    /// Persist every trainable slot's maintained counts + growth anchors to the
    /// counts table. Called at BATCH boundaries (end of ingest / ingestBatch /
    /// reindex), never per chunk. Keyed by the slot's serving (modelID,
    /// modelVersion) — the accumulator shares that key. `now` is the caller's
    /// instant (determinism).
    private func persistMaintainedCounts(now: Date) async throws {
        for slot in slots {
            guard let accumulator = slot.countsAccumulator else { continue }
            try await countsStore.upsert(PersistedCounts(
                modelID: slot.provider.modelID,
                modelVersion: slot.provider.modelVersion,
                counts: accumulator.serializeCounts(),
                documentCount: slot.countsDocumentCount,
                vocabSize: accumulator.countsVocabularySize,
                updatedAt: now))
        }
    }

    /// Enter deferred-index mode on the vector store for a drain burst.
    ///
    /// The ingest drain (CorpusIngestQueue) calls this before ingesting a drained
    /// batch so the burst's resident-index rebuilds collapse into a single rebuild
    /// at `publishVectorIndex()` — O(N) bulk import instead of O(N²). Internal:
    /// `vectorStore` is file-private, so the ingest-queue extension reaches it
    /// through this seam. Mirrors the Rust `Corpus::begin_deferred_vector_index`.
    func beginDeferredVectorIndex() async throws {
        try await vectorStore.beginDeferredIndex()
    }

    /// Publish the deferred resident vector index (one rebuild) at the end of a
    /// drain burst / drain barrier. No-op when nothing was deferred. Internal seam
    /// for the ingest-queue extension. Mirrors the Rust `Corpus::publish_vector_index`.
    func publishVectorIndex() async throws {
        try await vectorStore.publishResidentIndex()
    }

    /// Retrain the embedding basis on the full corpus and re-embed every chunk.
    ///
    /// When the configured provider is trainable (RI/PPMI/LSA/NMF), this:
    ///   1. gathers ALL chunk texts from the BundleStore,
    ///   2. trains the basis on them through the `TrainableEmbeddingBasis` seam
    ///      (`trainOnCorpus(texts:)`, which runs the provider's own
    ///      train+finalize sequence — RI no finalize, PPMI/LSA/NMF finalize),
    ///   3. persists the serialized basis blob (UPSERT, one row per provider
    ///      key) with `now` and the trained chunk count, and
    ///   4. re-embeds every chunk (binary lane v0 + float lane v1) under the
    ///      provider's modelID, REPLACING stale vectors in place (delete-all
    ///      then re-add per chunk — no duplicate rows).
    ///
    /// When the provider is NOT trainable (deterministic / named-model / FDC),
    /// no basis is persisted; the chunks are simply (re)embedded so the call is
    /// still a well-defined "refresh the vectors" operation.
    ///
    /// Deterministic: `now` is the only clock source — the engine never calls
    /// `Date()`. Training itself is a pure function of the corpus texts and the
    /// provider's fixed seeds (the seam contract), so the persisted basis and
    /// the resulting vectors are reproducible and cross-port identical.
    ///
    /// `reindex` is the EXPLICIT retrain trigger. Implicit train triggers in
    /// `ingest` are:
    ///   (a) first-ingest: no basis persisted yet → train on the current corpus.
    ///   (b) growth retrain (Kinsta-fix): basis is young (trainedChunkCount below
    ///       `perDocAutoRetrainStableChunkThreshold`) AND corpus has grown to ≥ 2×
    ///       trainedChunkCount → retrain on the full corpus. Stops once the basis
    ///       is stable. Prevents a rank-1 LSA SVD from persisting on a 1-doc
    ///       first-ingest corpus.
    ///
    /// Above the stability threshold, `ingest` only folds new chunks onto the
    /// frozen basis; this method is the only way to retrain for a mature corpus.
    ///
    /// - Parameter now: wall-clock time for the basis `trained_at` stamp and the
    ///   re-embedded vectors' filing timestamps. Pass `now` from the caller;
    ///   never call `Date()` inside the engine.
    public func reindex(now: Date) async throws {
        // Active chunks only: a source cleared by `remove(sourceID:)` must NOT be
        // re-embedded back into recall by a (possibly auto-triggered) reindex.
        let chunks = try await activeChunks()

        // Phase logging throughout: on a large corpus this call legitimately
        // runs tens of minutes (full basis retrain + full re-embed); without
        // log lines that is indistinguishable from a hang (the v1.0.13 vault
        // import triage required sampling the process to prove it was alive).
        corpusLog.info(
            "reindex: start — \(chunks.count, privacy: .public) active chunks, \(self.slots.count, privacy: .public) provider slots")

        // Phase 1 — train every trainable slot CONCURRENTLY. The five-signal
        // default carries FOUR trainable providers (RI / PPMI / LSA / NMF) whose
        // trainings are independent computations over the same chunk snapshot.
        // Running them serially made a large reindex wait ΣT(train) on one core
        // with LSA's SVD + NMF's ALS dominating; concurrent slots wait max(T)
        // instead. The heavy compute (reconstructBasis + trainOnCorpus) is a pure
        // function of (freshBlob, texts) — hoisted OFF the actor into a task
        // group; install + persist stay serial on the actor. Per-slot output is
        // byte-identical to the serial loop (kernels untouched, shared reduced embedding vocabulary). LSA and
        // NMF each derive the shared reduced embedding vocabulary reduced vocabulary with the same pure
        // deterministic selection, so concurrent duplicate computation of it is
        // benign (identical artifact). For N=1 this runs one task — same result.
        // Rust twin: the scoped-thread Phase 1 in `Corpus::reindex`.
        let texts = chunks.map(\.text)
        var trainInputs: [(index: Int, blob: Data, fresh: any TrainableEmbeddingBasis)] = []
        for index in slots.indices {
            if let blob = slots[index].freshBasisBlob,
               let fresh = slots[index].provider as? any TrainableEmbeddingBasis {
                trainInputs.append((index, blob, fresh))
            }
        }
        if !trainInputs.isEmpty {
            corpusLog.info(
                "reindex: training \(trainInputs.count, privacy: .public) trainable slots concurrently over \(texts.count, privacy: .public) texts")
            let trained: [(Int, any EmbeddingProvider)] =
                try await withThrowingTaskGroup(of: (Int, any EmbeddingProvider).self) { group in
                    for input in trainInputs {
                        group.addTask {
                            // Reconstruct a fresh untrained provider from the
                            // empty-basis blob and train it from scratch —
                            // trainOnCorpus is additive, so training fresh (not in
                            // place) is required. See ProviderSlot.freshBasisBlob.
                            let provider = try input.fresh.reconstructBasis(from: input.blob)
                            guard let trainable = provider as? any TrainableEmbeddingBasis else {
                                throw CorpusKitError.notTrainable(
                                    "reconstructed provider is not trainable — basis seam invariant violated")
                            }
                            trainable.trainOnCorpus(texts: texts)
                            corpusLog.info(
                                "reindex: trained \(provider.modelID, privacy: .public)")
                            return (input.index, provider)
                        }
                    }
                    var out: [(Int, any EmbeddingProvider)] = []
                    for try await result in group { out.append(result) }
                    return out
                }
            // Install + persist serially on the actor (cheap; the compute is done).
            for (index, provider) in trained.sorted(by: { $0.0 < $1.0 }) {
                guard let trainable = provider as? any TrainableEmbeddingBasis else { continue }
                slots[index].provider = provider
                try await basisStore.upsert(PersistedBasis(
                    modelID: provider.modelID,
                    modelVersion: provider.modelVersion,
                    basis: trainable.serializeBasis(),
                    trainedAt: now,
                    trainedChunkCount: chunks.count
                ))
            }
            corpusLog.info("reindex: training complete — bases persisted")
        }

        // Phase 2 — re-embed every chunk under each slot's (now possibly
        // retrained) provider, replacing stale vectors. Done whether or not a
        // retrain occurred: for a non-trainable slot (no factory blob) reindex is
        // a pure vector refresh under the current basis, with no basis row
        // written. Serial per slot: each re-embed already fans its embed compute
        // across all cores and funnels one bulk single-writer transaction.
        for index in slots.indices {
            corpusLog.info(
                "reindex: re-embedding \(chunks.count, privacy: .public) chunks under \(self.slots[index].provider.modelID, privacy: .public) (slot \(index + 1, privacy: .public)/\(self.slots.count, privacy: .public))")
            try await reembedChunks(slotIndex: index, chunks, now: now)
        }

        // Persist the maintained counts + growth anchors after the refresh. The
        // accumulators were kept current by the ingest fold path; persisting here
        // re-anchors the growth trigger to the just-reindexed state.
        try await persistMaintainedCounts(now: now)

        // disk-default storage residency NOTE: releaseBasis was here but is REMOVED because the
        // serving providers have no on-demand reconstruction path. Calling
        // releaseBasis() clears the live vocab, making subsequent embeds
        // return Engram.zero until the next full reindex or process restart.
        // The ~2GB vocab RAM stays resident until a proper lazy-load-from-
        // BasisStore mechanism is implemented. The diskBacked BM25 pattern
        // (load from SQLite on demand) is the model — the embedding providers
        // need the same treatment, but it's a larger refactor (each provider's
        // embed path must check for empty vocab and reconstruct from the
        // persisted basis blob before embedding).

        corpusLog.info(
            "reindex: complete — \(chunks.count, privacy: .public) chunks re-embedded across \(self.slots.count, privacy: .public) slots")
    }

    /// Train a FRESH provider on the given chunks' texts and persist the
    /// serialized basis FOR THE GIVEN SLOT. Shared by `reindex` and the
    /// first-ingest auto-train.
    ///
    /// Reconstructs a fresh (untrained) provider from the slot's
    /// `freshBasisBlob`, trains it on the chunk texts through the seam, installs
    /// it as the slot's `provider`, and UPSERTs the resulting basis keyed by
    /// (modelID, modelVersion). `trainedChunkCount` is the count the basis was
    /// trained on (the staleness anchor). Training fresh — not in place —
    /// guarantees the additive `trainOnCorpus` starts from scratch, so the basis
    /// is the canonical from-scratch one and reindex is idempotent.
    /// Precondition: `slots[slotIndex].freshBasisBlob != nil` (the caller checks
    /// this).
    private func trainAndPersistBasis(slotIndex: Int, chunks: [Chunk], now: Date) async throws {
        guard let freshBlob = slots[slotIndex].freshBasisBlob,
              let fresh = slots[slotIndex].provider as? any TrainableEmbeddingBasis else {
            // Defensive: trainAndPersistBasis is only invoked when this slot's
            // freshBasisBlob is non-nil and its provider is trainable. If neither
            // holds there is nothing to train; return without persisting a basis.
            return
        }
        // Reconstruct a fresh untrained provider from the empty-basis blob, train
        // it from scratch on the corpus, then install it as the slot's provider.
        let trainedProvider = try fresh.reconstructBasis(from: freshBlob)
        guard let trainable = trainedProvider as? any TrainableEmbeddingBasis else {
            // The reconstructed provider must itself be trainable (it is the same
            // concrete type). If not, the seam is broken; surface it rather than
            // silently persisting an untrained basis.
            throw CorpusKitError.notTrainable(
                "reconstructed provider is not trainable — basis seam invariant violated")
        }
        // `trainable` and `trainedProvider` are the SAME reference object;
        // training via the trainable view mutates the provider we install.
        trainable.trainOnCorpus(texts: chunks.map(\.text))
        slots[slotIndex].provider = trainedProvider
        try await basisStore.upsert(PersistedBasis(
            modelID: trainedProvider.modelID,
            modelVersion: trainedProvider.modelVersion,
            basis: trainable.serializeBasis(),
            trainedAt: now,
            trainedChunkCount: chunks.count
        ))
    }

    /// Re-embed every chunk (binary v0 + float v1) under the GIVEN SLOT's
    /// provider, replacing any stale vectors so no duplicate rows accumulate.
    ///
    /// For each chunk the prior vectors (all vector_index rows under that
    /// item_id for the slot provider's modelID) are deleted, then the binary
    /// engram and — when the provider supports it — the float vector are
    /// re-added. This is the same store-side shape as `ingest`'s fan-out, but
    /// delete-first so a retrain under a changed basis overwrites rather than
    /// duplicates. Other slots' rows (keyed by a different modelID) are
    /// untouched.
    private func reembedChunks(slotIndex: Int, _ chunks: [Chunk], now: Date) async throws {
        let provider = slots[slotIndex].provider
        // Snapshot the provider as Sendable values so the compute tasks touch no
        // actor-isolated state (mirrors ingestBatch Phase 2). `embedPair` is a
        // pure provider call, so concurrent calls are safe and order-independent.
        let prov = provider
        let modelID = provider.modelID
        let modelVersion = provider.modelVersion
        let filedAt = now

        // Fixed batch size — mirrors Rust REEMBED_BATCH_SIZE. Fixed (not count/cap)
        // on purpose: a realistic import produces MORE batches than cores, so a
        // slow batch cannot stall the join the way exact per-core slices can
        // (better load balancing). ~3000 amortizes per-batch overhead while still
        // fanning across every core; also the natural unit for a future
        // chunked-commit write.
        let reembedBatchSize = 3000
        var batches: [[Chunk]] = []
        var start = 0
        while start < chunks.count {
            let end = min(start + reembedBatchSize, chunks.count)
            batches.append(Array(chunks[start..<end]))
            start = end
        }

        // Phase 1 (PARALLEL, bounded to embedConcurrencyCap): embed each contiguous
        // batch. boundedConcurrentMap preserves input order, so flattening the
        // per-batch payloads reproduces chunk order EXACTLY — the stored rows are
        // byte-identical to the serial path (determinism / cross-port conformance
        // preserved); only the wall-clock changes.
        //
        // Progress counter: on a large corpus this phase runs many minutes; a
        // line every ~5k chunks keeps the daemon log distinguishable from a
        // hang. Lock-guarded (batches complete concurrently); logging order may
        // interleave but counts are exact.
        let progressStride = 5_000
        let totalChunks = chunks.count
        let embedded = Mutex(0)
        let perBatch: [[VectorPayloadInput]] =
            try await boundedConcurrentMap(batches, cap: embedConcurrencyCap) { batch in
                defer {
                    let done = embedded.withLock { count -> Int in
                        count += batch.count
                        return count
                    }
                    if done / progressStride > (done - batch.count) / progressStride {
                        corpusLog.info(
                            "reindex: reembed \(done, privacy: .public)/\(totalChunks, privacy: .public) (\(modelID, privacy: .public))")
                    }
                }
                var rows: [VectorPayloadInput] = []
                rows.reserveCapacity(batch.count * 2)
                for chunk in batch {
                    // Single inference pass: embedPair returns the engram and the
                    // float vector from ONE computation.
                    let (engram, floats) = try await prov.embedPair(chunk.text)
                    rows.append(VectorPayloadInput(
                        itemID: chunk.id.uuidString,
                        vectorIndex: 0,
                        payload: VectorPayload(engram: engram),
                        modelID: modelID,
                        modelVersion: modelVersion,
                        filedAt: filedAt
                    ))
                    // Float lane (Lane D): added only when non-empty.
                    if !floats.isEmpty {
                        rows.append(VectorPayloadInput(
                            itemID: chunk.id.uuidString,
                            vectorIndex: 1,
                            payload: VectorPayload(floats: floats),
                            modelID: modelID,
                            modelVersion: modelVersion,
                            filedAt: filedAt
                        ))
                    }
                }
                return rows
            }

        // Phase 2 (SERIAL — single-writer): clear the model's ENTIRE vector set in
        // ONE bulk pass — one DB delete + one O(n) resident-array sweep — then add
        // the freshly-embedded batch, all under a single transaction. The old
        // per-chunk deleteAllVectors scanned the whole resident array on EVERY
        // chunk, so re-embedding a corpus was O(n²) (the dominant cost of a large
        // reindex); clearing the whole model once is O(n), and the single
        // transaction commits with one fsync instead of one per row. A full clear +
        // re-add also ends each chunk with exactly the new vectors (no stale rows
        // from a prior basis in either lane), preserving the delete-first invariant.
        let batch = perBatch.flatMap { $0 }
        try await vectorStore.replaceModelVectors(modelID: modelID, batch)
    }

    /// Recall the top-k chunks relevant to a query.
    ///
    /// Embeds the query, then fuses vector kNN hits and BM25 keyword
    /// hits via Reciprocal Rank Fusion (SPEC § 5, B-4). Both passes are
    /// filtered to the model id the Corpus was configured with.
    ///
    /// - Parameters:
    ///   - query: Natural language query text.
    ///   - limit: Maximum number of results. Defaults to 10.
    ///   - now: Wall-clock time (reserved; included for API symmetry
    ///     with ingest and determinism discipline).
    /// - Returns: Scored chunks ranked by fused relevance, descending.
    public func recall(_ query: String, limit: Int = 10, now: Date) async throws -> [ScoredChunk] {
        // Single-signal entry point: recall runs on the DEFAULT signal (the
        // first held provider). Per-signal fan-out is exposed additively via
        // `floatNearestPerSignal` (the 6b RRF seam); this method is unchanged
        // for existing callers.
        let provider = defaultProvider
        let probe = try await provider.embed(query)
        return try await HybridRecall.recall(
            probe: probe,
            query: query,
            modelID: provider.modelID,
            limit: limit,
            vectorStore: vectorStore,
            invertedIndex: invertedIndex,
            bundleStore: bundleStore
        )
    }

    /// Remove a source document from the recall index.
    ///
    /// Removes the source's chunks from BM25 and deletes their vectors
    /// from VectorStore. Chunk rows are not deleted from content storage;
    /// the source will no longer appear in recall results after this call.
    /// To additionally erase the verbatim chunk text, use
    /// `expunge(sourceID:)` instead.
    ///
    /// - Parameter sourceID: The source document identifier supplied to
    ///   `ingest`.
    public func remove(sourceID: String) async throws {
        let chunks = try await bundleStore.chunksForSource(sourceID)
        // Vector deletion fans out across every held provider's modelID so no
        // slot leaves orphan rows for a removed source. For N=1 this inner loop
        // runs once. The modelIDs are gathered once up front (stable for the
        // corpus lifetime) so the per-chunk loop does not re-read `slots`.
        let modelIDs = slots.map { $0.provider.modelID }
        for chunk in chunks {
            try await invertedIndex.remove(itemID: chunk.id.uuidString)
            chunkSourceMap.removeValue(forKey: chunk.id)
            // Delete ALL vector_index rows for this chunk under EVERY held
            // modelID, not just the binary engram at vector_index=0: the float
            // lane (Lane D) stores a second row at vector_index=1 under the same
            // item_id. deleteAllVectors removes both and invalidates the float
            // index so a removed source cannot resurface through any signal's
            // dense float lane.
            for modelID in modelIDs {
                try await vectorStore.deleteAllVectors(
                    itemID: chunk.id.uuidString,
                    modelID: modelID
                )
            }
        }
        // Record the source as removed so a subsequent reindex / first-ingest
        // train (including the auto-triggered governor reindex) does NOT re-embed
        // it back into recall from the chunks table. (Keyword recall is already
        // suppressed above by removing the source's rows from the durable
        // InvertedIndexStore.)
        // `removed_at` is audit-only metadata (presence is what the active-chunk
        // filter reads), so it uses `Date()` directly — mirroring BundleStore's
        // `created_at` stamp; it is not a deterministic computation input.
        try await removedSourceStore.markRemoved(sourceID, now: Date())
    }

    // MARK: - Hard-delete erasure (secfix/ws2-coredelete)

    /// Zero all verbatim chunk text for `sourceID` and remove it from recall.
    ///
    /// This is the hard-delete variant of `remove(sourceID:)`. `remove` suppresses
    /// a source from recall (invertedIndex, vectorStore, removedSourceStore) but
    /// leaves the verbatim chunk text rows in the chunks table — content remains
    /// in SQLite. `expunge` additionally zeroes the text column of every chunk row
    /// for this source via `BundleStore.scrubText(sourceID:)`, ensuring the
    /// verbatim content is unrecoverable even if the structural rows persist.
    ///
    /// Call sequence:
    ///   1. Scrub text first — content is destroyed even if later steps fail.
    ///   2. Remove from recall — identical to `remove(sourceID:)`.
    ///
    /// Called by `GeniusLocusKit` as part of the two-step expunge flow
    /// (`VerbSurface.expunge`). Callers that only want recall suppression
    /// (no content erasure) continue to use `remove(sourceID:)`.
    ///
    /// (secfix/ws2-coredelete: hard-delete destruction contract)
    public func expunge(sourceID: String) async throws {
        // Step 1: zero verbatim text in the chunks table. Content is gone at
        // the database level before any recall-removal step can fail.
        try await bundleStore.scrubText(sourceID: sourceID)
        // Step 2: remove from recall — invertedIndex, vectorStore chunks,
        // removedSourceStore. Delegates to the existing remove() path so
        // the two are guaranteed identical recall-suppression behaviour.
        try await remove(sourceID: sourceID)
    }

    // MARK: - Lifecycle (GLK_PROVISION_001)

    /// Destroy the corpus's recall index.
    ///
    /// Clears the durable InvertedIndexStore (SQLite iix_termfreqs + iix_doclens
    /// rows), the chunk-source map, and THIS CORPUS'S vector rows from the
    /// VectorStore (ownership-scoped: its own chunk IDs under its held models —
    /// never rows other lanes wrote to shared storage) so this corpus no longer
    /// participates in recall.
    ///
    /// Chunk rows are not deleted by this call — they remain in the backing
    /// storage. What is destroyed is the corpus's active recall capability:
    /// after this call, `recall` returns empty results and `ingest` would
    /// re-index from scratch. To erase verbatim chunk content, call
    /// `expunge(sourceID:)` before `destroyRecallIndex`.
    ///
    /// Called by `GeniusLocusKit.destroy(storage:corpusStorage:handle:)` as part
    /// of the coordinated estate teardown path. The caller must ensure the estate
    /// is closed (not in use) before calling this.
    public func destroyRecallIndex() async throws {
        // 1. Clear the durable InvertedIndexStore and chunk-source map.
        //    deleteAll() removes every iix_termfreqs and iix_doclens row in one
        //    call and wipes the in-memory state — no per-chunk iteration needed.
        try await invertedIndex.deleteAll()
        chunkSourceMap.removeAll()

        // 2. Delete THIS CORPUS'S vector rows from the VectorStore —
        //    OWNERSHIP-SCOPED. The corpus owns exactly the rows keyed by its
        //    own chunk IDs under its held models' modelIDs; on shared storage
        //    the vectors table can also hold rows written by other lanes
        //    (drawer-keyed signals, other consumers), and destroying the
        //    corpus's recall index must never delete those. The chunk
        //    inventory comes from the append-only chunks table, so it covers
        //    every chunk this corpus ever wrote vectors for (already-removed
        //    sources' deletes are no-ops). Whole-table teardown
        //    (`destroyAllVectors`) is reserved for the whole-estate
        //    destruction path in GeniusLocusKit.destroy.
        let heldModelIDs = slots.map { $0.provider.modelID }
        for sourceID in try await bundleStore.allSourceIDs() {
            for chunk in try await bundleStore.chunksForSource(sourceID) {
                for modelID in heldModelIDs {
                    try await vectorStore.deleteAllVectors(
                        itemID: chunk.id.uuidString,
                        modelID: modelID
                    )
                }
            }
        }

        // 3. Wipe the persisted trained basis (mission 6a-ii-β). A destroyed
        //    corpus must leave no orphaned basis row FOR ANY held modelID: the
        //    next open would otherwise reconstruct a trained provider whose
        //    basis no longer matches any stored vectors. basisStore.deleteAll()
        //    clears every row regardless of modelID, so all held signals' bases
        //    are wiped in one call.
        try await basisStore.deleteAll()
        try await countsStore.deleteAll()
        try await removedSourceStore.deleteAll()
    }

    /// BM25-only top-k recall at the source granularity, using a bounded min-heap.
    ///
    /// Returns the top-`limit` sources by BM25 keyword score for the query text.
    /// Unlike `recall(_:limit:now:)`, this method skips embedding and vector kNN —
    /// it is the pure BM25 lane used by GeniusLocusKit's RecallDirector to drive
    /// the BM25 frontier independently from the vector lane.
    ///
    /// The returned `sourceID` values are the identifiers passed to `ingest`. In
    /// the GLK context these are LocusKit drawer IDs; the RecallDirector uses them
    /// to join BM25 hits back to hydrated `Drawer` rows.
    ///
    /// Sources with multiple matching chunks use the highest-scoring chunk's score
    /// for that source (max aggregation). Results are sorted descending by score.
    ///
    /// - Parameters:
    ///   - query: Natural language query text.
    ///   - limit: Maximum number of source-level results.
    /// - Returns: Up to `limit` (sourceID, score) pairs, descending by score.
    public func bm25TopKBySource(query: String, limit: Int) async throws -> [(sourceID: String, score: Float)] {
        guard limit > 0, !query.isEmpty else { return [] }
        // Tokenise using the same vocabulary as the indexed chunks. The
        // CorpusDefaultTokenizer is stateless; a fresh instance is semantically
        // equivalent to the tokenizer used at ingest — same FNV-1a fold and
        // vocab parameters, matching InvertedIndexStore's stored term frequencies.
        let tokens = CorpusDefaultTokenizer().keywordTokens(query)
        guard !tokens.isEmpty else { return [] }

        // Fetch chunk-level BM25 top-k with a 4× over-fetch so that after
        // source-level aggregation we still have at least `limit` sources.
        // The over-fetch is bounded: frontierK <= 256 per the RecallDirector
        // contract, so limit * 4 <= 1024 at most.
        // InvertedIndexStore.topK is synchronous internally (it builds or
        // returns the cached in-memory InvertedIndex and runs WAND/BMW), but
        // as an actor method it requires await to enter the actor's isolation
        // context. No async I/O occurs; the hop is cheap.
        let sparseHits = try await invertedIndex.topK(queryTerms: tokens, k: limit * 4)

        // Map SparseHit (itemID: String, impact: Float) to (id: UUID, score: Float).
        // Hits whose itemID is not a valid UUID string are dropped — should not
        // occur since InvertedIndexStore only receives chunk.id.uuidString at
        // ingest time, but dropping is correct defensive behaviour.
        let chunkHits: [(id: UUID, score: Float)] = sparseHits.compactMap { hit in
            guard let uuid = UUID(uuidString: hit.itemID) else { return nil }
            return (id: uuid, score: hit.impact)
        }

        // Aggregate by sourceID — take the max chunk score per source.
        var sourceScores: [String: Float] = [:]
        for hit in chunkHits {
            guard let sourceID = chunkSourceMap[hit.id] else { continue }
            sourceScores[sourceID] = max(sourceScores[sourceID, default: 0], hit.score)
        }

        // Sort descending by score, sourceID ascending on tie (deterministic).
        var ranked = sourceScores.map { (sourceID: $0.key, score: $0.value) }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.sourceID < b.sourceID
        }
        return Array(ranked.prefix(limit))
    }

    /// Embed the given text using the corpus's configured embedding model.
    ///
    /// Exposes the embedding surface for GeniusLocusKit's RecallDirector vector
    /// lane, which needs to embed the query text to produce a probe `Engram` for
    /// Hamming nearest-neighbour search against VectorStore.
    ///
    /// Returns `Engram.zero` for empty input (same as the internal ingest path).
    ///
    /// - Parameter text: Text to embed. Should be the query string.
    /// - Returns: A 256-bit `Engram` encoding the text's semantic fingerprint.
    public func embed(_ text: String) async throws -> Engram {
        // Single-signal entry point: embeds on the DEFAULT signal.
        try await defaultProvider.embed(text)
    }

    /// The embedding model identifier of this corpus's DEFAULT signal.
    ///
    /// Exposed for GeniusLocusKit's RecallDirector vector lane so it can pass
    /// the correct `modelID` to `VectorStore.findNearest`. Must match the
    /// `modelID` used during `ingest` for the default signal — vectors stored
    /// under a different model ID are not comparable per spec I-4. For an
    /// N-provider corpus this is the first held provider's modelID; the other
    /// signals' modelIDs are reachable through `floatNearestPerSignal`.
    public var modelID: String { defaultProvider.modelID }

    /// Embed the query text into the pooled dense float vector (Lane D) — the
    /// probe for the dense float recall lane.
    ///
    /// Delegates to the configured provider's `embedFloat`. The default
    /// `.deterministic` provider DOES implement `embedFloat` (FNV-1a + FloatSimHash),
    /// so Lane D is live from the first capture under the default. Providers that
    /// choose not to produce a dense float vector throw
    /// `VectorKitError.embeddingFailed`; the caller treats a throw as "this
    /// corpus has no float lane" and skips the dense lane rather than failing
    /// the whole recall. Empty input returns `[]` (no dense direction for the
    /// empty string), matching the storage-side contract in `ingest`.
    ///
    /// - Parameter text: the query text to embed.
    /// - Returns: the pooled float vector, or `[]` for empty input.
    /// - Throws: `VectorKitError.embeddingFailed` when the provider opts out.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // Single-signal entry point: embeds on the DEFAULT signal.
        try await defaultProvider.embedFloat(text)
    }

    /// Dense float nearest-neighbour recall (Lane D): embed `query` to its
    /// pooled float vector and rank stored chunks by cosine over the in-house
    /// `FloatBruteForceIndex`. Returns a `FloatLaneOutcome` that is always
    /// observable — dark lanes carry a typed reason, store errors are logged
    /// and counted, never swallowed.
    ///
    /// This is the cosine path the 256-bit SimHash-Hamming lane could not
    /// serve: cosine is scale-invariant, so an answer statement ranks above a
    /// near-duplicate of the question.
    ///
    /// **Degradation contract:** this method never throws. A dark lane is
    /// represented as `.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
    /// or `.emptyQuery` — all expected outcomes. `.storeError` is NOT expected:
    /// the error is logged (OSLog "CorpusKit") and emitted as
    /// `corpus.float_lane.store_error` telemetry before returning so the
    /// failure is always observable. The query continues on other lanes.
    ///
    /// **Telemetry** (off by default — single `Atomic<Bool>` load when disabled):
    /// - `corpus.float_lane.hit`           — lane ran and returned ≥1 result.
    /// - `corpus.float_lane.dark_provider` — provider opted out.
    /// - `corpus.float_lane.dark_no_rows`  — no float rows stored.
    /// - `corpus.float_lane.store_error`   — unexpected store failure.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches.
    /// - Returns: a `FloatLaneOutcome` describing the result.
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome {
        guard limit > 0, !query.isEmpty else {
            // Empty query or zero limit — no telemetry: this is a no-op call.
            return .emptyQuery
        }

        // Test-only hook: if a forced error is installed, consume it and return
        // .storeError immediately. This exercises the observable store-error code
        // path without requiring production modifications to the vector store.
        // Both entry points consult the hook: this single-signal path, and the
        // per-signal `floatNearestPerSignal` for its DEFAULT slot (slot 0), so the
        // store-error dark contract is observable through whichever path GLK uses.
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            corpusLog.error("floatNearest: findNearestFloat failed — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(forced)
        }

        // Single-signal entry point: run the dense float lane on the DEFAULT
        // signal. The per-provider mechanics live in `floatNearest(provider:…)`
        // so `floatNearestPerSignal` can reuse them unchanged.
        return await floatNearest(provider: defaultProvider, query: query, limit: limit)
    }

    /// Dense float recall for ONE provider — the per-signal mechanics shared by
    /// `floatNearest`/`floatNearestPerSignal` (nearest) and
    /// `floatFarthestPerSignal` (farthest, anti-similarity).
    ///
    /// Embeds `query` via `provider.embedFloat`, ranks stored chunks for that
    /// provider's modelID by cosine over the in-house `FloatBruteForceIndex`,
    /// aggregates chunk hits to source (drawer) level, and returns an observable
    /// `FloatLaneOutcome`. The telemetry counters and the degradation contract
    /// are identical regardless of direction.
    ///
    /// `direction` selects the objective (mission 6b-modifiers-antisim):
    ///   - `.nearest`  — surface the most SIMILAR sources. The store returns the
    ///     nearest chunks (`findNearestFloat`); a source's similarity is its
    ///     BEST (max) chunk cosine; sources rank similarity DESCENDING. This is
    ///     byte-identical to the pre-antisim behaviour (default).
    ///   - `.farthest` — surface the most DISSIMILAR sources ("find things
    ///     UNLIKE this"). The store returns the farthest chunks
    ///     (`findFarthestFloat`); a source's dissimilarity is its WORST (min)
    ///     chunk cosine; sources rank similarity ASCENDING. The max→min
    ///     inversion is required: a source's anti-similarity is governed by its
    ///     LEAST-similar chunk, the mirror of nearest's best-chunk rule.
    private func floatNearest(
        provider: any EmbeddingProvider,
        query: String,
        limit: Int,
        direction: SearchDirection = .nearest
    ) async -> FloatLaneOutcome {
        // Attempt to embed the query text via the float lane.
        //
        // Three distinct paths:
        //   1. Result is non-empty → proceed with the probe vector.
        //   2. Result is empty ([] from an untrained provider, or text that
        //      tokenises to nothing) → structural opt-out. Emit the
        //      dark_provider counter and return .unavailableProviderOptOut.
        //   3. Throw VectorKitError.embedFloatVocabMiss → the provider HAS a
        //      trained basis but all query tokens are OOV. This is a vocabulary
        //      coverage miss, not a structural opt-out. Return
        //      .unavailableNoVocabHit with its own counter so callers observe
        //      the correct dark-lane reason.
        //   4. Any other throw → structural opt-out (same as path 2).
        //
        // Path 2 and 4 share the dark_provider counter. Path 3 has its own
        // dark_vocabMiss counter (corpus.float_lane.dark_vocab_miss).
        let probe: [Float]
        do {
            let result = try await provider.embedFloat(query)
            guard !result.isEmpty else {
                // Provider returned an empty vector (untrained distributional
                // provider, or text that produces no tokens). Classify as
                // structural opt-out: the provider cannot produce a float vector
                // for structural reasons, not because of vocabulary coverage.
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider",
                    value: 1.0,
                    tags: ["kit": "CorpusKit"],
                    ts: Date().timeIntervalSince1970
                ))
                return .unavailableProviderOptOut
            }
            probe = result
        } catch VectorKitError.embedFloatVocabMiss {
            // Trained distributional provider: basis exists but query tokens
            // are all OOV. This is a vocabulary coverage miss — truthfully
            // distinct from a structural opt-out. Emit a separate counter
            // so telemetry surfaces vocabulary coverage vs. lane availability.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_vocab_miss",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoVocabHit
        } catch {
            // Provider threw a non-vocabMiss error — structural opt-out (e.g.
            // the deterministic provider, or any provider without a float lane).
            // Log nothing; emit the dark_provider counter only.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_provider",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableProviderOptOut
        }

        // Over-fetch 4× at the CHUNK granularity so that after source-level
        // aggregation we still have at least `limit` sources, mirroring
        // bm25TopKBySource's over-fetch discipline. The float index keys rows by
        // chunk.id (the vector item_id); we aggregate to sourceID below.
        let matches: [VectorMatch]
        do {
            // Direction selects which end of the cosine ranking the store
            // returns. Farthest is NOT a reordering of nearest results — the
            // dissimilar chunks are not in the nearest top-K, so the store must
            // run the farthest scan (mission 6b-modifiers-antisim).
            switch direction {
            case .nearest:
                matches = try await vectorStore.findNearestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            case .farthest:
                matches = try await vectorStore.findFarthestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            }
        } catch {
            // Store threw — this is NOT expected. Log it via OSLog so it is
            // never silent, then emit the store_error counter for telemetry
            // dashboards and alerts.
            corpusLog.error("floatNearest: findNearestFloat failed — \(error, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(error)
        }

        // Empty matches means no float rows are stored — expected dark outcome.
        guard !matches.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Aggregate chunk-level cosine to SOURCE (drawer) level. The vector
        // item_id is the chunk uuid string; chunkSourceMap resolves it to the
        // sourceID the caller ingested under (the drawer id in the GLK context),
        // exactly as bm25TopKBySource does, so float hits hydrate back to the
        // real Drawer row.
        //   .nearest  — a source's similarity is its BEST (max) chunk cosine.
        //   .farthest — a source's anti-similarity is governed by its WORST
        //               (min) chunk cosine: a source is "unlike the query" only
        //               if even its closest chunk is far. Picking max here would
        //               surface sources that happen to have one near chunk, the
        //               opposite of the anti-similarity objective.
        // VectorMatch.distance is the cosine DISTANCE (1 − sim) quantised
        // ×10_000 (FloatBruteForceIndex convention); recover sim = 1 − dist/1e4.
        var bySource: [String: Float] = [:]
        for m in matches {
            guard let chunkUUID = UUID(uuidString: m.itemID),
                  let sourceID = chunkSourceMap[chunkUUID] else { continue }
            let similarity = 1.0 - Float(m.distance) / 10_000.0
            switch direction {
            case .nearest:
                bySource[sourceID] = max(bySource[sourceID] ?? -Float.greatestFiniteMagnitude, similarity)
            case .farthest:
                bySource[sourceID] = min(bySource[sourceID] ?? Float.greatestFiniteMagnitude, similarity)
            }
        }

        // After source aggregation, no results means no chunks are in the
        // chunk→source map (all chunks were removed). Treat as no-rows dark.
        guard !bySource.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Sort by similarity, sourceID ascending on tie (the universal
        // deterministic tie-break), and return the top `limit`.
        //   .nearest  — similarity DESCENDING (most similar first).
        //   .farthest — similarity ASCENDING (most dissimilar first).
        // The tie-break (sourceID ascending) is identical in both directions.
        var ranked = bySource.map { (itemID: $0.key, similarity: $0.value) }
        ranked.sort { a, b in
            if a.similarity != b.similarity {
                switch direction {
                case .nearest:  return a.similarity > b.similarity
                case .farthest: return a.similarity < b.similarity
                }
            }
            return a.itemID < b.itemID
        }
        let result = Array(ranked.prefix(limit))

        // Happy path — lane ran. Emit hit counter (count = result size so
        // dashboards can see both that the lane ran and how many hits emerged).
        Intellectus.report(.metric(
            name: "corpus.float_lane.hit",
            value: Double(result.count),
            tags: ["kit": "CorpusKit"],
            ts: Date().timeIntervalSince1970
        ))
        return .hits(result)
    }

    /// Per-signal dense float nearest-neighbour recall (the 6b RRF-fusion seam).
    ///
    /// Runs the dense float lane independently for EVERY held provider slot,
    /// each queried against its own modelID float index, and returns one ranked
    /// `FloatLaneOutcome` per signal tagged by that signal's `modelID`. The
    /// outcome ordering follows slot (construction) order, so `[0]` is always
    /// the default signal.
    ///
    /// This is the seam the 6b mission's RRF/consensus fusion consumes: each
    /// signal's per-source similarity ranking is exposed separately, preserving
    /// the `FloatLaneOutcome` dark-lane observability per signal (a signal whose
    /// provider opted out reports `.unavailableProviderOptOut`; one with no rows
    /// reports `.unavailableNoFloatRows`; and so on). NO fusion happens here —
    /// the caller (6b) decides how to combine the per-signal lists.
    ///
    /// For N=1 this returns a single-element array whose only outcome equals what
    /// `floatNearest(query:limit:)` would return — same default-signal mechanics.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot order.
    ///   An empty query or zero limit returns one `.emptyQuery` outcome per
    ///   signal (no store access), mirroring the single-signal no-op guard.
    public func floatNearestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        // No-op guard mirrors floatNearest: an empty query / zero limit yields a
        // per-signal .emptyQuery without touching the store. Returning one entry
        // per signal keeps the result shape stable (the caller can still see
        // every signal's modelID).
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        // Test-only hook: a forced store error is consumed for the DEFAULT slot
        // (slot 0), mirroring the single-signal `floatNearest(query:limit:)`
        // contract. GLK's dense lane consumes this method, so the store-error dark
        // contract must remain observable through the per-signal path: the default
        // signal reports `.storeError`, other slots run normally. The seam is
        // single-use and consumed here exactly as the single-signal entry does.
        var forcedDefaultStoreError: FloatLaneOutcome? = nil
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            corpusLog.error("floatNearestPerSignal: findNearestFloat failed (default signal) — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            forcedDefaultStoreError = .storeError(forced)
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let provider = slot.provider
            // Slot 0 (default signal) honours the forced-error seam if installed;
            // all other slots — and slot 0 when no seam is set — run the real lane.
            let outcome: FloatLaneOutcome
            if index == 0, let forced = forcedDefaultStoreError {
                outcome = forced
            } else {
                outcome = await floatNearest(provider: provider, query: query, limit: limit)
            }
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Per-signal dense float FARTHEST recall — the anti-similarity sibling of
    /// `floatNearestPerSignal` (mission 6b-modifiers-antisim).
    ///
    /// Runs the dense float lane in the FARTHEST direction independently for
    /// EVERY held provider slot: each signal surfaces the most DISSIMILAR
    /// sources for its modelID ("find things UNLIKE this"), ranked least-similar
    /// first. The outcome shape, dark-lane observability, telemetry counters,
    /// and slot ordering are identical to `floatNearestPerSignal`; only the
    /// ranking objective differs (the store returns the farthest chunks, and a
    /// source's score is its WORST chunk cosine — see `floatNearest(provider:…)`).
    ///
    /// This is the seam GLK's RecallShape `antiSimilarLanes` consumes: a dense
    /// lane marked anti-similar queries THIS method for its per-signal list
    /// instead of `floatNearestPerSignal`, so the dissimilar candidates flow
    /// into the same RRF/consensus fold.
    ///
    /// The forced-error test seam is NOT consulted here — it is nearest-path
    /// test infrastructure (`floatNearest`/`floatNearestPerSignal` only), so the
    /// farthest path always runs the real lane.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot
    ///   order. An empty query or zero limit returns one `.emptyQuery` outcome
    ///   per signal (no store access), mirroring the nearest no-op guard.
    public func floatFarthestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for slot in slots {
            let provider = slot.provider
            let outcome = await floatNearest(
                provider: provider, query: query, limit: limit, direction: .farthest)
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Whether this corpus's DEFAULT signal supports the dense float lane
    /// (Lane D). True when `embedFloat` returns a vector rather than throwing
    /// the opt-out error. Probes with a single non-empty token so the answer
    /// reflects provider capability, not input. The GLK dense lane checks this
    /// (via a non-empty `floatNearest`) before fusing the dense column.
    public var supportsFloat: Bool {
        get async {
            ((try? await defaultProvider.embedFloat("x")) ?? []).isEmpty == false
        }
    }

    /// Count the total chunks in the bundle store across all sources.
    ///
    /// This count does not decrease when `remove(sourceID:)` is called —
    /// removed chunks are still stored but no longer appear in recall results.
    /// After `expunge(sourceID:)`, rows remain but their text is zeroed.
    public func count() async throws -> Int {
        // Excludes removed (recall-suppressed) sources: a removed source's chunks
        // remain stored but must not be counted as live recall content.
        // Fast path when nothing is removed (a plain row count).
        let removed = try await removedSourceStore.removedIDs()
        if removed.isEmpty { return try await bundleStore.count() }
        let all = try await bundleStore.allChunks()
        return all.filter { !removed.contains($0.sourceID) }.count
    }

    /// Return the set of all distinct source IDs (drawer IDs) currently in the
    /// chunks table — i.e. every drawer that has been ingested into this Corpus.
    ///
    /// Used by `GeniusLocusKit.reindexMissing(handle:)` to identify which
    /// drawers already have at least one chunk and can be skipped during
    /// a backfill sweep. The query touches all chunk rows but is only used
    /// in maintenance/admin contexts, never on hot paths.
    public func indexedSourceIDs() async throws -> Set<String> {
        try await bundleStore.allSourceIDs()
    }

    /// Resolve chunk IDs to the source (drawer) IDs that own them.
    ///
    /// Reads the warm in-memory `chunkSourceMap` (chunk id → source_id) that
    /// `open()` loads and every ingest maintains — no table scan, no body
    /// decode. IDs with no mapping (never ingested, or from another estate)
    /// are simply absent from the result.
    ///
    /// Used by `GeniusLocusKit.huntContradictions` to map vector rows —
    /// which the encode pipeline keys by CHUNK UUID — back to the drawers
    /// whose content they embed, so kNN hits on the corpus lane become
    /// drawer-pair candidates.
    public func sourceIDs(forChunkIDs ids: [UUID]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        out.reserveCapacity(ids.count)
        for id in ids {
            if let source = chunkSourceMap[id] { out[id] = source }
        }
        return out
    }

    // MARK: - Merkle attestation (NT-C1)

    /// Per-corpus Merkle root for a given source.
    /// Returns `MerkleRoot.empty` when no metadata row exists.
    public func corpusMerkleRoot(for sourceID: String) async throws -> MerkleRoot {
        try await bundleStore.corpusMerkleRoot(for: sourceID)
    }

    /// Estate-level corpus Merkle root — interior hash over all per-corpus roots.
    /// Returns `MerkleRoot.empty` when no corpora exist.
    public func globalCorpusMerkleRoot() async throws -> MerkleRoot {
        try await bundleStore.globalCorpusMerkleRoot()
    }
}

// MARK: - EmbeddingModel → provider construction

extension EmbeddingModel {
    // Projection seeds match CorpusKitProviders' model-specific seeds so
    // storage keys are consistent regardless of which surface is used.
    // Changing a seed re-keys all stored vectors for that model.
    private static let miniLMSeed: UInt64 = 0x4D49_4E4C_4D5F_7631       // "MINLM_v1"
    private static let mpNetSeed: UInt64 = 0x4D50_4E45_545F_7631        // "MPNET_v1"
    private static let embeddingGemmaSeed: UInt64 = 0x454D_4247_4D5F_7631 // "EMBGM_v1"
    // Deterministic seed is CorpusKit-specific; distinct from all model seeds.
    private static let deterministicSeed: UInt64 = 0xC05B_D15C_A15D_1B00

    /// Construct the concrete EmbeddingProvider for this model selection.
    /// The returned value is held privately inside the Corpus actor and
    /// never exposed on the public API.
    fileprivate func makeProvider() -> any EmbeddingProvider {
        switch self {
        case .randomIndexing(let provider):
            // The caller built and trained the provider externally. Pass it
            // through unchanged — no further construction needed here.
            return provider

        case .ppmi(let provider):
            // The caller built, trained, and finalized the PpmiProvider
            // externally. Pass through unchanged — no further construction
            // needed here. The finalization step (count → PPMI vectors) must
            // already have happened before this Corpus is used for recall.
            return provider

        case .lsa(let provider):
            // The caller built and trained the LsaProvider externally (term-
            // document matrix + SVD). Pass through unchanged.
            return provider

        case .nmf(let provider):
            // The caller built, trained, and finalized the NmfProvider externally
            // (TF matrix + NMF factorization via SubstrateML). Pass through unchanged.
            return provider

        case .fdc(let provider):
            // The caller constructed an FDCProvider externally. FDCProvider is
            // stateless (no training required) — the caller just passes it through
            // to register it as the fusion voter. Pass through unchanged.
            return provider

        case .deterministic:
            // FNV-1a 64-bit hash of the input text drives a 32-element
            // float vector. Each element is drawn from an LCG seeded by
            // the text hash, mapped to [-1, 1]. Consistent across calls;
            // not semantically meaningful.
            return FloatSimHashEmbeddingProvider(
                modelID: "corpus-deterministic-v1",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.deterministicSeed,
                inference: { text in
                    let fnvPrime: UInt64 = 1_099_511_628_211
                    let lcgMultiplier: UInt64 = 6_364_136_223_846_793_005
                    let lcgIncrement: UInt64 = 1_442_695_040_888_963_407
                    var h = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                        ($0 ^ UInt64($1)) &* fnvPrime
                    }
                    return (0..<32).map { _ in
                        h = h &* lcgMultiplier &+ lcgIncrement
                        // High 24 bits as a mantissa in [0, 1), then scale to [-1, 1].
                        let mantissa = Float(h >> 40) / Float(1 << 24)
                        return mantissa * 2.0 - 1.0
                    }
                }
            )

        case .miniLM(let inference):
            return CorpusTextProvider(
                modelID: "minilm-v6",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.miniLMSeed,
                vocabSize: 30522,
                maxTokenLen: 128,
                inference: inference
            )

        case .mpNet(let inference):
            return CorpusTextProvider(
                modelID: "mpnet-base-v2",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.mpNetSeed,
                vocabSize: 30522,
                maxTokenLen: 128,
                inference: inference
            )

        case .embeddingGemma(let inference):
            return CorpusTextProvider(
                modelID: "embedding-gemma-300m",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.embeddingGemmaSeed,
                vocabSize: 256_000,
                maxTokenLen: 2048,
                inference: inference
            )

#if canImport(NaturalLanguage)
        case .nlEmbedding(let provider):
            // The caller constructed an NLEmbeddingProvider (or a compatible
            // EmbeddingProvider) externally and passes it through here — same
            // pattern as .fdc(provider:). No further construction needed.
            return provider

        case .nlContextualEmbedding(let provider):
            // Same pass-through pattern. The caller constructed an
            // NLContextualEmbeddingProvider externally; we register it
            // as the serving provider for the "apple-nlcontextual-v1" lane.
            return provider
#endif // canImport(NaturalLanguage)
        }
    }
}

// MARK: - Private helpers

/// FNV-1a tokenizer used by the Corpus actor's BM25 index and as the
/// bridge tokenizer for named model cases.
///
/// Uses the same FNV-1a word-fold algorithm as `DeterministicTokenizer`
/// in CorpusKitProviders (FNV-1a 32-bit over UTF-8 bytes, folded into
/// [2, vocabSize)). Defined here because CorpusKitProviders depends on
/// CorpusKit — importing it from here would create a circular dependency.
// Internal (not private) so HybridRecall.swift can tokenise queries
// with the same vocabulary before calling InvertedIndexStore.topK(queryTerms:k:).
struct CorpusDefaultTokenizer: Tokenizer {
    let vocabID: String
    let maxTokens: Int
    let padTokenID: Int32 = 0
    let unknownTokenID: Int32 = 1
    private let vocabRange: UInt32   // vocabSize - 2; token ids live in [2, vocabSize)

    init(vocabID: String = "corpus-default-v1",
         maxTokens: Int = 128,
         vocabSize: UInt32 = 30522) {
        self.vocabID = vocabID
        self.maxTokens = maxTokens
        self.vocabRange = vocabSize - 2
    }

    func tokenize(_ text: String) -> [Int32] {
        keywordTokens(text).prefix(maxTokens).map { word in
            // FNV-1a 32-bit: fold each UTF-8 byte into [2, vocabSize).
            let h = word.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 1_677_619 }
            return Int32(2 + Int(h % vocabRange))
        }
    }
}

/// EmbeddingProvider adapter for named model cases (miniLM, mpNet,
/// embeddingGemma). Tokenizes text using CorpusDefaultTokenizer's FNV-1a
/// fold, calls the host-supplied CoreML inference closure, and projects
/// the resulting float vector through FloatSimHash with the model's
/// canonical seed.
///
/// This type is private to CorpusKit; it does not appear on any public
/// signature. Callers interact only through `EmbeddingModel` cases.
private struct CorpusTextProvider: EmbeddingProvider {
    let modelID: String
    let modelVersion: String
    let projectionSeed: UInt64
    private let tokenizer: CorpusDefaultTokenizer
    let inference: @Sendable ([Int32]) async throws -> [Float]

    init(modelID: String,
         modelVersion: String,
         projectionSeed: UInt64,
         vocabSize: UInt32,
         maxTokenLen: Int,
         inference: @escaping @Sendable ([Int32]) async throws -> [Float]) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
        self.tokenizer = CorpusDefaultTokenizer(
            vocabID: modelID,
            maxTokens: maxTokenLen,
            vocabSize: vocabSize
        )
        self.inference = inference
    }

    func embed(_ text: String) async throws -> Engram {
        guard !text.isEmpty else { return Engram.zero }
        let tokens = tokenizer.tokenize(text)
        let floats = try await inference(tokens)
        return FloatSimHash.project(vector: floats, seed: projectionSeed)
    }

    /// Float lane source (Lane D): the pooled vector this provider's `embed`
    /// already computes before projecting it to the 256-bit engram. Returning
    /// it directly feeds the dense float lane's cosine ranking — one inference
    /// pass, two stored rows. Empty input returns `[]` (no dense direction for
    /// the empty string), matching the `EmbeddingProvider.embedFloat` contract.
    /// This is the production float-lane path for the `.miniLM`/`.mpNet`/
    /// `.embeddingGemma` models; without it those models would have NO float
    /// lane (the protocol default opts out by throwing).
    func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        let tokens = tokenizer.tokenize(text)
        return try await inference(tokens)
    }

    /// Single-inference override: `embed` and `embedFloat` both tokenize and
    /// run the same inference pass — `embed` projects the pooled vector to the
    /// 256-bit engram, `embedFloat` returns it raw. Running both separately
    /// pays for two inference passes over identical tokens. This computes the
    /// pooled vector ONCE and returns both the projected engram and the floats,
    /// halving inference cost on the capture/reembed path. Output is identical
    /// to calling `embed` and `embedFloat` separately: empty input opts out of
    /// the float lane (`[]`) and yields `Engram.zero`, matching both methods.
    func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        guard !text.isEmpty else { return (.zero, []) }
        let tokens = tokenizer.tokenize(text)
        let floats = try await inference(tokens)
        return (FloatSimHash.project(vector: floats, seed: projectionSeed), floats)
    }
}

// MARK: - BackendConfiguration shard helper (EXT-4)

extension BackendConfiguration {
    /// Extract the SQLite URL for import-shard placement (the shard files live
    /// beside the estate so the install-key discipline applies uniformly).
    /// Returns nil for non-SQLite backends — the import then takes the serial
    /// path. Internal twin of the file-private helper in CorpusIngestQueue.swift.
    var sqliteURLForShards: URL? {
        if case let .sqlite(url, _) = self { return url }
        return nil
    }
}
