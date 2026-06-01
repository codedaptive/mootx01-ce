// SubstrateTypesTests.swift
//
// SubstrateTypes package-level smoke test. Confirms the public
// surface is importable and the type system links up correctly.
// Algorithm-specific tests live in dedicated per-type suites
// (Fingerprint256CombinatorsTests, HammingTests, …) or in the
// conformance harness at docs/validation/substrate_math_performance/.
//
// swift-testing (import Testing); the package test leg is swift-testing
// only — no XCTest remains.

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("SubstrateTypes package smoke")
struct SubstrateTypesSmokeTests {

    @Test("Fingerprint256.zero is canonical all-zeros")
    func fingerprint256ZeroIsCanonical() {
        let zero = Fingerprint256.zero
        #expect(zero.words == [0, 0, 0, 0])
        #expect(zero.popcount() == 0)
    }

    @Test("HLC ordering is total and lexicographic")
    func hlcOrderingIsTotal() {
        let a = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        let b = HLC(physicalTime: 1000, logicalCount: 1, nodeID: 1)
        let c = HLC(physicalTime: 1001, logicalCount: 0, nodeID: 1)
        #expect(a < b)
        #expect(b < c)
        #expect(a < c)
    }

    @Test("RowId is a 16-byte UUID typealias")
    func rowIdIsUUIDTypealias() {
        // Lockstep contract (Swift leads): the Rust port has
        // pub struct RowId(pub u128); Swift has typealias RowId = UUID;
        // both are byte-identical at the wire level.
        let id: RowId = UUID()
        #expect(MemoryLayout.size(ofValue: id) == 16)
    }
}
