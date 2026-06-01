// RowStateTests.swift
//
// Per-type suite for RowState / RowVerb / RowStateError (cookbook
// §2.3 / §9.1). The Rust `row_state.rs` module carries no inline
// tests; this suite asserts the contract from source: the scale-gapped
// raw values, the single-shift cluster predicate, CaseIterable
// completeness, and Codable round-trip. (The transition automaton lives
// in SubstrateLib and is out of scope here — these are the pure-data
// types only.)

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("RowState / RowVerb pure-data types")
struct RowStateTests {

    @Test("states carry their scale-gapped raw values (0/16/32 clusters)")
    func scaleGappedRawValues() {
        #expect(RowState.active.rawValue == 0)
        #expect(RowState.pending.rawValue == 1)
        #expect(RowState.contested.rawValue == 2)
        #expect(RowState.accepted.rawValue == 3)
        #expect(RowState.superseded.rawValue == 16)
        #expect(RowState.decayed.rawValue == 17)
        #expect(RowState.withdrawn.rawValue == 18)
        #expect(RowState.expired.rawValue == 19)
        #expect(RowState.rejected.rawValue == 32)
        #expect(RowState.tombstoned.rawValue == 33)
    }

    @Test("cluster is (rawValue >> 4) & 0x3 — A=0, B=1, C=2")
    func clusterIsSingleShiftAndMask() {
        func cluster(_ s: RowState) -> UInt8 { (s.rawValue >> 4) & 0x3 }
        // Cluster A (active / becoming)
        for s in [RowState.active, .pending, .contested, .accepted] {
            #expect(cluster(s) == 0)
        }
        // Cluster B (superseded / historical)
        for s in [RowState.superseded, .decayed, .withdrawn, .expired] {
            #expect(cluster(s) == 1)
        }
        // Cluster C (terminal)
        for s in [RowState.rejected, .tombstoned] {
            #expect(cluster(s) == 2)
        }
    }

    @Test("all ten states and twelve verbs are enumerable")
    func caseIterableCompleteness() {
        #expect(RowState.allCases.count == 10)
        #expect(RowVerb.allCases.count == 12)
    }

    @Test("RowState round-trips through Codable")
    func rowStateCodableRoundTrip() throws {
        for s in RowState.allCases {
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(RowState.self, from: data) == s)
        }
    }

    @Test("RowStateError is Equatable over its associated values")
    func rowStateErrorEquatable() {
        #expect(RowStateError.illegalTransition(.active, .retract)
                == RowStateError.illegalTransition(.active, .retract))
        #expect(RowStateError.illegalTransition(.active, .retract)
                != RowStateError.illegalTransition(.pending, .retract))
    }
}
