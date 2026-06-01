// ActionOutcomeMatrixTests.swift
//
// Action-outcome matrix per cookbook § 6.5. swift-testing peer suite
// for Sources/SubstrateML/ActionOutcomeMatrix.swift.
//
// rust/src/action_outcome.rs carries NO #[test], so this suite
// asserts the documented behavior set: observation accumulation,
// empirical success rate, the conservative Wilson lower bound, and
// the Wilson-ranked topActions selection (under-observed cells must
// not float to the top).

import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("ActionOutcomeMatrix")
struct ActionOutcomeMatrixTests {

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }

    @Test("a fresh matrix has no populated cells and nil success rates")
    func emptyMatrix() {
        let m = ActionOutcomeMatrix()
        #expect(m.populatedCellCount == 0)
        #expect(m.successRate(action: 1, outcome: 2) == nil)
        #expect(m.observationCount(action: 1, outcome: 2) == 0)
    }

    @Test("observe accumulates totals and successes")
    func observeAccumulates() {
        var m = ActionOutcomeMatrix()
        m.observe(action: 3, outcome: 1, success: true, at: hlc(10))
        m.observe(action: 3, outcome: 1, success: false, at: hlc(20))
        m.observe(action: 3, outcome: 1, success: true, at: hlc(30))
        #expect(m.observationCount(action: 3, outcome: 1) == 3)
        #expect(m.successRate(action: 3, outcome: 1) == Float32(2) / Float32(3))
        #expect(m.populatedCellCount == 1)
    }

    @Test("distinct (action, outcome) pairs occupy distinct cells")
    func distinctCells() {
        var m = ActionOutcomeMatrix()
        m.observe(action: 1, outcome: 1, success: true, at: hlc(1))
        m.observe(action: 1, outcome: 2, success: true, at: hlc(2))
        m.observe(action: 2, outcome: 1, success: true, at: hlc(3))
        #expect(m.populatedCellCount == 3)
    }

    @Test("an all-success cell has rate 1.0 but a Wilson bound below it")
    func wilsonIsConservative() {
        let cell = makeCell(success: 3, total: 3)
        #expect(cell.successRate == 1.0)
        #expect(cell.wilsonLowerBound < cell.successRate)
        #expect(cell.wilsonLowerBound > 0)
    }

    @Test("an empty cell has zero rate and zero Wilson bound")
    func emptyCellZero() {
        let cell = ActionOutcomeCell(lastUpdateHLC: hlc(0))
        #expect(cell.successRate == 0)
        #expect(cell.wilsonLowerBound == 0)
    }

    @Test("Wilson bound tightens toward the rate as observations grow")
    func wilsonTightensWithEvidence() {
        let few = makeCell(success: 8, total: 10)     // 80% over 10
        let many = makeCell(success: 80, total: 100)  // 80% over 100
        #expect(few.successRate == many.successRate)
        // More evidence ⇒ the lower bound sits closer to the rate.
        #expect(many.wilsonLowerBound > few.wilsonLowerBound)
    }

    @Test("topActions ranks by Wilson lower bound, not raw rate")
    func topActionsPrefersEvidence() {
        var m = ActionOutcomeMatrix()
        // Action 1: 1/1 success (rate 1.0 but thin evidence).
        m.observe(action: 1, outcome: 5, success: true, at: hlc(1))
        // Action 2: 18/20 success (rate 0.9 but strong evidence).
        for i in 0..<18 { m.observe(action: 2, outcome: 5, success: true, at: hlc(Int64(i))) }
        for i in 18..<20 { m.observe(action: 2, outcome: 5, success: false, at: hlc(Int64(i))) }
        let top = m.topActions(forOutcome: 5, k: 2)
        #expect(top.count == 2)
        // The well-evidenced action wins on Wilson lower bound.
        #expect(top.first?.action == 2)
    }

    @Test("topActions honors k and the minObservations floor")
    func topActionsLimitsAndFilters() {
        var m = ActionOutcomeMatrix()
        m.observe(action: 1, outcome: 7, success: true, at: hlc(1))
        m.observe(action: 2, outcome: 7, success: true, at: hlc(2))
        m.observe(action: 2, outcome: 7, success: true, at: hlc(3))
        m.observe(action: 3, outcome: 7, success: true, at: hlc(4))
        // k = 1 caps the result.
        #expect(m.topActions(forOutcome: 7, k: 1).count == 1)
        // minObservations = 2 filters out the single-observation cells.
        let filtered = m.topActions(forOutcome: 7, k: 10, minObservations: 2)
        #expect(filtered.count == 1)
        #expect(filtered.first?.action == 2)
    }

    /// Build a populated cell with the given counts (lastUpdateHLC
    /// is irrelevant to the rate/Wilson assertions).
    private func makeCell(success: UInt32, total: UInt32) -> ActionOutcomeCell {
        ActionOutcomeCell(successCount: success, totalCount: total, lastUpdateHLC: hlc(0))
    }
}
