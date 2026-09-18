// RecallSignalBudgetTests.swift
//
// Conformance vectors for `RecallSignalBudget.resolve` (COL-1). The same
// seven vectors are pinned, with the same literal f32 expectations, in
// rust/tests/recall_signal_budget_parity.rs — the two files ARE the shared
// vector. Inputs are the un-normalised adaptive base weights (locus 0.2,
// bm25 0.3, vector 0.3, matrix 0.1, fieldFit 0.1, diversity 0.1, graph 0.1)
// so the arithmetic is readable: total budget 1.2 (preference draws the
// graph slice a second time).
//
//   V1 neutral (no key, no absence)         → byte-identical to the weights, ρ 1.
//   V2 signal:matrix = 0                     → factor ρ 1.2/1.1, matrix 0.
//   V3 fieldFit+graph+preference ABSENT      → factor ρ 1.2/0.9, three zeros.
//   V4 signal:agreement = 0                  → agreement 0, budgets unchanged.
//   V5 signal:graph = -1                     → graph −0.1, NO redistribution.
//   V6 signal:bm25 = 2                       → bm25 0.6, NO redistribution.
//   V7 every budgeted column excluded        → all 0, factor ρ 1 (no div-by-zero).
// ρ is `redistribution`, the factor step 10 scales the MMR similarity term by.

import Testing
@testable import GeniusLocusKit

@Suite("RecallSignalBudget conformance vectors (COL-1)")
struct RecallSignalBudgetTests {

    private let weights = RecallWeights(
        locus: 0.2, bm25: 0.3, vector: 0.3, matrix: 0.1,
        fieldFit: 0.1, diversity: 0.1, graph: 0.1)

    private func resolve(_ keys: [String: Float],
                         absent: Set<RecallSignalBudget.Column> = []) -> RecallSignalBudget {
        RecallSignalBudget.resolve(weights: weights,
                                   signalWeight: { keys[$0] ?? 1.0 },
                                   absentColumns: absent)
    }

    private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= 1e-6 }

    @Test("V1 neutral: byte-identical to the adaptive weights")
    func v1Neutral() {
        let b = resolve([:])
        #expect(b.redistribution == 1.0)
        #expect(b.locus == weights.locus)
        #expect(b.bm25 == weights.bm25)
        #expect(b.vector == weights.vector)
        #expect(b.fieldFit == weights.fieldFit)
        #expect(b.matrix == weights.matrix)
        #expect(b.graph == weights.graph)
        #expect(b.preference == weights.graph)
        #expect(b.agreement == 1.0)
        #expect(b.excluded.isEmpty)
    }

    @Test("V2 signal:matrix = 0 excludes matrix and redistributes 1.2/1.1")
    func v2ExcludeMatrix() {
        let b = resolve([RecallShape.SignalKey.matrix: 0])
        #expect(near(b.redistribution, 1.0909091))
        #expect(near(b.locus, 0.21818183))
        #expect(near(b.bm25, 0.32727274))
        #expect(near(b.vector, 0.32727274))
        #expect(near(b.fieldFit, 0.10909092))
        #expect(b.matrix == 0)
        #expect(near(b.graph, 0.10909092))
        #expect(near(b.preference, 0.10909092))
        #expect(b.agreement == 1.0)
        #expect(b.excluded == [.matrix])
    }

    @Test("V3 absent fieldFit+graph+preference redistribute 1.2/0.9")
    func v3AbsentColumns() {
        let b = resolve([:], absent: [.fieldFit, .graph, .preference])
        #expect(near(b.redistribution, 1.3333334))
        #expect(near(b.locus, 0.26666668))
        #expect(near(b.bm25, 0.40000004))
        #expect(near(b.vector, 0.40000004))
        #expect(b.fieldFit == 0)
        #expect(near(b.matrix, 0.13333334))
        #expect(b.graph == 0)
        #expect(b.preference == 0)
        #expect(b.excluded == [.fieldFit, .graph, .preference])
    }

    @Test("V4 signal:agreement = 0 drops the bonus and redistributes nothing")
    func v4ExcludeAgreement() {
        let b = resolve([RecallShape.SignalKey.agreement: 0])
        #expect(b.agreement == 0)
        #expect(b.locus == weights.locus)
        #expect(b.bm25 == weights.bm25)
        #expect(b.matrix == weights.matrix)
        #expect(b.excluded == [.agreement])
    }

    @Test("V5 signal:graph = -1 suppresses without redistribution")
    func v5Suppress() {
        let b = resolve([RecallShape.SignalKey.graph: -1])
        #expect(near(b.graph, -0.1))
        #expect(b.locus == weights.locus)
        #expect(b.preference == weights.graph)
        #expect(b.excluded.isEmpty)
    }

    @Test("V6 signal:bm25 = 2 scales without redistribution")
    func v6Scale() {
        let b = resolve([RecallShape.SignalKey.bm25: 2])
        #expect(near(b.bm25, 0.6))
        #expect(b.locus == weights.locus)
        #expect(b.vector == weights.vector)
        #expect(b.excluded.isEmpty)
    }

    @Test("V7 every budgeted column excluded: all zero, no division by zero")
    func v7AllExcluded() {
        let keys = Dictionary(uniqueKeysWithValues:
            RecallShape.SignalKey.all.filter { $0 != RecallShape.SignalKey.agreement }.map { ($0, Float(0)) })
        let b = resolve(keys)
        #expect(b.locus == 0 && b.bm25 == 0 && b.vector == 0 && b.fieldFit == 0)
        #expect(b.matrix == 0 && b.graph == 0 && b.preference == 0)
        #expect(b.agreement == 1.0)
        #expect(b.redistribution == 1.0)
        #expect(b.excluded.count == 7)
    }

    @Test("SignalKey.all spells every column key in step-9 order")
    func keysMatchColumns() {
        #expect(RecallShape.SignalKey.all == RecallSignalBudget.Column.allCases.map(\.laneKey))
    }
}
