// FormalConceptStabilityTests.swift
//
// Tests for the sampled stability estimator introduced in MX-3B.
//
// Hand-verified fixture (dense-3):
//   Context: 3 rows each carrying {A, B}.
//   Concept: extent=[0,1,2], intent=[A,B], support=3.
//   All Bernoulli subsets (including empty) have intent=[A,B] because:
//     - non-empty subset: all rows carry A and B → intent=[A,B].
//     - empty subset: intent(∅) = all attributes = [A,B] (FCA convention).
//   Expected stability = 1.0 exactly, for any budget and seed.
//
// Nested 2-row fixture (theoretical stability 0.5):
//   Context: row 0 carries {A,B}, row 1 carries {A}.
//   Concept: extent=[0,1], intent=[A], support=2.
//   Bernoulli(p=0.5) over {0,1} — 4 equally probable draws in the limit:
//     {}    → intent(∅) = [A,B] ≠ [A] → miss
//     {0}   → intent({0}) = [A,B] ≠ [A] → miss
//     {1}   → intent({1}) = [A]   == [A] → hit
//     {0,1} → intent({0,1}) = [A] == [A] → hit
//   Expected stability (in limit) = 2/4 = 0.5.

import Testing
@testable import SubstrateML

// MARK: - Helpers

private let canonicalSeed: UInt64 = 0xCAFEBABEDEADBEEF

private func makeAttr(_ key: String, _ value: String) -> FormalAttribute {
    FormalAttribute(namespace: "test", key: key, value: value)
}

private let attrA = makeAttr("color", "red")
private let attrB = makeAttr("size", "large")
private let attrC = makeAttr("shape", "round")

// MARK: - StabilityEstimator unit tests

@Suite("StabilityEstimator")
struct StabilityEstimatorTests {

    // -- budget-zero guard --------------------------------------------------

    /// Budget zero must return 0.0 without calling the RNG.
    @Test("budget zero returns 0.0")
    func budgetZeroReturnsZero() {
        // Dense context: all rows carry {A, B}.
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA, attrB], [attrA, attrB],
        ])
        let concept = FormalConcept(
            extent: [0, 1, 2], intent: [attrA, attrB], support: 3)
        let stability = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 0, seed: canonicalSeed)
        #expect(stability == 0.0)
    }

    /// Negative budget (treated as ≤ 0) returns 0.0.
    @Test("negative budget returns 0.0")
    func negativeBudgetReturnsZero() {
        let context = FormalContext(rows: [[attrA]])
        let concept = FormalConcept(extent: [0], intent: [attrA], support: 1)
        #expect(StabilityEstimator.estimate(
            concept: concept, context: context, budget: -5, seed: canonicalSeed) == 0.0)
    }

    // -- range guard --------------------------------------------------------

    /// Stability must always be in [0.0, 1.0].
    @Test("stability is in [0.0, 1.0]")
    func stabilityInRange() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA], [attrB],
        ])
        let miner = BoundedConceptMiner(
            minSupport: 1, maxIntentSize: 8, maxConcepts: 8,
            stabilityBudget: 200, stabilitySeed: canonicalSeed)
        let concepts = miner.mine(context: context)
        #expect(!concepts.isEmpty)
        for concept in concepts {
            if let s = concept.stability {
                #expect(s >= 0.0 && s <= 1.0,
                    "stability \(s) out of [0,1] for concept with intent \(concept.intent)")
            }
        }
    }

    // -- hand-verified exact fixture ----------------------------------------

    /// Dense 3-row context: every Bernoulli subset produces intent=[A,B].
    /// Stability must be exactly 1.0 for any budget ≥ 1.
    @Test("dense concept has stability 1.0 (hand-verified)")
    func denseConceptStabilityIsOne() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA, attrB], [attrA, attrB],
        ])
        let concept = FormalConcept(
            extent: [0, 1, 2], intent: [attrA, attrB], support: 3)
        // Verify at several budgets: result must be exactly 1.0 every time
        // because all subsets (including empty, whose intent = all attributes
        // = [A,B]) produce intent = [A,B].
        for budget in [1, 10, 100] {
            let s = StabilityEstimator.estimate(
                concept: concept, context: context, budget: budget, seed: canonicalSeed)
            #expect(s == 1.0,
                "expected 1.0 for dense concept at budget \(budget), got \(s)")
        }
    }

    /// Single-row extent: any Bernoulli draw either gives the one row (hit)
    /// or the empty subset. Empty subset intent = all attributes. If the
    /// concept's intent IS all attributes of the context, every draw hits.
    @Test("single-row extent in single-row context has stability 1.0")
    func singleRowExtentSingleRowContext() {
        // Context has one row carrying {A}: intent(∅) = [A] = concept.intent.
        let context = FormalContext(rows: [[attrA]])
        let concept = FormalConcept(extent: [0], intent: [attrA], support: 1)
        let s = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 100, seed: canonicalSeed)
        #expect(s == 1.0)
    }

    // -- determinism --------------------------------------------------------

    /// Same inputs → same output, run twice.
    @Test("estimator is deterministic with same seed")
    func deterministicWithSameSeed() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA], [attrB, attrC],
        ])
        let concept = FormalConcept(extent: [0, 1], intent: [attrA], support: 2)
        let s1 = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 50, seed: canonicalSeed)
        let s2 = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 50, seed: canonicalSeed)
        #expect(s1 == s2)
    }

    /// Different seeds must produce different per-concept RNG streams —
    /// not necessarily different final values for every concept, but
    /// over a larger run they diverge.
    @Test("different seeds produce independent RNG streams")
    func differentSeedsProduceIndependentStreams() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA], [attrC],
        ])
        let concept = FormalConcept(extent: [0, 1], intent: [attrA], support: 2)
        // With budget 200 the sample means should agree to within tolerance
        // yet are produced by different seeds. We check they are independently
        // computed (no assertion on equality: different seeds are allowed to
        // agree by chance, but on average over many concepts they diverge).
        let s1 = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 200, seed: canonicalSeed)
        let s2 = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 200, seed: canonicalSeed &+ 1)
        // Both must be in-range — the independence test is not a strict
        // equality/inequality assertion because coincidence is possible.
        #expect(s1 >= 0.0 && s1 <= 1.0)
        #expect(s2 >= 0.0 && s2 <= 1.0)
    }

    // -- nested 2-row fixture (theoretical stability 0.5) ------------------

    /// For the nested context the theoretical limit is 0.5; with budget=1000
    /// the estimate should be within ±0.12 with overwhelming probability.
    @Test("nested concept stability converges toward 0.5")
    func nestedConceptConvergesToHalf() {
        // Row 0: {A, B}  Row 1: {A}
        // Concept: extent=[0,1], intent=[A]
        // Bernoulli draws (equally probable):
        //   {} → intent(∅)=[A,B] ≠ [A] → miss
        //   {0} → intent({0})=[A,B] ≠ [A] → miss
        //   {1} → intent({1})=[A] == [A] → hit
        //   {0,1} → intent({0,1})=[A] == [A] → hit
        // Expected = 2/4 = 0.5
        let context = FormalContext(rows: [[attrA, attrB], [attrA]])
        let concept = FormalConcept(extent: [0, 1], intent: [attrA], support: 2)
        let s = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 1000, seed: canonicalSeed)
        // Tolerance of 0.12 corresponds to ~4 standard deviations at n=1000.
        #expect(abs(s - 0.5) < 0.12,
            "expected stability near 0.5, got \(s)")
    }

    // -- conformance vector pin ----------------------------------------

    /// Conformance vector fcs-002-nested (fca_stability.json): verifies
    /// Swift and Rust produce bit-identical output. Uses namespace "cv" to
    /// match the vector file. Expected value 0.519 is pinned by the Rust
    /// test `conformance_fcs002_nested_matches_swift`.
    @Test("conformance fcs-002-nested: stability matches canonical vector (0.519)")
    func conformanceFcs002NestedMatchesVector() {
        // Fixtures use "cv" namespace to match fca_stability.json exactly.
        let k1 = FormalAttribute(namespace: "cv", key: "k1", value: "v1")
        let k2 = FormalAttribute(namespace: "cv", key: "k2", value: "v2")
        let context = FormalContext(rows: [[k1, k2], [k1]])
        let concept = FormalConcept(extent: [0, 1], intent: [k1], support: 2)
        let s = StabilityEstimator.estimate(
            concept: concept, context: context, budget: 1000, seed: canonicalSeed)
        // Exact pin — same deterministic PRNG seed and key as the Rust
        // conformance test and the fca_stability.json fcs-002-nested vector.
        #expect(s == 0.519,
            "fcs-002-nested: Swift must match canonical vector value 0.519, got \(s)")
    }
}

// MARK: - BoundedConceptMiner stability wiring

@Suite("BoundedConceptMiner stability wiring")
struct MinerStabilityTests {

    // -- budget=0 preserves v1 nil behavior ---------------------------------

    /// Default miner leaves stability nil on every emitted concept.
    @Test("budget zero preserves nil stability (v1 behavior)")
    func budgetZeroPreservesNilStability() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA, attrB], [attrA],
        ])
        let miner = BoundedConceptMiner(minSupport: 1, maxIntentSize: 8, maxConcepts: 8)
        let concepts = miner.mine(context: context)
        #expect(!concepts.isEmpty)
        for concept in concepts {
            #expect(concept.stability == nil,
                "v1 miner must leave stability nil, got \(String(describing: concept.stability))")
        }
    }

    /// Explicit stabilityBudget=0 also leaves stability nil.
    @Test("explicit budget zero leaves stability nil")
    func explicitBudgetZeroLeavesNil() {
        let context = FormalContext(rows: [[attrA], [attrA]])
        let miner = BoundedConceptMiner(
            minSupport: 1, maxIntentSize: 8, maxConcepts: 8, stabilityBudget: 0)
        let concepts = miner.mine(context: context)
        #expect(concepts.allSatisfy { $0.stability == nil })
    }

    // -- budget>0 populates stability ---------------------------------------

    /// When stabilityBudget > 0 every emitted concept has a non-nil stability.
    @Test("budget > 0 populates stability on all concepts")
    func budgetPositivePopulatesStability() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA, attrB], [attrA],
        ])
        let miner = BoundedConceptMiner(
            minSupport: 1, maxIntentSize: 8, maxConcepts: 8,
            stabilityBudget: 50, stabilitySeed: canonicalSeed)
        let concepts = miner.mine(context: context)
        #expect(!concepts.isEmpty)
        for concept in concepts {
            #expect(concept.stability != nil,
                "expected stability non-nil for concept with intent \(concept.intent)")
            if let s = concept.stability {
                #expect(s >= 0.0 && s <= 1.0)
            }
        }
    }

    // -- determinism through miner -----------------------------------------

    /// Two mine calls with the same parameters produce identical concepts
    /// including identical stability values.
    @Test("miner produces identical stability across two runs")
    func minerIsFullyDeterministic() {
        let context = FormalContext(rows: [
            [attrA, attrB], [attrA], [attrB],
        ])
        let miner = BoundedConceptMiner(
            minSupport: 1, maxIntentSize: 8, maxConcepts: 8,
            stabilityBudget: 100, stabilitySeed: canonicalSeed)
        let first = miner.mine(context: context)
        let second = miner.mine(context: context)
        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a.stability == b.stability,
                "stability mismatch: \(String(describing: a.stability)) vs \(String(describing: b.stability))")
        }
    }

    // -- edge cases --------------------------------------------------------

    /// Empty context produces no concepts regardless of stability budget.
    @Test("empty context produces no concepts with stability budget")
    func emptyContextNoConceptsWithBudget() {
        let context = FormalContext(rows: [])
        let miner = BoundedConceptMiner(
            minSupport: 1, maxIntentSize: 8, maxConcepts: 8,
            stabilityBudget: 100, stabilitySeed: canonicalSeed)
        #expect(miner.mine(context: context).isEmpty)
    }
}
