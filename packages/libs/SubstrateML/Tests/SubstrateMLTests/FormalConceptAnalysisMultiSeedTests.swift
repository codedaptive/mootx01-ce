// FormalConceptAnalysisMultiSeedTests.swift
//
// Tests for BoundedConceptMiner's multi-seed exploration.
//
// v1 single-seed tests are in FormalConceptAnalysisTests.swift —
// the parameterless init uses the single-seed default and every
// existing test must continue to pass unchanged.

import Testing
@testable import SubstrateML

@Suite("Multi-seed concept mining")
struct FormalConceptAnalysisMultiSeedTests {

    // MARK: - Fixtures

    private let attrA = FormalAttribute(namespace: "t", key: "k", value: "a")
    private let attrB = FormalAttribute(namespace: "t", key: "k", value: "b")
    private let attrC = FormalAttribute(namespace: "t", key: "k", value: "c")
    private let attrD = FormalAttribute(namespace: "t", key: "k", value: "d")

    /// Context designed so that multi-seed discovers an extra concept
    /// that single-seed misses.
    ///
    /// Rows:
    ///   0: {A, B, C}
    ///   1: {A, B, C}
    ///   2: {A, D}
    ///   3: {B, D}
    ///
    /// Single-attribute closures (minSupport=2):
    ///   closure([A]) = [A]  extent [0,1,2] support 3
    ///   closure([B]) = [B]  extent [0,1,3] support 3
    ///   closure([C]) = [A,B,C]  extent [0,1]   support 2
    ///   closure([D]) = [D]  extent [2,3]   support 2
    ///
    /// Single-seed mining at minSupport=2 yields: [A],[B],[A,B,C],[D]
    ///   That is 4 concepts (some single-attrs deduplicate to same intent).
    ///
    /// Multi-seed: pair {A,B} — both frequent. Extent of {A,B} = rows
    /// carrying both A AND B = [0,1] (rows 2,3 each miss one).
    ///   closure([A,B]) = intent([0,1]) = [A,B,C] (extent [0,1]).
    ///   This is NOT a new concept — [A,B,C] was already found via C.
    ///
    /// We need a context where multi-seed finds something NEW:
    ///
    /// Revised context — "bridge" pattern:
    ///   0: {A, B}    — rows 0,1,2 all carry A
    ///   1: {A, B}    — rows 0,1,3 carry B (row 2 is {A,C}, no B)
    ///   2: {A, C}    — rows 2,3 carry C
    ///   3: {B, C}
    ///
    /// Single-attribute closures (minSupport=2):
    ///   A appears in [0,1,2]: closure([A])=[A]    extent [0,1,2] support 3
    ///   B appears in [0,1,3]: closure([B])=[B]    extent [0,1,3] support 3
    ///   C appears in [2,3]:   closure([C])=[C]    extent [2,3]   support 2
    ///
    /// Single-seed: 3 concepts: {A}, {B}, {C}.
    ///
    /// Pair {A,B}: extent = rows with both A and B = [0,1].
    ///   closure([A,B]) = intent([0,1]) = [A,B] support 2.
    ///   [A,B] is NOT in the single-seed result (single seeds give {A},{B},{C}).
    ///   → multi-seed finds {A,B} as a NEW concept.
    private var bridgeContext: FormalContext {
        FormalContext(rows: [
            [attrA, attrB],  // 0
            [attrA, attrB],  // 1
            [attrA, attrC],  // 2
            [attrB, attrC],  // 3
        ])
    }

    // MARK: - V1 regression: single-seed mode unchanged

    @Test("single-seed mode produces v1 results unchanged")
    func singleSeedModeIsV1() {
        let single = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
            seedMode: .single
        )
        let defaultMiner = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 8
        )
        let fromSingle  = single.mine(context: bridgeContext)
        let fromDefault = defaultMiner.mine(context: bridgeContext)
        #expect(fromSingle == fromDefault)
    }

    @Test("single-seed finds three concepts in bridge context")
    func singleSeedThreeConcepts() {
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let out = miner.mine(context: bridgeContext)
        // {A}, {B}, {C} — sorted by support desc; A and B both support 3,
        // tie-break on intent size (equal) then lex; {A}<{B} lex, so A first.
        #expect(out.count == 3)
        #expect(out[0].intent == [attrA])
        #expect(out[1].intent == [attrB])
        #expect(out[2].intent == [attrC])
    }

    // MARK: - Multi-seed finds extra concept

    @Test("multi-seed finds strictly more concepts on bridge context")
    func multiSeedFindsMoreConcepts() {
        let single = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
                                         seedMode: .single)
        let multi  = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
                                         seedMode: .multi)

        let singleOut = single.mine(context: bridgeContext)
        let multiOut  = multi.mine(context: bridgeContext)

        #expect(multiOut.count > singleOut.count,
                "multi-seed must find more concepts than single-seed on bridge context")
    }

    @Test("multi-seed discovers {A,B} concept missed by single-seed")
    func multiSeedDiscoversABConcept() {
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
                                        seedMode: .multi)
        let out = miner.mine(context: bridgeContext)

        let intents = out.map { Set($0.intent) }
        let expectedExtra = Set([attrA, attrB])
        #expect(intents.contains(expectedExtra),
                "multi-seed must include {A,B} concept (extent [0,1], support 2)")
    }

    // MARK: - Caps respected in multi mode

    @Test("maxSeeds caps the number of pairs explored")
    func maxSeedsCapsExploration() {
        // maxSeeds=0 means no pair seeds are tried → same result as single.
        let cappedAtZero = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
            seedMode: .multi, maxSeeds: 0
        )
        let single = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
            seedMode: .single
        )
        #expect(cappedAtZero.mine(context: bridgeContext)
                == single.mine(context: bridgeContext))
    }

    @Test("maxIntentSize cap applies equally in multi mode")
    func maxIntentSizeCapAppliesInMultiMode() {
        // Cap at 1: only size-1 intents are kept regardless of seed mode.
        let capped = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 1, maxConcepts: 8,
            seedMode: .multi
        )
        let out = capped.mine(context: bridgeContext)
        // All emitted intents must have size ≤ 1.
        #expect(out.allSatisfy { $0.intent.count <= 1 })
    }

    @Test("maxConcepts cap applies equally in multi mode")
    func maxConceptsCapAppliesInMultiMode() {
        let capped = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 2,
            seedMode: .multi
        )
        let out = capped.mine(context: bridgeContext)
        #expect(out.count <= 2)
    }

    // MARK: - Determinism in multi mode

    @Test("multi-seed is deterministic across two identical calls")
    func multiSeedIsDeterministic() {
        let miner = BoundedConceptMiner(
            minSupport: 2, maxIntentSize: 8, maxConcepts: 8,
            seedMode: .multi
        )
        let first  = miner.mine(context: bridgeContext)
        let second = miner.mine(context: bridgeContext)
        #expect(first == second)
    }
}
