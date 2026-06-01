// FederationIdentityTests.swift
//
// Peer coverage for Sources/ConvergenceKitFederation/FederationIdentity.swift
// (LocalIdentity, PeerIdentity, FederationSignature). Deterministic
// Ed25519 sign/verify — no platform or network dependency.

import Testing
import Foundation
import Crypto
import ConvergenceKitFederation

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
