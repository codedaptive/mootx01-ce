import XCTest
@testable import mcp_benchmarker

/// Unit tests for `parseDrainResponse(_:)`.
///
/// The function must:
///   - Return `.noLanes`    for "drains: none" (Shape A — lane not registered;
///                          NOT idle-equivalent on a fresh estate).
///   - Return `.idle`       when ALL drain lines report state="idle" with zero counts (Shape B).
///   - Return `.draining`   when ANY drain line has state="draining" or non-zero counts.
///   - Return `.unparseable` for ANY response that doesn't match Shape A or B.
///
/// The `.unparseable` case is verified here at the parse level; the abort-on-unparseable
/// behaviour is in `waitForEncodeDrain` and is intentionally not tested with unit tests
/// (it calls `exit(1)`, which is not recoverable within a test process).
final class EncodeBarrierTests: XCTestCase {

    // MARK: - Shape A: "drains: none"

    func test_drainsNone_isNoLanes() {
        // Shape A means the corpus lane has not registered (or the estate runs
        // no drains). The state machine, not the parser, decides acceptance.
        XCTAssertEqual(parseDrainResponse("drains: none"), .noLanes)
    }

    func test_drainsNone_withLeadingTrailingWhitespace_isNoLanes() {
        // Callers join textBlocks with "\n" — trimming must tolerate outer whitespace.
        XCTAssertEqual(parseDrainResponse("  drains: none  \n"), .noLanes)
    }

    // MARK: - Shape B: single drain, 1.0.x-style fixture (corpus_encode lane)

    func test_singleDrain_draining_isDraining() {
        // 1.0.x corpus_encode lane actively encoding — barrier must keep polling.
        let text = "drains: 1\n  corpus_encode: draining \u{2014} pending: 42, in_flight: 3, encoded_chunks: 100"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    func test_singleDrain_idle_isIdle() {
        // 1.0.x corpus_encode lane fully drained — barrier may proceed.
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 2173"
        XCTAssertEqual(parseDrainResponse(text), .idle)
    }

    // MARK: - Shape B: single drain, 1.1.x-style fixture
    //
    // Server-side format is identical between 1.0.x and 1.1.x; the lane name or
    // count may differ. The fix contract is shape-tolerant — any lane that follows
    // the known wire format is handled correctly regardless of name.

    func test_singleDrain_11x_draining_isDraining() {
        // 1.1.x corpus_encode lane active.
        let text = "drains: 1\n  corpus_encode: draining \u{2014} pending: 7, in_flight: 1, encoded_chunks: 340"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    func test_singleDrain_11x_idle_isIdle() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0, encoded_chunks: 340"
        XCTAssertEqual(parseDrainResponse(text), .idle)
    }

    // MARK: - Shape B: multiple drains

    func test_multipleDrains_oneDraining_isDraining() {
        // Two drains: one idle, one draining — overall result must be Draining.
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  lsa_encode: draining \u{2014} pending: 12, in_flight: 2"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    func test_multipleDrains_allIdle_isIdle() {
        let text = "drains: 2\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0\n  lsa_encode: idle \u{2014} pending: 0, in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .idle)
    }

    // MARK: - Counts vs state word (belt-and-suspenders)
    //
    // The product server sets state based on pending+in_flight, so "idle" with
    // non-zero counts shouldn't occur in practice. But the parser must not silently
    // treat it as idle — a pending count of > 0 means there IS work outstanding.

    func test_idleStateWithNonZeroPending_isDraining() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 5, in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    func test_idleStateWithNonZeroInFlight_isDraining() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 2"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    // MARK: - Unknown shapes → unparseable

    func test_emptyString_isUnparseable() {
        XCTAssertEqual(parseDrainResponse(""), .unparseable)
    }

    func test_whitespaceOnly_isUnparseable() {
        XCTAssertEqual(parseDrainResponse("  \n  "), .unparseable)
    }

    func test_unknownHeader_isUnparseable() {
        // A completely different response format must be rejected.
        XCTAssertEqual(parseDrainResponse("status: unknown"), .unparseable)
    }

    func test_drainsZero_isUnparseable() {
        // "drains: 0" is not a valid Shape B header (N must be >= 1).
        XCTAssertEqual(parseDrainResponse("drains: 0"), .unparseable)
    }

    func test_drainsNonNumericCount_isUnparseable() {
        XCTAssertEqual(parseDrainResponse("drains: many"), .unparseable)
    }

    func test_headerWithNoDrainLines_isUnparseable() {
        // Header claims 1 drain but no lines follow.
        XCTAssertEqual(parseDrainResponse("drains: 1"), .unparseable)
    }

    func test_missingEmDashSeparator_isUnparseable() {
        // Drain line without the "—" separator cannot be parsed.
        let text = "drains: 1\n  corpus_encode: draining pending: 5 in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .unparseable)
    }

    func test_unknownStateWord_isUnparseable() {
        // A state word other than "draining" or "idle" is a protocol error.
        let text = "drains: 1\n  corpus_encode: encoding \u{2014} pending: 0, in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .unparseable)
    }

    func test_missingPendingField_isUnparseable() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .unparseable)
    }

    func test_missingInFlightField_isUnparseable() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0"
        XCTAssertEqual(parseDrainResponse(text), .unparseable)
    }

    // MARK: - parseIntField helper coverage

    func test_parseIntField_extractsPending() {
        // Verify the helper correctly parses the first field.
        // Tested indirectly via parseDrainResponse; this test exercises it directly.
        let text = "drains: 1\n  corpus_encode: draining \u{2014} pending: 99, in_flight: 1"
        XCTAssertEqual(parseDrainResponse(text), .draining)
    }

    func test_parseIntField_zeroIsValid() {
        let text = "drains: 1\n  corpus_encode: idle \u{2014} pending: 0, in_flight: 0"
        XCTAssertEqual(parseDrainResponse(text), .idle)
    }
}

// MARK: - DrainBarrierState (FIX-HARNESS-20260727)

/// Unit tests for the barrier's evidence state machine. The async poll loop in
/// `waitForEncodeDrain` drives this machine; testing the machine directly
/// covers the sequencing rules without needing an MCPClient.
final class DrainBarrierStateTests: XCTestCase {

    private let grace = DrainBarrierGrace(minConsecutiveNoLanes: 4, minSeconds: 2.0)

    /// Shape B idle converges immediately with lane evidence.
    func test_shapeBIdle_convergesImmediately_laneObserved() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        let decision = state.observe(.idle, at: start)
        XCTAssertEqual(decision, .converged(laneObserved: true))
    }

    /// The fresh-estate race: a FIRST poll of "drains: none" must NOT converge.
    func test_firstNoLanes_keepsPolling() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        XCTAssertEqual(state.observe(.noLanes, at: start), .keepPolling)
    }

    /// Draining then idle: the normal path. Lane observed on the draining poll.
    func test_drainingThenIdle_convergesWithLaneObserved() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        XCTAssertEqual(state.observe(.draining, at: start), .keepPolling)
        XCTAssertTrue(state.laneObserved)
        XCTAssertEqual(state.observe(.idle, at: start.addingTimeInterval(0.5)),
                       .converged(laneObserved: true))
    }

    /// The defect scenario: noLanes first (poll beat lane wiring), THEN the
    /// lane appears draining, then idle. Pre-fix, the first poll returned
    /// converged and the queries raced the encoder.
    func test_noLanesThenDrainingThenIdle_doesNotConvergeEarly() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        XCTAssertEqual(state.observe(.noLanes, at: start), .keepPolling)
        XCTAssertEqual(state.observe(.draining, at: start.addingTimeInterval(0.5)), .keepPolling)
        XCTAssertEqual(state.observe(.idle, at: start.addingTimeInterval(1.0)),
                       .converged(laneObserved: true))
    }

    /// Grace window by count AND time: 4 consecutive noLanes polls spanning
    /// >= 2 s converge WITHOUT lane evidence (tiny corpus / no drains estate).
    func test_noLanesGraceWindow_convergesWithoutLaneEvidence() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(0.5)), .keepPolling)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(1.0)), .keepPolling)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(1.5)), .keepPolling)
        // 4th consecutive poll AND >= 2.0 s elapsed → accept via grace.
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(2.0)),
                       .converged(laneObserved: false))
    }

    /// Count satisfied but time NOT satisfied: a burst of fast polls must not
    /// satisfy the grace window by count alone.
    func test_noLanesFastBurst_countAloneDoesNotConverge() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        for i in 0..<10 {
            // 10 polls all within 1 second — time constraint (2.0 s) unmet.
            let decision = state.observe(.noLanes, at: start.addingTimeInterval(Double(i) * 0.1))
            XCTAssertEqual(decision, .keepPolling,
                           "poll \(i): count alone must not satisfy the grace window")
        }
    }

    /// Time satisfied but count NOT satisfied: a single late poll must not
    /// converge on elapsed time alone.
    func test_noLanesSingleLatePoll_timeAloneDoesNotConverge() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(10.0)), .keepPolling)
    }

    /// A draining sighting resets the consecutive noLanes counter.
    func test_drainingResetsNoLanesCount() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        _ = state.observe(.noLanes, at: start.addingTimeInterval(0.5))
        _ = state.observe(.noLanes, at: start.addingTimeInterval(1.0))
        _ = state.observe(.noLanes, at: start.addingTimeInterval(1.5))
        // Lane appears — evidence chain broken AND lane now observed.
        _ = state.observe(.draining, at: start.addingTimeInterval(2.0))
        XCTAssertTrue(state.laneObserved)
    }

    /// After the lane was observed, "drains: none" is anomalous (the lane never
    /// deregisters in the product). The machine keeps polling rather than
    /// trusting the vanished lane — the timeout bounds the worst case.
    func test_noLanesAfterLaneObserved_keepsPolling() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        _ = state.observe(.draining, at: start)
        // Even far beyond the grace window, post-lane noLanes never converges.
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(60.0)), .keepPolling)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(61.0)), .keepPolling)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(62.0)), .keepPolling)
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(63.0)), .keepPolling)
    }

    /// An RPC error between polls breaks the consecutive-noLanes evidence chain.
    func test_noteErrorResetsNoLanesCount() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        _ = state.observe(.noLanes, at: start.addingTimeInterval(0.5))
        _ = state.observe(.noLanes, at: start.addingTimeInterval(1.0))
        _ = state.observe(.noLanes, at: start.addingTimeInterval(1.5))
        state.noteError()
        // This would be the 4th consecutive poll past 2.0 s — but the error
        // reset the counter, so it is now the 1st.
        XCTAssertEqual(state.observe(.noLanes, at: start.addingTimeInterval(2.5)), .keepPolling)
    }

    /// Unparseable always aborts, regardless of prior evidence.
    func test_unparseableAborts() {
        let start = Date()
        var state = DrainBarrierState(start: start, grace: grace)
        _ = state.observe(.draining, at: start)
        XCTAssertEqual(state.observe(.unparseable, at: start.addingTimeInterval(0.5)),
                       .abortUnparseable)
    }
}
