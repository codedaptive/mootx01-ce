// ScenarioProfileTests.swift
//
// Round-trip conformance for the ScenarioProfile value type minus the
// tournamentReport field per Known Ambiguity 2 in the mission.

import XCTest
@testable import NeuronKit

final class ScenarioProfileTests: XCTestCase {

    func testRoundTripsThroughJSONIdentically() throws {
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

        XCTAssertEqual(decoded, original)
    }

    func testDefaultInitializerFieldsLineUp() {
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
        XCTAssertEqual(p.name, "x")
        XCTAssertEqual(p.framingParameters, [:])
        XCTAssertEqual(p.scoringBreakdown, [:])
        XCTAssertEqual(p.preferenceWeights, [:])
        XCTAssertEqual(p.createdAt, now)
        XCTAssertFalse(p.trainingEligible)
    }

    func testTournamentReportFieldDeferred() {
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
        XCTAssertFalse(json.contains("tournamentReport"))
        XCTAssertFalse(json.contains("TournamentReport"))
    }
}
