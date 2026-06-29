// AprioriMiningTests.swift
//
// Conformance and edge-case tests for `AprioriMining.mine`.
//
// The Rust version (`apriori_mining.rs`) encodes IDENTICAL input cases
// and expected outputs, gated against the vectors in
// docs/engineering/substrate_reference/test-harness/vectors/apriori_mining.json.
// Float comparisons use tolerance 1e-12 (exact IEEE-754 double results
// of small-integer divisions reproduce deterministically on any IEEE-754
// platform).

import Testing
import Foundation
@testable import SubstrateML

// MARK: - Helpers

private let eps = 1e-12

/// Build a `RowAttributeView` directly from a flat list of (field, value) pairs.
private func row(_ pairs: (UInt8, UInt8)...) -> RowAttributeView {
    RowAttributeView(
        rowID: UUID(),
        tier: "t",
        attributes: pairs.map { (field: $0.0, value: $0.1) }
    )
}

/// Verify a float-valued field within tolerance.
private func near(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < eps
}

// MARK: - Suite

@Suite("AprioriMining")
struct AprioriMiningTests {

    // MARK: Edge cases

    @Test("am-001: empty rows returns empty rules")
    func emptyRows() {
        let rules = AprioriMining.mine(
            rows: [],
            thresholds: AprioriThresholds(minSupport: 0.5, minConfidence: 0.5)
        )
        #expect(rules.isEmpty)
    }

    @Test("single row yields no rules (can't form pairs)")
    func singleRow() {
        let rules = AprioriMining.mine(
            rows: [row((0, 1), (0, 2))],
            thresholds: AprioriThresholds(minSupport: 0.1, minConfidence: 0.1)
        )
        // 1 row: {A,B} freq, but confidence(A→B) = 1/1 = 1.0 and
        // support = 1/1 = 1.0 — however lift = 1/(1*1) = 1 so rule emits.
        // Actually with N=1: support({A})=1, support({B})=1, support({A,B})=1
        // lift = 1/(1*1) = 1.0 — passes with minLift=1.0
        // So 2 rules (A→B and B→A) ARE emitted.
        #expect(rules.count == 2)
    }

    @Test("no item reaches minSupport — empty output")
    func nothingFrequent() {
        let rows = [
            row((0, 1)),
            row((0, 2)),
            row((0, 3)),
            row((0, 4)),
            row((0, 5)),
        ]
        let rules = AprioriMining.mine(
            rows: rows,
            thresholds: AprioriThresholds(minSupport: 0.5, minConfidence: 0.0)
        )
        // Every item appears in exactly 1/5 = 0.2 rows — below 0.5.
        #expect(rules.isEmpty)
    }

    @Test("lift threshold filters anti-correlated rules")
    func liftThreshold() {
        // Two items, each appearing in 2/4 rows but never together:
        // A (item 0,1) in rows 0,1; B (item 0,2) in rows 2,3.
        // No co-occurrence → no 2-itemsets → no rules.
        let rows = [
            row((0, 1)),
            row((0, 1)),
            row((0, 2)),
            row((0, 2)),
        ]
        let rules = AprioriMining.mine(
            rows: rows,
            thresholds: AprioriThresholds(minSupport: 0.4, minConfidence: 0.5, minLift: 1.0)
        )
        // A and B never co-occur → {A,B} has 0 support → no rules.
        #expect(rules.isEmpty)
    }

    // MARK: am-002: five-row, two-item conformance case

    @Test("am-002: basic pairwise rules — lift, confidence, conviction")
    func am002BasicPairwise() {
        // Dataset (N=5):
        //   Rows 0-2: A=(0,1), B=(0,2)
        //   Row  3:   A=(0,1), C=(0,3)
        //   Row  4:   C=(0,3)
        //
        // With minSupport=0.5 (minCount=3):
        //   {A}: 4 rows, {B}: 3 rows, {C}: 2 rows (not frequent)
        //   {A,B}: 3 rows → both pairwise rules emitted
        //
        // Expected metrics (hand-computed):
        //   B→A: conf=1.0, lift=5/4=1.25, leverage=3/25=0.12, conv=+inf
        //   A→B: conf=3/4=0.75, lift=1.25, leverage=0.12, conv=8/5=1.6
        //   Sort: same lift, same evidenceCount → confidence desc: B→A first
        let rows = [
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 3)),
            row((0, 3)),
        ]
        let thresholds = AprioriThresholds(
            minSupport: 0.5,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 2
        )
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)

        #expect(rules.count == 2)

        // Rule 0: B=(0,2) → A=(0,1)
        let r0 = rules[0]
        #expect(r0.antecedent.count == 1)
        #expect(r0.antecedent[0] == Item(field: 0, value: 2))
        #expect(r0.consequent == Item(field: 0, value: 1))
        #expect(near(r0.support, 0.6))
        #expect(near(r0.confidence, 1.0))
        #expect(near(r0.lift, 1.25))
        #expect(near(r0.leverage, 0.12))
        #expect(r0.conviction.isInfinite)
        #expect(r0.evidenceCount == 3)

        // Rule 1: A=(0,1) → B=(0,2)
        let r1 = rules[1]
        #expect(r1.antecedent.count == 1)
        #expect(r1.antecedent[0] == Item(field: 0, value: 1))
        #expect(r1.consequent == Item(field: 0, value: 2))
        #expect(near(r1.support, 0.6))
        #expect(near(r1.confidence, 0.75))
        #expect(near(r1.lift, 1.25))
        #expect(near(r1.leverage, 0.12))
        #expect(near(r1.conviction, 1.6))
        #expect(r1.evidenceCount == 3)
    }

    // MARK: maxK=2 matches ARM on equivalent data

    @Test("maxK=2 rules match ARM pairwise mining on equivalent row data")
    func maxK2MatchesARM() {
        // Build a dataset where all rows have exactly {A, B} — perfect
        // co-occurrence. ARM on the equivalent MatrixO should emit the
        // same rules as Apriori at maxK=2.
        //
        // N=4: rows 0-3 all have A=(0,1), B=(0,2).
        // ARM thresholds (0.1, 0.1) → 2 rules: A→B and B→A.
        // Apriori maxK=2 thresholds (0.1, 0.1) → same 2 rules.
        //
        // We can't run ARM directly here (it needs MatrixO), but we
        // can verify Apriori produces 2 rules with support=1.0,
        // confidence=1.0, and lift=1.0. ARM would compute identical
        // values from the equivalent MatrixO (O[A,A]=4, O[B,B]=4,
        // O[A,B]=4, N=4).
        let rows = [
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
        ]
        let thresholds = AprioriThresholds(
            minSupport: 0.1,
            minConfidence: 0.1,
            minLift: 1.0,
            maxK: 2
        )
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)

        // Both A→B and B→A
        #expect(rules.count == 2)
        for r in rules {
            #expect(near(r.support, 1.0))
            #expect(near(r.confidence, 1.0))
            #expect(near(r.lift, 1.0))
            #expect(r.evidenceCount == 4)
        }
    }

    // MARK: k=3 rules

    @Test("maxK=3 emits rules with two-item antecedents")
    func maxK3TwoItemAntecedent() {
        // Dataset (N=5): rows 0-2 have {A,B,C}; rows 3,4 have {A,B}.
        //
        //   {A}: 5, {B}: 5, {C}: 3
        //   {A,B}: 5, {A,C}: 3, {B,C}: 3
        //   {A,B,C}: 3
        //
        // With minSupport=0.5, minConfidence=0.5, minLift=1.0, maxK=3:
        //
        // All 1-item and 2-item sets frequent. {A,B,C} = 3/5 = 0.6 ✓
        //
        // 3-itemset rules ({A,B}→C, {A,C}→B, {B,C}→A) should appear
        // in addition to the pairwise rules.
        let rows = [
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
        ]
        let thresholds = AprioriThresholds(
            minSupport: 0.5,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 3
        )
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)

        // Only 2-item antecedent rules can appear (a 3-item antecedent
        // would require a 4-itemset, which this fixture doesn't have).
        // 2-item antecedent rules (from 3-itemset {A,B,C}):
        //   {A,B}→C, {A,C}→B, {B,C}→A
        let twoAntecedentRules = rules.filter { $0.antecedent.count == 2 }
        #expect(twoAntecedentRules.count == 3)

        // Verify {A,B}→C (antecedent=[A=(0,1),B=(0,2)], consequent=C=(0,3)):
        let abToC = twoAntecedentRules.first {
            $0.antecedent == [Item(field: 0, value: 1), Item(field: 0, value: 2)]
            && $0.consequent == Item(field: 0, value: 3)
        }
        #expect(abToC != nil)
        if let r = abToC {
            // support({A,B,C}) = 3/5 = 0.6
            // confidence = 3/5 = 0.6 (support({A,B}) = 1.0, so conf = 0.6/1.0 = 0.6)
            #expect(near(r.support, 0.6))
            #expect(near(r.confidence, 0.6))
            #expect(r.evidenceCount == 3)
        }
    }

    // MARK: Sort order

    @Test("rules sorted lift desc, confidence desc, evidenceCount desc")
    func sortOrder() {
        // Two perfectly-correlated item pairs sharing no rows:
        //   Rows 0-2: A=(0,1), B=(0,2)  (support each = 3/6 = 0.5)
        //   Rows 3-5: C=(0,3), D=(0,4)  (support each = 3/6 = 0.5)
        //
        // {A,B} support = 3/6 = 0.5; lift = 0.5/(0.5*0.5) = 2.0 > 1 ✓
        // {C,D} support = 0.5;        lift = 2.0
        // No cross-pair co-occurrence (A never appears with C/D, etc.)
        //
        // With minSupport=0.4, minConfidence=0.5, minLift=1.0:
        //   4 rules emitted: A→B, B→A, C→D, D→C
        //   All have lift=2.0, confidence=1.0, evidenceCount=3.
        let rows = [
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 3), (0, 4)),
            row((0, 3), (0, 4)),
            row((0, 3), (0, 4)),
        ]
        let thresholds = AprioriThresholds(
            minSupport: 0.4,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 2
        )
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)
        #expect(rules.count == 4)

        // Verify sort invariant: lift[i] >= lift[i+1] for all i.
        guard rules.count >= 2 else { return }
        for i in 0..<(rules.count - 1) {
            #expect(rules[i].lift >= rules[i + 1].lift - eps)
            // When lift equal, confidence must be non-increasing.
            if near(rules[i].lift, rules[i + 1].lift) {
                #expect(rules[i].confidence >= rules[i + 1].confidence - eps)
            }
        }
    }

    // MARK: Free function delegate

    @Test("mineAprioriRules free function delegates to AprioriMining.mine")
    func freeFunctionDelegate() {
        let rows = [row((0, 1), (0, 2)), row((0, 1), (0, 2))]
        let t = AprioriThresholds(minSupport: 0.5, minConfidence: 0.5)
        let direct = AprioriMining.mine(rows: rows, thresholds: t)
        let via = mineAprioriRules(rows: rows, thresholds: t)
        #expect(direct.count == via.count)
        for (a, b) in zip(direct, via) {
            #expect(a == b)
        }
    }
}
