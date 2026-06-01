// TierContributionFingerprintTests.swift
//
// Tier contribution fingerprint per cookbook § 12.3. swift-testing
// peer suite for Sources/SubstrateML/TierContributionFingerprint.swift.
//
// rust/src/tier_contribution.rs carries NO #[test], so this suite
// asserts the behavior set the file documents: build OR-reduces the
// cohort, the 64-byte canonical wire format round-trips through
// encode/decode, and decode rejects malformed input (wrong length,
// unknown federation case).

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("TierContributionFingerprint")
struct TierContributionFingerprintTests {

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }

    @Test("build OR-reduces the shareable fingerprints and counts the cohort")
    func buildOrReducesCohort() {
        let a = Fingerprint256(block0: 0xFF00, block1: 0, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x00FF, block1: 0x1, block2: 0, block3: 0)
        let contrib = TierContributionFingerprint.build(
            estateUUID: UUID(), case: .household,
            shareableFingerprints: [a, b], hlc: hlc(100))
        #expect(contrib.rowCount == 2)
        #expect(contrib.aggregate == a.union(b))
        #expect(contrib.aggregate.block0 == 0xFFFF)
        #expect(contrib.aggregate.block1 == 0x1)
    }

    @Test("an empty cohort yields a zero aggregate and zero count")
    func buildEmptyCohort() {
        let contrib = TierContributionFingerprint.build(
            estateUUID: UUID(), case: .fleet,
            shareableFingerprints: [], hlc: hlc(1))
        #expect(contrib.rowCount == 0)
        #expect(contrib.aggregate == Fingerprint256.zero)
    }

    @Test("encode produces exactly 64 bytes")
    func encodeIs64Bytes() {
        let contrib = TierContributionFingerprint.build(
            estateUUID: UUID(), case: .industry,
            shareableFingerprints: [Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)],
            hlc: hlc(7))
        #expect(TierContributionFingerprint.encode(contrib).count == 64)
    }

    @Test("encode/decode is a faithful round-trip")
    func encodeDecodeRoundTrip() {
        let original = TierContribution(
            estateUUID: UUID(),
            federationCase: .fleet,
            rowCount: 5,
            aggregate: Fingerprint256(block0: 0xDEAD, block1: 0xBEEF, block2: 0xCAFE, block3: 0xF00D),
            hlc: hlc(123_456))
        let wire = TierContributionFingerprint.encode(original)
        let decoded = TierContributionFingerprint.decode(wire)
        #expect(decoded == original)
    }

    @Test("decode rejects input that is not 64 bytes")
    func decodeRejectsWrongLength() {
        #expect(TierContributionFingerprint.decode(Data(repeating: 0, count: 63)) == nil)
        #expect(TierContributionFingerprint.decode(Data(repeating: 0, count: 65)) == nil)
    }

    @Test("decode rejects an unknown federation case")
    func decodeRejectsBadCase() {
        // A valid 64-byte buffer whose case field (bytes 16..19, BE)
        // is 0 — not a defined FederationCase (1/2/3).
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[16] = 0; bytes[17] = 0; bytes[18] = 0; bytes[19] = 0
        #expect(TierContributionFingerprint.decode(Data(bytes)) == nil)
    }
}
