// BradleyTerryTests.swift
//
// Bradley-Terry online preference learning per cookbook § 8.12.
// swift-testing peer suite for Sources/SubstrateML/BradleyTerry.swift,
// mirroring rust/src/bradley_terry.rs (4 #[test]). Rust's `RowId(n)`
// newtype maps to Swift's `RowId = UUID`; this suite uses fixed
// UUIDs in place of the small-integer row ids, preserving each
// test's intent (winner up, loser down, repeated wins converge,
// unobserved row neutral). Learning rate / L2 match the Rust seeds:
// default() ⇒ (0.05, 0.001); new(0.05, 0.0) ⇒ zero regularization.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("BradleyTerry")
struct BradleyTerryTests {

    // Stable row ids standing in for Rust's RowId(1/2/3/42).
    private func rid(_ n: UInt8) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16); bytes[15] = n
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @Test("a winner's strength increases after an observation")
    func winnerStrengthIncreases() {
        var est = BradleyTerryEstimator()
        let s0 = est.strength(of: rid(1))
        est.observe(PreferenceObservation(winnerID: rid(1), losers: [rid(2), rid(3)]))
        let s1 = est.strength(of: rid(1))
        #expect(s1 > s0)
    }

    @Test("a loser's strength decreases after an observation")
    func loserStrengthDecreases() {
        var est = BradleyTerryEstimator()
        let s0 = est.strength(of: rid(2))
        est.observe(PreferenceObservation(winnerID: rid(1), losers: [rid(2)]))
        let s1 = est.strength(of: rid(2))
        #expect(s1 < s0)
    }

    @Test("repeated wins converge toward P(beats) ≈ 1")
    func repeatedWinsConverge() {
        var est = BradleyTerryEstimator(learningRate: 0.05, l2: 0.0)
        for _ in 0..<1000 {
            est.observe(PreferenceObservation(winnerID: rid(1), losers: [rid(2)]))
        }
        let p = est.probability(rid(1), beats: rid(2))
        #expect(p > 0.9)
    }

    @Test("an unobserved row has neutral strength 1.0")
    func unobservedRowIsNeutral() {
        let est = BradleyTerryEstimator()
        let s = est.strength(of: rid(42))
        #expect(abs(s - 1.0) < 1e-9)
    }
}
