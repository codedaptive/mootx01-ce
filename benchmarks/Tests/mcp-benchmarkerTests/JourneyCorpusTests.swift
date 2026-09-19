import Foundation
import Testing
@testable import mcp_benchmarker

// JourneyCorpusTests — generator determinism, corpus invariants, and the
// cross-language conformance check against the committed vector file.
//
// The vector file (conformance/journey_vectors.json) is the corpus for
// seed 20260725 / 4 precise-miss scenarios / 3 clusters × 4 members.
// Both legs must regenerate it EXACTLY: a benchmark whose corpus drifts
// between legs or between runs cannot support a claim.

/// Resolves `benchmarks/conformance/<filename>` from this file.
private func journeyConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

@Suite("Journey corpus")
struct JourneyCorpusTests {

    @Test("generation is a pure function of seed")
    func deterministicGeneration() {
        let a = generateJourneyCorpus(seed: 42, preciseMissCount: 4,
                                      clusterCount: 3, membersPerCluster: 4)
        let b = generateJourneyCorpus(seed: 42, preciseMissCount: 4,
                                      clusterCount: 3, membersPerCluster: 4)
        #expect(a == b)
        let c = generateJourneyCorpus(seed: 43, preciseMissCount: 4,
                                      clusterCount: 3, membersPerCluster: 4)
        #expect(a.preciseMiss.records[0].content != c.preciseMiss.records[0].content)
    }

    @Test("precise-miss scenario has target, decoy, and two fillers")
    func preciseMissScenarioLayout() {
        let corpus = generateJourneyCorpus(seed: 20260725, preciseMissCount: 4,
                                           clusterCount: 0, membersPerCluster: 4)
        // Each scenario contributes 4 records: target + decoy + 2 fillers.
        #expect(corpus.preciseMiss.records.count == 16)
        #expect(corpus.preciseMiss.scenarios.count == 4)
        for (i, s) in corpus.preciseMiss.scenarios.enumerated() {
            #expect(s.targetRecordID == "pm-\(i)-t")
            #expect(s.decoyRecordID == "pm-\(i)-d")
            #expect(s.fillerRecordIDs == ["pm-\(i)-f0", "pm-\(i)-f1"])
        }
    }

    @Test("vague-narrow cluster trueID is one of memberIDs")
    func vagueNarrowTrueIDInCluster() {
        let corpus = generateJourneyCorpus(seed: 20260725, preciseMissCount: 0,
                                           clusterCount: 3, membersPerCluster: 4)
        for cluster in corpus.vagueNarrow.clusters {
            #expect(cluster.memberIDs.contains(cluster.trueID))
        }
    }

    @Test("topics cycle across four scenario types")
    func topicCycle() {
        let corpus = generateJourneyCorpus(seed: 1, preciseMissCount: 8,
                                           clusterCount: 0, membersPerCluster: 4)
        // Scenario 0 and scenario 4 both use the same topic (index 0 % 4 = 0 % 4).
        // Both questions contain the "count survey" base text from that topic.
        let q0 = corpus.preciseMiss.scenarios[0].question
        let q4 = corpus.preciseMiss.scenarios[4].question
        #expect(q0.contains("count survey"))
        #expect(q4.contains("count survey"))
    }

    @Test("committed conformance vectors regenerate exactly")
    func conformanceVectors() throws {
        let url = journeyConformancePath("journey_vectors.json")
        let expected = try JSONDecoder().decode(JourneyCorpus.self,
                                               from: Data(contentsOf: url))
        let generated = generateJourneyCorpus(seed: 20260725, preciseMissCount: 4,
                                              clusterCount: 3, membersPerCluster: 4)
        #expect(generated == expected)
    }
}
