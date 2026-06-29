// GCPinTests.swift
//
// Tests for GC pin via snapshot-registry minimum HLC (ADR-017 §15).
// Part 5 of mission NT-P3.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct GCPinTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func pinSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "GCPinTestKit",
            version: 1,
            tables: [
                SnapshotSchema.registryTable,
                SnapshotSchema.attestationsTable,
            ]
        )
    }

    @Test func noSnapshotsReturnsNilMinimum() async throws {
        let storage = makeStorage()
        try await storage.open(schema: pinSchema())

        let min = try await GCPin.minimumRetainableHlc(rowStore: storage.rowStore)
        #expect(min == nil)
    }

    @Test func noSnapshotsMeansNothingPinned() async throws {
        let storage = makeStorage()
        try await storage.open(schema: pinSchema())

        let pinned = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)
        )
        #expect(pinned == false)
    }

    @Test func singleSnapshotPinsNewerRows() async throws {
        let storage = makeStorage()
        try await storage.open(schema: pinSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapHlc = HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)

        _ = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: snapHlc,
            label: "pin-test",
            createdAt: now,
            attestations: []
        )

        let min = try await GCPin.minimumRetainableHlc(rowStore: storage.rowStore)
        #expect(min == snapHlc)

        // Row at the snapshot HLC is pinned.
        let pinnedAtSnap = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: snapHlc
        )
        #expect(pinnedAtSnap == true)

        // Row newer than snapshot is pinned.
        let pinnedNewer = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 10_000, logicalCount: 1, nodeID: 0)
        )
        #expect(pinnedNewer == true)

        // Row older than snapshot is NOT pinned (vacuumable).
        let pinnedOlder = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 1_000, logicalCount: 1, nodeID: 0)
        )
        #expect(pinnedOlder == false)
    }

    @Test func multipleSnapshotsUseOldest() async throws {
        let storage = makeStorage()
        try await storage.open(schema: pinSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Create snapshots at HLC 3000, 7000, 5000.
        for pt: Int64 in [3_000, 7_000, 5_000] {
            _ = try await SnapshotRegistryOps.createSnapshot(
                rowStore: storage.rowStore,
                hlc: HLC(physicalTime: pt, logicalCount: 1, nodeID: 0),
                label: nil,
                createdAt: now,
                attestations: []
            )
        }

        // Minimum should be 3000 (the oldest).
        let min = try await GCPin.minimumRetainableHlc(rowStore: storage.rowStore)
        #expect(min == HLC(physicalTime: 3_000, logicalCount: 1, nodeID: 0))

        // Row at 2000 is NOT pinned.
        let old = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0)
        )
        #expect(old == false)

        // Row at 4000 IS pinned.
        let mid = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 4_000, logicalCount: 1, nodeID: 0)
        )
        #expect(mid == true)
    }

    @Test func deletingOldestSnapshotMovesPin() async throws {
        let storage = makeStorage()
        try await storage.open(schema: pinSchema())

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let snap1 = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0),
            label: nil,
            createdAt: now,
            attestations: []
        )
        _ = try await SnapshotRegistryOps.createSnapshot(
            rowStore: storage.rowStore,
            hlc: HLC(physicalTime: 8_000, logicalCount: 1, nodeID: 0),
            label: nil,
            createdAt: now,
            attestations: []
        )

        // Pin is at 2000.
        let before = try await GCPin.minimumRetainableHlc(rowStore: storage.rowStore)
        #expect(before == HLC(physicalTime: 2_000, logicalCount: 1, nodeID: 0))

        // Row at 5000 is pinned.
        let pinnedBefore = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)
        )
        #expect(pinnedBefore == true)

        // Delete the oldest snapshot.
        _ = try await SnapshotRegistryOps.deleteSnapshot(
            rowStore: storage.rowStore,
            snapshotId: snap1.snapshotId
        )

        // Pin moves to 8000.
        let after = try await GCPin.minimumRetainableHlc(rowStore: storage.rowStore)
        #expect(after == HLC(physicalTime: 8_000, logicalCount: 1, nodeID: 0))

        // Row at 5000 is now NOT pinned.
        let pinnedAfter = try await GCPin.isPinned(
            rowStore: storage.rowStore,
            rowHlc: HLC(physicalTime: 5_000, logicalCount: 1, nodeID: 0)
        )
        #expect(pinnedAfter == false)
    }
}
