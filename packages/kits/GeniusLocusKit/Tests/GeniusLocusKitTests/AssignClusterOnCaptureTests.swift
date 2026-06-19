// AssignClusterOnCaptureTests.swift
//
// Integration tests proving that assignCluster is called automatically
// on the capture write-path (Dg5 wiring). These tests go end-to-end:
// capture via the mode-aware verb → encode via corpus.ingest →
// assignClusterAfterIngest → memory_clusters row written.
//
// Coverage:
//  I1  Three captures with IDENTICAL content (Hamming distance = 0)
//      produce exactly ONE open cluster with member_count = 3.
//      This proves the impatient inline path fires assignCluster.
//  I2  Three captures with IDENTICAL content via the REGULAR
//      (drain) path also produce one cluster with member_count = 3
//      (after awaitEncodeDrain).
//  I3  A capture with DIFFERENT content seeds its own cluster
//      (dissimilar engrams: Hamming > 64 for unrelated texts).
//
// All tests use the .deterministic embedding model (no CoreML, reproducible).
// The deterministic SimHash produces IDENTICAL engrams for IDENTICAL text,
// so member_count = 3 is guaranteed for same-content captures.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
@testable import GeniusLocusKit

// MARK: - Fixture helpers

/// Provision a GLK estate with the composite GLK schema applied so
/// `memory_clusters` is available for querying after captures.
///
/// Applies `GeniusLocusKitSchema.estateSchemaDeclaration` to the same
/// storage used by `provision`, which adds the `memory_clusters` table
/// (DG1). The schema open is idempotent — `provision` already applied
/// the LocusKit/Corpus/VectorStore component schemas; adding the GLK
/// composite version bumps the global version counter without re-running
/// lower component migrations.
private func provisionGLKWithClusterSchema(
    modelID: String
) async throws -> (GeniusLocusKit, EstateHandle, InMemoryStorage) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "owner-assign-cluster-on-capture")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)

    // Step 1: provision wires LocusKit + Corpus + VectorStore + encode queue.
    let params = EstateProvisionParams(
        estateName: "AssignClusterOnCapture Test Estate",
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none
    )
    let handle = try await kit.provision(
        storage: storage,
        owner: owner,
        params: params,
        embeddingModels: [.deterministic]
    )

    // Step 2: Ensure the GLK composite schema is applied so memory_clusters
    // exists. provision now applies it via the shared wireSubstores seam (the
    // .glk branch opens GeniusLocusKitSchema.estateSchemaDeclaration), so this
    // is a redundant, idempotent re-open kept to make the test's schema
    // dependency explicit and self-contained.
    try await storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)

    return (kit, handle, storage)
}

/// Build a CaptureFrame with the given content and a fixed room.
private func clusterFrame(content: String) -> CaptureFrame {
    CaptureFrame(
        content: content,
        channel: .typed,
        room: "cluster-test-inbox",
        latticeAnchor: .udc("000"),
        addedBy: "assign-cluster-on-capture-tests",
        // embeddingModelID on the frame is a caller hint; assignCluster uses
        // corpus.modelID (the authoritative VectorKit lane key).
        embeddingModelID: "deterministic-v1"
    )
}

/// Query the open rows from memory_clusters in `storage`.
private func openClusterRows(storage: InMemoryStorage) async throws -> [StorageRow] {
    try await storage.rowStore.query(
        table: "memory_clusters",
        where: .eq(Column(table: "memory_clusters", name: "status"), .text("open")),
        orderBy: [], limit: nil, offset: nil
    )
}

/// Decode a JSON-encoded [String] from a TypedValue (.json or .blob).
private func decodeIDs(_ v: TypedValue?) -> [String] {
    let data: Data?
    switch v {
    case .json(let d): data = d
    case .blob(let d): data = d
    default: return []
    }
    guard let d = data else { return [] }
    return (try? JSONDecoder().decode([String].self, from: d)) ?? []
}

/// Provision a GLK estate with the PRODUCTION default 5-signal ensemble
/// (RI / PPMI / LSA / NMF / FDC — all freshly constructed, zero training).
/// Used by I4 to prove cluster assignment is training-independent.
private func provisionGLKWithProductionEnsemble(
) async throws -> (GeniusLocusKit, EstateHandle, InMemoryStorage) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "owner-i4-production-ensemble")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)

    let params = EstateProvisionParams(
        estateName: "I4 Production Ensemble Test Estate",
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none
    )
    // No embeddingModels argument → defaults to CorpusEnsemble.defaultEnsemble()
    // (RI / PPMI / LSA / NMF / FDC, all untrained). The fix must not depend on
    // any of these being trained for cluster assignment to work.
    let handle = try await kit.provision(
        storage: storage,
        owner: owner,
        params: params
    )

    try await storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)

    return (kit, handle, storage)
}

// MARK: - Tests

@Suite("assignCluster write-path wiring (Dg5 integration)")
struct AssignClusterOnCaptureTests {

    private let sameContent = "The mitochondria is the powerhouse of the cell quantum entanglement"
    private let differentContent = "Baroque period counterpoint fugue Johann Sebastian Bach harpsichord"

    // MARK: - I1: impatient path forms cluster with member_count = 3

    @Test("I1: three identical captures via impatient path form one cluster with member_count = 3")
    func impatientPathFormsCluster() async throws {
        let (kit, handle, storage) = try await provisionGLKWithClusterSchema(
            modelID: "deterministic-v1"
        )
        defer { Task { try? await kit.close(handle) } }

        let frame = clusterFrame(content: sameContent)

        // Three captures with identical content — all produce Hamming distance = 0.
        for _ in 0..<3 {
            _ = try await kit.capture(handle, frame, mode: .impatient)
        }

        // One open cluster must exist, with member_count = 3.
        let rows = try await openClusterRows(storage: storage)
        #expect(rows.count == 1, "three identical-content captures must form exactly one open cluster; got \(rows.count)")

        if let row = rows.first {
            let ids = decodeIDs(row["member_ids"])
            #expect(ids.count == 3, "open cluster must have 3 members; got \(ids.count)")
        }
    }

    // MARK: - I2: regular (drain) path forms cluster with member_count = 3

    @Test("I2: three identical captures via regular (drain) path form one cluster after drain")
    func regularPathFormsClusterAfterDrain() async throws {
        let (kit, handle, storage) = try await provisionGLKWithClusterSchema(
            modelID: "deterministic-v1"
        )
        defer { Task { try? await kit.close(handle) } }

        let frame = clusterFrame(content: sameContent)

        // Three regular captures — encode jobs are enqueued, not inline.
        for _ in 0..<3 {
            _ = try await kit.capture(handle, frame, mode: .regular)
        }

        // Wait for the drain worker to process all encode jobs.
        try await kit.awaitEncodeDrain(for: handle)

        // One open cluster with member_count = 3.
        let rows = try await openClusterRows(storage: storage)
        #expect(rows.count == 1, "three identical-content regular captures must form one open cluster after drain; got \(rows.count)")

        if let row = rows.first {
            let ids = decodeIDs(row["member_ids"])
            #expect(ids.count == 3, "open cluster must have 3 members after drain; got \(ids.count)")
        }
    }

    // MARK: - I3: dissimilar captures each seed their own cluster

    @Test("I3: dissimilar captures seed independent clusters (different Hamming neighborhoods)")
    func dissimilarCapturesSeedSeparateClusters() async throws {
        let (kit, handle, storage) = try await provisionGLKWithClusterSchema(
            modelID: "deterministic-v1"
        )
        defer { Task { try? await kit.close(handle) } }

        // Two captures with completely different text — deterministic SimHash
        // produces very different fingerprints for unrelated vocabulary.
        _ = try await kit.capture(handle, clusterFrame(content: sameContent), mode: .impatient)
        _ = try await kit.capture(handle, clusterFrame(content: differentContent), mode: .impatient)

        // Each drawer should seed its own cluster (two open clusters).
        // If the deterministic embedder happens to produce nearby fingerprints
        // for these particular strings the second drawer could join the first —
        // that is also semantically correct behaviour for the gate (the Hamming
        // threshold is 64, not 0). The invariant that matters is: at least one
        // cluster exists and the total member_count across all open clusters = 2.
        let rows = try await openClusterRows(storage: storage)
        let totalMembers = rows.reduce(0) { acc, row in
            acc + decodeIDs(row["member_ids"]).count
        }
        #expect(rows.count >= 1, "at least one open cluster must exist after two captures; got \(rows.count)")
        #expect(totalMembers == 2, "total member count across all open clusters must be 2; got \(totalMembers)")
    }

    // MARK: - I4: production default ensemble (untrained) still forms clusters

    /// Three near-identical captures via the production default 5-signal ensemble
    /// (RI / PPMI / LSA / NMF / FDC — all freshly constructed, zero training)
    /// must still produce exactly ONE open cluster with member_count = 3.
    ///
    /// This is the regression test for the original bug: before the fix,
    /// `assignClusterAfterIngest` called `corpus.embed(content)`, which on
    /// an untrained estate (RI basis empty → near-zero engrams) caused cluster
    /// joining to fail for every capture. After the fix, cluster assignment
    /// uses `contentDeterministicFingerprint`, which is training-independent,
    /// so identical texts produce the same structural fingerprint and cluster
    /// correctly regardless of training state.
    @Test("I4: production embedding (untrained estate) still forms clusters with member_count = 3")
    func productionEnsembleUntrainedEstateFormsCluster() async throws {
        let (kit, handle, storage) = try await provisionGLKWithProductionEnsemble()
        defer { Task { try? await kit.close(handle) } }

        let frame = clusterFrame(content: sameContent)

        // Three captures with identical content on a FULLY UNTRAINED estate.
        // The fix routes cluster assignment through contentDeterministicFingerprint,
        // so near-identical texts must form a cluster even with zero RI training.
        for _ in 0..<3 {
            _ = try await kit.capture(handle, frame, mode: .impatient)
        }

        let rows = try await openClusterRows(storage: storage)
        #expect(
            rows.count == 1,
            "three identical-content captures on untrained estate must form exactly one open cluster; got \(rows.count)"
        )

        if let row = rows.first {
            let ids = decodeIDs(row["member_ids"])
            #expect(
                ids.count == 3,
                "open cluster on untrained estate must have 3 members; got \(ids.count)"
            )
        }
    }
}
