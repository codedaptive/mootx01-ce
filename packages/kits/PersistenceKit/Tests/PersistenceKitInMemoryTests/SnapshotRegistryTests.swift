// SnapshotRegistryTests.swift
//
// Tests for snapshot registry + attestations (ADR-017 §15).
// Parts 1 and 2 of mission NT-P3.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct SnapshotRegistryTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    /// Schema including snapshot tables.
    func snapshotSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "SnapshotTestKit",
            version: 1,
            tables: [
                SnapshotSchema.registryTable,
                SnapshotSchema.attestationsTable,
            ]
        )
    }

    // MARK: - Part 1: Snapshot registry CRUD

    @Test func createSnapshotMintsIdAndRecordsHlc() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 0)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let record = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: hlc,
            label: "test-snap",
            createdAt: now,
            attestations: []
        )

        #expect(record.hlc == hlc)
        #expect(record.label == "test-snap")
        #expect(record.createdAt == now)
        #expect(!record.snapshotId.rawValue.isEmpty)
    }

    @Test func listSnapshotsOrderedByHlc() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let snap1 = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0),
            label: "first",
            createdAt: now,
            attestations: []
        )
        let snap2 = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 3_000, logicalCount: 1, nodeID: 0),
            label: "third",
            createdAt: now,
            attestations: []
        )
        let snap3 = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0),
            label: "second",
            createdAt: now,
            attestations: []
        )

        let list = try await SnapshotRegistryOps.listSnapshots(rowStore: storage.rowStore)

        #expect(list.count == 3)
        // Ordered by HLC ascending: snap1 (1000), snap3 (2000), snap2 (3000).
        #expect(list[0].snapshotId == snap1.snapshotId)
        #expect(list[1].snapshotId == snap3.snapshotId)
        #expect(list[2].snapshotId == snap2.snapshotId)
    }

    @Test func deleteSnapshotRemovesRegistryRow() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0),
            label: nil,
            createdAt: now,
            attestations: []
        )

        let deleted = try await SnapshotRegistryOps.deleteSnapshot(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(deleted == true)

        let list = try await SnapshotRegistryOps.listSnapshots(rowStore: storage.rowStore)
        #expect(list.isEmpty)
    }

    @Test func deleteNonexistentSnapshotReturnsFalse() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let deleted = try await SnapshotRegistryOps.deleteSnapshot(
            rowStore: storage.rowStore,
            snapshotId: SnapshotId("nonexistent")
        )
        #expect(deleted == false)
    }

    @Test func nilLabelRoundTrips() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0),
            label: nil,
            createdAt: now,
            attestations: []
        )

        let list = try await SnapshotRegistryOps.listSnapshots(rowStore: storage.rowStore)
        #expect(list.count == 1)
        #expect(list[0].label == nil)
    }

    // MARK: - Part 2: Snapshot attestations

    @Test func attestationsWrittenAtCreateTime() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hlc = HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)

        // Attestations use a placeholder snapshot id (overwritten by createSnapshot).
        let atts = [
            SnapshotAttestation(
                snapshotId: SnapshotId("placeholder"),
                subjectKind: "wing",
                subjectId: "wing-1",
                merkleRoot: "abc123",
                keyVersion: nil
            ),
            SnapshotAttestation(
                snapshotId: SnapshotId("placeholder"),
                subjectKind: "drawer",
                subjectId: "drawer-42",
                merkleRoot: "def456",
                keyVersion: 2
            ),
        ]

        let snap = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: hlc,
            label: "attested",
            createdAt: now,
            attestations: atts
        )

        let readBack = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )

        #expect(readBack.count == 2)

        // Ordered by (subject_kind, subject_id) ascending.
        let drawer = readBack.first { $0.subjectKind == "drawer" }!
        #expect(drawer.subjectId == "drawer-42")
        #expect(drawer.merkleRoot == "def456")
        #expect(drawer.keyVersion == 2)
        #expect(drawer.snapshotId == snap.snapshotId)

        let wing = readBack.first { $0.subjectKind == "wing" }!
        #expect(wing.subjectId == "wing-1")
        #expect(wing.merkleRoot == "abc123")
        #expect(wing.keyVersion == nil)
        #expect(wing.snapshotId == snap.snapshotId)
    }

    @Test func deleteSnapshotCascadesToAttestations() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0),
            label: nil,
            createdAt: now,
            attestations: [
                SnapshotAttestation(
                    snapshotId: SnapshotId("placeholder"),
                    subjectKind: "wing",
                    subjectId: "w1",
                    merkleRoot: "root1"
                ),
            ]
        )

        // Verify attestation exists.
        let before = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(before.count == 1)

        // Delete snapshot — should remove attestations too.
        let deleted = try await SnapshotRegistryOps.deleteSnapshot(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(deleted == true)

        let after = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(after.isEmpty)
    }

    @Test func attestationsForNonexistentSnapshotReturnsEmpty() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let result = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: SnapshotId("ghost")
        )
        #expect(result.isEmpty)
    }

    @Test func createSnapshotRoundTripFullCycle() async throws {
        let storage = makeStorage()
        try await storage.open(schema: snapshotSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hlc = HLC(physicalTime: 10_000, logicalCount: 5, nodeID: 0)

        // Create with attestations.
        let snap = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: hlc,
            label: "full-cycle",
            createdAt: now,
            attestations: [
                SnapshotAttestation(
                    snapshotId: SnapshotId("_"),
                    subjectKind: "estate",
                    subjectId: "e1",
                    merkleRoot: "rootHash",
                    keyVersion: 1
                ),
            ]
        )

        // List — should contain the snapshot.
        let listed = try await SnapshotRegistryOps.listSnapshots(rowStore: storage.rowStore)
        #expect(listed.count == 1)
        #expect(listed[0].snapshotId == snap.snapshotId)
        #expect(listed[0].hlc == hlc)
        #expect(listed[0].label == "full-cycle")

        // Read attestations.
        let atts = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(atts.count == 1)
        #expect(atts[0].merkleRoot == "rootHash")

        // Delete.
        let deleted = try await SnapshotRegistryOps.deleteSnapshot(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(deleted == true)

        // Verify empty.
        let afterList = try await SnapshotRegistryOps.listSnapshots(rowStore: storage.rowStore)
        #expect(afterList.isEmpty)
        let afterAtts = try await SnapshotRegistryOps.attestations(
            rowStore: storage.rowStore,
            snapshotId: snap.snapshotId
        )
        #expect(afterAtts.isEmpty)
    }
}
