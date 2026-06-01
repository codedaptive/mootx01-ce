// ScenarioProfileTests.swift
//
// Round-trip conformance for the ScenarioProfile value type minus the
// tournamentReport field per Known Ambiguity 2 in the mission.

import Testing
import Foundation
@testable import NeuronKit

@Suite("ScenarioProfile round-trip + shape")
struct ScenarioProfileTests {

    @Test("round-trips through JSON identically")
    func roundTripsThroughJSONIdentically() throws {
        let original = ScenarioProfile(
            profileID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            name: "morning planning",
            framingParameters: ["focus": "P0", "horizon": "1d"],
            scoringBreakdown: ["averageReward": 0.42, "proposalAcceptanceRate": 0.61],
            preferenceWeights: ["averageReward": 0.5, "proposalAcceptanceRate": 0.5],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            trainingEligible: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ScenarioProfile.self, from: data)

        #expect(decoded == original)
    }

    @Test("default initializer fields line up")
    func defaultInitializerFieldsLineUp() {
        // The initializer assigns profileID via UUID() when omitted —
        // verify the remaining fields land in their declared slots.
        let now = Date(timeIntervalSince1970: 1)
        let p = ScenarioProfile(
            name: "x",
            framingParameters: [:],
            scoringBreakdown: [:],
            preferenceWeights: [:],
            createdAt: now
        )
        #expect(p.name == "x")
        #expect(p.framingParameters == [:])
        #expect(p.scoringBreakdown == [:])
        #expect(p.preferenceWeights == [:])
        #expect(p.createdAt == now)
        #expect(!p.trainingEligible)
    }

    @Test("tournamentReport field is deferred (absent from v0.1 JSON)")
    func tournamentReportFieldDeferred() {
        // The struct intentionally lacks `tournamentReport` (Known
        // Ambiguity 2). This test pins the v0.1 shape by encoding to
        // JSON and confirming the key is absent — so a future addition
        // of the field is recognised as a versioned change.
        let p = ScenarioProfile(
            name: "y",
            framingParameters: [:],
            scoringBreakdown: [:],
            preferenceWeights: [:],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(p)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("tournamentReport"))
        #expect(!json.contains("TournamentReport"))
    }
}
