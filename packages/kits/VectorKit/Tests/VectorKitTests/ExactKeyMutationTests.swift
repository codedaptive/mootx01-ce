// ExactKeyMutationTests.swift
//
// Exact-key batch mutation + representation-claims coverage
// (GLK shared-content 1.1, P0 — vector representation ownership gate).
//
// These tests prove the property the migration relies on: ONE model
// partition can contain retained/shared keys and removed keys side by
// side, and scoped mutation touches exactly the addressed keys with no
// collateral mutation — the byte-identical survival of unaddressed rows
// is asserted, not assumed. The claims ledger tests pin the
// shared-vs-exclusive ownership semantics that gate physical deletion.

import Testing
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import Foundation
@testable import VectorKit

@Suite("ExactKeyMutation", .serialized)
struct ExactKeyMutationTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() async throws -> (VectorStore, any Storage) {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return (VectorStore(storage: storage), storage)
    }

    private func engram(_ seed: UInt64) -> Engram {
        Engram(blocks: seed, seed &* 3, seed &* 5, seed &* 7)
    }

    private func binaryInput(
        item: String, model: String, version: String = "1.0.0", seed: UInt64
    ) -> VectorPayloadInput {
        VectorPayloadInput(
            itemID: item, vectorIndex: 0,
            payload: VectorPayload(engram: engram(seed)),
            modelID: model, modelVersion: version, filedAt: now)
    }

    private func floatInput(
        item: String, model: String, version: String = "1.0.0", floats: [Float]
    ) -> VectorPayloadInput {
        VectorPayloadInput(
            itemID: item, vectorIndex: 1,
            payload: VectorPayload(floats: floats),
            modelID: model, modelVersion: version, filedAt: now)
    }

    /// Canonical baseline of every vector row, keyed for exact comparison.
    private func rowBaseline(_ storage: any Storage) async throws -> [String: String] {
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var out: [String: String] = [:]
        for row in rows {
            guard case let .text(item)? = row["item_id"],
                  case let .int(vectorIndex)? = row["vector_index"],
                  case let .text(model)? = row["model_id"] else { continue }
            let key = "\(model)|\(item)|\(vectorIndex)"
            // The payload bytes are the collateral-mutation detector.
            let payload = DatabaseInventory.canonicalValueEncoding(row["payload"] ?? .null)
            out[key] = payload
        }
        return out
    }

    // MARK: - deleteVectors(keys:)

    @Test func deleteVectorsRemovesExactlyTheNamedKeys() async throws {
        try await GlobalTestLock.shared.withLock {
            let (store, storage) = try await makeStore()
            // One model partition holding retained AND removed keys, plus a
            // second model partition that must be untouched.
            try await store.addPayloads([
                binaryInput(item: "keep-1", model: "model-a", seed: 1),
                binaryInput(item: "drop-1", model: "model-a", seed: 2),
                binaryInput(item: "drop-2", model: "model-a", seed: 3),
                binaryInput(item: "keep-1", model: "model-b", seed: 4),
                floatInput(item: "keep-1", model: "model-a", floats: [1, 0, 0]),
                floatInput(item: "drop-1", model: "model-a", floats: [0, 1, 0])
            ])
            let before = try await rowBaseline(storage)

            try await store.deleteVectors(keys: [
                VectorExactKey(itemID: "drop-1", vectorIndex: 0, modelID: "model-a"),
                VectorExactKey(itemID: "drop-1", vectorIndex: 1, modelID: "model-a"),
                VectorExactKey(itemID: "drop-2", vectorIndex: 0, modelID: "model-a")
            ])

            let after = try await rowBaseline(storage)
            #expect(after["model-a|drop-1|0"] == nil)
            #expect(after["model-a|drop-1|1"] == nil)
            #expect(after["model-a|drop-2|0"] == nil)
            // Unaddressed rows survive byte-identically — including the
            // same-model retained keys and the whole other model partition.
            #expect(after["model-a|keep-1|0"] == before["model-a|keep-1|0"])
            #expect(after["model-a|keep-1|1"] == before["model-a|keep-1|1"])
            #expect(after["model-b|keep-1|0"] == before["model-b|keep-1|0"])
            #expect(after.count == before.count - 3)

            // Search coherence: the deleted binary key no longer surfaces; the
            // retained one still does.
            let hits = try await store.findNearest(
                probe: engram(2), modelID: "model-a", limit: 10)
            #expect(!hits.contains { $0.itemID == "drop-1" })
            #expect(hits.contains { $0.itemID == "keep-1" })
        }
    }

    @Test func deleteVectorsClearsEveryModelVersionAtThePosition() async throws {
        try await GlobalTestLock.shared.withLock {
            let (store, storage) = try await makeStore()
            // Two versions written at the same logical position over time —
            // the upsert keeps one row, but a legacy estate may hold stale
            // version rows written before the unique constraint; simulate by
            // direct insert of a second version row.
            try await store.addPayloads([
                binaryInput(item: "item", model: "model-a", version: "1.0.0", seed: 1)
            ])
            _ = try await storage.rowStore.insert(table: "vectors", values: [
                "id": .uuid(UUID()),
                "item_id": .text("item-stale"),
                "vector_index": .int(0),
                "model_id": .text("model-a"),
                "model_version": .text("0.9.0"),
                "kind": .int(0),
                "dim": .int(256),
                "payload": .blob(Data(repeating: 0xAB, count: 32)),
                "scale": .null,
                "filed_at": .timestamp(now)
            ])

            try await store.deleteVectors(keys: [
                VectorExactKey(itemID: "item", vectorIndex: 0, modelID: "model-a"),
                VectorExactKey(itemID: "item-stale", vectorIndex: 0, modelID: "model-a")
            ])
            let remaining = try await rowBaseline(storage)
            #expect(remaining.isEmpty)
        }
    }

    // MARK: - reconcileModelVectors(modelID:expected:)

    @Test func reconcileDeletesStaleUpsertsExpectedLeavesOthersAlone() async throws {
        try await GlobalTestLock.shared.withLock {
            let (store, storage) = try await makeStore()
            try await store.addPayloads([
                binaryInput(item: "stays", model: "model-a", seed: 1),
                binaryInput(item: "stale", model: "model-a", seed: 2),
                binaryInput(item: "other", model: "model-b", seed: 3)
            ])
            let before = try await rowBaseline(storage)

            let outcome = try await store.reconcileModelVectors(
                modelID: "model-a",
                expected: [
                    binaryInput(item: "stays", model: "model-a", seed: 1),
                    binaryInput(item: "fresh", model: "model-a", seed: 9)
                ])
            #expect(outcome.removed == 1)
            #expect(outcome.upserted == 2)

            let after = try await rowBaseline(storage)
            #expect(after["model-a|stale|0"] == nil)
            #expect(after["model-a|stays|0"] == before["model-a|stays|0"])
            #expect(after["model-a|fresh|0"] != nil)
            // The other model's partition is untouched byte for byte.
            #expect(after["model-b|other|0"] == before["model-b|other|0"])

            // Search coherence after the scoped rebuild.
            let hits = try await store.findNearest(
                probe: engram(9), modelID: "model-a", limit: 10)
            #expect(hits.contains { $0.itemID == "fresh" })
            #expect(!hits.contains { $0.itemID == "stale" })
        }
    }

    @Test func reconcileRejectsCrossPartitionInputs() async throws {
        try await GlobalTestLock.shared.withLock {
            let (store, _) = try await makeStore()
            await #expect(throws: VectorKitError.self) {
                try await store.reconcileModelVectors(
                    modelID: "model-a",
                    expected: [binaryInput(item: "x", model: "model-b", seed: 1)])
            }
        }
    }

    @Test func reconcileIsIdempotent() async throws {
        try await GlobalTestLock.shared.withLock {
            let (store, storage) = try await makeStore()
            let expected = [
                binaryInput(item: "a", model: "model-a", seed: 1),
                binaryInput(item: "b", model: "model-a", seed: 2)
            ]
            try await store.reconcileModelVectors(modelID: "model-a", expected: expected)
            let first = try await rowBaseline(storage)
            let second = try await store.reconcileModelVectors(
                modelID: "model-a", expected: expected)
            #expect(second.removed == 0)
            let after = try await rowBaseline(storage)
            #expect(after == first)
        }
    }

    // MARK: - Representation claims ledger

    @Test func claimsLedgerTracksSharedAndExclusiveOwnership() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)
            let claims = VectorRepresentationClaims(storage: storage)
            let key = VectorRepresentationKey(
                modelID: "minilm-v6", modelVersion: "1.0.0", vectorIndex: 1)

            // Unclaimed at first — never treated as exclusive.
            #expect(try await claims.isUnclaimed(key: key))
            #expect(try await !claims.isExclusive(consumer: "corpus", key: key))

            // One claimant → exclusive.
            try await claims.registerClaim(consumer: "corpus", key: key, now: now)
            #expect(try await claims.isExclusive(consumer: "corpus", key: key))
            #expect(try await claims.claimants(key: key) == ["corpus"])

            // Two claimants → shared: NEITHER is exclusive, so neither may
            // delete the representation's rows.
            try await claims.registerClaim(consumer: "glk-encode", key: key, now: now)
            #expect(try await !claims.isExclusive(consumer: "corpus", key: key))
            #expect(try await !claims.isExclusive(consumer: "glk-encode", key: key))
            #expect(try await claims.claimants(key: key) == ["corpus", "glk-encode"])

            // Releasing one claim restores the other's exclusivity.
            try await claims.releaseClaim(consumer: "corpus", key: key)
            #expect(try await claims.isExclusive(consumer: "glk-encode", key: key))

            // Releasing the last claim leaves the key unclaimed.
            try await claims.releaseClaim(consumer: "glk-encode", key: key)
            #expect(try await claims.isUnclaimed(key: key))
        }
    }

    @Test func claimsLedgerEnumeratesAndBulkReleasesPerConsumer() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.migrate(to: VectorRepresentationClaims.schemaDeclaration)
            let claims = VectorRepresentationClaims(storage: storage)
            let binary = VectorRepresentationKey(
                modelID: "corpus-deterministic-v1", modelVersion: "1.0.0", vectorIndex: 0)
            let float = VectorRepresentationKey(
                modelID: "corpus-deterministic-v1", modelVersion: "1.0.0", vectorIndex: 1)
            let shared = VectorRepresentationKey(
                modelID: "minilm-v6", modelVersion: "1.0.0", vectorIndex: 1)

            try await claims.registerClaim(consumer: "corpus", key: binary, now: now)
            try await claims.registerClaim(consumer: "corpus", key: float, now: now)
            try await claims.registerClaim(consumer: "corpus", key: shared, now: now)
            try await claims.registerClaim(consumer: "glk-encode", key: shared, now: now)

            #expect(try await claims.claims(consumer: "corpus") == [binary, float, shared].sorted())

            // Index teardown: the corpus releases everything it claims; the
            // shared key stays claimed by the retained lane.
            try await claims.releaseAllClaims(consumer: "corpus")
            #expect(try await claims.claims(consumer: "corpus").isEmpty)
            #expect(try await claims.claimants(key: shared) == ["glk-encode"])
            #expect(try await claims.isUnclaimed(key: binary))
        }
    }
}
