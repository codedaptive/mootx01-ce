// FederationIdentityTests.swift
//
// Peer coverage for Sources/ConvergenceKitFederation/FederationIdentity.swift
// (LocalIdentity, PeerIdentity, FederationSignature) and the persistence
// behaviour added by WC1 (loadOrMintIdentity in FederationStateActor).

import Testing
import Foundation
import Crypto
import ConvergenceKit
import ConvergenceKitFederation
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation identity")
struct FederationIdentityTests {

    @Test("a signature from a local identity verifies under its own public key")
    func signVerifyRoundtrip() throws {
        let identity = LocalIdentity()
        let data = Data("a federated payload".utf8)
        let signature = try identity.sign(data)
        #expect(FederationSignature.verify(signature, of: data, by: identity.publicKey))
    }

    @Test("verification fails when the payload is tampered")
    func verifyRejectsTamperedPayload() throws {
        let identity = LocalIdentity()
        let data = Data("a federated payload".utf8)
        let signature = try identity.sign(data)
        let tampered = Data("a federated payloaX".utf8)
        #expect(FederationSignature.verify(signature, of: tampered, by: identity.publicKey) == false)
    }

    @Test("verification fails under a different peer's public key")
    func verifyRejectsWrongKey() throws {
        let signer = LocalIdentity()
        let other = LocalIdentity()
        let data = Data("a federated payload".utf8)
        let signature = try signer.sign(data)
        #expect(FederationSignature.verify(signature, of: data, by: other.publicKey) == false)
    }

    @Test("verification returns false for a malformed public key")
    func verifyRejectsMalformedKey() {
        let data = Data("a federated payload".utf8)
        #expect(FederationSignature.verify(Data([0x00, 0x01]), of: data, by: Data([0x00, 0x01])) == false)
    }

    @Test("an identity restored from private-key bytes reproduces the same public key")
    func restoreFromPrivateKeyBytes() throws {
        let identity = LocalIdentity()
        let bytes = identity.privateKey.rawRepresentation
        let restored = try LocalIdentity(privateKeyBytes: bytes)
        #expect(restored.publicKey == identity.publicKey)

        // A signature from the restored key verifies under the original
        // public key — proof the keypair is genuinely the same.
        let data = Data("round-trip".utf8)
        let signature = try restored.sign(data)
        #expect(FederationSignature.verify(signature, of: data, by: identity.publicKey))
    }

    @Test("PeerIdentity is Equatable and Hashable on its public key")
    func peerIdentityEquality() {
        let key = Data([0x01, 0x02, 0x03])
        let a = PeerIdentity(publicKey: key)
        let b = PeerIdentity(publicKey: key)
        let c = PeerIdentity(publicKey: Data([0x09]))
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}

// MARK: - Identity persistence tests (WC1)

/// Tests for loadOrMintIdentity — the _fed_identity side-table persistence added
/// in WC1. These tests drive enable() with real InMemoryStorage so the full
/// ensureFedSyncMetaTable + loadOrMintIdentity path is exercised.
private func makeFedStorage() async throws -> InMemoryStorage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    let schema = SchemaDeclaration(
        kitID: "IdTestKit",
        version: 1,
        tables: [
            TableDeclaration(name: "items", columns: [.uuid("id")], primaryKey: ["id"])
        ]
    )
    try await storage.open(schema: schema)
    return storage
}

private func makeFedManifest() -> SyncManifest {
    SyncManifest(
        kitID: "IdTestKit",
        schemaVersion: 1,
        zoneIdentifier: "zone-id-test",
        tables: [SyncedTable(name: "items", primaryKeyColumn: "id")]
    )
}

@Suite("Federation identity persistence (WC1)")
struct FederationIdentityPersistenceTests {

    @Test("identity survives disable/re-enable against the same estate storage")
    func identityPersistsAcrossReEnable() async throws {
        let storage = try await makeFedStorage()
        let manifest = makeFedManifest()

        // First engine: enable mints and persists the identity.
        let engine1 = FederationSyncEngine()
        try await engine1.enable(manifest: manifest, storage: storage)
        let pubKey1 = await engine1.identity.publicKey
        try await engine1.disable()

        // Second engine: enable against the same storage must reload the same identity.
        let engine2 = FederationSyncEngine()
        try await engine2.enable(manifest: manifest, storage: storage)
        let pubKey2 = await engine2.identity.publicKey
        try await engine2.disable()

        #expect(
            pubKey1 == pubKey2,
            "public key must be identical after re-enable against the same estate storage (I-8)"
        )
    }

    @Test("restored identity signs data verifiable under the original public key")
    func restoredIdentitySignsCorrectly() async throws {
        let storage = try await makeFedStorage()
        let manifest = makeFedManifest()

        let engine1 = FederationSyncEngine()
        try await engine1.enable(manifest: manifest, storage: storage)
        let pubKey1 = await engine1.identity.publicKey
        try await engine1.disable()

        // Restore from same storage and sign fresh data.
        let engine2 = FederationSyncEngine()
        try await engine2.enable(manifest: manifest, storage: storage)
        let identity2 = await engine2.identity
        let payload = Data("federation payload".utf8)
        let signature = try identity2.sign(payload)
        try await engine2.disable()

        // Signature from the restored identity must verify under the original public key.
        #expect(
            FederationSignature.verify(signature, of: payload, by: pubKey1),
            "signature from reloaded identity must verify under the original public key"
        )
    }

    @Test("distinct estate storages receive distinct identities")
    func distinctEstatesGetDistinctIdentities() async throws {
        let storage1 = try await makeFedStorage()
        let storage2 = try await makeFedStorage()
        let manifest = makeFedManifest()

        let engine1 = FederationSyncEngine()
        try await engine1.enable(manifest: manifest, storage: storage1)
        let pubKey1 = await engine1.identity.publicKey
        try await engine1.disable()

        let engine2 = FederationSyncEngine()
        try await engine2.enable(manifest: manifest, storage: storage2)
        let pubKey2 = await engine2.identity.publicKey
        try await engine2.disable()

        // Two distinct estates must not share the same keypair.
        #expect(
            pubKey1 != pubKey2,
            "distinct estate storages must produce distinct Ed25519 identities"
        )
    }
}
