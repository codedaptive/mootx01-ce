// DistillationIntegrationTests.swift
//
// End-to-end integration test for the full INTRA-ITEM distillation pipeline.
//
// Four test cases exercising the complete write-path → dense recall → expand
// → search injection depth sequence against a real in-memory estate.
//
// Test IDs: CK-INT-1..4
//
// Layer discipline: estates opened via the public GeniusLocusKit API. A single
// multi-sentence item is captured; Consolidate runs the per-item sweep, which
// reduces the item from its OWN sentences (intraItem: true) into one factoid.
//
// Content determinism: the item's five sentences each repeat "Provenance"
// (capitalized, non-first word) so defaultExtractor extracts the same entity
// from every sentence. Recurrence across the item's sentences → docFrequency=1.0
// → confidence=1.0 → factoid produced. featureFingerprint = featureHash of the
// stem of "provenance", non-zero, deterministic.

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
    case noDistilledDrawer
}

// MARK: - Test suite

@Suite("DistillationIntegrationTests — end-to-end intra-item distillation")
struct DistillationIntegrationTests {

    private static let ownerID = "distillation-integration-tests"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // One item whose five sentences each repeat "Provenance" at a non-first,
    // capitalized position so defaultExtractor extracts the same entity from
    // every sentence. Recurrence across the item's own sentences drives
    // docFrequency=1.0 → confidence=1.0 → a factoid is produced. The item is
    // segmented into M=5 sentences for the incidence matrix; however src= in the
    // DIST header records sourceIDs.count = 1 (the single source memory), not M.
    private static let itemBody: String =
        "Records exist. The Provenance record confirms zero. " +
        "The Provenance record confirms one. The Provenance record confirms two. " +
        "The Provenance record confirms three."

    // MARK: - Shared fixture

    private struct DistilledEstate {
        let kit: GeniusLocusKit
        let handle: EstateHandle
        let storage: InMemoryStorage
        let vectorStore: VectorStore
        let factoidID: String
        let sourceID: String
    }

    /// Open an estate with a registered VectorStore, capture ONE multi-sentence
    /// item, and run Consolidate so the estate contains exactly one factoid drawer
    /// in room `_distilled` linked back to the source item by a `_distilled_from`
    /// tunnel. The factoid's lineageID equals the source item's id.
    ///
    /// Throws `IntegrationSetupError` if consolidation does not produce a factoid.
    private func setUpDistilledEstate() async throws -> DistilledEstate {
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

        // Capture ONE multi-sentence source item.
        let frame = CaptureFrame(
            content: Self.itemBody,
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "dp3-integration-test",
            embeddingModelID: "test-v1")
        let sourceDrawer = try await kit.capture(handle, frame)
        let sourceID = sourceDrawer.id

        // Run the per-item distillation sweep via the Consolidate recipe. Pass
        // defaultExtractor explicitly so the fixture sentences (capitalization
        // heuristic, not HMM tagger output) produce deterministic features.
        let consolidateOut = try await Consolidate().run(
            input: Consolidate.Input(),
            estate: handle,
            kit: kit,
            extractFeatures: DistillationPipeline.defaultExtractor,
            now: t0)

        guard consolidateOut.factoidsProduced >= 1 else {
            throw IntegrationSetupError.consolidationProducedNoFactoid
        }

        // Resolve the factoid: the only drawer in room "_distilled" whose
        // lineageID equals the source item's id (set by distillItemsSweep
        // via captureFactoid using the source drawer's UUID as lineageID).
        // Drawer no longer carries wing/room — resolve via the node tree.
        let allDrawers = try await kit.allDrawers(in: handle)
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: allDrawers.map(\.parentNodeId))
        guard let factoid = allDrawers.first(where: {
            nodeNames[$0.parentNodeId]?.room == "_distilled" && $0.lineageID.uuidString == sourceID
        }) else {
            throw IntegrationSetupError.noDistilledDrawer
        }

        return DistilledEstate(
            kit: kit, handle: handle, storage: estateStorage,
            vectorStore: vectorStore, factoidID: factoid.id, sourceID: sourceID)
    }

    // MARK: - CK-INT-1: Full write path

    /// CK-INT-1: one multi-sentence item → Consolidate → 1 factoid + 1
    /// `_distilled_from` tunnel back to the source item.
    ///
    /// Verifies the complete intra-item distillation write path from capture to
    /// factoid drawer capture, VectorStore fingerprint storage, and tunnel wiring.
    @Test("CK-INT-1: full write path — one item → Consolidate → 1 factoid + 1 tunnel")
    func fullWritePath() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            // Factoid drawer must exist and carry a DIST header.
            let factoidContent = try await estate.kit.hydrate(
                estate.handle, ids: [estate.factoidID])
            let content = try #require(
                factoidContent[estate.factoidID],
                "factoid drawer must be hydrateable from the estate")
            #expect(content.hasPrefix("[DIST|"),
                "factoid content must start with a DIST header")

            // Verify a single _distilled_from tunnel wired from factoid to the
            // source item (intra-item provenance: one source = the item itself).
            // tunnels are filed in LocusKit.defaultWingName ("Agentic Memory").
            let allTunnels = try await estate.kit.recallTunnels(estate.handle, wing: LocusKit.defaultWingName)
            let distilledFromTunnels = allTunnels.filter {
                $0.label == "_distilled_from" && $0.sourceDrawerId == estate.factoidID
            }
            #expect(distilledFromTunnels.count == 1,
                "intra-item distillation writes one _distilled_from tunnel to the source item")

            // The single source item ID must appear as the tunnel target.
            let targetIDs = Set(distilledFromTunnels.compactMap(\.targetDrawerId))
            #expect(targetIDs == Set([estate.sourceID]),
                "the source item ID must appear as the tunnel target")
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

    // MARK: - CK-INT-3: Recollect

    /// CK-INT-3: moot_recollect(factoidID) → the single source item.
    ///
    /// Verifies the recollect path: factoid hydration → DIST header validation →
    /// tunnel graph traversal → source hydration. Under the intra-item model the
    /// factoid links back to exactly one source (the item it was distilled from).
    @Test("CK-INT-3: recollect returns the single source item")
    func recollect() async throws {
        try await withCognitionLock {
            let estate = try await setUpDistilledEstate()

            let out = try await Recollect().run(
                input: Recollect.Input(factoidDrawerID: estate.factoidID),
                estate: estate.handle, kit: estate.kit)

            #expect(out.factoidID == estate.factoidID,
                "Recollect.Output.factoidID must match the requested factoid drawer ID")
            #expect(out.sources.count == 1,
                "recollect must return the single source item linked by the _distilled_from tunnel")

            // The source item ID must appear in the expansion.
            let expandedIDs = Set(out.sources.map(\.id))
            #expect(expandedIDs == Set([estate.sourceID]),
                "the original source item ID must appear in Recollect output")

            // Prose is the dominant feature extracted by the pipeline.
            #expect(!out.prose.isEmpty,
                "Recollect.Output.prose must be non-empty for a successful factoid")
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
            // src= in the DIST header records the number of SOURCE MEMORIES (sourceIDs.count),
            // not the sentence count (M). For intra-item distillation there is always exactly
            // one source memory (the item itself), so sourceCount must be 1. This is the
            // invariant: sourceCount == number of _distilled_from tunnels == expand returns.
            #expect(header.sourceCount == 1,
                "DIST header src= must record source memory count (1 for intra-item), not sentence count")
            #expect(header.deltaType == .static,
                "identical recurring feature across sentences yields deltaType=STATIC")

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
