import Testing
import Foundation
@testable import mcp_benchmarker

/// Pins the no-lanes grace-window path that the supersession drain barrier
/// relies on. A fast estate whose corpus lane never registers reports
/// "drains: none" on every poll; routing through the shared barrier's
/// state machine, four consecutive no-lanes polls past the 2-second
/// minimum converge via the grace window rather than timing out and failing.
@Suite struct SupersessionBarrierTests {

    @Test func noLanesEstateConvergesViaGraceNotHardFail() {
        // A fast/small estate that never wires a corpus lane. Every
        // moot_drain_status poll returns "drains: none". Verify that the
        // shared barrier's state machine converges via the grace window
        // (>= 4 consecutive no-lanes polls AND >= 2.0 s elapsed) rather
        // than treating persistent no-lanes as a timeout failure.
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var state = DrainBarrierState(
            start: base,
            grace: DrainBarrierGrace(minConsecutiveNoLanes: 4, minSeconds: 2.0))
        // Three no-lanes polls: count criterion not yet met — must keep polling.
        #expect(state.observe(.noLanes, at: base.addingTimeInterval(0.5)) == .keepPolling)
        #expect(state.observe(.noLanes, at: base.addingTimeInterval(1.0)) == .keepPolling)
        #expect(state.observe(.noLanes, at: base.addingTimeInterval(1.5)) == .keepPolling)
        // Fourth no-lanes poll past the 2-second minimum — grace window satisfied.
        // The barrier converges with laneObserved=false rather than failing.
        #expect(state.observe(.noLanes, at: base.addingTimeInterval(2.0))
            == .converged(laneObserved: false))
    }
}
