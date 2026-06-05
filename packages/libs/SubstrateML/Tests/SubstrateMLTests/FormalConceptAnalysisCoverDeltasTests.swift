// FormalConceptAnalysisCoverDeltasTests.swift
//
// Tests for ConceptCoverDeltas.covering(concepts:).
//
// Cover deltas are a structural lens over the concept order — not a
// logical implication basis. Each test case is hand-verified against
// the definition:
//   A → (B \ A) is emitted iff A.intent ⊂ B.intent and no C in the
//   input has A.intent ⊂ C.intent ⊂ B.intent.

import Testing
@testable import SubstrateML

@Suite("Concept cover deltas — structural lens over concept order")
struct FormalConceptAnalysisCoverDeltasTests {

    // MARK: - Fixtures

    private let attrA = FormalAttribute(namespace: "t", key: "k", value: "a")
    private let attrB = FormalAttribute(namespace: "t", key: "k", value: "b")
    private let attrC = FormalAttribute(namespace: "t", key: "k", value: "c")

    /// Single concept — no cover relations (no strict subset pairs).
    private func singleConcept() -> [FormalConcept] {
        [
            FormalConcept(extent: [0, 1], intent: [attrA], support: 2),
        ]
    }

    /// Two disjoint concepts — no subset relationship; no cover deltas.
    private func disjointConcepts() -> [FormalConcept] {
        [
            FormalConcept(extent: [0, 1], intent: [attrA], support: 2),
            FormalConcept(extent: [2, 3], intent: [attrB], support: 2),
        ]
    }

    /// Chain fixture: three concepts in a cover chain.
    ///   A = {a}       support 5
    ///   B = {a, b}    support 3
    ///   C = {a, b, c} support 2
    /// Direct covers: A→B, B→C (A→C is NOT a cover because B is intermediate).
    private func chainConcepts() -> [FormalConcept] {
        [
            FormalConcept(extent: [0,1,2,3,4], intent: [attrA],             support: 5),
            FormalConcept(extent: [0,1,2],     intent: [attrA, attrB],      support: 3),
            FormalConcept(extent: [0,1],       intent: [attrA, attrB, attrC], support: 2),
        ]
    }

    /// Direct-cover fixture: A = {a}, B = {a,b,c} — no intermediate.
    ///   One cover delta: lowerIntent={a}, addedAttributes={b, c}
    private func directCoverConcepts() -> [FormalConcept] {
        [
            FormalConcept(extent: [0,1,2], intent: [attrA],             support: 3),
            FormalConcept(extent: [0,1],   intent: [attrA, attrB, attrC], support: 2),
        ]
    }

    // MARK: - Edge cases

    @Test("empty concept list produces empty cover deltas")
    func emptyConceptsProduceEmptyCoverDeltas() {
        let deltas = ConceptCoverDeltas.covering(concepts: [])
        #expect(deltas.coverDeltas.isEmpty)
    }

    @Test("single concept produces empty cover deltas")
    func singleConceptProducesEmptyCoverDeltas() {
        let deltas = ConceptCoverDeltas.covering(concepts: singleConcept())
        #expect(deltas.coverDeltas.isEmpty)
    }

    @Test("disjoint concepts produce empty cover deltas")
    func disjointConceptsProduceEmptyCoverDeltas() {
        let deltas = ConceptCoverDeltas.covering(concepts: disjointConcepts())
        #expect(deltas.coverDeltas.isEmpty)
    }

    // MARK: - Correctness

    @Test("chain of three yields two cover deltas, not three")
    func chainYieldsTwoCoverDeltas() {
        let deltas = ConceptCoverDeltas.covering(concepts: chainConcepts())
        // A→B and B→C are direct covers. A→C is NOT a cover (B is intermediate).
        #expect(deltas.coverDeltas.count == 2)

        let delta0 = deltas.coverDeltas[0]  // smaller lowerIntent first
        let delta1 = deltas.coverDeltas[1]

        // First cover delta: lowerIntent={a}, addedAttributes={b}  (A→B cover)
        #expect(delta0.lowerIntent == Set([attrA]))
        #expect(delta0.addedAttributes == Set([attrB]))

        // Second cover delta: lowerIntent={a,b}, addedAttributes={c}  (B→C cover)
        #expect(delta1.lowerIntent == Set([attrA, attrB]))
        #expect(delta1.addedAttributes == Set([attrC]))
    }

    @Test("direct cover (no intermediate) yields one delta with full attribute delta")
    func directCoverYieldsOneDelta() {
        let deltas = ConceptCoverDeltas.covering(concepts: directCoverConcepts())
        #expect(deltas.coverDeltas.count == 1)

        let delta = deltas.coverDeltas[0]
        #expect(delta.lowerIntent == Set([attrA]))
        #expect(delta.addedAttributes == Set([attrB, attrC]))
    }

    // MARK: - Structural correctness

    @Test("every delta's lowerIntent union addedAttributes is a concept's intent")
    func everyDeltaCorrespondsToAConcept() {
        // For each cover delta, lowerIntent ∪ addedAttributes must equal
        // the more-specific concept's intent — that is the concept the
        // cover relation connects to.
        let concepts = chainConcepts()
        let deltas = ConceptCoverDeltas.covering(concepts: concepts)

        let allIntents = concepts.map { Set($0.intent) }
        for delta in deltas.coverDeltas {
            let full = delta.lowerIntent.union(delta.addedAttributes)
            #expect(allIntents.contains(full),
                    "lowerIntent ∪ addedAttributes must be a concept's intent: \(full)")
        }
    }

    @Test("lowerIntent is also a concept's intent (the more general concept)")
    func lowerIntentIsAConceptIntent() {
        let concepts = chainConcepts()
        let deltas = ConceptCoverDeltas.covering(concepts: concepts)
        let allIntents = concepts.map { Set($0.intent) }
        for delta in deltas.coverDeltas {
            #expect(allIntents.contains(delta.lowerIntent),
                    "lowerIntent must be a concept's intent: \(delta.lowerIntent)")
        }
    }

    @Test("no cover delta has empty addedAttributes")
    func noEmptyAddedAttributes() {
        let deltas = ConceptCoverDeltas.covering(concepts: chainConcepts())
        #expect(deltas.coverDeltas.allSatisfy { !$0.addedAttributes.isEmpty })
    }

    // MARK: - Determinism

    @Test("two calls produce identical ordered output")
    func coverDeltasAreDeterministic() {
        let concepts = chainConcepts()
        let first = ConceptCoverDeltas.covering(concepts: concepts)
        let second = ConceptCoverDeltas.covering(concepts: concepts)
        #expect(first.coverDeltas == second.coverDeltas)
    }

    @Test("input order does not affect output")
    func inputOrderDoesNotAffectOutput() {
        let canonical = ConceptCoverDeltas.covering(concepts: chainConcepts())
        let reversed  = ConceptCoverDeltas.covering(concepts: chainConcepts().reversed())
        #expect(canonical.coverDeltas == reversed.coverDeltas)
    }
}
