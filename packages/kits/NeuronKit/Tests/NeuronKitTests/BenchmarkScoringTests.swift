// BenchmarkScoringTests.swift
//
// Conformance fixtures for the pure recall-fidelity scoring core
// (NEURONKIT_SPEC § 4.7). These exact inputs and expected metrics are
// mirrored by the Rust port's `benchmark_scoring` tests
// (NeuronKit/rust/src/benchmark_scoring.rs) — both ports run the identical
// math and must agree. The live `benchmark(...)` end-to-end path keeps its
// own coverage in NK_BR_01_BranchBenchmarkTests; this file pins the
// extracted math directly, which is the cross-port gate.

import XCTest
@testable import NeuronKit

final class BenchmarkScoringTests: XCTestCase {

    // BS-1 — perfect migration: every expected concept recalled at rank 1.
    func testPerfectRecall() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b", "c"],
            foundPerQuery: [["a"], ["b"], ["c"]])
        XCTAssertEqual(s.queryCount, 3)
        XCTAssertEqual(s.recallOverlap, 1.0, accuracy: 1e-6)     // 3∩ / 3∪
        XCTAssertEqual(s.recallPrecision, 1.0, accuracy: 1e-6)   // 3∩ / 3 found
        XCTAssertEqual(s.meanReciprocalRank, 1.0, accuracy: 1e-6) // all rank 1
        XCTAssertEqual(s.notFoundInBranch, [])
        XCTAssertEqual(s.newInBranch, [])
    }

    // BS-2 — silent loss: one concept never recalled (C-13 signal).
    func testSilentLoss() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["a"], []])
        // foundUnion = {a}; expected = {a,b}. ∩=1, ∪=2.
        XCTAssertEqual(s.recallOverlap, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s.recallPrecision, 1.0, accuracy: 1e-6)   // 1∩ / 1 found
        // MRR: a@rank1 (1.0), b absent (0.0) -> mean 0.5
        XCTAssertEqual(s.meanReciprocalRank, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s.notFoundInBranch, ["b"])                // the C-13 signal
        XCTAssertEqual(s.newInBranch, [])
    }

    // BS-3 — rank sensitivity + surplus: expected found at deeper ranks,
    // plus an unexpected ("new") id surfaced.
    func testRankAndSurplus() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["x", "a"], ["b", "y"]])
        // foundUnion = {x,a,b,y}; expected = {a,b}. ∩=2, ∪=4.
        XCTAssertEqual(s.recallOverlap, 0.5, accuracy: 1e-6)      // 2/4
        XCTAssertEqual(s.recallPrecision, 0.5, accuracy: 1e-6)    // 2/4 found
        // MRR: a@rank2 (0.5), b@rank1 (1.0) -> mean 0.75
        XCTAssertEqual(s.meanReciprocalRank, 0.75, accuracy: 1e-6)
        XCTAssertEqual(s.notFoundInBranch, [])
        XCTAssertEqual(s.newInBranch, ["x", "y"])                 // surplus, sorted
    }

    // BS-4 — empty corpus / empty recalls: every metric the guarded 0.
    func testEmptyIsZeroNotTrap() {
        let s = BenchmarkScoring.score(expectedIDs: [], foundPerQuery: [])
        XCTAssertEqual(s.queryCount, 0)
        XCTAssertEqual(s.recallOverlap, 0.0)
        XCTAssertEqual(s.recallPrecision, 0.0)
        XCTAssertEqual(s.meanReciprocalRank, 0.0)
        XCTAssertEqual(s.notFoundInBranch, [])
        XCTAssertEqual(s.newInBranch, [])
    }

    // BS-5 — union semantics: a concept recalled by ANY query counts as
    // found (C-13). "b" missing from its own query but surfaced by query 0.
    func testFoundUnionAcrossQueries() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["a", "b"], []])
        // foundUnion = {a,b}; nothing lost despite query 1 being empty.
        XCTAssertEqual(s.notFoundInBranch, [])
        XCTAssertEqual(s.recallOverlap, 1.0, accuracy: 1e-6)
        // MRR pairing is per-query: a@rank1 in q0 (1.0); b NOT in q1 (0.0)
        // -> mean 0.5. (Set metrics use the union; MRR uses the pairing.)
        XCTAssertEqual(s.meanReciprocalRank, 0.5, accuracy: 1e-6)
    }
}
