import Foundation
import Testing
@testable import mcp_benchmarker

// SupersessionContradictionTests — pure tests for the hunt-output parser and
// the planted-pair scorer (scored behaviour 3 of the supersession lane).

private let sampleHuntOutput = """
moot_hunt_contradictions: sweep complete
probesScanned: 26
pairsScreened: 40
alreadySettled: 0
proposed: 2
  PROPOSED UUID-A contradicts UUID-B (negation, score 0.91, tunnel T-1)
  PROPOSED UUID-C contradicts UUID-D (antonym, score 0.88, tunnel T-2)
Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.
borderlineCandidates: 1
  CANDIDATE UUID-E vs UUID-F (negation, score 0.55)
    a: Sarah Chen 0 works at Acme Robotics.
    b: Sarah Chen 0 works at Beta Corp.
Judge each CANDIDATE pair: if the two memories genuinely conflict, \
record it with moot_link_memories kind=contradicts proposed=true; otherwise ignore it.
"""

@Suite("Supersession contradiction sweep")
struct SupersessionContradictionTests {

    @Test("parser extracts PROPOSED and CANDIDATE pairs, skips prose")
    func parserExtractsPairs() {
        let pairs = parseHuntContradictionsReport(sampleHuntOutput)
        #expect(pairs.count == 3)
        #expect(pairs[0] == ReportedContradictionPair(a: "UUID-A", b: "UUID-B", tier: "proposed"))
        #expect(pairs[1] == ReportedContradictionPair(a: "UUID-C", b: "UUID-D", tier: "proposed"))
        #expect(pairs[2] == ReportedContradictionPair(a: "UUID-E", b: "UUID-F", tier: "candidate"))
    }

    @Test("parser returns empty for a sweep with no findings")
    func parserEmptySweep() {
        let text = """
        moot_hunt_contradictions: sweep complete
        probesScanned: 10
        pairsScreened: 12
        alreadySettled: 0
        proposed: 0
        borderlineCandidates: 0
        """
        #expect(parseHuntContradictionsReport(text).isEmpty)
    }

    @Test("scorer credits planted pairs in either drawer order and by tier")
    func scorerTierAndOrder() {
        let planted = [
            ContradictionPair(id: "con-0", leftRecordID: "con-0-a",
                              rightRecordID: "con-0-b", entity: "E0", attribute: "city"),
            ContradictionPair(id: "con-1", leftRecordID: "con-1-a",
                              rightRecordID: "con-1-b", entity: "E1", attribute: "city"),
            ContradictionPair(id: "con-2", leftRecordID: "con-2-a",
                              rightRecordID: "con-2-b", entity: "E2", attribute: "city"),
        ]
        let uuids = [
            "con-0-a": "UUID-A", "con-0-b": "UUID-B",
            "con-1-a": "UUID-E", "con-1-b": "UUID-F",
            "con-2-a": "UUID-X", "con-2-b": "UUID-Y",
        ]
        // Pair 0 reported PROPOSED in REVERSED order; pair 1 CANDIDATE only;
        // pair 2 never reported. One extra pair outside the planted set.
        let reported = [
            ReportedContradictionPair(a: "UUID-B", b: "UUID-A", tier: "proposed"),
            ReportedContradictionPair(a: "UUID-E", b: "UUID-F", tier: "candidate"),
            ReportedContradictionPair(a: "UUID-P", b: "UUID-Q", tier: "candidate"),
        ]
        let outcome = scoreContradictionSweep(
            planted: planted, uuidByRecordID: uuids,
            reported: reported, huntSeconds: 1.5)
        #expect(outcome.plantedCount == 3)
        #expect(outcome.detectedAnyTier == 2)
        #expect(outcome.detectedProposed == 1)
        #expect(outcome.flaggedOutsidePlanted == 1)
    }

    @Test("unmappable planted pair counts as undetected, not as a crash")
    func unmappablePlantedPair() {
        let planted = [
            ContradictionPair(id: "con-0", leftRecordID: "con-0-a",
                              rightRecordID: "con-0-b", entity: "E0", attribute: "city"),
        ]
        // No uuids captured for the pair's records.
        let outcome = scoreContradictionSweep(
            planted: planted, uuidByRecordID: [:],
            reported: [ReportedContradictionPair(a: "X", b: "Y", tier: "proposed")],
            huntSeconds: 0.1)
        #expect(outcome.detectedAnyTier == 0)
        #expect(outcome.flaggedOutsidePlanted == 1)
    }
}
