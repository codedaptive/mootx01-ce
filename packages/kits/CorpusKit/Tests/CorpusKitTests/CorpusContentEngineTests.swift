#if MOOTX01_DENSE_FAMILIES
// Dense-family test — compiled only when DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See Package.swift.
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
import SynapseKit
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

    /// Bounded version: polls `blockEntered` with 10 ms intervals until the
    /// source enters the blocked state or the deadline expires. The actor
    /// releases isolation during each sleep interval so the retrain task can
    /// call `record(for:)` and set `blockEntered = true`.
    ///
    /// Throws `WaitTimedOut` with a clear message instead of hanging the suite.
    func waitUntilBlockedBounded(timeout: Duration = .seconds(5)) async throws {
        struct WaitTimedOut: Error, CustomStringConvertible {
            var description: String {
                "waitUntilBlockedBounded: source did not enter blocked state within timeout — " +
                "check that blockNextRecord was called with the correct ID and the " +
                "retrain task was started"
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if blockEntered { return }
            // Sleep releases actor isolation, allowing the retrain task to call
            // record(for:) and set blockEntered = true before the next check.
            try await Task.sleep(for: .milliseconds(10))
        }
        guard blockEntered else { throw WaitTimedOut() }
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

            // Corrected routing: an empty-pending force retrain takes the counts
            // path and pages nothing — waitUntilBlocked() would never fire and the
            // suite hangs. This test exercises the corpus-path publication race
            // window, so a non-subsumed pending delta must exist before the force
            // retrain. Updating the anchor to revision 2 creates that pending
            // reference; RI's deltaNotFoldSafe guard then routes to the corpus
            // path, restoring the blocking behaviour the test depends on.
            let anchorV2Text = "publication anchor revised"
            let anchorV2 = CorpusContentRecord(
                id: anchor.id, revision: 2,
                digest: CorpusContentDigest.digest(anchorV2Text), text: anchorV2Text)
            await source.add(anchorV2)
            try await engine.applyChange(
                .upsert(id: anchor.id, revision: 2, digest: anchorV2.digest),
                cursor: nil, now: now)

            await source.blockNextRecord(id: anchor.id)
            let retrain = Task {
                try await engine.trainTrainableSlots(now: now, force: true)
            }
            // Bounded wait: fails with a clear message after 5 s instead of
            // hanging the suite if the retrain task never reaches the blocked record.
            try await source.waitUntilBlockedBounded()

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
            // After the corpus-path retrain (anchor only) and the subsequent
            // growth settle (which trains anchor v2 + late), the post-snapshot
            // admission is incorporated into the corpus. The settled basis means
            // no pending reference row remains for late — instead verify that the
            // admission was preserved by checking the index state carries the
            // correct digest.
            #expect(try await CorpusIndexStateStore(storage: storage)
                .state(for: late.id)?.digest == late.digest)
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
            // Bounded wait: fails with a clear message after 5 s instead of
            // hanging the suite if the retrain task never reaches the blocked record.
            try await source.waitUntilBlockedBounded()
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

// MARK: - Mutable attached-source for counts-path tests

/// Actor-isolated, mutable source for tests that need to add/remove records
/// or make a specific ID transiently return nil (simulating F-6 / G-6a).
private actor MutableAttachedSource: CorpusContentSource {
    /// Active record set — record(for:) probes this dictionary.
    private var records: [CorpusContentID: CorpusContentRecord] = [:]
    /// IDs listed in activeContentIDs() regardless of whether they resolve.
    /// Populated separately so tests can list an ID without making it resolvable.
    private var listedIDs: [CorpusContentID] = []

    /// Add a record AND list its ID.
    func addResolvable(_ r: CorpusContentRecord) {
        records[r.id] = r
        if !listedIDs.contains(r.id) { listedIDs.append(r.id) }
    }

    /// List an ID without making it resolvable (sentinel scenario).
    func listUnresolvable(id: CorpusContentID) {
        if !listedIDs.contains(id) { listedIDs.append(id) }
    }

    /// Remove a record from both the dictionary and the listed set.
    func remove(id: CorpusContentID) {
        records.removeValue(forKey: id)
        listedIDs.removeAll { $0 == id }
    }

    /// Update an existing record's revision/digest (revision scenario).
    func update(_ r: CorpusContentRecord) {
        records[r.id] = r
    }

    /// Cumulative count of record(for:) calls — used by F-1 two-directional gate
    /// to verify bodies paged during counts-path trains.
    private var recordFetchCount = 0

    /// Returns the current fetch count since the last resetFetchCount() call.
    func fetchCount() -> Int { recordFetchCount }

    /// Resets the fetch counter to zero. Call immediately before the train call
    /// under measurement so only that train's fetches are counted.
    func resetFetchCount() { recordFetchCount = 0 }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        recordFetchCount += 1
        return records[id]
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        .empty
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        listedIDs.sorted()
    }
}

// MARK: - Gate G-5a / G-5a-RI / G-5b / G-6a / G-6f (counts-path decision seam)

extension CorpusContentEngineTests {

    // Helper: build an attached engine over scratch storage with the given models.
    private func makeAttachedEngine(
        storage: any Storage,
        source: any CorpusContentSource,
        models: [EmbeddingModel]
    ) async throws -> CorpusContentEngine {
        let config = try CorpusContentConfiguration(mode: .attached, indexUnit: .wholeContent)
        try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
        return try await CorpusContentEngine(
            storage: storage, configuration: config,
            source: source, models: models)
    }

    // Helper: helper digest function for test content.
    private func testDigest(_ s: String) -> String {
        CorpusContentDigest.digest(Data(s.utf8))
    }

    // MARK: - G-5a: PPMI positive delta-fold

    /// Gate G-5a: when a PPMI engine has a persisted basis, a counts row, and M
    /// pending (non-subsumed) reference rows that match the population guard, the
    /// next `trainTrainableSlots` call must take the COUNTS PATH and record
    /// `.countsDeltaFold(folded: M)`. The resulting digest must equal a from-
    /// scratch PPMI trained on all base + delta texts.
    @Test("G-5a: PPMI counts-path records countsDeltaFold and digest matches from-scratch twin")
    func ppmiCountsPathDeltaFold() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()

            // Three base documents.
            let baseDocs: [CorpusContentRecord] = [
                .init(id: "g5a-1", revision: 1, digest: testDigest("g5a-1v1"),
                      text: "the cat sat on the mat quietly"),
                .init(id: "g5a-2", revision: 1, digest: testDigest("g5a-2v1"),
                      text: "the dog ran across the open field"),
                .init(id: "g5a-3", revision: 1, digest: testDigest("g5a-3v1"),
                      text: "rivers flow gently towards the sea"),
            ]
            for doc in baseDocs { await source.addResolvable(doc) }

            let engine = try await makeAttachedEngine(
                storage: storage, source: source, models: [.ppmi(provider: PpmiProvider())])

            // Base docs are already in source via addResolvable; we do NOT call
            // applyChange for them. On a young basis (trainedChunkCount < 50),
            // applyChange triggers firstIngestTrainIfNeeded (on the first doc) and
            // then settleYoungBasisIfGrown (on every subsequent doc), creating the
            // basis before the explicit force-train runs. The force-train would then
            // see an existing basis and not record firstTrain. Leaving applyChange
            // uncalled lets the explicit force-train below be the true firstTrain:
            // source.activeContentIDs() returns all five IDs, the corpus path trains
            // on the three resolvable base docs and writes sentinel refs for the two
            // unresolvable delta IDs, and the decision seam records firstTrain. The
            // base docs receive subsumed reference rows (indexed state = nil at that
            // point, so prepareProviderTraining treats them as newly-covered) that
            // are required for the population guard on the subsequent countsDeltaFold.

            // Two delta IDs listed but transiently unresolvable during the first train.
            // The corpus-path publication writes non-subsumed sentinel rows for them.
            // We do NOT call applyChange for the delta docs either: on a young basis,
            // doing so would trigger settleYoungBasisIfGrown (indexedCount > trainedChunkCount)
            // and absorb the delta into the base before the explicit counts-path train runs.
            let deltaDocs: [CorpusContentRecord] = [
                .init(id: "g5a-4", revision: 1, digest: testDigest("g5a-4v1"),
                      text: "machines learn patterns from large datasets"),
                .init(id: "g5a-5", revision: 1, digest: testDigest("g5a-5v1"),
                      text: "neural networks approximate complex functions"),
            ]
            await source.listUnresolvable(id: "g5a-4")
            await source.listUnresolvable(id: "g5a-5")

            // Force-train: no basis row → firstTrain → corpus path.
            // g5a-1..3 resolve (subsumed); g5a-4..5 nil → sentinel rows written.
            // trainedChunkCount = 3; allIDs = 5; pending = 2 sentinels.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.firstTrain),
                    "first force-train with no prior basis must take corpus path (firstTrain)")

            // Make the delta docs resolvable WITHOUT calling applyChange.
            // Calling applyChange would increment indexedCount and trigger
            // settleYoungBasisIfGrown (4 > trainedChunkCount 3) — absorbing g5a-4 into
            // the base before the explicit non-forced train runs. The sentinels are
            // already non-subsumed pending refs; source.record(for:) now returns the
            // real records when the delta fold queries them.
            for doc in deltaDocs { await source.addResolvable(doc) }

            // F-1 two-directional gate: reset counter immediately before the measured
            // train call so only this call's record fetches are counted.
            await source.resetFetchCount()

            // Force-retrain (drift path): basis + counts row exist; 2 sentinel pending
            // refs; population guard: trainedChunkCount(3) + pending(2) == allIDs(5)
            // → counts path. force==true is required — the drift gate owns when a
            // retrain fires; a non-force call on a trained slot is skipped.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            let decision = await engine._trainingPathDecision(for: "ppmi-v1")
            #expect(decision == .countsDeltaFold(folded: 2),
                    "two sentinel pending refs delta-folded must record countsDeltaFold(2)")
            // F-1 two-directional gate: bodies paged must equal the folded pending count
            // (or zero on restore) — measured, not inferred.
            #expect(await source.fetchCount() == 2,
                    "F-1 two-directional gate: delta-fold of 2 pending refs must page exactly 2 bodies — measured, not inferred")

            // Non-force call on a trained slot: skip semantics — decision seam records
            // nothing (nil). The drift gate, not the train entry point, decides when a
            // retrain fires.
            _ = try await engine.trainTrainableSlots(now: now)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1") == nil,
                    "non-force call on a trained slot must be skipped — no decision recorded")

            // From-scratch twin: PPMI trained on all 5 texts in source order.
            let allDocs = baseDocs + deltaDocs
            let twin = PpmiProvider()
            for doc in allDocs { twin.addToCounts(text: doc.text) }
            _ = twin.finalizeFromCounts()
            let twinDigest = CorpusContentDigest.digest(twin.serializeBasis())

            // Engine's persisted basis digest must match the twin.
            let basisRow = try await BasisStore(storage: storage)
                .load(modelID: "ppmi-v1", modelVersion: "1.1.0")
            let engineDigest = CorpusContentDigest.digest(
                try #require(basisRow?.basis, "basis row must exist after counts-path publication"))
            #expect(engineDigest == twinDigest,
                    "counts-path delta-fold must produce the same basis as from-scratch training on all 5 texts")
        }
    }

    // MARK: - G-5a-RI: RI behavior

    /// Gate G-5a-RI: RandomIndexing (countsDeltaFoldSafe == false) falls to
    /// corpus(.deltaNotFoldSafe) when pending refs exist; when no pending refs
    /// exist, it takes the counts-restore path and pages zero bodies.
    @Test("G-5a-RI: RI with pending → corpus(.deltaNotFoldSafe); no pending → countsRestore")
    func riCountsPathBehavior() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()
            let riDocs: [CorpusContentRecord] = [
                .init(id: "ri-1", revision: 1, digest: testDigest("ri-1v1"),
                      text: "car engine drive road vehicle fuel"),
                .init(id: "ri-2", revision: 1, digest: testDigest("ri-2v1"),
                      text: "dog bark run fetch animal cat"),
                .init(id: "ri-3", revision: 1, digest: testDigest("ri-3v1"),
                      text: "river flow mountain valley stream"),
            ]
            for doc in riDocs { await source.addResolvable(doc) }

            let engine = try await makeAttachedEngine(
                storage: storage, source: source,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            for doc in riDocs {
                try await engine.applyChange(
                    .upsert(id: doc.id, revision: doc.revision, digest: doc.digest),
                    cursor: nil, now: now)
            }

            // ri-4 is listed but transiently unresolvable during the first train.
            // This produces a sentinel ref (non-subsumed) without calling applyChange,
            // which would trigger settleYoungBasisIfGrown and absorb ri-4 into the base
            // (indexedCount 4 > trainedChunkCount 3 on a young basis < 50).
            let delta = CorpusContentRecord(
                id: "ri-4", revision: 1, digest: testDigest("ri-4v1"),
                text: "wind blow cloud sky storm thunder")
            await source.listUnresolvable(id: "ri-4")

            // First train: corpus path (force + no basis).
            // ri-1..3 resolve → subsumed; ri-4 nil → sentinel (non-subsumed) written.
            _ = try await engine.trainTrainableSlots(now: now, force: true)

            // Make ri-4 resolvable without calling applyChange. The sentinel ref
            // already serves as the pending delta; source.record(for:) will now return
            // the real record when the non-fold-safe corpus path processes it.
            await source.addResolvable(delta)

            // Force-retrain (drift path): RI is not fold-safe → corpus(.deltaNotFoldSafe).
            // force==true is required — the drift gate owns when a retrain fires.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "random-indexing-v1")
                    == .corpus(.deltaNotFoldSafe),
                    "RI with a pending sentinel must fall to corpus(.deltaNotFoldSafe)")

            // After corpus path publication, all 4 refs are subsumed; no pending remain.
            // Next force-retrain with no pending → countsRestore (RI restore-only path).
            // F-1 two-directional gate: reset counter immediately before the measured
            // train call so only this call's record fetches are counted.
            await source.resetFetchCount()
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "random-indexing-v1")
                    == .countsRestore,
                    "RI with no pending refs must take the counts-restore path (bodies paged == 0)")
            // F-1 two-directional gate: bodies paged must equal the folded pending count
            // (or zero on restore) — measured, not inferred.
            #expect(await source.fetchCount() == 0,
                    "F-1 two-directional gate: counts-restore with no pending refs must page zero bodies — measured, not inferred")

            // Non-force call on a trained slot: skip semantics — decision seam records
            // nothing (nil). The drift gate, not the train entry point, decides when a
            // retrain fires.
            _ = try await engine.trainTrainableSlots(now: now)
            #expect(await engine._trainingPathDecision(for: "random-indexing-v1") == nil,
                    "non-force call on a trained slot must be skipped — no decision recorded")
        }
    }

    // MARK: - G-5b: revision / removal → populationMismatch

    /// Gate G-5b: PPMI engine whose trained corpus has been disturbed by either
    /// a revision (new digest for an existing ID) or a removal (fewer active IDs)
    /// must record corpus(.populationMismatch) — NOT the counts path.
    @Test("G-5b: revision of a trained doc drives corpus(.populationMismatch)")
    func populationMismatchOnRevision() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()
            let docs: [CorpusContentRecord] = [
                .init(id: "pb-1", revision: 1, digest: testDigest("pb-1v1"),
                      text: "the quick brown fox jumps over the lazy dog"),
                .init(id: "pb-2", revision: 1, digest: testDigest("pb-2v1"),
                      text: "pack my box with five dozen liquor jugs"),
            ]
            for doc in docs { await source.addResolvable(doc) }

            let engine = try await makeAttachedEngine(
                storage: storage, source: source, models: [.ppmi(provider: PpmiProvider())])
            for doc in docs {
                try await engine.applyChange(
                    .upsert(id: doc.id, revision: doc.revision, digest: doc.digest),
                    cursor: nil, now: now)
            }
            // First train: corpus path.
            _ = try await engine.trainTrainableSlots(now: now, force: true)

            // Revise doc pb-1 to a new revision — the subsumed ref gets replaced
            // with a non-subsumed ref (revision 2), so pending count becomes 1
            // while trainedChunkCount (2) + pending (1) > allIDs (2).
            let revised = CorpusContentRecord(
                id: "pb-1", revision: 2, digest: testDigest("pb-1v2"),
                text: "the quick brown fox jumps over the lazy dog — revised")
            await source.update(revised)
            try await engine.applyChange(
                .upsert(id: revised.id, revision: revised.revision, digest: revised.digest),
                cursor: nil, now: now)

            // force==true: drift-triggered retrain; revised doc makes trainedChunkCount
            // + pending > allIDs → populationMismatch → corpus path.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.populationMismatch),
                    "a revised doc makes trainedChunkCount + pending > allIDs → populationMismatch")
        }
    }

    @Test("G-5b: removal of a trained doc drives corpus(.populationMismatch)")
    func populationMismatchOnRemoval() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()
            let docs: [CorpusContentRecord] = [
                .init(id: "pr-1", revision: 1, digest: testDigest("pr-1v1"),
                      text: "swift actors isolate mutable state safely"),
                .init(id: "pr-2", revision: 1, digest: testDigest("pr-2v1"),
                      text: "async await enables structured concurrency"),
                .init(id: "pr-3", revision: 1, digest: testDigest("pr-3v1"),
                      text: "sendable types cross actor boundaries"),
            ]
            for doc in docs { await source.addResolvable(doc) }

            let engine = try await makeAttachedEngine(
                storage: storage, source: source, models: [.ppmi(provider: PpmiProvider())])
            for doc in docs {
                try await engine.applyChange(
                    .upsert(id: doc.id, revision: doc.revision, digest: doc.digest),
                    cursor: nil, now: now)
            }
            // First train: corpus path; trainedChunkCount = 3, allIDs = 3.
            _ = try await engine.trainTrainableSlots(now: now, force: true)

            // Remove pr-3: source now has 2 IDs; trainedChunkCount (3) + pending (0)
            // does not equal allIDs (2) → populationMismatch.
            await source.remove(id: "pr-3")
            try await engine.applyChange(
                .remove(id: "pr-3", revision: 1),
                cursor: nil, now: now)

            // force==true: drift-triggered retrain; removed doc makes trainedChunkCount
            // > allIDs → populationMismatch → corpus path.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.populationMismatch),
                    "removing a doc makes trainedChunkCount > allIDs → populationMismatch")
        }
    }

    // MARK: - G-6a: skipped-ID sentinel + later resolution

    /// Gate G-6a: when a source lists an ID in activeContentIDs() but returns nil
    /// from record(for:), the corpus-path publication writes a non-subsumed
    /// sentinel row. On the next pass the sentinel appears as a pending ref;
    /// if it still resolves nil → corpus(.pendingUnresolvable). Once the ID
    /// becomes resolvable, the counts path delta-folds it and the digest matches
    /// a from-scratch twin on all texts.
    @Test("G-6a: nil-resolving ID gets sentinel ref; resolves later → countsDeltaFold + twin digest")
    func skippedIDSentinelAndResolution() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()

            // Three resolvable base docs.
            let baseDocs: [CorpusContentRecord] = [
                .init(id: "sk-1", revision: 1, digest: testDigest("sk-1v1"),
                      text: "information retrieval ranks documents by relevance"),
                .init(id: "sk-2", revision: 1, digest: testDigest("sk-2v1"),
                      text: "term frequency inverse document frequency weighs terms"),
                .init(id: "sk-3", revision: 1, digest: testDigest("sk-3v1"),
                      text: "latent semantic analysis finds hidden structure"),
            ]
            for doc in baseDocs { await source.addResolvable(doc) }

            // sk-4 is listed but returns nil (transiently unavailable).
            await source.listUnresolvable(id: "sk-4")

            let engine = try await makeAttachedEngine(
                storage: storage, source: source, models: [.ppmi(provider: PpmiProvider())])
            for doc in baseDocs {
                try await engine.applyChange(
                    .upsert(id: doc.id, revision: doc.revision, digest: doc.digest),
                    cursor: nil, now: now)
            }

            // Force-train: 4 IDs listed, 3 resolve; sk-4 skipped → sentinel row.
            _ = try await engine.trainTrainableSlots(now: now, force: true)

            // Assert: sentinel reference row exists for sk-4 (isSubsumed: false).
            let countsStore = CorpusProviderCountsStore(storage: storage)
            let sentinelRef = try await countsStore.referenceFor(
                modelID: "ppmi-v1", modelVersion: "1.1.0", contentID: "sk-4")
            let sentinel = try #require(sentinelRef,
                "sentinel reference row must be written for a skipped ID after corpus publication")
            #expect(!sentinel.isSubsumed,
                    "sentinel must be non-subsumed (counts as pending on next pass)")
            #expect(sentinel.revision == 0,
                    "sentinel revision must be 0 (ID was never indexed)")
            #expect(sentinel.digest == "",
                    "sentinel digest must be empty string (ID was never indexed)")

            // Second force-retrain (drift path, sk-4 still nil): sentinel appears in
            // pending; resolves nil → corpus(.pendingUnresolvable).
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.pendingUnresolvable),
                    "unresolvable pending ref must cause corpus(.pendingUnresolvable) on counts path")

            // Make sk-4 resolvable WITHOUT calling applyChange. The sentinel ref row
            // (non-subsumed, revision=0, digest="") already exists as the pending delta.
            // Calling applyChange would trigger settleYoungBasisIfGrown (trainedChunkCount=3
            // < 50, indexedCount would become 4 > 3), forcing a corpus-path retrain that
            // subsumes sk-4 into the base BEFORE the explicit trainTrainableSlots can see
            // it as pending. By skipping applyChange we preserve the sentinel as the
            // pending ref and let the counts path fold it on the third explicit train.
            let sk4 = CorpusContentRecord(
                id: "sk-4", revision: 1, digest: testDigest("sk-4v1"),
                text: "probabilistic latent semantic indexing models co-occurrence")
            await source.addResolvable(sk4)

            // Third force-retrain (drift path): sentinel ref is pending; sk-4 is now
            // resolvable via source. Population guard: trainedChunkCount(3) +
            // pendingRefs(1) == allIDs(4) ✓.
            // F-1 two-directional gate: reset counter immediately before the measured
            // train call so only this call's record fetches are counted.
            await source.resetFetchCount()
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            let finalDecision = await engine._trainingPathDecision(for: "ppmi-v1")
            #expect(finalDecision == .countsDeltaFold(folded: 1),
                    "once sk-4 is resolvable, the counts path must delta-fold it (1 pending sentinel ref)")
            // F-1 two-directional gate: bodies paged must equal the folded pending count
            // (or zero on restore) — measured, not inferred.
            #expect(await source.fetchCount() == 1,
                    "F-1 two-directional gate: delta-fold of 1 pending ref must page exactly 1 body — measured, not inferred")

            // Digest must match from-scratch twin on all 4 texts.
            let allDocs = baseDocs + [sk4]
            let twin = PpmiProvider()
            for doc in allDocs { twin.addToCounts(text: doc.text) }
            _ = twin.finalizeFromCounts()
            let twinDigest = CorpusContentDigest.digest(twin.serializeBasis())
            let basisRow = try await BasisStore(storage: storage)
                .load(modelID: "ppmi-v1", modelVersion: "1.1.0")
            let engineDigest = CorpusContentDigest.digest(
                try #require(basisRow?.basis))
            #expect(engineDigest == twinDigest,
                    "delta-fold on sk-4 must produce the same basis as from-scratch training on all 4 texts")
        }
    }

    // MARK: - G-6f: sentinel safety

    /// Gate G-6f: a sentinel row (isSubsumed: false, revision: 0, digest: "")
    /// must never be treated as subsumed (which would trigger early-continue,
    /// blocking the ID's first real indexing) and must not match any real record's
    /// digest (which would silence the new-content fold-in).
    @Test("G-6f: sentinel row is never consumed as subsumed or same-digest early-continue")
    func sentinelSafety() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()
            let baseDocs: [CorpusContentRecord] = [
                .init(id: "sf-1", revision: 1, digest: testDigest("sf-1v1"),
                      text: "tensor operations on multidimensional arrays"),
                .init(id: "sf-2", revision: 1, digest: testDigest("sf-2v1"),
                      text: "gradient descent optimises differentiable objectives"),
            ]
            for doc in baseDocs { await source.addResolvable(doc) }
            await source.listUnresolvable(id: "sf-3")

            let engine = try await makeAttachedEngine(
                storage: storage, source: source, models: [.ppmi(provider: PpmiProvider())])
            for doc in baseDocs {
                try await engine.applyChange(
                    .upsert(id: doc.id, revision: doc.revision, digest: doc.digest),
                    cursor: nil, now: now)
            }
            // Train: sf-3 listed but nil → sentinel row written.
            _ = try await engine.trainTrainableSlots(now: now, force: true)

            let countsStore = CorpusProviderCountsStore(storage: storage)
            let sentinel = try await countsStore.referenceFor(
                modelID: "ppmi-v1", modelVersion: "1.1.0", contentID: "sf-3")
            let s = try #require(sentinel, "sentinel must exist after first corpus train")

            // G-6f invariant 1: sentinel must NOT be marked subsumed.
            // If it were, `commitDirectIndex` would attempt to delete it on
            // the next applyChange for sf-3, treating the digest match "" == ""
            // as "already represented" — silencing the real content fold.
            #expect(!s.isSubsumed,
                    "sentinel must be non-subsumed so it is never silently consumed")

            // G-6f invariant 2: sentinel digest "" cannot match any real record digest.
            // Real digests are SHA-256 hex (64 chars); sentinel is empty string.
            #expect(s.digest == "", "sentinel digest must be the empty string marker")
            let realDigest = testDigest("sf-3v1")
            #expect(realDigest != s.digest,
                    "real record digest must differ from sentinel digest to prevent same-digest early-continue")
            #expect(realDigest.count == 64,
                    "real digest is SHA-256 hex (64 chars) — cannot equal the empty sentinel")

            // G-6f invariant 3: sentinel revision 0 != any real revision (>= 1).
            #expect(s.revision == 0, "sentinel revision must be 0")
            // Apply the real sf-3 record: digest "" ≠ real digest → sentinel is
            // replaced with a real pending ref, NOT consumed as same-digest.
            let sf3 = CorpusContentRecord(
                id: "sf-3", revision: 1, digest: testDigest("sf-3v1"),
                text: "backpropagation computes parameter gradients via chain rule")
            await source.addResolvable(sf3)
            try await engine.applyChange(
                .upsert(id: sf3.id, revision: sf3.revision, digest: sf3.digest),
                cursor: nil, now: now)

            // After adding sf3 and applying, settleYoungBasisIfGrown fires a growth
            // retrain (indexedCount 3 > trainedChunkCount 2, basis is young). That
            // retrain runs the corpus path over all 3 docs, then calls deleteReferences
            // so all reference rows — including sf3's newly created real ref — are
            // consumed into the trained base. Verify sf3 IS in the new base by
            // checking trainedChunkCount; a raw referenceFor query after the growth
            // retrain will return nil (expected: the sentinel was resolved, trained, and
            // cleaned up).
            let basisStore = BasisStore(storage: storage)
            let basisRow = try await basisStore.load(
                modelID: "ppmi-v1", modelVersion: "1.1.0")
            #expect(basisRow?.trainedChunkCount == 3,
                    "growth retrain after adding sf-3 must train on all 3 docs (sf-3 was not silently consumed)")
        }
    }

    // MARK: - G-5a-ENTRY: production entry point drives a counts-path decision

    /// G-5a-ENTRY: the attached engine's public reindex entry
    /// (`reindex(now:laneScope:)`) must record a counts-path decision when the
    /// population guard passes. This gate is distinct from G-5a (which drives
    /// `trainTrainableSlots` directly) because the production drift-trigger calls
    /// `reindex`, not the internal train function. The decision must be
    /// `countsDeltaFold(n)` with at least one folded ref, proving the production
    /// entry invokes `trainTrainableSlots(force: true)` internally.
    @Test("G-5a-ENTRY: reindex(now:laneScope:) records countsDeltaFold via the production entry point")
    func ppmiCountsPathReindexEntry() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()

            // Base doc: trained in the first corpus pass.
            let baseDoc = CorpusContentRecord(
                id: "entry-base", revision: 1,
                digest: testDigest("entry-basev1"),
                text: "the planet orbits the star in a year")
            await source.addResolvable(baseDoc)

            // Delta doc: listed but unresolvable during the first train.
            // The corpus-path publication writes a non-subsumed sentinel ref.
            // We do NOT call applyChange — on a young basis, applyChange would
            // trigger settleYoungBasisIfGrown and absorb the delta before the
            // force-retrain runs.
            await source.listUnresolvable(id: "entry-delta")
            let deltaDoc = CorpusContentRecord(
                id: "entry-delta", revision: 1,
                digest: testDigest("entry-deltav1"),
                text: "gravity pulls mass toward the centre of the planet")

            let engine = try await makeAttachedEngine(
                storage: storage, source: source,
                models: [.ppmi(provider: PpmiProvider())])

            // First force-retrain: corpus path (no basis row → firstTrain).
            // base resolves → subsumed; entry-delta nil → sentinel ref written.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.firstTrain),
                    "first force-train must record firstTrain for a new slot")

            // Make entry-delta resolvable; sentinel is the pending ref.
            await source.addResolvable(deltaDoc)

            // Drive the PRODUCTION ENTRY POINT — the call the drift trigger makes.
            // `reindex(now:laneScope:)` calls `trainTrainableSlots(force: true)`
            // internally, then proceeds to index content.  The counts-path guard
            // sequence: basis✓ counts✓ capable✓ foldSafe✓ population✓ →
            // countsDeltaFold(1).
            try await engine.reindex(now: now)
            let decision = await engine._trainingPathDecision(for: "ppmi-v1")
            #expect(decision == .countsDeltaFold(folded: 1),
                    "G-5a-ENTRY: reindex(now:laneScope:) must record countsDeltaFold(1) when one sentinel pending ref exists — production entry drives counts path")
        }
    }

    // MARK: - F-10: counts-path publication admission survival (twin of corpus-path race test)

    /// F-10 twin: proves the counts-path publication's per-reference delete
    /// removes ONLY the folded pending refs and does NOT delete a reference row
    /// written by a subsequent admission.
    ///
    /// Proof shape: sequential (without interleaving).
    ///
    /// Why interleaving cannot corrupt the counts path: `trainTrainableSlots`
    /// acquires `acquireCountsAdmission()` at its entry point
    /// (CorpusContentEngine.swift line 2489–2490, `defer { releaseCountsAdmission() }`),
    /// which is held for the entire duration of the counts-path fold and
    /// publication transaction. Any concurrent `applyChange` that tries to write
    /// a reference row will block at the `acquireCountsAdmission()` call inside
    /// `commitQueueBatch` (CorpusContentEngine.swift line 1631–1632) until the
    /// counts-path transaction commits and admission is released. Therefore:
    ///   - The set of pending refs deleted by the counts-path transaction is
    ///     captured AFTER acquisition, inside the admission lock (line 2586–2588),
    ///     so no admission can slip a reference row in between snapshot and lock.
    ///   - Any reference row written by an admission that runs after the
    ///     transaction commits is NOT in that set and is NOT deleted.
    ///
    /// This sequential test observes the property directly: admit a record
    /// immediately after a counts-path publication and assert its reference row
    /// exists and is not affected by the previous publication's per-ref delete.
    @Test("F-10: counts-path per-ref delete leaves post-publication admissions untouched")
    func countsPathPublicationAdmissionSurvives() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()

            // Three base docs + one sentinel pending ref.
            let baseDocs: [CorpusContentRecord] = [
                .init(id: "f10-1", revision: 1, digest: testDigest("f10-1v1"),
                      text: "the tide rises and falls along the shore"),
                .init(id: "f10-2", revision: 1, digest: testDigest("f10-2v1"),
                      text: "salt water carries dissolved minerals"),
                .init(id: "f10-3", revision: 1, digest: testDigest("f10-3v1"),
                      text: "waves break when the depth equals half the wavelength"),
            ]
            for doc in baseDocs { await source.addResolvable(doc) }
            await source.listUnresolvable(id: "f10-sentinel")

            let engine = try await makeAttachedEngine(
                storage: storage, source: source,
                models: [.ppmi(provider: PpmiProvider())])

            // First force-retrain: corpus path (firstTrain).
            // base docs → subsumed refs; sentinel → non-subsumed sentinel ref.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.firstTrain),
                    "F-10 setup: first train must record firstTrain")

            // Make the sentinel resolvable; it is now a pending (non-subsumed) ref.
            let sentinelDoc = CorpusContentRecord(
                id: "f10-sentinel", revision: 1, digest: testDigest("f10-sentinelv1"),
                text: "currents transport heat from the tropics to the poles")
            await source.addResolvable(sentinelDoc)

            // Counts-path fold: base✓ counts✓ capable✓ foldSafe✓ population✓
            // (trainedChunkCount=3 + pending=1 == allIDs=4) → countsDeltaFold(1).
            // The per-ref delete removes ONLY the sentinel ref from the store.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .countsDeltaFold(folded: 1),
                    "F-10 setup: counts-path fold with 1 sentinel ref must record countsDeltaFold(1)")

            // POST-PUBLICATION ADMISSION: admit a new record immediately after
            // the counts-path publication completes. Its non-subsumed reference
            // row is written by the admission path's commitIndexBatch and must
            // NOT be affected by the previous publication's per-ref delete
            // (which already committed and only touched the sentinel ref).
            let lateDoc = CorpusContentRecord(
                id: "f10-late", revision: 1, digest: testDigest("f10-latev1"),
                text: "deep water currents are driven by temperature and salinity")
            await source.addResolvable(lateDoc)
            try await engine.applyChange(
                .upsert(id: lateDoc.id, revision: lateDoc.revision, digest: lateDoc.digest),
                cursor: nil, now: now)

            // PROPERTY 1: the late record's non-subsumed reference row EXISTS.
            // The counts path's per-ref delete only removed the sentinel ref;
            // the late ref was written AFTER the transaction committed.
            let countsStore = CorpusProviderCountsStore(storage: storage)
            let lateRef = try await countsStore.referenceFor(
                modelID: "ppmi-v1", modelVersion: "1.1.0",
                contentID: lateDoc.id)
            #expect(lateRef != nil,
                    "F-10: the late admission's reference row must exist after counts-path publication — the per-ref delete only removed the folded sentinel ref")
            #expect(lateRef?.isSubsumed == false,
                    "F-10: the late admission's reference must be non-subsumed (pending) — it was not folded into the counts-path basis")

            // PROPERTY 2: the late record's terms are NOT in the counts-path
            // published basis. Verify by forcing another retrain: the late ref is
            // the only pending ref, so the next counts-path fold must record
            // countsDeltaFold(1). If the late record had been silently folded into
            // the previous publication, it would appear as a subsumed ref and the
            // next retrain would record countsRestore(0).
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            let subsequentDecision = await engine._trainingPathDecision(for: "ppmi-v1")
            #expect(subsequentDecision == .countsDeltaFold(folded: 1),
                    "F-10: a subsequent force-retrain must fold the late record via countsDeltaFold(1) — proving the late record was NOT included in the previous counts-path publication")
        }
    }

    // MARK: - G-5d: countsRestore publication invalidates coverage

    /// G-5d: after a countsRestore publication, the global basis-generation
    /// counter increments, invalidating all existing coverage bitmaps via
    /// generation mismatch (O(1) invalidation — no estate-wide row writes).
    ///
    /// Two facts documented by this gate:
    /// (i) Migration repair relies on the generation bump invalidating coverage
    ///     so backfill re-embeds all content under the new basis — REQUIRED.
    ///     The countsRestore path bumps the generation (trainedSlotsCount > 0 →
    ///     incrementBasisGeneration) exactly like the corpus path.
    /// (ii) Therefore a no-op reindex (countsRestore with identical bytes)
    ///     re-embeds the entire corpus, which matches the PRE-MISSION corpus-path
    ///     behaviour for a no-op force reindex and is NOT a regression introduced
    ///     by the counts path. The no-op-reindex re-embed optimisation is a named
    ///     follow-up for Bob, out of this mission's scope.
    @Test("G-5d: countsRestore bumps basis generation, invalidating existing coverage bitmaps")
    func countsRestorePublicationInvalidatesCoverage() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let source = MutableAttachedSource()

            // Two base docs for a well-formed PPMI corpus.
            let docs: [CorpusContentRecord] = [
                .init(id: "g5d-1", revision: 1, digest: testDigest("g5d-1v1"),
                      text: "light travels at three hundred thousand kilometres per second"),
                .init(id: "g5d-2", revision: 1, digest: testDigest("g5d-2v1"),
                      text: "photons carry energy proportional to their frequency"),
            ]
            for doc in docs { await source.addResolvable(doc) }

            let engine = try await makeAttachedEngine(
                storage: storage, source: source,
                models: [.ppmi(provider: PpmiProvider())])

            // Phase 1: full reindex — trains (firstTrain bumps gen to 1) then
            // indexes content (stamps coverage bits at gen 1 via indexWholeContentBatch).
            try await engine.reindex(now: now)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .corpus(.firstTrain),
                    "G-5d setup: first reindex must record firstTrain")

            // Verify the index state row exists and record the operationalBitmap
            // before the countsRestore so we can prove it does not change (O(1) tenet).
            let indexStateStore = CorpusIndexStateStore(storage: storage)
            let gen1 = try await indexStateStore.basisGeneration()
            let stateAfterReindex = try await indexStateStore.state(for: docs[0].id)
            #expect(stateAfterReindex != nil,
                    "G-5d setup: corpus_index_state row must exist for g5d-1 after reindex")

            // Phase 2: force countsRestore — no pending refs after the first
            // corpus-path publication (all refs subsumed), so the second retrain
            // takes the counts-restore path. trainedSlotsCount > 0 → generation
            // bumps from gen1 to gen1+1, invalidating all existing coverage bitmaps.
            _ = try await engine.trainTrainableSlots(now: now, force: true)
            #expect(await engine._trainingPathDecision(for: "ppmi-v1")
                    == .countsRestore,
                    "G-5d: force-retrain after corpus-path publication must record countsRestore (no pending refs)")

            // OBSERVED BEHAVIOUR (fact i): countsRestore bumps the global basis generation.
            // The engine's `trainedSlotsCount > 0` branch calls `incrementBasisGeneration`
            // exactly as the corpus path does. This is what invalidates all existing
            // coverage bitmaps — migration repair relies on this: backfill re-embeds every
            // content row because its stored basisGeneration field no longer matches the
            // global counter, so isFullyCovered returns false.
            //
            // OBSERVED BEHAVIOUR (fact ii): no-op reindex (countsRestore with identical
            // bytes) therefore re-embeds the entire corpus. This matches the PRE-MISSION
            // corpus-path behaviour for a no-op force reindex and is NOT a regression
            // introduced by the counts path. The no-op-reindex re-embed optimisation is a
            // named follow-up for Bob, out of this mission's scope.
            let gen2 = try await indexStateStore.basisGeneration()
            #expect(gen2 == gen1 + 1,
                    "G-5d: generation must increment from \(gen1) to \(gen1 + 1) after countsRestore")

            if let state = stateAfterReindex {
                // O(1) invalidation: the DB row bitmap is NOT rewritten during countsRestore.
                // Invalidity is detected at read-time via generation mismatch (row's
                // basisGeneration field != global gen2), so no estate-wide row writes occur.
                let stateAfterRestore = try await indexStateStore.state(for: docs[0].id)
                #expect(stateAfterRestore?.operationalBitmap == state.operationalBitmap,
                        "G-5d: operational_bitmap must not change on countsRestore generation bump — O(1) invalidation, no estate-wide row writes")

                // The row's stored generation stamp does not match the new global generation,
                // proving that isFullyCovered(currentGeneration: gen2) returns false (stale).
                // The bitmap guard in isFullyCovered is: `guard basisGeneration == currentGeneration`.
                if let fresh = stateAfterRestore {
                    #expect(fresh.basisGeneration != gen2,
                            "G-5d: row basisGeneration must not equal new global gen — generation mismatch makes isFullyCovered return false at gen2")
                }
            }
        }
    }
}

#endif // MOOTX01_DENSE_FAMILIES
