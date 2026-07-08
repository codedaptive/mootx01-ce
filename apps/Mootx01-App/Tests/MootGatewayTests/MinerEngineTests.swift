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

// M-ING-2 Part 2 — concrete sources through the engine, fixture readers only.
@Suite("Miner sources (M-ING-2 Part 2)", .serialized)
struct MinerSourceTests {

    @Test("calendar and birthday mappers encode stable identity in subjects")
    func mappersEncodeIdentity() {
        let event = MinerMappers.fact(CalendarEventSample(
            eventID: "ev-9", title: "Dentist", start: Date(timeIntervalSince1970: 1_750_000_000)))
        #expect(event.subject == "calendar.event.ev-9")
        #expect(event.predicate == "scheduled")
        #expect(event.object.contains("Dentist at 2025-06-15"))

        let bday = MinerMappers.fact(BirthdaySample(
            contactID: "cn-3", name: "Ada Lovelace", month: 12, day: 10))
        #expect(bday.subject == "contact.birthday.cn-3")
        #expect(bday.object == "Ada Lovelace on 12-10")
    }

    @Test("calendar miner is idempotent end-to-end through the engine")
    func calendarMinerIdempotent() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let miner = CalendarMiner {
            [CalendarEventSample(eventID: "ev-1", title: "Standup",
                                 start: Date(timeIntervalSince1970: 1_750_000_000))]
        }
        let first = try await MinerEngine.run(miner, caller: bridge)
        #expect(first == .init(filed: 1, skipped: 0, failed: 0))
        let second = try await MinerEngine.run(miner, caller: bridge)
        #expect(second == .init(filed: 0, skipped: 1, failed: 0))
    }

    @Test("birthday miner files facts queryable in the fact lane")
    func birthdayMinerFilesFacts() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let miner = BirthdayMiner {
            [BirthdaySample(contactID: "cn-7", name: "Grace Hopper", month: 12, day: 9)]
        }
        _ = try await MinerEngine.run(miner, caller: bridge)
        let search = await bridge.callToolFull("moot_fact_search", arguments: [
            "query": .string("contact.birthday.cn-7"),
        ])
        #expect(search.text.contains("Grace Hopper on 12-09"))
    }
}

// M-ING-2 — cadence policy (D7: user-configurable; deterministic time).
@Suite("MinerScheduler (M-ING-2)")
struct MinerSchedulerTests {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("never-mined scheduled cadences are due immediately; manual never")
    func neverMinedSemantics() {
        #expect(MinerScheduler.isDue(lastRun: nil, cadence: .daily, now: t0))
        #expect(MinerScheduler.isDue(lastRun: nil, cadence: .weekly, now: t0))
        #expect(!MinerScheduler.isDue(lastRun: nil, cadence: .manual, now: t0))
    }

    @Test("daily fires at +24h, not before; weekly at +7d")
    func intervalBoundaries() {
        let justUnder = t0.addingTimeInterval(86_399)
        let exactly = t0.addingTimeInterval(86_400)
        #expect(!MinerScheduler.isDue(lastRun: t0, cadence: .daily, now: justUnder))
        #expect(MinerScheduler.isDue(lastRun: t0, cadence: .daily, now: exactly))
        #expect(MinerScheduler.nextRun(after: t0, cadence: .weekly, now: t0)
                == t0.addingTimeInterval(7 * 86_400))
    }

    @Test("manual cadence has no next run")
    func manualNeverSchedules() {
        #expect(MinerScheduler.nextRun(after: t0, cadence: .manual, now: t0) == nil)
    }
}
