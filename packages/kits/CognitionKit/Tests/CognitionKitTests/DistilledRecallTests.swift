// DistilledRecallTests.swift
//
// End-to-end tests for the DistilledRecall recipe over a real
// GeniusLocusKit in-memory estate. No mocks.
//
// Test setup: capture a drawer in room "_distilled" with a DIST header
// content string, add its structural fingerprint to a VectorStore under
// the "distillation-features-v1" model lane, then run the recipe. The
// query fingerprint is computed with DistillationPipeline.defaultExtractor
// and stored as the drawer's fingerprint so the Hamming NN returns
// a distance-0 match.
//
// Coverage:
//   CK-DR-1: happy path — one distilled drawer + matching vector; recipe
//             returns at least one DistilledMatch.
//   CK-DR-2: DistilledMatch.prose matches DistilledHeader.parse prose.
//   CK-DR-3a: injectionDepth is .factoidOnly for confidence >= 0.7.
//   CK-DR-3b: injectionDepth is .factoidWithMeta for confidence ∈ [0.4, 0.7).
//   CK-DR-4: empty estate (no vectors) → matches = [], no crash.

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

@Suite("DistilledRecallTests")
struct DistilledRecallTests {

    /// Deterministic seed time — never Date() in tests that assert ordering.
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Helpers

    /// Open an in-memory estate and register a VectorStore against it.
    ///
    /// Follows the FindNearestDistilledTests pattern: explicit Estate.create
    /// before kit.open ensures the schema is initialised before any captures.
    private func openEstateWithVectorStore() async throws -> (GeniusLocusKit, EstateHandle, VectorStore) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "distilled-recall-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle, vectorStore)
    }

    /// Capture one `_distilled` drawer and add its fingerprint to the VectorStore.
    ///
    /// The content is the canonical DIST format:
    ///   "[DIST|conf=X.XX|src=N|snr=Y.Y|delta=STATIC[|uncertain]] prose"
    /// The fingerprint stored in the VectorStore is the same fingerprint used
    /// as the query probe, guaranteeing a Hamming distance-0 match.
    ///
    /// Returns the captured drawer's stable UUID.
    private func captureDistilledDrawer(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vectorStore: VectorStore,
        prose: String,
        confidence: Float32,
        fingerprint: Engram
    ) async throws -> String {
        // Build the DIST header. Append |uncertain for confidence ∈ [0.4, 0.7).
        let uncertainFlag = (confidence >= 0.4 && confidence < 0.7) ? "|uncertain" : ""
        let content = "[DIST|conf=\(String(format: "%.2f", confidence))|src=3|snr=4.50|delta=STATIC\(uncertainFlag)] \(prose)"
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "_distilled",
            latticeAnchor: .udc("0"),
            addedBy: "distillation-daemon",
            embeddingModelID: "test-v1")
        let drawer = try await kit.capture(handle, frame)
        try await vectorStore.addVector(
            itemID: drawer.id,
            engram: fingerprint,
            modelID: "distillation-features-v1",
            modelVersion: "1.0",
            filedAt: t0)
        return drawer.id
    }

    // MARK: - CK-DR-1: Happy path

    /// One distilled drawer + matching vector: recipe must return at least one match.
    @Test("happy path: one distilled drawer returns one DistilledMatch")
    func happyPathReturnsMatch() async throws {
        try await withCognitionLock {
            let (kit, handle, store) = try await openEstateWithVectorStore()

            // defaultExtractor finds no entities in all-lowercase text so the
            // fingerprint is Fingerprint256.zero. Store the same zero fingerprint
            // for the drawer → Hamming distance 0 → guaranteed top match.
            let query = "test query with no named entities"
            let queryFP = DistillationPipeline.queryFingerprint(
                query: query, extractFeatures: DistillationPipeline.defaultExtractor)

            _ = try await captureDistilledDrawer(
                kit: kit, handle: handle, vectorStore: store,
                prose: "the sky is blue on clear days",
                confidence: 0.85, fingerprint: queryFP)

            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: query),
                estate: handle, kit: kit)

            #expect(!output.matches.isEmpty,
                "recipe must return at least one match from the distilled tier")
        }
    }

    // MARK: - CK-DR-2: prose fidelity

    /// DistilledMatch.prose must equal the prose portion of the stored DIST header.
    @Test("DistilledMatch.prose matches the DIST header prose field")
    func proseMatchesParsedHeader() async throws {
        try await withCognitionLock {
            let (kit, handle, store) = try await openEstateWithVectorStore()

            let query = "test query with no named entities"
            let queryFP = DistillationPipeline.queryFingerprint(
                query: query, extractFeatures: DistillationPipeline.defaultExtractor)
            let expectedProse = "the sky is blue on clear days"

            let drawerID = try await captureDistilledDrawer(
                kit: kit, handle: handle, vectorStore: store,
                prose: expectedProse, confidence: 0.85, fingerprint: queryFP)

            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: query),
                estate: handle, kit: kit)

            let match = try #require(
                output.matches.first { $0.id == drawerID },
                "match for drawer \(drawerID) must be present in recipe output")
            #expect(match.prose == expectedProse,
                "prose must equal the content after the DIST header closing bracket")
        }
    }

    // MARK: - CK-DR-3a: injectionDepth for high confidence

    /// confidence >= 0.7 → injectionDepth must be .factoidOnly.
    @Test("injectionDepth is .factoidOnly for confidence >= 0.7")
    func injectionDepthFactoidOnly() async throws {
        try await withCognitionLock {
            let (kit, handle, store) = try await openEstateWithVectorStore()
            let query = "test"
            let fp = DistillationPipeline.queryFingerprint(
                query: query, extractFeatures: DistillationPipeline.defaultExtractor)

            _ = try await captureDistilledDrawer(
                kit: kit, handle: handle, vectorStore: store,
                prose: "high confidence factoid", confidence: 0.85, fingerprint: fp)

            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: query), estate: handle, kit: kit)

            let match = try #require(output.matches.first, "expected at least one match")
            #expect(match.injectionDepth == .factoidOnly,
                "confidence 0.85 >= 0.7 must yield .factoidOnly")
        }
    }

    // MARK: - CK-DR-3b: injectionDepth for mid confidence

    /// confidence ∈ [0.4, 0.7) → injectionDepth must be .factoidWithMeta.
    @Test("injectionDepth is .factoidWithMeta for confidence in [0.4, 0.7)")
    func injectionDepthFactoidWithMeta() async throws {
        try await withCognitionLock {
            let (kit, handle, store) = try await openEstateWithVectorStore()
            let query = "test"
            let fp = DistillationPipeline.queryFingerprint(
                query: query, extractFeatures: DistillationPipeline.defaultExtractor)

            _ = try await captureDistilledDrawer(
                kit: kit, handle: handle, vectorStore: store,
                prose: "mid confidence factoid", confidence: 0.55, fingerprint: fp)

            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: query), estate: handle, kit: kit)

            let match = try #require(output.matches.first, "expected at least one match")
            #expect(match.injectionDepth == .factoidWithMeta,
                "confidence 0.55 ∈ [0.4, 0.7) must yield .factoidWithMeta")
        }
    }

    // MARK: - CK-DR-4: Empty estate

    /// An estate with no distilled vectors must return an empty match list without crashing.
    @Test("empty estate returns empty matches without crash")
    func emptyEstateReturnsEmpty() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await openEstateWithVectorStore()

            let recipe = DistilledRecall()
            let output = try await recipe.run(
                input: DistilledRecall.Input(query: "anything"),
                estate: handle, kit: kit)

            #expect(output.matches.isEmpty,
                "estate with no distilled vectors must return an empty match list")
            #expect(output.discrimination == .single,
                "empty result must yield .single discrimination")
        }
    }
}
