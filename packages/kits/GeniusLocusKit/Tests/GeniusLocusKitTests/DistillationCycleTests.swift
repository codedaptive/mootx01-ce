// DistillationCycleTests.swift
//
// Tests for the assignCluster write-path and runDistillationSweep (DG5).
//
// Coverage:
//  T1  assignCluster seeds a new single-member open cluster for an
//      unclustered drawer (no VectorKit hit within Hamming 64).
//  T2  assignCluster joins an existing open cluster when the nearest
//      neighbor is within Hamming distance ≤ 64.
//  T3  runDistillationSweep success: factoid drawer captured in "_distilled"
//      room; sweep returns factoidCount = 1.
//  T4  runDistillationSweep success: M _distilled_from tunnels written
//      (source = factoid, target = each source drawer).
//  T5  runDistillationSweep success: featureFingerprint stored in VectorKit
//      "distillation-features-v1" lane under the factoidID.
//  T6  runDistillationSweep held: cluster with SNR < 2.0 marked 'held'.
//  T7  runDistillationSweep failed: cluster with !succeeded and SNR ≥ 2.0
//      marked 'failed'.

import Testing
import Foundation
import EngramLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("DistillationCycle — cluster assignment and distillation sweep (DG5)")
struct DistillationCycleTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let modelID = "minilm-v6"

    // MARK: - Fixtures

    /// Open one estate with a VectorStore registered. Returns the kit, handle,
    /// estate storage, and vector store so each test can inspect rows directly.
    ///
    /// Two-step schema setup:
    ///   1. Estate.create applies the LocusKit schema (drawers, tunnels, etc.).
    ///   2. storage.open(schema: GeniusLocusKitSchema) adds GLK-specific tables
    ///      (memory_clusters) via the separate GeniusLocusKit kitID migration
    ///      chain, without conflicting with LocusKit's tables.
    private func openEstate() async throws -> (
        GeniusLocusKit, EstateHandle, InMemoryStorage, VectorStore
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-dg5-cycle-tests")
        let estateStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        // Apply the GLK composite schema so memory_clusters and other GLK-specific
        // tables exist. InMemoryStorage.open(schema:) is idempotent for already-migrated
        // tables and applies only the new GLK kitID migrations.
        try await estateStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle, estateStorage, vectorStore)
    }

    /// Capture `count` ordinary drawers in "inbox" via the GLK verb surface
    /// and return their IDs. Uses kit.capture(handle, frame) to stay on the
    /// actor's executor without needing estate(for:).
    private func captureDrawers(
        count: Int,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let frame = CaptureFrame(
                content: "Source memory \(i) mentioning Alice, Bob, Carol",
                channel: .typed,
                room: "inbox",
                latticeAnchor: LatticeAnchor.udc("000.000"),
                addedBy: "test-dg5",
                embeddingModelID: modelID
            )
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
        }
        return ids
    }

    /// Insert an open cluster row directly via the estate's rowStore so tests
    /// can exercise runDistillationSweep without going through assignCluster.
    private func seedOpenCluster(
        memberIDs: [String],
        storage: InMemoryStorage
    ) async throws -> String {
        let clusterID = UUID().uuidString
        let memberData = try JSONEncoder().encode(memberIDs)
        _ = try await storage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(clusterID),
                "status": .text("open"),
                "snr": .null,
                "member_ids": .json(memberData),
                "member_count": .int(Int64(memberIDs.count)),
                "factoid_id": .null,
                "held_reason": .null,
                "filed_at": .timestamp(t0),
                "updated_at": .timestamp(t0)
            ]
        )
        return clusterID
    }

    // MARK: - Stub distillFn closures

    /// Stub that returns a successful DistillationOutput (conf = 0.80, SNR = 3.5).
    private func successFn(
        memberCount: Int
    ) -> @Sendable (DistillationInput) -> DistillationOutput {
        let header = "[DIST|conf=0.80|src=\(memberCount)|snr=3.50|delta=STATIC] test factoid"
        return { _ in
            DistillationOutput(
                drawerContent: header,
                confidence: 0.80,
                uncertain: false,
                snr: 3.5,
                deltaType: nil,
                succeeded: true,
                failureReason: nil,
                featureFingerprint: Engram.zero
            )
        }
    }

    /// Stub that returns a held DistillationOutput (succeeded = false, SNR = 1.0 < 2.0).
    private var heldFn: @Sendable (DistillationInput) -> DistillationOutput {
        return { _ in
            DistillationOutput(
                drawerContent: "",
                confidence: 0.0,
                uncertain: false,
                snr: 1.0,
                deltaType: nil,
                succeeded: false,
                failureReason: "SNR 1.0 below gate 2.0",
                featureFingerprint: Engram.zero
            )
        }
    }

    /// Stub that returns a failed DistillationOutput
    /// (!succeeded, SNR = 2.5 ≥ 2.0 → falls through to failed branch).
    private var failedFn: @Sendable (DistillationInput) -> DistillationOutput {
        return { _ in
            DistillationOutput(
                drawerContent: "",
                confidence: 0.2,
                uncertain: false,
                snr: 2.5,
                deltaType: nil,
                succeeded: false,
                failureReason: "Confidence 0.2 below 0.4 threshold",
                featureFingerprint: Engram.zero
            )
        }
    }

    // MARK: - T1: assignCluster seeds a new cluster

    @Test("assignCluster seeds a new single-member open cluster")
    func assignClusterSeedsNewCluster() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let drawerID = UUID().uuidString

        try await kit.assignCluster(
            handle: handle,
            engram: Engram.zero,
            drawerID: drawerID,
            modelID: modelID,
            now: t0
        )

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "status"), .text("open")),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1, "one open cluster must be seeded for an unclustered drawer")

        if let row = rows.first, let data = jsonData(row["member_ids"]) {
            let ids = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            #expect(ids.contains(drawerID), "seeded cluster must contain the new drawerID")
            #expect(ids.count == 1, "new cluster must have member_count = 1")
        }
    }

    // MARK: - T2: assignCluster joins an existing cluster

    @Test("assignCluster joins an existing open cluster when nearest neighbor is within Hamming 64")
    func assignClusterJoinsExistingCluster() async throws {
        let (kit, handle, storage, vectorStore) = try await openEstate()

        // File drawer1's engram (Engram.zero) in VectorKit.
        let drawer1ID = UUID().uuidString
        try await vectorStore.addVector(
            itemID: drawer1ID,
            engram: Engram.zero,
            modelID: modelID,
            modelVersion: "1",
            filedAt: t0
        )
        // Seed an open cluster containing drawer1.
        _ = try await seedOpenCluster(memberIDs: [drawer1ID], storage: storage)

        // Assign drawer2 with Engram.zero — Hamming distance to drawer1 = 0 ≤ 64.
        let drawer2ID = UUID().uuidString
        try await kit.assignCluster(
            handle: handle,
            engram: Engram.zero,
            drawerID: drawer2ID,
            modelID: modelID,
            now: t0
        )

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "status"), .text("open")),
            orderBy: [], limit: nil, offset: nil
        )
        // drawer2 must join the existing cluster, not seed a second one.
        #expect(rows.count == 1, "drawer2 must join the existing cluster, not seed a new one")

        if let row = rows.first, let data = jsonData(row["member_ids"]) {
            let ids = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            #expect(ids.count == 2, "cluster must have 2 members after drawer2 joins")
            #expect(ids.contains(drawer2ID), "cluster must contain drawer2")
        }
    }

    // MARK: - T3 + T4 + T5: runDistillationSweep success path

    @Test("runDistillationSweep success: factoid drawer, tunnels, and VectorKit entry created")
    func runDistillationSweepSuccess() async throws {
        let (kit, handle, storage, vectorStore) = try await openEstate()

        // Capture 3 source drawers so fetchDrawerRows can resolve their content.
        let sourceIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        _ = try await seedOpenCluster(memberIDs: sourceIDs, storage: storage)

        let factoidCount = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: successFn(memberCount: 3),
            now: t0
        )

        // T3: Sweep returns count = 1.
        #expect(factoidCount == 1, "sweep must return factoidCount = 1 for one successful cluster")

        // T3: One drawer in "_distilled" room.
        let distilledRows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "room"), .text("_distilled")),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(distilledRows.count == 1, "exactly one _distilled drawer must be created")

        guard let factoidRow = distilledRows.first,
              let factoidID = stringValue(factoidRow["id"]) else {
            Issue.record("no factoid drawer found in drawers table")
            return
        }

        // T4: 3 _distilled_from tunnels with source = factoidID, one per source drawer.
        let tunnelRows = try await storage.rowStore.query(
            table: "tunnels",
            where: .and([
                .eq(Column(table: "tunnels", name: "label"), .text("_distilled_from")),
                .eq(Column(table: "tunnels", name: "sourceDrawerId"), .text(factoidID))
            ]),
            orderBy: [], limit: nil, offset: nil
        )
        #expect(tunnelRows.count == 3, "3 _distilled_from tunnels must be written, one per source drawer")

        // T5: "distillation-features-v1" lane has one entry for factoidID.
        let vectorMatches = try await vectorStore.findNearest(
            probe: Engram.zero,
            modelID: "distillation-features-v1",
            limit: 5
        )
        #expect(
            vectorMatches.contains(where: { $0.itemID == factoidID }),
            "distillation-features-v1 lane must contain an entry for the factoidID"
        )
    }

    // MARK: - T6: held cluster

    @Test("runDistillationSweep marks cluster 'held' when SNR < 2.0")
    func runDistillationSweepHeld() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let sourceIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let clusterID = try await seedOpenCluster(memberIDs: sourceIDs, storage: storage)

        _ = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: heldFn,
            now: t0
        )

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(clusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let status = rows.first.flatMap { stringValue($0["status"]) }
        #expect(status == "held", "cluster with SNR < 2.0 must be marked 'held'")
    }

    // MARK: - T7: failed cluster

    @Test("runDistillationSweep marks cluster 'failed' when !succeeded and SNR >= 2.0")
    func runDistillationSweepFailed() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let sourceIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let clusterID = try await seedOpenCluster(memberIDs: sourceIDs, storage: storage)

        _ = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: failedFn,
            now: t0
        )

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(clusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let status = rows.first.flatMap { stringValue($0["status"]) }
        #expect(status == "failed", "cluster with !succeeded and SNR >= 2.0 must be marked 'failed'")
    }

    // MARK: - TypedValue extraction helpers

    private func stringValue(_ v: TypedValue?) -> String? {
        guard case .text(let s) = v else { return nil }
        return s
    }

    private func jsonData(_ v: TypedValue?) -> Data? {
        switch v {
        case .json(let d): return d
        case .blob(let d): return d
        default: return nil
        }
    }
}
