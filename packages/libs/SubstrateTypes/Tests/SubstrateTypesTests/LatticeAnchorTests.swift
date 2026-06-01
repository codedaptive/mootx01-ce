// LatticeAnchorTests.swift
//
// Per-type suite for LatticeAnchor (16-byte UDC + Q-ID reference,
// cookbook §2.7 / I-16). The Rust `lattice_anchor.rs` module carries
// no inline tests; this suite asserts the contract from source: the
// null predicate, FNV-1a-backed `udc(_:)` determinism, and equality.

import Testing
@testable import SubstrateTypes

@Suite("LatticeAnchor")
struct LatticeAnchorTests {

    @Test("the all-zero anchor is null")
    func zeroAnchorIsNull() {
        #expect(LatticeAnchor(udcCode: 0, qidPointer: 0).isNull)
        #expect(!LatticeAnchor(udcCode: 1, qidPointer: 0).isNull)
        #expect(!LatticeAnchor(udcCode: 0, qidPointer: 1).isNull)
    }

    @Test("qidPointer defaults to 0 (null pointer)")
    func qidPointerDefaultsToZero() {
        #expect(LatticeAnchor(udcCode: 42).qidPointer == 0)
    }

    @Test("udc(_:) is deterministic and matches FNV-1a 64 of the string")
    func udcIsDeterministicFNV() {
        let a = LatticeAnchor.udc("613.71")
        let b = LatticeAnchor.udc("613.71")
        #expect(a == b)
        #expect(a.udcCode == FNV.hash64("613.71"))
        #expect(a.qidPointer == 0)
    }

    @Test("different UDC strings produce different anchors")
    func differentStringsDiffer() {
        #expect(LatticeAnchor.udc("613.71") != LatticeAnchor.udc("530.12"))
    }
}
