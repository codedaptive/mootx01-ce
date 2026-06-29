// ConceptImplicationsTests.swift
//
// Tests for ConceptImplications: the Duquenne–Guigues canonical basis
// engine over FormalContext.
//
// Test organisation:
//   1. Soundness (the primary contract)
//   2. Hand-verified small fixtures (basis correctness)
//   3. Bounding cap behaviour (maxImplications, maxPremiseSize)
//   4. Edge cases (empty context, single row, no implications)
//   5. Determinism

import Testing
@testable import SubstrateML

// MARK: - Helpers

/// Build a FormalAttribute in the "t" namespace with key "k".
private func attr(_ value: String) -> FormalAttribute {
    FormalAttribute(namespace: "t", key: "k", value: value)
}

private let a = attr("a")
private let b = attr("b")
private let c = attr("c")
private let d = attr("d")

// MARK: - Test suite

@Suite("ConceptImplications")
struct ConceptImplicationsTests {

    // MARK: 1. Soundness

    /// Primary contract: for every emitted implication (premise → conclusion),
    /// every row that carries all attributes in premise also carries all
    /// attributes in conclusion. Tested exhaustively on a context with
    /// multiple known implications.
    ///
    /// Context: two rows — {a} (row 0) and {b,c} (row 1).
    ///   closure({b}) = {b,c}  → implication {b}→{c}
    ///   closure({c}) = {b,c}  → implication {c}→{b}
    @Test func soundnessHoldsForEveryRow() {
        let context = FormalContext(rows: [
            [a],        // row 0
            [b, c],     // row 1
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        // Exhaustively verify soundness: for each implication, check every row.
        let rowAttrs: [Set<FormalAttribute>] = [
            [a], [b, c],
        ]
        for impl in result.implications {
            for rowSet in rowAttrs {
                if impl.premise.isSubset(of: rowSet) {
                    #expect(impl.conclusion.isSubset(of: rowSet),
                        "Soundness violation: row \(rowSet) satisfies premise \(impl.premise) but not conclusion \(impl.conclusion)")
                }
            }
        }
    }

    /// Soundness on the three-singleton context where all pairs are pseudo-intents.
    @Test func soundnessOnThreeSingletonContext() {
        let context = FormalContext(rows: [
            [a],   // row 0
            [b],   // row 1
            [c],   // row 2
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        let rowAttrs: [Set<FormalAttribute>] = [[a], [b], [c]]
        for impl in result.implications {
            for rowSet in rowAttrs {
                if impl.premise.isSubset(of: rowSet) {
                    #expect(impl.conclusion.isSubset(of: rowSet),
                        "Soundness violation: row \(rowSet) satisfies \(impl.premise) but not \(impl.conclusion)")
                }
            }
        }
    }

    // MARK: 2. Hand-verified fixtures

    /// Two-row context: Row0:{a}, Row1:{b,c}.
    /// D-G basis: {b}→{c} and {c}→{b}.
    /// (Row0 has only a; no other row has a, so a is irrelevant to these implications.)
    @Test func handVerifiedTwoRowThreeAttribute() {
        let context = FormalContext(rows: [
            [a],        // row 0: {a}
            [b, c],     // row 1: {b, c}
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        #expect(!result.isTruncated)
        // Expected: {b}→{c} and {c}→{b}
        #expect(result.implications.count == 2)
        let premises = result.implications.map { $0.premise }
        #expect(premises.contains(Set([b])))
        #expect(premises.contains(Set([c])))
        // Find each implication and verify conclusion.
        let bImpl = result.implications.first { $0.premise == Set([b]) }
        let cImpl = result.implications.first { $0.premise == Set([c]) }
        #expect(bImpl?.conclusion == Set([c]))
        #expect(cImpl?.conclusion == Set([b]))
    }

    /// Two-row context: Row0:{a,b}, Row1:{b,c}.
    /// closure({}) = {a,b}∩{b,c} = {b} → {} is a pseudo-intent → {}→{b}.
    /// With {}→{b} in the basis, {a}: closure({a})={a,b}≠{a}.
    ///   {a} is D-G pseudo-intent? Check {}: {}⊊{a} and {}''={b}⊆{a}? No.
    ///   So {a} is NOT D-G pseudo-intent.
    /// {c}: closure({c})={b,c}≠{c}. Check {}: {}''={b}⊆{c}? No. NOT D-G pseudo-intent.
    /// D-G basis: {{}→{b}} only.
    @Test func handVerifiedGlobalAttributeContext() {
        // Row0:{a,b}, Row1:{b,c}. b is a global attribute (appears in all rows).
        let context = FormalContext(rows: [
            [a, b],     // row 0
            [b, c],     // row 1
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        #expect(!result.isTruncated)
        // Only one implication: {} → {b}.
        #expect(result.implications.count == 1)
        let impl = result.implications.first
        #expect(impl?.premise == Set())
        #expect(impl?.conclusion == Set([b]))
    }

    /// Context with two disjoint 2-attribute rows: Row0:{a,b}, Row1:{c,d}.
    /// Each single attribute is a pseudo-intent (closure adds the partner),
    /// yielding four implications: {a}→{b}, {b}→{a}, {c}→{d}, {d}→{c}.
    @Test func handVerifiedTwoDisjointPairs() {
        // Row0:{a,b}, Row1:{c,d}.
        let context = FormalContext(rows: [
            [a, b],     // row 0
            [c, d],     // row 1
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        #expect(!result.isTruncated)
        // Expected implications:
        //   {a}→{b}, {b}→{a}, {c}→{d}, {d}→{c}
        // Check: {a,c}→{b,d} is NOT in the D-G basis (it's derivable from {a}→{b} and {c}→{d}).
        #expect(result.implications.count == 4)
        let premises = result.implications.map { $0.premise }
        #expect(premises.contains(Set([a])))
        #expect(premises.contains(Set([b])))
        #expect(premises.contains(Set([c])))
        #expect(premises.contains(Set([d])))
        // Verify conclusions.
        let aImpl = result.implications.first { $0.premise == Set([a]) }
        let bImpl = result.implications.first { $0.premise == Set([b]) }
        let cImpl = result.implications.first { $0.premise == Set([c]) }
        let dImpl = result.implications.first { $0.premise == Set([d]) }
        #expect(aImpl?.conclusion == Set([b]))
        #expect(bImpl?.conclusion == Set([a]))
        #expect(cImpl?.conclusion == Set([d]))
        #expect(dImpl?.conclusion == Set([c]))
    }

    /// Context where all rows are identical: every attribute is global.
    /// Row0:{a,b,c}, Row1:{a,b,c}.
    /// closure({}) = {a,b,c} (all rows share all attributes) → {}→{a,b,c}.
    /// This is the single canonical implication: the empty premise forces
    /// all three attributes (they are "global" in the context).
    @Test func globalAttributesProduceEmptyPremiseImplication() {
        let context = FormalContext(rows: [
            [a, b, c],
            [a, b, c],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        // D-G basis: {} → {a,b,c} (every row has all attributes → global).
        #expect(result.implications.count == 1)
        #expect(!result.isTruncated)
        let impl = result.implications.first
        #expect(impl?.premise == Set())
        #expect(impl?.conclusion == Set([a, b, c]))
    }

    // MARK: 3. Bounding cap behaviour

    /// maxImplications cap: three-singleton context produces 3 implications
    /// (all pairs, size 2). With maxImplications=2: truncated=true, count≤2.
    @Test func maxImplicationsCapTruncates() {
        // Three singletons: each pair is a pseudo-intent.
        let context = FormalContext(rows: [
            [a],   // row 0
            [b],   // row 1
            [c],   // row 2
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 2,
            maxPremiseSize: 100
        )
        #expect(result.isTruncated == true)
        #expect(result.implications.count <= 2)
    }

    /// maxImplications=0: returns empty, truncated=true when pseudo-intents exist.
    @Test func maxImplicationsZeroTruncates() {
        let context = FormalContext(rows: [
            [a],
            [b, c],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 0,
            maxPremiseSize: 100
        )
        #expect(result.implications.isEmpty)
        #expect(result.isTruncated == true)
    }

    /// maxPremiseSize filter: context with size-2 pseudo-intents.
    /// With maxPremiseSize=1: no size-2 premises emitted (only size-0 and size-1).
    @Test func maxPremiseSizeFiltersLargePremises() {
        // Three singletons context: D-G basis has only size-2 premises.
        let context = FormalContext(rows: [
            [a],
            [b],
            [c],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 1
        )
        // All D-G pseudo-intents have premise size 2: none emitted.
        #expect(result.implications.isEmpty)
        // isTruncated should be false: we filtered, not cap-truncated.
        // (The engine enumerates up to maxPremiseSize=1, finds no pseudo-intents
        // of size ≤ 1, so the basis for the bounded range is complete.)
        #expect(!result.isTruncated)
    }

    /// maxPremiseSize=1 with size-1 pseudo-intents present: they ARE emitted.
    @Test func maxPremiseSizeAllowsSize1Premises() {
        // Two-row context: {b}→{c} and {c}→{b} are size-1 pseudo-intents.
        let context = FormalContext(rows: [
            [a],
            [b, c],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 1
        )
        // {b}→{c} and {c}→{b} both have premise size 1 → emitted.
        #expect(result.implications.count == 2)
        #expect(!result.isTruncated)
    }

    // MARK: 4. Edge cases

    /// Empty context: empty basis, no truncation.
    @Test func emptyContextProducesEmptyBasis() {
        let context = FormalContext(rows: [])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        #expect(result.implications.isEmpty)
        #expect(!result.isTruncated)
    }

    /// Single-row context: both attributes are global (every row — the sole row —
    /// carries both). The D-G basis is {} → {a,b}: the empty premise forces
    /// both attributes. No separate {a}→{b} or {b}→{a} because {}→{a,b}
    /// already covers them by Armstrong's augmentation.
    @Test func singleRowContextHasOneImplication() {
        let context = FormalContext(rows: [
            [a, b],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        // D-G basis: {} → {a,b} (both attributes are global in one-row context).
        #expect(result.implications.count == 1)
        #expect(!result.isTruncated)
        let impl = result.implications.first
        #expect(impl?.premise == Set())
        #expect(impl?.conclusion == Set([a, b]))
    }

    /// Context with only one attribute (universe size 1): a is global.
    /// Both rows carry a, so closure({}) = {a} → {} is a pseudo-intent.
    /// The D-G basis is {} → {a}.
    @Test func singleAttributeGlobalImplication() {
        let context = FormalContext(rows: [
            [a],
            [a],
        ])
        let result = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        // D-G basis: {} → {a} (a appears in every row → global attribute).
        #expect(result.implications.count == 1)
        #expect(!result.isTruncated)
        #expect(result.implications.first?.premise == Set())
        #expect(result.implications.first?.conclusion == Set([a]))
    }

    // MARK: 5. Determinism

    /// Two runs on the same input produce identical output.
    @Test func determinismTwoRuns() {
        let context = FormalContext(rows: [
            [a],
            [b, c],
            [a, b],
        ])
        let first = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        let second = ConceptImplications.conceptImplications(
            over: [],
            context: context,
            maxImplications: 100,
            maxPremiseSize: 100
        )
        #expect(first.implications.count == second.implications.count)
        #expect(first.isTruncated == second.isTruncated)
        for (l, r) in zip(first.implications, second.implications) {
            #expect(l.premise == r.premise)
            #expect(l.conclusion == r.conclusion)
        }
    }

    /// Input order of rows does NOT change the implications (same context,
    /// rows in different order, should produce identical result since FCA
    /// is order-independent on rows for the canonical basis).
    @Test func determinismInputOrderIndependent() {
        let rows: [[FormalAttribute]] = [[a], [b, c]]
        let ctx1 = FormalContext(rows: rows)
        let ctx2 = FormalContext(rows: rows.reversed())
        let r1 = ConceptImplications.conceptImplications(over: [], context: ctx1, maxImplications: 100, maxPremiseSize: 100)
        let r2 = ConceptImplications.conceptImplications(over: [], context: ctx2, maxImplications: 100, maxPremiseSize: 100)
        // Same implications, same order.
        #expect(r1.implications.count == r2.implications.count)
        #expect(r1.isTruncated == r2.isTruncated)
        for (l, r) in zip(r1.implications, r2.implications) {
            #expect(l.premise == r.premise)
            #expect(l.conclusion == r.conclusion)
        }
    }
}
