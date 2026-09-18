import Testing
import Foundation
@testable import mcp_benchmarker

// JourneySpecConformanceTests — the journey report against its DEFINITION.
//
// Every assertion here is transcribed from the journey specification,
// not from the runner. That direction is the whole point.
//
// On 2026-08-18 the lane published `target_over_decoy_rate` and
// `true_found_rate` as its headline figures. Neither appears in the definition.
// §Metrics says the lane is four integer counts over an ordered step sequence —
// hops, token-turn residency integral, pre-terminal full-content tokens, total
// payload tokens — and §What is recorded says "per journey: the four counts,
// the step sequence, and the data set seed".
//
// The precise-miss journeys carried no counts at all, the fourth count was
// absent from both aggregates, and the step sequence was never written. The
// suite was green: every test had been written from the implementation, so it
// asserted what the code did rather than what the benchmark promised.
//
// A test that reads the specification is the only kind that catches this.

@Suite("Journey report conforms to benchmarks/journey.md")
struct JourneySpecConformanceTests {

    /// One step: a recall reply, terminal, no full-content hydration.
    private func oneStep(_ tokens: Int) -> [JourneyStep] {
        [JourneyStep(verb: "recall", payloadTokens: tokens,
                     hydratedFullContent: false, terminal: true)]
    }

    private func fourStep() -> [JourneyStep] {
        [JourneyStep(verb: "recall", payloadTokens: 100, hydratedFullContent: false, terminal: false),
         JourneyStep(verb: "recall", payloadTokens: 80, hydratedFullContent: false, terminal: false),
         JourneyStep(verb: "recall", payloadTokens: 40, hydratedFullContent: false, terminal: false),
         JourneyStep(verb: "get", payloadTokens: 200, hydratedFullContent: true, terminal: true)]
    }

    private func report() -> JourneyReport {
        let pmSteps = oneStep(120)
        let vnSteps = fourStep()
        let outcome = JourneyLaneOutcome(
            preciseMiss: [PreciseMissOutcome(
                scenarioID: "pm-0", targetRank: 2, decoyRank: 1,
                targetOutranksDecoy: false, targetFound: true, querySeconds: 0.05,
                metrics: computeJourneyMetrics(steps: pmSteps), steps: pmSteps)],
            vagueNarrow: [VagueNarrowOutcome(
                clusterID: "vn-0", trueFound: true, trueRank: 1,
                hydratedTrueMember: true,
                metrics: computeJourneyMetrics(steps: vnSteps), steps: vnSteps,
                journeySeconds: 0.4)],
            seededRecords: 140)
        let corpus = generateJourneyCorpus(
            seed: 1, preciseMissCount: 1, clusterCount: 1, membersPerCluster: 2)
        return buildJourneyReport(
            corpus: corpus, outcome: outcome,
            config: JourneyRunConfig(
                seed: 1, mootBinaryPath: "/nonexistent",
                scratchDir: URL(fileURLWithPath: "/tmp/journey-spec-test"),
                posture: .plaintextTransient, shape: .disk, topK: 10),
            runEnvironment: RunEnvironment.collect(mootx01BinaryPath: nil, runMode: "quiet"))
    }

    private func encoded(_ r: JourneyReport) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(r), as: UTF8.self)
    }

    // §Metrics: "Four integer counts over an ordered sequence of steps."

    @Test("Both sub-corpora report all four counts")
    func bothAggregatesCarryTheFourCounts() throws {
        let json = try encoded(report())
        for key in ["mean_hops",
                    "mean_token_turn_integral",
                    "mean_pre_terminal_full_content_tokens",
                    "mean_total_payload_tokens"] {
            // Twice: once under precise_miss_aggregate, once under
            // vague_narrow_aggregate. The lane has two sub-corpora and the
            // definition does not exempt either from the metrics.
            let count = json.components(separatedBy: "\"\(key)\"").count - 1
            #expect(count == 2, "\(key) must appear in BOTH aggregates, found \(count)")
        }
    }

    // §What is recorded: "per journey: the four counts, the step sequence,
    // and the data set seed."

    @Test("Every journey records its step sequence")
    func everyJourneyRecordsItsSteps() throws {
        let r = report()
        #expect(r.preciseMiss.allSatisfy { !$0.steps.isEmpty })
        #expect(r.vagueNarrow.allSatisfy { !$0.steps.isEmpty })
        let json = try encoded(r)
        #expect(json.contains("\"steps\""))
    }

    @Test("Every journey records its four counts")
    func everyJourneyRecordsItsCounts() throws {
        let r = report()
        // A one-step journey still has four counts. Omitting them because the
        // walk is short is the defect this test exists for.
        for pm in r.preciseMiss {
            #expect(pm.metrics.hops == 1)
            #expect(pm.metrics.totalPayloadTokens > 0)
            #expect(pm.metrics.preTerminalFullContentTokens == 0)
            #expect(pm.metrics.tokenTurnIntegral == pm.metrics.totalPayloadTokens)
        }
        for vn in r.vagueNarrow {
            #expect(vn.metrics.hops == 4)
            #expect(vn.metrics.totalPayloadTokens > 0)
        }
    }

    @Test("The data set seed is recorded")
    func seedIsRecorded() throws {
        #expect(try encoded(report()).contains("\"seed\""))
    }

    // §Metrics: the integral is defined exactly, so it is checked exactly
    // rather than trusted.
    //
    //   integral = Σ(i=0..N-1) Σ(j=0..i) payloadTokens[j]
    //
    // For 100, 80, 40, 200: 100 + 180 + 220 + 420 = 920.

    @Test("The token-turn integral matches the definition's formula")
    func integralMatchesTheFormula() {
        let steps = fourStep()
        let m = computeJourneyMetrics(steps: steps)
        var expected = 0, running = 0
        for s in steps { running += s.payloadTokens; expected += running }
        #expect(m.tokenTurnIntegral == expected)
        #expect(m.tokenTurnIntegral == 920)
    }
}
