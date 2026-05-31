// MigrationRankingTests.swift
//
// Conformance fixtures for the deterministic decision core. These exact
// inputs and expected outputs are mirrored by the Rust port's
// `migration_ranking` tests (CognitionKit/rust/src/migration_ranking.rs)
// — both ports must agree. Per CLAUDE.md neither port leads; this file
// and the Rust `#[cfg(test)]` block are the shared gate.
//
// FIXTURES (keep in lockstep with the Rust tests):
//   F1 firstDuplicate(["a","b","c"]) == nil
//   F2 firstDuplicate(["x","y","x","y"]) == "x"   (first repeat in scan order)
//   F3 lostConcepts(dropped:["b"], notFound:["a","b"]) == ["a","b"]  (union, sorted, deduped)
//   F4 partitionOrigin([("a","hi"),("b","  "),("c","yo")]) == (["a","c"], ["b"])
//   F5 rank of four clean equal-score plans -> alphabetical, winner first
//   F6 rank with one lost plan -> disqualified, excluded from ranking
//   F7 rank distinct scores -> strict descending by combinedScore

import XCTest
@testable import CognitionKit

final class MigrationRankingTests: XCTestCase {

    // F1 / F2 — duplicate detection
    func testFirstDuplicate() {
        XCTAssertNil(MigrationRanking.firstDuplicate(["a", "b", "c"]))
        XCTAssertEqual(MigrationRanking.firstDuplicate(["x", "y", "x", "y"]), "x")
        XCTAssertNil(MigrationRanking.firstDuplicate([]))
    }

    // F3 — lost-concept union, sorted + deduped
    func testLostConcepts() {
        XCTAssertEqual(
            MigrationRanking.lostConcepts(dropped: ["b"], notFound: ["a", "b"]),
            ["a", "b"])
        XCTAssertEqual(
            MigrationRanking.lostConcepts(dropped: [], notFound: []),
            [])
        XCTAssertEqual(
            MigrationRanking.lostConcepts(dropped: ["z", "m"], notFound: ["m", "a"]),
            ["a", "m", "z"])
    }

    // F4 — origin partition by empty-after-trim content
    func testPartitionOrigin() {
        let result = MigrationRanking.partitionOrigin([
            (id: "a", content: "hi"),
            (id: "b", content: "   "),
            (id: "c", content: "yo"),
        ])
        XCTAssertEqual(result.migratable, ["a", "c"])
        XCTAssertEqual(result.dropped, ["b"])
    }

    // F5 — four clean equal-score plans rank alphabetically
    func testRankEqualScoresTieBreakByName() {
        let outcomes = ["delta", "alpha", "charlie", "bravo"].map {
            MigrationRanking.PlanOutcome(
                name: $0, recallOverlap: 1.0, meanReciprocalRank: 1.0, lost: [])
        }
        let r = MigrationRanking.rank(outcomes)
        XCTAssertEqual(r.rankings.map(\.name), ["alpha", "bravo", "charlie", "delta"])
        XCTAssertEqual(r.winner, "alpha")
        XCTAssertTrue(r.disqualified.isEmpty)
    }

    // F6 — a lost plan is disqualified, never ranked
    func testRankDisqualifiesLostPlan() {
        let outcomes = [
            MigrationRanking.PlanOutcome(
                name: "clean", recallOverlap: 1.0, meanReciprocalRank: 1.0, lost: []),
            MigrationRanking.PlanOutcome(
                name: "lossy", recallOverlap: 0.5, meanReciprocalRank: 0.5, lost: ["x"]),
        ]
        let r = MigrationRanking.rank(outcomes)
        XCTAssertEqual(r.rankings.map(\.name), ["clean"])
        XCTAssertEqual(r.disqualified.map(\.name), ["lossy"])
        XCTAssertEqual(r.disqualified.first?.lostConcepts, ["x"])
        XCTAssertEqual(r.winner, "clean")
    }

    // F7 — distinct scores rank strictly descending; combinedScore = overlap*mrr
    func testRankDistinctScoresDescending() {
        let outcomes = [
            MigrationRanking.PlanOutcome(
                name: "low", recallOverlap: 0.2, meanReciprocalRank: 0.5, lost: []),   // 0.10
            MigrationRanking.PlanOutcome(
                name: "high", recallOverlap: 0.8, meanReciprocalRank: 1.0, lost: []),  // 0.80
            MigrationRanking.PlanOutcome(
                name: "mid", recallOverlap: 0.5, meanReciprocalRank: 0.8, lost: []),   // 0.40
        ]
        let r = MigrationRanking.rank(outcomes)
        XCTAssertEqual(r.rankings.map(\.name), ["high", "mid", "low"])
        XCTAssertEqual(r.rankings.first?.combinedScore ?? 0, 0.8, accuracy: 1e-6)
        XCTAssertEqual(r.winner, "high")
    }

    // Empty input -> empty result, no winner.
    func testRankEmpty() {
        let r = MigrationRanking.rank([])
        XCTAssertTrue(r.rankings.isEmpty)
        XCTAssertTrue(r.disqualified.isEmpty)
        XCTAssertNil(r.winner)
    }
}
