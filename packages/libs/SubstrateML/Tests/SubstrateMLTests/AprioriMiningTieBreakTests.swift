// AprioriMiningTieBreakTests.swift
//
// Deterministic tie-break tests for AprioriMining.
//
// The Apriori engine generates rules from frequent itemsets and sorts
// them by lift ↓, confidence ↓, evidenceCount ↓. When two or more
// rules share identical values for all three metrics, the prior
// implementation broke ties by hash order — which is undefined and
// differs between Swift and Rust dictionary implementations.
//
// Fix: a fourth sort key breaks ties lexicographically by
// (antecedent packed keys ↑, consequent packed key ↑). This makes
// the output a total order: identical inputs always produce identical
// output across runs and across ports.
//
// Also: the frequent-itemset extraction loop now iterates in
// canonical sorted order (not dictionary hash order), so rule
// generation order is deterministic even before the sort.
//
// The maxK=2 ARM-equivalence invariant is validated by the existing
// `am-002` case in AprioriMiningTests.swift, which passes the same
// fixture through Apriori and checks exact metric values; those tests
// continue to pass after the tie-break addition (no metrics change).
//
// Conformance vector: docs/engineering/substrate_reference/test-harness/
//   vectors/apriori_tiebreak.json

import Foundation
import Testing
@testable import SubstrateML

// MARK: - Helpers

private func row(_ pairs: (UInt8, UInt8)...) -> RowAttributeView {
    RowAttributeView(
        rowID: UUID(),
        tier: "t",
        attributes: pairs.map { (field: $0.0, value: $0.1) }
    )
}

@Suite("AprioriMining deterministic tie-break")
struct AprioriMiningTieBreakTests {

    // MARK: - Determinism across repeated calls

    @Test("same input produces identical output across two calls")
    func deterministicAcrossCalls() {
        // Dataset: A, B, C always appear together with maxK=2 → 6 pairwise rules,
        // all with identical metrics (lift=1.0, confidence=1.0, evidenceCount=3).
        // Identical metrics trigger the lexicographic tie-break on every comparison.
        let rows = [
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
        ]
        let thresholds = AprioriThresholds(minSupport: 0.5, minConfidence: 0.5,
                                           minLift: 1.0, maxK: 2)
        let r1 = AprioriMining.mine(rows: rows, thresholds: thresholds)
        let r2 = AprioriMining.mine(rows: rows, thresholds: thresholds)
        #expect(r1.count == r2.count)
        for (a, b) in zip(r1, r2) {
            #expect(a.antecedent == b.antecedent)
            #expect(a.consequent == b.consequent)
        }
    }

    // MARK: - Lexicographic tie-break order

    @Test("equal-metric rules resolve in ascending lexicographic antecedent/consequent order")
    func lexicographicTieBreakOrder() {
        // Dataset: A=(0,1), B=(0,2), C=(0,3) always together. maxK=2 limits
        // output to pairwise rules (equivalent to ARM surface).
        // All pairwise rules: lift = P(AB)/(P(A)*P(B)) = 1/(1*1) = 1.0,
        // confidence = 1.0, evidenceCount = 3. All six rules share identical
        // metrics → tie-break fires on every comparison.
        //
        // Packed keys: A.packed = (0<<8)|1 = 1, B.packed = 2, C.packed = 3.
        // Expected sort order (ascending antecedent packed key, then consequent):
        //   [A→B, A→C, B→A, B→C, C→A, C→B]
        let rows = [
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
            row((0, 1), (0, 2), (0, 3)),
        ]
        let thresholds = AprioriThresholds(minSupport: 0.5, minConfidence: 0.5,
                                           minLift: 1.0, maxK: 2)
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)

        #expect(rules.count == 6,
                "expected 6 equal-metric pairwise rules, got \(rules.count)")

        // Rule 0: A=(0,1) → B=(0,2)
        #expect(rules[0].antecedent == [Item(field: 0, value: 1)])
        #expect(rules[0].consequent == Item(field: 0, value: 2))

        // Rule 1: A=(0,1) → C=(0,3)
        #expect(rules[1].antecedent == [Item(field: 0, value: 1)])
        #expect(rules[1].consequent == Item(field: 0, value: 3))

        // Rule 2: B=(0,2) → A=(0,1)
        #expect(rules[2].antecedent == [Item(field: 0, value: 2)])
        #expect(rules[2].consequent == Item(field: 0, value: 1))

        // Rule 3: B=(0,2) → C=(0,3)
        #expect(rules[3].antecedent == [Item(field: 0, value: 2)])
        #expect(rules[3].consequent == Item(field: 0, value: 3))

        // Rule 4: C=(0,3) → A=(0,1)
        #expect(rules[4].antecedent == [Item(field: 0, value: 3)])
        #expect(rules[4].consequent == Item(field: 0, value: 1))

        // Rule 5: C=(0,3) → B=(0,2)
        #expect(rules[5].antecedent == [Item(field: 0, value: 3)])
        #expect(rules[5].consequent == Item(field: 0, value: 2))

        // Verify total-order property: identical output on repeated call.
        let r2 = AprioriMining.mine(rows: rows, thresholds: thresholds)
        for (a, b) in zip(rules, r2) {
            #expect(a.antecedent == b.antecedent)
            #expect(a.consequent == b.consequent)
        }
    }

    // MARK: - maxK=2 output is unchanged post-tie-break

    @Test("maxK=2 am-002 fixture metrics unchanged after tie-break addition")
    func maxK2MetricsUnchanged() {
        // The am-002 conformance fixture from AprioriMiningTests. Verifies that
        // the tie-break sort key leaves the two-rule output of the canonical
        // fixture unchanged (both rules differ in confidence, so the 4th key
        // never fires here — this confirms no regression).
        let rows = [
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 2)),
            row((0, 1), (0, 3)),
            row((0, 3)),
        ]
        let thresholds = AprioriThresholds(minSupport: 0.5, minConfidence: 0.5, minLift: 1.0, maxK: 2)
        let rules = AprioriMining.mine(rows: rows, thresholds: thresholds)

        #expect(rules.count == 2)

        // Rule 0: B=(0,2) → A=(0,1), confidence=1.0, lift=1.25
        #expect(rules[0].antecedent == [Item(field: 0, value: 2)])
        #expect(rules[0].consequent == Item(field: 0, value: 1))
        #expect(abs(rules[0].confidence - 1.0) < 1e-12)
        #expect(abs(rules[0].lift - 1.25) < 1e-12)

        // Rule 1: A=(0,1) → B=(0,2), confidence=0.75, lift=1.25
        #expect(rules[1].antecedent == [Item(field: 0, value: 1)])
        #expect(rules[1].consequent == Item(field: 0, value: 2))
        #expect(abs(rules[1].confidence - 0.75) < 1e-12)
        #expect(abs(rules[1].lift - 1.25) < 1e-12)
    }
}
