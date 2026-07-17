// HyperplaneFamilyExchange.swift
//
// Codable value types for the pairing handshake (paper section 9.2).
// Two estates share a hyperplane family so their 256-bit fingerprints
// are directly comparable across the federation.
//
// This file defines the proposal/acceptance types only. The current
// FederationSyncEngine.pair path receives a HyperplaneFamilySpec from
// the caller and stores it in memory; it does not sign or negotiate
// these proposal/acceptance structs.

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

/// Canonical byte encoding of a `PairingProposal` for signing and verification.
///
/// Layout (all integers little-endian):
///   proposerPublicKey  (32 bytes, Ed25519 pubkey raw)
///   proposedFamily.seed       (8 bytes: LE u64)
///   proposedFamily.dimension  (4 bytes: LE u32)
///   nonce              (variable)
///
/// This encoding is byte-identical to the Rust `proposal_signing_bytes` in
/// `pairing.rs`. Both sides MUST produce the same bytes; byte widths and
/// field ordering are fixed here for cross-port verification.
///
/// Note: `HyperplaneFamilySpec.dimension` is `Int` in Swift; it is truncated
/// to `UInt32` (LE 4 bytes) to match the Rust `u32` encoding.
public func proposalSigningBytes(_ proposal: PairingProposal) -> Data {
    var bytes = Data()
    bytes.reserveCapacity(
        proposal.proposerPublicKey.count + 8 + 4 + proposal.nonce.count
    )
    // 32-byte Ed25519 proposer public key
    bytes.append(contentsOf: proposal.proposerPublicKey)
    // 8-byte LE u64 hyperplane family seed
    var seed = proposal.proposedFamily.seed.littleEndian
    withUnsafeBytes(of: &seed) { bytes.append(contentsOf: $0) }
    // 4-byte LE u32 dimension (Int truncated to UInt32 for wire format)
    var dim = UInt32(proposal.proposedFamily.dimension).littleEndian
    withUnsafeBytes(of: &dim) { bytes.append(contentsOf: $0) }
    // nonce bytes (16 bytes in the standard handshake)
    bytes.append(contentsOf: proposal.nonce)
    return bytes
}
