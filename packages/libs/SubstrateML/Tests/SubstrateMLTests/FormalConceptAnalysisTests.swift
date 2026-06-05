// FormalConceptAnalysisTests.swift
//
// Conformance and edge-case tests for the bounded FCA engine
// (`FormalContext` closure operators + `BoundedConceptMiner`). All
// vectors are in-code and hand-computed; the Rust version's inline
// `#[cfg(test)] mod tests` in `rust/src/formal_concept_analysis.rs`
// encodes the IDENTICAL cases and expected outputs — these tests are
// the cross-language conformance contract. Everything here is exact
// (sorted integer extents, sorted attribute intents, integer supports);
// no float tolerance is involved because v1 omits stability.

import Testing
@testable import SubstrateML

@Suite("Bounded formal concept analysis")
struct FormalConceptAnalysisTests {

    // MARK: - Fixtures
    //
    // Five attributes in one namespace. Sorted universe order (by
    // (namespace, key, value)) is [C, A, E, B, D]:
    //   C=(adj,color,blue) < A=(adj,color,red) < E=(adj,shape,round)
    //     < B=(adj,size,large) < D=(adj,size,small)
    //
    // Cohort fixture — 6 rows, two clean cohorts plus a singleton:
    //   rows 0,1,2: {A,B}   rows 3,4: {C,D}   row 5: {E}
    // Hand-computed closures (minSupport=2 seeds: A,B,C,D; E support 1):
    //   closure([A]) = closure([B]) = [A,B]  extent [0,1,2] support 3
    //   closure([C]) = closure([D]) = [C,D]  extent [3,4]   support 2
    // → two concepts after intent-dedup, ordered support desc.

    private let attrA = FormalAttribute(namespace: "adj", key: "color", value: "red")
    private let attrB = FormalAttribute(namespace: "adj", key: "size", value: "large")
    private let attrC = FormalAttribute(namespace: "adj", key: "color", value: "blue")
    private let attrD = FormalAttribute(namespace: "adj", key: "size", value: "small")
    private let attrE = FormalAttribute(namespace: "adj", key: "shape", value: "round")

    private var cohortContext: FormalContext {
        FormalContext(rows: [
            [attrA, attrB],   // 0
            [attrA, attrB],   // 1
            [attrA, attrB],   // 2
            [attrC, attrD],   // 3
            [attrC, attrD],   // 4
            [attrE],          // 5
        ])
    }

    /// Nested fixture — closures of different intent sizes:
    ///   rows 0,1,2: {A,B}   rows 3,4: {A}
    ///   closure([A]) = [A]    extent [0,1,2,3,4] support 5
    ///   closure([B]) = [A,B]  extent [0,1,2]     support 3
    private var nestedContext: FormalContext {
        FormalContext(rows: [
            [attrA, attrB],
            [attrA, attrB],
            [attrA, attrB],
            [attrA],
            [attrA],
        ])
    }

    // MARK: - 1. Derivation operators

    @Test("extent of empty intent is all rows; unknown attribute empties it")
    func extentOperatorBoundaries() {
        let ctx = cohortContext
        #expect(ctx.extent(of: []) == [0, 1, 2, 3, 4, 5])
        let unknown = FormalAttribute(namespace: "adj", key: "color", value: "green")
        #expect(ctx.extent(of: [unknown]) == [])
        #expect(ctx.extent(of: [attrA]) == [0, 1, 2])
        #expect(ctx.extent(of: [attrA, attrB]) == [0, 1, 2])
        #expect(ctx.extent(of: [attrA, attrC]) == [])
    }

    @Test("intent of empty extent is all attributes, sorted")
    func intentOperatorBoundaries() {
        let ctx = cohortContext
        // Sorted universe: [C, A, E, B, D] per the fixture comment.
        #expect(ctx.intent(of: []) == [attrC, attrA, attrE, attrB, attrD])
        #expect(ctx.intent(of: [0, 1, 2]) == [attrA, attrB])
        #expect(ctx.intent(of: [3, 4]) == [attrC, attrD])
        #expect(ctx.intent(of: [0, 3]) == [])
    }

    @Test("closure derives the full shared intent")
    func closureDerivesSharedIntent() {
        let ctx = cohortContext
        #expect(ctx.closure(of: [attrA]) == [attrA, attrB])
        #expect(ctx.closure(of: [attrC]) == [attrC, attrD])
        #expect(ctx.closure(of: [attrE]) == [attrE])
    }

    @Test("closure is idempotent: closure(closure(x)) == closure(x)")
    func closureIsIdempotent() {
        let ctx = cohortContext
        for seed in [[attrA], [attrB], [attrC], [attrE], [], [attrA, attrC]] {
            let once = ctx.closure(of: seed)
            #expect(ctx.closure(of: once) == once)
        }
    }

    // MARK: - 2. Miner: cohorts, dedup, ordering

    @Test("two distinct cohorts yield their two concepts, support-desc ordered")
    func twoCohortsYieldTwoConcepts() {
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let out = miner.mine(context: cohortContext)
        // Four seeds (A,B,C,D) collapse to two intents; E gated by
        // minSupport. Support 3 cohort precedes support 2 cohort.
        #expect(out.count == 2)
        #expect(out[0].extent == [0, 1, 2])
        #expect(out[0].intent == [attrA, attrB])
        #expect(out[0].support == 3)
        #expect(out[1].extent == [3, 4])
        #expect(out[1].intent == [attrC, attrD])
        #expect(out[1].support == 2)
    }

    @Test("equal support and intent size tie-break on lexicographic intent")
    func equalSupportTieBreaksOnIntentKey() {
        // Two cohorts of 2: both concepts support 2, intent size 2.
        // [C,D] starts at (adj,color,blue) < (adj,color,red), so the
        // [C,D] concept precedes [A,B].
        let ctx = FormalContext(rows: [
            [attrA, attrB],
            [attrA, attrB],
            [attrC, attrD],
            [attrC, attrD],
        ])
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let out = miner.mine(context: ctx)
        #expect(out.count == 2)
        #expect(out[0].intent == [attrC, attrD])
        #expect(out[1].intent == [attrA, attrB])
    }

    @Test("smaller intent precedes larger at equal support")
    func smallerIntentPrecedesLargerAtEqualSupport() {
        // rows 0,1: {A}; rows 2,3: {C,D} — both concepts support 2;
        // intent sizes 1 vs 2 → [A] first despite blue < red.
        let ctx = FormalContext(rows: [
            [attrA],
            [attrA],
            [attrC, attrD],
            [attrC, attrD],
        ])
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let out = miner.mine(context: ctx)
        #expect(out.count == 2)
        #expect(out[0].intent == [attrA])
        #expect(out[1].intent == [attrC, attrD])
    }

    // MARK: - 3. Caps

    @Test("maxIntentSize cap excludes over-large closures")
    func maxIntentSizeCapExcludes() {
        // Nested fixture: closure([A]) has intent size 1, closure([B])
        // size 2. Cap at 1 keeps only the [A] concept.
        let capped = BoundedConceptMiner(minSupport: 2, maxIntentSize: 1, maxConcepts: 8)
        let out = capped.mine(context: nestedContext)
        #expect(out.count == 1)
        #expect(out[0].extent == [0, 1, 2, 3, 4])
        #expect(out[0].intent == [attrA])
        #expect(out[0].support == 5)

        // Cap at 2 admits both, support-desc ordered.
        let uncapped = BoundedConceptMiner(minSupport: 2, maxIntentSize: 2, maxConcepts: 8)
        let both = uncapped.mine(context: nestedContext)
        #expect(both.count == 2)
        #expect(both[0].intent == [attrA])
        #expect(both[1].intent == [attrA, attrB])
        #expect(both[1].support == 3)
    }

    @Test("maxConcepts truncates after the full sort")
    func maxConceptsTruncates() {
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 1)
        let out = miner.mine(context: cohortContext)
        // Truncation keeps the sort's head: the support-3 cohort.
        #expect(out.count == 1)
        #expect(out[0].intent == [attrA, attrB])
        #expect(out[0].support == 3)
    }

    @Test("minSupport gates seeds and concepts")
    func minSupportGates() {
        let ctx = cohortContext
        // minSupport=3: only the A/B cohort survives.
        let three = BoundedConceptMiner(minSupport: 3, maxIntentSize: 8, maxConcepts: 8)
            .mine(context: ctx)
        #expect(three.count == 1)
        #expect(three[0].intent == [attrA, attrB])
        // minSupport=4: nothing survives.
        let four = BoundedConceptMiner(minSupport: 4, maxIntentSize: 8, maxConcepts: 8)
            .mine(context: ctx)
        #expect(four.isEmpty)
        // minSupport=0 clamps to 1: the singleton E concept appears.
        let zero = BoundedConceptMiner(minSupport: 0, maxIntentSize: 8, maxConcepts: 8)
            .mine(context: ctx)
        #expect(zero.count == 3)
        #expect(zero[2].extent == [5])
        #expect(zero[2].intent == [attrE])
        #expect(zero[2].support == 1)
    }

    // MARK: - 4. Edges

    @Test("empty context mines to empty")
    func emptyContextMinesEmpty() {
        let ctx = FormalContext(rows: [])
        let miner = BoundedConceptMiner(minSupport: 1, maxIntentSize: 8, maxConcepts: 8)
        #expect(miner.mine(context: ctx).isEmpty)
        #expect(ctx.extent(of: []) == [])
    }

    @Test("non-positive caps mine to empty")
    func nonPositiveCapsMineEmpty() {
        let ctx = cohortContext
        #expect(BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 0)
            .mine(context: ctx).isEmpty)
        #expect(BoundedConceptMiner(minSupport: 2, maxIntentSize: 0, maxConcepts: 8)
            .mine(context: ctx).isEmpty)
    }

    // MARK: - 5. Determinism and v1 stability omission

    @Test("two runs are identical")
    func twoRunsAreIdentical() {
        let miner = BoundedConceptMiner(minSupport: 1, maxIntentSize: 8, maxConcepts: 8)
        let first = miner.mine(context: cohortContext)
        let second = miner.mine(context: cohortContext)
        #expect(first == second)
    }

    @Test("stability is nil in v1 (computation omitted, no subset enumeration)")
    func stabilityIsNilInV1() {
        let miner = BoundedConceptMiner(minSupport: 1, maxIntentSize: 8, maxConcepts: 8)
        let out = miner.mine(context: cohortContext)
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.stability == nil })
    }
}
