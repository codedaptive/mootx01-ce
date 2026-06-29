import Foundation
import CryptoKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import LocusKit

/// Tests for the Ed25519 Keychain migration (secfix/ed25519-keychain, ADR-007).
///
/// Verifies three properties:
///
/// 1. After `Estate.open`, the `ed25519_private_key_wrapped` row is absent
///    from `estate_meta` — the private key must not be stored in the manifest.
///
/// 2. The private key IS retrievable via `Estate.retrievePrivateSigningKeyData()`
///    (the in-memory cache loaded from the injected identity key store).
///
/// 3. The public key IS present in the manifest and is the matching public key
///    for the private key in the store — so signatures produced with the private
///    key verify against the manifest's public key.
///
/// All tests use `InMemoryEstateIdentityKeyStore` to avoid Keychain entitlement
/// requirements and cross-test Keychain pollution. `InMemoryEstateIdentityKeyStore`
/// exercises the same code path as `KeychainEstateIdentityKeyStore` because
/// `Estate.open` is parameterised on the `EstateIdentityKeyStore` protocol.
@Suite("EstateIdentityKeyStoreTests")
struct EstateIdentityKeyStoreTests {

    // MARK: - Helpers

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-keychain")

    // MARK: - 1. Private key absent from estate_meta after open

    /// After the Keychain migration, `Estate.open` must not write the private
    /// signing key to the manifest. Any value in `ed25519_private_key_wrapped`
    /// is plaintext-visible to database and backup readers — storing it there
    /// is the security posture the migration is designed to eliminate.
    @Test("Estate.open does not persist the private key in estate_meta")
    func openDoesNotPersistPrivateKeyInMeta() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        _ = try await Estate.create(storage: storage, owner: testOwner)
        let estate = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await estate.close() } }

        // Read the manifest directly and assert the private key row is absent.
        let manifest = try await estate.manifest
        #expect(
            manifest.ed25519PrivateKeyWrapped == nil,
            "ed25519_private_key_wrapped must not be present in the manifest after Keychain migration"
        )
    }

    // MARK: - 2. Private key present in the identity key store after open

    /// The private key must be stored in the injected key store (not in
    /// `estate_meta`) so grant signing works. The in-memory store is
    /// inspectable after the estate is opened, letting us verify that the
    /// key was stored in the right place.
    @Test("Estate.open stores the private key in the identity key store")
    func openStoresPrivateKeyInKeyStore() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        _ = try await Estate.create(storage: storage, owner: testOwner)
        let estate = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        let estateID = await estate.estateUUID
        defer { Task { try? await estate.close() } }

        // The key store should contain the private key for this estate UUID.
        let storedKey = keyStore._storedPrivateKey(forEstateID: estateID)
        #expect(storedKey != nil, "private key must be present in the key store after open")
        #expect(storedKey?.count == 32, "Curve25519 private key is always 32 bytes")
    }

    // MARK: - 3. retrievePrivateSigningKeyData returns the private key

    /// `Estate.retrievePrivateSigningKeyData()` returns the in-memory cache
    /// populated at open time. The returned bytes are the raw 32-byte
    /// Curve25519 private key that matches the public key in the manifest.
    @Test("Estate.retrievePrivateSigningKeyData returns 32 bytes after open")
    func retrievePrivateSigningKeyDataReturns32Bytes() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        _ = try await Estate.create(storage: storage, owner: testOwner)
        let estate = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await estate.close() } }

        let raw = await estate.retrievePrivateSigningKeyData()
        #expect(raw != nil, "private signing key must be available in memory after open")
        #expect(raw?.count == 32, "Curve25519 private key is always 32 bytes")
    }

    // MARK: - 4. Public key in manifest matches the stored private key

    /// The public key in the manifest is the Ed25519 verifying key for the
    /// private key in the store. A signature over arbitrary data produced with
    /// the private key must verify against the manifest's public key.
    @Test("Ed25519 public key in manifest matches the private key in the key store")
    func publicKeyMatchesPrivateKey() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        _ = try await Estate.create(storage: storage, owner: testOwner)
        let estate = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await estate.close() } }

        // Retrieve the private key bytes and reconstruct the CryptoKit key.
        let rawPrivate = try #require(await estate.retrievePrivateSigningKeyData())
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivate)

        // Read the public key from the manifest.
        let manifest = try await estate.manifest
        let rawPublic = try #require(manifest.ed25519PublicKey)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublic)

        // Sign arbitrary data and verify against the manifest public key.
        let testPayload = Data("secfix-ed25519-keychain-test".utf8)
        let signature = try privateKey.signature(for: testPayload)
        #expect(
            publicKey.isValidSignature(signature, for: testPayload),
            "a signature produced with the in-store private key must verify against the manifest's public key"
        )
    }

    // MARK: - 5. Key stability across reopen

    /// Re-opening an estate that already has an `ed25519_public_key` in its
    /// manifest does NOT regenerate the keypair. The same public key is present
    /// on the second open, and the key store retains the original private key.
    @Test("Re-opening an estate does not regenerate the Ed25519 keypair")
    func reopenDoesNotRegenerateKeypair() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        // First open: generates the keypair.
        _ = try await Estate.create(storage: storage, owner: testOwner)
        let first = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        let pubKeyFirst = try await first.manifest.ed25519PublicKey
        let rawFirst = await first.retrievePrivateSigningKeyData()
        try await first.close()

        // Second open: loads from the key store; must NOT regenerate.
        let second = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await second.close() } }

        let pubKeySecond = try await second.manifest.ed25519PublicKey
        let rawSecond = await second.retrievePrivateSigningKeyData()

        #expect(pubKeyFirst == pubKeySecond, "public key must be stable across reopens")
        #expect(rawFirst == rawSecond, "private key bytes must be stable across reopens")
        #expect(
            try await second.manifest.ed25519PrivateKeyWrapped == nil,
            "ed25519_private_key_wrapped must remain absent across reopens"
        )
    }

    // MARK: - 6. retrievePrivateSigningKeyData is nil when key store has no key

    /// When an estate is opened with an `InMemoryEstateIdentityKeyStore` that
    /// does not contain the private key for the estate UUID (e.g. a fresh store
    /// instance on a subsequent open), `retrievePrivateSigningKeyData()` returns
    /// nil. The estate opens successfully; signing fails at the call site.
    @Test("retrievePrivateSigningKeyData is nil when key store does not contain the key")
    func retrieveReturnsNilWhenKeyStoreEmpty() async throws {
        let storage = makeStorage()
        let firstKeyStore = InMemoryEstateIdentityKeyStore()

        // First open: generates the keypair, stores in firstKeyStore.
        _ = try await Estate.create(storage: storage, owner: testOwner)
        let first = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: firstKeyStore
        )
        try await first.close()

        // Second open: uses a fresh (empty) key store — simulates a Keychain
        // wipe or a key store that was not seeded.
        let emptyStore = InMemoryEstateIdentityKeyStore()
        let second = try await Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: emptyStore
        )
        defer { Task { try? await second.close() } }

        let raw = await second.retrievePrivateSigningKeyData()
        #expect(raw == nil, "private key must be nil when the key store does not contain it")
    }
}
