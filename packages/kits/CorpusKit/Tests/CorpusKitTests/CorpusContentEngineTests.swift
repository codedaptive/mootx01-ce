// CorpusContentEngineTests.swift
//
// Canonical-ID engine coverage (GLK shared-content 1.1, P2).
//
// The engine must satisfy the identity and indexing contract: every
// derived key IS the canonical content ID (or a range key that
// aggregates back to it), text is resolved by ID at work time, stale
// jobs are rejected without checkpoint advance, replaying a revision is
// byte-idempotent, and no default path touches the legacy chunk lane.

import Testing
import Foundation
import EngramLib
import PersistenceKit
@testable import PersistenceKitSQLite
import VectorKit
import CorpusKitProviders

@testable import CorpusKit

private final class ReindexConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    func enter() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func peakValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

private struct ReindexConcurrencyProvider: EmbeddingProvider {
    let modelID = "reindex-concurrency-probe"
    let modelVersion = "1.0.0"
    let probe: ReindexConcurrencyProbe

    func embed(_ text: String) async throws -> Engram {
        probe.enter()
        defer { probe.leave() }
        try await Task.sleep(for: .milliseconds(20))
        return .zero
    }

    func embedFloat(_ text: String) async throws -> [Float] { [1.0] }
}

private actor PublicationRaceSource: CorpusContentSource {
    private var records: [String: CorpusContentRecord]
    private var blockedID: String?
    private var blockEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(records: [CorpusContentRecord]) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func add(_ record: CorpusContentRecord) {
        records[record.id] = record
    }

    func blockNextRecord(id: String) {
        blockedID = id
        blockEntered = false
    }

    func waitUntilBlocked() async {
        if blockEntered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func releaseBlockedRecord() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        if blockedID == id {
            blockedID = nil
            blockEntered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return records[id]
    }

    func changes(since cursor: String?, limit: Int) async throws
        -> CorpusContentChangeBatch
    {
        .empty
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }
}

@Suite("CorpusContentEngine", .serialized)
struct CorpusContentEngineTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A standalone engine over a real SQLite estate: the document store
    /// is both the canonical authority and the engine's source.
    private func makeStandalone(
        indexUnit: CorpusIndexUnitPolicy = .wholeContent
    ) async throws -> (CorpusContentEngine, CorpusDocumentStore, any Storage) {
        let storage = try makeScratchStorage()
        let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: indexUnit)
#if CORPUSKIT_STANDALONE_PASSAGES
        var passages = false
        if case .tokenWindows = indexUnit { passages = true }
        try await storage.migrate(
            to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: passages))
#else
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
#endif
        let store = CorpusDocumentStore(storage: storage)
        let engine = try await CorpusContentEngine(
            storage: storage, configuration: config, source: store)
        return (engine, store, storage)
    }

    private func itemIDs(_ storage: any Storage, table: String, column: String) async throws -> Set<String> {
        let rows = try await storage.rowStore.query(
            table: table, where: nil, orderBy: [], limit: nil, offset: nil)
        var out: Set<String> = []
        for row in rows {
            if case let .text(value)? = row[column] { out.insert(value) }
        }
        return out
    }

    // MARK: - Whole-content identity

    @Test func derivedKeysAreCanonicalContentIDs() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            _ = try await store.put("The moon landing was in 1969.", id: "drawer-moon", now: now)
            _ = try await store.put("Swift actors isolate state.", id: "drawer-swift", now: now)
            try await engine.indexContent(id: "drawer-moon", now: now)
            try await engine.indexContent(id: "drawer-swift", now: now)

            // BM25 postings and vector rows are keyed by the content IDs
            // THEMSELVES — no chunk UUIDs, no translation lane.
            #expect(try await itemIDs(storage, table: "iix_doclens", column: "item_id")
                == ["drawer-moon", "drawer-swift"])
            #expect(try await itemIDs(storage, table: "vectors", column: "item_id")
                == ["drawer-moon", "drawer-swift"])

            // No legacy copy lane exists anywhere in this estate.
            await #expect(throws: (any Error).self) {
                _ = try await storage.rowStore.count(table: "chunks", where: nil)
            }

            // Recall returns the content ID directly.
            let hits = try await engine.recall("moon landing", now: now)
            #expect(hits.first?.id == "drawer-moon")
            #expect(hits.first?.evidence == nil)

            // BM25-only frontier too.
            let keyword = try await engine.bm25TopK(query: "actors isolate", limit: 5)
            #expect(keyword.first?.id == "drawer-swift")

            // Checkpoints reconcile with the canonical set.
            #expect(try await engine.indexedContentIDs() == ["drawer-moon", "drawer-swift"])
        }
    }

    // MARK: - Stale-revision safety

    @Test func staleJobIsRejectedWithoutCheckpointAdvance() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            let rev1 = try await store.put("First revision.", id: "drawer-1", now: now)
            try await engine.applyChange(
                .upsert(id: "drawer-1", revision: rev1.revision, digest: rev1.digest),
                cursor: "1", now: now)

            // The canonical store moves on to revision 2 …
            let rev2 = try await store.put("Second revision.", id: "drawer-1", now: now)

            // … so a REPLAY of the rev-1 job is stale: rejected, and the
            // checkpoint still reflects what is actually indexed (rev 1).
            await #expect(throws: CorpusKitError.self) {
                try await engine.applyChange(
                    .upsert(id: "drawer-1", revision: rev1.revision, digest: rev1.digest),
                    cursor: "9", now: now)
            }
            let checkpointAfterStale = try await CorpusIndexStateStore(storage: storage)
                .state(for: "drawer-1")
            #expect(checkpointAfterStale?.revision == rev1.revision)
            // The stale job also must not advance the feed cursor.
            #expect(try await engine.appliedFeedCursor() == "1")

            // The rev-2 job applies cleanly.
            try await engine.applyChange(
                .upsert(id: "drawer-1", revision: rev2.revision, digest: rev2.digest),
                cursor: "2", now: now)
            let checkpoint = try await CorpusIndexStateStore(storage: storage)
                .state(for: "drawer-1")
            #expect(checkpoint?.revision == rev2.revision)
            #expect(checkpoint?.digest == rev2.digest)
            #expect(try await engine.appliedFeedCursor() == "2")
        }
    }

    // MARK: - Idempotent replay

    @Test func replayingTheSameRevisionChangesNoDerivedBytes() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            let rec = try await store.put("Idempotent content.", id: "drawer-i", now: now)
            try await engine.applyChange(
                .upsert(id: "drawer-i", revision: rec.revision, digest: rec.digest),
                cursor: "1", now: now)
            let before = try await DatabaseInventory.capture(
                storage: storage,
                tables: ["iix_termfreqs", "iix_doclens", "vectors", "corpus_index_state"])

            try await engine.applyChange(
                .upsert(id: "drawer-i", revision: rec.revision, digest: rec.digest),
                cursor: "1", now: now)
            let after = try await DatabaseInventory.capture(
                storage: storage,
                tables: ["iix_termfreqs", "iix_doclens", "vectors", "corpus_index_state"])
            #expect(before == after)
        }
    }

    // MARK: - Remove

    @Test func providerAdditionAndSubtractionReconcileWithoutResidue() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("alpha provider coverage", id: "drawer-a", now: now)
            _ = try await store.put("beta provider coverage", id: "drawer-b", now: now)
            let config = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)

            let small = try await CorpusContentEngine(
                storage: storage, configuration: config, source: store,
                models: [.deterministic])
            _ = try await small.indexContentStructuralBatch(
                ids: ["drawer-a", "drawer-b"], now: now, parallelism: 2)
            try await small.reconcileConfiguredProviders(now: now)

            let big = try await CorpusContentEngine(
                storage: storage, configuration: config, source: store,
                models: [
                    .deterministic,
                    .randomIndexing(provider: RandomIndexingProvider()),
                ])
            try await big.reconcileConfiguredProviders(now: now)
            #expect(try await big.coveredCount(modelID: "random-indexing-v1") == 2)
            #expect(try await storage.rowStore.count(
                table: "corpus_provider_basis",
                where: .eq(
                    Column(table: "corpus_provider_basis", name: "model_id"),
                    .text("random-indexing-v1"))) == 1)
            #expect(try await storage.rowStore.count(
                table: "corpus_provider_counts",
                where: .eq(
                    Column(table: "corpus_provider_counts", name: "model_id"),
                    .text("random-indexing-v1"))) == 1)

            let maintainedAnchor = await big.maintainedVocabAnchor()
            #expect(maintainedAnchor > 0)
            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: config, source: store,
                models: [
                    .deterministic,
                    .randomIndexing(provider: RandomIndexingProvider()),
                ])
            try await reopened.reconcileConfiguredProviders(now: now)
            #expect(await reopened.maintainedVocabAnchor() == maintainedAnchor)

            let removed = try await CorpusContentEngine(
                storage: storage, configuration: config, source: store,
                models: [.deterministic])
            try await removed.reconcileConfiguredProviders(now: now)
            for table in ["vectors", "corpus_provider_basis", "corpus_provider_counts",
                          "corpus_provider_coverage"] {
                #expect(try await storage.rowStore.count(
                    table: table,
                    where: .eq(Column(table: table, name: "model_id"),
                               .text("random-indexing-v1"))) == 0,
                    "retired provider residue survived in \(table)")
            }
            let claims = VectorRepresentationClaims(storage: storage)
            #expect(try await claims.claims(consumer: CorpusContentEngine.claimsConsumer)
                .allSatisfy { $0.modelID != "random-indexing-v1" })

            // Replay is a no-op and cannot disturb the retained provider.
            try await removed.reconcileConfiguredProviders(now: now)
            #expect(try await removed.coveredCount(modelID: "corpus-deterministic-v1") == 2)
        }
    }

    @Test func removeClearsDerivedStateAndRecordsCursor() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            let rec = try await store.put("Removable content.", id: "drawer-r", now: now)
            try await engine.applyChange(
                .upsert(id: "drawer-r", revision: rec.revision, digest: rec.digest),
                cursor: "1", now: now)
            try await store.remove(id: "drawer-r", now: now)
            try await engine.applyChange(
                .remove(id: "drawer-r", revision: rec.revision),
                cursor: "2", now: now)

            #expect(try await itemIDs(storage, table: "iix_doclens", column: "item_id").isEmpty)
            #expect(try await itemIDs(storage, table: "vectors", column: "item_id").isEmpty)
            #expect(try await engine.indexedContentIDs().isEmpty)
            #expect(try await engine.appliedFeedCursor() == "2")

            // Recall finds nothing afterwards.
            let hits = try await engine.recall("removable content", now: now)
            #expect(hits.isEmpty)
        }
    }

    // MARK: - Queue payload

    @Test func jobPayloadCarriesNoTextAndProcessesLikeApplyChange() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, _) = try await makeStandalone()
            let rec = try await store.put("Job-driven content.", id: "drawer-q", now: now)
            let job = ContentIndexJob(
                change: .upsert(id: "drawer-q", revision: rec.revision, digest: rec.digest),
                cursor: "7")
            let payload = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
            #expect(!payload.contains("Job-driven content"))
            #expect(payload.contains("drawer-q"))

            let decoded = try JSONDecoder().decode(
                ContentIndexJob.self, from: Data(payload.utf8))
            try await engine.processJob(decoded, now: now)
            #expect(try await engine.indexedContentIDs() == ["drawer-q"])
            let hits = try await engine.recall("job-driven", now: now)
            #expect(hits.first?.id == "drawer-q")
        }
    }

    @Test func queueBatchCommitsCheckpointBeforeReplayBecomesNoOp() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            let record = try await store.put(
                "Queue checkpoint content.", id: "drawer-queue", now: now)
            let engine = try await CorpusContentEngine(
                storage: storage,
                configuration: try CorpusContentConfiguration(
                    mode: .attached, indexUnit: .wholeContent),
                source: store,
                models: [.deterministic])
            let job = ContentIndexJob(
                change: .upsert(
                    id: record.id, revision: record.revision, digest: record.digest),
                cursor: "41")

            let first = try await engine.prepareQueueJob(
                job, now: now, contentAlreadyPrepared: false)
            #expect(first.checkpoints.count == 2)
            try await engine.commitQueueBatch(
                checkpoints: first.checkpoints,
                countsUpdates: first.countsUpdate.map { [$0] } ?? [],
                now: now)
            #expect(try await engine.indexedContentIDs() == ["drawer-queue"])
            #expect(try await engine.appliedFeedCursor() == "41")

            // A terminal queue-reply failure can replay the durable reference.
            // The committed content checkpoint makes the derived work and counts
            // fold a no-op; only the idempotent feed-cursor checkpoint remains.
            let replay = try await engine.prepareQueueJob(
                job, now: now, contentAlreadyPrepared: false)
            #expect(replay.countsUpdate == nil)
            #expect(replay.checkpoints.count == 1)
            try await engine.commitQueueBatch(
                checkpoints: replay.checkpoints, countsUpdates: [], now: now)
            #expect(try await engine.indexedContentIDs() == ["drawer-queue"])
        }
    }

    @Test func queuePersistsCompactCountsReferenceAndReplaysItOnReopen() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put(
                "initial training vocabulary", id: "drawer-anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let baseBefore = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            let record = try await store.put(
                "queue delta remains reference only", id: "drawer-delta", now: now)
            let job = ContentIndexJob(
                change: .upsert(
                    id: record.id, revision: record.revision, digest: record.digest),
                cursor: "delta-1")
            let prepared = try await engine.prepareQueueJob(
                job, now: now, contentAlreadyPrepared: false)
            try await engine.commitQueueBatch(
                checkpoints: prepared.checkpoints,
                countsUpdates: prepared.countsUpdate.map { [$0] } ?? [],
                now: now)

            let baseAfter = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(baseAfter.counts == baseBefore.counts)
            // The anchor columns advance in the same transaction as the
            // reference; only the serialized base blob stays frozen.
            #expect(baseAfter.documentCount == 2)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.count == 1)
            #expect(await engine.maintainedDocumentCount() == 2)

            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            #expect(await reopened.maintainedDocumentCount() == 2)

            let replay = try await reopened.prepareQueueJob(
                job, now: now, contentAlreadyPrepared: false)
            #expect(replay.countsUpdate == nil)
            try await reopened.commitQueueBatch(
                checkpoints: replay.checkpoints, countsUpdates: [], now: now)
            #expect(await reopened.maintainedDocumentCount() == 2)

            // Provider publication compacts only this generation's pending
            // references into its replacement base, in the same transaction.
            try await reopened.trainTrainableSlots(now: now, force: true)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.isEmpty)
            let compacted = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(compacted.documentCount == 2)
            #expect(await reopened.maintainedDocumentCount() == 2)
        }
    }

    @Test func queueRemoveReaddDoesNotDoubleFoldCountsReference() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("training anchor", id: "anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)
            let countsStore = CorpusProviderCountsStore(storage: storage)

            let first = try await store.put("identity delta", id: "readd", now: now)
            let firstJob = ContentIndexJob(
                change: .upsert(id: first.id, revision: first.revision, digest: first.digest),
                cursor: "readd-1")
            let firstPrepared = try await engine.prepareQueueJob(
                firstJob, now: now, contentAlreadyPrepared: false)
            try await engine.commitQueueBatch(
                checkpoints: firstPrepared.checkpoints,
                countsUpdates: firstPrepared.countsUpdate.map { [$0] } ?? [], now: now)
            #expect(await engine.maintainedDocumentCount() == 2)

            try await store.remove(id: "readd", now: now)
            let remove = ContentIndexJob(
                change: .remove(id: "readd", revision: first.revision), cursor: "readd-2")
            let removePrepared = try await engine.prepareQueueJob(
                remove, now: now, contentAlreadyPrepared: false)
            try await engine.commitQueueBatch(
                checkpoints: removePrepared.checkpoints, countsUpdates: [], now: now)

            let second = try await store.put("identity delta", id: "readd", now: now)
            let secondJob = ContentIndexJob(
                change: .upsert(id: second.id, revision: second.revision, digest: second.digest),
                cursor: "readd-3")
            let secondPrepared = try await engine.prepareQueueJob(
                secondJob, now: now, contentAlreadyPrepared: false)
            try await engine.commitQueueBatch(
                checkpoints: secondPrepared.checkpoints,
                countsUpdates: secondPrepared.countsUpdate.map { [$0] } ?? [], now: now)

            #expect(await engine.maintainedDocumentCount() == 2)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.count == 1)
        }
    }

    @Test func queueRevisionsAdvanceRestartStableGovernorAnchors() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("training anchor vocabulary", id: "anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)
            let countsStore = CorpusProviderCountsStore(storage: storage)
            let base = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))

            let first = try await store.put(
                "identity firstnovel", id: "revision", now: now)
            let firstJob = ContentIndexJob(
                change: .upsert(
                    id: first.id, revision: first.revision, digest: first.digest),
                cursor: "revision-1")
            let firstPrepared = try await engine.prepareQueueJob(
                firstJob, now: now, contentAlreadyPrepared: false)
            #expect(firstPrepared.countsUpdate != nil)
            try await engine.commitQueueBatch(
                checkpoints: firstPrepared.checkpoints,
                countsUpdates: firstPrepared.countsUpdate.map { [$0] } ?? [], now: now)
            let firstAnchor = await engine.maintainedVocabAnchor()
            #expect(firstAnchor > base.vocabSize)
            #expect(await engine.maintainedDocumentCount() == 2)

            let second = try await store.put(
                "identity firstnovel secondnovel", id: "revision", now: now)
            let secondJob = ContentIndexJob(
                change: .upsert(
                    id: second.id, revision: second.revision, digest: second.digest),
                cursor: "revision-2")
            let secondPrepared = try await engine.prepareQueueJob(
                secondJob, now: now, contentAlreadyPrepared: false)
            #expect(secondPrepared.countsUpdate != nil)
            try await engine.commitQueueBatch(
                checkpoints: secondPrepared.checkpoints,
                countsUpdates: secondPrepared.countsUpdate.map { [$0] } ?? [], now: now)
            let secondAnchor = await engine.maintainedVocabAnchor()
            #expect(secondAnchor > firstAnchor)
            #expect(await engine.maintainedDocumentCount() == 2)

            let afterSecond = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(afterSecond.counts == base.counts)
            #expect(afterSecond.vocabSize == secondAnchor)
            let firedLive = secondAnchor - firstAnchor >= 1

            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            let reopenedAnchor = await reopened.maintainedVocabAnchor()
            #expect(reopenedAnchor == secondAnchor)
            let firedAfterReopen = reopenedAnchor - firstAnchor >= 1
            #expect(firedAfterReopen == firedLive)

            let third = try await store.put(
                "identity firstnovel secondnovel thirdnovel", id: "revision", now: now)
            let thirdJob = ContentIndexJob(
                change: .upsert(
                    id: third.id, revision: third.revision, digest: third.digest),
                cursor: "revision-3")
            let thirdPrepared = try await reopened.prepareQueueJob(
                thirdJob, now: now, contentAlreadyPrepared: false)
            #expect(thirdPrepared.countsUpdate != nil)
            try await reopened.commitQueueBatch(
                checkpoints: thirdPrepared.checkpoints,
                countsUpdates: thirdPrepared.countsUpdate.map { [$0] } ?? [], now: now)
            let thirdAnchor = await reopened.maintainedVocabAnchor()
            #expect(thirdAnchor > secondAnchor)
            #expect(await reopened.maintainedDocumentCount() == 2)

            let reopenedAgain = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            #expect(await reopenedAgain.maintainedVocabAnchor() == thirdAnchor)
            #expect(await reopenedAgain.maintainedDocumentCount() == 2)
        }
    }

    @Test func directRevisionsUseTheSameRestartStableCountsAdmission() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("direct training anchor", id: "anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)

            let first = try await store.put("direct firstnovel", id: "direct", now: now)
            try await engine.applyChange(
                .upsert(id: first.id, revision: first.revision, digest: first.digest),
                cursor: "direct-1", now: now)
            let firstAnchor = await engine.maintainedVocabAnchor()

            let second = try await store.put(
                "direct firstnovel secondnovel", id: "direct", now: now)
            try await engine.applyChange(
                .upsert(id: second.id, revision: second.revision, digest: second.digest),
                cursor: "direct-2", now: now)
            let secondAnchor = await engine.maintainedVocabAnchor()
            #expect(secondAnchor > firstAnchor)
            #expect(await engine.maintainedDocumentCount() == 2)

            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            #expect(await reopened.maintainedVocabAnchor() == secondAnchor)
            #expect(await reopened.maintainedDocumentCount() == 2)

            let third = try await store.put(
                "direct firstnovel secondnovel thirdnovel", id: "direct", now: now)
            try await reopened.applyChange(
                .upsert(id: third.id, revision: third.revision, digest: third.digest),
                cursor: "direct-3", now: now)
            let thirdAnchor = await reopened.maintainedVocabAnchor()
            #expect(thirdAnchor > secondAnchor)

            let reopenedAgain = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            #expect(await reopenedAgain.maintainedVocabAnchor() == thirdAnchor)
            #expect(await reopenedAgain.maintainedDocumentCount() == 2)
        }
    }

    @Test func directCheckpointFailureRollsBackCountsAdmission() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let sqlite = try #require(storage as? SQLiteStorage)
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("direct atomic anchor", id: "anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let before = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            let revision = try await store.put(
                "direct atomic novel vocabulary", id: "direct-atomic", now: now)

            try await sqlite.backend.connection.exec("""
                CREATE TRIGGER fail_direct_checkpoint
                BEFORE INSERT ON corpus_index_state
                BEGIN SELECT RAISE(ABORT, 'injected direct checkpoint failure'); END;
                """)
            await #expect(throws: (any Error).self) {
                try await engine.applyChange(
                    .upsert(
                        id: revision.id, revision: revision.revision,
                        digest: revision.digest),
                    cursor: "direct-atomic-1", now: now)
            }

            let afterFailure = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(afterFailure.documentCount == before.documentCount)
            #expect(afterFailure.vocabSize == before.vocabSize)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.isEmpty)
            #expect(try await CorpusIndexStateStore(storage: storage)
                .state(for: revision.id) == nil)

            try await sqlite.backend.connection.exec("DROP TRIGGER fail_direct_checkpoint;")
            try await engine.applyChange(
                .upsert(
                    id: revision.id, revision: revision.revision,
                    digest: revision.digest),
                cursor: "direct-atomic-1", now: now)
            let afterRetry = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(afterRetry.documentCount == before.documentCount + 1)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.count == 1)
            #expect(try await CorpusIndexStateStore(storage: storage)
                .state(for: revision.id)?.digest == revision.digest)
        }
    }

    @Test func concurrentAdmissionCommitsOneReferenceDelta() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            _ = try await store.put("concurrent anchor", id: "anchor", now: now)
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: store,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let before = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            let checkpoint = CorpusIndexState(
                contentID: "concurrent-admission", revision: 1,
                digest: "same-digest", indexVersion: CorpusContentEngine.indexVersion,
                appliedCursor: nil, updatedAt: now)
            let update = (
                contentID: "concurrent-admission", revision: Int64(1),
                digest: "same-digest", text: "concurrent admission vocabulary")

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try await engine.commitQueueBatch(
                            checkpoints: [checkpoint], countsUpdates: [update], now: now)
                    }
                }
                try await group.waitForAll()
            }

            let after = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(after.documentCount == before.documentCount + 1)
            #expect(try await countsStore.references(
                modelID: "random-indexing-v1", modelVersion: "1.1.0")
                .filter { !$0.isSubsumed }.count == 1)
        }
    }

    @Test func providerPublicationPreservesPostSnapshotAdmission() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let anchorText = "publication anchor"
            let anchor = CorpusContentRecord(
                id: "anchor", revision: 1,
                digest: CorpusContentDigest.digest(anchorText), text: anchorText)
            let source = PublicationRaceSource(records: [anchor])
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)

            await source.blockNextRecord(id: anchor.id)
            let retrain = Task {
                try await engine.trainTrainableSlots(now: now, force: true)
            }
            await source.waitUntilBlocked()

            let lateText = "post snapshot vocabulary"
            let late = CorpusContentRecord(
                id: "late", revision: 1,
                digest: CorpusContentDigest.digest(lateText), text: lateText)
            await source.add(late)
            let admission = Task {
                try await engine.applyChange(
                    .upsert(id: late.id, revision: late.revision, digest: late.digest),
                    cursor: nil, now: now)
            }
            try await Task.sleep(for: .milliseconds(50))
            await source.releaseBlockedRecord()
            _ = try await retrain.value
            try await admission.value

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let after = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(after.documentCount == 2)
            #expect(try await countsStore.referenceFor(
                modelID: "random-indexing-v1", modelVersion: "1.1.0",
                contentID: late.id)?.digest == late.digest)
        }
    }

    @Test func providerPublicationDoesNotRefoldPreSnapshotPendingAdmission() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let anchorText = "publication anchor"
            let anchor = CorpusContentRecord(
                id: "anchor", revision: 1,
                digest: CorpusContentDigest.digest(anchorText), text: anchorText)
            let source = PublicationRaceSource(records: [anchor])
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)
            try await engine.applyChange(
                .upsert(
                    id: anchor.id, revision: anchor.revision,
                    digest: anchor.digest),
                cursor: nil, now: now)

            // The canonical record is visible before the retrain snapshot, but
            // its queue/direct admission has not committed. The replacement
            // base therefore already contains it when that admission resumes.
            let pendingText = "pre snapshot pending vocabulary"
            let pending = CorpusContentRecord(
                id: "pending", revision: 1,
                digest: CorpusContentDigest.digest(pendingText), text: pendingText)
            await source.add(pending)

            await source.blockNextRecord(id: anchor.id)
            let retrain = Task {
                try await engine.trainTrainableSlots(now: now, force: true)
            }
            await source.waitUntilBlocked()
            let admission = Task {
                try await engine.applyChange(
                    .upsert(
                        id: pending.id, revision: pending.revision,
                        digest: pending.digest),
                    cursor: nil, now: now)
            }
            try await Task.sleep(for: .milliseconds(50))
            await source.releaseBlockedRecord()
            _ = try await retrain.value
            try await admission.value

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let after = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(after.documentCount == 2)
            #expect(try await countsStore.referenceFor(
                modelID: "random-indexing-v1", modelVersion: "1.1.0",
                contentID: pending.id) == nil)
            #expect(try await CorpusIndexStateStore(storage: storage)
                .state(for: pending.id)?.digest == pending.digest)

            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            #expect(await reopened.maintainedDocumentCount() == 2)
        }
    }

    @Test func providerPublicationMarkerSurvivesReopenBeforeAdmission() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let text = "published before delayed admission"
            let pending = CorpusContentRecord(
                id: "pending-reopen", revision: 1,
                digest: CorpusContentDigest.digest(text), text: text)
            let source = PublicationRaceSource(records: [pending])
            let configuration = try CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent)
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await engine.trainTrainableSlots(now: now)
            // A public counts compaction must retain the marker because the
            // matching admission/checkpoint is still pending.
            try await engine.persistCountsSnapshot(now: now)

            let countsStore = CorpusProviderCountsStore(storage: storage)
            #expect(try await countsStore.referenceFor(
                modelID: "random-indexing-v1", modelVersion: "1.1.0",
                contentID: pending.id)?.isSubsumed == true)

            let reopened = try await CorpusContentEngine(
                storage: storage, configuration: configuration, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await reopened.applyChange(
                .upsert(
                    id: pending.id, revision: pending.revision,
                    digest: pending.digest),
                cursor: nil, now: now)

            let after = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(after.documentCount == 1)
            #expect(try await countsStore.referenceFor(
                modelID: "random-indexing-v1", modelVersion: "1.1.0",
                contentID: pending.id) == nil)
            #expect(await reopened.maintainedDocumentCount() == 1)
        }
    }

    // MARK: - Standalone passages

#if CORPUSKIT_STANDALONE_PASSAGES
    @Test func passageWindowsUseTokenOverlapDeterministically() {
        let text = "one two three four five six seven"
        let ranges = PassageProduction.passageRanges(
            text: text, windowTokens: 4, overlapTokens: 2)
        let bytes = Array(text.utf8)
        let excerpts = ranges.map {
            String(decoding: bytes[$0.utf8Start..<($0.utf8Start + $0.utf8Length)], as: UTF8.self)
        }
        #expect(excerpts == [
            "one two three four",
            "three four five six",
            "five six seven",
        ])
    }

    @Test func passagePolicyIsBoundPerStandaloneDatabase() async throws {
        let first = try makeScratchStorage()
        try await first.migrate(
            to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: true))
        let firstPolicy = CorpusIndexUnitPolicy.tokenWindows(
            windowTokens: 512, overlapTokens: 64)
        let firstAuthority = CorpusIndexConfigurationStore(storage: first)
        try await firstAuthority.bind(firstPolicy)
        try await firstAuthority.bind(firstPolicy) // reopen-idempotent
        #expect(try await firstAuthority.fingerprint()
            == "token-windows-v1:corpus-alphanumeric-v1:512:64")
        await #expect(throws: CorpusKitError.self) {
            try await firstAuthority.bind(
                .tokenWindows(windowTokens: 256, overlapTokens: 32))
        }

        // A different standalone database owns an independent policy.
        let second = try makeScratchStorage()
        try await second.migrate(
            to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: true))
        let secondAuthority = CorpusIndexConfigurationStore(storage: second)
        try await secondAuthority.bind(
            .tokenWindows(windowTokens: 256, overlapTokens: 32))
        #expect(try await secondAuthority.fingerprint()
            == "token-windows-v1:corpus-alphanumeric-v1:256:32")

        // An unbound pre-feature database with existing whole-content state
        // cannot silently reinterpret those rows as passages.
        let existing = try makeScratchStorage()
        try await existing.migrate(
            to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: true))
        _ = try await existing.rowStore.insert(table: "iix_doclens", values: [
            "item_id": .text("existing-doc"), "length": .int(10),
        ])
        let existingAuthority = CorpusIndexConfigurationStore(storage: existing)
        await #expect(throws: CorpusKitError.self) {
            try await existingAuthority.bind(
                .tokenWindows(windowTokens: 128, overlapTokens: 16))
        }
    }

    @Test func passageModeIndexesRangesAndAggregatesToContentID() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone(
                indexUnit: .tokenWindows(windowTokens: 6, overlapTokens: 2))
            let text = "alpha beta gamma delta epsilon zeta " // 6 tokens (passage 1)
                + "eta theta iota kappa lambda mu "          // 6 tokens (passage 2)
                + "nu xi omicron"                            // 3 tokens (passage 3)
            let rec = try await store.put(text, id: "doc-p", now: now)
            try await engine.applyChange(
                .upsert(id: "doc-p", revision: rec.revision, digest: rec.digest),
                cursor: "1", now: now)

            // Range rows exist, hold NO text, and are revision-bound.
            let passageRows = try await storage.rowStore.query(
                table: "corpus_passages", where: nil, orderBy: [], limit: nil, offset: nil)
            #expect(passageRows.count == 4)
            for row in passageRows {
                #expect(row["text"] == nil)
                if case let .int(revision)? = row["revision"] {
                    #expect(revision == rec.revision)
                }
            }

            // Derived keys are passage keys that PARSE back to the content
            // ID — never a second identity.
            let bmKeys = try await itemIDs(storage, table: "iix_doclens", column: "item_id")
            #expect(bmKeys.count == 4)
            for key in bmKeys {
                #expect(IndexUnitIdentity.contentID(fromItemKey: key) == "doc-p")
            }

            // Recall aggregates to ONE hit whose identity is the content
            // ID, with the best passage as range evidence.
            let hits = try await engine.recall("lambda mu", now: now)
            #expect(hits.count == 1)
            #expect(hits.first?.id == "doc-p")
            let evidence = try #require(hits.first?.evidence)
            let utf8 = Array(text.utf8)
            let excerpt = String(
                decoding: utf8[evidence.utf8Start..<(evidence.utf8Start + evidence.utf8Length)],
                as: UTF8.self)
            #expect(excerpt.contains("lambda"))

            // Re-putting changed text replaces the passage set — no stale
            // revision-1 keys survive.
            let rec2 = try await store.put("totally new words here", id: "doc-p", now: now)
            try await engine.applyChange(
                .upsert(id: "doc-p", revision: rec2.revision, digest: rec2.digest),
                cursor: "2", now: now)
            let freshKeys = try await itemIDs(storage, table: "iix_doclens", column: "item_id")
            #expect(freshKeys.count == 1)
            for key in freshKeys {
                #expect(key.contains("\u{1F}\(rec2.revision)\u{1F}"))
            }
        }
    }
#endif

    // MARK: - Attached mode

    @Test func attachedEngineOpensWithoutContentTablesAndReturnsDrawerIDs() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let config = try CorpusContentConfiguration(mode: .attached, indexUnit: .wholeContent)
            // The adapter stand-in: content canonical OUTSIDE CorpusKit.
            let adapter = StaticContentSource(records: [
                CorpusContentRecord(
                    id: "drawer-a", revision: 1,
                    digest: CorpusContentDigest.digest("Attached drawer content about llamas."),
                    text: "Attached drawer content about llamas."),
                CorpusContentRecord(
                    id: "drawer-b", revision: 1,
                    digest: CorpusContentDigest.digest("Another drawer about compilers."),
                    text: "Another drawer about compilers.")
            ])
            let engine = try await CorpusContentEngine(
                storage: storage, configuration: config, source: adapter)
            try await engine.indexContent(id: "drawer-a", now: now)
            try await engine.indexContent(id: "drawer-b", now: now)

            // No canonical content table of ANY kind in the attached estate.
            for table in ["corpus_documents", "chunks", "corpus_metadata", "corpus_passages"] {
                await #expect(throws: (any Error).self) {
                    _ = try await storage.rowStore.count(table: table, where: nil)
                }
            }

            let hits = try await engine.recall("llamas", now: now)
            #expect(hits.first?.id == "drawer-a")
        }
    }

    // MARK: - Claims

    @Test func engineClaimsItsRepresentations() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            _ = try await store.put("Claimed content.", id: "drawer-c", now: now)
            try await engine.indexContent(id: "drawer-c", now: now)

            let claims = VectorRepresentationClaims(storage: storage)
            let claimed = try await claims.claims(consumer: CorpusContentEngine.claimsConsumer)
            #expect(claimed.contains(VectorRepresentationKey(
                modelID: "corpus-deterministic-v1", modelVersion: "1.0.0", vectorIndex: 0)))
            #expect(claimed.contains(VectorRepresentationKey(
                modelID: "corpus-deterministic-v1", modelVersion: "1.0.0", vectorIndex: 1)))
        }
    }

    // MARK: - Reindex

    @Test func providerTrainingParallelismUsesAvailableCPUWithinMemoryBudget() {
        let roomy = CorpusContentEngine.providerTrainingParallelism(
            contentCount: 2_000,
            providerCount: 4,
            environment: [:],
            physicalMemory: 128 * 1_024 * 1_024 * 1_024,
            processorCount: 18)
        #expect(roomy == 4)

        let constrained = CorpusContentEngine.providerTrainingParallelism(
            contentCount: 98_118,
            providerCount: 4,
            environment: [:],
            physicalMemory: 16 * 1_024 * 1_024 * 1_024,
            processorCount: 18)
        #expect(constrained == 1)
    }

    @Test func reindexReindexesEveryActiveContentRow() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone()
            _ = try await store.put("Alpha doc.", id: "a", now: now)
            _ = try await store.put("Beta doc.", id: "b", now: now)
            try await engine.reindex(now: now)
            #expect(try await engine.indexedContentIDs() == ["a", "b"])
            // Reindex is a FORCED rewrite (a retrain changes the basis), so
            // the surrogate vector row ids churn; logical bytes — keys,
            // payloads, postings — are identical for unchanged content.
            let exclusions = ["vectors": Set(["id"])]
            let before = try await DatabaseInventory.capture(
                storage: storage, tables: ["iix_termfreqs", "iix_doclens", "vectors"],
                excludingColumns: exclusions)
            try await engine.reindex(now: now)
            let after = try await DatabaseInventory.capture(
                storage: storage, tables: ["iix_termfreqs", "iix_doclens", "vectors"],
                excludingColumns: exclusions)
            #expect(before == after)
        }
    }

    @Test func wholeContentReindexUsesBoundedParallelEmbeddingPreparation() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            for index in 0..<12 {
                _ = try await store.put(
                    "parallel reindex content \(index)", id: "parallel-\(index)", now: now)
            }
            let probe = ReindexConcurrencyProbe()
            let engine = try await CorpusContentEngine(
                storage: storage,
                configuration: try CorpusContentConfiguration(
                    mode: .attached, indexUnit: .wholeContent),
                source: store,
                models: [.fdc(provider: ReindexConcurrencyProvider(probe: probe))])

            try await engine.reindex(now: now)

            let bound = max(1, ProcessInfo.processInfo.activeProcessorCount)
            #expect(probe.peakValue() <= bound)
            if bound > 1 {
                #expect(probe.peakValue() > 1)
            }
            #expect(try await engine.indexedContentIDs().count == 12)
        }
    }

    /// Structural equivalence: `drainContentQueueOnce` must use bounded parallel
    /// embedding preparation (the fan-out restored by fix-fanout, Cause 1).
    ///
    /// Proof:
    ///   1. Concurrency probe: peak concurrent embed workers > 1 on multi-core
    ///      hardware, bounded by activeProcessorCount.
    ///   2. Output equivalence: all enqueued content IDs are indexed
    ///      (`indexedContentIDs` matches the enqueued set).
    ///
    /// The `ReindexConcurrencyProvider` sleeps 20ms per `embed` call — serial
    /// execution of 12 docs takes ≥240ms; parallel takes ~20ms. The sleep makes
    /// the concurrency window wide enough that the probe reliably observes
    /// concurrent entry even under `nice -n 19` scheduling pressure.
    @Test func queueDrainUsesBoundedParallelEmbeddingPreparation() async throws {
        try await GlobalTestLock.shared.withLock {
            // Build 12-document store — enough to exercise ≥ 2 concurrent
            // workers on any multi-core machine.
            //
            // Use a per-test isolated subdirectory so the DrainLease file
            // (encode.drain.lease) does not collide with concurrent suites
            // that also use SQLite-backed estates in the shared temp directory.
            let testDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("qdrain-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: testDir) }
            let dbURL = testDir.appendingPathComponent("corpus.sqlite3")
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)
            var records: [CorpusContentRecord] = []
            for index in 0..<12 {
                let record = try await store.put(
                    "queue drain parallel content \(index)",
                    id: "qdrain-\(index)", now: now)
                records.append(record)
            }

            // Instrument with the concurrency probe provider.
            let probe = ReindexConcurrencyProbe()
            let engine = try await CorpusContentEngine(
                storage: storage,
                configuration: try CorpusContentConfiguration(
                    mode: .attached, indexUnit: .wholeContent),
                source: store,
                models: [.fdc(provider: ReindexConcurrencyProvider(probe: probe))])

            // Mount queue, enqueue all 12 change references, then drain.
            // All 12 jobs land in the queue before the drain worker starts,
            // so drainIndexBatch receives them as one batch and fans them out.
            try await engine.mountIngestQueue()
            for record in records {
                try await engine.enqueueChange(
                    .upsert(id: record.id, revision: record.revision,
                            digest: record.digest),
                    cursor: nil, capturedAt: now)
            }
            try await engine.awaitIngestDrain()

            // Proof 1: bounded concurrency.
            let bound = max(1, ProcessInfo.processInfo.activeProcessorCount)
            #expect(probe.peakValue() <= bound,
                    "peak concurrent workers must not exceed activeProcessorCount")
            if bound > 1 {
                let peak = probe.peakValue()
                #expect(peak > 1,
                        "queue drain must use multiple concurrent embed workers (peakValue=\(peak), bound=\(bound))")
            }

            // Proof 2: output equivalence — all 12 IDs indexed by the parallel path.
            let indexed = try await engine.indexedContentIDs()
            #expect(Set(indexed) == Set(records.map(\.id)),
                    "all 12 enqueued content IDs must appear in indexedContentIDs after drain")

            await engine.dropIngestQueue()
        }
    }

    // MARK: - §12 Three-state basis — non-degeneracy under per-doc queue drain

    /// 20 docs split evenly between cars and animals. Distinct vocabularies let
    /// a well-trained LSA basis separate them; a rank-1 car-only basis would
    /// leave all animal terms OOV.
    private let lsaCarDocs: [String] = (1...10).map {
        "car engine fuel road vehicle drive speed combustion power auto document \($0)"
    }
    private let lsaAnimalDocs: [String] = (1...10).map {
        "dog cat bark fetch run animal pet fur forest wild document \($0)"
    }

    /// REGRESSION TEST — fails on code with degenerate-basis bug, passes after fix.
    ///
    /// Simulates the "impatient inline encoding" path (GLK 1.1.x): each document
    /// is stored then immediately enqueued and drained before the next is stored.
    ///
    /// Without the three-state retrain fix:
    ///   - Drain 1 trains on 1 car doc → rank-1 SVD with car-only vocabulary.
    ///   - All subsequent docs fold onto this basis → degenerate.
    ///   - "dog bark fetch animal" is all-OOV → floatNearest returns .unavailableNoVocabHit.
    ///
    /// With the fix, growth retrains fire at corpus doublings (2, 4, 8, 16 docs)
    /// until the basis is stable at `perDocAutoRetrainStableChunkThreshold = 50`.
    /// The retrain at doc 16 covers 10 car + 6 animal docs → vocabulary is present.
    ///
    /// This is the CorpusContentEngine equivalent of
    /// BasisPersistenceTests.perDocIngestProducesNonDegenerateBasis.
    @Test("per-doc queue drain of 20 docs produces a non-degenerate LSA basis (REGRESSION)")
    func perDocQueueDrainProducesNonDegenerateBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            // Unique subdirectory prevents DrainLease collision with other test suites
            // that share the system temp directory.
            let testDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("perDocBasis-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: testDir) }
            let dbURL = testDir.appendingPathComponent("corpus.sqlite3")

            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            // corpus_documents table — attachedDeclaration intentionally excludes it.
            try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
            let store = CorpusDocumentStore(storage: storage)

            let engine = try await CorpusContentEngine(
                storage: storage,
                configuration: try CorpusContentConfiguration(
                    mode: .attached, indexUnit: .wholeContent),
                source: store,
                models: [.lsa(provider: LsaProvider())])

            try await engine.mountIngestQueue()

            // Ingest 20 docs ONE AT A TIME (the impatient path). Without the
            // growth-retrain fix, drain 1 trains on 1 car doc and the basis
            // stays rank-1 for the remaining 19 drains.
            let allDocs = lsaCarDocs + lsaAnimalDocs
            for (i, doc) in allDocs.enumerated() {
                let category = i < 10 ? "car" : "animal"
                let record = try await store.put(
                    doc,
                    id: "\(category)-\(i)",
                    now: now.addingTimeInterval(TimeInterval(i)))
                try await engine.enqueueChange(
                    .upsert(id: record.id, revision: record.revision,
                            digest: record.digest),
                    cursor: nil,
                    capturedAt: now.addingTimeInterval(TimeInterval(i)))
                // Drain this single doc before the next is stored — the impatient path.
                // awaitIngestDrain blocks until the queue is empty and publishes the
                // resident vector index, so subsequent queries are coherent.
                try await engine.awaitIngestDrain(timeout: .seconds(60))
            }

            // After 20 per-doc drains the growth-retrain path must have trained on
            // ≥16 docs (last doubling fires when corpus reaches 16). Animal vocabulary
            // is present from doc 10 onward; a degenerate 1-doc basis would return
            // .unavailableNoVocabHit.
            let animalQuery = await engine.floatNearest(
                query: "dog bark fetch animal", limit: 5)
            guard case .hits(let animalHits) = animalQuery else {
                Issue.record("""
                    animal query returned a dark outcome (\(animalQuery)) — basis \
                    is degenerate (animal vocabulary absent). Expected .hits from a \
                    non-degenerate 20-doc LSA basis after growth-retrain fires.
                    """)
                await engine.dropIngestQueue()
                return
            }
            let hasAnimalDoc = animalHits.prefix(5).contains {
                $0.itemID.hasPrefix("animal-")
            }
            #expect(hasAnimalDoc,
                    "animal query must retrieve an animal doc from the non-degenerate 20-doc basis")

            await engine.dropIngestQueue()
        }
    }

    // MARK: - §13 Three-state basis — reindex recovery (CorpusContentEngine)

    /// REGRESSION TEST — CorpusContentEngine analogue of
    /// BasisPersistenceTests.reindexRecoversDegenerateBasis.
    ///
    /// Flow:
    ///   1. Batch-ingest 20 docs via queue → firstIngestTrainIfNeeded trains on
    ///      the full corpus on the first drain pass → trainedChunkCount == 20.
    ///   2. Overwrite the basis in BasisStore with a 1-doc-trained degenerate blob.
    ///   3. Reopen CorpusContentEngine — resolveProvider loads the degenerate basis.
    ///   4. Confirm degenerate state: animal query is OOV (dark outcome).
    ///   5. Call engine.reindex(now:) — trainTrainableSlots(force: true) retrains
    ///      on ALL active source content.
    ///   6. Confirm recovery: trainedChunkCount == 20 and animal query returns hits.
    @Test("CorpusContentEngine.reindex recovers a deliberately-degenerate LSA basis")
    func contentEngineReindexRecoversDegenerateBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let testDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cceReindex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: testDir) }
            let dbURL = testDir.appendingPathComponent("corpus.sqlite3")
            let lsaModelID = "lsa-v1"
            let lsaModelVersion = "1.1.0"
            let allDocs = lsaCarDocs + lsaAnimalDocs

            // Phase 1: batch-ingest all 20 docs.
            // All docs are stored before any drain fires, so firstIngestTrainIfNeeded
            // sees 20 source content IDs on its first call → trains on the full corpus.
            do {
                let storage1 = try SQLiteStorage(configuration: EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
                try await storage1.migrate(to: CorpusDocumentStore.schemaDeclaration)
                let store1 = CorpusDocumentStore(storage: storage1)
                let engine1 = try await CorpusContentEngine(
                    storage: storage1,
                    configuration: try CorpusContentConfiguration(
                        mode: .attached, indexUnit: .wholeContent),
                    source: store1,
                    models: [.lsa(provider: LsaProvider())])

                var changes: [(change: CorpusContentChange, cursor: String?,
                                capturedAt: Date)] = []
                for (i, doc) in allDocs.enumerated() {
                    let cat = i < 10 ? "car" : "animal"
                    let record = try await store1.put(
                        doc, id: "\(cat)-\(i)",
                        now: now.addingTimeInterval(TimeInterval(i)))
                    changes.append((
                        change: .upsert(id: record.id, revision: record.revision,
                                        digest: record.digest),
                        cursor: nil,
                        capturedAt: now.addingTimeInterval(TimeInterval(i))))
                }
                try await engine1.mountIngestQueue()
                try await engine1.enqueueChangeBatch(changes)
                try await engine1.awaitIngestDrain()
                await engine1.dropIngestQueue()

                let basisStore1 = BasisStore(storage: storage1)
                let goodBasis = try await basisStore1.load(
                    modelID: lsaModelID, modelVersion: lsaModelVersion)
                #expect(goodBasis?.trainedChunkCount == allDocs.count,
                        "batch ingest must train on the full 20-doc corpus")
            }
            // storage1, store1, engine1 go out of scope here — connections released.

            // Phase 2: inject a degenerate (1-doc-trained) basis.
            // The 1-doc blob has only car vocabulary; animal terms are OOV.
            let degradedBlob: Data = {
                let p = LsaProvider()
                p.trainOnCorpus(texts: [allDocs[0]])    // car-only vocabulary
                return p.serializeBasis()
            }()
            do {
                let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
                let basisStore2 = BasisStore(storage: storage2)
                try await basisStore2.upsert(PersistedBasis(
                    modelID: lsaModelID, modelVersion: lsaModelVersion,
                    basis: degradedBlob, trainedAt: now, trainedChunkCount: 1))
            }

            // Phase 3: reopen — resolveProvider loads the degenerate basis from BasisStore.
            let storage3 = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            let store3 = CorpusDocumentStore(storage: storage3)
            let engine3 = try await CorpusContentEngine(
                storage: storage3,
                configuration: try CorpusContentConfiguration(
                    mode: .attached, indexUnit: .wholeContent),
                source: store3,
                models: [.lsa(provider: LsaProvider())])

            // Phase 4: confirm degenerate state. Animal terms OOV → dark outcome.
            let animalBefore = await engine3.floatNearest(
                query: "dog bark fetch animal", limit: 5)
            let isDark: Bool
            switch animalBefore {
            case .unavailableNoVocabHit, .unavailableProviderOptOut,
                 .unavailableNoFloatRows:
                isDark = true
            default:
                isDark = false
            }
            #expect(isDark,
                    "animal query must be dark before reindex — degenerate 1-doc basis has no animal vocabulary")

            // Phase 5: reindex retrains on the full corpus.
            try await engine3.reindex(now: now.addingTimeInterval(100))

            // Phase 6: verify recovery — basis now covers all 20 docs.
            let basisStore3 = BasisStore(storage: storage3)
            let reindexedBasis = try await basisStore3.load(
                modelID: lsaModelID, modelVersion: lsaModelVersion)
            #expect(reindexedBasis?.trainedChunkCount == allDocs.count,
                    "reindex must retrain on the full 20-doc corpus")

            let animalAfter = await engine3.floatNearest(
                query: "dog bark fetch animal", limit: 5)
            guard case .hits(let animalHits) = animalAfter else {
                Issue.record("""
                    animal query still dark after reindex (\(animalAfter)). \
                    reindex must restore full vocabulary so animal terms are \
                    in-vocabulary and animal docs rank in results.
                    """)
                return
            }
            let hasAnimalDoc = animalHits.prefix(5).contains {
                $0.itemID.hasPrefix("animal-")
            }
            #expect(hasAnimalDoc,
                    "animal doc must rank in top-5 after reindex on the full 20-doc corpus")
        }
    }
}

// MARK: - Static attached-source stand-in

private struct StaticContentSource: CorpusContentSource {
    let records: [CorpusContentRecord]

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        records.first { $0.id == id }
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        .empty
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.map(\.id).sorted()
    }
}
