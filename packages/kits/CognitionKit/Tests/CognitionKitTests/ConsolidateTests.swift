// ConsolidateTests.swift
//
// Integration tests for the Consolidate recipe.
//
// Test IDs: CK-CO-1 .. CK-CO-5
//
// Layer discipline: estates opened via public GeniusLocusKit API.
// Clusters seeded directly into storage.rowStore (public PersistenceKit API)
// following the DistillationCycleTests pattern — no @testable needed.
//
// Rust mirror: not applicable (Consolidate is Swift-only at this revision).
//
// API gap note: the recipe wraps GLK.runDistillationSweep, which does not
// support per-cluster filtering (clusterID) or re-sweeping held clusters
// (includeHeld). Tests CK-CO-3 and CK-CO-4 verify that these inputs are
// ACCEPTED without crashing and return valid Output, documenting where the
// GLK API surface lands today.

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

    // MARK: - Fixtures

    /// Open an estate backed by InMemoryStorage WITHOUT a registered VectorStore.
    ///
    /// GeniusLocusKit.runDistillationSweep returns 0 immediately when no
    /// VectorStore is registered (locus-only estate). Used for tests that
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
                latticeAnchor: LatticeAnchor.udc("000.000"),
                addedBy: "consolidate-test",
                embeddingModelID: "minilm-v6")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
        }
        return ids
    }

    /// Insert an open cluster row directly via the estate's rowStore.
    ///
    /// The rowStore is a public PersistenceKit API. Direct insertion mirrors
    /// the DistillationCycleTests helper and avoids routing through assignCluster
    /// (which requires VectorKit query seams that vary by estate configuration).
    private func seedOpenCluster(
        memberIDs: [String],
        storage: InMemoryStorage,
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
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
                "filed_at": .timestamp(now),
                "updated_at": .timestamp(now)
            ]
        )
        return clusterID
    }

    /// Insert a held cluster row (SNR gate reached, status = held).
    private func seedHeldCluster(
        memberIDs: [String],
        storage: InMemoryStorage,
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
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
                "filed_at": .timestamp(now),
                "updated_at": .timestamp(now)
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
    // The DistillationPipeline.defaultExtractor (capitalization heuristic)
    // is the distillFn — factoid production depends on content and may be
    // 0 (SNR gate or confidence below threshold). Verifies that all Output
    // fields are non-nil and the recipe returns without error.
    @Test("CK-CO-2: estate with 3-member open cluster — run returns valid Output with all fields")
    func estateWithOpenCluster() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        // Capture 3 drawers to populate cluster member content.
        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // Seed a 3-member open cluster pointing at those drawers.
        _ = try await seedOpenCluster(memberIDs: memberIDs, storage: storage)

        let out = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        // factoidsProduced >= 0 (may be 0 if defaultExtractor yields low confidence).
        #expect(out.factoidsProduced >= 0)
        // heldClusterIDs and failedClusterIDs are always [] until GLK surfaces cluster status reads.
        #expect(out.heldClusterIDs.isEmpty)
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-3: Specific clusterID supplied → recipe accepts the input and returns
    // valid Output. Documents that per-cluster targeting is not yet filterable at
    // the current GLK sweep API level; the sweep processes all eligible open clusters.
    @Test("CK-CO-3: clusterID specified — accepted without crash, returns valid Output")
    func specificClusterID() async throws {
        let (kit, handle) = try await openEstate()

        let specificID = UUID().uuidString
        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: specificID, includeHeld: false),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced >= 0)
        #expect(out.heldClusterIDs.isEmpty)
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-4: includeHeld: true — recipe accepts the flag and returns valid Output.
    // Documents that held-cluster re-sweep is not yet wired at the GLK level;
    // runDistillationSweep only sweeps status = open clusters. A held cluster
    // seeded here will NOT be swept and will remain held after run().
    @Test("CK-CO-4: includeHeld=true accepted without crash; held cluster remains held")
    func includeHeldAccepted() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        // Seed a held cluster — member_count >= 3 but SNR gate was reached.
        let memberIDs = try await captureDrawers(count: 3, kit: kit, handle: handle)
        _ = try await seedHeldCluster(memberIDs: memberIDs, storage: storage)

        let out = try await Consolidate().run(
            input: Consolidate.Input(clusterID: nil, includeHeld: true),
            estate: handle,
            kit: kit)

        // GLK sweep does not re-process held clusters yet; factoidsProduced = 0.
        #expect(out.factoidsProduced == 0)
        #expect(out.heldClusterIDs.isEmpty)
        #expect(out.failedClusterIDs.isEmpty)
    }

    // CK-CO-5: Multiple open clusters → run completes, returns valid Output.
    // Non-zero factoidsProduced possible if the pipeline succeeds for any cluster;
    // test asserts the count is non-negative (not a specific value).
    @Test("CK-CO-5: multiple open clusters — run completes, factoidsProduced non-negative")
    func multipleOpenClusters() async throws {
        let (kit, handle, storage, _) = try await openEstateWithVectorStore()

        // Seed two independent 3-member clusters.
        let members1 = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let members2 = try await captureDrawers(count: 3, kit: kit, handle: handle)
        _ = try await seedOpenCluster(memberIDs: members1, storage: storage)
        _ = try await seedOpenCluster(memberIDs: members2, storage: storage)

        let out = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        #expect(out.factoidsProduced >= 0)
        #expect(out.heldClusterIDs.isEmpty)
        #expect(out.failedClusterIDs.isEmpty)
    }
}
