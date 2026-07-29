// DistillTests.swift
//
// Integration tests for the Distill recipe (SPEC_DISTILLATION_STORAGE §3/§7).
//
// Test IDs: CK-DI-1 .. CK-DI-8
//
// Distill drives the per-item sweep GeniusLocusKit.distillItemsSweep under
// the p1 contract: every active drawer with non-empty content and a NULL
// (or stale-version) representation gets its four representation columns
// populated on the SOURCE row — matrix path for ≥3 sentences, token
// compaction for shorter items (§7.5). No factoid drawers, no tunnels
// (§11). Idempotent by the NULL predicate.
//
// Layer discipline: estates opened via public GeniusLocusKit API. Items
// captured via the public GLK verb.
//
// Rust mirror: cognition_kit::distill — run_distill delegates to
// EstateCoordinator::distill_items_sweep, mirroring this Swift recipe body.

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

@Suite("DistillTests — on-demand per-item distillation recipe")
struct DistillTests {

    private static let ownerID = "distill-test"
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // A multi-sentence body whose entities recur across its own sentences —
    // takes the §7.4 matrix path.
    private let recurringBody =
        "Research begins. Alice studies CERN. Alice analyses CERN data. " +
        "Alice reports CERN findings. The CERN result stands."

    // A body with fewer than 3 sentences — takes the §7.5 compaction path.
    private let shortBody = "Alice visited CERN. She left."

    // MARK: - Fixtures

    /// Open a locus-only estate (no VectorStore). The sweep still populates
    /// the representation columns — the fingerprint lane is simply dark.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: Self.ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Open an estate with the GLK schema applied AND a registered
    /// VectorStore so the sweep also writes fingerprint-lane entries.
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
                addedBy: "distill-test",
                embeddingModelID: "minilm-v6")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
        }
        return ids
    }

    /// Run Distill via the deterministic internal overload (fixed clock).
    private func runDistill(
        input: Distill.Input = Distill.Input(),
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Distill.Output {
        try await Distill().run(input: input, estate: handle, kit: kit, now: t0)
    }

    // MARK: - Tests

    // CK-DI-1: Empty estate → itemsDistilled = 0, no crash.
    @Test("CK-DI-1: empty estate returns itemsDistilled=0 with no crash")
    func emptyEstate() async throws {
        let (kit, handle) = try await openEstate()
        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 0)
    }

    // CK-DI-2: One multi-sentence item distills onto its own row.
    @Test("CK-DI-2: one item distills — representation columns populated on the source row")
    func oneItemDistills() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        let ids = try await captureItems(count: 1, body: recurringBody, kit: kit, handle: handle)

        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 1)

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: ids).first)
        #expect(row.distilled != nil)
        #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
        #expect(row.distilledTokenCount != nil)
        #expect(row.distilledAt == t0)
        // No factoid drawers, no [DIST| content, anywhere (§13.2).
        let all = try await estate.allDrawers()
        #expect(!all.contains { $0.addedBy == "distillation-daemon" })
        #expect(!all.contains { $0.content.hasPrefix("[DIST|") })
    }

    // CK-DI-3: Multiple items each distill independently.
    @Test("CK-DI-3: each item distills onto its own row")
    func eachItemDistillsIndependently() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        try await captureItems(count: 3, body: recurringBody, kit: kit, handle: handle)
        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 3, "one representation per item")
    }

    // CK-DI-4: Short items (<3 sentences) distill via the §7.5 compaction
    // path — the old skip is retired (§13.1 includes items under 3 sentences).
    @Test("CK-DI-4: a short item (<3 sentences) distills via token compaction")
    func shortItemDistills() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        let ids = try await captureItems(count: 1, body: shortBody, kit: kit, handle: handle)

        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 1, "short items take the §7.5 compaction path")

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: ids).first)
        // The §7.6 transform's canonical rendering of the short body.
        #expect(row.distilled == "Alice visited CERN. She left.")
    }

    // CK-DI-5: Idempotent by the NULL predicate (§7.1).
    @Test("CK-DI-5: re-running the sweep is idempotent — distilled rows are skipped")
    func sweepIsIdempotent() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)

        let first = try await runDistill(kit: kit, handle: handle)
        #expect(first.itemsDistilled == 2)

        let second = try await runDistill(kit: kit, handle: handle)
        #expect(second.itemsDistilled == 0, "distilled IS NOT NULL at the current version → skipped")
    }

    // CK-DI-6: Mixed item lengths — EVERY active non-empty item distills.
    @Test("CK-DI-6: mixed item lengths — every item distills (§13.1)")
    func mixedItemLengths() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)
        try await captureItems(count: 2, body: shortBody, kit: kit, handle: handle)
        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 4, "matrix + compaction paths together cover every item")
    }

    // CK-DI-7: Locus-only estate (no VectorStore): columns still populate;
    // only the fingerprint lane is dark (§7.2 — writes are independent).
    @Test("CK-DI-7: locus-only estate still populates representation columns")
    func locusOnlyEstateStillDistills() async throws {
        let (kit, handle) = try await openEstate()
        let ids = try await captureItems(count: 2, body: recurringBody, kit: kit, handle: handle)

        let out = try await runDistill(kit: kit, handle: handle)
        #expect(out.itemsDistilled == 2, "VectorStore absence must not block column writes")

        let estate = try await kit.estate(for: handle)
        let rows = try await estate.getDrawers(ids: ids)
        #expect(rows.allSatisfy { $0.distilled != nil })
    }

    // CK-DI-8: clusterID and includeHeld are accepted no-ops.
    // Mirrors Rust CK-CON-3 (cluster_id/include_held no-ops must not error).
    @Test("CK-DI-8: clusterID and includeHeld are accepted without error, results unchanged")
    func clusterIDAndIncludeHeldAreNoOps() async throws {
        let (kit, handle, _, _) = try await openEstateWithVectorStore()
        try await captureItems(count: 1, body: recurringBody, kit: kit, handle: handle)

        let outWithParams = try await runDistill(
            input: Distill.Input(clusterID: "some-cluster", includeHeld: true),
            kit: kit, handle: handle)
        #expect(outWithParams.itemsDistilled == 1,
            "clusterID/includeHeld must not suppress eligible items (they are no-ops)")

        let outSecond = try await runDistill(
            input: Distill.Input(clusterID: "some-cluster", includeHeld: true),
            kit: kit, handle: handle)
        #expect(outSecond.itemsDistilled == 0,
            "second run with no-op params must still respect idempotency")
    }
}
