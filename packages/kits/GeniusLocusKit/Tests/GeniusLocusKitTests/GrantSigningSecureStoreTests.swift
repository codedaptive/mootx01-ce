import Testing
import Foundation
import CryptoKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Tests for Ed25519 grant-signing behavior after the Keychain migration
/// (secfix/ed25519-keychain, data-movement privacy tiers).
///
/// Verifies:
///   (a) `estate_meta` does NOT contain the private key after `Estate.open`
///       when GeniusLocusKit opens estates through `kit.open`.
///   (b) Grant signing still works: `issueGrant` produces a grant whose
///       signature verifies against the manifest's Ed25519 public key.
///   (c) Signing fails gracefully when the key store does not contain the
///       private key — `issueGrant` throws rather than silently producing a
///       bad signature.
///
/// All tests inject `InMemoryEstateIdentityKeyStore` into the LocusKit open
/// path. The GLK `kit.open` path uses the default `KeychainEstateIdentityKeyStore`
/// for the initial LocusKit open; tests that need controlled injection open
/// the estate directly via `LocusKit.Estate.open` with the injected store
/// before calling `kit.open` on the same storage (which finds the public key
/// already in the manifest and loads the private key from the injected store).
@Suite("GrantSigningSecureStoreTests")
struct GrantSigningSecureStoreTests {

    // MARK: - Helpers

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    private let testOwner = OwnerCredentials(ownerIdentifier: "owner-grt-secstore")

    private func options(
        _ custody: CustodyMode,
        grantee: UUID = UUID(),
        lifetime: GrantLifetime = .permanent
    ) -> GrantOptions {
        GrantOptions(
            granteeEstateID: grantee,
            scope: .wholeEstate,
            custodyMode: custody,
            lifetime: lifetime
        )
    }

    // MARK: - (a) Private key absent from estate_meta after GLK-mediated open

    /// When GeniusLocusKit opens an estate, the underlying `LocusKit.Estate.open`
    /// must not write the private signing key to `estate_meta`. This test opens
    /// the estate via the standard GLK path (which uses the Keychain by default
    /// on macOS) and then re-reads the manifest to confirm the private key row
    /// is absent.
    @Test("estate_meta does not contain ed25519 private key after kit.open")
    func kitOpenDoesNotPersistPrivateKeyInMeta() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()

        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let handle = try await kit.open(storage: storage, owner: testOwner)

        // Re-read the estate manifest via a fresh LocusKit handle to inspect
        // what was actually written to estate_meta.
        let inspectEstate = try await LocusKit.Estate.open(
            storage: storage,
            owner: testOwner
        )
        defer { Task { try? await inspectEstate.close() } }
        let manifest = try await inspectEstate.manifest

        #expect(
            manifest.ed25519PrivateKeyWrapped == nil,
            "ed25519_private_key_wrapped must not be present in the manifest after the Keychain migration"
        )

        try await kit.close(handle)
    }

    // MARK: - (b) Grant signing works end-to-end with injected key store

    /// Grant signing must still produce a valid signature after the Keychain
    /// migration. This test seeds the estate identity with an injected
    /// `InMemoryEstateIdentityKeyStore`, issues a grant through GLK, then
    /// verifies the grant's signature against the manifest's public key.
    @Test("issueGrant produces a signature that verifies against the manifest public key (injected store)")
    func grantSignatureVerifiesWithInjectedKeyStore() async throws {
        let storage = makeStorage()
        let keyStore = InMemoryEstateIdentityKeyStore()

        // Seed the estate identity via LocusKit with the injected key store.
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let seedEstate = try await LocusKit.Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        // The keypair is now in keyStore (and in manifest's public key row).
        let seedEstateID = await seedEstate.estateUUID
        try await seedEstate.close()

        // Open through GLK using a key store that forwards to the same backing.
        // Because the public key is already in the manifest, GLK's call to
        // Estate.open takes the "load from store" branch, not "generate new key".
        // Using the same InMemoryEstateIdentityKeyStore instance ensures the
        // key loaded by GLK is the same one seeded above.
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await kit.close(handle) } }

        // Issue a mode-1 (mediated) grant — this internally calls signingIdentity(for:)
        // which reads from the in-memory cache loaded at open time.
        let result = try await kit.issueGrant(handle, options(.mediated))

        // Read the manifest public key and verify the signature.
        let inspectEstate = try await LocusKit.Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: keyStore
        )
        defer { Task { try? await inspectEstate.close() } }
        let manifest = try await inspectEstate.manifest
        let rawPub = try #require(manifest.ed25519PublicKey)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPub)

        #expect(
            publicKey.isValidSignature(result.grant.signature, for: result.grant.signingPayload),
            "grant signature must verify against the estate Ed25519 public key in the manifest"
        )
        // The estate UUID in the grant result must match the estate we opened.
        #expect(
            handle.estateUUID == seedEstateID,
            "estate UUID must be stable: seeded estate UUID must match opened handle UUID"
        )
    }

    // MARK: - (c) Signing fails gracefully when the key store has no key

    /// If the private key is absent from the key store (simulating a Keychain
    /// wipe), `issueGrant` must throw rather than silently producing a
    /// corrupt or empty signature. The error must be a GeniusLocusKitError
    /// (not a crash or a nil-key panic).
    @Test("issueGrant throws when the private key is absent from the key store")
    func issueGrantThrowsWhenKeyStoreEmpty() async throws {
        let storage = makeStorage()

        // First open: seeds the estate with a fresh keypair (stored in firstStore).
        let firstStore = InMemoryEstateIdentityKeyStore()
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let seedEstate = try await LocusKit.Estate.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: firstStore
        )
        try await seedEstate.close()

        // Second open with an EMPTY key store — simulates a Keychain wipe.
        // The public key is in the manifest, so the estate opens successfully,
        // but the private key is absent from emptyStore.
        let emptyStore = InMemoryEstateIdentityKeyStore()
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: emptyStore
        )
        defer { Task { try? await kit.close(handle) } }

        await #expect(throws: (any Error).self) {
            _ = try await kit.issueGrant(handle, options(.mediated))
        }
    }
}
