// BenchmarkScoringTests.swift
//
// Conformance fixtures for the pure recall-fidelity scoring core
// (NEURONKIT_SPEC § 4.7). These exact inputs and expected metrics are
// mirrored by the Rust version's `benchmark_scoring` tests
// (NeuronKit/rust/src/benchmark_scoring.rs) — both versions run the identical
// math and must agree. The live `benchmark(...)` end-to-end path keeps its
// own coverage in NK_BR_01_BranchBenchmarkTests; this file pins the
// extracted math directly, which is the cross-version gate.

import Testing
@testable import NeuronKit

@Suite("Benchmark scoring core")
struct BenchmarkScoringTests {

    // BS-1 — perfect migration: every expected concept recalled at rank 1.
    @Test("perfect recall scores every metric at 1.0")
    func perfectRecall() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b", "c"],
            foundPerQuery: [["a"], ["b"], ["c"]])
        #expect(s.queryCount == 3)
        #expect(abs(s.recallOverlap - 1.0) <= 1e-6)     // 3∩ / 3∪
        #expect(abs(s.recallPrecision - 1.0) <= 1e-6)   // 3∩ / 3 found
        #expect(abs(s.meanReciprocalRank - 1.0) <= 1e-6) // all rank 1
        #expect(s.notFoundInBranch == [])
        #expect(s.newInBranch == [])
    }

    // BS-2 — silent loss: one concept never recalled (C-13 signal).
    @Test("silent loss surfaces the lost concept and halves overlap")
    func silentLoss() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["a"], []])
        // foundUnion = {a}; expected = {a,b}. ∩=1, ∪=2.
        #expect(abs(s.recallOverlap - 0.5) <= 1e-6)
        #expect(abs(s.recallPrecision - 1.0) <= 1e-6)   // 1∩ / 1 found
        // MRR: a@rank1 (1.0), b absent (0.0) -> mean 0.5
        #expect(abs(s.meanReciprocalRank - 0.5) <= 1e-6)
        #expect(s.notFoundInBranch == ["b"])                // the C-13 signal
        #expect(s.newInBranch == [])
    }

    // BS-3 — rank sensitivity + surplus: expected found at deeper ranks,
    // plus an unexpected ("new") id surfaced.
    @Test("deeper ranks and surplus ids are scored correctly")
    func rankAndSurplus() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["x", "a"], ["b", "y"]])
        // foundUnion = {x,a,b,y}; expected = {a,b}. ∩=2, ∪=4.
        #expect(abs(s.recallOverlap - 0.5) <= 1e-6)      // 2/4
        #expect(abs(s.recallPrecision - 0.5) <= 1e-6)    // 2/4 found
        // MRR: a@rank2 (0.5), b@rank1 (1.0) -> mean 0.75
        #expect(abs(s.meanReciprocalRank - 0.75) <= 1e-6)
        #expect(s.notFoundInBranch == [])
        #expect(s.newInBranch == ["x", "y"])                 // surplus, sorted
    }

    // BS-4 — empty corpus / empty recalls: every metric the guarded 0.
    @Test("empty input yields guarded zeros, not a trap")
    func emptyIsZeroNotTrap() {
        let s = BenchmarkScoring.score(expectedIDs: [], foundPerQuery: [])
        #expect(s.queryCount == 0)
        #expect(s.recallOverlap == 0.0)
        #expect(s.recallPrecision == 0.0)
        #expect(s.meanReciprocalRank == 0.0)
        #expect(s.notFoundInBranch == [])
        #expect(s.newInBranch == [])
    }

    // BS-5 — union semantics: a concept recalled by ANY query counts as
    // found (C-13). "b" missing from its own query but surfaced by query 0.
    @Test("found-union counts a concept recalled by any query")
    func foundUnionAcrossQueries() {
        let s = BenchmarkScoring.score(
            expectedIDs: ["a", "b"],
            foundPerQuery: [["a", "b"], []])
        // foundUnion = {a,b}; nothing lost despite query 1 being empty.
        #expect(s.notFoundInBranch == [])
        #expect(abs(s.recallOverlap - 1.0) <= 1e-6)
        // MRR pairing is per-query: a@rank1 in q0 (1.0); b NOT in q1 (0.0)
        // -> mean 0.5. (Set metrics use the union; MRR uses the pairing.)
        #expect(abs(s.meanReciprocalRank - 0.5) <= 1e-6)
    }
}
