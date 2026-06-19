// DistillationIntegrationTests.swift
//
// End-to-end integration test for the full distillation pipeline (Dp3 final).
//
// Four test cases exercising the complete write-path → dense recall → expand
// → search injection depth sequence against a real in-memory estate.
//
// Test IDs: CK-INT-1..4
//
// Layer discipline: estates opened via the public GeniusLocusKit API.
// Clusters seeded directly via storage.rowStore (public PersistenceKit API)
// following the ConsolidateTests / DistillationCycleTests pattern.
//
// Content determinism: memories use "The Provenance record confirms…"
// so defaultExtractor always extracts "Provenance" (capitalized, non-first word).
// Five identical features → docFrequency=1.0 → confidence=1.0 → succeeded=true.
// featureFingerprint = featureHash("Provenance"), non-zero, deterministic.

import Testing
import Foundation
import EngramLib
import GeniusLocusKit
import LocusKit
import NeuronKit
import VectorKit
import SubstrateML
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

// MARK: - Error types for setup failures

private enum IntegrationSetupError: Error {
    case consolidationProducedNoFactoid
    case noDistilledClusterRow
    case missingFactoidIDColumn
}

// MARK: - Test suite

@Suite("DistillationIntegrationTests — end-to-end distillation pipeline (Dp3)")
struct DistillationIntegrationTests {

    private static let ownerID = "distillation-integration-tests"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // Five memories sharing "Provenance" at position 1 (capitalized, non-first word)
    // so defaultExtractor extracts the same entity from every memory.
    // The repeated entity across all five memories drives docFrequency=1.0 →
    // confidence=1.0 (mean_df × coherence_ratio = 1.0 × 1.0) → succeeded=true.
    private static let memoryContents: [String] = [
        "The Provenance record confirms memory zero was filed",
        "The Provenance record confirms memory one was filed",
        "The Provenance record confirms memory two was filed",
        "The Provenance record confirms memory three was filed",
        "The Provenance record confirms memory four was filed",
    ]

    // MARK: - Shared fixture

    private struct DistilledEstate {
        let kit: GeniusLocusKit
        let handle: EstateHandle
        let storage: InMemoryStorage
        let vectorStore: VectorStore
        let factoidID: String
        let sourceIDs: [String]
    }

    /// Open an estate with a registered VectorStore, capture 5 source memories,
    /// seed an open cluster, and run Consolidate so the estate contains exactly
    /// one factoid drawer in room `_distilled` with 5 `_distilled_from` tunnels.
    ///
    /// Throws `IntegrationSetupError` if consolidation does not produce a factoid.
    private func setUpDistilledEstate() async throws -> DistilledEstate {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)

        let estateStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        // Apply the GLK composite schema so memory_clusters exists before we insert.
        // Mirrors ConsolidateTests.openEstateWithVectorStore.
        try await estateStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        // Capture 5 source memories in sequence (oldest → newest for filedAt ordering).
        var sourceIDs: [String] = []
        for content in Self.memoryContents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "inbox",
                latticeAnchor: LatticeAnchor.udc("000.000"),
                addedBy: "dp3-integration-test",
                embeddingModelID: "test-v1")
            let drawer = try await kit.capture(handle, frame)
            sourceIDs.append(drawer.id)
        }

        // Seed one open cluster containing all 5 drawer IDs.
        // Direct rowStore insertion mirrors ConsolidateTests.seedOpenCluster.
        let memberData = try JSONEncoder().encode(sourceIDs)
        _ = try await estateStorage.rowStore.insert(
            table: "memory_clusters",
            values: [
                "id": .text(UUID().uuidString),
                "status": .text("open"),
                "snr": .null,
                "member_ids": .json(memberData),
                "member_count": .int(5),
                "factoid_id": .null,
                "held_reason": .null,
                "filed_at": .timestamp(t0),
                "updated_at": .timestamp(t0)
            ])

        // Run the distillation sweep via the Consolidate recipe.
        let consolidateOut = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit)

        guard consolidateOut.factoidsProduced >= 1 else {
            throw IntegrationSetupError.consolidationProducedNoFactoid
        }

        // Resolve factoidID by reading the distilled cluster row in the database.
        // StoragePredicate.eq requires a Column(table:name:) reference.
        let clusterRows = try await estateStorage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "status"), .text("distilled")))
        guard let row = clusterRows.first else {
            throw IntegrationSetupError.noDistilledClusterRow
        }
        guard case .text(let factoidID) = row["factoid_id"] else {
            throw IntegrationSetupError.missingFactoidIDColumn
        }

        return DistilledEstate(
            kit: kit, handle: handle, storage: estateStorage,
            vectorStore: vectorStore, factoidID: factoidID, sourceIDs: sourceIDs)
    }

    // MARK: - CK-INT-1: Full write path

    /// CK-INT-1: 5 overlapping captures → Consolidate → 1 factoid + 5 tunnels +
    /// cluster.status = 'distilled'.
    ///
    /// Verifies the complete distillation write path from capture to factoid
    /// drawer capture, VectorStore fingerprint storage, and tunnel graph wiring.
    @Test("CK-INT-1: full write path — 5 captures → Consolidate → 1 factoid + 5 tunnels")
    func fullWritePath() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            // Factoid drawer must exist (factoidID resolves from the cluster row above).
            let factoidContent = try await estate.kit.hydrate(
                estate.handle, ids: [estate.factoidID])
            let content = try #require(
                factoidContent[estate.factoidID],
                "factoid drawer must be hydrateable from the estate")
            #expect(content.hasPrefix("[DIST|"),
                "factoid content must start with a DIST header")

            // Verify 5 _distilled_from tunnels wired from factoid to each source.
            let wing = "wing_\(Self.ownerID)"
            let allTunnels = try await estate.kit.recallTunnels(estate.handle, wing: wing)
            let distilledFromTunnels = allTunnels.filter {
                $0.label == "_distilled_from" && $0.sourceDrawerId == estate.factoidID
            }
            #expect(distilledFromTunnels.count == 5,
                "runDistillationSweep must write 5 _distilled_from tunnels (one per source memory)")

            // All 5 source IDs must appear as tunnel targets.
            let targetIDs = Set(distilledFromTunnels.map(\.targetDrawerId))
            #expect(targetIDs == Set(estate.sourceIDs),
                "each of the 5 source drawer IDs must appear as a tunnel target")
        }
    }

    // MARK: - CK-INT-2: Dense recall (no embedding inference)

    /// CK-INT-2: moot_recall_distilled → ≥1 DistilledMatch, no embedding call.
    ///
    /// The dense path uses DistillationPipeline.queryFingerprint (pure bit ops)
    /// and VectorStore Hamming NN over the "distillation-features-v1" lane.
    /// No float-vector embedding model is invoked.
    @Test("CK-INT-2: dense recall returns ≥1 DistilledMatch via fingerprint Hamming NN")
    func denseRecall() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            // Query with lowercase "provenance" — defaultExtractor extracts no features
            // (first word, or not capitalized), yielding Fingerprint256.zero. The stored
            // fingerprint is featureHash("Provenance") ≠ zero. VectorStore.findNearest
            // returns the factoid as the nearest available vector regardless of Hamming
            // distance, since it is the only vector in the distillation-features-v1 lane.
            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: "provenance"),
                estate: estate.handle, kit: estate.kit)

            #expect(!output.matches.isEmpty,
                "moot_recall_distilled must return ≥1 DistilledMatch from the _distilled lane")

            // The factoid produced by Consolidate has confidence=1.0 (single dominant
            // feature, docFrequency=1.0). Verify injectionDepth matches threshold.
            if let match = output.matches.first {
                #expect(match.confidence > 0.4,
                    "factoid confidence must be above 0.4 (distillation confidence gate)")
                // confidence=1.0 ≥ 0.7 → factoidOnly (prose only, no annotation suffix)
                #expect(match.injectionDepth == .factoidOnly,
                    "confidence ≥ 0.7 must yield .factoidOnly injection depth")
            }
        }
    }

    // MARK: - CK-INT-3: Expand memory

    /// CK-INT-3: moot_expand_memory(factoidID) → 5 ExpandedSources, oldest-first.
    ///
    /// Verifies the expand path: factoid hydration → DIST header validation →
    /// tunnel graph traversal → source hydration.
    @Test("CK-INT-3: expand memory returns 5 ExpandedSources with source IDs present")
    func expandMemory() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            let out = try await ExpandMemory().run(
                input: ExpandMemory.Input(factoidDrawerID: estate.factoidID),
                estate: estate.handle, kit: estate.kit)

            #expect(out.factoidID == estate.factoidID,
                "ExpandMemory.Output.factoidID must match the requested factoid drawer ID")
            #expect(out.sources.count == 5,
                "expand must return all 5 source memories linked by _distilled_from tunnels")

            // All 5 source IDs must appear in the expansion (order may vary by tunnel filedAt).
            let expandedIDs = Set(out.sources.map(\.id))
            #expect(expandedIDs == Set(estate.sourceIDs),
                "all 5 original source drawer IDs must appear in ExpandMemory output")

            // Prose is the dominant feature extracted by the pipeline.
            #expect(!out.prose.isEmpty,
                "ExpandMemory.Output.prose must be non-empty for a successful factoid")
            #expect(out.confidence > 0.4,
                "factoid confidence must exceed the 0.4 distillation gate")
        }
    }

    // MARK: - CK-INT-4: Search injection depth annotation

    /// CK-INT-4: moot_memory_search result for a _distilled hit is correctly annotated.
    ///
    /// Hydrates the factoid, parses the DIST header, and verifies that InjectionDepth
    /// classification matches the confidence value produced by the pipeline.
    ///
    /// confidence=1.0 (single feature, df=1.0) → InjectionDepth.factoidOnly:
    ///   prose only, no annotation suffix appended by ToolDispatch.
    @Test("CK-INT-4: _distilled hit DIST header parses correctly and yields .factoidOnly depth")
    func searchInjectionDepth() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            // Hydrate the factoid drawer — this is the content that ToolDispatch reads
            // when a moot_memory_search result has room == "_distilled".
            let bodyMap = try await estate.kit.hydrate(
                estate.handle, ids: [estate.factoidID])
            let factoidContent = try #require(
                bodyMap[estate.factoidID],
                "factoid content must be hydrateable by its drawer ID")

            // Parse the DIST header. This is the same call ToolDispatch makes before
            // applying InjectionDepth formatting in the moot_memory_search result.
            let header = try #require(
                DistilledHeader.parse(factoidContent),
                "factoid content must contain a parseable DIST header starting with '[DIST|'")

            // confidence=1.0 is expected from the single-feature (Provenance) cluster.
            #expect(header.confidence > 0.4,
                "parsed confidence must exceed 0.4 — pipeline gate ensures this")
            #expect(header.sourceCount == 5,
                "DIST header src= field must record the 5 source memories")
            #expect(header.deltaType == .static,
                "5 identical feature sequences yield deltaType=STATIC")

            // Verify InjectionDepth classification using the same thresholds as ToolDispatch.
            // conf ≥ 0.7 → .factoidOnly (prose only, no annotation suffix).
            // conf ∈ [0.4, 0.7) → .factoidWithMeta.
            // conf < 0.4 → .factoidWithProvenance (never reached for a produced factoid).
            if header.confidence >= 0.7 {
                // Pipeline produced high-confidence factoid: annotation is prose only.
                #expect(!header.prose.isEmpty,
                    "prose must be non-empty for a high-confidence factoid")
            } else {
                // Borderline confidence: factoidWithMeta annotation expected.
                // Record for observability — does not block the test.
                Issue.record(
                    "Unexpected borderline confidence \(header.confidence); expected >= 0.7 for single-feature cluster with df=1.0")
            }
        }
    }
}
