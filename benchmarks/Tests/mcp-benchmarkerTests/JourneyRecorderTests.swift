import Foundation
import Testing
@testable import mcp_benchmarker

// JourneyRecorderTests — recorder accumulation, token estimation wiring, and
// report block format. The twin test in Rust (journey_recorder.rs unit tests)
// uses identical fixture strings so both legs are verified on the same inputs.

@Suite("Journey recorder")
struct JourneyRecorderTests {

    @Test("append converts reply text to token estimate")
    func appendConvertsText() {
        // "Hello" = 5 UTF-8 bytes → ceil(5/4) = 2 tokens
        var recorder = JourneyRecorder()
        recorder.append(verb: "store", replyText: "Hello",
                        hydratedFullContent: false, terminal: false)
        let steps = recorder.currentSteps()
        #expect(steps.count == 1)
        #expect(steps[0].payloadTokens == 2)
    }

    @Test("empty recorder metrics are zero")
    func emptyMetrics() {
        let recorder = JourneyRecorder()
        let m = recorder.metrics()
        #expect(m.hops == 0)
        #expect(m.tokenTurnIntegral == 0)
        #expect(m.preTerminalFullContentTokens == 0)
        #expect(m.totalPayloadTokens == 0)
    }

    @Test("report block format matches Rust twin")
    func reportBlockFormat() {
        // "ABCD" = 4 bytes → 1 token. "EFGH" = 4 bytes → 1 token.
        // hops=2, integral=1+(1+1)=3, preTerminal=1 (step0 hydrated&&!terminal), total=2
        var recorder = JourneyRecorder()
        recorder.append(verb: "store", replyText: "ABCD",
                        hydratedFullContent: true, terminal: false)
        recorder.append(verb: "recall", replyText: "EFGH",
                        hydratedFullContent: false, terminal: true)
        let block = recorder.reportBlock()
        #expect(block == """
        hops: 2
        token_turn_integral: 3
        pre_terminal_full_tokens: 1
        total_payload_tokens: 2
        """)
    }

    @Test("fixture reply texts match expected metrics")
    func fixtureReplyTexts() {
        // Fixture texts chosen to produce exact token counts:
        //   "StoredItem"  = 10 bytes → ceil(10/4) = 3 tokens
        //   "RecallReply" = 11 bytes → ceil(11/4) = 3 tokens
        //
        // hops=2, integral=3+(3+3)=9, preTerminal=0 (neither hydrated), total=6
        var recorder = JourneyRecorder()
        recorder.append(verb: "store", replyText: "StoredItem",
                        hydratedFullContent: false, terminal: false)
        recorder.append(verb: "recall", replyText: "RecallReply",
                        hydratedFullContent: false, terminal: true)
        let m = recorder.metrics()
        #expect(m.hops == 2)
        #expect(m.tokenTurnIntegral == 9)
        #expect(m.preTerminalFullContentTokens == 0)
        #expect(m.totalPayloadTokens == 6)
    }

    @Test("currentSteps reflects all appended events")
    func currentStepsAccumulates() {
        var recorder = JourneyRecorder()
        recorder.append(verb: "store", replyText: "A",
                        hydratedFullContent: false, terminal: false)
        recorder.append(verb: "recall", replyText: "BB",
                        hydratedFullContent: true, terminal: true)
        let steps = recorder.currentSteps()
        #expect(steps.count == 2)
        #expect(steps[0].verb == "store")
        #expect(steps[1].verb == "recall")
        #expect(steps[1].hydratedFullContent == true)
        #expect(steps[1].terminal == true)
    }
}
