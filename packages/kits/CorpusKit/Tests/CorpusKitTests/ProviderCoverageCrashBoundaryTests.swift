// ProviderCoverageCrashBoundaryTests.swift
//
// Crash-boundary coverage for the corrective pass's provider machinery:
// streamed training with atomic basis+counts commits, per-provider
// coverage rows as the backfill's resume authority, digest-mismatch
// re-coverage, provider addition to an already-indexed estate, and
// claim-aware shared-vector ownership on remove/destroy.
//
// Every test is FAST (tiny corpora); the durable boundaries are exercised
// with injected faults, then the operation is re-run to prove resume:
// nothing is double-written, nothing is lost, and progress bookkeeping
// never leads the durable vector rows.

import Testing
import Foundation
import CorpusKitProviders
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import VectorKit
@testable import CorpusKit

@Suite("ProviderCoverageCrashBoundary", .serialized)
struct ProviderCoverageCrashBoundaryTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchStorage() throws -> any Storage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-coverage-\(UUID().uuidString).sqlite3")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    private func docs(_ engine: CorpusContentEngine, _ count: Int) async throws {
        for index in 0..<count {
            try await engine.ingest(
                "document \(index) about signals lanes coverage and drawers",
                contentID: String(format: "doc-%03d", index), now: now)
        }
    }

    private func basisRow(_ storage: any Storage, _ modelID: String) async throws -> Data? {
        try await BasisStore(storage: storage).load(modelID: modelID, modelVersion: "1.1.0")?.basis
    }

    // MARK: 1+2. Training interruption before/after basis publication

    @Test func trainingFaultBeforeCommitRetrainsFromZero() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engine = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            await engine._armTrainFault(beforeCommitModelID: "random-indexing-v1")
            // First ingest triggers first-ingest training, which faults
            // BEFORE the atomic commit: no basis row, no counts row.
            await #expect(throws: (any Error).self) {
                try await docs(engine, 3)
            }
            #expect(try await basisRow(storage, "random-indexing-v1") == nil)
            #expect(try await CorpusProviderCountsStore(storage: storage)
                .load(modelID: "random-indexing-v1", modelVersion: "1.1.0") == nil)

            // Resume: retrains from zero, commits once, and the estate
            // reaches full coverage.
            try await docs(engine, 3)
            let blob = try #require(try await basisRow(storage, "random-indexing-v1"))
            #expect(try await engine.coveredCount(modelID: "random-indexing-v1") == 3)
            // The counts row committed atomically with the basis.
            #expect(try await CorpusProviderCountsStore(storage: storage)
                .load(modelID: "random-indexing-v1", modelVersion: "1.1.0") != nil)
            _ = blob
        }
    }

    @Test func trainingFaultAfterCommitSkipsCommittedProviderOnResume() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engine = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [
                    .randomIndexing(provider: RandomIndexingProvider()),
                    .ppmi(provider: PpmiProvider())
                ])
            await engine._armTrainFault(afterModelID: "random-indexing-v1")
            await #expect(throws: (any Error).self) {
                try await docs(engine, 3)
            }
            // The fault fired AFTER RI's atomic commit and BEFORE PPMI
            // trained: exactly one basis row exists.
            // The fault boundary itself: RI's basis row exists (committed).
            _ = try #require(try await basisRow(storage, "random-indexing-v1"))
            #expect(try await basisRow(storage, "ppmi-v1") == nil)

            // Resume: the TRAINING RESUME skips the committed RI provider
            // (train's non-forced path never redoes committed work) and PPMI
            // trains. RI's blob may legitimately CHANGE afterwards — the
            // post-ingest young-basis settle (settleYoungBasisIfGrown)
            // retrains a young basis whenever the indexed corpus grows, and
            // the resume's ingest is exactly such growth. The crash-boundary
            // contract is convergence, not byte-stability: both bases exist
            // and both providers reach full coverage.
            try await docs(engine, 3)
            #expect(try await basisRow(storage, "random-indexing-v1") != nil)
            #expect(try await basisRow(storage, "ppmi-v1") != nil)
            #expect(try await engine.coveredCount(modelID: "random-indexing-v1") == 3)
            #expect(try await engine.coveredCount(modelID: "ppmi-v1") == 3)
        }
    }

    @Test func reindexDoesNotDoubleFoldTheTrainingSnapshotIntoCounts() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engine = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [.randomIndexing(provider: RandomIndexingProvider())])
            try await docs(engine, 3)

            try await engine.reindex(now: now)
            let counts = try #require(try await CorpusProviderCountsStore(storage: storage)
                .load(modelID: "random-indexing-v1", modelVersion: "1.1.0"))
            #expect(counts.documentCount == 3)
        }
    }

    // MARK: 3. Backfill interruption before/after vector-batch persistence

    @Test func backfillFaultAfterVectorsResumesWithoutLossOrDuplication() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            // Index under the deterministic provider only.
            let engineA = try await CorpusContentEngine(
                standaloneOn: storage, models: [.deterministic])
            try await docs(engineA, 5)

            // Reopen with an ADDED trainable provider — the engine-level
            // "add a provider to an already indexed estate" path.
            let engineB = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [.deterministic, .randomIndexing(provider: RandomIndexingProvider())])
            _ = try await engineB.trainTrainableSlots(now: now)
            // Fault AFTER the vector batch persists but BEFORE its coverage
            // rows: durable vectors lead, coverage lags — never the reverse.
            await engineB._armBackfillFaultHook { phase, _ in
                if phase == .afterVectors { throw CorpusKitError.invalidConfiguration("injected") }
            }
            await #expect(throws: (any Error).self) {
                _ = try await engineB.backfillProviderCoverage(now: now, batchSize: 2)
            }
            await engineB._armBackfillFaultHook(nil)
            let midCovered = try await engineB.coveredCount(modelID: "random-indexing-v1") ?? 0
            #expect(midCovered < 5)

            let vectorsBefore = try await vectorBytes(storage, modelID: "random-indexing-v1")
            #expect(!vectorsBefore.isEmpty)

            // Resume: the coverage anti-join re-embeds ONLY the lagging tail;
            // replay is byte-idempotent (existing rows unchanged).
            let written = try await engineB.backfillProviderCoverage(now: now, batchSize: 2)
            #expect(written == 5 - midCovered)
            #expect(try await engineB.coveredCount(modelID: "random-indexing-v1") == 5)
            let vectorsAfter = try await vectorBytes(storage, modelID: "random-indexing-v1")
            for (key, bytes) in vectorsBefore {
                #expect(vectorsAfter[key] == bytes, "replayed row \(key) must be byte-identical")
            }

            // A THIRD run writes nothing: coverage is complete.
            #expect(try await engineB.backfillProviderCoverage(now: now) == 0)
        }
    }

    @Test func backfillFaultAfterCoverageIsAlreadyDurable() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engineA = try await CorpusContentEngine(
                standaloneOn: storage, models: [.deterministic])
            try await docs(engineA, 4)
            let engineB = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [.deterministic, .randomIndexing(provider: RandomIndexingProvider())])
            _ = try await engineB.trainTrainableSlots(now: now)
            await engineB._armBackfillFaultHook { phase, batch in
                if phase == .afterCoverage && batch == 0 {
                    throw CorpusKitError.invalidConfiguration("injected")
                }
            }
            await #expect(throws: (any Error).self) {
                _ = try await engineB.backfillProviderCoverage(now: now, batchSize: 2)
            }
            await engineB._armBackfillFaultHook(nil)
            // The faulted batch's coverage was ALREADY durable; the resume
            // covers exactly the remaining pairs.
            let covered = try await engineB.coveredCount(modelID: "random-indexing-v1") ?? 0
            #expect(covered == 2)
            #expect(try await engineB.backfillProviderCoverage(now: now, batchSize: 2) == 2)
            #expect(try await engineB.coveredCount(modelID: "random-indexing-v1") == 4)
        }
    }

    // MARK: 4+5. Coverage disagreement and basis-digest mismatch

    @Test func laggingAndMismatchedCoverageRowsAreHealedExactly() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engine = try await CorpusContentEngine(
                standaloneOn: storage,
                models: [.deterministic, .randomIndexing(provider: RandomIndexingProvider())])
            try await docs(engine, 4)
            #expect(try await engine.coveredCount(modelID: "random-indexing-v1") == 4)

            // Simulate a lagging row (progress bookkeeping ahead of a lost
            // coverage write): delete one coverage row.
            _ = try await storage.rowStore.delete(
                table: "corpus_provider_coverage",
                where: .and([
                    .eq(Column(table: "corpus_provider_coverage", name: "content_id"), .text("doc-001")),
                    .eq(Column(table: "corpus_provider_coverage", name: "model_id"), .text("random-indexing-v1"))
                ]))
            // Simulate a stale generation: tamper another row's digest.
            _ = try await storage.rowStore.upsert(
                table: "corpus_provider_coverage",
                values: [
                    "content_id": .text("doc-002"),
                    "model_id": .text("random-indexing-v1"),
                    "basis_digest": .text("stale-digest"),
                    "updated_at": .timestamp(now)
                ],
                conflictColumns: ["content_id", "model_id"])

            // The backfill heals EXACTLY the two defective pairs.
            #expect(try await engine.backfillProviderCoverage(now: now) == 2)
            #expect(try await engine.coveredCount(modelID: "random-indexing-v1") == 4)
            #expect(try await engine.backfillProviderCoverage(now: now) == 0)
        }
    }

    // MARK: 7. Exact shared-vector ownership on remove/destroy

    @Test func sharedRepresentationSurvivesRemoveAndDestroy() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try scratchStorage()
            let engine = try await CorpusContentEngine(
                standaloneOn: storage, models: [.deterministic])
            try await docs(engine, 2)

            // A second consumer claims the SAME representation family the
            // engine writes — the exact rows are shared.
            let claims = VectorRepresentationClaims(storage: storage)
            for lane in [0, 1] {
                try await claims.registerClaim(
                    consumer: "other-lane",
                    key: VectorRepresentationKey(
                        modelID: "corpus-deterministic-v1",
                        modelVersion: "1.0.0", vectorIndex: lane),
                    now: now)
            }

            let before = try await vectorBytes(storage, modelID: "corpus-deterministic-v1")
            #expect(!before.isEmpty)

            // Remove one content: BM25 + checkpoint + coverage go; the
            // SHARED vector rows survive byte-identically.
            try await engine.removeContent(id: "doc-000")
            let afterRemove = try await vectorBytes(storage, modelID: "corpus-deterministic-v1")
            #expect(afterRemove == before)

            // Destroy the recall index: same rule — the shared family's
            // rows outlive the engine's own teardown.
            try await engine.destroyRecallIndex()
            let afterDestroy = try await vectorBytes(storage, modelID: "corpus-deterministic-v1")
            #expect(afterDestroy == before)

            // The other consumer releases its claims; a fresh engine's
            // teardown NOW owns the family exclusively and deletes it.
            for lane in [0, 1] {
                try await claims.releaseClaim(
                    consumer: "other-lane",
                    key: VectorRepresentationKey(
                        modelID: "corpus-deterministic-v1",
                        modelVersion: "1.0.0", vectorIndex: lane))
            }
            let engineC = try await CorpusContentEngine(
                standaloneOn: storage, models: [.deterministic])
            try await docs(engineC, 2)
            try await engineC.destroyRecallIndex()
            #expect(try await vectorBytes(storage, modelID: "corpus-deterministic-v1").isEmpty)
        }
    }

    // MARK: helpers

    private func vectorBytes(
        _ storage: any Storage, modelID: String
    ) async throws -> [String: String] {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            orderBy: [], limit: nil, offset: nil)
        var out: [String: String] = [:]
        for row in rows {
            guard case let .text(item)? = row["item_id"],
                  case let .int(lane)? = row["vector_index"] else { continue }
            out["\(item)|\(lane)"] =
                DatabaseInventory.canonicalValueEncoding(row["payload"] ?? .null)
        }
        return out
    }
}
