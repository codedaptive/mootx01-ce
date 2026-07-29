// DistillationIntegrationTests.swift
//
// End-to-end integration tests for the full distillation flow —
// SPEC_DISTILLATION_STORAGE §7 (generation), §8 (lane re-key),
// §10 (distilled recall), §11/§13.2 (factoid retirement).
//
// Test IDs: CK-INT-1..4
//
// Layer discipline: estates opened via the public GeniusLocusKit API. A
// multi-sentence item is captured; Distill runs the per-item sweep, which
// writes the four representation columns on the SOURCE row and one
// distillation-features-v1 lane entry keyed by the SOURCE drawer id.
//
// Content determinism: the item's five sentences each repeat "Provenance"
// (capitalized, non-first word) so the p1 default extractor extracts the
// same entity from every sentence — a deterministic non-zero fingerprint.

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

@Suite("DistillationIntegrationTests — end-to-end distillation flow")
struct DistillationIntegrationTests {

    private static let ownerID = "distillation-integration-tests"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // One item whose five sentences each repeat "Provenance" at a non-first,
    // capitalized position so the default extractor extracts the same entity
    // from every sentence — recurrence across the item's own sentences gives
    // a deterministic non-zero structural fingerprint.
    private static let itemBody: String =
        "Records exist. The Provenance record confirms zero. " +
        "The Provenance record confirms one. The Provenance record confirms two. " +
        "The Provenance record confirms three."

    // MARK: - Shared fixture

    private struct DistilledEstate {
        let kit: GeniusLocusKit
        let handle: EstateHandle
        let vectorStore: VectorStore
        let sourceID: String
    }

    /// Open an estate with a registered VectorStore, capture ONE
    /// multi-sentence item, and run Distill so the item carries its on-row
    /// representation and its lane entry (keyed by the source drawer id).
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
            addedBy: "distillation-integration-test",
            embeddingModelID: "test-v1")
        let sourceDrawer = try await kit.capture(handle, frame)

        // The moot_distill sweep (p1 contract, deterministic clock).
        let out = try await Distill().run(
            input: Distill.Input(), estate: handle, kit: kit, now: t0)
        #expect(out.itemsDistilled >= 1)

        return DistilledEstate(
            kit: kit, handle: handle, vectorStore: vectorStore,
            sourceID: sourceDrawer.id)
    }

    // MARK: - CK-INT-1: §7.2 two writes

    @Test("CK-INT-1: sweep writes the on-row representation and the source-keyed lane entry")
    func sweepWritesColumnsAndLane() async throws {
        try await withCognitionLock {
            let fixture = try await setUpDistilledEstate()

            // Write 1: the four representation columns on the SOURCE row.
            let estate = try await fixture.kit.estate(for: fixture.handle)
            let row = try #require(
                try await estate.getDrawers(ids: [fixture.sourceID]).first)
            #expect(row.distilled != nil)
            #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
            #expect(row.distilledTokenCount
                == TokenCompaction.estimateTokenCount(row.distilled ?? ""))
            #expect(row.distilledAt == t0)

            // Write 2: the lane entry keyed by the SOURCE drawer id (§8).
            let probe = DistillationPipeline.queryFingerprint(
                query: Self.itemBody,
                extractFeatures: DistillationPipeline.defaultExtractor)
            let matches = try await fixture.vectorStore.findNearest(
                probe: probe,
                modelID: GeniusLocusKit.distillationLaneModelID,
                limit: 5)
            #expect(matches.contains { $0.itemID == fixture.sourceID },
                "the lane key is the SOURCE drawer id, not a factoid id")
        }
    }

    // MARK: - CK-INT-2: §10.3 distilled recall end-to-end

    @Test("CK-INT-2: distilled recall returns the SOURCE id with the distilled payload")
    func distilledRecallEndToEnd() async throws {
        try await withCognitionLock {
            let fixture = try await setUpDistilledEstate()

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "Provenance record"),
                estate: fixture.handle, kit: fixture.kit)

            let match = try #require(
                output.matches.first { $0.id == fixture.sourceID },
                "the hit is the SOURCE drawer — there is no factoid tier")
            #expect(!match.servedFromContent)
            #expect(match.tokenCount != nil)
            #expect(match.text != Self.itemBody, "payload is the dense rendering")
        }
    }

    // MARK: - CK-INT-3: §7.3/§13.6 regeneration on version mismatch

    @Test("CK-INT-3: a stale pipeline version regenerates on the next sweep and replaces the lane entry")
    func staleVersionRegenerates() async throws {
        try await withCognitionLock {
            let fixture = try await setUpDistilledEstate()
            let estate = try await fixture.kit.estate(for: fixture.handle)

            // Simulate a representation from an older contract.
            _ = try await estate.setDistilledRepresentation(
                drawerId: fixture.sourceID,
                distilled: "stale rendering from an older contract",
                pipelineVersion: "p0",
                tokenCount: 5,
                at: t0)

            let out = try await Distill().run(
                input: Distill.Input(), estate: fixture.handle, kit: fixture.kit,
                now: t0.addingTimeInterval(100))
            #expect(out.itemsDistilled >= 1, "version mismatch is a regeneration candidate (§7.3)")

            let row = try #require(
                try await estate.getDrawers(ids: [fixture.sourceID]).first)
            #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
            #expect(row.distilled != "stale rendering from an older contract")
            #expect(row.distilledAt == t0.addingTimeInterval(100))

            // The lane still carries exactly one entry for this drawer id
            // (addVector upserts — §8 replace semantics, §13.6).
            let probe = DistillationPipeline.queryFingerprint(
                query: Self.itemBody,
                extractFeatures: DistillationPipeline.defaultExtractor)
            let matches = try await fixture.vectorStore.findNearest(
                probe: probe,
                modelID: GeniusLocusKit.distillationLaneModelID,
                limit: 10)
            #expect(matches.filter { $0.itemID == fixture.sourceID }.count == 1)
        }
    }

    // MARK: - CK-INT-4: §13.2 zero factoid artifacts

    @Test("CK-INT-4: no factoid drawers, no _distilled_from tunnels, no [DIST| content")
    func zeroFactoidArtifacts() async throws {
        try await withCognitionLock {
            let fixture = try await setUpDistilledEstate()
            let estate = try await fixture.kit.estate(for: fixture.handle)
            let drawers = try await estate.allDrawers()
            #expect(!drawers.contains { $0.addedBy == "distillation-daemon" })
            #expect(!drawers.contains { $0.content.hasPrefix("[DIST|") })
            let tunnels = try await estate.allTunnels()
            #expect(!tunnels.contains { $0.label == "_distilled_from" })
        }
    }
}
