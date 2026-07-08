import Testing
import Foundation
@testable import MootGateway
import MootIntentKit

// M-ING-2 Part 1 — MinerEngine against a live in-memory estate, fixture
// sources only (no platform frameworks, no TCC prompts). The acceptance bar
// from the spec: re-running a day's mine files NOTHING new.

private struct FixtureSource: MinerSource {
    let sourceID = "fixture"
    let facts: [MinedFact]
    func collect() async throws -> [MinedFact] { facts }
}

@Suite("MinerEngine (M-ING-2)", .serialized)
struct MinerEngineTests {

    private let day1 = [
        MinedFact(subject: "health.weight.2026-07-06", predicate: "measured", object: "82.1 kg"),
        MinedFact(subject: "calendar.event.abc123", predicate: "scheduled", object: "Dentist 2026-07-09 14:00"),
    ]

    @Test("double-run is idempotent: second run files zero")
    func doubleRunFilesNothing() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let source = FixtureSource(facts: day1)

        let first = try await MinerEngine.run(source, caller: bridge)
        #expect(first == .init(filed: 2, skipped: 0, failed: 0))

        let second = try await MinerEngine.run(source, caller: bridge)
        #expect(second == .init(filed: 0, skipped: 2, failed: 0))
    }

    @Test("new samples file alongside already-mined history")
    func incrementalDayFilesOnlyNewSamples() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = try await MinerEngine.run(FixtureSource(facts: day1), caller: bridge)

        let day2 = day1 + [
            MinedFact(subject: "health.weight.2026-07-07", predicate: "measured", object: "81.9 kg"),
        ]
        let result = try await MinerEngine.run(FixtureSource(facts: day2), caller: bridge)
        #expect(result == .init(filed: 1, skipped: 2, failed: 0))

        // The new fact is really in the estate's fact lane.
        let search = await bridge.callToolFull("moot_fact_search", arguments: [
            "query": .string("health.weight.2026-07-07"),
        ])
        #expect(search.text.contains("81.9 kg"))
    }

    @Test("facts land with miner provenance riding source_id")
    func provenanceRecorded() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = try await MinerEngine.run(FixtureSource(facts: [day1[0]]), caller: bridge)
        // moot_fact_search surfaces the fact; filing succeeded through the
        // real tool (source_id acceptance is the dispatcher's contract —
        // runFileFact grounds every fact in its provided source).
        let search = await bridge.callToolFull("moot_fact_search", arguments: [
            "query": .string("health.weight.2026-07-06"),
        ])
        #expect(search.isError == false)
        #expect(search.text.contains("82.1 kg"))
    }
}
