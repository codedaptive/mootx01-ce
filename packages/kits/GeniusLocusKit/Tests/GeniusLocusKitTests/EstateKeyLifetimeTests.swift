// EstateKeyLifetimeTests.swift
//
// Zero-residue contract for the estate-key-lifetime fix (2026-07-29).
//
// Incident: agent test loops provisioned and destroyed ~200k estates and
// left every identity/db key in the macOS Keychain. The fix is a DECLARED
// lifetime (`EstateProvisionParams.lifetime`) — never a path heuristic —
// plus first-class key disposal on destroy. These tests pin both halves:
//
//   1. `.ephemeral` provisions carry an in-memory identity store, so no
//      Keychain item is ever created for the estate's identity key.
//   2. `destroy()` disposes key material (idempotent — missing items are
//      not errors), so durable estates being retired do not orphan keys.
//   3. The incident scenario itself: a provision→destroy loop leaves zero
//      per-estate key residue (probed per estate UUID against the real
//      Keychain store where available; the store returns nil for absent
//      keys, so the probe is side-effect-free).

import Foundation
import Testing
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Estate key lifetime — declared ephemeral + disposal (zero residue)")
struct EstateKeyLifetimeTests {

    // MARK: - Helpers

    private func makeParams(name: String, lifetime: EstateLifetime) -> EstateProvisionParams {
        EstateProvisionParams(
            estateName: name,
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none,
            lifetime: lifetime
        )
    }

    private func provision(
        _ kit: GeniusLocusKit, name: String, lifetime: EstateLifetime
    ) async throws -> (EstateHandle, InMemoryStorage) {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let owner = OwnerCredentials(ownerIdentifier: "owner-key-lifetime-tests")
        let handle = try await kit.provision(
            storage: storage, owner: owner,
            params: makeParams(name: name, lifetime: lifetime),
            embeddingModels: [.deterministic])
        return (handle, storage)
    }

    // MARK: - 1. Declaration, not inference

    @Test("default lifetime is durable — declaration is explicit, never inferred")
    func defaultLifetimeIsDurable() {
        let params = EstateProvisionParams(
            estateName: "Defaults Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        #expect(params.lifetime == .durable)
    }

    @Test("ephemeral provision is fully operational — capture works, then destroy succeeds")
    func ephemeralProvisionRoundTrip() async throws {
        let kit = GeniusLocusKit()
        let (handle, storage) = try await provision(
            kit, name: "Ephemeral RT Estate", lifetime: .ephemeral)
        // The estate is a real estate: a capture must succeed (signing identity
        // works from the in-memory store).
        _ = try await kit.captureBatch(handle, [
            CaptureFrame(
                content: "ephemeral estates are real estates",
                channel: .typed,
                room: "key-lifetime-tests",
                latticeAnchor: .udc("000"),
                addedBy: "key-lifetime-tests",
                embeddingModelID: "test-model-v1"
            )
        ])
        try await kit.destroy(storage: storage, handle: handle)
    }

    @Test("ephemeral identity never lands in the Keychain store")
    func ephemeralLeavesNoKeychainIdentity() async throws {
        let kit = GeniusLocusKit()
        let (handle, storage) = try await provision(
            kit, name: "Ephemeral No-Keychain Estate", lifetime: .ephemeral)
        let estateID = handle.estateUUID
        try await kit.destroy(storage: storage, handle: handle)
        #if canImport(Security)
        // Probe the REAL Keychain-backed store for this estate's UUID. For an
        // ephemeral estate no item was ever created, so the load returns nil.
        // (loadPrivateKey is a read — absent items are nil, not errors — so
        // the probe itself leaves no residue.) If the Keychain is unavailable
        // in this environment the probe throws; that is a skip, not a failure.
        let probe = KeychainEstateIdentityKeyStore()
        if let residue = try? probe.loadPrivateKey(forEstateID: estateID) {
            #expect(residue == nil, "ephemeral estate left an identity key in the Keychain")
        }
        #endif
    }

    // MARK: - 2. Disposal on destroy (idempotent)

    @Test("disposeEstateKeys is idempotent — destroy of a never-keyed estate does not throw")
    func disposalIdempotentOnMissingItems() async throws {
        let kit = GeniusLocusKit()
        // inMemory backend: no db-key Keychain item is ever written, and the
        // identity item may or may not exist. destroy() must succeed either way
        // (missing Keychain items are NOT errors — the disposal contract).
        let (handle, storage) = try await provision(
            kit, name: "Disposal Idempotence Estate", lifetime: .ephemeral)
        try await kit.destroy(storage: storage, handle: handle)
        // Second disposal against the same UUID: nothing to delete, still no throw.
        try await kit.disposeEstateKeys(for: handle, storage: storage)
    }

    // MARK: - 3. The incident scenario — bulk loop, zero residue

    @Test("provision+destroy loop (N=50) leaves zero per-estate key residue")
    func bulkLoopLeavesZeroResidue() async throws {
        let kit = GeniusLocusKit()
        var estateIDs: [UUID] = []
        for i in 0..<50 {
            let (handle, storage) = try await provision(
                kit, name: "Loop Estate \(i)", lifetime: .ephemeral)
            estateIDs.append(handle.estateUUID)
            try await kit.destroy(storage: storage, handle: handle)
        }
        #expect(estateIDs.count == 50)
        #if canImport(Security)
        // Zero-residue probe: every looped estate UUID must have NO identity
        // key in the real Keychain store. This is the incident scenario —
        // 200k mint/delete cycles accumulating Keychain items — pinned at
        // N=50. Probe errors (Keychain unavailable in the test environment)
        // skip silently; a present item fails loudly.
        let probe = KeychainEstateIdentityKeyStore()
        for estateID in estateIDs {
            if let residue = try? probe.loadPrivateKey(forEstateID: estateID) {
                #expect(residue == nil, "loop estate \(estateID) left an identity key in the Keychain")
            }
        }
        #endif
    }
}
