// HyperplaneFamilyExchangeTests.swift
//
// Peer coverage for
// Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift
// (HyperplaneFamilySpec, PairingProposal, PairingAcceptance).
// Deterministic value-type / Codable behavior.

import Testing
import Foundation
import ConvergenceKitFederation

@Suite("Hyperplane family exchange")
struct HyperplaneFamilyExchangeTests {

    @Test("HyperplaneFamilySpec defaults dimension to 256")
    func specDefaultDimension() {
        let spec = HyperplaneFamilySpec(seed: 42)
        #expect(spec.seed == 42)
        #expect(spec.dimension == 256)
    }

    @Test("HyperplaneFamilySpec round-trips through Codable")
    func specCodableRoundtrip() throws {
        let spec = HyperplaneFamilySpec(seed: 0xCAFE, dimension: 128)
        let decoded = try JSONDecoder().decode(
            HyperplaneFamilySpec.self,
            from: JSONEncoder().encode(spec)
        )
        #expect(decoded == spec)
    }

    @Test("HyperplaneFamilySpec is Hashable on its fields")
    func specHashable() {
        let a = HyperplaneFamilySpec(seed: 1)
        let b = HyperplaneFamilySpec(seed: 1)
        let c = HyperplaneFamilySpec(seed: 2)
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test("PairingProposal round-trips through Codable")
    func proposalCodableRoundtrip() throws {
        let proposal = PairingProposal(
            proposerPublicKey: Data([0x01, 0x02, 0x03]),
            proposedFamily: HyperplaneFamilySpec(seed: 7),
            nonce: Data([0x09, 0x09])
        )
        let decoded = try JSONDecoder().decode(
            PairingProposal.self,
            from: JSONEncoder().encode(proposal)
        )
        #expect(decoded.proposerPublicKey == Data([0x01, 0x02, 0x03]))
        #expect(decoded.proposedFamily == HyperplaneFamilySpec(seed: 7))
        #expect(decoded.nonce == Data([0x09, 0x09]))
    }

    @Test("PairingAcceptance round-trips through Codable")
    func acceptanceCodableRoundtrip() throws {
        let acceptance = PairingAcceptance(
            accepterPublicKey: Data([0x04, 0x05]),
            acceptedFamily: HyperplaneFamilySpec(seed: 8, dimension: 64),
            signatureOfProposal: Data([0x07])
        )
        let decoded = try JSONDecoder().decode(
            PairingAcceptance.self,
            from: JSONEncoder().encode(acceptance)
        )
        #expect(decoded.accepterPublicKey == Data([0x04, 0x05]))
        #expect(decoded.acceptedFamily == HyperplaneFamilySpec(seed: 8, dimension: 64))
        #expect(decoded.signatureOfProposal == Data([0x07]))
    }
}
