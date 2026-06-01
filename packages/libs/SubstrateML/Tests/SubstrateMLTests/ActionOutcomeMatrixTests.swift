// ActionOutcomeMatrixTests.swift
//
// Action-outcome matrix per cookbook § 6.5. swift-testing peer suite
// for Sources/SubstrateML/ActionOutcomeMatrix.swift.
//
// The Rust leg (rust/src/action_outcome.rs) carries its own #[cfg(test)]
// module that mirrors this suite's topActions invariants.
//
// Asserts the documented behavior set: observation accumulation,
// empirical success rate, the conservative Wilson lower bound, and
// the Wilson-ranked topActions selection (under-observed cells must
// not float to the top). Also asserts that topActions surfaces the
// wilsonLowerBound it ranked by — the regression guard for the
// order/value mismatch defect where the returned rate field did not
// match the ordering criterion.

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

    @Test("topActions result is non-increasing in wilsonLowerBound")
    func topActionsOrderMatchesReturnedWilson() {
        var m = ActionOutcomeMatrix()
        // Three actions with identical raw rate (1.0) but different
        // evidence depth — Wilson LB order must equal returned order.
        m.observe(action: 10, outcome: 3, success: true, at: hlc(1))             // 1/1
        for i in 0..<5  { m.observe(action: 11, outcome: 3, success: true, at: hlc(Int64(i + 10))) } // 5/5
        for i in 0..<20 { m.observe(action: 12, outcome: 3, success: true, at: hlc(Int64(i + 20))) } // 20/20
        let top = m.topActions(forOutcome: 3, k: 3)
        #expect(top.count == 3)
        // Returned wilsonLowerBound must be non-increasing across results.
        for i in 0..<(top.count - 1) {
            #expect(top[i].wilsonLowerBound >= top[i + 1].wilsonLowerBound,
                    "result \(i) wilson \(top[i].wilsonLowerBound) must be ≥ result \(i+1) wilson \(top[i+1].wilsonLowerBound)")
        }
        // And the returned wilsonLowerBound must equal the cell's computed value,
        // confirming the returned field is the ranking signal, not the raw rate.
        for entry in top {
            let cell = m.cells[ActionOutcomeKey(actionKind: entry.action, outcomeCategory: 3)]!
            #expect(entry.wilsonLowerBound == cell.wilsonLowerBound)
            #expect(entry.rate == cell.successRate)
        }
    }

    @Test("topActions regression: Wilson-LB order differs from raw-rate order")
    func topActionsWilsonOrderDiffersFromRawRateOrder() {
        // Regression guard for the original defect: results were sorted by
        // Wilson LB but only the raw rate was returned, making the ordering
        // appear arbitrary to any consumer comparing returned rate to position.
        //
        // Setup: action A has rate 1.0 over 1 obs; action B has rate 0.8 over
        // 100 obs. Raw-rate order is A > B (1.0 > 0.8). Wilson-LB order is
        // B > A (strong evidence beats thin perfect record).
        var m = ActionOutcomeMatrix()
        m.observe(action: 20, outcome: 8, success: true, at: hlc(1))           // action A: 1/1
        for i in 0..<80  { m.observe(action: 21, outcome: 8, success: true,  at: hlc(Int64(i + 2))) }
        for i in 80..<100 { m.observe(action: 21, outcome: 8, success: false, at: hlc(Int64(i + 2))) }

        let top = m.topActions(forOutcome: 8, k: 2)
        #expect(top.count == 2)

        // Wilson-LB order: action B (21) should rank first.
        #expect(top[0].action == 21, "B must rank first by Wilson LB")
        #expect(top[1].action == 20, "A must rank second")

        // Returned wilsonLowerBound must be strictly consistent with the rank.
        #expect(top[0].wilsonLowerBound > top[1].wilsonLowerBound)

        // Raw rate order is opposite — confirms the two orderings diverge,
        // which is the scenario the old code mis-handled.
        #expect(top[0].rate < top[1].rate,
                "raw rate of B (0.8) should be less than A (1.0) — verifying the order/value divergence scenario")
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
