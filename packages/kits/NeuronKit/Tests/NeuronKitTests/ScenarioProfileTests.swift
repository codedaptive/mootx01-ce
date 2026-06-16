// ScenarioProfileTests.swift
//
// Round-trip conformance for the ScenarioProfile value type.

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
        // tournamentReport defaults to nil when not supplied.
        #expect(p.tournamentReport == nil)
    }

    @Test("tournamentReport is runtime-only — absent from JSON wire shape")
    func tournamentReportNotSerialised() throws {
        // `tournamentReport` carries `any BranchHandle`, which is not
        // Codable. ScenarioProfile excludes it via custom CodingKeys so
        // the JSON wire shape is stable and backwards-compatible with
        // persisted profiles that were saved before the field existed.
        let p = ScenarioProfile(
            name: "y",
            framingParameters: [:],
            scoringBreakdown: [:],
            preferenceWeights: [:],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(p)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Key must not appear in JSON — it is a runtime-only advisory value.
        #expect(!json.contains("tournamentReport"))
        #expect(!json.contains("TournamentReport"))
    }

    @Test("tournamentReport field is present and populated at init time")
    func tournamentReportFieldPresent() throws {
        // The field is live on the type — callers can attach the report
        // from saveScenarioProfile; it survives in memory for the session.
        let report = TournamentReport(
            winner: nil,
            ranking: [],
            disqualified: [],
            evaluatedAt: Date(timeIntervalSince1970: 0),
            interval: DateInterval(
                start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: 1)
            )
        )
        let p = ScenarioProfile(
            name: "z",
            framingParameters: [:],
            scoringBreakdown: [:],
            preferenceWeights: [:],
            createdAt: Date(timeIntervalSince1970: 0),
            tournamentReport: report
        )
        #expect(p.tournamentReport != nil)
        // JSON still omits the field — wire shape is unchanged.
        let encoder = JSONEncoder()
        let data = try encoder.encode(p)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("tournamentReport"))
    }
}
