// CaptureBatchTests.swift
//
// GLK_BATCH1 — acceptance tests for `captureBatch(_:_:)`.
//
// Verifies:
//   - Empty frames slice is a no-op returning an empty array
//   - A batch of N frames inserts all N drawers and returns them
//   - Each returned drawer has a distinct non-empty ID
//   - All batch-inserted drawers are recall-visible
//   - Content round-trips through a single-frame batch
//   - An unknown handle throws estateNotOpen
//
// Transaction semantics: the in-memory backend uses the no-op RowStore
// default for begin/commit/rollback, so the batch-insert observable
// behaviour is identical to repeated single-capture calls from the
// caller's perspective. The rollback-on-error path is exercised by
// TransactionBoundaryTests (PersistenceKit), which owns the SQLite-
// backed rollback contract.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("CaptureBatchTests — bulk import via single-transaction batch")
struct CaptureBatchTests {

    // MARK: - Helpers

    /// Open a minimal LocusKit-only estate — no Corpus or VectorStore needed.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "capture-batch-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "capture-batch-tests",
            latticeAnchor: .udc("000"),
            addedBy: "capture-batch-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    private func recallAll() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    // MARK: - Tests

    /// An empty frames array is a no-op that returns an empty array.
    @Test
    func emptyBatchIsNoOp() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let result = try await kit.captureBatch(handle, [])
        #expect(result.isEmpty, "empty input must produce empty output")
    }

    /// Three frames → three drawers returned; each has a distinct non-empty ID.
    @Test
    func batchInsertReturnsAllDrawers() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let frames = [
            captureFrame("first drawer content"),
            captureFrame("second drawer content"),
            captureFrame("third drawer content"),
        ]
        let drawers = try await kit.captureBatch(handle, frames)
        #expect(drawers.count == 3, "must return one drawer per input frame")
        let ids = Set(drawers.map(\.id))
        #expect(ids.count == 3, "all returned drawer IDs must be distinct")
        for d in drawers {
            #expect(!d.id.isEmpty, "drawer ID must be non-empty")
        }
    }

    /// Drawers inserted via `captureBatch` are recall-visible.
    @Test
    func batchInsertedDrawersAreRecallVisible() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let frames = [captureFrame("recall visible alpha"), captureFrame("recall visible beta")]
        let inserted = try await kit.captureBatch(handle, frames)
        let insertedIDs = Set(inserted.map(\.id))

        let recalled = try await kit.recall(handle, recallAll())
        let recalledIDs = Set(recalled.map(\.id))
        for id in insertedIDs {
            #expect(recalledIDs.contains(id),
                    "captureBatch drawer \(id) must appear in recall")
        }
    }

    /// Content round-trips through a single-frame batch.
    @Test
    func singleFrameBatchRoundTripsContent() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "the quick brown fox"
        let drawers = try await kit.captureBatch(handle, [captureFrame(content)])
        #expect(drawers.count == 1)
        #expect(drawers[0].content == content)
    }

    /// Batch capture classifies sentinel UDC frames before storage so federation
    /// latticeSubtree scopes evaluate against the real category.
    @Test
    func batchCaptureClassifiesSentinelAnchorsBeforeStorage() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let drawers = try await kit.captureBatch(handle, [
            captureFrame("software engineering algorithms data structures")
        ])

        #expect(drawers.count == 1)
        #expect(drawers[0].udcCode == "004",
                "classifiable batch content must not remain under the unclassified sentinel")
    }

    /// A closed (stale) handle throws `GeniusLocusKitError.estateNotOpen`.
    @Test
    func closedHandleThrowsEstateNotOpen() async throws {
        let (kit, handle) = try await openEstate()
        try await kit.close(handle)
        // handle is now stale — captureBatch must throw estateNotOpen.
        var threw = false
        do {
            _ = try await kit.captureBatch(handle, [captureFrame("test")])
        } catch GeniusLocusKitError.estateNotOpen {
            threw = true
        }
        #expect(threw, "closed handle must throw estateNotOpen")
    }

    /// SQLite-backed batch: verifies the nested-transaction fix.
    ///
    /// SQLiteBackend tracks open transactions via `inTransaction`; the old
    /// captureBatch called `rowStore.beginTransaction()` then called
    /// `capture()` per-row, which opened a second nested transaction via
    /// `storage.transaction()` and threw `StorageError.transactionConflict`.
    /// This test catches any regression to that pattern.
    @Test
    func sqliteBatchDoesNotConflict() async throws {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-batch-sqlite-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("sqlite-wal"))
            try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("sqlite-shm"))
        }

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "sqlite-batch-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .sqlite(url: dbURL))
        let storage = try SQLiteStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        defer { Task { try? await kit.close(handle) } }

        let frames = (1...5).map { captureFrame("sqlite batch item \($0)") }
        let drawers = try await kit.captureBatch(handle, frames)
        #expect(drawers.count == 5, "SQLite batch must insert all 5 drawers without transaction conflict")
        let ids = Set(drawers.map(\.id))
        #expect(ids.count == 5, "all SQLite batch drawer IDs must be distinct")
    }
}
