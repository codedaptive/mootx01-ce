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
//   - standalone `.tokenBudgetedPassages`: index units are token-budgeted
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
import PersistenceKit
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes
import VectorKit

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

// MARK: - Passage production

/// Deterministic token-budgeted passage ranges over UTF-8 text.
///
/// Token boundaries follow the SAME alphanumeric-run rule as
/// `defaultKeywordTokens` (runs of Unicode-alphabetic + ASCII-digit
/// scalars), computed WITHOUT lowercasing so byte offsets refer to the
/// original text. Passages are consecutive non-overlapping windows of at
/// most `tokenBudget` tokens; each range spans from its first token's
/// start byte through its last token's end byte. Cross-port identical
/// (Rust `passage_ranges`).
enum PassageProduction {
    static func passageRanges(
        text: String, tokenBudget: Int
    ) -> [(utf8Start: Int, utf8Length: Int)] {
        precondition(tokenBudget > 0)
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
            let windowEnd = min(index + tokenBudget, tokenRanges.count)
            let first = tokenRanges[index]
            let last = tokenRanges[windowEnd - 1]
            out.append((utf8Start: first.start, utf8Length: last.end - first.start))
            index = windowEnd
        }
        return out
    }

    /// Field separator inside passage keys — cannot appear in validated
    /// content IDs.
    static let keySeparator = "\u{1F}"

    /// The deterministic passage key: contentID␟revision␟start␟length.
    static func passageKey(
        contentID: CorpusContentID, revision: Int64, utf8Start: Int, utf8Length: Int
    ) -> String {
        "\(contentID)\(keySeparator)\(revision)\(keySeparator)\(utf8Start)\(keySeparator)\(utf8Length)"
    }

    /// Parse a derived-row item key back to its canonical content ID.
    /// A whole-content key contains no separator and returns itself.
    static func contentID(fromItemKey key: String) -> CorpusContentID {
        guard let range = key.range(of: keySeparator) else { return key }
        return String(key[key.startIndex..<range.lowerBound])
    }

    static func evidence(fromItemKey key: String) -> CorpusEvidence? {
        let parts = key.components(separatedBy: keySeparator)
        guard parts.count == 4, let start = Int(parts[2]), let length = Int(parts[3]) else {
            return nil
        }
        return CorpusEvidence(passageID: key, utf8Start: start, utf8Length: length)
    }
}

// MARK: - Engine

/// The canonical-ID indexing/recall engine. One engine serves BOTH
/// operating modes; only the content source and the (validated)
/// configuration differ.
public actor CorpusContentEngine {

    /// The engine/index layout version stamped into `corpus_index_state`.
    /// Bump when the derived layout changes incompatibly.
    public static let indexVersion: Int64 = 1

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
    private let claims: VectorRepresentationClaims
    private var slots: [Slot]

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
            var passages = false
            if case .tokenBudgetedPassages = configuration.indexUnit { passages = true }
            try await storage.migrate(
                to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: passages))
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
            built.append(Slot(
                provider: resolved.provider,
                freshBasisBlob: resolved.freshBasisBlob,
                countsAccumulator: resolved.countsAccumulator,
                countsDocumentCount: resolved.countsDocumentCount))
        }
        self.slots = built
        try await invertedIndex.open()
    }

    /// Register this engine's representation claims (idempotent). Called
    /// by the engine's writers before the first vector write; exposed so
    /// lifecycle paths can pre-claim at construction.
    public func registerClaims(now: Date) async throws {
        for slot in slots {
            for lane: Int in [0, 1] {
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

    /// STANDALONE convenience: put canonical text and index it in one call.
    /// Attached mode rejects content mutation through CorpusKit
    /// (`attachedModeViolation`) — removal/authorship authority there is the
    /// GLK/LocusKit verb surface.
    public func ingest(_ text: String, contentID: CorpusContentID, now: Date) async throws {
        guard configuration.allowsContentMutation,
              let store = source as? any CorpusContentStore else {
            throw CorpusKitError.attachedModeViolation(
                "content mutation through CorpusKit is standalone-only — attached "
                + "content changes flow through the canonical store's own verbs")
        }
        try validate(id: contentID)
        guard !text.isEmpty else { return }
        _ = try await store.put(text, id: contentID, now: now)
        try await indexContent(id: contentID, now: now)
    }

    // MARK: - Content validation

    private func validate(id: CorpusContentID) throws {
        guard !id.isEmpty, !id.contains(PassageProduction.keySeparator) else {
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

    private func index(
        record: CorpusContentRecord, appliedCursor: String?, force: Bool, now: Date
    ) async throws {
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
            return
        }
        try await registerClaims(now: now)
        try await firstIngestTrainIfNeeded(now: now)

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
        var rows: [VectorPayloadInput] = []
        rows.reserveCapacity(units.count * slots.count * 2)
        for slot in slots {
            for unit in units {
                let (engram, floats) = try await slot.provider.embedPair(unit.text)
                rows.append(VectorPayloadInput(
                    itemID: unit.key, vectorIndex: 0,
                    payload: VectorPayload(engram: engram),
                    modelID: slot.provider.modelID,
                    modelVersion: slot.provider.modelVersion,
                    filedAt: now))
                if !floats.isEmpty {
                    rows.append(VectorPayloadInput(
                        itemID: unit.key, vectorIndex: 1,
                        payload: VectorPayload(floats: floats),
                        modelID: slot.provider.modelID,
                        modelVersion: slot.provider.modelVersion,
                        filedAt: now))
                }
            }
        }
        if !rows.isEmpty {
            try await vectorStore.addPayloads(rows)
        }

        // Maintained counts: fold the canonical text once per record.
        foldIntoCounts(text: record.text)
        try await persistCounts(now: now)

        // Checkpoint LAST — derived rows reflect (revision, digest) now.
        try await indexState.advance(CorpusIndexState(
            contentID: record.id, revision: record.revision, digest: record.digest,
            indexVersion: Self.indexVersion, appliedCursor: appliedCursor, updatedAt: now))
        Intellectus.report(.metric(
            name: "corpus.content.indexed", value: 1.0,
            tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
    }

    /// One index unit: its derived-row key and the text it covers.
    private struct IndexUnit {
        let key: String
        let text: String
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
            units = [IndexUnit(key: record.id, text: record.text)]
        case .tokenBudgetedPassages(let budget):
            let ranges = PassageProduction.passageRanges(
                text: record.text, tokenBudget: budget)
            let utf8 = Array(record.text.utf8)
            units = ranges.map { range in
                let key = PassageProduction.passageKey(
                    contentID: record.id, revision: record.revision,
                    utf8Start: range.utf8Start, utf8Length: range.utf8Length)
                let bytes = utf8[range.utf8Start..<(range.utf8Start + range.utf8Length)]
                return IndexUnit(key: key, text: String(decoding: bytes, as: UTF8.self))
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
                    "utf8_length": .int(Int64(range.utf8Length))
                ])
            }
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
        if case .tokenBudgetedPassages = configuration.indexUnit {
            let rows = try await storage.rowStore.query(
                table: "corpus_passages",
                where: .eq(Column(table: "corpus_passages", name: "content_id"), .text(id)),
                orderBy: [], limit: nil, offset: nil)
            for row in rows {
                if case let .text(passageID)? = row["passage_id"] { keys.insert(passageID) }
            }
        }
        return keys
    }

    /// Delete the BM25 postings and vector rows for the given unit keys —
    /// exact-key scoped, never model-wide.
    private func deleteDerivedRows(unitKeys: Set<String>) async throws {
        var vectorKeys: [VectorExactKey] = []
        for key in unitKeys.sorted() {
            try await invertedIndex.remove(itemID: key)
            for slot in slots {
                vectorKeys.append(VectorExactKey(
                    itemID: key, vectorIndex: 0, modelID: slot.provider.modelID))
                vectorKeys.append(VectorExactKey(
                    itemID: key, vectorIndex: 1, modelID: slot.provider.modelID))
            }
        }
        try await vectorStore.deleteVectors(keys: vectorKeys)
    }

    /// Clear EVERYTHING derived for `id` (the remove path): BM25, vectors,
    /// passage rows, and the checkpoint.
    private func clearDerivedState(id: CorpusContentID) async throws {
        let keys = try await unitKeys(for: id)
        try await deleteDerivedRows(unitKeys: keys)
        if case .tokenBudgetedPassages = configuration.indexUnit {
            _ = try await storage.rowStore.delete(
                table: "corpus_passages",
                where: .eq(Column(table: "corpus_passages", name: "content_id"), .text(id)))
        }
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

    private func firstIngestTrainIfNeeded(now: Date) async throws {
        for index in slots.indices where slots[index].freshBasisBlob != nil {
            let provider = slots[index].provider
            let hasBasis = try await basisStore.load(
                modelID: provider.modelID, modelVersion: provider.modelVersion) != nil
            if !hasBasis {
                try await trainSlot(index, now: now)
            }
        }
    }

    private func trainSlot(_ index: Int, now: Date) async throws {
        guard let blob = slots[index].freshBasisBlob,
              let fresh = slots[index].provider as? any TrainableEmbeddingBasis else { return }
        let texts = try await activeTexts()
        guard !texts.isEmpty else { return }
        let provider = try fresh.reconstructBasis(from: blob)
        guard let trainable = provider as? any TrainableEmbeddingBasis else {
            throw CorpusKitError.notTrainable(
                "reconstructed provider is not trainable — basis seam invariant violated")
        }
        trainable.trainOnCorpus(texts: texts)
        slots[index].provider = provider
        try await basisStore.upsert(PersistedBasis(
            modelID: provider.modelID,
            modelVersion: provider.modelVersion,
            basis: trainable.serializeBasis(),
            trainedAt: now,
            trainedChunkCount: texts.count))
    }

    private func activeTexts() async throws -> [String] {
        var texts: [String] = []
        for id in try await source.activeContentIDs() {
            if let record = try await source.record(for: id) {
                texts.append(record.text)
            }
        }
        return texts
    }

    /// Retrain every trainable slot from scratch on the full active corpus
    /// and re-index every active content row. Deterministic ascending-ID
    /// streaming order.
    public func reindex(now: Date) async throws {
        for index in slots.indices where slots[index].freshBasisBlob != nil {
            try await trainSlot(index, now: now)
        }
        for id in try await source.activeContentIDs() {
            guard let record = try await source.record(for: id) else {
                try await clearDerivedState(id: id)
                continue
            }
            // Forced: a retrain changes the basis, so vectors must be
            // rewritten even when the checkpoint already matches.
            try await index(record: record, appliedCursor: nil, force: true, now: now)
        }
        try await persistCounts(now: now)
    }

    // MARK: - Maintained counts

    private func foldIntoCounts(text: String) {
        for index in slots.indices where slots[index].countsAccumulator != nil {
            slots[index].countsAccumulator!.addToCounts(text: text)
            slots[index].countsDocumentCount += 1
        }
    }

    private func persistCounts(now: Date) async throws {
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

    /// The vocab-growth anchor the autonomic governor reads (content-unit
    /// semantics: documents folded are canonical records, not chunks).
    public func maintainedVocabAnchor() -> Int {
        slots.compactMap { $0.countsAccumulator?.countsVocabularySize }.max() ?? 0
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
            let id = PassageProduction.contentID(fromItemKey: match.itemID)
            // Hamming distance → similarity for ranking (256 − distance).
            let score = Float(256 - match.distance)
            if let existing = vectorBest[id], existing.score >= score { continue }
            vectorBest[id] = (score, match.itemID)
        }
        var keywordBest: [CorpusContentID: (score: Float, key: String)] = [:]
        for hit in keywordHits {
            let id = PassageProduction.contentID(fromItemKey: hit.itemID)
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
            let evidence = bestKey.flatMap { PassageProduction.evidence(fromItemKey: $0) }
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
            let id = PassageProduction.contentID(fromItemKey: hit.itemID)
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
        let ids = try await indexedContentIDs()
        var keys: [VectorExactKey] = []
        for id in ids {
            for key in try await unitKeys(for: id) {
                for slot in slots {
                    keys.append(VectorExactKey(
                        itemID: key, vectorIndex: 0, modelID: slot.provider.modelID))
                    keys.append(VectorExactKey(
                        itemID: key, vectorIndex: 1, modelID: slot.provider.modelID))
                }
            }
        }
        try await vectorStore.deleteVectors(keys: keys)
        try await invertedIndex.deleteAll()
        try await indexState.clearAll()
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
                let id = PassageProduction.contentID(fromItemKey: match.itemID)
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
