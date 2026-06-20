// DistillationCycleTests.swift
//
// Tests for the per-item distillation path.
//
// Coverage:
//  T8   distillItem produces a factoid (non-zero fingerprint) even when
//       confidence < 0.4 (intra-item gate is fingerprint, not confidence).
//  T9   distillItem returns nil for an item with fewer than 3 sentences
//       (M < 3 degenerates the feature matrix).
//  T10  distillItem returns nil when the pipeline yields a zero fingerprint
//       (empty dominant component F*).
//  T11  distillItemsSweep distills each eligible item once and is idempotent
//       on re-run (lineageID-based deduplication).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("DistillationCycle — per-item distillation")
struct DistillationCycleTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private let modelID = "minilm-v6"

    // MARK: - Fixtures

    /// Open one estate with a VectorStore registered.
    private func openEstate() async throws -> (
        GeniusLocusKit, EstateHandle, VectorStore
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-distill-tests")
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

        return (kit, handle, vectorStore)
    }

    /// Capture one multi-sentence item and return its drawer id.
    private func captureItem(
        body: String,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> String {
        let frame = CaptureFrame(
            content: body,
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "test-distill",
            embeddingModelID: modelID
        )
        let drawer = try await kit.capture(handle, frame)
        return drawer.id
    }

    // MARK: - Stub distillFn closures

    /// Stub that returns a successful intra-item DistillationOutput with a
    /// NON-ZERO fingerprint. The gate for per-item distillation is the
    /// fingerprint being non-zero, not confidence.
    private func intraItemFn(
        fingerprint: Fingerprint256
    ) -> @Sendable (DistillationInput) -> DistillationOutput {
        return { input in
            let m = input.memoryContents.count
            return DistillationOutput(
                drawerContent: "[DIST|conf=0.30|src=\(m)|snr=4.00|delta=STATIC] item factoid",
                confidence: 0.30,       // below the old cross-memory 0.4 gate on purpose
                uncertain: false,
                snr: 4.0,
                deltaType: nil,
                succeeded: false,       // intra-item gate is fingerprint, not succeeded flag
                failureReason: nil,
                featureFingerprint: fingerprint
            )
        }
    }

    /// Stub that returns a ZERO fingerprint — intra-item must NOT produce a factoid.
    private var intraItemZeroFn: @Sendable (DistillationInput) -> DistillationOutput {
        return { _ in
            DistillationOutput(
                drawerContent: "",
                confidence: 0.0,
                uncertain: false,
                snr: 0.0,
                deltaType: nil,
                succeeded: false,
                failureReason: "PMI graph produced no dominant component",
                featureFingerprint: Fingerprint256.zero
            )
        }
    }

    // A non-zero engram for intra-item fingerprint stubs.
    private var nonZeroFingerprint256: Fingerprint256 {
        DistillationPipeline.featureHash("provenance")
    }

    // A three-sentence body — clears the M ≥ 3 intra-item guard.
    private let threeSentenceBody = "First fact holds. Second fact holds. Third fact holds."

    // MARK: - T8: distillItem produces a factoid when fingerprint is non-zero

    @Test("distillItem produces a factoid (non-zero fingerprint) even when confidence < 0.4")
    func distillItemProducesFactoid() async throws {
        let (kit, handle, _) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        let factoidID = try await kit.distillItem(
            handle: handle,
            drawerID: itemID,
            content: threeSentenceBody,
            distillFn: intraItemFn(fingerprint: nonZeroFingerprint256),
            now: t0
        )
        #expect(factoidID != nil, "a non-zero fingerprint must produce a factoid for intra-item")
    }

    // MARK: - T9: distillItem skips a too-short item (< 3 sentences)

    @Test("distillItem returns nil for an item with fewer than 3 sentences")
    func distillItemSkipsShortItem() async throws {
        let (kit, handle, _) = try await openEstate()
        let shortBody = "Only one sentence here."
        let itemID = try await captureItem(body: shortBody, kit: kit, handle: handle)

        let factoidID = try await kit.distillItem(
            handle: handle,
            drawerID: itemID,
            content: shortBody,
            distillFn: intraItemFn(fingerprint: nonZeroFingerprint256),
            now: t0
        )
        #expect(factoidID == nil, "an item with < 3 sentences must not distill")
    }

    // MARK: - T10: distillItem skips when the fingerprint is zero

    @Test("distillItem returns nil when the pipeline yields a zero fingerprint")
    func distillItemSkipsZeroFingerprint() async throws {
        let (kit, handle, _) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        let factoidID = try await kit.distillItem(
            handle: handle,
            drawerID: itemID,
            content: threeSentenceBody,
            distillFn: intraItemZeroFn,
            now: t0
        )
        #expect(factoidID == nil, "a zero fingerprint (empty F*) must not produce a factoid")
    }

    // MARK: - T11: distillItemsSweep is idempotent

    @Test("distillItemsSweep distills each eligible item once and is idempotent on re-run")
    func distillItemsSweepIdempotent() async throws {
        let (kit, handle, _) = try await openEstate()
        _ = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)
        _ = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        let first = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: intraItemFn(fingerprint: nonZeroFingerprint256),
            now: t0,
            limit: nil
        )
        #expect(first == 2, "both eligible items must distill on the first sweep")

        let second = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: intraItemFn(fingerprint: nonZeroFingerprint256),
            now: t0,
            limit: nil
        )
        #expect(second == 0, "already-distilled items (lineageID == source id) must be skipped")
    }
}
