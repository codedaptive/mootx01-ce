// FindNearestDistilledTests.swift
//
// Verifies the `findNearestDistilled` capability added by DG3:
// GLK verb-surface parity for no-inference Hamming NN on the
// distilled structural fingerprint tier.
//
// Coverage:
//  T1 — Happy path: vector filed under "distillation-features-v1"
//       is returned when the probe Engram matches.
//  T2 — Stale handle: `GeniusLocusKitError.estateNotOpen` thrown
//       after the estate is closed.
//  T3 — No VectorStore registered: `VerbError.notSupportedByEstate`
//       thrown when the estate has no VectorStore wired.
//  T4 — limit = 0: empty result, no error.

import Testing
import Foundation
import EngramLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import GeniusLocusKit

@Suite("findNearestDistilled capability")
struct FindNearestDistilledTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    /// Open one estate and return the kit and handle. The estate is opened
    /// without a VectorStore registered — each test that needs one wires it
    /// explicitly so the no-VectorStore test can share this helper.
    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-dg3-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Build a VectorStore on a fresh in-memory storage, open its schema,
    /// and return the store. The caller registers it against the kit handle.
    private func makeVectorStore() async throws -> VectorStore {
        let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: vsStorage)
    }

    // MARK: - T1: Happy path

    /// Open an estate, register a VectorStore, file one vector under
    /// "distillation-features-v1" using the zero Engram as the probe.
    /// `findNearestDistilled` with the same Engram must return the filed item.
    @Test
    func findNearestDistilledReturnsMatchingVector() async throws {
        let (kit, handle) = try await openOneEstate()
        let store = try await makeVectorStore()

        // File one binary fingerprint in the distillation lane.
        let probe = Engram.zero
        try await store.addVector(
            itemID: "distilled-item-1",
            engram: probe,
            modelID: "distillation-features-v1",
            modelVersion: "1.0",
            filedAt: t0)

        // Register the store so the verb surface can resolve it by handle.
        await kit.registerVectorStore(store, for: handle)

        let results = try await kit.findNearestDistilled(handle, engram: probe, limit: 5)

        #expect(!results.isEmpty,
            "findNearestDistilled must return the filed vector for a matching probe")
        #expect(results[0].itemID == "distilled-item-1",
            "nearest result must be the item whose Engram matches the probe (Hamming 0)")
    }

    // MARK: - T2: Stale handle

    /// After `close`, the handle is stale. `findNearestDistilled` must throw
    /// `GeniusLocusKitError.estateNotOpen` — same contract as every other verb
    /// surface method.
    @Test
    func findNearestDistilledOnStaleHandleThrowsEstateNotOpen() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.close(handle)

        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.findNearestDistilled(
                handle,
                engram: Engram.zero,
                limit: 1)
        }
        if case .estateNotOpen? = thrown {} else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }

    // MARK: - T3: No VectorStore registered

    /// An estate that was opened without a VectorStore registered raises
    /// `VerbError.notSupportedByEstate`. The distillation tier requires a
    /// VectorStore; a missing store is a typed error, not an empty result.
    @Test
    func findNearestDistilledWithoutVectorStoreThrowsNotSupported() async throws {
        let (kit, handle) = try await openOneEstate()
        // Deliberately do NOT register a VectorStore.

        let thrown = await #expect(throws: VerbError.self) {
            try await kit.findNearestDistilled(
                handle,
                engram: Engram.zero,
                limit: 1)
        }
        if case .notSupportedByEstate(let verb)? = thrown {
            #expect(verb == "findNearestDistilled",
                "verb label must be 'findNearestDistilled'")
        } else {
            Issue.record("expected .notSupportedByEstate, got \(String(describing: thrown))")
        }
    }

    // MARK: - T4: limit = 0

    /// `limit: 0` returns an empty array without error. VectorStore guards
    /// `k > 0` internally and returns `[]` immediately, so the verb surface
    /// must not treat zero as an error condition.
    @Test
    func findNearestDistilledWithLimitZeroReturnsEmpty() async throws {
        let (kit, handle) = try await openOneEstate()
        let store = try await makeVectorStore()

        try await store.addVector(
            itemID: "distilled-item-limit0",
            engram: Engram.zero,
            modelID: "distillation-features-v1",
            modelVersion: "1.0",
            filedAt: t0)

        await kit.registerVectorStore(store, for: handle)

        let results = try await kit.findNearestDistilled(handle, engram: Engram.zero, limit: 0)
        #expect(results.isEmpty, "limit: 0 must return an empty array without error")
    }
}
