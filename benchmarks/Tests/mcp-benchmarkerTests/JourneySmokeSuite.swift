import Testing
import Foundation
@testable import mcp_benchmarker

// JourneySmokeSuite.swift — scripted end-to-end journey smoke tests (D4).
//
// A "journey" is a multi-step agent interaction with the memory system:
//   1. SURVEY  — broad recall to find candidate memories ("what's there?")
//   2. PIVOT   — near:<uuid> recall to explore a neighbourhood
//   3. WINNOW  — shaped/filtered recall to narrow to the answer
//   4. HYDRATE — batch-get to fetch full body of the final item
//
// These smoke tests run the four-step journey against CANNED FIXTURE REPLIES —
// no live product server is required. They verify:
//   - JourneyRecorder accumulates all steps correctly.
//   - JourneyMetrics are computed correctly for the full step sequence.
//   - The JourneyDriver argument builders interoperate with parseToolResult.
//
// NOTE: byte-compat re-run (live benchmarker run before/after to confirm
// existing score distributions are unaffected) is DEFERRED to the ruled next
// gated run window — it requires a live product instance. This is noted
// in the PR-07 completion report.

// MARK: - Shared fixture helpers

/// Wraps raw reply text in the MCP content-block envelope.
private func textResult(_ text: String) -> JSONValue {
    .object(["content": .array([
        .object(["type": .string("text"), "text": .string(text)])
    ])])
}

// MARK: - Fixtures (stable, canned — no live server)

// Three UUIDs used as the fixture estate.
private let surveyUUID = "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018"
private let pivotUUID  = "84B0178B-A133-4F43-91D0-2854E7AC45FB"
private let answerUUID = "A2C35028-84BE-40D0-A8CB-7FCFE8EB6019"

/// SURVEY step reply: broad recall returns three candidates.
private let surveyReply = """
found 3 memory(s)
\(surveyUUID) · Survey hit one, general topic. · fdc:GEN · qid:Q1 · 2020-01-01T00:00:00Z
\(pivotUUID) · Survey hit two, related domain. · fdc:DOM · qid:Q2 · 2020-01-02T00:00:00Z
\(answerUUID) · Survey hit three, specific detail. · fdc:SPE · qid:Q3 · 2020-01-03T00:00:00Z
"""

/// PIVOT step reply: near:<surveyUUID> returns domain neighbours.
private let pivotReply = """
found 2 memory(s)
\(pivotUUID) · Neighbourhood entry one. · fdc:DOM · qid:Q4 · 2020-02-01T00:00:00Z
\(answerUUID) · Neighbourhood entry two — closer to answer. · fdc:SPE · qid:Q5 · 2020-02-02T00:00:00Z
"""

/// WINNOW step reply: shaped recall narrows to the answer item.
private let winnowReply = """
found 1 memory(s)
\(answerUUID) · Specific detail item. · fdc:SPE · qid:Q6 · 2020-03-01T00:00:00Z
"""

/// HYDRATE step reply: batch-get returns the full body of the answer item.
/// Simulates the dense content that triggers hydratedFullContent=true.
private let hydrateReply = """
\(answerUUID) [import/test] The full body content of the answer item: station reading 47.2 ppm recorded on 2020-01-03 by technician J. Harper. Cross-referenced with sensor log SL-0042. Signed off: QA team.
"""

// MARK: - Smoke suite

@Suite("Journey smoke — fixture-driven survey→pivot→winnow→hydrate") struct JourneySmokeSuite {

    // MARK: Step-by-step verification

    @Test("Survey step extracts three candidate UUIDs")
    func surveyStepParsesUUIDs() {
        let result = MCPClient.parseToolResult(textResult(surveyReply), format: .mootText)
        #expect(result.orderedIDs == [surveyUUID, pivotUUID, answerUUID])
    }

    @Test("Pivot step produces a near anchor arg and parses two neighbours")
    func pivotStepArgsAndParse() {
        let args = nearPivotSearchArgs(uuid: surveyUUID)
        #expect(args["near"] == .string(surveyUUID))
        // near and query are mutually exclusive on the live tool.
        #expect(args["query"] == nil)

        let result = MCPClient.parseToolResult(textResult(pivotReply), format: .mootText)
        #expect(result.orderedIDs == [pivotUUID, answerUUID])
    }

    @Test("Winnow step parses single answer UUID")
    func winnowStepParsesAnswer() {
        let result = MCPClient.parseToolResult(textResult(winnowReply), format: .mootText)
        #expect(result.orderedIDs == [answerUUID])
    }

    @Test("Hydrate step produces ids+depth:full args and parses full content")
    func hydrateStepArgsAndParse() {
        let args = batchHydrateArgs(ids: [answerUUID], depth: .full)
        // v2: key renamed ids → memory_ids
        #expect(args["memory_ids"] == .array([.string(answerUUID)]))
        #expect(args["depth"] == .string("full"))

        let result = MCPClient.parseToolResult(textResult(hydrateReply), format: .mootText)
        #expect(result.orderedIDs == [answerUUID])
        #expect(result.items.first?.content?.contains("station reading") == true)
    }

    // MARK: Full four-step journey with JourneyRecorder

    @Test("Four-step journey produces correct metrics via JourneyRecorder")
    func fullJourneyMetrics() {
        var recorder = JourneyRecorder()

        // Step 1: SURVEY — broad recall, not hydrated, not terminal.
        recorder.append(verb: "survey", replyText: surveyReply,
                        hydratedFullContent: false, terminal: false)

        // Step 2: PIVOT — neighbourhood recall, not hydrated, not terminal.
        recorder.append(verb: "pivot", replyText: pivotReply,
                        hydratedFullContent: false, terminal: false)

        // Step 3: WINNOW — shaped recall, not hydrated, not terminal.
        recorder.append(verb: "winnow", replyText: winnowReply,
                        hydratedFullContent: false, terminal: false)

        // Step 4: HYDRATE — full body fetch, hydrated, terminal.
        recorder.append(verb: "hydrate", replyText: hydrateReply,
                        hydratedFullContent: true, terminal: true)

        let metrics = recorder.metrics()

        // hops: 4 steps total.
        #expect(metrics.hops == 4)

        // preTerminalFullContentTokens: only step 4 has hydratedFullContent=true,
        // but step 4 is terminal, so preTerminalFullContentTokens must be 0.
        #expect(metrics.preTerminalFullContentTokens == 0)

        // totalPayloadTokens: sum of all step token estimates (must be > 0).
        #expect(metrics.totalPayloadTokens > 0)

        // tokenTurnIntegral: always >= totalPayloadTokens for multi-step journeys.
        #expect(metrics.tokenTurnIntegral >= metrics.totalPayloadTokens)
    }

    @Test("JourneyRecorder report block contains all four metric keys")
    func journeyReportBlockKeys() {
        var recorder = JourneyRecorder()
        recorder.append(verb: "survey", replyText: surveyReply,
                        hydratedFullContent: false, terminal: false)
        recorder.append(verb: "hydrate", replyText: hydrateReply,
                        hydratedFullContent: true, terminal: true)

        let report = recorder.reportBlock()
        #expect(report.contains("hops:"))
        #expect(report.contains("token_turn_integral:"))
        #expect(report.contains("pre_terminal_full_tokens:"))
        #expect(report.contains("total_payload_tokens:"))
    }

    @Test("JourneyRecorder steps accumulate in order")
    func recorderStepOrder() {
        var recorder = JourneyRecorder()
        recorder.append(verb: "survey",  replyText: surveyReply,  hydratedFullContent: false, terminal: false)
        recorder.append(verb: "pivot",   replyText: pivotReply,   hydratedFullContent: false, terminal: false)
        recorder.append(verb: "winnow",  replyText: winnowReply,  hydratedFullContent: false, terminal: false)
        recorder.append(verb: "hydrate", replyText: hydrateReply, hydratedFullContent: true,  terminal: true)

        let steps = recorder.currentSteps()
        #expect(steps.count == 4)
        #expect(steps[0].verb == "survey")
        #expect(steps[1].verb == "pivot")
        #expect(steps[2].verb == "winnow")
        #expect(steps[3].verb == "hydrate")
        #expect(steps[3].terminal == true)
        #expect(steps[3].hydratedFullContent == true)
    }

    // MARK: Token-turn integral arithmetic

    @Test("tokenTurnIntegral matches manual computation for two-step journey")
    func tokenTurnIntegralArithmetic() {
        // Manually craft two steps with known token counts to verify the
        // integral definition: sum over steps i of (cumulative payload at i).
        let step1 = JourneyStep(verb: "a", payloadTokens: 10, hydratedFullContent: false, terminal: false)
        let step2 = JourneyStep(verb: "b", payloadTokens: 20, hydratedFullContent: true,  terminal: true)

        let metrics = computeJourneyMetrics(steps: [step1, step2])

        // cumulative at step 0: 10; cumulative at step 1: 30.
        // integral = 10 + 30 = 40.
        #expect(metrics.tokenTurnIntegral == 40)
        #expect(metrics.hops == 2)
        #expect(metrics.totalPayloadTokens == 30)
        // step2 is terminal and hydrated: preTerminalFullContentTokens = 0.
        #expect(metrics.preTerminalFullContentTokens == 0)
    }

    @Test("preTerminalFullContentTokens counts hydrated non-terminal steps")
    func preTerminalHydrationCost() {
        // Step 1: non-terminal, hydrated — should count.
        let step1 = JourneyStep(verb: "a", payloadTokens: 50, hydratedFullContent: true,  terminal: false)
        // Step 2: terminal, hydrated — should NOT count.
        let step2 = JourneyStep(verb: "b", payloadTokens: 10, hydratedFullContent: true,  terminal: true)

        let metrics = computeJourneyMetrics(steps: [step1, step2])
        #expect(metrics.preTerminalFullContentTokens == 50)
    }
}
