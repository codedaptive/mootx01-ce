// CorpusContentEngine.swift
//
// The ONE canonical indexing and recall engine (GLK shared-content 1.1, P2).
//
// The engine consumes the content boundary (`CorpusContentSource`) and
// keys EVERY derived row — BM25 postings, vector items, checkpoints — by
// the canonical content ID (the Drawer ID in attached mode). There is no
// chunk identity lane, no chunk-to-content translation map, and no copied
// text anywhere in the engine's storage:
//
//   - `.wholeContent` (the default and the ONLY attached policy): one
//     index unit per content row, keyed by the content ID itself. Recall
//     returns content IDs directly.
//   - standalone `.tokenWindows`: index units use a token window + overlap
//     UTF-8 RANGES over canonical text (`corpus_passages` rows — no
//     copied text). Passage hits AGGREGATE to the canonical ID; the range
//     is carried as evidence and never changes result identity.
//
// The engine resolves text BY ID at work time. Queue payloads
// (`ContentIndexJob`) carry id/revision/digest/cursor only; a job whose
// (revision, digest) no longer matches the CURRENT record is rejected
// with `staleRevision` and the checkpoint does not advance — a stale job
// can never overwrite a newer revision.
//
// The legacy `Chunk`/`Chunker`/`BundleStore` surface remains a 1.0
// standalone compatibility surface on the `Corpus` actor only; nothing
// here reaches it. Vector writes are exact-key scoped
// (`deleteVectors(keys:)` + upserts) and every representation this
// engine produces is claimed in the `VectorRepresentationClaims` ledger
// under the "corpus" consumer.
//
// Rust twin: `rust/src/content_engine.rs`.

import EngramLib
import Foundation
import IntellectusLib
import OSLog
import PersistenceKit
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes
import VectorKit

// Logger shared by the engine and its queue extension (CorpusContentEngineQueue.swift).
private let contentEngineLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

// MARK: - Results

/// Range evidence for a standalone passage hit. Never changes result
/// identity — the hit's `id` is always the canonical content ID.
public struct CorpusEvidence: Sendable, Equatable {
    public let passageID: String
    public let utf8Start: Int
    public let utf8Length: Int

    public init(passageID: String, utf8Start: Int, utf8Length: Int) {
        self.passageID = passageID
        self.utf8Start = utf8Start
        self.utf8Length = utf8Length
    }
}

/// One recall result: a canonical content ID plus fused score. The caller
/// hydrates content from the canonical store (Drawers in GLK) — the
/// engine never returns copied text.
public struct CorpusContentHit: Sendable, Equatable {
    public let id: CorpusContentID
    public let score: Float
    public let keywordScore: Float?
    public let vectorScore: Float?
    /// Present only in standalone passage mode (the best-scoring passage).
    public let evidence: CorpusEvidence?

    public init(
        id: CorpusContentID, score: Float, keywordScore: Float?,
        vectorScore: Float?, evidence: CorpusEvidence? = nil
    ) {
        self.id = id
        self.score = score
        self.keywordScore = keywordScore
        self.vectorScore = vectorScore
        self.evidence = evidence
    }
}

// MARK: - Queue payload

/// The async index-work payload: identity, revision, digest, cursor —
/// NEVER text. The worker resolves the current record by ID at work time.
/// Codable keys are the cross-port wire contract (Rust `ContentIndexJob`).
public struct ContentIndexJob: Sendable, Codable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case upsert
        case remove
    }
    public let kind: Kind
    public let contentID: CorpusContentID
    public let revision: Int64
    /// Present for upserts; nil for removes.
    public let digest: String?
    /// The source cursor this change was drained at, when feed-driven.
    public let cursor: String?

    public init(
        kind: Kind, contentID: CorpusContentID, revision: Int64,
        digest: String?, cursor: String?
    ) {
        self.kind = kind
        self.contentID = contentID
        self.revision = revision
        self.digest = digest
        self.cursor = cursor
    }

    public init(change: CorpusContentChange, cursor: String?) {
        switch change {
        case .upsert(let id, let revision, let digest):
            self.init(kind: .upsert, contentID: id, revision: revision,
                      digest: digest, cursor: cursor)
        case .remove(let id, let revision):
            self.init(kind: .remove, contentID: id, revision: revision,
                      digest: nil, cursor: cursor)
        }
    }
}

// MARK: - Index-unit identity

/// Maps a derived-row key back to its canonical content identity. In the
/// GLK/MOOTx01 build this compiles to the identity function because passage
/// keys cannot be produced. The parsing branch exists only in standalone
/// passage builds.
enum IndexUnitIdentity {
    /// Reserved internal separator. Content IDs reject it in every build so
    /// a database created without passages can safely enable them only via an
    /// explicit future rebuild.
    static let reservedSeparator = "\u{1F}"

    static func contentID(fromItemKey key: String) -> CorpusContentID {
#if CORPUSKIT_STANDALONE_PASSAGES
        guard let range = key.range(of: reservedSeparator) else { return key }
        return String(key[key.startIndex..<range.lowerBound])
#else
        return key
#endif
    }

    static func evidence(fromItemKey key: String) -> CorpusEvidence? {
#if CORPUSKIT_STANDALONE_PASSAGES
        let parts = key.components(separatedBy: reservedSeparator)
        guard parts.count == 4, let start = Int(parts[2]), let length = Int(parts[3]) else {
            return nil
        }
        return CorpusEvidence(passageID: key, utf8Start: start, utf8Length: length)
#else
        return nil
#endif
    }
}

#if CORPUSKIT_STANDALONE_PASSAGES
// MARK: - Standalone passage production

/// Deterministic token-budgeted passage ranges over UTF-8 text.
///
/// Token boundaries follow the SAME alphanumeric-run rule as
/// `defaultKeywordTokens` (runs of Unicode-alphabetic + ASCII-digit
/// scalars), computed WITHOUT lowercasing so byte offsets refer to the
/// original text. Passages use a configurable sliding token window; each
/// range spans from its first token's
/// start byte through its last token's end byte. Cross-port identical
/// (Rust `passage_ranges`).
enum PassageProduction {
    static func passageRanges(
        text: String, windowTokens: Int, overlapTokens: Int
    ) -> [(utf8Start: Int, utf8Length: Int)] {
        precondition(windowTokens > 0)
        precondition(overlapTokens >= 0 && overlapTokens < windowTokens)
        // Token byte ranges under the alphanumeric-run rule.
        var tokenRanges: [(start: Int, end: Int)] = []
        var offset = 0
        var runStart: Int? = nil
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            let isToken = scalar.properties.isAlphabetic
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isToken {
                if runStart == nil { runStart = offset }
            } else if let start = runStart {
                tokenRanges.append((start, offset))
                runStart = nil
            }
            offset += width
        }
        if let start = runStart { tokenRanges.append((start, offset)) }

        var out: [(utf8Start: Int, utf8Length: Int)] = []
        var index = 0
        while index < tokenRanges.count {
            let windowEnd = min(index + windowTokens, tokenRanges.count)
            let first = tokenRanges[index]
            let last = tokenRanges[windowEnd - 1]
            out.append((utf8Start: first.start, utf8Length: last.end - first.start))
            if windowEnd == tokenRanges.count { break }
            index += windowTokens - overlapTokens
        }
        return out
    }

    /// Field separator inside passage keys — cannot appear in validated
    /// content IDs.
    static let keySeparator = IndexUnitIdentity.reservedSeparator

    /// The deterministic passage key: contentID␟revision␟start␟length.
    static func passageKey(
        contentID: CorpusContentID, revision: Int64, utf8Start: Int, utf8Length: Int
    ) -> String {
        "\(contentID)\(keySeparator)\(revision)\(keySeparator)\(utf8Start)\(keySeparator)\(utf8Length)"
    }

}
#endif

// MARK: - Engine

/// The canonical-ID indexing/recall engine. One engine serves BOTH
/// operating modes; only the content source and the (validated)
/// configuration differ.
public actor CorpusContentEngine {

    /// The engine/index layout version stamped into `corpus_index_state`.
    /// Bump when the derived layout changes incompatibly.
    /// v2 (corrective pass): per-provider coverage rows; attached-mode
    /// binary rows written for the DEFAULT slot only.
    public static let indexVersion: Int64 = 2

    /// The consumer name this engine claims representations under.
    public static let claimsConsumer = "corpus"

    /// Reserved checkpoint row recording the last APPLIED feed cursor —
    /// the lane-level cursor a remove records (a removed ID has no
    /// per-content checkpoint row to carry it). The reserved ID starts
    /// with the key separator, which no validated content ID can.
    static let feedCursorRowID = "\u{1F}feed"

    private struct Slot {
        var provider: any EmbeddingProvider
        let freshBasisBlob: Data?
        var countsAccumulator: (any TrainableEmbeddingBasis)?
        var countsDocumentCount: Int
        /// Hashes of vocabulary terms first observed after the published
        /// counts generation. Persisted inside identity-scoped references, so
        /// repeated revisions and reopen reconstruct the same monotonic set
        /// without mutating the frozen provider counts blob.
        var growthTermDigests: Set<String> = []
        /// Governor-facing vocabulary-growth anchor: persisted on the counts
        /// row in the same transaction as every reference mutation so the
        /// threshold decision is restart-deterministic.
        var countsVocabAnchor: Int = 0
        /// The basis-generation anchor stamped into coverage rows: for
        /// trainable slots the SHA-256 of the persisted basis blob (empty
        /// string while untrained); for stateless slots a constant derived
        /// from the model version (their representation never regenerates).
        var basisDigest: String
    }

    /// A trainable slot with no trained basis yet carries this digest;
    /// coverage rows are never written under it.
    static let untrainedDigest = ""

    /// The stateless-slot digest: the representation is a pure function of
    /// the model version, so the version IS the generation.
    static func statelessDigest(modelVersion: String) -> String {
        "stateless@\(modelVersion)"
    }

    // Internal (not private) so the queue extension in
    // CorpusContentEngineQueue.swift can reach the estate configuration.
    let storage: any Storage
    private let configuration: CorpusContentConfiguration
    // Internal so the queue drain worker resolves records at work time.
    let source: any CorpusContentSource
    private let invertedIndex: InvertedIndexStore
    private let vectorStore: VectorStore
    private let basisStore: BasisStore
    private let countsStore: CorpusProviderCountsStore
    private let indexState: CorpusIndexStateStore
    private let coverageStore: CorpusProviderCoverageStore
    private let providerConfigurationStore: CorpusProviderConfigurationStore
    private let claims: VectorRepresentationClaims
    private var slots: [Slot]
    /// Set after an ambiguous counts/checkpoint transaction failure. The next
    /// queue attempt must rehydrate the in-memory accumulators from durable
    /// state before it can fold another content reference.
    private var countsReloadRequired = false
    /// Actor methods are reentrant at storage awaits. Keep reference lookup,
    /// in-memory folding, and transactional publication in one logical
    /// admission critical section without serializing preparation or reindex.
    private var countsAdmissionActive = false
    private var countsAdmissionWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Content-reference ingest queue state (GLK shared-content P3)
    //
    // The engine owns its encode pipeline exactly as the legacy Corpus did —
    // QueueKit jobs on the shared per-estate queue.sqlite, one cross-process
    // drainer per stream — but the JOB PAYLOAD is a `ContentIndexJob`
    // (id/revision/digest/cursor): Drawer change references, never text.
    // See CorpusContentEngineQueue.swift for the methods.

    /// The engine-owned ingest queue. nil until `mountIngestQueue()`.
    var ingestQueue: QueueKit?
    /// The background drain worker; spawned in `mountIngestQueue`, cancelled
    /// in `dropIngestQueue`.
    var ingestDrainWorker: Task<Void, Never>?
    /// Single-drainer lease for durable estates ("encode" stream).
    var drainLease: DrainLease?
    /// Per-engine HLC for stamping queue submissions (deterministic — derived
    /// from each change's capture instant, no Date() in the engine).
    var ingestHLC = HLCGenerator(nodeID: 1)
    /// Invoked AFTER a drained batch indexes, with the affected canonical
    /// content IDs (Drawer IDs) — GLK's room-rollup coordination hook.
    public var onEncoded: (@Sendable ([String]) async -> Void)?

    /// Cancel the drain worker and release the lease on teardown (mirror of
    /// `Corpus.deinit`; the explicit path is `dropIngestQueue()`).
    deinit {
        ingestDrainWorker?.cancel()
        drainLease?.release()
    }

    /// Construct the engine over a validated configuration and content
    /// source. Applies the mode's profile declaration plus the VectorKit
    /// and claims schemas (all additive/idempotent). In attached mode NO
    /// canonical content table is created.
    public init(
        storage: any Storage,
        configuration: CorpusContentConfiguration,
        source: any CorpusContentSource,
        models: [EmbeddingModel] = [.default]
    ) async throws {
        guard !models.isEmpty else {
            throw CorpusKitError.invalidConfiguration(
                "CorpusContentEngine requires at least one embedding model")
        }
        switch configuration.mode {
        case .standalone:
#if CORPUSKIT_STANDALONE_PASSAGES
            var passages = false
            if case .tokenWindows = configuration.indexUnit { passages = true }
            try await storage.migrate(
                to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: passages))
            try await CorpusIndexConfigurationStore(storage: storage)
                .bind(configuration.indexUnit)
#else
            try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
#endif
        case .attached:
            try await storage.migrate(to: CorpusSchemaProfile.attachedDeclaration)
        }
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)

        self.storage = storage
        self.configuration = configuration
        self.source = source
        self.invertedIndex = InvertedIndexStore(storage: storage)
        self.vectorStore = VectorStore(
            storage: storage, sidecarURL: VectorStore.defaultSidecarURL(for: storage))
        self.basisStore = BasisStore(storage: storage)
        self.countsStore = CorpusProviderCountsStore(storage: storage)
        self.indexState = CorpusIndexStateStore(storage: storage)
        self.coverageStore = CorpusProviderCoverageStore(storage: storage)
        self.providerConfigurationStore = CorpusProviderConfigurationStore(storage: storage)
        self.claims = VectorRepresentationClaims(storage: storage)

        var built: [Slot] = []
        built.reserveCapacity(models.count)
        for model in models {
            let fresh = model.makeProvider()
            let resolved = try await Corpus.resolveProvider(
                freshProvider: fresh,
                isTrainable: model.isTrainable,
                basisStore: basisStore,
                countsStore: countsStore)
            // Basis-generation digest: stateless slots derive it from the
            // model version; trainable slots from the PERSISTED basis blob
            // (empty until trained — coverage is never written untrained).
            let digest: String
            if model.isTrainable {
                if let persisted = try await basisStore.load(
                    modelID: resolved.provider.modelID,
                    modelVersion: resolved.provider.modelVersion) {
                    digest = CorpusContentDigest.digest(persisted.basis)
                } else {
                    digest = Self.untrainedDigest
                }
            } else {
                digest = Self.statelessDigest(modelVersion: resolved.provider.modelVersion)
            }
            built.append(Slot(
                provider: resolved.provider,
                freshBasisBlob: resolved.freshBasisBlob,
                countsAccumulator: resolved.countsAccumulator,
                countsDocumentCount: resolved.countsDocumentCount,
                basisDigest: digest))
        }
        self.slots = built
        // A base counts blob is compacted only at provider publication. Replay
        // the reference-only deltas accumulated since that snapshot so reopen
        // restores the exact live growth anchor without rewriting estate-scale
        // blobs for every Drawer.
        try await reloadCountsFromStorage()
        try await invertedIndex.open()
    }

    /// Register this engine's representation claims (idempotent). Called
    /// by the engine's writers before the first vector write; exposed so
    /// lifecycle paths can pre-claim at construction.
    public func registerClaims(now: Date) async throws {
        for (index, slot) in slots.enumerated() {
            for lane: Int in [0, 1] {
                // Attached mode writes binary (lane 0) rows for the DEFAULT
                // slot only — GLK's Hamming readers all probe the default
                // model — so non-default binary claims are not registered
                // there either. Standalone keeps per-slot binary lanes.
                if lane == 0 && index != 0 && configuration.mode == .attached { continue }
                try await claims.registerClaim(
                    consumer: Self.claimsConsumer,
                    key: VectorRepresentationKey(
                        modelID: slot.provider.modelID,
                        modelVersion: slot.provider.modelVersion,
                        vectorIndex: lane),
                    now: now)
            }
        }
    }

    /// Current-runtime provider reconciliation. This is deliberately NOT a
    /// historical schema migration: every current-format engine runs it after
    /// open so adding a provider backfills its missing generation and removing
    /// one releases only CorpusKit's claims and now-unowned artifacts.
    /// Reopen/replay is idempotent.
    public func reconcileConfiguredProviders(now: Date) async throws {
        let desired = Set(slots.enumerated().flatMap { index, slot -> [VectorRepresentationKey] in
            [0, 1].compactMap { lane in
                if lane == 0 && index != 0 && configuration.mode == .attached { return nil }
                return VectorRepresentationKey(
                    modelID: slot.provider.modelID,
                    modelVersion: slot.provider.modelVersion,
                    vectorIndex: lane)
            }
        })
        let existing = Set(try await claims.claims(consumer: Self.claimsConsumer))
        if existing == desired,
           try await providerConfigurationStore.generationToken() == providerGenerationToken() {
            return
        }
        try await registerClaims(now: now)
        let stale = existing.filter { !desired.contains($0) }
        var retiredProviders: Set<String> = []
        for key in stale {
            let otherClaimants = try await claims.claimants(key: key)
                .filter { $0 != Self.claimsConsumer }
            try await claims.releaseClaim(consumer: Self.claimsConsumer, key: key)
            if otherClaimants.isEmpty {
                let rows = try await storage.rowStore.query(
                    table: "vectors",
                    where: .and([
                        .eq(Column(table: "vectors", name: "model_id"), .text(key.modelID)),
                        .eq(Column(table: "vectors", name: "vector_index"), .int(Int64(key.vectorIndex)))
                    ]),
                    orderBy: [], limit: nil, offset: nil)
                let exact = rows.compactMap { row -> VectorExactKey? in
                    guard case let .text(version)? = row["model_version"], version == key.modelVersion,
                          case let .text(itemID)? = row["item_id"] else { return nil }
                    return VectorExactKey(
                        itemID: itemID, vectorIndex: key.vectorIndex, modelID: key.modelID)
                }
                try await vectorStore.deleteVectors(keys: exact)
            }
            retiredProviders.insert("\(key.modelID)\u{1F}\(key.modelVersion)")
        }

        let desiredModelIDs = Set(slots.map { $0.provider.modelID })
        for encoded in retiredProviders {
            let parts = encoded.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let modelID = parts[0]
            let modelVersion = parts[1]
            let providerPredicate: StoragePredicate = .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ])
            _ = try await storage.rowStore.delete(
                table: "corpus_provider_basis", where: providerPredicate)
            _ = try await storage.rowStore.delete(
                table: "corpus_provider_counts", where: .and([
                    .eq(Column(table: "corpus_provider_counts", name: "model_id"), .text(modelID)),
                    .eq(Column(table: "corpus_provider_counts", name: "model_version"), .text(modelVersion))
                ]))
            _ = try await storage.rowStore.delete(
                table: "corpus_provider_count_references", where: .and([
                    .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                        .text(modelID)),
                    .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                        .text(modelVersion))
                ]))
            if !desiredModelIDs.contains(modelID) {
                _ = try await storage.rowStore.delete(
                    table: "corpus_provider_coverage",
                    where: .eq(
                        Column(table: "corpus_provider_coverage", name: "model_id"),
                        .text(modelID)))
            }
        }

        _ = try await trainTrainableSlots(now: now)
        try await vectorStore.beginDeferredIndex()
        _ = try await backfillProviderCoverage(now: now)
        try await vectorStore.publishResidentIndex()
        // LAST durable write: equality makes future opens O(1). A crash
        // before here safely retries from per-provider coverage.
        try await providerConfigurationStore.markCurrent(
            providerGenerationToken(), now: now)
    }

    private func providerGenerationToken() -> String {
        configurationFingerprint() + "|" + slots.map {
            "\($0.provider.modelID)@\($0.provider.modelVersion)=\($0.basisDigest)"
        }.joined(separator: "|")
    }

    /// STANDALONE convenience: construct a whole-content standalone engine
    /// that OWNS its canonical documents (a `CorpusDocumentStore` over the
    /// same storage). The complete put→index→recall standalone surface in
    /// one constructor.
    public init(
        standaloneOn storage: any Storage,
        models: [EmbeddingModel] = [.default]
    ) async throws {
        try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
        try await self.init(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .standalone, indexUnit: .wholeContent),
            source: CorpusDocumentStore(storage: storage),
            models: models)
    }

#if CORPUSKIT_STANDALONE_PASSAGES
    /// STANDALONE SDK convenience with an explicit database-bound index-unit
    /// policy. Direct CorpusKit consumers enable the `StandalonePassages`
    /// package trait and select `.wholeContent` or a token window + overlap.
    /// This initializer is absent from GLK/MOOTx01 builds.
    public init(
        standaloneOn storage: any Storage,
        indexUnit: CorpusIndexUnitPolicy,
        models: [EmbeddingModel] = [.default]
    ) async throws {
        try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
        try await self.init(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .standalone, indexUnit: indexUnit),
            source: CorpusDocumentStore(storage: storage),
            models: models)
    }
#endif

    /// STANDALONE convenience: put canonical text and index it in one call.
    /// Attached mode rejects content mutation through CorpusKit
    /// (`attachedModeViolation`) — removal/authorship authority there is the
    /// GLK/LocusKit verb surface.
    public func ingest(_ text: String, contentID: CorpusContentID, now: Date) async throws {
        try await ingest(text, denseCompositionText: nil, contentID: contentID, now: now)
    }

    /// STANDALONE convenience with dual-text support: put canonical text
    /// plus an optional dense-composition text and index in one call.
    ///
    /// `denseCompositionText` is stored in the document store's `dense_text`
    /// column (NULL when nil) and carried in every subsequent
    /// `source.record(for:)` call so retrain and reindex paths can recompose
    /// the dense vector without external input (recomposability rule).
    ///
    /// BM25/lexical indexing always uses `text`; the dense float lane uses
    /// `denseCompositionText` when non-nil, falling back to `text` otherwise.
    public func ingest(
        _ text: String, denseCompositionText: String?,
        contentID: CorpusContentID, now: Date
    ) async throws {
        guard configuration.allowsContentMutation,
              let store = source as? CorpusDocumentStore else {
            throw CorpusKitError.attachedModeViolation(
                "content mutation through CorpusKit is standalone-only — attached "
                + "content changes flow through the canonical store's own verbs")
        }
        try validate(id: contentID)
        guard !text.isEmpty else { return }
        _ = try await store.put(text, denseCompositionText: denseCompositionText,
                                id: contentID, now: now)
        try await indexContent(id: contentID, now: now)
    }

    // MARK: - Content validation

    private func validate(id: CorpusContentID) throws {
        guard !id.isEmpty, !id.contains(IndexUnitIdentity.reservedSeparator) else {
            throw CorpusKitError.invalidConfiguration(
                "content IDs must be non-empty and must not contain the U+001F separator")
        }
    }

    // MARK: - Index one content row

    /// Index (or re-index) the CURRENT record for `id`, resolved from the
    /// source at work time. Returns true when live content was indexed,
    /// false when the ID no longer resolves (its derived state is cleared).
    @discardableResult
    public func indexContent(id: CorpusContentID, now: Date) async throws -> Bool {
        try validate(id: id)
        guard let record = try await source.record(for: id) else {
            try await clearDerivedState(id: id)
            return false
        }
        try await index(record: record, appliedCursor: nil, force: false, now: now)
        return true
    }

    /// STRUCTURAL index for the migration's rebuild phase: BM25 postings,
    /// checkpoint, and STATELESS-slot vectors + coverage only. Trainable
    /// slots are deferred to `trainTrainableSlots` + the coverage backfill
    /// so the rebuild never triggers training and never double-writes.
    @discardableResult
    public func indexContentStructural(id: CorpusContentID, now: Date) async throws -> Bool {
        try validate(id: id)
        guard let record = try await source.record(for: id) else {
            try await clearDerivedState(id: id)
            return false
        }
        try await index(
            record: record, appliedCursor: nil, force: false, now: now,
            slotScope: .statelessOnly)
        return true
    }

    /// Migration rebuild kernel: resolve a bounded batch, perform the pure
    /// tokenization/stateless-embedding work concurrently, then publish BM25,
    /// vectors, coverage, and checkpoints through the engine's serial writer.
    /// Results are reassembled in input order, and checkpoints advance only
    /// after every derived row for the batch is durable. This is the attached
    /// whole-content counterpart of `Corpus.ingestBatch`'s proven
    /// compute-parallel/write-serial pipeline; it does not alter provider math.
    @discardableResult
    public func indexContentStructuralBatch(
        ids: [CorpusContentID], now: Date, parallelism: Int? = nil
    ) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        guard configuration.mode == .attached,
              configuration.indexUnit == .wholeContent else {
            throw CorpusKitError.invalidConfiguration(
                "structural batch rebuild is available only to attached whole-content engines")
        }
        return try await indexWholeContentBatch(
            ids: ids, now: now, parallelism: parallelism,
            slotScope: .statelessOnly, force: false)
    }

    /// Shared whole-content compute-parallel/write-serial kernel. Migration
    /// selects only stateless slots without forcing existing checkpoints;
    /// full reindex selects every published slot and forces representation
    /// replacement after retraining. Passage replacement deliberately stays
    /// on the serial `prepareIndex` path because it also mutates range rows.
    private func indexWholeContentBatch(
        ids: [CorpusContentID], now: Date, parallelism: Int?,
        slotScope: SlotScope, force: Bool
    ) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        guard case .wholeContent = configuration.indexUnit else {
            throw CorpusKitError.invalidConfiguration(
                "whole-content batch indexing requires the wholeContent index unit")
        }
        try await registerClaims(now: now)

        var records: [CorpusContentRecord] = []
        records.reserveCapacity(ids.count)
        for id in ids {
            try validate(id: id)
            guard let record = try await source.record(for: id) else {
                try await clearDerivedState(id: id)
                continue
            }
            if !force,
               let existing = try await indexState.state(for: id),
               existing.revision == record.revision,
               existing.digest == record.digest,
               existing.indexVersion == Self.indexVersion {
                continue
            }
            records.append(record)
        }
        guard !records.isEmpty else { return 0 }

        // Delegate the bounded parallel embed phase to the shared kernel,
        // which also services the queue drain path.
        let cap = max(1, parallelism ?? ProcessInfo.processInfo.activeProcessorCount)
        let prepared = try await embedQueueRecords(records, slotScope: slotScope, cap: cap, now: now)

        for item in prepared {
            try await invertedIndex.index(itemID: item.record.id, tokens: item.tokens, now: now)
        }
        let vectorRows = prepared.flatMap(\.vectorRows)
        if !vectorRows.isEmpty { try await vectorStore.addPayloads(vectorRows) }
        try await coverageStore.markCovered(prepared.flatMap(\.covered), now: now)
        for item in prepared {
            try await indexState.advance(CorpusIndexState(
                contentID: item.record.id,
                revision: item.record.revision,
                digest: item.record.digest,
                indexVersion: Self.indexVersion,
                appliedCursor: nil,
                updatedAt: now))
            if force {
                // The former serial reindex path emitted this metric once per
                // completed record. Preserve that observability while moving
                // only the embedding preparation onto bounded workers.
                Intellectus.report(.metric(
                    name: "corpus.content.indexed", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
            }
        }
        return prepared.count
    }

    /// Immutable provider snapshot for one bounded parallel embed pass.
    /// Internal so the queue extension (CorpusContentEngineQueue.swift) can
    /// receive the return value of `embedQueueRecords`.
    struct StructuralProvider: Sendable {
        let provider: any EmbeddingProvider
        let modelID: String
        let modelVersion: String
        let basisDigest: String
        /// True for the default slot (index 0) and for all slots in standalone
        /// mode — only these slots write the binary (Hamming) vector lane.
        let writeBinary: Bool
    }

    /// Output of one bounded parallel embed worker — pure compute, no storage
    /// writes. Internal so CorpusContentEngineQueue.swift can consume it.
    struct PreparedStructuralRecord: Sendable {
        let record: CorpusContentRecord
        let tokens: [String]
        let vectorRows: [VectorPayloadInput]
        let covered: [(CorpusContentID, String, String)]
    }

    private func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], cap: Int,
        _ work: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(cap >= 1)
        var results = [Output?](repeating: nil, count: inputs.count)
        var start = 0
        while start < inputs.count {
            let end = min(start + cap, inputs.count)
            try await withThrowingTaskGroup(of: (Int, Output).self) { group in
                for index in start..<end {
                    let input = inputs[index]
                    group.addTask { (index, try await work(input)) }
                }
                for try await (index, output) in group { results[index] = output }
            }
            start = end
        }
        return results.map { $0! }
    }

    /// Embed `records` using bounded parallelism (≤ `cap` tasks active at once),
    /// returning one `PreparedStructuralRecord` per input record in the SAME
    /// ORDER as the input. No storage writes occur — this is pure compute: each
    /// worker calls `embedPair` for every active provider slot and accumulates
    /// keyword tokens.
    ///
    /// The provider snapshot is built once from the current actor state before
    /// any tasks are spawned, so there is no actor re-entry during the parallel
    /// phase. Callers are responsible for the subsequent serial storage writes
    /// (BM25, vectorStore.addPayloads, coverageStore.markCovered).
    ///
    /// `slotScope` follows the same semantics as `indexWholeContentBatch`:
    ///   - `.all`: embed across every active provider slot.
    ///   - `.statelessOnly`: skip trainable slots (migration / backfill path).
    func embedQueueRecords(
        _ records: [CorpusContentRecord],
        slotScope: SlotScope,
        cap: Int,
        now: Date
    ) async throws -> [PreparedStructuralRecord] {
        guard !records.isEmpty else { return [] }
        // Build an immutable provider snapshot from current actor state once,
        // so the parallel tasks never re-enter the actor for slot reads.
        let providers = slots.enumerated().compactMap { index, slot -> StructuralProvider? in
            if slotScope == .statelessOnly, slot.freshBasisBlob != nil { return nil }
            // A trainable slot with no trained basis cannot embed yet.
            if slot.freshBasisBlob != nil, slot.basisDigest == Self.untrainedDigest { return nil }
            return StructuralProvider(
                provider: slot.provider,
                modelID: slot.provider.modelID,
                modelVersion: slot.provider.modelVersion,
                basisDigest: slot.basisDigest,
                writeBinary: index == 0 || configuration.mode == .standalone)
        }
        // No active providers: return skeleton records (BM25 will still run).
        guard !providers.isEmpty else {
            return records.map { record in
                PreparedStructuralRecord(
                    record: record,
                    tokens: CorpusDefaultTokenizer().keywordTokens(record.text),
                    vectorRows: [],
                    covered: [])
            }
        }
        return try await boundedConcurrentMap(records, cap: cap) { record in
            var rows: [VectorPayloadInput] = []
            rows.reserveCapacity(providers.count * 2)
            var covered: [(CorpusContentID, String, String)] = []
            covered.reserveCapacity(providers.count)
            // Dense lane uses effectiveDenseText (denseCompositionText when set,
            // text otherwise). BM25 tokens always use the lexical text.
            let denseText = record.effectiveDenseText
            for target in providers {
                let (engram, floats) = try await target.provider.embedPair(denseText)
                if target.writeBinary {
                    rows.append(VectorPayloadInput(
                        itemID: record.id, vectorIndex: 0,
                        payload: VectorPayload(engram: engram),
                        modelID: target.modelID, modelVersion: target.modelVersion,
                        filedAt: now))
                }
                if !floats.isEmpty {
                    rows.append(VectorPayloadInput(
                        itemID: record.id, vectorIndex: 1,
                        payload: VectorPayload(floats: floats),
                        modelID: target.modelID, modelVersion: target.modelVersion,
                        filedAt: now))
                }
                covered.append((record.id, target.modelID, target.basisDigest))
            }
            return PreparedStructuralRecord(
                record: record,
                // BM25 keyword tokens: always lexical text, never dense text.
                tokens: CorpusDefaultTokenizer().keywordTokens(record.text),
                vectorRows: rows,
                covered: covered)
        }
    }

    // MARK: - Parallel queue drain kernel

    /// Assembled output of `drainIndexBatch`: everything the queue extension
    /// needs to call `commitQueueBatch` and `queue.reply`. Declared here (not
    /// in the queue extension file) so it can access the engine's private stores.
    struct DrainIndexBatchResult {
        var completions: [(jobID: JobID, status: ObservationStatus)]
        var checkpoints: [CorpusIndexState]
        var countsUpdates: [(contentID: String, revision: Int64, digest: String, text: String)]
        var encodedIDs: [String]
        let batchNow: Date
    }

    /// The indexing kernel for `drainContentQueueOnce`. Takes the raw job array
    /// from `queue.drain` and returns the assembled batch result; the queue
    /// extension handles `commitQueueBatch` and `queue.reply` after this returns.
    ///
    /// Four-phase pipeline:
    ///   Phase 0 — once-per-batch: countsReload guard, batchTrainIfNeeded (three-
    ///             state Kinsta-fix), registerClaims (Cause 1+2 fixes).
    ///   Phase 1 — serial per-job: decode, validate, record fetch, idempotence
    ///             check; remove jobs handled here entirely.
    ///   Phase 2 — bounded parallel embed (≤ activeProcessorCount tasks):
    ///             embedQueueRecords over pending upserts (Cause 1 fix).
    ///   Phase 3 — serial storage writes: BM25, one vectorStore.addPayloads,
    ///             one coverageStore.markCovered for the whole batch (Cause 5 fix).
    ///
    /// The contract is unchanged from the previous serial path: same indexed
    /// outputs, same idempotence guarantees, same AT-LEAST-ONCE delivery, same
    /// cursor-checkpoint semantics. Only the execution schedule differs.
    func drainIndexBatch(_ jobs: [Job]) async throws -> DrainIndexBatchResult {
        // Phase 0: once-per-batch housekeeping — hoisted out of the per-job loop.
        // countsReloadRequired is set on a failed commitQueueBatch; heal before
        // any new fold.
        if countsReloadRequired {
            try await reloadCountsFromStorage()
            countsReloadRequired = false
        }
        // batchTrainIfNeeded: three-state auto-train (Kinsta-fix). Fires:
        //   (1) first ingest — no persisted basis;
        //   (2) growth retrain — young basis, corpus ≥ 2× trainedChunkCount;
        //   (3) fold-in — stable basis, no retrain.
        // Called once per batch (not per job); decisions are serialized here
        // before the Phase 2 parallel embed fan-out.
        let batchNow = Date()
        try await batchTrainIfNeeded(now: batchNow)
        // registerClaims: idempotent — upserts claims only when absent; calling
        // once per batch eliminates N×slots unconditional upserts (Cause 2 fix).
        try await registerClaims(now: batchNow)

        // Phase 1: serial per-job decode, record resolution, and idempotence gate.
        // Source reads and the indexed-state store must be serialized on the actor.
        var result = DrainIndexBatchResult(
            completions: [], checkpoints: [], countsUpdates: [],
            encodedIDs: [], batchNow: batchNow)
        result.completions.reserveCapacity(jobs.count)
        var preparedUpserts: Set<String> = []

        // Pre-scan Phase 1 upsert jobs to batch-fetch all source records in one
        // WHERE…IN call instead of N serial record(for:) calls (Cause 4 fix).
        // Over-fetching is harmless — stale/deduped jobs just leave entries unused.
        var upsertContentIDs: [CorpusContentID] = []
        var seenUpsertIDs = Set<CorpusContentID>()
        for job in jobs {
            if let payload = try? JSONDecoder().decode(ContentIndexJob.self, from: job.payload),
               payload.kind == .upsert,
               seenUpsertIDs.insert(payload.contentID).inserted
            {
                upsertContentIDs.append(payload.contentID)
            }
        }
        let sourceRecords = try await source.records(for: upsertContentIDs)

        // Upsert records validated in Phase 1, queued for Phase 2 parallel embed.
        struct PendingEmbedWork: Sendable {
            let record: CorpusContentRecord
            let workNow: Date
            let cursor: String?
            let jobID: JobID
            let upsertKey: String
        }
        var pendingWork: [PendingEmbedWork] = []

        for job in jobs {
            guard let payload = try? JSONDecoder().decode(
                ContentIndexJob.self, from: job.payload)
            else {
                contentEngineLog.error("content job decode failed; replying blocked")
                result.completions.append((job.id, .blocked))
                continue
            }
            // The work instant: the job's submission HLC physical time (the capture
            // instant) — deterministic, no Date() in the per-job path.
            let workNow = Date(timeIntervalSince1970:
                Double(job.submittedAt.physicalTime) / 1000.0)

            switch payload.kind {
            case .remove:
                // Remove: cancel any pending upsert for the same content (queue
                // order preserved — a later remove supersedes an earlier upsert),
                // then clear derived state serially on the actor.
                for work in pendingWork where work.record.id == payload.contentID {
                    result.completions.append((work.jobID, .done))
                }
                pendingWork.removeAll { $0.record.id == payload.contentID }
                result.checkpoints.removeAll { $0.contentID == payload.contentID }
                result.countsUpdates.removeAll { $0.contentID == payload.contentID }
                let upsertPrefix = "\(payload.contentID)\u{1F}"
                preparedUpserts = preparedUpserts.filter { !$0.hasPrefix(upsertPrefix) }
                do {
                    try _ingestFailureHook?(payload.contentID)
                    try await clearDerivedState(id: payload.contentID)
                    if let cursor = payload.cursor {
                        result.checkpoints.append(CorpusIndexState(
                            contentID: Self.feedCursorRowID, revision: 0, digest: "",
                            indexVersion: Self.indexVersion, appliedCursor: cursor,
                            updatedAt: workNow))
                    }
                    result.completions.append((job.id, .done))
                } catch {
                    contentEngineLog.error("content remove failed for \(payload.contentID, privacy: .public): \(error, privacy: .public)")
                    result.completions.append((job.id, .blocked))
                }

            case .upsert:
                guard let digest = payload.digest else {
                    result.completions.append((job.id, .blocked))
                    continue
                }
                // Test seam: a non-nil hook simulates a transient failure. The
                // parallel drain does not retry in-loop — AT-LEAST-ONCE delivery
                // re-queues the job on the next drain pass.
                do {
                    try _ingestFailureHook?(payload.contentID)
                } catch {
                    contentEngineLog.error("content index hook failure for \(payload.contentID, privacy: .public): \(error, privacy: .public)")
                    result.completions.append((job.id, .blocked))
                    continue
                }

                // Within-batch deduplication: a (id, revision, digest) already
                // prepared in this drain pass is a no-op.
                let upsertKey =
                    "\(payload.contentID)\u{1F}\(payload.revision)\u{1F}\(digest)"
                if preparedUpserts.contains(upsertKey) {
                    result.encodedIDs.append(payload.contentID)
                    if let cursor = payload.cursor {
                        result.checkpoints.append(CorpusIndexState(
                            contentID: Self.feedCursorRowID, revision: 0, digest: "",
                            indexVersion: Self.indexVersion, appliedCursor: cursor,
                            updatedAt: workNow))
                    }
                    result.completions.append((job.id, .done))
                    continue
                }

                // Resolve the current content record from the pre-fetched batch.
                // A nil hit means the ID is no longer live in the source — stale job.
                guard let record = sourceRecords[payload.contentID] else {
                    contentEngineLog.info("content job for \(payload.contentID, privacy: .public) rev \(payload.revision, privacy: .public) stale — ID gone")
                    result.completions.append((job.id, .done))
                    continue
                }
                guard record.revision == payload.revision, record.digest == digest else {
                    contentEngineLog.info("content job for \(payload.contentID, privacy: .public) rev \(payload.revision, privacy: .public) stale — superseded")
                    result.completions.append((job.id, .done))
                    continue
                }

                // Durable idempotence: skip records whose checkpoint already covers
                // this exact (revision, digest, indexVersion). The checkpoint is
                // advanced LAST, so a complete checkpoint proves all derived rows
                // are complete — replay is truly a no-op.
                if let existing = try await indexState.state(for: record.id),
                   existing.revision == record.revision,
                   existing.digest == record.digest,
                   existing.indexVersion == Self.indexVersion
                {
                    preparedUpserts.insert(upsertKey)
                    result.encodedIDs.append(payload.contentID)
                    if let cursor = payload.cursor {
                        result.checkpoints.append(CorpusIndexState(
                            contentID: Self.feedCursorRowID, revision: 0, digest: "",
                            indexVersion: Self.indexVersion, appliedCursor: cursor,
                            updatedAt: workNow))
                    }
                    result.completions.append((job.id, .done))
                    continue
                }

                // Record passed all gates — enqueue for bounded parallel embedding.
                pendingWork.append(PendingEmbedWork(
                    record: record, workNow: workNow, cursor: payload.cursor,
                    jobID: job.id, upsertKey: upsertKey))
            }
        }

        // Phase 2: bounded parallel embed — pure compute, no storage writes.
        // embedQueueRecords builds an immutable provider snapshot, then spawns
        // up to activeProcessorCount tasks; results arrive in input order.
        guard !pendingWork.isEmpty else { return result }
        let cap = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let embedded = try await embedQueueRecords(
            pendingWork.map(\.record), slotScope: .all, cap: cap, now: batchNow)

        // Phase 3: serial storage writes for the embedded batch.
        // BM25 — one index call per record.
        for (work, item) in zip(pendingWork, embedded) {
            try await invertedIndex.index(
                itemID: item.record.id, tokens: item.tokens, now: work.workNow)
        }
        // Vector rows — ONE addPayloads call for the entire batch (Cause 5 fix).
        let allVectorRows = embedded.flatMap(\.vectorRows)
        if !allVectorRows.isEmpty {
            try await vectorStore.addPayloads(allVectorRows)
        }
        // Coverage — ONE markCovered call for the entire batch (Cause 5 fix).
        try await coverageStore.markCovered(embedded.flatMap(\.covered), now: batchNow)

        // Assemble checkpoints and countsUpdates for the embedded records.
        for (work, item) in zip(pendingWork, embedded) {
            result.checkpoints.append(CorpusIndexState(
                contentID: item.record.id, revision: item.record.revision,
                digest: item.record.digest, indexVersion: Self.indexVersion,
                appliedCursor: work.cursor, updatedAt: work.workNow))
            if let cursor = work.cursor {
                result.checkpoints.append(CorpusIndexState(
                    contentID: Self.feedCursorRowID, revision: 0, digest: "",
                    indexVersion: Self.indexVersion, appliedCursor: cursor,
                    updatedAt: work.workNow))
            }
            result.countsUpdates.append((
                contentID: item.record.id, revision: item.record.revision,
                digest: item.record.digest, text: item.record.text))
            preparedUpserts.insert(work.upsertKey)
            result.encodedIDs.append(item.record.id)
            result.completions.append((work.jobID, .done))
            Intellectus.report(.metric(
                name: "corpus.content.indexed", value: 1.0,
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
        }
        return result
    }

    /// Test seam for the backfill crash-boundary suites: phase marker the
    /// hook receives per batch.
    public enum BackfillFaultPhase: Sendable { case afterVectors, afterCoverage }
    var _backfillFaultHook: (@Sendable (BackfillFaultPhase, Int) throws -> Void)?
    public func _armBackfillFaultHook(
        _ hook: (@Sendable (BackfillFaultPhase, Int) throws -> Void)?
    ) {
        _backfillFaultHook = hook
    }

    /// Backfill MISSING provider representations (trainable AND stateless
    /// slots alike — an upgrade can add either), driven by the coverage
    /// table — writes ONLY what is absent under each slot's CURRENT basis
    /// digest:
    ///   - resolves each missing Drawer's record once and embeds only the
    ///     slots whose (content, model) coverage is absent or carries a
    ///     stale digest;
    ///   - never touches BM25, never folds counts, never rewrites covered
    ///     providers' rows;
    ///   - per batch: vector rows first, coverage rows second — a crash
    ///     leaves coverage lagging the durable vectors (replay embeds the
    ///     lagging tail idempotently), never ahead of them.
    ///
    /// Callers stream large backfills inside a VectorStore deferred-index
    /// window. Returns the number of (content, provider) pairs covered.
    @discardableResult
    public func backfillProviderCoverage(
        now: Date, batchSize: Int = 500, parallelism: Int? = nil
    ) async throws -> Int {
        // Every slot with a live generation (stateless digests are
        // constants; an untrained trainable slot has no generation yet).
        let targets: [(index: Int, modelID: String, digest: String)] =
            slots.enumerated().compactMap { index, slot in
                guard slot.basisDigest != Self.untrainedDigest else { return nil }
                return (index, slot.provider.modelID, slot.basisDigest)
            }
        guard !targets.isEmpty else { return 0 }
        guard case .wholeContent = configuration.indexUnit else {
            throw CorpusKitError.invalidConfiguration(
                "backfillTrainableCoverage supports the wholeContent index unit "
                + "(the mandatory attached policy); passage engines reindex instead")
        }
        try await registerClaims(now: now)

        // Missing set per slot from the durable coverage rows (the resume
        // authority — a stale-digest row is missing by definition).
        var missingBySlot: [Int: Set<CorpusContentID>] = [:]
        let indexed = Set(try await indexedContentIDs())
        for target in targets {
            let covered = try await coverageStore.coveredContentIDs(
                modelID: target.modelID, basisDigest: target.digest)
            missingBySlot[target.index] = indexed.subtracting(covered)
        }
        let affected = missingBySlot.values.reduce(into: Set<CorpusContentID>()) {
            $0.formUnion($1)
        }
        var written = 0
        var batchIndex = 0
        let cap = max(1, parallelism ?? ProcessInfo.processInfo.activeProcessorCount)
        let computeTargets = targets.map { target in
            StructuralProvider(
                provider: slots[target.index].provider,
                modelID: target.modelID,
                modelVersion: slots[target.index].provider.modelVersion,
                basisDigest: target.digest,
                writeBinary: target.index == 0 || configuration.mode == .standalone)
        }
        let targetSlotIndices = targets.map(\.index)
        let missingSnapshot = missingBySlot
        for chunk in affected.sorted().chunked(into: batchSize) {
            var records: [CorpusContentRecord] = []
            records.reserveCapacity(chunk.count)
            for id in chunk {
                if let record = try await source.record(for: id) { records.append(record) }
            }
            let prepared = try await boundedConcurrentMap(records, cap: cap) { record in
                var rows: [VectorPayloadInput] = []
                var covered: [(CorpusContentID, String, String)] = []
                // Backfill uses the same dense-composition text as initial
                // indexing — recomposability rule: same input, same vector.
                let denseText = record.effectiveDenseText
                for (targetIndex, target) in computeTargets.enumerated()
                    where missingSnapshot[targetSlotIndices[targetIndex]]?.contains(record.id) == true
                {
                    let (engram, floats) = try await target.provider.embedPair(denseText)
                    if target.writeBinary {
                        rows.append(VectorPayloadInput(
                            itemID: record.id, vectorIndex: 0,
                            payload: VectorPayload(engram: engram),
                            modelID: target.modelID, modelVersion: target.modelVersion,
                            filedAt: now))
                    }
                    if !floats.isEmpty {
                        rows.append(VectorPayloadInput(
                            itemID: record.id, vectorIndex: 1,
                            payload: VectorPayload(floats: floats),
                            modelID: target.modelID, modelVersion: target.modelVersion,
                            filedAt: now))
                    }
                    covered.append((record.id, target.modelID, target.basisDigest))
                }
                return (rows, covered)
            }
            let rows = prepared.flatMap(\.0)
            let covered = prepared.flatMap(\.1)
            if !rows.isEmpty {
                try await vectorStore.addPayloads(rows)
            }
            try _backfillFaultHook?(.afterVectors, batchIndex)
            try await coverageStore.markCovered(covered, now: now)
            try _backfillFaultHook?(.afterCoverage, batchIndex)
            written += covered.count
            batchIndex += 1
        }
        return written
    }

    /// Coverage count for one held slot's model under its CURRENT basis
    /// digest — the verification-gate read.
    public func coveredCount(modelID: String) async throws -> Int? {
        guard let slot = slots.first(where: { $0.provider.modelID == modelID })
        else { return nil }
        return try await coverageStore.coveredCount(
            modelID: modelID, basisDigest: slot.basisDigest)
    }

    /// Every held slot's (modelID, basisDigest) in slot order — the
    /// provider-generation surface the migration records and verifies.
    public func providerGenerations() -> [(modelID: String, basisDigest: String)] {
        slots.map { ($0.provider.modelID, $0.basisDigest) }
    }

    /// The ensemble/configuration fingerprint: mode, index version, and
    /// every slot's identity+trainability in slot order. A migrated
    /// estate records this; wiring a DIFFERENT configuration over a
    /// completed record is detected as an upgrade, never trusted as
    /// complete. Deliberately excludes basis digests (retraining the same
    /// configuration is not a configuration change).
    public nonisolated static func configurationFingerprint(
        mode: CorpusOperatingMode, models: [EmbeddingModel]
    ) -> String {
        let parts = models.map { model -> String in
            let provider = model.makeProvider()
            return "\(provider.modelID)@\(provider.modelVersion)\(model.isTrainable ? ":T" : "")"
        }
        return "iv\(Self.indexVersion)|\(mode == .attached ? "attached" : "standalone")|"
            + parts.joined(separator: "|")
    }

    /// This engine's own configuration fingerprint.
    public func configurationFingerprint() -> String {
        let parts = slots.map { slot -> String in
            "\(slot.provider.modelID)@\(slot.provider.modelVersion)\(slot.freshBasisBlob != nil ? ":T" : "")"
        }
        return "iv\(Self.indexVersion)|\(configuration.mode == .attached ? "attached" : "standalone")|"
            + parts.joined(separator: "|")
    }

    /// Apply one change (typically drained from a queue job). The stale
    /// gate: an upsert whose (revision, digest) mismatches the CURRENT
    /// record throws `staleRevision` and advances NOTHING.
    public func applyChange(
        _ change: CorpusContentChange, cursor: String?, now: Date
    ) async throws {
        try validate(id: change.id)
        switch change {
        case .upsert(let id, let revision, let digest):
            guard let record = try await source.record(for: id) else {
                throw CorpusKitError.staleRevision(
                    "upsert for \(id) rev \(revision): the ID no longer resolves — "
                    + "the remove change will clear it")
            }
            guard record.revision == revision, record.digest == digest else {
                Intellectus.report(.metric(
                    name: "corpus.content.stale_rejected", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                throw CorpusKitError.staleRevision(
                    "upsert for \(id) rev \(revision) does not match the current "
                    + "record rev \(record.revision) — stale job rejected without checkpoint advance")
            }
            try await index(record: record, appliedCursor: cursor, force: false, now: now)
        case .remove(let id, _):
            try await clearDerivedState(id: id)
            Intellectus.report(.metric(
                name: "corpus.content.removed", value: 1.0,
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
        }
        if let cursor {
            try await advanceFeedCursor(cursor, now: now)
        }
    }

    /// Process one queue job payload — the drain-worker entry point.
    public func processJob(_ job: ContentIndexJob, now: Date) async throws {
        switch job.kind {
        case .upsert:
            guard let digest = job.digest else {
                throw CorpusKitError.invalidConfiguration(
                    "upsert job for \(job.contentID) carries no digest")
            }
            try await applyChange(
                .upsert(id: job.contentID, revision: job.revision, digest: digest),
                cursor: job.cursor, now: now)
        case .remove:
            try await applyChange(
                .remove(id: job.contentID, revision: job.revision),
                cursor: job.cursor, now: now)
        }
    }

    /// Queue-only preparation seam. Derived rows and provider coverage are
    /// written in their normal order, while final content/cursor checkpoints
    /// are returned for an atomic batch commit with maintained counts.
    func prepareQueueJob(
        _ job: ContentIndexJob, now: Date, contentAlreadyPrepared: Bool
    ) async throws -> (
        checkpoints: [CorpusIndexState],
        countsUpdate: (
            contentID: String, revision: Int64, digest: String, text: String
        )?
    ) {
        if countsReloadRequired {
            try await reloadCountsFromStorage()
            countsReloadRequired = false
        }
        try validate(id: job.contentID)
        var checkpoints: [CorpusIndexState] = []
        var countsUpdate: (
            contentID: String, revision: Int64, digest: String, text: String
        )?
        switch job.kind {
        case .upsert:
            guard let digest = job.digest else {
                throw CorpusKitError.invalidConfiguration(
                    "upsert job for \(job.contentID) carries no digest")
            }
            guard let record = try await source.record(for: job.contentID) else {
                throw CorpusKitError.staleRevision(
                    "upsert for \(job.contentID) rev \(job.revision): the ID no longer resolves — "
                    + "the remove change will clear it")
            }
            guard record.revision == job.revision, record.digest == digest else {
                throw CorpusKitError.staleRevision(
                    "upsert for \(job.contentID) rev \(job.revision) does not match the current "
                    + "record rev \(record.revision) — stale job rejected without checkpoint advance")
            }
            if !contentAlreadyPrepared,
               let checkpoint = try await prepareIndex(
                record: record, appliedCursor: job.cursor, force: false, now: now,
                slotScope: .all)
            {
                checkpoints.append(checkpoint)
                // Every newly prepared revision reaches the durable-reference
                // admission authority at batch close. That authority decides
                // whether this is a new identity, an idempotent replay, or a
                // changed digest whose novel vocabulary must advance the
                // governor anchor without incrementing the document anchor.
                countsUpdate = (record.id, record.revision, record.digest, record.text)
            }
        case .remove:
            try await clearDerivedState(id: job.contentID)
        }
        if let cursor = job.cursor {
            checkpoints.append(CorpusIndexState(
                contentID: Self.feedCursorRowID, revision: 0, digest: "",
                indexVersion: Self.indexVersion, appliedCursor: cursor, updatedAt: now))
        }
        return (checkpoints, countsUpdate)
    }

    /// Last-write transaction for a durable queue batch. A crash can observe
    /// either the old counts/checkpoints (and replay the durable references) or
    /// the new pair, never a checkpoint that outruns its maintained counts.
    func commitQueueBatch(
        checkpoints: [CorpusIndexState],
        countsUpdates: [(
            contentID: String, revision: Int64, digest: String, text: String
        )],
        now: Date
    ) async throws {
        await acquireCountsAdmission()
        defer { releaseCountsAdmission() }
        // A prior failed commit whose reload ALSO failed leaves the in-memory
        // accumulator dirty; heal from storage before any new fold.
        if countsReloadRequired {
            try await reloadCountsFromStorage()
            countsReloadRequired = false
        }
        var references: [PersistedCountsReference] = []
        var consumedSubsumedReferences: [(modelID: String, modelVersion: String, contentID: String)] = []
        // countsDocument false = revision of an already-admitted identity.
        // The published provider counts stay frozen. Only the identity's
        // compact set of genuinely novel term hashes advances, so obsolete
        // revisions cannot accumulate differently before and after reopen.
        var growthUpdates: [(
            slotIndex: Int, termDigests: Set<String>, countsDocument: Bool
        )] = []
        if !countsUpdates.isEmpty {
            // Deduplicate content IDs once before the slot loop so the batch
            // query (one per slot) fetches exactly the set we need.
            var seenIDs = Set<String>()
            let uniqueContentIDs = countsUpdates.compactMap { update -> String? in
                seenIDs.insert(update.contentID).inserted ? update.contentID : nil
            }
            for index in slots.indices {
                guard slots[index].countsAccumulator != nil else { continue }
                let modelID = slots[index].provider.modelID
                let modelVersion = slots[index].provider.modelVersion
                // Batch-fetch all references for this slot in one WHERE…IN query
                // instead of N individual referenceFor calls. Semantics identical:
                // the resulting dictionary is nil-for-absent, matching the old path.
                let existingRefs = try await countsStore.referencesFor(
                    modelID: modelID, modelVersion: modelVersion,
                    contentIDs: uniqueContentIDs)
                var admittedIDs: Set<String> = []
                for update in countsUpdates {
                    guard admittedIDs.insert(update.contentID).inserted else { continue }
                    let countsDocument: Bool
                    var termDigests: Set<String> = []
                    if let existing = existingRefs[update.contentID] {
                        if existing.digest == update.digest {
                            if existing.isSubsumed {
                                consumedSubsumedReferences.append(
                                    (modelID, modelVersion, update.contentID))
                            }
                            continue
                        }
                        countsDocument = false
                        termDigests.formUnion(existing.growthTermDigests)
                    } else {
                        // A prior checkpoint proves this canonical identity
                        // was already represented by the published base.
                        // Revisions add vocabulary but never another document.
                        countsDocument = try await indexState.state(
                            for: update.contentID) == nil
                    }
                    if let accumulator = slots[index].countsAccumulator {
                        for term in defaultKeywordTokens(update.text)
                            where !accumulator.countsContainsTerm(term)
                        {
                            termDigests.insert(CorpusContentDigest.digest(Data(term.utf8)))
                        }
                    }
                    references.append(PersistedCountsReference(
                        modelID: modelID,
                        modelVersion: modelVersion,
                        contentID: update.contentID,
                        revision: update.revision,
                        digest: update.digest,
                        updatedAt: now,
                        growthTermDigests: Array(termDigests)))
                    growthUpdates.append((index, termDigests, countsDocument))
                }
            }
        }

        // Advance the compact growth sets BEFORE the durable commit: anchors
        // written in the transaction reflect the exact same identity-scoped
        // contributions a reopened process loads from the reference rows.
        var touchedSlots: Set<Int> = []
        for update in growthUpdates {
            slots[update.slotIndex].growthTermDigests.formUnion(update.termDigests)
            if update.countsDocument {
                slots[update.slotIndex].countsDocumentCount += 1
            }
            let publishedVocabulary =
                slots[update.slotIndex].countsAccumulator?.countsVocabularySize ?? 0
            slots[update.slotIndex].countsVocabAnchor = max(
                slots[update.slotIndex].countsVocabAnchor,
                publishedVocabulary + slots[update.slotIndex].growthTermDigests.count)
            touchedSlots.insert(update.slotIndex)
        }
        var anchorRows: [(modelID: String, modelVersion: String, docs: Int, vocab: Int)] = []
        for index in touchedSlots.sorted() {
            anchorRows.append((
                slots[index].provider.modelID,
                slots[index].provider.modelVersion,
                slots[index].countsDocumentCount,
                slots[index].countsVocabAnchor))
        }

        let pendingReferences = references
        let pendingSubsumedDeletes = consumedSubsumedReferences
        let pendingAnchors = anchorRows
        let countsStore = self.countsStore
        let indexState = self.indexState
        do {
            try await storage.transaction(isolation: .serializable) { txn in
                for row in pendingSubsumedDeletes {
                    try await countsStore.deleteReference(
                        modelID: row.modelID, modelVersion: row.modelVersion,
                        contentID: row.contentID, into: txn.rowStore)
                }
                for row in pendingReferences {
                    try await countsStore.upsertReference(row, into: txn.rowStore)
                }
                for anchors in pendingAnchors {
                    _ = try await countsStore.updateAnchors(
                        modelID: anchors.modelID, modelVersion: anchors.modelVersion,
                        documentCount: anchors.docs, vocabSize: anchors.vocab,
                        into: txn.rowStore)
                }
                for checkpoint in checkpoints {
                    try await indexState.advance(checkpoint, into: txn.rowStore)
                }
            }
        } catch {
            // Treat the storage transaction as authoritative even when the
            // backend reports an ambiguous commit failure. Rehydrate before
            // another durable reference can be attempted so replay cannot
            // double-fold the in-memory counts.
            countsReloadRequired = true
            do {
                try await reloadCountsFromStorage()
                countsReloadRequired = false
            } catch let reloadError {
                throw CorpusKitError.storeUnavailable(
                    "queue counts/checkpoint transaction failed: \(error); "
                    + "durable counts reload failed: \(reloadError)")
            }
            throw error
        }
    }

    private func reloadCountsFromStorage() async throws {
        for index in slots.indices {
            guard let blob = slots[index].freshBasisBlob,
                  let witness = slots[index].countsAccumulator,
                  let accumulator = try witness.reconstructBasis(from: blob)
                    as? any TrainableEmbeddingBasis
            else { continue }
            let persisted = try await countsStore.load(
                modelID: slots[index].provider.modelID,
                modelVersion: slots[index].provider.modelVersion)
            if let persisted {
                try accumulator.restoreCounts(from: persisted.counts)
                slots[index].countsDocumentCount = persisted.documentCount
            } else {
                slots[index].countsDocumentCount = 0
            }
            var growthTerms: Set<String> = []
            for reference in try await countsStore.references(
                modelID: slots[index].provider.modelID,
                modelVersion: slots[index].provider.modelVersion)
            {
                // Training-snapshot markers are already represented by the
                // persisted base. They exist only to make a delayed admission
                // consume that fact instead of folding the content twice.
                if reference.isSubsumed { continue }
                growthTerms.formUnion(reference.growthTermDigests)
            }
            slots[index].countsAccumulator = accumulator
            slots[index].growthTermDigests = growthTerms
            // The STORED anchors are the authority, committed with the same
            // reference bytes that reconstruct `growthTermDigests`.
            if let persisted {
                slots[index].countsDocumentCount = persisted.documentCount
                slots[index].countsVocabAnchor = persisted.vocabSize
            } else {
                slots[index].countsVocabAnchor =
                    accumulator.countsVocabularySize
            }
        }
    }

    /// Which slots an indexing pass embeds. `.all` is the ordinary path;
    /// `.statelessOnly` is the migration's structural rebuild — BM25 +
    /// checkpoints + stateless-slot vectors, with trainable slots deferred
    /// to the train + backfill phases.
    enum SlotScope: Sendable { case all, statelessOnly }

    private func index(
        record: CorpusContentRecord, appliedCursor: String?, force: Bool, now: Date,
        slotScope: SlotScope = .all
    ) async throws {
        if let checkpoint = try await prepareIndex(
            record: record, appliedCursor: appliedCursor, force: force, now: now,
            slotScope: slotScope
        ) {
            try await commitDirectIndex(record: record, checkpoint: checkpoint, now: now)
        }
    }

    /// Produce every derived row and return the final checkpoint without
    /// committing it. The durable queue uses this seam to publish maintained
    /// counts and all corresponding checkpoints atomically at batch close.
    private func prepareIndex(
        record: CorpusContentRecord, appliedCursor: String?, force: Bool, now: Date,
        slotScope: SlotScope
    ) async throws -> CorpusIndexState? {
        // Idempotence anchor: when the checkpoint already covers this exact
        // (revision, digest, indexVersion), the derived rows are complete
        // (the checkpoint is advanced LAST) — replaying the change writes
        // NOTHING, so replay changes no derived bytes. `force` (reindex
        // after a retrain) bypasses the short-circuit deliberately.
        if !force,
           let existing = try await indexState.state(for: record.id),
           existing.revision == record.revision,
           existing.digest == record.digest,
           existing.indexVersion == Self.indexVersion {
            return nil
        }
        try await registerClaims(now: now)
        if slotScope == .all {
            try await firstIngestTrainIfNeeded(now: now)
        }

        // Determine this record's index units.
        let units = try await replaceUnits(for: record, now: now)

        // BM25: replace the record's postings with the new units'.
        for unit in units {
            try await invertedIndex.index(
                itemID: unit.key,
                tokens: CorpusDefaultTokenizer().keywordTokens(unit.text),
                now: now)
        }

        // Vectors: exact-key scoped replace per model — delete the
        // record's PRIOR keys (previous units), then upsert fresh rows.
        // Attached mode writes the binary (Hamming) row for the DEFAULT
        // slot only: every GLK binary reader probes `corpus.modelID`
        // (slots[0]); non-default binary rows would be unreachable weight.
        // Standalone keeps per-slot binary lanes (its recall surface can
        // probe any slot).
        var rows: [VectorPayloadInput] = []
        var covered: [(contentID: CorpusContentID, modelID: String, basisDigest: String)] = []
        rows.reserveCapacity(units.count * slots.count * 2)
        for (slotIndex, slot) in slots.enumerated() {
            switch slotScope {
            case .all: break
            case .statelessOnly:
                if slot.freshBasisBlob != nil { continue }
            }
            // A trainable slot with no trained basis cannot embed; the
            // train + backfill phases cover it (never write vectors or
            // coverage under the untrained digest).
            if slot.freshBasisBlob != nil && slot.basisDigest == Self.untrainedDigest {
                continue
            }
            let writeBinary = slotIndex == 0 || configuration.mode == .standalone
            for unit in units {
                // Dense lane: use effectiveDenseText (denseText when set,
                // lexical text otherwise). BM25 tokenisation above always
                // uses unit.text (the lexical surface) — the two paths are
                // kept independent so a nil denseText is a true no-op.
                let (engram, floats) = try await slot.provider.embedPair(unit.effectiveDenseText)
                if writeBinary {
                    rows.append(VectorPayloadInput(
                        itemID: unit.key, vectorIndex: 0,
                        payload: VectorPayload(engram: engram),
                        modelID: slot.provider.modelID,
                        modelVersion: slot.provider.modelVersion,
                        filedAt: now))
                }
                if !floats.isEmpty {
                    rows.append(VectorPayloadInput(
                        itemID: unit.key, vectorIndex: 1,
                        payload: VectorPayload(floats: floats),
                        modelID: slot.provider.modelID,
                        modelVersion: slot.provider.modelVersion,
                        filedAt: now))
                }
            }
            covered.append((record.id, slot.provider.modelID, slot.basisDigest))
        }
        if !rows.isEmpty {
            try await vectorStore.addPayloads(rows)
        }
        // Coverage rows AFTER the vector rows are durable — coverage never
        // overstates the vectors table (and the checkpoint below never
        // overstates coverage).
        try await coverageStore.markCovered(covered, now: now)

        // The caller publishes this checkpoint LAST.
        let checkpoint = CorpusIndexState(
            contentID: record.id, revision: record.revision, digest: record.digest,
            indexVersion: Self.indexVersion, appliedCursor: appliedCursor, updatedAt: now)
        Intellectus.report(.metric(
            name: "corpus.content.indexed", value: 1.0,
            tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
        return checkpoint
    }

    /// One index unit: its derived-row key plus the two text surfaces.
    ///
    /// `text` is always the LEXICAL text — used for BM25 keyword tokenisation.
    /// `denseText` is the dense-composition text for the float vector lane; nil
    /// means fall back to `text` (default). Separating the two here keeps the
    /// BM25 / dense-embedding split explicit through every downstream code path
    /// that receives an `IndexUnit`.
    private struct IndexUnit {
        let key: String
        /// Lexical text — BM25 tokenisation only.
        let text: String
        /// Dense-composition text for vector embedding. nil → use `text`.
        let denseText: String?
        /// The text the engine passes to `embedPair`. Returns `denseText`
        /// when set, falls back to `text`.
        var effectiveDenseText: String { denseText ?? text }
    }

    /// Compute the record's index units under the configured policy,
    /// replacing durable passage rows and deleting STALE derived keys
    /// (prior units) by exact key. Returns the fresh units.
    private func replaceUnits(
        for record: CorpusContentRecord, now: Date
    ) async throws -> [IndexUnit] {
        // Prior unit keys (whole-content key + any recorded passages).
        var staleKeys = try await unitKeys(for: record.id)

        let units: [IndexUnit]
        switch configuration.indexUnit {
        case .wholeContent:
            // Whole-content unit: lexical text for BM25; dense-composition
            // text (when set) for vector embedding. The two paths stay
            // independent through replaceUnits and prepareIndex.
            units = [IndexUnit(
                key: record.id, text: record.text,
                denseText: record.denseCompositionText)]
#if CORPUSKIT_STANDALONE_PASSAGES
        case .tokenWindows(let window, let overlap):
            let ranges = PassageProduction.passageRanges(
                text: record.text, windowTokens: window, overlapTokens: overlap)
            let utf8 = Array(record.text.utf8)
            units = ranges.map { range in
                let key = PassageProduction.passageKey(
                    contentID: record.id, revision: record.revision,
                    utf8Start: range.utf8Start, utf8Length: range.utf8Length)
                let bytes = utf8[range.utf8Start..<(range.utf8Start + range.utf8Length)]
                // Passage text is a UTF-8 sub-span of the LEXICAL text.
                // Dense-composition text is whole-document; sub-span
                // splitting on it is not supported — passages embed the
                // lexical sub-span only (denseText: nil → falls back to text).
                return IndexUnit(key: key,
                                 text: String(decoding: bytes, as: UTF8.self),
                                 denseText: nil)
            }
            // Replace the durable passage-range rows for this content.
            _ = try await storage.rowStore.delete(
                table: "corpus_passages",
                where: .eq(Column(table: "corpus_passages", name: "content_id"),
                           .text(record.id)))
            for (unit, range) in zip(units, ranges) {
                _ = try await storage.rowStore.insert(table: "corpus_passages", values: [
                    "passage_id": .text(unit.key),
                    "content_id": .text(record.id),
                    "revision": .int(record.revision),
                    "digest": .text(record.digest),
                    "utf8_start": .int(Int64(range.utf8Start)),
                    "utf8_length": .int(Int64(range.utf8Length)),
                    "policy_fingerprint": .text(configuration.indexUnit.persistedFingerprint)
                ])
            }
#endif
        }

        // Anything previously derived that is NOT a fresh unit is stale.
        let freshKeys = Set(units.map(\.key))
        staleKeys.subtract(freshKeys)
        if !staleKeys.isEmpty {
            try await deleteDerivedRows(unitKeys: staleKeys)
        }
        return units
    }

    /// Every derived-row key currently attributable to `id`: the
    /// whole-content key plus any recorded passage keys.
    private func unitKeys(for id: CorpusContentID) async throws -> Set<String> {
        var keys: Set<String> = [id]
#if CORPUSKIT_STANDALONE_PASSAGES
        if case .tokenWindows = configuration.indexUnit {
            let rows = try await storage.rowStore.query(
                table: "corpus_passages",
                where: .eq(Column(table: "corpus_passages", name: "content_id"), .text(id)),
                orderBy: [], limit: nil, offset: nil)
            for row in rows {
                if case let .text(passageID)? = row["passage_id"] { keys.insert(passageID) }
            }
        }
#endif
        return keys
    }

    /// Delete the BM25 postings and vector rows for the given unit keys —
    /// exact-key scoped, never model-wide, and CLAIM-AWARE: a key whose
    /// (model, lane) representation family is also claimed by another
    /// retained consumer is NOT deleted — the row may serve that claimant's
    /// exact representation. The engine only removes what it exclusively
    /// owns; shared families outlive any single consumer's remove/destroy.
    private func deleteDerivedRows(unitKeys: Set<String>) async throws {
        let shared = try await sharedRepresentationFamilies()
        var vectorKeys: [VectorExactKey] = []
        for key in unitKeys.sorted() {
            try await invertedIndex.remove(itemID: key)
            for slot in slots {
                for lane: Int in [0, 1] {
                    if shared.contains("\(slot.provider.modelID)|\(lane)") { continue }
                    vectorKeys.append(VectorExactKey(
                        itemID: key, vectorIndex: lane,
                        modelID: slot.provider.modelID))
                }
            }
        }
        try await vectorStore.deleteVectors(keys: vectorKeys)
    }

    /// Representation families (modelID|lane) this engine's slots write
    /// that at least one OTHER consumer also claims. Rows in these
    /// families are never deleted by the engine's remove/destroy paths.
    private func sharedRepresentationFamilies() async throws -> Set<String> {
        var shared: Set<String> = []
        for slot in slots {
            for lane: Int in [0, 1] {
                let claimants = try await claims.claimants(
                    key: VectorRepresentationKey(
                        modelID: slot.provider.modelID,
                        modelVersion: slot.provider.modelVersion,
                        vectorIndex: lane))
                if claimants.contains(where: { $0 != Self.claimsConsumer }) {
                    shared.insert("\(slot.provider.modelID)|\(lane)")
                }
            }
        }
        return shared
    }

    /// Clear EVERYTHING derived for `id` (the remove path): BM25, vectors,
    /// passage rows, and the checkpoint.
    private func clearDerivedState(id: CorpusContentID) async throws {
        let keys = try await unitKeys(for: id)
        try await deleteDerivedRows(unitKeys: keys)
        try await coverageStore.clear(contentID: id)
#if CORPUSKIT_STANDALONE_PASSAGES
        if case .tokenWindows = configuration.indexUnit {
            _ = try await storage.rowStore.delete(
                table: "corpus_passages",
                where: .eq(Column(table: "corpus_passages", name: "content_id"), .text(id)))
        }
#endif
        try await indexState.clear(contentID: id)
    }

    private func advanceFeedCursor(_ cursor: String, now: Date) async throws {
        try await indexState.advance(CorpusIndexState(
            contentID: Self.feedCursorRowID, revision: 0, digest: "",
            indexVersion: Self.indexVersion, appliedCursor: cursor, updatedAt: now))
    }

    /// The last applied feed cursor, or nil when no feed change has been
    /// applied yet.
    public func appliedFeedCursor() async throws -> String? {
        try await indexState.state(for: Self.feedCursorRowID)?.appliedCursor
    }

    /// Content IDs with a live checkpoint — the reconciliation set
    /// verification compares against `source.activeContentIDs()`.
    public func indexedContentIDs() async throws -> [CorpusContentID] {
        try await indexState.allStates()
            .map(\.contentID)
            .filter { $0 != Self.feedCursorRowID }
    }

    // MARK: - Training

    /// Minimum content-count threshold for a "stable" auto-trained basis.
    ///
    /// Below this count a 2× corpus growth triggers a growth retrain;
    /// above it only explicit `reindex(now:)` retrains (the "stable" contract).
    /// Produces at most log₂(50) ≈ 6 implicit retrains before the basis is
    /// stable — exponential doubling, stopping at the threshold.
    ///
    /// Mirrors `Corpus.ingest`'s `perDocAutoRetrainStableChunkThreshold`
    /// (fix-basis d7011ae2). The constant is public so tests can assert on it
    /// without magic numbers.
    public static let perDocAutoRetrainStableChunkThreshold = 50

    /// First-ingest auto-train (standalone / per-document path): trains a
    /// trainable slot that has no persisted basis — fires exactly once per
    /// estate lifetime. Used by `prepareIndex` (direct `indexContent`,
    /// `applyChange`, and `prepareQueueJob` callers).
    ///
    /// The growth-retrain check is intentionally ABSENT here. Per-document
    /// callers do not have batch context; a growth retrain that fires on every
    /// `indexContent` call would mutate the counts store in ways that break
    /// idempotence contracts. Growth retrains belong to the batch drain path —
    /// see `batchTrainIfNeeded`.
    private func firstIngestTrainIfNeeded(now: Date) async throws {
        let untrained = slots.indices.filter {
            slots[$0].freshBasisBlob != nil
                && slots[$0].basisDigest == Self.untrainedDigest
        }
        guard !untrained.isEmpty else { return }
        _ = try await trainTrainableSlots(now: now)
    }

    /// Three-state auto-train (Kinsta-fix, batch drain path): prevents a
    /// degenerate rank-1 basis from freezing during early corpus growth.
    ///
    /// Called from `drainIndexBatch` Phase 0 — ONCE per batch, before any
    /// per-document embed work. Never called from per-document paths.
    ///
    /// Implicit train triggers (mirrors Corpus.ingest fix-basis d7011ae2):
    ///   (1) First-ingest: no persisted basis → train from scratch on the full
    ///       current corpus snapshot (all content IDs in `source`).
    ///   (2) Growth retrain: basis is young (trainedChunkCount <
    ///       `perDocAutoRetrainStableChunkThreshold`) AND corpus has grown to
    ///       ≥ 2× trainedChunkCount → retrain from scratch on the full corpus.
    ///       Prevents a 1-doc rank-1 LSA SVD from becoming the permanent basis.
    ///       Retrains thin out exponentially and stop once the basis is stable.
    ///   (3) Fold-in: basis is stable or hasn't grown 2× → no retrain; new
    ///       records are projected onto the frozen basis.
    ///
    /// Active content is fetched lazily and cached across slots so multi-slot
    /// corpora pay only one DB read per drain pass. Retrain decisions are serial;
    /// the embed fan-out (Phase 2) runs on the post-retrain basis.
    ///
    /// `force: true` in `trainTrainableSlots` is required for case (2) because
    /// a young-basis slot has basisDigest ≠ untrainedDigest (already trained once),
    /// and the non-forced path would skip it. All trainable slots are retrained
    /// together (same corpus snapshot) so the decision is uniform.
    private func batchTrainIfNeeded(now: Date) async throws {
        let stableThreshold = Self.perDocAutoRetrainStableChunkThreshold
        // Indexed-doc count (CHECKPOINTED docs only), fetched lazily and
        // shared across all trainable slots — one DB read per batch.
        //
        // IMPORTANT — indexed count, not source count: the growth ratio compares
        // the basis (trained on trainedChunkCount INDEXED docs) against the ALREADY
        // CHECKPOINTED doc count. Using source.activeContentIDs() would include docs
        // queued but not yet indexed in the current drain batch. Those docs are about
        // to be processed below. If they triggered a growth retrain, trainTrainableSlots
        // would include them in the training corpus and create subsumed references for
        // them, which commitQueueBatch would then delete instead of creating the normal
        // non-subsumed delta references, corrupting the maintained counts.
        var cachedIndexedCount: Int? = nil
        var shouldRetrain = false

        for slotIndex in slots.indices {
            guard slots[slotIndex].freshBasisBlob != nil else { continue }
            // No persisted basis: first ingest — always train.
            if slots[slotIndex].basisDigest == Self.untrainedDigest {
                shouldRetrain = true
                break
            }
            // Persisted basis exists. Check if it is young enough to retrain.
            let persisted = try await basisStore.load(
                modelID: slots[slotIndex].provider.modelID,
                modelVersion: slots[slotIndex].provider.modelVersion)
            guard let basis = persisted,
                  basis.trainedChunkCount < stableThreshold
            else { continue } // Case (3): stable basis — fold-in only.
            // Case (2): young basis — check 2× growth against INDEXED count.
            let indexedCount: Int
            if let cached = cachedIndexedCount {
                indexedCount = cached
            } else {
                indexedCount = try await indexedContentIDs().count
                cachedIndexedCount = indexedCount
            }
            if indexedCount >= basis.trainedChunkCount * 2 {
                shouldRetrain = true
                break
            }
            // Indexed corpus hasn't grown 2× yet — fold-in only.
        }

        guard shouldRetrain else { return }
        // Retrain all trainable slots. force: true is required for cases (1)
        // and (2) — for case (2) basisDigest ≠ untrainedDigest; the non-forced
        // path skips already-trained slots.
        _ = try await trainTrainableSlots(now: now, force: true)
    }

    /// Training page size: how many canonical records stream through the
    /// accumulators per page. Bounds transient text memory to one page;
    /// accumulator state is vocabulary-scale regardless of page size, and
    /// the trained basis is byte-identical for every page size.
    public static let trainingPageSize = 2_000

    /// Test seam: when set, throws after the named provider's ATOMIC
    /// basis+counts commit (nil in production). Exercises resume across
    /// the per-provider training boundary.
    var _trainFaultAfterModelID: String?
    public func _armTrainFault(afterModelID: String?) {
        _trainFaultAfterModelID = afterModelID
    }
    /// Test seam: when set, throws BEFORE the named provider's basis
    /// commit (after accumulation/finalize). Exercises restart-from-zero.
    var _trainFaultBeforeCommitModelID: String?
    public func _armTrainFault(beforeCommitModelID: String?) {
        _trainFaultBeforeCommitModelID = beforeCommitModelID
    }

    /// One provider's immutable input to the bounded training fan-out.
    private struct ProviderTrainingJob: Sendable {
        let slotIndex: Int
        let modelID: String
        let modelVersion: String
        let freshBasisBlob: Data
        let witness: any TrainableEmbeddingBasis
    }

    /// One provider's fully-computed, not-yet-durable generation. The worker
    /// writes no durable state; the actor publishes these in slot order.
    private struct PreparedProviderTraining: Sendable {
        let job: ProviderTrainingJob
        let provider: any EmbeddingProvider & Sendable
        let countsAccumulator: any TrainableEmbeddingBasis
        let basisRow: PersistedBasis
        let countsRow: PersistedCounts
        let basisDigest: String
        let subsumedReferences: [PersistedCountsReference]
    }

    /// Conservative memory admission for concurrent provider training. The
    /// calibrated per-worker envelope mirrors the migration capacity gate:
    /// 2 GiB fixed plus 320 KiB per active content row. The default budget is
    /// 80% of physical RAM; operators may lower it explicitly. At least one
    /// worker is always admitted so this never makes an estate less operable
    /// than the former serial implementation.
    static func providerTrainingParallelism(
        contentCount: Int,
        providerCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        guard providerCount > 0 else { return 1 }
        let explicit = environment["MOOT_PROVIDER_TRAINING_MEMORY_BUDGET_BYTES"]
            .flatMap(UInt64.init)
            ?? environment["MOOT_MIGRATION_MEMORY_BUDGET_BYTES"].flatMap(UInt64.init)
        let budget = explicit ?? physicalMemory * 4 / 5
        let perWorker = 2 * UInt64(1_024 * 1_024 * 1_024)
            + UInt64(max(0, contentCount)) * UInt64(320 * 1_024)
        let memoryWorkers = max(1, Int(budget / max(1, perWorker)))
        return max(1, min(providerCount, max(1, processorCount), memoryWorkers))
    }

    private static func prepareProviderTraining(
        job: ProviderTrainingJob,
        allIDs: [CorpusContentID],
        indexedStates: [CorpusContentID: CorpusIndexState],
        source: any CorpusContentSource,
        now: Date
    ) async throws -> PreparedProviderTraining {
        let provider = try job.witness.reconstructBasis(from: job.freshBasisBlob)
        guard let trainable = provider as? any TrainableEmbeddingBasis else {
            throw CorpusKitError.notTrainable(
                "reconstructed provider is not trainable — basis seam invariant violated")
        }
        guard let countsAccumulator =
            try job.witness.reconstructBasis(from: job.freshBasisBlob)
                as? any TrainableEmbeddingBasis
        else {
            throw CorpusKitError.notTrainable(
                "reconstructed counts provider is not trainable — basis seam invariant violated")
        }

        var subsumedPendingReferences: [PersistedCountsReference] = []
        var documentCount = 0
        var cursor = 0
        while cursor < allIDs.count {
            let end = min(cursor + Self.trainingPageSize, allIDs.count)
            var texts: [String] = []
            texts.reserveCapacity(end - cursor)
            for id in allIDs[cursor..<end] {
                if let record = try await source.record(for: id) {
                    // Train the basis on the same text the dense lane uses at
                    // embed time — effectiveDenseText (denseCompositionText when
                    // set, lexical text otherwise). This keeps the basis
                    // vocabulary coherent with the composed vectors: both the
                    // training corpus and the per-document embed use the same
                    // text surface, so the basis projects the dense text into
                    // a geometry that the query (always lexical/short) can match.
                    // For callers without a dense-composition text the behaviour
                    // is identical to pre-dual-text code (effectiveDenseText == text).
                    texts.append(record.effectiveDenseText)
                    let indexed = indexedStates[record.id]
                    if indexed?.revision != record.revision
                        || indexed?.digest != record.digest
                        || indexed?.indexVersion != Self.indexVersion
                    {
                        subsumedPendingReferences.append(
                            PersistedCountsReference(
                                modelID: job.modelID,
                                modelVersion: job.modelVersion,
                                contentID: record.id,
                                revision: record.revision,
                                digest: record.digest,
                                updatedAt: now,
                                isSubsumed: true))
                    }
                }
            }
            trainable.accumulateTraining(texts: texts)
            for text in texts { countsAccumulator.addToCounts(text: text) }
            documentCount += texts.count
            cursor = end
        }
        trainable.finalizeTraining()

        let basisBlob = trainable.serializeBasis()
        let digest = CorpusContentDigest.digest(basisBlob)
        return PreparedProviderTraining(
            job: job,
            provider: provider,
            countsAccumulator: countsAccumulator,
            basisRow: PersistedBasis(
                modelID: job.modelID,
                modelVersion: job.modelVersion,
                basis: basisBlob,
                trainedAt: now,
                trainedChunkCount: documentCount),
            countsRow: PersistedCounts(
                modelID: job.modelID,
                modelVersion: job.modelVersion,
                counts: countsAccumulator.serializeCounts(),
                documentCount: documentCount,
                vocabSize: countsAccumulator.countsVocabularySize,
                updatedAt: now),
            basisDigest: digest,
            subsumedReferences: subsumedPendingReferences)
    }

    /// Stream-train every trainable slot that lacks a CURRENT basis (or
    /// every trainable slot when `force` is true), with bounded provider-level
    /// parallel compute and deterministic slot-order publication.
    ///
    /// Crash safety per provider: accumulation and finalization are
    /// in-memory only — a crash loses nothing durable and the resumed run
    /// retrains that provider from zero. The commit is ONE atomic
    /// transaction writing the basis AND its training-corpus counts (the
    /// metadata pair that must agree), after which the slot serves the new
    /// generation and its digest is returned. Already-trained providers
    /// are skipped on resume (their persisted digest is current).
    ///
    /// Bounded: texts stream through in pages of `trainingPageSize`;
    /// per-provider accumulator state is vocabulary-scale.
    ///
    /// - Returns: modelID → basis digest for every trainable slot (newly
    ///   trained and already-current alike).
    @discardableResult
    public func trainTrainableSlots(
        now: Date, force: Bool = false
    ) async throws -> [String: String] {
        // Publication replaces the base snapshot and deletes only reference
        // deltas represented by that snapshot. Prevent a reentrant admission
        // from publishing a post-snapshot reference before that deletion.
        await acquireCountsAdmission()
        defer { releaseCountsAdmission() }
        let indexedStates = Dictionary(uniqueKeysWithValues:
            try await indexState.allStates()
                .filter { $0.contentID != Self.feedCursorRowID }
                .map { ($0.contentID, $0) })
        var digests: [String: String] = [:]
        var jobs: [ProviderTrainingJob] = []
        for slotIndex in slots.indices {
            guard let blob = slots[slotIndex].freshBasisBlob,
                  let fresh = slots[slotIndex].provider as? any TrainableEmbeddingBasis
            else { continue }
            let modelID = slots[slotIndex].provider.modelID
            if !force, slots[slotIndex].basisDigest != Self.untrainedDigest {
                // Already trained (persisted basis loaded at open or a
                // prior pass this run) — resume skips it.
                digests[modelID] = slots[slotIndex].basisDigest
                continue
            }
            jobs.append(ProviderTrainingJob(
                slotIndex: slotIndex,
                modelID: modelID,
                modelVersion: slots[slotIndex].provider.modelVersion,
                freshBasisBlob: blob,
                witness: fresh))
        }

        let allIDs = try await source.activeContentIDs()
        guard !allIDs.isEmpty else { return digests }
        let cap = Self.providerTrainingParallelism(
            contentCount: allIDs.count, providerCount: jobs.count)
        let trainingSource = source

        var start = 0
        while start < jobs.count {
            let end = min(start + cap, jobs.count)
            var prepared = [PreparedProviderTraining?](
                repeating: nil, count: end - start)
            try await withThrowingTaskGroup(
                of: (Int, PreparedProviderTraining).self
            ) { group in
                for offset in 0..<(end - start) {
                    let job = jobs[start + offset]
                    group.addTask {
                        (offset, try await Self.prepareProviderTraining(
                            job: job,
                            allIDs: allIDs,
                            indexedStates: indexedStates,
                            source: trainingSource,
                            now: now))
                    }
                }
                for try await (offset, result) in group {
                    prepared[offset] = result
                }
            }

            // Publication remains deterministic and crash-resumable: each
            // provider commits atomically in configured slot order.
            for result in prepared.compactMap({ $0 }) {
                let modelID = result.job.modelID
                if _trainFaultBeforeCommitModelID == modelID {
                    _trainFaultBeforeCommitModelID = nil
                    throw CorpusKitError.invalidConfiguration(
                        "injected training fault before commit: \(modelID)")
                }
                let basisStore = self.basisStore
                let countsStore = self.countsStore
                try await storage.transaction(isolation: .serializable) { txn in
                    try await basisStore.upsert(result.basisRow, into: txn.rowStore)
                    try await countsStore.upsert(result.countsRow, into: txn.rowStore)
                    try await countsStore.deleteReferences(
                        modelID: result.job.modelID,
                        modelVersion: result.job.modelVersion,
                        into: txn.rowStore)
                    for reference in result.subsumedReferences {
                        try await countsStore.upsertReference(
                            reference, into: txn.rowStore)
                    }
                }
                let slotIndex = result.job.slotIndex
                slots[slotIndex].provider = result.provider
                slots[slotIndex].basisDigest = result.basisDigest
                slots[slotIndex].countsAccumulator = result.countsAccumulator
                slots[slotIndex].countsDocumentCount =
                    result.countsRow.documentCount
                slots[slotIndex].growthTermDigests = []
                slots[slotIndex].countsVocabAnchor = result.countsRow.vocabSize
                digests[modelID] = result.basisDigest

                if _trainFaultAfterModelID == modelID {
                    _trainFaultAfterModelID = nil
                    throw CorpusKitError.invalidConfiguration(
                        "injected training fault after commit: \(modelID)")
                }
            }
            start = end
        }
        return digests
    }

    /// Retrain every trainable slot from scratch on the full active corpus
    /// and re-index every active content row. Deterministic ascending-ID
    /// streaming order. Training is streamed (bounded) and each provider's
    /// basis+counts commit is atomic.
    public func reindex(now: Date) async throws {
        _ = try await trainTrainableSlots(now: now, force: true)
        // Bulk-write bracket (same idiom as reconcileConfiguredProviders and
        // the drain worker): defer the resident dense index for the whole
        // O(corpus) rewrite and publish ONCE — per-record invalidation makes
        // an estate-scale retrain rebuild the resident index per write.
        try await vectorStore.beginDeferredIndex()
        let ids = try await source.activeContentIDs()
        if case .wholeContent = configuration.indexUnit {
            // Bound both task admission and prepared-result memory. The batch
            // kernel preserves input order and advances each checkpoint only
            // after BM25, vectors, and coverage are durable.
            for batch in ids.chunked(into: 500) {
                _ = try await indexWholeContentBatch(
                    ids: batch, now: now, parallelism: nil,
                    slotScope: .all, force: true)
            }
        } else {
            // Standalone passage policies also replace durable range rows;
            // keep that mutation path serialized and policy-bound.
            for id in ids {
                guard let record = try await source.record(for: id) else {
                    try await clearDerivedState(id: id)
                    continue
                }
                if let checkpoint = try await prepareIndex(
                    record: record, appliedCursor: nil, force: true, now: now,
                    slotScope: .all
                ) {
                    try await indexState.advance(checkpoint)
                }
            }
        }
        try await vectorStore.publishResidentIndex()
        try await providerConfigurationStore.markCurrent(
            providerGenerationToken(), now: now)
    }

    // MARK: - Maintained counts

    /// Direct-path last-write publication under the same durable-reference
    /// authority as the queue batch. Reference mutation, nondecreasing anchors,
    /// and the corresponding content checkpoint commit together.
    private func commitDirectIndex(
        record: CorpusContentRecord, checkpoint: CorpusIndexState, now: Date
    ) async throws {
        await acquireCountsAdmission()
        defer { releaseCountsAdmission() }
        if countsReloadRequired {
            try await reloadCountsFromStorage()
            countsReloadRequired = false
        }
        var references: [(
            reference: PersistedCountsReference, slotIndex: Int,
            countsDocument: Bool, termDigests: Set<String>
        )] = []
        var consumedSubsumedReferences: [(modelID: String, modelVersion: String, contentID: String)] = []
        for index in slots.indices where slots[index].countsAccumulator != nil {
            let modelID = slots[index].provider.modelID
            let modelVersion = slots[index].provider.modelVersion
            let countsDocument: Bool
            var termDigests: Set<String> = []
            if let existing = try await countsStore.referenceFor(
                modelID: modelID, modelVersion: modelVersion, contentID: record.id)
            {
                if existing.digest == record.digest {
                    if existing.isSubsumed {
                        consumedSubsumedReferences.append(
                            (modelID, modelVersion, record.id))
                    }
                    continue
                }
                countsDocument = false
                termDigests.formUnion(existing.growthTermDigests)
            } else {
                countsDocument = try await indexState.state(for: record.id) == nil
            }
            if let accumulator = slots[index].countsAccumulator {
                for term in defaultKeywordTokens(record.text)
                    where !accumulator.countsContainsTerm(term)
                {
                    termDigests.insert(CorpusContentDigest.digest(Data(term.utf8)))
                }
            }
            references.append((
                PersistedCountsReference(
                    modelID: modelID, modelVersion: modelVersion,
                    contentID: record.id, revision: record.revision,
                    digest: record.digest, updatedAt: now,
                    growthTermDigests: Array(termDigests)),
                index, countsDocument, termDigests))
        }
        var anchorRows: [(modelID: String, modelVersion: String, docs: Int, vocab: Int)] = []
        for item in references {
            slots[item.slotIndex].growthTermDigests.formUnion(item.termDigests)
            if item.countsDocument {
                slots[item.slotIndex].countsDocumentCount += 1
            }
            let publishedVocabulary =
                slots[item.slotIndex].countsAccumulator?.countsVocabularySize ?? 0
            slots[item.slotIndex].countsVocabAnchor = max(
                slots[item.slotIndex].countsVocabAnchor,
                publishedVocabulary + slots[item.slotIndex].growthTermDigests.count)
            anchorRows.append((
                item.reference.modelID, item.reference.modelVersion,
                slots[item.slotIndex].countsDocumentCount,
                slots[item.slotIndex].countsVocabAnchor))
        }
        let pendingReferences = references.map(\.reference)
        let pendingSubsumedDeletes = consumedSubsumedReferences
        let pendingAnchors = anchorRows
        let countsStore = self.countsStore
        let indexState = self.indexState
        do {
            try await storage.transaction(isolation: .serializable) { txn in
                for row in pendingSubsumedDeletes {
                    try await countsStore.deleteReference(
                        modelID: row.modelID, modelVersion: row.modelVersion,
                        contentID: row.contentID, into: txn.rowStore)
                }
                for row in pendingReferences {
                    try await countsStore.upsertReference(row, into: txn.rowStore)
                }
                for anchors in pendingAnchors {
                    _ = try await countsStore.updateAnchors(
                        modelID: anchors.modelID, modelVersion: anchors.modelVersion,
                        documentCount: anchors.docs, vocabSize: anchors.vocab,
                        into: txn.rowStore)
                }
                try await indexState.advance(checkpoint, into: txn.rowStore)
            }
        } catch {
            countsReloadRequired = true
            do {
                try await reloadCountsFromStorage()
                countsReloadRequired = false
            } catch let reloadError {
                throw CorpusKitError.storeUnavailable(
                    "direct counts/checkpoint transaction failed: \(error); "
                    + "durable counts reload failed: \(reloadError)")
            }
            throw error
        }
    }

    private func acquireCountsAdmission() async {
        if !countsAdmissionActive {
            countsAdmissionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            countsAdmissionWaiters.append(continuation)
        }
    }

    private func releaseCountsAdmission() {
        guard !countsAdmissionWaiters.isEmpty else {
            countsAdmissionActive = false
            return
        }
        countsAdmissionWaiters.removeFirst().resume()
    }

    private func persistCounts(now: Date) async throws {
        for slot in slots {
            guard let accumulator = slot.countsAccumulator else { continue }
            let row = PersistedCounts(
                modelID: slot.provider.modelID,
                modelVersion: slot.provider.modelVersion,
                counts: accumulator.serializeCounts(),
                documentCount: slot.countsDocumentCount,
                vocabSize: slot.countsVocabAnchor,
                updatedAt: now)
            let countsStore = self.countsStore
            // The blob is the immutable publication snapshot. Identity-scoped
            // growth references remain authoritative until the next provider
            // publication; deleting them here would lose restart-exact term
            // contributions.
            try await countsStore.upsert(row)
        }
    }

    /// Persist the maintained counts snapshot — the BATCH-boundary write.
    /// Called by the drain worker at burst close (and by training commits
    /// through their own atomic path); never once per record.
    public func persistCountsSnapshot(now: Date) async throws {
        await acquireCountsAdmission()
        defer { releaseCountsAdmission() }
        try await persistCounts(now: now)
    }

    /// The vocab-growth anchor the autonomic governor reads (content-unit
    /// semantics: documents folded are canonical records, not chunks).
    public func maintainedVocabAnchor() -> Int {
        slots.filter { $0.countsAccumulator != nil }
            .map(\.countsVocabAnchor).max() ?? 0
    }

    /// Canonical records represented by the base snapshot plus durable deltas.
    public func maintainedDocumentCount() -> Int {
        slots.filter { $0.countsAccumulator != nil }
            .map(\.countsDocumentCount).max() ?? 0
    }

    // MARK: - Recall

    /// Hybrid recall: BM25 + binary-vector kNN on the default signal,
    /// fused via RRF, aggregated to canonical content IDs. Result identity
    /// is ALWAYS the content ID; passage mode attaches range evidence.
    public func recall(
        _ query: String, limit: Int = 10, now: Date
    ) async throws -> [CorpusContentHit] {
        guard limit > 0, !query.isEmpty else { return [] }
        let provider = slots[0].provider
        let candidateK = max(limit * 4, 32)

        let probe = try await provider.embed(query)
        let vectorMatches = try await vectorStore.findNearest(
            probe: probe, modelID: provider.modelID, limit: candidateK)
        let queryTokens = CorpusDefaultTokenizer().keywordTokens(query)
        let keywordHits = try await invertedIndex.topK(
            queryTerms: queryTokens, k: candidateK)

        // Aggregate each lane to canonical content IDs (identity rule:
        // best-unit score represents the content).
        var vectorBest: [CorpusContentID: (score: Float, key: String)] = [:]
        for match in vectorMatches {
            let id = IndexUnitIdentity.contentID(fromItemKey: match.itemID)
            // Hamming distance → similarity for ranking (256 − distance).
            let score = Float(256 - match.distance)
            if let existing = vectorBest[id], existing.score >= score { continue }
            vectorBest[id] = (score, match.itemID)
        }
        var keywordBest: [CorpusContentID: (score: Float, key: String)] = [:]
        for hit in keywordHits {
            let id = IndexUnitIdentity.contentID(fromItemKey: hit.itemID)
            if let existing = keywordBest[id], existing.score >= hit.impact { continue }
            keywordBest[id] = (hit.impact, hit.itemID)
        }

        // RRF fusion over the two per-content ranked lists (rrfK = 60,
        // the same constant HybridRecall uses; deterministic ID tie-break).
        let rrfK: Double = 60
        let vectorRanked = vectorBest
            .sorted { $0.value.score != $1.value.score
                ? $0.value.score > $1.value.score : $0.key < $1.key }
            .map(\.key)
        let keywordRanked = keywordBest
            .sorted { $0.value.score != $1.value.score
                ? $0.value.score > $1.value.score : $0.key < $1.key }
            .map(\.key)
        var fused: [CorpusContentID: Double] = [:]
        for (rank, id) in vectorRanked.enumerated() {
            fused[id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
        }
        for (rank, id) in keywordRanked.enumerated() {
            fused[id, default: 0] += 1.0 / (rrfK + Double(rank + 1))
        }

        let ranked = fused.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(limit)

        return ranked.map { (id, score) in
            // Evidence: the best-scoring unit key for this content, when
            // it parses as a passage key (standalone passage mode only).
            let bestKey = keywordBest[id]?.key ?? vectorBest[id]?.key
            let evidence = bestKey.flatMap { IndexUnitIdentity.evidence(fromItemKey: $0) }
            return CorpusContentHit(
                id: id,
                score: Float(score),
                keywordScore: keywordBest[id]?.score,
                vectorScore: vectorBest[id]?.score,
                evidence: evidence)
        }
    }

    /// BM25-only top-k at content granularity — the RecallDirector's
    /// keyword frontier. Returns content IDs DIRECTLY (no translation).
    public func bm25TopK(query: String, limit: Int) async throws -> [(id: CorpusContentID, score: Float)] {
        guard limit > 0, !query.isEmpty else { return [] }
        let tokens = CorpusDefaultTokenizer().keywordTokens(query)
        guard !tokens.isEmpty else { return [] }
        let hits = try await invertedIndex.topK(queryTerms: tokens, k: limit * 4)
        var best: [CorpusContentID: Float] = [:]
        for hit in hits {
            let id = IndexUnitIdentity.contentID(fromItemKey: hit.itemID)
            best[id] = max(best[id] ?? 0, hit.impact)
        }
        return best.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(limit).map { (id: $0.key, score: $0.value) }
    }

    /// Enter deferred-index mode on the vector store for a drain burst (one
    /// resident-index rebuild per burst — O(N), not O(N²)). Internal seam for
    /// the queue extension; mirrors `Corpus.beginDeferredVectorIndex`.
    func beginDeferredVectorIndex() async throws {
        try await vectorStore.beginDeferredIndex()
    }

    /// Publish the deferred resident vector index at burst end. Internal seam
    /// for the queue extension; mirrors `Corpus.publishVectorIndex`.
    func publishVectorIndex() async throws {
        try await vectorStore.publishResidentIndex()
    }

    /// The default signal's model ID (for callers driving the vector lane
    /// directly).
    public var modelID: String { slots[0].provider.modelID }

    /// Embed on the default signal (the recall probe surface).
    public func embed(_ text: String) async throws -> Engram {
        try await slots[0].provider.embed(text)
    }

    // MARK: - GLK orchestration surface (P3 cutover compatibility)

    /// BM25-only top-k with the RecallDirector's historical tuple labels.
    /// Identity is DIRECT: the returned `sourceID` IS the canonical content
    /// ID (Drawer ID) — no translation happened to produce it.
    public func bm25TopKBySource(
        query: String, limit: Int
    ) async throws -> [(sourceID: String, score: Float)] {
        try await bm25TopK(query: query, limit: limit)
            .map { (sourceID: $0.id, score: $0.score) }
    }

    /// Live indexed content IDs as a Set — the intake backfill's skip set.
    public func indexedSourceIDs() async throws -> Set<String> {
        Set(try await indexedContentIDs())
    }

    /// Per-content derived-index coverage attestations: which canonical
    /// (revision, digest) each ID's derived rows currently reflect. This is
    /// the engine's ONLY integrity surface — canonical-content integrity is
    /// the LocusKit Drawer content root; the engine attests coverage and
    /// never builds a second content Merkle hierarchy (shared-content 1.1).
    public func indexCoverageAttestations() async throws
        -> [(contentID: CorpusContentID, revision: Int64, digest: String)] {
        try await indexState.allStates()
            .filter { $0.contentID != Self.feedCursorRowID }
            .map { ($0.contentID, $0.revision, $0.digest) }
    }

    /// Indexed content-row count (content-unit semantics — canonical rows,
    /// not chunks). The estate drain status reports this.
    public func count() async throws -> Int {
        try await indexedContentIDs().count
    }

    /// The estate's single dense vector store, borrowed by the composition
    /// layer for its scored-recall vector lane (one store, one resident
    /// array — same seam the legacy Corpus exposed).
    public var sharedVectorStore: VectorStore { vectorStore }

    /// Clear one content ID's derived state directly (the expunge/withdraw
    /// verb path — removal authority is the GLK/LocusKit verb; this clears
    /// the derived rows it owns).
    public func removeContent(id: CorpusContentID) async throws {
        try validate(id: id)
        try await clearDerivedState(id: id)
    }

    /// The declared encode speed. The content drain currently processes
    /// serially per job; the setting is retained for the fan-out the scale
    /// phase may add. Accepting it keeps the estate governor's surface.
    public func setEncodeSpeed(_ speed: EncodeSpeed) {
        // Serial drain today — the preference has no effect yet.
    }

    /// Destroy this engine's recall index — OWNERSHIP-SCOPED, unlike the
    /// legacy `destroyAllVectors` teardown:
    ///   - BM25 sidecar + checkpoints + basis/counts are corpus-exclusive
    ///     tables and are cleared wholesale;
    ///   - vector rows are deleted by EXACT KEY (every checkpointed content
    ///     ID × slot model × lane) — rows of other lanes are never touched;
    ///   - the engine's consumer claims are released; representations still
    ///     claimed by other lanes survive untouched.
    public func destroyRecallIndex() async throws {
        // Claim-aware: keys in representation families another retained
        // consumer also claims are NOT deleted — that claimant may own the
        // exact same rows. The engine releases its own claims below; the
        // surviving claimant's rows survive with it.
        let shared = try await sharedRepresentationFamilies()
        let ids = try await indexedContentIDs()
        var keys: [VectorExactKey] = []
        for id in ids {
            for key in try await unitKeys(for: id) {
                for slot in slots {
                    for lane: Int in [0, 1] {
                        if shared.contains("\(slot.provider.modelID)|\(lane)") { continue }
                        keys.append(VectorExactKey(
                            itemID: key, vectorIndex: lane,
                            modelID: slot.provider.modelID))
                    }
                }
            }
        }
        try await vectorStore.deleteVectors(keys: keys)
        try await invertedIndex.deleteAll()
        try await indexState.clearAll()
        try await coverageStore.clearAll()
        try await basisStore.deleteAll()
        try await countsStore.deleteAll()
        try await claims.releaseAllClaims(consumer: Self.claimsConsumer)
    }

    // MARK: - Per-signal dense float lanes (the RecallDirector seam)

    /// Per-signal dense float NEAREST recall — content-ID keyed. One
    /// `(modelID, outcome)` pair per held slot, in slot order. Hit item IDs
    /// are canonical content IDs (passage keys aggregate to their content
    /// ID before ranking).
    public func floatNearestPerSignal(
        query: String, limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        await floatPerSignal(query: query, limit: limit, direction: .nearest)
    }

    /// Single-signal dense float nearest recall — the DEFAULT slot's
    /// outcome (compatibility convenience over `floatNearestPerSignal`).
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome {
        await floatNearestPerSignal(query: query, limit: limit).first?.outcome ?? .emptyQuery
    }

    /// Per-signal dense float FARTHEST (anti-similarity) recall.
    public func floatFarthestPerSignal(
        query: String, limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        await floatPerSignal(query: query, limit: limit, direction: .farthest)
    }

    /// Test-only: when non-nil, the next per-signal float call reports
    /// `.storeError(this)` for the DEFAULT slot (single-use), mirroring the
    /// legacy `Corpus._testForceFloatStoreError` seam so GLK's dark-lane
    /// chain tests exercise the store-error contract. Never set in
    /// production.
    var _forcedFloatError: Error? = nil

    /// Install the single-use forced float store error (test seam).
    public func _testForceFloatStoreError(_ error: Error) {
        _forcedFloatError = error
    }

    /// Test-only ingest failure hook: invoked with the content ID BEFORE the
    /// drain processes a job; a throw simulates a transient index failure so
    /// the at-least-once retry semantics are exercisable. nil in production.
    var _ingestFailureHook: (@Sendable (String) throws -> Void)?

    /// Arm (or clear) the drain failure-injection hook (test seam).
    public func _armIngestFailureHook(_ hook: (@Sendable (String) throws -> Void)?) {
        _ingestFailureHook = hook
    }

    private func floatPerSignal(
        query: String, limit: Int, direction: SearchDirection
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }
        // Consume the forced-error seam for the DEFAULT slot (nearest path
        // only — same contract as the legacy engine's seam).
        var forcedDefault: FloatLaneOutcome? = nil
        if direction == .nearest, let forced = _forcedFloatError {
            _forcedFloatError = nil
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error", value: 1.0,
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
            forcedDefault = .storeError(forced)
        }
        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            if slotIndex == 0, let forced = forcedDefault {
                results.append((slot.provider.modelID, forced))
                continue
            }
            let provider = slot.provider
            let probe: [Float]
            do {
                let result = try await provider.embedFloat(query)
                guard !result.isEmpty else {
                    Intellectus.report(.metric(
                        name: "corpus.float_lane.dark_provider", value: 1.0,
                        tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                    results.append((provider.modelID, .unavailableProviderOptOut))
                    continue
                }
                probe = result
            } catch VectorKitError.embedFloatVocabMiss {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_vocab_miss", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoVocabHit))
                continue
            } catch {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableProviderOptOut))
                continue
            }
            let matches: [VectorMatch]
            do {
                switch direction {
                case .nearest:
                    matches = try await vectorStore.findNearestFloat(
                        probe: probe, modelID: provider.modelID, limit: limit * 4)
                case .farthest:
                    matches = try await vectorStore.findFarthestFloat(
                        probe: probe, modelID: provider.modelID, limit: limit * 4)
                }
            } catch {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.store_error", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .storeError(error)))
                continue
            }
            guard !matches.isEmpty else {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_no_rows", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoFloatRows))
                continue
            }
            // Aggregate unit hits to canonical content IDs — DIRECT identity;
            // a passage key parses to its content ID, a whole-content key IS it.
            var byContent: [String: Float] = [:]
            for match in matches {
                let id = IndexUnitIdentity.contentID(fromItemKey: match.itemID)
                let similarity = 1.0 - Float(match.distance) / 10_000.0
                switch direction {
                case .nearest:
                    byContent[id] = max(byContent[id] ?? -Float.greatestFiniteMagnitude, similarity)
                case .farthest:
                    byContent[id] = min(byContent[id] ?? Float.greatestFiniteMagnitude, similarity)
                }
            }
            guard !byContent.isEmpty else {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_no_rows", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoFloatRows))
                continue
            }
            var ranked = byContent.map { (itemID: $0.key, similarity: $0.value) }
            ranked.sort { a, b in
                if a.similarity != b.similarity {
                    switch direction {
                    case .nearest: return a.similarity > b.similarity
                    case .farthest: return a.similarity < b.similarity
                    }
                }
                return a.itemID < b.itemID
            }
            let hits = Array(ranked.prefix(limit))
            Intellectus.report(.metric(
                name: "corpus.float_lane.hit", value: Double(hits.count),
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
            results.append((provider.modelID, .hits(hits)))
        }
        return results
    }
}


// MARK: - Batch slicing

extension Array {
    /// Fixed-size slices in order; the last slice may be short.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
