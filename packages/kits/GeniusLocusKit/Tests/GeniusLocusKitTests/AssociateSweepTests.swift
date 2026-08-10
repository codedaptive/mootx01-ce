// AssociateSweepTests.swift
//
// Tests for `GeniusLocusKit.associateSweep(in:probeLimit:now:)`.
//
// Four coverage cases:
//   1. Associations form on planted-similar vectors (nil probeLimit — all items).
//   2. Bounded probeLimit coverage — probeLimit: 1 finds the single probed pair.
//   3. Dedup holds on re-run — a second sweep writes 0, all deduplicated.
//   4. Counts accurate — probed / candidatePairs / written / deduplicated match
//      expected values for a two-item estate with identical engrams.
//
// Additionally, the signal-behavior-unchanged invariant is verified via the
// existing StandingSignalsTests; these tests focus on the direct verb surface.

import Testing
import Foundation
import SubstrateTypes
import VectorKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// Engram is a typealias for Fingerprint256 in EngramLib.
private typealias Engram = Fingerprint256

@Suite("associateSweep verb — proximity scan + write path", .serialized)
struct AssociateSweepTests {

    // MARK: - Fixture

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Open a fresh in-memory estate and register an empty VectorStore.
    /// Returns (kit, handle, vectorStore) so tests can plant vectors.
    private func openEstateWithVectorStore() async throws -> (GeniusLocusKit, EstateHandle, VectorStore) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "assoc-sweep-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Build a separate in-memory VectorStore and register it.
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle, vectorStore)
    }

    /// Capture a drawer and file an engram for it in `vectorStore`.
    /// Returns the drawer's ID.
    @discardableResult
    private func plantDrawer(
        content: String,
        engram: Engram,
        modelID: String = "minilm-v6",
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vectorStore: VectorStore
    ) async throws -> String {
        let drawer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: "test-room",
            latticeAnchor: .udc("000"),
            addedBy: "assoc-sweep-test",
            embeddingModelID: modelID))
        // File the engram under the drawer's ID so ProximityScanCore Lane 1 finds it.
        try await vectorStore.addVector(
            itemID: drawer.id, engram: engram,
            modelID: modelID, modelVersion: "v1", filedAt: now)
        return drawer.id
    }

    // MARK: - Test 1 — associations form, nil probeLimit (all coverage)

    /// Two drawers with identical engrams (Hamming distance 0, well within
    /// the default proximity threshold of 64) produce one written association
    /// when `associateSweep` is called with `probeLimit: nil` (all items).
    @Test func associateSweepWritesOnSimilarPair() async throws {
        let (kit, handle, vectorStore) = try await openEstateWithVectorStore()

        let idA = try await plantDrawer(
            content: "alpha", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)
        let idB = try await plantDrawer(
            content: "beta", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)

        // nil probeLimit = all items.
        let report = try await kit.associateSweep(in: handle, probeLimit: nil, now: now)

        // Both items probed; one candidate pair; one association written.
        #expect(report.probed == 2, "both items must be probed (nil probeLimit = all)")
        #expect(report.candidatePairs >= 1, "identical engrams must produce at least one candidate pair")
        #expect(report.written >= 1, "at least one association must be written")
        #expect(report.deduplicated == 0, "no existing associations on a fresh estate")
        _ = idA; _ = idB // silence unused-var warning
    }

    // MARK: - Test 2 — bounded probeLimit

    /// With `probeLimit: 1`, only the most recently filed item is probed.
    /// An estate with two identical-engram drawers still produces a written
    /// association because the neighbour search is unbounded — the probe
    /// finds its clone in the whole-estate kNN scan even with one probe.
    @Test func associateSweepBoundedProbeLimitFindsNeighbour() async throws {
        let (kit, handle, vectorStore) = try await openEstateWithVectorStore()

        try await plantDrawer(
            content: "gamma", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)
        try await plantDrawer(
            content: "delta", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)

        // Probe only the single most-recently-filed item; neighbours search whole estate.
        let report = try await kit.associateSweep(in: handle, probeLimit: 1, now: now)

        #expect(report.probed == 1, "probeLimit:1 must probe exactly one item")
        // Neighbour search is estate-wide, so the clone is still found.
        #expect(report.candidatePairs >= 1, "kNN neighbour search covers the whole estate")
        #expect(report.written >= 1, "at least one association written even with bounded probe")
    }

    // MARK: - Test 3 — dedup holds on re-run

    /// Running `associateSweep` twice on the same estate must write 0 on the
    /// second call: the first call writes the association, and the second call
    /// finds it in the settled set and marks it deduplicated.
    @Test func associateSweepDeduplicationHoldsOnRerun() async throws {
        let (kit, handle, vectorStore) = try await openEstateWithVectorStore()

        try await plantDrawer(
            content: "echo", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)
        try await plantDrawer(
            content: "foxtrot", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)

        // First sweep: should write at least one association.
        let first = try await kit.associateSweep(in: handle, probeLimit: nil, now: now)
        #expect(first.written >= 1, "first sweep must write at least one association")

        // Second sweep: all candidate pairs already exist → zero written.
        let second = try await kit.associateSweep(in: handle, probeLimit: nil, now: now)
        #expect(second.written == 0, "second sweep must write nothing — all pairs already settled")
        #expect(second.deduplicated == first.written,
            "second sweep deduplicated count must equal first sweep written count")
    }

    // MARK: - Test 4 — counts accurate

    /// Verify that `probed + candidatePairs + written + deduplicated` all
    /// agree with the known estate state for a clean two-drawer fixture.
    @Test func associateSweepCountsAreAccurate() async throws {
        let (kit, handle, vectorStore) = try await openEstateWithVectorStore()

        try await plantDrawer(
            content: "golf", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)
        try await plantDrawer(
            content: "hotel", engram: .zero,
            kit: kit, handle: handle, vectorStore: vectorStore)

        let report = try await kit.associateSweep(in: handle, probeLimit: nil, now: now)

        // probed = 2 (both items in the VectorStore).
        #expect(report.probed == 2)
        // candidatePairs + 0 (none settled yet) = candidatePairs.
        // written + deduplicated = candidatePairs (every candidate is either written or deduped).
        #expect(report.written + report.deduplicated == report.candidatePairs,
            "written + deduplicated must equal candidatePairs")
        // On a fresh estate with no existing associations, deduplicated must be 0.
        #expect(report.deduplicated == 0, "no prior associations on a fresh estate")
        #expect(report.written == report.candidatePairs,
            "all candidates must be written on a fresh estate")
    }

    // MARK: - Test 5 — no VectorStore registered → zero report

    /// When no VectorStore is registered for the estate, `associateSweep`
    /// must return a zero report rather than throwing.
    @Test func associateSweepWithNoVectorStoreReturnsZeroReport() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "assoc-sweep-novs")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        // No registerVectorStore call.

        let report = try await kit.associateSweep(in: handle, probeLimit: nil, now: now)

        #expect(report.probed == 0)
        #expect(report.candidatePairs == 0)
        #expect(report.written == 0)
        #expect(report.deduplicated == 0)
    }
}
