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
import PersistenceKit
import PersistenceKitSQLite
import VectorKit
import CorpusKitProviders

@testable import CorpusKit

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
        var passages = false
        if case .tokenBudgetedPassages = indexUnit { passages = true }
        try await storage.migrate(
            to: CorpusSchemaProfile.standaloneDeclaration(passageIndexing: passages))
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
            #expect(baseAfter.documentCount == baseBefore.documentCount)
            #expect(try await storage.rowStore.count(
                table: "corpus_provider_count_references", where: nil) == 1)
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
            #expect(try await storage.rowStore.count(
                table: "corpus_provider_count_references", where: nil) == 0)
            let compacted = try #require(try await countsStore.load(
                modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(compacted.documentCount == 2)
            #expect(await reopened.maintainedDocumentCount() == 2)
        }
    }

    // MARK: - Standalone passages

    @Test func passageModeIndexesRangesAndAggregatesToContentID() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store, storage) = try await makeStandalone(
                indexUnit: .tokenBudgetedPassages(tokenBudget: 6))
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
            #expect(passageRows.count == 3)
            for row in passageRows {
                #expect(row["text"] == nil)
                if case let .int(revision)? = row["revision"] {
                    #expect(revision == rec.revision)
                }
            }

            // Derived keys are passage keys that PARSE back to the content
            // ID — never a second identity.
            let bmKeys = try await itemIDs(storage, table: "iix_doclens", column: "item_id")
            #expect(bmKeys.count == 3)
            for key in bmKeys {
                #expect(PassageProduction.contentID(fromItemKey: key) == "doc-p")
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
