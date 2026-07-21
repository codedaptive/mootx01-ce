// DestroyRecallOwnershipTests.swift
//
// Ownership-scoped legacy teardown (GLK shared-content 1.1, P5).
//
// `Corpus.destroyRecallIndex()` on SHARED storage must delete exactly the
// corpus's own vector rows (its chunk IDs under its held models) and leave
// every row other lanes wrote — same model or different model — byte-
// identically intact. The broad whole-table teardown (`destroyAllVectors`)
// is reserved for the whole-estate destruction path in GeniusLocusKit and
// must never run on this path.

import Testing
import Foundation
import CorpusKit
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import VectorKit

@Suite("DestroyRecallOwnership", .serialized)
struct DestroyRecallOwnershipTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-ownership-\(UUID().uuidString).sqlite3")
    }

    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    /// Canonical map of every vectors-table row: "model|item|index" → payload
    /// encoding. Payload bytes are the collateral-mutation detector.
    private func vectorRows(_ storage: any Storage) async throws -> [String: String] {
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: [String: String] = [:]
        for row in rows {
            guard case let .text(item)? = row["item_id"],
                  case let .int(vectorIndex)? = row["vector_index"],
                  case let .text(model)? = row["model_id"] else { continue }
            out["\(model)|\(item)|\(vectorIndex)"] =
                DatabaseInventory.canonicalValueEncoding(row["payload"] ?? .null)
        }
        return out
    }

    @Test func destroyRecallIndexLeavesForeignVectorsIntact() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let storage = try storage(at: url)
            let corpus = try await Corpus(storage: storage, model: .deterministic)
            try await corpus.ingest(
                "The corpus indexes this sentence about engines.",
                sourceID: "doc-1", now: now)
            try await corpus.ingest(
                "A second sentence about animals and pets.",
                sourceID: "doc-2", now: now)

            // Plant FOREIGN rows directly in the shared vectors table:
            // another lane's item under the corpus's OWN model, and another
            // lane's item under a different model. Neither belongs to the
            // corpus; both must survive the teardown byte-identically.
            let foreignStore = VectorStore(storage: storage)
            let engram = Engram(blocks: 11, 22, 33, 44)
            try await foreignStore.addVector(
                itemID: "drawer-foreign-1",
                engram: engram,
                modelID: "corpus-deterministic-v1",
                modelVersion: "1.0.0",
                filedAt: now)
            try await foreignStore.addVector(
                itemID: "drawer-foreign-2",
                engram: engram,
                modelID: "other-lane-model",
                modelVersion: "1.0.0",
                filedAt: now)

            let before = try await vectorRows(storage)
            let foreignKeys = before.keys.filter { $0.contains("drawer-foreign") }
            #expect(foreignKeys.count == 2)
            // The corpus really has rows of its own to delete.
            #expect(before.count > 2)

            try await corpus.destroyRecallIndex()

            let after = try await vectorRows(storage)
            // Exactly the two foreign rows survive, byte-identical.
            #expect(after.count == 2)
            for key in foreignKeys {
                #expect(after[key] == before[key])
            }
        }
    }
}
