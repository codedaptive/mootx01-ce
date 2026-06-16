// HyperplaneFamilyExchange.swift
//
// Pairing handshake per paper section 9.2. Two estates negotiate
// a shared hyperplane family so their 256-bit fingerprints are
// directly comparable across the federation.
//
// For v1.0 the handshake exchanges the family parameters
// (seed + dimension) signed by each peer's Ed25519 key.

import Foundation
import SubstrateTypes
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

public struct HyperplaneFamilySpec: Sendable, Codable, Hashable {
    /// Deterministic seed used by HyperplaneFamily(seed:) to
    /// reproduce the family on both sides.
    public let seed: UInt64

    /// Dimensionality of the hyperplane family (typically 256 for
    /// the four-block fingerprint).
    public let dimension: Int

    public init(seed: UInt64, dimension: Int = 256) {
        self.seed = seed
        self.dimension = dimension
    }
}

public struct PairingProposal: Sendable, Codable {
    public let proposerPublicKey: Data
    public let proposedFamily: HyperplaneFamilySpec
    public let nonce: Data

    public init(proposerPublicKey: Data, proposedFamily: HyperplaneFamilySpec, nonce: Data) {
        self.proposerPublicKey = proposerPublicKey
        self.proposedFamily = proposedFamily
        self.nonce = nonce
    }
}

public struct PairingAcceptance: Sendable, Codable {
    public let accepterPublicKey: Data
    public let acceptedFamily: HyperplaneFamilySpec
    public let signatureOfProposal: Data

    public init(accepterPublicKey: Data, acceptedFamily: HyperplaneFamilySpec, signatureOfProposal: Data) {
        self.accepterPublicKey = accepterPublicKey
        self.acceptedFamily = acceptedFamily
        self.signatureOfProposal = signatureOfProposal
    }
}
