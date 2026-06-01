// MatchTests.swift
//
// swift-testing suite for the Match type: ordering and sort
// semantics (distance ascending, ties broken by index ascending).
// Peer to EngramLibTests.swift; split per source type per
// ENGRAM-TEST-01. Mirrors the Rust `match_ordering` test in
// rust/tests/engram_lib_tests.rs.

import Testing
@testable import EngramLib

@Suite("Match ordering")
struct MatchTests {

    @Test("Match sorts by distance then index")
    func matchOrdering() {
        let m1 = Match(index: 5, distance: 3)
        let m2 = Match(index: 1, distance: 3)
        let m3 = Match(index: 0, distance: 2)
        #expect(m3 < m2)
        #expect(m2 < m1)
        let sorted = [m1, m2, m3].sorted()
        #expect(sorted.map { $0.index } == [0, 1, 5])
    }
}
