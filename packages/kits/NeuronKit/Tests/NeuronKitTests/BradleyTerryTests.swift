// BradleyTerryTests.swift
//
// Conformance, determinism, and convergence tests for the
// Bradley-Terry batch MLE ranker (mission NK-BT-01).

import XCTest
@testable import NeuronKit

final class BradleyTerryTests: XCTestCase {

    // MARK: - Fixtures

    /// A strongly-connected transitive-DOMINANCE ladder. A beats B and
    /// C decisively, B beats C decisively, and a single C-beats-A result
    /// closes the directed cycle so the win graph is strongly connected
    /// and the MLE is finite. Records: A>B ×3, B>C ×3, A>C ×3, C>A ×1.
    /// Win/loss: A 6-1, B 3-3, C 1-6 → expected order A > B > C.
    ///
    /// (A pure transitive fixture with no reverse result — A>B, B>C,
    /// A>C only — has a competitor that never wins (C) and one that
    /// never loses (A); its MLE is not finite, so the fitter throws
    /// .disconnectedComparisonGraph on it. That case is asserted in
    /// testPureTransitiveIsNotFinite. The "known ranking" requirement is
    /// served by this strongly-connected ladder.)
    private var dominanceLadder: [PairwiseOutcome] {
        [
            PairwiseOutcome(winner: "A", loser: "B", count: 3),
            PairwiseOutcome(winner: "B", loser: "C", count: 3),
            PairwiseOutcome(winner: "A", loser: "C", count: 3),
            PairwiseOutcome(winner: "C", loser: "A", count: 1),
        ]
    }

    // MARK: - Determinism

    func testSameInputsProduceBitForBitIdenticalScores() throws {
        let first = try bradleyTerry(outcomes: dominanceLadder)
        let second = try bradleyTerry(outcomes: dominanceLadder)
        XCTAssertEqual(first, second)
        // Equatable on Double is bit-exact; assert CI bounds explicitly
        // too so a regression in the SE path cannot hide behind ==.
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.strength, b.strength)
            XCTAssertEqual(a.confidenceLow, b.confidenceLow)
            XCTAssertEqual(a.confidenceHigh, b.confidenceHigh)
        }
    }

    func testRankingIsInvariantToInputOrder() throws {
        let forward = try bradleyTerry(outcomes: dominanceLadder)
        let reversed = try bradleyTerry(outcomes: dominanceLadder.reversed())
        // Shuffled into a third arbitrary permutation.
        let shuffled = try bradleyTerry(outcomes: [
            dominanceLadder[2], dominanceLadder[0],
            dominanceLadder[3], dominanceLadder[1],
        ])
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, shuffled)
    }

    // MARK: - Known ranking

    func testTransitiveDominanceRanksAOverBOverC() throws {
        let scores = try bradleyTerry(outcomes: dominanceLadder)
        XCTAssertEqual(scores.map(\.competitorID), ["A", "B", "C"])
        XCTAssertGreaterThan(scores[0].strength, scores[1].strength)
        XCTAssertGreaterThan(scores[1].strength, scores[2].strength)
        // A is the strongest competitor.
        let strongest = scores.max { $0.strength < $1.strength }
        XCTAssertEqual(strongest?.competitorID, "A")
    }

    func testEveryScoreHasFiniteConfidenceIntervalBracketingStrength() throws {
        let scores = try bradleyTerry(outcomes: dominanceLadder)
        for score in scores {
            XCTAssertTrue(score.strength.isFinite)
            XCTAssertTrue(score.confidenceLow.isFinite)
            XCTAssertTrue(score.confidenceHigh.isFinite)
            XCTAssertLessThanOrEqual(score.confidenceLow, score.strength)
            XCTAssertLessThanOrEqual(score.strength, score.confidenceHigh)
        }
    }

    // MARK: - Symmetric / tied fixture

    func testSymmetricOutcomesProduceEqualStrengthsAndOverlappingCIs() throws {
        // Every pair splits 1-1: a fully symmetric round-robin. All
        // strengths must be equal (0 on the sum-to-zero log scale) and
        // the CIs identical, hence overlapping.
        let symmetric = [
            PairwiseOutcome(winner: "A", loser: "B"),
            PairwiseOutcome(winner: "B", loser: "A"),
            PairwiseOutcome(winner: "B", loser: "C"),
            PairwiseOutcome(winner: "C", loser: "B"),
            PairwiseOutcome(winner: "A", loser: "C"),
            PairwiseOutcome(winner: "C", loser: "A"),
        ]
        let scores = try bradleyTerry(outcomes: symmetric)
        XCTAssertEqual(scores.count, 3)
        for score in scores {
            XCTAssertEqual(score.strength, 0.0, accuracy: 1e-9)
        }
        // CIs all coincide → trivially overlapping.
        let lows = Set(scores.map { ($0.confidenceLow * 1e9).rounded() })
        let highs = Set(scores.map { ($0.confidenceHigh * 1e9).rounded() })
        XCTAssertEqual(lows.count, 1)
        XCTAssertEqual(highs.count, 1)
        // And the interval genuinely brackets 0.
        XCTAssertLessThan(scores[0].confidenceLow, 0.0)
        XCTAssertGreaterThan(scores[0].confidenceHigh, 0.0)
    }

    // MARK: - count aggregation

    func testCountAggregationEqualsRepeatedSingleOutcomes() throws {
        let aggregated = [
            PairwiseOutcome(winner: "A", loser: "B", count: 5),
            PairwiseOutcome(winner: "B", loser: "A", count: 2),
        ]
        var expanded: [PairwiseOutcome] = []
        for _ in 0..<5 { expanded.append(PairwiseOutcome(winner: "A", loser: "B")) }
        for _ in 0..<2 { expanded.append(PairwiseOutcome(winner: "B", loser: "A")) }
        XCTAssertEqual(try bradleyTerry(outcomes: aggregated),
                       try bradleyTerry(outcomes: expanded))
    }

    func testNonPositiveCountContributesNothing() throws {
        let withZero = dominanceLadder + [
            PairwiseOutcome(winner: "A", loser: "B", count: 0),
            PairwiseOutcome(winner: "C", loser: "B", count: -4),
        ]
        XCTAssertEqual(try bradleyTerry(outcomes: dominanceLadder),
                       try bradleyTerry(outcomes: withZero))
    }

    // MARK: - Self-pairing and empty input

    func testSelfPairingThrows() {
        let bad = [PairwiseOutcome(winner: "A", loser: "A")]
        XCTAssertThrowsError(try bradleyTerry(outcomes: bad)) { error in
            XCTAssertEqual(error as? MOOTx01Error, .selfPairing(competitor: "A"))
        }
    }

    func testEmptyInputReturnsEmpty() throws {
        XCTAssertEqual(try bradleyTerry(outcomes: []), [])
    }

    // MARK: - Convergence / stationarity

    func testConvergesToStationaryPointSatisfyingMMCondition() throws {
        // A larger, irregular but strongly-connected tournament that
        // requires several MM sweeps. After fitting, the returned
        // strengths must satisfy the BT stationarity condition: for
        // each competitor i, p_i ≈ w_i / Σ_j n_ij/(p_i+p_j).
        let outcomes = [
            PairwiseOutcome(winner: "alpha", loser: "bravo", count: 7),
            PairwiseOutcome(winner: "bravo", loser: "alpha", count: 2),
            PairwiseOutcome(winner: "bravo", loser: "charlie", count: 5),
            PairwiseOutcome(winner: "charlie", loser: "bravo", count: 4),
            PairwiseOutcome(winner: "charlie", loser: "delta", count: 6),
            PairwiseOutcome(winner: "delta", loser: "charlie", count: 3),
            PairwiseOutcome(winner: "delta", loser: "alpha", count: 2),
            PairwiseOutcome(winner: "alpha", loser: "delta", count: 8),
            PairwiseOutcome(winner: "alpha", loser: "charlie", count: 3),
            PairwiseOutcome(winner: "charlie", loser: "alpha", count: 1),
        ]
        let scores = try bradleyTerry(outcomes: outcomes)
        XCTAssertEqual(scores.count, 4)

        // Reconstruct tallies to verify stationarity independently.
        let ids = scores.map(\.competitorID).sorted()
        var index: [String: Int] = [:]
        for (slot, id) in ids.enumerated() { index[id] = slot }
        let n = ids.count
        var wins = [Double](repeating: 0, count: n)
        var pairCount = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for outcome in outcomes {
            let i = index[outcome.winner]!, j = index[outcome.loser]!
            wins[i] += Double(outcome.count)
            pairCount[i][j] += Double(outcome.count)
            pairCount[j][i] += Double(outcome.count)
        }
        var p = [Double](repeating: 0, count: n)
        for score in scores { p[index[score.competitorID]!] = exp(score.strength) }

        for i in 0..<n {
            var denom = 0.0
            for j in 0..<n where j != i {
                if pairCount[i][j] != 0 { denom += pairCount[i][j] / (p[i] + p[j]) }
            }
            let stationaryP = wins[i] / denom
            // Relative residual at the fixed point must be ~epsilon.
            XCTAssertEqual(p[i], stationaryP, accuracy: max(1e-7, abs(p[i]) * 1e-6))
        }
    }

    // MARK: - Disconnected graph

    func testDisconnectedComponentsThrow() {
        // Two strongly-connected islands that never play each other:
        // {A,B} and {C,D}. The mission's named "a group never compared
        // against the rest" case.
        let islands = [
            PairwiseOutcome(winner: "A", loser: "B"),
            PairwiseOutcome(winner: "B", loser: "A"),
            PairwiseOutcome(winner: "C", loser: "D"),
            PairwiseOutcome(winner: "D", loser: "C"),
        ]
        XCTAssertThrowsError(try bradleyTerry(outcomes: islands)) { error in
            XCTAssertEqual(error as? MOOTx01Error, .disconnectedComparisonGraph)
        }
    }

    func testPureTransitiveIsNotFinite() {
        // A>B, B>C, A>C with no reverse result: C never wins, A never
        // loses. The win graph is connected but NOT strongly connected,
        // so the MLE is not finite and the fitter throws.
        let pureTransitive = [
            PairwiseOutcome(winner: "A", loser: "B"),
            PairwiseOutcome(winner: "B", loser: "C"),
            PairwiseOutcome(winner: "A", loser: "C"),
        ]
        XCTAssertThrowsError(try bradleyTerry(outcomes: pureTransitive)) { error in
            XCTAssertEqual(error as? MOOTx01Error, .disconnectedComparisonGraph)
        }
    }
}
