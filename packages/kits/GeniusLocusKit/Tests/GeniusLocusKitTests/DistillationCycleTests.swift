// DistillationCycleTests.swift
//
// Tests for the per-item distillation path — SPEC_DISTILLATION_STORAGE
// §7 (generation paths), §8 (lane re-key), §11 (factoid retirement).
//
// Coverage:
//  • distillItem writes the four representation columns on the SOURCE
//    drawer row (§7.2) — no factoid drawer, no tunnel, no lineage touch.
//  • Short items (<3 sentences) distill via the token-compaction path
//    (§7.5) — the old M < 3 skip is retired.
//  • Zero fingerprint: the rendering is still stored; no lane entry is
//    written (columns and lane independently valid, §7.5).
//  • The lane entry is keyed by the SOURCE drawer id (§8).
//  • distillItemsSweep is idempotent by the NULL predicate (§7.1) and
//    covers every active non-empty item (§13.1), at every sensitivity.
//  • Zero factoid drawers in new-write paths (§13.2).
//
// The Rust twin coverage lives in coordinator.rs distillation tests +
// distill_segmentation_parity.rs.

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

    /// Capture one item and return its drawer id.
    private func captureItem(
        body: String,
        kit: GeniusLocusKit,
        handle: EstateHandle,
        sensitivity: AdjectiveSensitivity? = nil
    ) async throws -> String {
        var frame = CaptureFrame(
            content: body,
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "test-distill",
            embeddingModelID: modelID
        )
        if let sensitivity {
            frame.sensitivity = sensitivity
        }
        let drawer = try await kit.capture(handle, frame)
        return drawer.id
    }

    // MARK: - Stub distillFn closures

    /// Stub returning a fixed rendering + fingerprint (the matrix path's
    /// output shape, §7.4).
    private func stubFn(
        rendering: String,
        fingerprint: Fingerprint256
    ) -> @Sendable (DistillationInput) -> DistillationOutput {
        return { _ in
            DistillationOutput(
                distilledText: rendering,
                confidence: 0.30,
                uncertain: false,
                snr: 4.0,
                deltaType: nil,
                succeeded: false,
                failureReason: nil,
                featureFingerprint: fingerprint
            )
        }
    }

    /// Stub returning a ZERO fingerprint and empty rendering — the
    /// degenerate-matrix case.
    private var zeroFn: @Sendable (DistillationInput) -> DistillationOutput {
        return { _ in
            DistillationOutput(
                distilledText: "",
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

    private var nonZeroFingerprint256: Fingerprint256 {
        DistillationPipeline.featureHash("provenance")
    }

    // A three-sentence body — takes the matrix path (M ≥ 3).
    private let threeSentenceBody = "First fact holds. Second fact holds. Third fact holds."

    // MARK: - §7.2: representation columns on the source row

    @Test("distillItem writes the four representation columns on the SOURCE row")
    func distillItemWritesColumnsOnSourceRow() async throws {
        let (kit, handle, _) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        let distilled = try await kit.distillItem(
            handle: handle,
            drawerID: itemID,
            content: threeSentenceBody,
            distillFn: stubFn(rendering: "First fact. Second fact. Third fact.",
                              fingerprint: nonZeroFingerprint256),
            now: t0
        )
        #expect(distilled)

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [itemID]).first)
        #expect(row.distilled == "First fact. Second fact. Third fact.")
        #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
        #expect(row.distilledTokenCount != nil)
        #expect(row.distilledAt == t0)
        // Content untouched — the representation is a parallel view.
        #expect(row.content == threeSentenceBody)
    }

    @Test("distillItem writes NO factoid drawer and NO tunnel (§11)")
    func distillItemWritesNoFactoidNoTunnel() async throws {
        let (kit, handle, _) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)
        let estate = try await kit.estate(for: handle)
        let drawersBefore = try await estate.allDrawers().count

        _ = try await kit.distillItem(
            handle: handle, drawerID: itemID, content: threeSentenceBody,
            distillFn: stubFn(rendering: "rendered", fingerprint: nonZeroFingerprint256),
            now: t0)

        // §13.2: no new drawer rows, no distillation-daemon provenance,
        // no _distilled_from tunnels, no [DIST| content anywhere.
        let drawers = try await estate.allDrawers()
        #expect(drawers.count == drawersBefore)
        #expect(!drawers.contains { $0.addedBy == "distillation-daemon" })
        #expect(!drawers.contains { $0.content.hasPrefix("[DIST|") })
        let tunnels = try await estate.allTunnels()
        #expect(!tunnels.contains { $0.label == "_distilled_from" })
    }

    // MARK: - §7.5: short-item path

    @Test("short item (<3 sentences) distills via token compaction")
    func shortItemDistillsViaCompaction() async throws {
        let (kit, handle, _) = try await openEstate()
        let shortBody = "My favorite color is blue."
        let itemID = try await captureItem(body: shortBody, kit: kit, handle: handle)

        let distilled = try await kit.distillItem(
            handle: handle,
            drawerID: itemID,
            content: shortBody,
            // The stub must NOT be called on the short path — the guard
            // proves it by producing a sentinel the assertions reject.
            distillFn: stubFn(rendering: "MATRIX-PATH-SENTINEL",
                              fingerprint: nonZeroFingerprint256),
            now: t0
        )
        #expect(distilled, "short items distill via the §7.5 compaction path")

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [itemID]).first)
        // The §7.6 transform's canonical rendering of the §5.4 example.
        #expect(row.distilled == "My favorite color blue.")
        #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
        #expect(row.distilledTokenCount == TokenCompaction.estimateTokenCount("My favorite color blue."))
    }

    // MARK: - §7.5/§8: lane entry independence and re-key

    @Test("zero fingerprint: rendering stored, no lane entry (columns and lane independent)")
    func zeroFingerprintStoresColumnsSkipsLane() async throws {
        let (kit, handle, vectorStore) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        let distilled = try await kit.distillItem(
            handle: handle, drawerID: itemID, content: threeSentenceBody,
            distillFn: zeroFn, now: t0)
        #expect(distilled, "the rendering is still stored when no features extracted")

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [itemID]).first)
        // Degenerate matrix falls back to the compaction rendering (§13.1).
        #expect(row.distilled != nil)
        // No lane entry for a zero fingerprint.
        let matches = try await vectorStore.findNearest(
            probe: nonZeroFingerprint256,
            modelID: GeniusLocusKit.distillationLaneModelID,
            limit: 10)
        #expect(matches.isEmpty)
    }

    @Test("lane entry is keyed by the SOURCE drawer id (§8 re-key)")
    func laneEntryKeyedBySourceDrawerID() async throws {
        let (kit, handle, vectorStore) = try await openEstate()
        let itemID = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)

        _ = try await kit.distillItem(
            handle: handle, drawerID: itemID, content: threeSentenceBody,
            distillFn: stubFn(rendering: "rendered", fingerprint: nonZeroFingerprint256),
            now: t0)

        let matches = try await vectorStore.findNearest(
            probe: nonZeroFingerprint256,
            modelID: GeniusLocusKit.distillationLaneModelID,
            limit: 10)
        #expect(matches.count == 1)
        #expect(matches.first?.itemID == itemID,
                "the lane key is the SOURCE drawer id, not a factoid id")
    }

    // MARK: - §7.1/§13.1: sweep coverage and idempotence

    @Test("distillItemsSweep covers every active non-empty item and is idempotent by the NULL predicate")
    func distillItemsSweepIdempotent() async throws {
        let (kit, handle, _) = try await openEstate()
        _ = try await captureItem(body: threeSentenceBody, kit: kit, handle: handle)
        // A SHORT item is eligible too (§13.1 includes items under 3 sentences).
        _ = try await captureItem(body: "Favorite color is blue.", kit: kit, handle: handle)

        let first = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: stubFn(rendering: "rendered", fingerprint: nonZeroFingerprint256),
            now: t0,
            limit: nil
        )
        #expect(first == 2, "both eligible items (matrix + short path) must distill on the first sweep")

        let second = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: stubFn(rendering: "rendered", fingerprint: nonZeroFingerprint256),
            now: t0,
            limit: nil
        )
        #expect(second == 0, "distilled IS NOT NULL at the current pipeline version → skipped (§7.1)")
    }

    @Test("sweep distills restricted/secret rows too — the representation rides the row's own sensitivity (§2)")
    func sweepCoversAllSensitivities() async throws {
        let (kit, handle, _) = try await openEstate()
        let secretID = try await captureItem(
            body: threeSentenceBody, kit: kit, handle: handle, sensitivity: .secret)

        let produced = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: stubFn(rendering: "secret rendering", fingerprint: nonZeroFingerprint256),
            now: t0, limit: nil)
        #expect(produced == 1)

        // The representation lives on the row whose sensitivity governs it —
        // there is no cross-row sensitivity floor to enforce (§2).
        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [secretID]).first)
        #expect(row.adjectiveSensitivity == .secret)
        #expect(row.distilled == "secret rendering")
    }
}
