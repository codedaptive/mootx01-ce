// ConsolidateTests.swift
//
// Integration tests for the Consolidate recipe under the INTRA-ITEM model.
//
// Test IDs: CK-CO-1 .. CK-CO-8
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
// Rust mirror: cognition_kit::consolidate — run_consolidate delegates to
// EstateCoordinator::distill_items_sweep, mirroring this Swift recipe body.
// Tests: CK-CON-1..CK-CON-3 in consolidate.rs (IMM-COG-001).

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

    // wing is the fixed constant LocusKit.defaultWingName ("Agentic Memory").
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

    // CK-CO-8: Source-count invariant — reported src= in the DIST header equals the
    // number of _distilled_from tunnels, which equals the number of sources recollect
    // returns. For the intra-item model each factoid has exactly ONE source (the item
    // itself), so the invariant is: sourceCount == 1 == tunnels.count == expand.sources.count.
    //
    // This test guards the bug where src=N in the DIST header was set to M (sentence count)
    // instead of sourceIDs.count (source memory count), causing reported sources: 3/5/N
    // while recollect returned only 1 source.
    @Test("CK-CO-8: source-count invariant — DIST header src== tunnel count == recollect sources count")
    func sourceCountMatchesTunnelsAndExpand() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        // Capture one multi-sentence item. The intra-item pipeline runs on its
        // own sentences; the factoid should link back to this single source.
        let sourceIDs = try await captureItems(count: 1, body: recurringBody, kit: kit, handle: handle)
        let sourceID = sourceIDs[0]

        let out = try await runConsolidate(kit: kit, handle: handle)
        #expect(out.factoidsProduced == 1)

        // Resolve the factoid drawer. Since Drawer no longer carries wing/room,
        // resolve display names via the estate's node tree to find the _distilled room.
        let allDrawers = try await kit.allDrawers(in: handle)
        let estate = try await kit.estate(for: handle)
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: allDrawers.map(\.parentNodeId))
        let factoidDrawer = try #require(
            allDrawers.first { nodeNames[$0.parentNodeId]?.room == "_distilled" && $0.lineageID.uuidString == sourceID },
            "one factoid in _distilled whose lineageID == sourceID")

        // 1. DIST header src= must be 1 (one source memory, not sentence count).
        let factoidContent = try await kit.hydrate(handle, ids: [factoidDrawer.id])
        let content = try #require(factoidContent[factoidDrawer.id], "factoid must be hydrateable")
        let header = try #require(DistilledHeader.parse(content), "factoid must have a DIST header")
        #expect(header.sourceCount == 1,
            "src= in DIST header must be 1 (sourceIDs.count), not the sentence count")

        // 2. _distilled_from tunnel count must be 1.
        let allTunnels = try await kit.recallTunnels(handle, wing: LocusKit.defaultWingName)
        let sourceTunnels = allTunnels.filter {
            $0.label == "_distilled_from" && $0.sourceDrawerId == factoidDrawer.id
        }
        #expect(sourceTunnels.count == 1,
            "_distilled_from tunnel count must equal sourceIDs.count (1)")

        // 3. recollect sources.count must be 1, and sourceCount (from header) must agree.
        let expandOut = try await Recollect().run(
            input: Recollect.Input(factoidDrawerID: factoidDrawer.id),
            estate: handle, kit: kit)
        #expect(expandOut.sourceCount == 1,
            "Recollect.Output.sourceCount must equal the DIST header src= value (1)")
        #expect(expandOut.sources.count == 1,
            "recollect must return exactly 1 source for an intra-item factoid")
        #expect(expandOut.sourceCount == expandOut.sources.count,
            "sourceCount (DIST header) must equal sources.count (actual tunnels returned)")
        #expect(expandOut.sources[0].id == sourceID,
            "the single expanded source must be the original captured item")
    }

    // CK-CO-9: clusterID and includeHeld are accepted no-ops — passing non-nil /
    // non-default values must not cause errors and must not change sweep behavior.
    // Mirrors Rust CK-CON-3 (cluster_id/include_held no-ops must not cause errors).
    @Test("CK-CO-9: clusterID and includeHeld are accepted without error, results are unchanged")
    func clusterIDAndIncludeHeldAreNoOps() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()

        try await captureItems(count: 1, body: recurringBody, kit: kit, handle: handle)

        // Run with both no-op parameters set to non-default values. Sweep must
        // produce the same factoid count as with default Input.
        let outWithParams = try await runConsolidate(
            input: Consolidate.Input(clusterID: "some-cluster", includeHeld: true),
            kit: kit, handle: handle)
        #expect(outWithParams.factoidsProduced == 1,
            "clusterID/includeHeld must not suppress eligible items (they are no-ops)")

        // Idempotency: a second run with the same no-op params produces 0 (item already distilled).
        let outSecond = try await runConsolidate(
            input: Consolidate.Input(clusterID: "some-cluster", includeHeld: true),
            kit: kit, handle: handle)
        #expect(outSecond.factoidsProduced == 0,
            "second run with no-op params must still respect idempotency (already distilled)")
    }
}
