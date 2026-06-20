// ConsolidateTests.swift
//
// Integration tests for the Consolidate recipe under the INTRA-ITEM model.
//
// Test IDs: CK-CO-1 .. CK-CO-7
//
// Consolidate drives the PER-ITEM sweep GeniusLocusKit.distillItemsSweep:
// each stored item is reduced from its OWN sentences (intraItem: true). These
// tests verify the per-item contract: items with ≥3 sentences and a non-zero
// feature fingerprint produce one factoid each; short items are skipped;
// the sweep is idempotent.
//
// Layer discipline: estates opened via public GeniusLocusKit API. Items captured
// via the public GLK verb.
//
// Rust mirror: Consolidate is Swift-only at this revision (the Rust port keeps
// the recipe as pure data types; the per-item sweep storage orchestration lives
// at the GLK coordinator level).

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

@Suite("ConsolidateTests — on-demand per-item distillation recipe (DC1)")
struct ConsolidateTests {

    // ADR-016: wing is the fixed constant LocusKit.defaultWingName ("Agentic Memory").
    private static let ownerID = "consolidate-test"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // A multi-sentence body whose entities recur across its own sentences, so
    // the intra-item pipeline forms a non-zero fingerprint and produces a factoid.
    // Capitalized non-first-word entities (Alice, CERN) recur across sentences,
    // which the defaultExtractor picks up; ≥3 sentences clears the M≥3 guard.
    private let recurringBody =
        "Research begins. Alice studies CERN. Alice analyses CERN data. " +
        "Alice reports CERN findings. The CERN result stands."

    // A body with fewer than 3 sentences — too short to distill intra-item.
    private let shortBody = "Alice visited CERN. She left."

    // MARK: - Fixtures

    /// Open a locus-only estate (no VectorStore). The per-item sweep returns 0
    /// immediately when no VectorStore is registered.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Open an estate with the GLK schema applied AND a registered VectorStore so
    /// distillItemsSweep can capture factoids and store their fingerprints.
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

    /// Capture `count` items with the given body via the public GLK verb.
    @discardableResult
    private func captureItems(
        count: Int,
        body: String,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> [String] {
        var ids: [String] = []
        for _ in 0..<count {
            let frame = CaptureFrame(
                content: body,
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

    /// Run Consolidate via the deterministic internal overload (defaultExtractor,
    /// fixed clock) so factoid production does not depend on the HMM tagger's SNR
    /// response to synthetic fixture sentences.
    private func runConsolidate(
        input: Consolidate.Input = Consolidate.Input(),
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Consolidate.Output {
        try await Consolidate().run(
            input: input,
            estate: handle,
            kit: kit,
            extractFeatures: DistillationPipeline.defaultExtractor,
            now: t0)
    }

    // MARK: - Tests

    // CK-CO-1: Empty estate (no VectorStore, no items) → factoidsProduced = 0, no crash.
    @Test("CK-CO-1: empty estate returns factoidsProduced=0 with no crash")
    func emptyEstate() async throws {
        let (kit, handle) = try await openEstate()

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 0)
    }

    // CK-CO-2: A single recurring multi-sentence item produces exactly one factoid.
    @Test("CK-CO-2: one recurring multi-sentence item produces one factoid")
    func oneItemProducesOneFactoid() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 1, body: recurringBody, kit: kit, handle: handle)

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 1)
    }

    // CK-CO-3: Multiple recurring items each distill into their own factoid.
    @Test("CK-CO-3: each recurring item distills into its own factoid")
    func eachItemDistillsIndependently() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 3, body: recurringBody, kit: kit, handle: handle)

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 3, "one factoid per item")
    }

    // CK-CO-4: An item with fewer than 3 sentences is too short to distill and is
    // skipped (no factoid, no error).
    @Test("CK-CO-4: a short item (<3 sentences) is skipped")
    func shortItemSkipped() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 1, body: shortBody, kit: kit, handle: handle)

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 0, "an item with <3 sentences must not distill")
    }

    // CK-CO-5: The per-item sweep is idempotent. A second run produces no new
    // factoids because already-distilled items (lineageID == source id) are skipped.
    @Test("CK-CO-5: re-running the sweep is idempotent — already-distilled items are skipped")
    func sweepIsIdempotent() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)

        let first = try await runConsolidate(kit: kit, handle: handle)
        #expect(first.factoidsProduced == 2)

        let second = try await runConsolidate(kit: kit, handle: handle)
        #expect(second.factoidsProduced == 0, "already-distilled items must be skipped on re-run")
    }

    // CK-CO-6: A mix of distillable and short items produces a factoid only for the
    // distillable ones.
    @Test("CK-CO-6: mixed item lengths — only items with ≥3 sentences distill")
    func mixedItemLengths() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)
        try await captureItems(count: 2, body: shortBody, kit: kit, handle: handle)

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 2, "only the two multi-sentence items distill")
    }

    // CK-CO-7: With no VectorStore registered, the sweep produces nothing even when
    // distillable items exist (locus-only estate guard).
    @Test("CK-CO-7: locus-only estate (no VectorStore) produces no factoids")
    func locusOnlyEstateProducesNothing() async throws {
        let (kit, handle) = try await openEstate()

        try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)

        let out = try await runConsolidate(kit: kit, handle: handle)

        #expect(out.factoidsProduced == 0)
    }
}
