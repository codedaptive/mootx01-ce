import Foundation
import Testing
@testable import mcp_benchmarker

// JourneyMetricsTests — pure-integer metric computation and the cross-
// language conformance check against the committed vector file.
//
// The vector file (conformance/journey_metrics_vectors.json) contains three
// hand-computed cases: empty journey, single terminal step, and a three-step
// mixed case. Both Swift and Rust legs must produce the same values.

/// Resolves `benchmarks/conformance/<filename>` from this file.
private func metricsConformancePath(_ filename: String,
                                    file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

@Suite("Journey metrics")
struct JourneyMetricsTests {

    @Test("empty journey is all zeros")
    func emptyJourney() {
        let m = computeJourneyMetrics(steps: [])
        #expect(m.hops == 0)
        #expect(m.tokenTurnIntegral == 0)
        #expect(m.preTerminalFullContentTokens == 0)
        #expect(m.totalPayloadTokens == 0)
    }

    @Test("single terminal step")
    func singleTerminalStep() {
        let steps = [JourneyStep(verb: "recall", payloadTokens: 20,
                                 hydratedFullContent: false, terminal: true)]
        let m = computeJourneyMetrics(steps: steps)
        #expect(m.hops == 1)
        #expect(m.tokenTurnIntegral == 20)
        #expect(m.preTerminalFullContentTokens == 0)
        #expect(m.totalPayloadTokens == 20)
    }

    @Test("three-step mixed case")
    func threeStepMixed() {
        // step 0: store, 10 tokens, not hydrated, not terminal
        // step 1: recall, 40 tokens, hydrated, not terminal
        // step 2: recall, 5 tokens, not hydrated, terminal
        let steps = [
            JourneyStep(verb: "store", payloadTokens: 10,
                        hydratedFullContent: false, terminal: false),
            JourneyStep(verb: "recall", payloadTokens: 40,
                        hydratedFullContent: true, terminal: false),
            JourneyStep(verb: "recall", payloadTokens: 5,
                        hydratedFullContent: false, terminal: true),
        ]
        let m = computeJourneyMetrics(steps: steps)
        #expect(m.hops == 3)
        // cumulative at step 0 = 10, step 1 = 50, step 2 = 55; sum = 115
        #expect(m.tokenTurnIntegral == 115)
        // only step 1 is hydrated && !terminal
        #expect(m.preTerminalFullContentTokens == 40)
        #expect(m.totalPayloadTokens == 55)
    }

    @Test("integral exceeds total for multi-step journey")
    func integralExceedsTotal() {
        let steps = [
            JourneyStep(verb: "store", payloadTokens: 10,
                        hydratedFullContent: false, terminal: false),
            JourneyStep(verb: "recall", payloadTokens: 5,
                        hydratedFullContent: false, terminal: true),
        ]
        let m = computeJourneyMetrics(steps: steps)
        // integral = 10 + 15 = 25; total = 15
        #expect(m.tokenTurnIntegral > m.totalPayloadTokens)
        #expect(m.tokenTurnIntegral == 25)
        #expect(m.totalPayloadTokens == 15)
    }

    @Test("committed conformance vectors match computation")
    func conformanceVectors() throws {
        let url = metricsConformancePath("journey_metrics_vectors.json")
        let vectors = try JSONDecoder().decode(JourneyMetricsVectors.self,
                                              from: Data(contentsOf: url))
        for c in vectors.cases {
            let computed = computeJourneyMetrics(steps: c.steps)
            #expect(computed == c.expected,
                    "case '\(c.description)': computed \(computed) != expected \(c.expected)")
        }
    }
}
