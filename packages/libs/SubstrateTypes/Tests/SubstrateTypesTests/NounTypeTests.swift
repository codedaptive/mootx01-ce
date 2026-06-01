// NounTypeTests.swift
//
// Per-type suite for NounType, the eight wire-stable noun categories
// (cookbook §2.5). The Rust `noun_type.rs` module carries no inline
// tests; this suite asserts the contract from source: raw values are
// fixed (0..7) and must never be renumbered, and round-trip through
// rawValue holds.

import Testing
@testable import SubstrateTypes

@Suite("NounType wire-stable categories")
struct NounTypeTests {

    @Test("raw values are fixed and must never be renumbered")
    func rawValuesAreWireStable() {
        #expect(NounType.drawer.rawValue == 0)
        #expect(NounType.tunnel.rawValue == 1)
        #expect(NounType.kgFact.rawValue == 2)
        #expect(NounType.diaryEntry.rawValue == 3)
        #expect(NounType.proposal.rawValue == 4)
        #expect(NounType.association.rawValue == 5)
        #expect(NounType.learnedReference.rawValue == 6)
        #expect(NounType.ambientSample.rawValue == 7)
    }

    @Test("rawValue round-trips through init(rawValue:)")
    func rawValueRoundTrips() {
        for raw: UInt8 in 0...7 {
            #expect(NounType(rawValue: raw)?.rawValue == raw)
        }
        #expect(NounType(rawValue: 8) == nil)
    }
}
