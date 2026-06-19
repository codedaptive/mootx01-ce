// ClusterStatusReadsTests.swift
//
// Tests for the cluster status read API added in the glk-cluster-status-api
// feature (ClusterStatusReads.swift) and the per-cluster / includeHeld
// targeting extension to runDistillationSweep (DistillationCycle.swift).
//
// Coverage:
//  S1  clusterIDs(withStatus:) returns IDs for status='held'.
//  S2  clusterIDs(withStatus:) returns IDs for status='failed'.
//  S3  clusterIDs(withStatus:) returns empty for status with no matches.
//  S4  heldClusterIDs convenience wrapper returns the same result as
//      clusterIDs(withStatus:"held").
//  S5  failedClusterIDs convenience wrapper returns the same result as
//      clusterIDs(withStatus:"failed").
//  S6  clusterIDs(withStatus:) throws estateNotOpen for an unknown handle.
//  S7  runDistillationSweep with a targeted clusterID processes only that
//      cluster; a sibling open cluster is untouched.
//  S8  runDistillationSweep with includeHeld:true processes a held cluster
//      (giving it another distillation attempt).
//  S9  runDistillationSweep with includeHeld:false leaves held clusters alone.

import Testing
import Foundation
import EngramLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("ClusterStatusReads — status query API and sweep targeting")
struct ClusterStatusReadsTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_100_000)
    private let modelID = "minilm-v6"

    // MARK: - Fixtures

    /// Open one estate with a VectorStore registered. Returns the kit, handle,
    /// estate storage, and vector store so tests can inspect rows directly.
    private func openEstate() async throws -> (
        GeniusLocusKit, EstateHandle, InMemoryStorage, VectorStore
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-cluster-status-tests")
        let estateStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        try await estateStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle, estateStorage, vectorStore)
    }

    /// Insert a cluster row with an explicit status directly into memory_clusters.
    private func seedCluster(
        status: String,
        memberIDs: [String],
        storage: InMemoryStorage
    ) async throws -> String {
        let clusterID = UUID().uuidString
        let memberData = try JSONEncoder().encode(memberIDs)
        _ = try await storage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(clusterID),
                "status": .text(status),
                "snr": .float(1.5),
                "member_ids": .json(memberData),
                "member_count": .int(Int64(memberIDs.count)),
                "factoid_id": .null,
                "held_reason": status == "held" ? .text("SNR 1.5 below gate 2.0") : .null,
                "filed_at": .timestamp(t0),
                "updated_at": .timestamp(t0)
            ]
        )
        return clusterID
    }

    /// Capture `count` source drawers and return their IDs.
    private func captureDrawers(
        count: Int,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let frame = CaptureFrame(
                content: "Cluster status test memory \(i) — Alice, Bob, Carol",
                channel: .typed,
                room: "inbox",
                latticeAnchor: LatticeAnchor.udc("000"),
                addedBy: "test-cluster-status",
                embeddingModelID: modelID
            )
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
        }
        return ids
    }

    // Stub: succeeds (conf 0.80, SNR 3.5)
    private let successFn: @Sendable (DistillationInput) -> DistillationOutput = { _ in
        DistillationOutput(
            drawerContent: "[DIST|conf=0.80|src=3|snr=3.50|delta=STATIC] test factoid",
            confidence: 0.80,
            uncertain: false,
            snr: 3.5,
            deltaType: nil,
            succeeded: true,
            failureReason: nil,
            featureFingerprint: Engram.zero
        )
    }

    // Stub: held (SNR 1.0 < 2.0)
    private let heldFn: @Sendable (DistillationInput) -> DistillationOutput = { _ in
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

    // Stub: failed (SNR 2.5 ≥ 2.0, !succeeded → falls through to failed branch)
    private let failedFn: @Sendable (DistillationInput) -> DistillationOutput = { _ in
        DistillationOutput(
            drawerContent: "",
            confidence: 0.2,
            uncertain: false,
            snr: 2.5,
            deltaType: nil,
            succeeded: false,
            failureReason: "confidence below threshold",
            featureFingerprint: Engram.zero
        )
    }

    // MARK: - S1: clusterIDs(withStatus:) for held

    @Test("clusterIDs(withStatus: held) returns matching cluster IDs")
    func clusterIDsWithStatusHeld() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let memberIDs = (0..<3).map { _ in UUID().uuidString }
        let heldID = try await seedCluster(status: "held", memberIDs: memberIDs, storage: storage)
        // Seed an open cluster that must NOT appear in held results.
        _ = try await seedCluster(status: "open", memberIDs: memberIDs, storage: storage)

        let result = try await kit.clusterIDs(withStatus: "held", handle: handle)
        #expect(result == [heldID], "only the held cluster must be returned")
    }

    // MARK: - S2: clusterIDs(withStatus:) for failed

    @Test("clusterIDs(withStatus: failed) returns matching cluster IDs")
    func clusterIDsWithStatusFailed() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let memberIDs = (0..<3).map { _ in UUID().uuidString }
        let failedID = try await seedCluster(status: "failed", memberIDs: memberIDs, storage: storage)
        _ = try await seedCluster(status: "open", memberIDs: memberIDs, storage: storage)

        let result = try await kit.clusterIDs(withStatus: "failed", handle: handle)
        #expect(result == [failedID], "only the failed cluster must be returned")
    }

    // MARK: - S3: clusterIDs(withStatus:) returns empty when no matches

    @Test("clusterIDs(withStatus: distilled) returns empty when estate has no distilled clusters")
    func clusterIDsWithStatusDistilledEmpty() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let memberIDs = (0..<3).map { _ in UUID().uuidString }
        _ = try await seedCluster(status: "open", memberIDs: memberIDs, storage: storage)

        let result = try await kit.clusterIDs(withStatus: "distilled", handle: handle)
        #expect(result.isEmpty, "no distilled clusters should be found in a fresh estate")
    }

    // MARK: - S4: heldClusterIDs convenience wrapper

    @Test("heldClusterIDs returns same result as clusterIDs(withStatus: held)")
    func heldClusterIDsConvenience() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let memberIDs = (0..<3).map { _ in UUID().uuidString }
        _ = try await seedCluster(status: "held", memberIDs: memberIDs, storage: storage)
        _ = try await seedCluster(status: "held", memberIDs: memberIDs, storage: storage)

        let viaConvenience = try await kit.heldClusterIDs(handle: handle)
        let viaDirect = try await kit.clusterIDs(withStatus: "held", handle: handle)
        #expect(
            Set(viaConvenience) == Set(viaDirect),
            "heldClusterIDs must return the same IDs as clusterIDs(withStatus: held)"
        )
    }

    // MARK: - S5: failedClusterIDs convenience wrapper

    @Test("failedClusterIDs returns same result as clusterIDs(withStatus: failed)")
    func failedClusterIDsConvenience() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        let memberIDs = (0..<3).map { _ in UUID().uuidString }
        _ = try await seedCluster(status: "failed", memberIDs: memberIDs, storage: storage)

        let viaConvenience = try await kit.failedClusterIDs(handle: handle)
        let viaDirect = try await kit.clusterIDs(withStatus: "failed", handle: handle)
        #expect(
            viaConvenience == viaDirect,
            "failedClusterIDs must return the same IDs as clusterIDs(withStatus: failed)"
        )
    }

    // MARK: - S6: estateNotOpen throws for a stale (closed) handle

    @Test("clusterIDs(withStatus:) throws estateNotOpen for a stale handle")
    func clusterIDsThrowsForStaleHandle() async throws {
        let (kit, handle, _, _) = try await openEstate()
        // Close the estate so the handle becomes stale.
        try await kit.close(handle)
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.clusterIDs(withStatus: "held", handle: handle)
        }
    }

    // MARK: - S7: targeted clusterID sweep only touches that cluster

    @Test("runDistillationSweep with clusterID only processes the targeted cluster")
    func sweepTargetedClusterIDOnly() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        // Two open clusters, each with 3 source drawers.
        let targetDrawerIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let siblingDrawerIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)

        let targetClusterID = UUID().uuidString
        let siblingClusterID = UUID().uuidString

        for (clusterID, memberIDs) in [
            (targetClusterID, targetDrawerIDs),
            (siblingClusterID, siblingDrawerIDs)
        ] {
            let memberData = try JSONEncoder().encode(memberIDs)
            _ = try await storage.rowStore.insert(
                table: "memory_clusters",
                values: [
                    "id": .text(clusterID),
                    "status": .text("open"),
                    "snr": .null,
                    "member_ids": .json(memberData),
                    "member_count": .int(3),
                    "factoid_id": .null,
                    "held_reason": .null,
                    "filed_at": .timestamp(t0),
                    "updated_at": .timestamp(t0)
                ]
            )
        }

        // Sweep only the target cluster with the success stub.
        let count = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: successFn,
            now: t0,
            clusterID: targetClusterID
        )

        #expect(count == 1, "sweep of one target cluster must produce exactly 1 factoid")

        // The target cluster must now be 'distilled'.
        let targetRows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(targetClusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let targetStatus = targetRows.first.flatMap { row -> String? in
            guard case .text(let s) = row["status"] else { return nil }
            return s
        }
        #expect(targetStatus == "distilled", "targeted cluster must be marked 'distilled'")

        // The sibling cluster must still be 'open' (untouched).
        let siblingRows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(siblingClusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let siblingStatus = siblingRows.first.flatMap { row -> String? in
            guard case .text(let s) = row["status"] else { return nil }
            return s
        }
        #expect(siblingStatus == "open", "sibling cluster must remain 'open' when not targeted")
    }

    // MARK: - S8: includeHeld:true processes held clusters

    @Test("runDistillationSweep with includeHeld:true processes a held cluster")
    func sweepIncludesHeldClusters() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        // Seed a held cluster (SNR-gated in a prior sweep).
        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let heldClusterID = try await seedCluster(
            status: "held",
            memberIDs: memberIDs,
            storage: storage
        )

        // Sweep with includeHeld:true using the success stub.
        // The held cluster must get another attempt and succeed.
        let count = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: successFn,
            now: t0,
            includeHeld: true
        )

        #expect(count == 1, "held cluster given a second chance must produce 1 factoid on success")

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(heldClusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let status = rows.first.flatMap { row -> String? in
            guard case .text(let s) = row["status"] else { return nil }
            return s
        }
        #expect(
            status == "distilled",
            "held cluster must be promoted to 'distilled' after a successful retry"
        )
    }

    // MARK: - S9: includeHeld:false leaves held clusters alone

    @Test("runDistillationSweep with includeHeld:false leaves held clusters untouched")
    func sweepExcludesHeldClusters() async throws {
        let (kit, handle, storage, _) = try await openEstate()

        // Seed a held cluster.
        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let heldClusterID = try await seedCluster(
            status: "held",
            memberIDs: memberIDs,
            storage: storage
        )

        // Default sweep (includeHeld = false): must NOT process the held cluster.
        let count = try await kit.runDistillationSweep(
            handle: handle,
            distillFn: successFn,
            now: t0,
            includeHeld: false
        )

        #expect(count == 0, "sweep without includeHeld must skip held clusters → 0 factoids")

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "id"), .text(heldClusterID)),
            orderBy: [], limit: 1, offset: nil
        )
        let status = rows.first.flatMap { row -> String? in
            guard case .text(let s) = row["status"] else { return nil }
            return s
        }
        #expect(
            status == "held",
            "held cluster must remain 'held' when includeHeld is false"
        )
    }
}
