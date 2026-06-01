// MigrationRankingTests.swift
//
// Conformance fixtures for the deterministic decision core. These exact
// inputs and expected outputs are mirrored by the Rust version's
// `migration_ranking` tests (CognitionKit/rust/src/migration_ranking.rs)
// — both versions must agree. Per CLAUDE.md neither leads; this file
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

import Testing
import Foundation
@testable import CognitionKit

@Suite("MigrationRankingTests")
struct MigrationRankingTests {

    // F1 / F2 — duplicate detection
    @Test("first duplicate")
    func firstDuplicate() {
        #expect(MigrationRanking.firstDuplicate(["a", "b", "c"]) == nil)
        #expect(MigrationRanking.firstDuplicate(["x", "y", "x", "y"]) == "x")
        #expect(MigrationRanking.firstDuplicate([]) == nil)
    }

    // F3 — lost-concept union, sorted + deduped
    @Test("lost concepts")
    func lostConcepts() {
        #expect(MigrationRanking.lostConcepts(dropped: ["b"], notFound: ["a", "b"]) == ["a", "b"])
        #expect(MigrationRanking.lostConcepts(dropped: [], notFound: []) == [])
        #expect(MigrationRanking.lostConcepts(dropped: ["z", "m"], notFound: ["m", "a"]) == ["a", "m", "z"])
    }

    // F4 — origin partition by empty-after-trim content
    @Test("partition origin")
    func partitionOrigin() {
        let result = MigrationRanking.partitionOrigin([
            (id: "a", content: "hi"),
            (id: "b", content: "   "),
            (id: "c", content: "yo"),
        ])
        #expect(result.migratable == ["a", "c"])
        #expect(result.dropped == ["b"])
    }

    // F5 — four clean equal-score plans rank alphabetically
    @Test("rank equal scores tie-break by name")
    func rankEqualScoresTieBreakByName() {
        let outcomes = ["delta", "alpha", "charlie", "bravo"].map {
            MigrationRanking.PlanOutcome(
                name: $0, recallOverlap: 1.0, meanReciprocalRank: 1.0, lost: [])
        }
        let r = MigrationRanking.rank(outcomes)
        #expect(r.rankings.map(\.name) == ["alpha", "bravo", "charlie", "delta"])
        #expect(r.winner == "alpha")
        #expect(r.disqualified.isEmpty)
    }

    // F6 — a lost plan is disqualified, never ranked
    @Test("rank disqualifies lost plan")
    func rankDisqualifiesLostPlan() {
        let outcomes = [
            MigrationRanking.PlanOutcome(
                name: "clean", recallOverlap: 1.0, meanReciprocalRank: 1.0, lost: []),
            MigrationRanking.PlanOutcome(
                name: "lossy", recallOverlap: 0.5, meanReciprocalRank: 0.5, lost: ["x"]),
        ]
        let r = MigrationRanking.rank(outcomes)
        #expect(r.rankings.map(\.name) == ["clean"])
        #expect(r.disqualified.map(\.name) == ["lossy"])
        #expect(r.disqualified.first?.lostConcepts == ["x"])
        #expect(r.winner == "clean")
    }

    // F7 — distinct scores rank strictly descending; combinedScore = overlap*mrr
    @Test("rank distinct scores descending")
    func rankDistinctScoresDescending() {
        let outcomes = [
            MigrationRanking.PlanOutcome(
                name: "low", recallOverlap: 0.2, meanReciprocalRank: 0.5, lost: []),   // 0.10
            MigrationRanking.PlanOutcome(
                name: "high", recallOverlap: 0.8, meanReciprocalRank: 1.0, lost: []),  // 0.80
            MigrationRanking.PlanOutcome(
                name: "mid", recallOverlap: 0.5, meanReciprocalRank: 0.8, lost: []),   // 0.40
        ]
        let r = MigrationRanking.rank(outcomes)
        #expect(r.rankings.map(\.name) == ["high", "mid", "low"])
        #expect(abs((r.rankings.first?.combinedScore ?? 0) - 0.8) < 1e-6)
        #expect(r.winner == "high")
    }

    // Empty input -> empty result, no winner.
    @Test("rank empty")
    func rankEmpty() {
        let r = MigrationRanking.rank([])
        #expect(r.rankings.isEmpty)
        #expect(r.disqualified.isEmpty)
        #expect(r.winner == nil)
    }
}
