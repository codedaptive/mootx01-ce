// BitwiseArithmeticTests.swift
//
// Per-type suite for BitwiseArithmetic (intersect / difference /
// prototype) and the FingerprintBuilder interpreter. Mirrors the Rust
// `bitwise.rs` inline #[test] set: intersect_commutative,
// intersect_self_is_self, difference_self_is_zero, prototype_empty_is_zero,
// prototype_unanimous, prototype_minority_drops.

import Testing
@testable import SubstrateTypes

@Suite("BitwiseArithmetic")
struct BitwiseArithmeticTests {

    private func fp(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> Fingerprint256 {
        Fingerprint256(block0: a, block1: b, block2: c, block3: d)
    }

    @Test("intersect is commutative")
    func intersectCommutative() {
        let a = fp(0xF0F0, 0xAA, 0x55, 0xFF)
        let b = fp(0xFF, 0xF0, 0x55, 0xAA)
        #expect(BitwiseArithmetic.intersect(a, b) == BitwiseArithmetic.intersect(b, a))
    }

    @Test("intersect with self is self")
    func intersectSelfIsSelf() {
        let a = fp(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF)
        #expect(BitwiseArithmetic.intersect(a, a) == a)
    }

    @Test("intersect with zero is zero")
    func intersectZeroIsZero() {
        let a = fp(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF)
        #expect(BitwiseArithmetic.intersect(a, .zero) == .zero)
    }

    @Test("difference with self is zero")
    func differenceSelfIsZero() {
        let a = fp(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF)
        #expect(BitwiseArithmetic.difference(a, a) == .zero)
    }

    @Test("prototype of empty cohort is zero")
    func prototypeEmptyIsZero() {
        let empty: [Fingerprint256] = []
        #expect(BitwiseArithmetic.prototype(empty) == .zero)
    }

    @Test("prototype of a unanimous cohort is the shared fingerprint")
    func prototypeUnanimous() {
        let a = fp(0xFF, 0, 0, 0)
        #expect(BitwiseArithmetic.prototype([a, a, a, a, a]) == a)
    }

    @Test("prototype drops a minority bit (40% < majority)")
    func prototypeMinorityDrops() {
        let with = fp(1, 0, 0, 0)
        let without = fp(0, 0, 0, 0)
        #expect(BitwiseArithmetic.prototype([with, with, without, without, without]) == .zero)
    }

    @Test("FingerprintBuilder evaluates a composed expression")
    func builderEvaluates() {
        let a = fp(0b1100, 0, 0, 0)
        let b = fp(0b1010, 0, 0, 0)
        let expr = FingerprintBuilder.intersect(.literal(a), .literal(b))
        #expect(expr.evaluate() == BitwiseArithmetic.intersect(a, b))
        let diff = FingerprintBuilder.difference(.literal(a), .literal(b))
        #expect(diff.evaluate() == BitwiseArithmetic.difference(a, b))
    }
}
