// SecurityHardeningTests.swift
//
// Regression tests for SECFIX-WS2-PK planned security hardening (replication).
//
// F5 — Blob delete propagation: a full snapshot replication must delete blobs
//      from the destination that are absent from the source. Prior to the fix,
//      `replicateFull` was additive-only for blobs, leaving orphaned payloads
//      in replicas after the source had hard-deleted them. This is a data-
//      lifecycle defect: deleted data must not survive in replicas.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitReplication

// MARK: - Schema

private let replicationSecSchema = SchemaDeclaration(
    kitID: "SecFixReplicationTestKit",
    version: 1,
    tables: [
        TableDeclaration(
            name: "docs",
            columns: [.uuid("id"), .text("title")],
            primaryKey: ["id"]
        )
    ]
)

// MARK: - Factories

private func makeInMemory() async throws -> InMemoryStorage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    try await storage.open(schema: replicationSecSchema)
    return storage
}

// MARK: - Tests

@Suite("SecurityHardeningTests — F5 blob delete propagation")
struct F5BlobDeletePropagationTests {

    /// When a full snapshot replication is performed and the source has fewer blobs
    /// than the destination, the replication must delete the extra blobs from the
    /// destination. Without the fix, stale blobs would accumulate in replicas.
    @Test func fullReplicationDeletesOrphanBlobs() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Blob A is present in both source and destination.
        let keyA = "docs/blob/A"
        let keyB = "docs/blob/B"  // present only in destination (stale)

        try await source.blobStore.put(key: keyA, bytes: Data([0x01]))
        try await destination.blobStore.put(key: keyA, bytes: Data([0x01]))
        try await destination.blobStore.put(key: keyB, bytes: Data([0x02, 0x03]))

        // Verify pre-condition: destination has both blobs.
        let preKeys = try await destination.blobStore.listKeys()
        #expect(preKeys.contains(keyA), "Pre-condition: destination must have blob A")
        #expect(preKeys.contains(keyB), "Pre-condition: destination must have blob B (the stale one)")

        // Replicate source → destination.
        _ = try await StorageReplicator.replicate(
            from: source,
            to: destination,
            schema: replicationSecSchema
        )

        // After replication, destination must have blob A (present in source)
        // and must NOT have blob B (absent from source).
        let postKeys = try await destination.blobStore.listKeys()
        #expect(postKeys.contains(keyA), "Blob A (present in source) must remain in destination")
        #expect(
            !postKeys.contains(keyB),
            "Blob B (absent from source) must have been deleted from destination (F5)"
        )
    }

    /// When the source has NO blobs, all blobs in the destination must be deleted.
    @Test func fullReplicationDeletesAllOrphanBlobsWhenSourceIsEmpty() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        // Pre-populate destination with two blobs; source has none.
        try await destination.blobStore.put(key: "orphan/1", bytes: Data([0xAA]))
        try await destination.blobStore.put(key: "orphan/2", bytes: Data([0xBB]))

        _ = try await StorageReplicator.replicate(
            from: source,
            to: destination,
            schema: replicationSecSchema
        )

        let postKeys = try await destination.blobStore.listKeys()
        #expect(
            postKeys.isEmpty,
            "All destination blobs must be deleted when source has no blobs; got: \(postKeys)"
        )
    }

    /// When source and destination have the same blobs, no blob deletion occurs
    /// and all source blobs survive in the destination.
    @Test func fullReplicationPreservesMatchingBlobs() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()

        let keys = ["match/1", "match/2", "match/3"]
        for key in keys {
            try await source.blobStore.put(key: key, bytes: Data([0x10]))
            try await destination.blobStore.put(key: key, bytes: Data([0x10]))
        }

        _ = try await StorageReplicator.replicate(
            from: source,
            to: destination,
            schema: replicationSecSchema
        )

        let postKeys = try await destination.blobStore.listKeys()
        for key in keys {
            #expect(postKeys.contains(key), "Matching blob \(key) must survive replication")
        }
        #expect(postKeys.count == keys.count, "No extra or missing blobs after replication")
    }
}
