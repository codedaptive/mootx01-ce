// ORReduceTests.swift
//
// Per-type suite for ORReduce. Mirrors the Rust `or_reduce.rs` inline
// #[test] set: empty_reduces_to_zero, commutative, associative,
// idempotent. Adds the block-restricted reduce overload (Swift surface).

import Testing
@testable import SubstrateTypes

@Suite("ORReduce")
struct ORReduceTests {

    private func fp(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> Fingerprint256 {
        Fingerprint256(block0: a, block1: b, block2: c, block3: d)
    }

    @Test("empty reduces to zero (the identity)")
    func emptyReducesToZero() {
        let empty: [Fingerprint256] = []
        #expect(ORReduce.reduce(empty) == .zero)
    }

    @Test("OR-reduce is commutative")
    func commutative() {
        let a = fp(0x1, 0x2, 0x4, 0x8)
        let b = fp(0x10, 0x20, 0x40, 0x80)
        #expect(ORReduce.reduce([a, b]) == ORReduce.reduce([b, a]))
    }

    @Test("OR-reduce is associative")
    func associative() {
        let a = fp(0x1, 0x2, 0x4, 0x8)
        let b = fp(0x10, 0x20, 0x40, 0x80)
        let c = fp(0x100, 0x200, 0x400, 0x800)
        let lhs = ORReduce.reduce([ORReduce.reduce([a, b]), c])
        let rhs = ORReduce.reduce([a, ORReduce.reduce([b, c])])
        #expect(lhs == rhs)
    }

    @Test("OR-reduce is idempotent")
    func idempotent() {
        let a = fp(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
        #expect(ORReduce.reduce([a, a]) == a)
    }

    @Test("block-restricted reduce keeps only selected blocks")
    func blockRestrictedReduce() {
        let a = fp(0x1, 0x2, 0x4, 0x8)
        let b = fp(0x10, 0x20, 0x40, 0x80)
        let full = ORReduce.reduce([a, b])
        let only0and2 = ORReduce.reduce([a, b], blocks: [0, 2])
        #expect(only0and2.block0 == full.block0)
        #expect(only0and2.block1 == 0)
        #expect(only0and2.block2 == full.block2)
        #expect(only0and2.block3 == 0)
    }
}
