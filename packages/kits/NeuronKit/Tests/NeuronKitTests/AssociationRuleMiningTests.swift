// AssociationRuleMiningTests.swift
//
// Conformance and edge-case tests for `mineAssociationRules`, the
// pairwise association-rule mining engine over MatrixO. The tests use
// fixed, hand-constructed matrices (built through `MatrixO.applyRow`,
// the same update rule the substrate uses) so every metric is
// hand-computable from the row counts.
//
// These tests are the Rust version's conformance contract too: the
// `association_rule_mining.rs` inline tests encode the IDENTICAL
// input cases and expected outputs, and the packed-key emission
// order documented here must reproduce exactly across versions.
//
// Float tolerance: expected values are encoded as the same exact
// fraction expressions the engine computes (IEEE-754 double division
// of small integers is deterministic), asserted with an absolute
// tolerance of 1e-12 to keep the contract explicit.

import Testing
import SubstrateTypes
@testable import NeuronKit

@Suite("mineAssociationRules pairwise mining")
struct AssociationRuleMiningTests {

    // MARK: - Fixtures
    //
    // Items (packed key = field<<8 | value):
    //   A = (field 0, value 1)  packed 0x0001
    //   B = (field 5, value 3)  packed 0x0503
    //   C = (field 5, value 4)  packed 0x0504
    //
    // Main fixture — N = 10 active rows:
    //   4 rows {A, B}, 2 rows {A, C}, 2 rows {B}, 1 row {A}, 1 row {}
    //
    // MatrixO counts (applyRow writes every ordered pair incl. diagonal):
    //   O[A,A] = 4+2+1 = 7    O[B,B] = 4+2 = 6    O[C,C] = 2
    //   O[A,B] = O[B,A] = 4   O[A,C] = O[C,A] = 2  O[B,C] = 0 (absent)
    //
    // Hand-computed rules at thresholds (0, 0), N = 10:
    //   A→B: support 4/10, confidence 4/7,  lift 40/42,
    //        leverage 4/10 − (7/10)(6/10) = −0.02,
    //        conviction (1 − 6/10)/(1 − 4/7) = 0.4/(3/7)
    //   A→C: support 2/10, confidence 2/7,  lift 20/14,
    //        leverage 2/10 − (7/10)(2/10) = 0.06,
    //        conviction (1 − 2/10)/(1 − 2/7) = 0.8/(5/7)
    //   B→A: support 4/10, confidence 4/6,  lift 40/42,
    //        leverage −0.02,
    //        conviction (1 − 7/10)/(1 − 4/6) = 0.3/(1/3)
    //   C→A: support 2/10, confidence 2/2 = 1 → conviction +inf,
    //        lift 20/14, leverage 0.06
    //
    // Emission order (ascending packed (antecedent, consequent)):
    //   [A→B, A→C, B→A, C→A]

    private let itemA = Item(field: 0, value: 1)
    private let itemB = Item(field: 5, value: 3)
    private let itemC = Item(field: 5, value: 4)

    private let rowA: [(field: UInt8, value: UInt8)] = [(0, 1)]
    private let rowB: [(field: UInt8, value: UInt8)] = [(5, 3)]
    private let rowAB: [(field: UInt8, value: UInt8)] = [(0, 1), (5, 3)]
    private let rowAC: [(field: UInt8, value: UInt8)] = [(0, 1), (5, 4)]

    /// Accumulates rows into a MatrixO through the substrate's own
    /// update rule (delta +1 per row, all ordered pairs incl. diagonal).
    private func matrix(rows: [[(field: UInt8, value: UInt8)]]) -> MatrixO {
        var o = MatrixO()
        for row in rows {
            o.applyRow(delta: 1, fieldValues: row)
        }
        return o
    }

    /// Main fixture: 4×{A,B}, 2×{A,C}, 2×{B}, 1×{A} — 9 populated rows;
    /// N = 10 counts one additional active row with no mined fields.
    private func mainMatrix() -> MatrixO {
        matrix(rows: [rowAB, rowAB, rowAB, rowAB, rowAC, rowAC, rowB, rowB, rowA])
    }

    private let zeroThresholds = MiningThresholds(minSupport: 0, minConfidence: 0)

    /// Documented float tolerance for metric comparisons.
    private static let tolerance = 1e-12

    private func expectClose(
        _ actual: Double, _ expected: Double,
        _ label: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if expected.isInfinite {
            #expect(actual == expected, label, sourceLocation: sourceLocation)
        } else {
            #expect(abs(actual - expected) < Self.tolerance, label,
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - 1. Empty matrix

    @Test("empty matrix yields no rules")
    func emptyMatrixYieldsNoRules() {
        let out = mineAssociationRules(
            matrix: MatrixO(), activeRowCount: 10, thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    // MARK: - 2. Single co-occurring pair — all five metrics

    @Test("single co-occurring pair carries all five hand-computed metrics")
    func singlePairAllFiveMetrics() {
        // N = 4: 2 rows {A,B}, 1 row {A}, 1 row {B}.
        //   O[A,A] = 3, O[B,B] = 3, O[A,B] = O[B,A] = 2.
        //   A→B (B→A is symmetric here):
        //     support    = 2/4  = 0.5
        //     confidence = 2/3
        //     lift       = (2·4)/(3·3) = 8/9
        //     leverage   = 2/4 − (3/4)(3/4) = −0.0625
        //     conviction = (1 − 3/4)/(1 − 2/3) = 0.25/(1/3) = 0.75
        let o = matrix(rows: [rowAB, rowAB, rowA, rowB])
        let out = mineAssociationRules(
            matrix: o, activeRowCount: 4, thresholds: zeroThresholds)

        #expect(out.count == 2)
        #expect(out[0].antecedent == itemA && out[0].consequent == itemB)
        #expect(out[1].antecedent == itemB && out[1].consequent == itemA)

        for rule in out {
            expectClose(rule.support, 2.0 / 4.0, "support")
            expectClose(rule.confidence, 2.0 / 3.0, "confidence")
            expectClose(rule.lift, 8.0 / 9.0, "lift")
            expectClose(rule.leverage, 2.0 / 4.0 - (3.0 / 4.0) * (3.0 / 4.0), "leverage")
            expectClose(rule.conviction, (1.0 - 3.0 / 4.0) / (1.0 - 2.0 / 3.0), "conviction")
        }
    }

    // MARK: - 3. confidence == 1 → conviction == +inf

    @Test("confidence == 1 yields +infinite conviction")
    func confidenceOneYieldsInfiniteConviction() {
        // Main fixture: C occurs in 2 rows, both with A → O[C,A] = O[C,C] = 2,
        // so confidence(C→A) = 1 exactly and conviction is +inf.
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10, thresholds: zeroThresholds)
        let cToA = out.first { $0.antecedent == itemC && $0.consequent == itemA }
        let rule = try! #require(cToA)
        expectClose(rule.confidence, 1.0, "confidence")
        #expect(rule.conviction == .infinity)
        expectClose(rule.support, 2.0 / 10.0, "support")
        expectClose(rule.lift, 20.0 / 14.0, "lift")
        expectClose(rule.leverage, 2.0 / 10.0 - (2.0 / 10.0) * (7.0 / 10.0), "leverage")
    }

    // MARK: - 4. Threshold gating

    @Test("minSupport gates: one rule pair passes, the other is dropped")
    func minSupportGates() {
        // support(A→B) = support(B→A) = 0.4 ≥ 0.3 → pass.
        // support(A→C) = support(C→A) = 0.2 < 0.3 → dropped.
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10,
            thresholds: MiningThresholds(minSupport: 0.3, minConfidence: 0))
        #expect(out.map { [$0.antecedent, $0.consequent] } ==
                [[itemA, itemB], [itemB, itemA]])
    }

    @Test("minConfidence gates: low-confidence rules are dropped")
    func minConfidenceGates() {
        // confidence: A→B = 4/7 ≈ .571 (drop), A→C = 2/7 ≈ .286 (drop),
        //             B→A = 4/6 ≈ .667 (pass), C→A = 1.0 (pass).
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10,
            thresholds: MiningThresholds(minSupport: 0, minConfidence: 0.6))
        #expect(out.map { [$0.antecedent, $0.consequent] } ==
                [[itemB, itemA], [itemC, itemA]])
    }

    // MARK: - 5. N <= 0

    @Test("N == 0 yields no rules")
    func zeroActiveRowCountYieldsNoRules() {
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 0, thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    @Test("negative N yields no rules")
    func negativeActiveRowCountYieldsNoRules() {
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: -5, thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    // MARK: - 6. Diagonal-only matrix

    @Test("diagonal-only matrix (single item, no co-occurrence) yields no rules")
    func diagonalOnlyYieldsNoRules() {
        // One row with one item: O[A,A] = 1 is the only cell. The
        // diagonal stores support but is excluded from emission.
        let out = mineAssociationRules(
            matrix: matrix(rows: [rowA]), activeRowCount: 1,
            thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    // MARK: - 7. Missing single-item support (engine guards)

    @Test("off-diagonal cell without antecedent diagonal is skipped")
    func missingAntecedentSupportSkips() {
        // Hand-built matrix: O[A,B] exists but neither diagonal does
        // (impossible via applyRow; reachable through decay/expunge
        // imbalance). Both the O[A,A]==0 and O[B,B]==0 guards skip.
        var o = MatrixO()
        o.increment(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 5, valueJ: 3), by: 2)
        let out = mineAssociationRules(
            matrix: o, activeRowCount: 10, thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    @Test("off-diagonal cell without consequent diagonal is skipped")
    func missingConsequentSupportSkips() {
        // O[A,B] and O[A,A] exist, O[B,B] does not → consequent guard.
        var o = MatrixO()
        o.increment(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 0, valueJ: 1), by: 2)
        o.increment(CooccurrenceKey(fieldI: 0, valueI: 1, fieldJ: 5, valueJ: 3), by: 2)
        let out = mineAssociationRules(
            matrix: o, activeRowCount: 10, thresholds: zeroThresholds)
        #expect(out.isEmpty)
    }

    // MARK: - 8. Emission order

    @Test("rules emit in ascending packed (antecedent, consequent) order")
    func emissionOrderIsPackedKeyAscending() {
        // Main fixture at zero thresholds emits all four rules in
        // exactly this sequence — the conformance anchor for ordering:
        //   (A,B) 0x0001→0x0503, (A,C) 0x0001→0x0504,
        //   (B,A) 0x0503→0x0001, (C,A) 0x0504→0x0001.
        let out = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10, thresholds: zeroThresholds)
        #expect(out.map { [$0.antecedent, $0.consequent] } == [
            [itemA, itemB],
            [itemA, itemC],
            [itemB, itemA],
            [itemC, itemA],
        ])

        // Full metric sweep over the ordered result, against the
        // worked values in the fixture comment.
        expectClose(out[0].support, 4.0 / 10.0, "A→B support")
        expectClose(out[0].confidence, 4.0 / 7.0, "A→B confidence")
        expectClose(out[0].lift, 40.0 / 42.0, "A→B lift")
        expectClose(out[0].leverage, 4.0 / 10.0 - (7.0 / 10.0) * (6.0 / 10.0), "A→B leverage")
        expectClose(out[0].conviction, (1.0 - 6.0 / 10.0) / (1.0 - 4.0 / 7.0), "A→B conviction")

        expectClose(out[1].support, 2.0 / 10.0, "A→C support")
        expectClose(out[1].confidence, 2.0 / 7.0, "A→C confidence")
        expectClose(out[1].lift, 20.0 / 14.0, "A→C lift")
        expectClose(out[1].leverage, 2.0 / 10.0 - (7.0 / 10.0) * (2.0 / 10.0), "A→C leverage")
        expectClose(out[1].conviction, (1.0 - 2.0 / 10.0) / (1.0 - 2.0 / 7.0), "A→C conviction")

        expectClose(out[2].support, 4.0 / 10.0, "B→A support")
        expectClose(out[2].confidence, 4.0 / 6.0, "B→A confidence")
        expectClose(out[2].lift, 40.0 / 42.0, "B→A lift")
        expectClose(out[2].leverage, 4.0 / 10.0 - (6.0 / 10.0) * (7.0 / 10.0), "B→A leverage")
        expectClose(out[2].conviction, (1.0 - 7.0 / 10.0) / (1.0 - 4.0 / 6.0), "B→A conviction")

        expectClose(out[3].support, 2.0 / 10.0, "C→A support")
        expectClose(out[3].confidence, 1.0, "C→A confidence")
        expectClose(out[3].lift, 20.0 / 14.0, "C→A lift")
        expectClose(out[3].leverage, 2.0 / 10.0 - (2.0 / 10.0) * (7.0 / 10.0), "C→A leverage")
        #expect(out[3].conviction == .infinity)
    }

    // MARK: - 9. Determinism

    @Test("two runs are identical")
    func twoRunsAreIdentical() {
        let first = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10, thresholds: zeroThresholds)
        let second = mineAssociationRules(
            matrix: mainMatrix(), activeRowCount: 10, thresholds: zeroThresholds)
        #expect(first == second)
    }
}
