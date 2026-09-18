// JaccardTests.swift
//
// Cross-port golden pins for the Jaccard unlock (W2.5 Track M1). Literal
// twins of rust jaccard.rs tests.

import Testing
@testable import SubstrateTypes

struct JaccardTests {
    private func fp(_ b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64) -> Fingerprint256 {
        Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }

    @Test("golden pins: identity, disjoint, empty-union, thirds")
    func pins() {
        let a = fp(0b1011, 0, 0, .max)
        #expect(Jaccard.similarity(a, a) == 1.0)
        #expect(Jaccard.similarity(fp(0b1011, 0, 0, 0), fp(0b0100, 0, 1, 0)) == 0.0)
        #expect(Jaccard.similarity(fp(0, 0, 0, 0), fp(0, 0, 0, 0)) == 0.0)
        let x = fp(0b011, 0, 0, 0)
        let y = fp(0b110, 0, 0, 0)
        #expect(Jaccard.similarity(x, y) == 1.0 / 3.0)
        #expect(Jaccard.distance(x, y) == 1.0 - 1.0 / 3.0)
    }
}
