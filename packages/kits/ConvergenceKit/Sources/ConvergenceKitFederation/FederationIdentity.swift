// FederationIdentity.swift
//
// Per-estate Ed25519 keypair. Generated on first call to
// `establish`. Persisted in the PersistenceKit estate's audit-log
// metadata (a small blob row) so it survives restarts.

import Foundation
import SubstrateTypes
import Crypto
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import PersistenceKit

public struct PeerIdentity: Sendable, Hashable {
    public let publicKey: Data  // 32 bytes Ed25519

    public init(publicKey: Data) {
        self.publicKey = publicKey
    }
}

public struct LocalIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Data

    public init() {
        let key = Curve25519.Signing.PrivateKey()
        self.privateKey = key
        self.publicKey = key.publicKey.rawRepresentation
    }

    public init(privateKeyBytes: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        self.privateKey = key
        self.publicKey = key.publicKey.rawRepresentation
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

public enum FederationSignature {
    public static func verify(_ signature: Data, of data: Data, by peerPublicKey: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: peerPublicKey) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: data)
    }
}
