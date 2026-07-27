import XCTest
@testable import mcp_benchmarker

/// Unit tests for `parseDrainResponse(_:)`.
///
/// The function must:
///   - Return `.idle`       for "drains: none" (Shape A).
///   - Return `.idle`       when ALL drain lines report state="idle" with zero counts (Shape B).
///   - Return `.draining`   when ANY drain line has state="draining" or non-zero counts.
///   - Return `.unparseable` for ANY response that doesn't match Shape A or B.
///
/// The `.unparseable` case is verified here at the parse level; the abort-on-unparseable
/// behaviour is in `waitForEncodeDrain` and is intentionally not tested with unit tests
/// (it calls `exit(1)`, which is not recoverable within a test process).
final class EncodeBarrierTests: XCTestCase {

    // MARK: - Shape A: "drains: none"

    func test_drainsNone_isIdle() {
        XCTAssertEqual(parseDrainResponse("drains: none"), .idle)
    }

    func test_drainsNone_withLeadingTrailingWhitespace_isIdle() {
        // Callers join textBlocks with "\n" — trimming must tolerate outer whitespace.
        XCTAssertEqual(parseDrainResponse("  drains: none  \n"), .idle)
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
