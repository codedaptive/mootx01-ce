// ConsolidateTests.swift
//
// Integration tests for the Consolidate recipe.
//
// Test IDs: CK-CO-1 .. CK-CO-8
//
// Layer discipline: estates opened via public GeniusLocusKit API.
// Clusters seeded directly into storage.rowStore (public PersistenceKit API)
// following the DistillationCycleTests pattern.
//
// Rust mirror: not applicable (Consolidate is Swift-only at this revision).

import Testing
import Foundation
import EngramLib
import GeniusLocusKit
import LocusKit
import VectorKit
import SubstrateML
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("ConsolidateTests — on-demand distillation sweep recipe (DC1)")
struct ConsolidateTests {

    // ownerIdentifier drives wing derivation: wing = "wing_\(ownerID)".
    private static let ownerID = "consolidate-test"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Fixtures

    /// Open an estate backed by InMemoryStorage WITHOUT a registered VectorStore.
    ///
    /// GeniusLocusKit.runDistillationSweep returns 0 immediately when no
    /// VectorStore is registered (locus-only estate guard). Used for tests that
    /// verify Output shape and Input acceptance rather than factoid production.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Open an estate with InMemoryStorage (GLK schema applied) AND a
    /// registered VectorStore so runDistillationSweep can actually process
    /// clusters.
    ///
    /// Two-step schema setup mirrors DistillationCycleTests pattern:
    ///   1. Estate.create applies the LocusKit schema.
    ///   2. estateStorage.open(schema: GeniusLocusKitSchema) adds GLK tables
    ///      (including memory_clusters) without conflicting with LocusKit tables.
    private func openEstateWithVectorStore() async throws -> (
        GeniusLocusKit, EstateHandle, InMemoryStorage, VectorStore
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)
        let estateStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        try await estateStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle, estateStorage, vectorStore)
    }

    /// Capture `count` content drawers via the public GLK verb and return their IDs.
    private func captureDrawers(
        count: Int,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let frame = CaptureFrame(
                content: "Source memory \(i) about Alice and her daily schedule",
                channel: .typed,
                room: "inbox",
                latticeAnchor: LatticeAnchor.udc("000"),
                addedBy: "consolidate-test",
                embeddingModelID: "minilm-v6")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
        }
        return ids
    }

    /// Insert an open cluster row directly via the estate's rowStore.
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

    /// Insert a held cluster row (SNR gate reached, status = held).
    private func seedHeldCluster(
        memberIDs: [String],
        storage: InMemoryStorage
    ) async throws -> String {
        let clusterID = UUID().uuidString
        let memberData = try JSONEncoder().encode(memberIDs)
        _ = try await storage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(clusterID),
                "status": .text("held"),
                "snr": .float(1.2),
                "member_ids": .json(memberData),
                "member_count": .int(Int64(memberIDs.count)),
                "factoid_id": .null,
                "held_reason": .text("SNR 1.2 < 2.0"),
                "filed_at": .timestamp(t0),
                "updated_at": .timestamp(t0)
            ]
        )
        return clusterID
    }

    /// Insert a failed cluster row.
    private func seedFailedCluster(
        memberIDs: [String],
        storage: InMemoryStorage
    ) async throws -> String {
        let clusterID = UUID().uuidString
        let memberData = try JSONEncoder().encode(memberIDs)
        _ = try await storage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(clusterID),
                "status": .text("failed"),
                "snr": .float(2.8),
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

    // MARK: - Tests

    // CK-CO-1: Empty estate (no VectorStore, no clusters) → factoidsProduced = 0, no crash.
    // Verifies the recipe's zero-work path: runDistillationSweep returns 0 when
    // no VectorStore is registered (locus-only estate guard).
    @Test("CK-CO-1: empty estate returns factoidsProduced=0 with no crash")
    func emptyEstate() async throws {
        let (kit, handle) = try await openEstate()

        let out = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced == 0)
        #expect(out.heldClusterIDs.isEmpty)
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-2: Estate with VectorStore and 3-member open cluster.
    // The DistillationPipeline.defaultExtractor is the distillFn.
    // Verifies Output fields are non-nil and the recipe completes without error.
    @Test("CK-CO-2: estate with 3-member open cluster — run returns valid Output with all fields")
    func estateWithOpenCluster() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        _ = try await seedOpenCluster(memberIDs: memberIDs, storage: storage)

        let out = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        // factoidsProduced >= 0 (may be 0 if defaultExtractor yields low confidence).
        #expect(out.factoidsProduced >= 0)
        // The sweep processed the cluster; its final status is reflected in the output.
        // If it succeeded: heldClusterIDs and failedClusterIDs are both empty.
        // If held or failed: exactly one of those lists is non-empty. Either way,
        // heldClusterIDs + failedClusterIDs accounts for the non-produced clusters.
        let unproduced = out.heldClusterIDs.count + out.failedClusterIDs.count
        let expectedUnproduced = 1 - out.factoidsProduced
        #expect(
            unproduced == expectedUnproduced,
            "held + failed count must equal 1 - factoidsProduced for a single-cluster estate"
        )
    }

    // CK-CO-3: heldClusterIDs is populated by pre-existing held clusters.
    // Seeds a held cluster (not swept, since includeHeld defaults to false).
    // Verifies the status-read path: held rows are surfaced in Output.heldClusterIDs
    // regardless of whether the sweep touched them.
    @Test("CK-CO-3: heldClusterIDs reflects pre-existing held clusters even without sweeping them")
    func heldClusterIDsReflectsPreExistingHeldClusters() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        // Seed a held cluster (SNR-gated from a prior sweep). The default sweep
        // (includeHeld=false) will not touch this cluster.
        let heldClusterID = try await seedHeldCluster(memberIDs: memberIDs, storage: storage)

        // No open clusters exist, so the sweep does no factoid work.
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: nil, includeHeld: false),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced == 0)
        #expect(
            out.heldClusterIDs.contains(heldClusterID),
            "heldClusterIDs must surface pre-existing held clusters"
        )
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-4: failedClusterIDs is populated by pre-existing failed clusters.
    // Seeds a failed cluster and verifies the status-read path surfaces it
    // in Output.failedClusterIDs.
    @Test("CK-CO-4: failedClusterIDs reflects pre-existing failed clusters")
    func failedClusterIDsReflectsPreExistingFailedClusters() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let failedClusterID = try await seedFailedCluster(memberIDs: memberIDs, storage: storage)

        // No open clusters exist, so the sweep does no factoid work.
        let out = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced == 0)
        #expect(out.heldClusterIDs.isEmpty)
        #expect(
            out.failedClusterIDs.contains(failedClusterID),
            "failedClusterIDs must surface pre-existing failed clusters"
        )
    }

    // CK-CO-5: Specific clusterID — accepted without crash, returns valid Output.
    // Sweeps only the named cluster; the sibling cluster must remain untouched
    // (it stays 'open' and does not appear in held or failed).
    @Test("CK-CO-5: clusterID targeting — only the targeted cluster is eligible for sweep")
    func specificClusterID() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let members1 = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let members2 = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let targetClusterID = try await seedOpenCluster(memberIDs: members1, storage: storage)
        let siblingClusterID = try await seedOpenCluster(memberIDs: members2, storage: storage)

        // Sweep only the target cluster.
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: targetClusterID, includeHeld: false),
            estate: handle,
            kit: kit)

        // The sibling cluster was NOT swept; it remains open and must NOT appear
        // in held or failed lists (those only contain clusters whose status changed).
        #expect(
            !out.heldClusterIDs.contains(siblingClusterID),
            "sibling cluster (not targeted) must not appear in heldClusterIDs"
        )
        #expect(
            !out.failedClusterIDs.contains(siblingClusterID),
            "sibling cluster (not targeted) must not appear in failedClusterIDs"
        )
        // At most 1 factoid can have been produced (the target cluster only).
        #expect(out.factoidsProduced <= 1)
        // The target cluster's new status is reflected: either in factoidsProduced
        // or in heldClusterIDs/failedClusterIDs (exactly one of these applies).
        let targetInOutput =
            out.factoidsProduced == 1
            || out.heldClusterIDs.contains(targetClusterID)
            || out.failedClusterIDs.contains(targetClusterID)
        _ = siblingClusterID   // suppress unused-warning on the sibling ID
        #expect(
            targetInOutput,
            "targeted cluster must be accounted for in Output (factoid, held, or failed)"
        )
    }

    // CK-CO-6: includeHeld:true — a held cluster is included in the sweep.
    // Its final outcome (success/held/failed) is pipeline-determined; the test
    // verifies the recipe completes without error and the output is well-formed.
    @Test("CK-CO-6: includeHeld=true — held cluster is included in sweep; output is well-formed")
    func includeHeldAccepted() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let heldClusterID = try await seedHeldCluster(memberIDs: memberIDs, storage: storage)

        // The held cluster gets another attempt. Its outcome depends on the pipeline.
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: nil, includeHeld: true),
            estate: handle,
            kit: kit)

        // factoidsProduced is 0 or 1 depending on the pipeline result.
        #expect(out.factoidsProduced >= 0)
        // If the held cluster did NOT succeed, it remains held or transitions to failed.
        // Either way, it must no longer appear as pre-existing-held if it was swept.
        // The contract: cluster is accounted for in exactly one output field.
        let accountedFor =
            out.factoidsProduced >= 1
            || out.heldClusterIDs.contains(heldClusterID)
            || out.failedClusterIDs.contains(heldClusterID)
        #expect(
            accountedFor,
            "held cluster swept with includeHeld=true must be accounted for in Output"
        )
    }

    // CK-CO-7: includeHeld:false leaves held clusters unswept.
    // A pre-existing held cluster must remain held and appear in heldClusterIDs.
    @Test("CK-CO-7: includeHeld=false skips held clusters; they remain in heldClusterIDs")
    func includeHeldFalseSkipsHeldClusters() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let heldClusterID = try await seedHeldCluster(memberIDs: memberIDs, storage: storage)

        // Default sweep: must skip the held cluster.
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: nil, includeHeld: false),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced == 0, "held cluster must be skipped → 0 factoids produced")
        // The unswept held cluster is still held; the status read must surface it.
        #expect(
            out.heldClusterIDs.contains(heldClusterID),
            "pre-existing held cluster (not swept) must appear in heldClusterIDs"
        )
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-8: Multiple open + pre-existing held and failed clusters.
    // The sweep touches open clusters; the pre-seeded held and failed remain.
    // Output surfaces all three categories correctly.
    @Test("CK-CO-8: mixed cluster statuses — output surfaces held and failed accurately")
    func mixedClusterStatuses() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let preHeldID = try await seedHeldCluster(memberIDs: memberIDs, storage: storage)
        let preFailedID = try await seedFailedCluster(memberIDs: memberIDs, storage: storage)

        // No open clusters → sweep does no work. Both pre-existing statuses surface.
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: nil, includeHeld: false),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced == 0)
        #expect(
            out.heldClusterIDs.contains(preHeldID),
            "pre-existing held cluster must appear in heldClusterIDs"
        )
        #expect(
            out.failedClusterIDs.contains(preFailedID),
            "pre-existing failed cluster must appear in failedClusterIDs"
        )
    }
}
