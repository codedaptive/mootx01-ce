// SnapshotReplicationTests.swift
//
// Snapshot replication atomicity conformance test.
// Part 6 of mission NT-P3.
//
// Verifies that snapshot registry + attestations replicate atomically:
// no partial snapshot where the registry row is present but
// attestations are missing.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import PersistenceKitReplication

// MARK: - Schema

private let snapshotReplicationSchema = SchemaDeclaration(
    kitID: "SnapshotReplicationTestKit",
    version: 1,
    tables: [
        SnapshotSchema.registryTable,
        SnapshotSchema.attestationsTable,
    ]
)

// MARK: - Factories

private func makeInMemory() async throws -> InMemoryStorage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    try await storage.open(schema: snapshotReplicationSchema)
    return storage
}

private func makeSQLite() async throws -> (SQLiteStorage, URL) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("snap-repl-\(UUID().uuidString).sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url)
    ))
    try await storage.open(schema: snapshotReplicationSchema)
    return (storage, url)
}

private func removeSQLite(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

// MARK: - Tests

/// Poll `condition` up to ~5 s (50 × 100 ms) rather than waiting one fixed
/// interval for the observer AsyncStream to drain into the dirty-set.
/// `observe()` registers synchronously, but delivery runs on a detached task,
/// and under the parallel full-lane's load that task can land past any single
/// fixed sleep — the flake class fixed in 9629d17a (ObserverSink) and 14d4dc4a
/// (PK-TEST-01). Returns as soon as the condition holds; the trailing
/// assertion then confirms it (and reports the real value if it never did).
private func pollObserver(_ condition: () async -> Bool) async throws {
    for _ in 0..<50 where !(await condition()) {
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
    }
}


@Suite("SnapshotReplicationTests")
struct SnapshotReplicationTests {

    /// Helper: create a snapshot with attestations on source, replicate to
    /// destination, verify both registry and attestations arrived.
    private func verifyAtomicReplication(
        source: any Storage,
        destination: any Storage
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hlc = HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)

        // Start replication session BEFORE writes so observer catches them.
        let session = IncrementalReplicationSession.start(
            source: source,
            schema: snapshotReplicationSchema
        )

        // Small delay to let observer subscriptions activate.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Create snapshot with two attestations on source.
        let snap = try await SnapshotRegistryOps.createSnapshot(
            rowStore: source.rowStore,
            hlc: hlc,
            label: "repl-test",
            createdAt: now,
            attestations: [
                SnapshotAttestation(
                    snapshotId: SnapshotId("_"),
                    subjectKind: "wing",
                    subjectId: "w1",
                    merkleRoot: "root-wing-1",
                    keyVersion: nil
                ),
                SnapshotAttestation(
                    snapshotId: SnapshotId("_"),
                    subjectKind: "drawer",
                    subjectId: "d42",
                    merkleRoot: "root-drawer-42",
                    keyVersion: 3
                ),
            ]
        )

        // Small delay for observer to accumulate dirty set.
        try await pollObserver { await session.dirtySet.count() >= 3 }

        // Replicate.
        let cursor = ReplicationCursor(hlcWatermark: nil, rowsWritten: 0, auditEventsWritten: 0)
        _ = try await session.sync(
            from: source,
            to: destination,
            fromCursor: cursor
        )

        // Verify registry row arrived.
        let destSnapshots = try await SnapshotRegistryOps.listSnapshots(
            rowStore: destination.rowStore
        )
        #expect(destSnapshots.count == 1)
        #expect(destSnapshots[0].snapshotId == snap.snapshotId)
        #expect(destSnapshots[0].hlc == hlc)
        #expect(destSnapshots[0].label == "repl-test")

        // Verify attestations arrived atomically (not partial).
        let destAtts = try await SnapshotRegistryOps.attestations(
            rowStore: destination.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(destAtts.count == 2)

        let wing = destAtts.first { $0.subjectKind == "wing" }
        #expect(wing != nil)
        #expect(wing?.merkleRoot == "root-wing-1")
        #expect(wing?.keyVersion == nil)

        let drawer = destAtts.first { $0.subjectKind == "drawer" }
        #expect(drawer != nil)
        #expect(drawer?.merkleRoot == "root-drawer-42")
        #expect(drawer?.keyVersion == 3)
    }

    @Test func inMemoryToInMemory() async throws {
        let source = try await makeInMemory()
        let destination = try await makeInMemory()
        try await verifyAtomicReplication(source: source, destination: destination)
    }

    @Test func sqliteToSQLite() async throws {
        let (source, srcUrl) = try await makeSQLite()
        let (destination, dstUrl) = try await makeSQLite()
        defer {
            removeSQLite(at: srcUrl)
            removeSQLite(at: dstUrl)
        }
        try await verifyAtomicReplication(source: source, destination: destination)
    }

    @Test func inMemoryToSQLite() async throws {
        let source = try await makeInMemory()
        let (destination, dstUrl) = try await makeSQLite()
        defer { removeSQLite(at: dstUrl) }
        try await verifyAtomicReplication(source: source, destination: destination)
    }
}
