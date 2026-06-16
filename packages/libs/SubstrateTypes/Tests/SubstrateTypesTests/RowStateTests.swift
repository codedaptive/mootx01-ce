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

    @Test("public RowState.cluster matches the (raw>>4)&0x3 partition for every state")
    func publicClusterAccessorMatchesShiftAndMask() {
        // The public accessor must equal the canonical shift-and-mask for
        // every defined state — no hand-rolled boundary may diverge from it.
        for s in RowState.allCases {
            let expected = RowStateCluster(rawValue: (s.rawValue >> 4) & 0x3)!
            #expect(s.cluster == expected)
        }
        // Cluster A is the believed/active partition; B and C are retired.
        for s in [RowState.active, .pending, .contested, .accepted] {
            #expect(s.cluster == .a)
            #expect(s.isActiveCluster)
        }
        for s in [RowState.superseded, .decayed, .withdrawn, .expired] {
            #expect(s.cluster == .b)
            #expect(!s.isActiveCluster)
        }
        for s in [RowState.rejected, .tombstoned] {
            #expect(s.cluster == .c)
            #expect(!s.isActiveCluster)
        }
    }

    @Test("cluster(ofRawState:) classifies every defined raw and nils every gap raw")
    func clusterOfRawStateCoversAllRaws() {
        // Across the ENTIRE 6-bit state field (0...63), the classifier must
        // return the automaton's cluster for the ten defined states and nil
        // for every undefined gap raw (4–15, 20–31, 34–63). A future state
        // added to a defined cluster will classify correctly; an undefined
        // raw is explicitly nil, never silently mis-bucketed as "active".
        let defined: Set<UInt8> = Set(RowState.allCases.map(\.rawValue))
        for raw in UInt8(0)...UInt8(63) {
            let got = RowState.cluster(ofRawState: raw)
            if let state = RowState(rawValue: raw) {
                #expect(defined.contains(raw))
                #expect(got == state.cluster)
            } else {
                #expect(!defined.contains(raw))
                #expect(got == nil, "gap raw \(raw) must classify as nil, not a cluster")
            }
        }
    }

    @Test("activeClusterUpperBoundRaw == cluster-B floor and a `< bound` predicate matches the automaton for every defined raw")
    func activeBoundaryMatchesClusterForDefinedRaws() {
        // The named boundary is the cluster-B floor (superseded == 16),
        // not a bare magic number. Storage predicates can't call
        // cluster(ofRawState:), so they filter `g_state_cluster < bound`;
        // this pins that predicate to the same automaton boundary.
        #expect(RowState.activeClusterUpperBoundRaw == 16)
        #expect(RowState.activeClusterUpperBoundRaw == RowState.superseded.rawValue)
        for raw in UInt8(0)...UInt8(63) {
            guard let cluster = RowState.cluster(ofRawState: raw) else { continue }
            let predicate = raw < RowState.activeClusterUpperBoundRaw
            #expect(
                predicate == cluster.isActive,
                "defined raw \(raw): storage predicate (< \(RowState.activeClusterUpperBoundRaw)) must match automaton active-cluster")
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
