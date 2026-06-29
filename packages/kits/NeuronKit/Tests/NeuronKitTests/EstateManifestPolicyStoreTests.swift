// EstateManifestPolicyStoreTests.swift
//
// F6 / ADR-020: the manifest-backed policy stores persist dreaming/maintenance
// policy, bandit, and daemon cycle state THROUGH the public substrate interface
// (GeniusLocusKit.estate(for:) → Estate.meta/setMeta). These tests prove the
// round-trip through a live estate. Cross-restart durability of the underlying
// manifest table is proven separately by LocusKit's EstateTests reopen test.

import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import NeuronKit

@Suite("EstateManifestPolicyStore — manifest-backed daemon persistence")
struct EstateManifestPolicyStoreTests {

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "manifest-store-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    // MARK: - Dreaming

    @Test("Dreaming policy round-trips through the estate manifest")
    func dreamingPolicyRoundTrip() async throws {
        let (kit, handle) = try await makeKit()
        let store = EstateManifestDreamingPolicyStore(handle: handle, kit: kit)

        // Absent before first save.
        #expect(try await store.loadPolicy() == nil)

        let policy = DreamingPolicy(
            minSuccessRate: 0.55, minConfidence: 0.8, minAttempts: 5,
            tickIntervalMs: 45_000, eventObservationThreshold: 2)
        try await store.savePolicy(policy)
        #expect(try await store.loadPolicy() == policy)
    }

    @Test("Dreaming bandit round-trips through the estate manifest")
    func dreamingBanditRoundTrip() async throws {
        let (kit, handle) = try await makeKit()
        let store = EstateManifestDreamingPolicyStore(handle: handle, kit: kit)

        #expect(try await store.loadBandit() == nil)

        var bandit = SolverBandit()
        bandit.observe(arm: .timer, reward: 1.0)
        bandit.observe(arm: .event, reward: 0.0)
        try await store.saveBandit(bandit)
        #expect(try await store.loadBandit() == bandit)
    }

    @Test("Dreaming daemon state round-trips through the estate manifest")
    func dreamingDaemonStateRoundTrip() async throws {
        let (kit, handle) = try await makeKit()
        let store = EstateManifestDreamingPolicyStore(handle: handle, kit: kit)

        #expect(try await store.loadDaemonState() == nil)

        let state = DreamingDaemonState(
            lastTickAt: Date(timeIntervalSince1970: 1_700_000_000),
            proposedKeys: ["a|b", "c|d"],
            lastReindexVocab: 1_234,
            consolidated: ["a|b": 0.88, "c|d": 0.42],
            cycleCount: 7)
        try await store.saveDaemonState(state)
        #expect(try await store.loadDaemonState() == state)
    }

    // MARK: - Maintenance

    @Test("Maintenance policy round-trips through the estate manifest")
    func maintenancePolicyRoundTrip() async throws {
        let (kit, handle) = try await makeKit()
        let store = EstateManifestMaintenancePolicyStore(handle: handle, kit: kit)

        #expect(try await store.loadPolicy() == nil)

        let policy = MaintenancePolicy()
        try await store.savePolicy(policy)
        #expect(try await store.loadPolicy() == policy)
    }

    @Test("Maintenance daemon state round-trips through the estate manifest")
    func maintenanceDaemonStateRoundTrip() async throws {
        let (kit, handle) = try await makeKit()
        let store = EstateManifestMaintenancePolicyStore(handle: handle, kit: kit)

        #expect(try await store.loadDaemonState() == nil)

        let state = MaintenanceDaemonState(
            lastTickAt: Date(timeIntervalSince1970: 1_700_000_500),
            lastAuditCheckAt: Date(timeIntervalSince1970: 1_700_000_400),
            proposedKeys: ["decay:room-1", "tombstone:row-9"],
            cycleCount: 3)
        try await store.saveDaemonState(state)
        #expect(try await store.loadDaemonState() == state)
    }
}
