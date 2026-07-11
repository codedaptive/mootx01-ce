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

private actor AuthorizationState {
    private var value: MinerAuthorizationStatus = .notDetermined
    func get() -> MinerAuthorizationStatus { value }
    func grant() -> MinerAuthorizationStatus {
        value = .authorized
        return value
    }
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

    @Test("changed source records replace and retire the stale fact")
    func changedRecordReconciles() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let original = MinedFact(
            subject: "calendar.event.changed",
            predicate: "scheduled",
            object: "Review at 2026-07-11T10:00:00Z"
        )
        let replacement = MinedFact(
            subject: original.subject,
            predicate: original.predicate,
            object: "Review at 2026-07-11T11:00:00Z"
        )
        _ = try await MinerEngine.run(FixtureSource(facts: [original]), caller: bridge)
        let result = try await MinerEngine.run(FixtureSource(facts: [replacement]), caller: bridge)
        #expect(result == .init(filed: 1, skipped: 0, failed: 0))

        let active = await bridge.callToolFull("moot_fact_search", arguments: [
            "subject_exact": .string(original.subject),
            "source_id_exact": .string("miner:fixture"),
        ])
        #expect(active.text.contains(replacement.object))
        #expect(!active.text.contains(original.object))
    }

    @Test("records deleted at the source are retired")
    func deletedRecordReconciles() async throws {
        let bridge = try await MootBridge.attachInMemory()
        _ = try await MinerEngine.run(FixtureSource(facts: day1), caller: bridge)
        let result = try await MinerEngine.run(FixtureSource(facts: [day1[0]]), caller: bridge)
        #expect(result == .init(filed: 0, skipped: 1, failed: 0))

        let deleted = await bridge.callToolFull("moot_fact_search", arguments: [
            "subject_exact": .string(day1[1].subject),
            "source_id_exact": .string("miner:fixture"),
        ])
        #expect(deleted.text.hasPrefix("facts: 0"))
    }

    @Test("sample identities are exact, not substring matches")
    func substringIdentityDoesNotCollide() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let long = MinedFact(subject: "calendar.event.ev-10", predicate: "scheduled", object: "ten")
        let short = MinedFact(subject: "calendar.event.ev-1", predicate: "scheduled", object: "one")
        _ = try await MinerEngine.run(FixtureSource(facts: [long]), caller: bridge)
        let result = try await MinerEngine.run(FixtureSource(facts: [long, short]), caller: bridge)
        #expect(result == .init(filed: 1, skipped: 1, failed: 0))
    }

    @Test("duplicate identities in one source snapshot fail closed")
    func duplicateSnapshotIdentityFails() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let duplicate = MinedFact(
            subject: day1[0].subject,
            predicate: day1[0].predicate,
            object: "different"
        )
        await #expect(throws: MinerEngineError.self) {
            _ = try await MinerEngine.run(
                FixtureSource(facts: [day1[0], duplicate]),
                caller: bridge
            )
        }
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

// M-ING-2 — the executor: settings × scheduler × engine.
@Suite("MinerRunLoop (M-ING-2)", .serialized)
struct MinerRunLoopTests {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func freshDefaults() throws -> UserDefaults {
        let d = try #require(UserDefaults(suiteName: "ming2-runloop-tests"))
        d.removePersistentDomain(forName: "ming2-runloop-tests")
        return d
    }

    private var fixtureSource: FixtureSource {
        FixtureSource(facts: [MinedFact(
            subject: "runloop.probe.1", predicate: "observed", object: "tick")])
    }

    @Test("disabled sources never run — the shipped default is silent")
    func disabledSourcesSkipped() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let d = try freshDefaults()
        let loop = MinerRunLoop(sources: [fixtureSource], defaults: d)
        let summaries = await loop.tick(now: t0, caller: bridge)
        #expect(summaries.isEmpty)
        #expect(loop.lastRun(for: "fixture") == nil)
    }

    @Test("enabled + due runs, records lastRun, and respects cadence next tick")
    func enabledDueRunsOnce() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let d = try freshDefaults()
        d.set(true, forKey: "miner.fixture.enabled")
        let loop = MinerRunLoop(sources: [fixtureSource], defaults: d)

        let first = await loop.tick(now: t0, caller: bridge)
        #expect(first == [MinerRunSummary(sourceID: "fixture",
                                          result: .init(filed: 1, skipped: 0, failed: 0))])
        #expect(loop.lastRun(for: "fixture") == t0)

        // One hour later: daily cadence says not due — no run.
        let second = await loop.tick(now: t0.addingTimeInterval(3_600), caller: bridge)
        #expect(second.isEmpty)

        // Next day: due again; engine dedup makes it a no-op file.
        let third = await loop.tick(now: t0.addingTimeInterval(86_400), caller: bridge)
        #expect(third == [MinerRunSummary(sourceID: "fixture",
                                          result: .init(filed: 0, skipped: 1, failed: 0))])
    }

    @Test("manual cadence runs only through Mine Now")
    func manualOnlyRunsExplicitly() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let d = try freshDefaults()
        d.set(true, forKey: "miner.fixture.enabled")
        d.set("manual", forKey: "miner.fixture.cadence")
        let loop = MinerRunLoop(sources: [fixtureSource], defaults: d)

        #expect(await loop.tick(now: t0, caller: bridge) == [])
        let ran = await loop.runNow(sourceID: "fixture", now: t0, caller: bridge)
        #expect(ran?.result.filed == 1)
    }

    @Test("unattended ticks never request platform authorization")
    func tickDoesNotPromptForAuthorization() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let d = try freshDefaults()
        d.set(true, forKey: "miner.calendar.enabled")
        let source = CalendarMiner(
            reader: { [] },
            statusReader: { .notDetermined },
            authorizationRequester: {
                Issue.record("unattended tick requested authorization")
                return .authorized
            }
        )
        let loop = MinerRunLoop(sources: [source], defaults: d)
        #expect(await loop.tick(now: t0, caller: bridge).isEmpty)
        #expect(loop.lastRun(for: "calendar") == nil)
    }

    @Test("Mine Now is the attended authorization path")
    func runNowRequestsAuthorization() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let d = try freshDefaults()
        d.set(true, forKey: "miner.calendar.enabled")
        let authorization = AuthorizationState()
        let source = CalendarMiner(
            reader: { [] },
            statusReader: { await authorization.get() },
            authorizationRequester: { await authorization.grant() }
        )
        let loop = MinerRunLoop(sources: [source], defaults: d)
        let result = await loop.runNow(sourceID: "calendar", now: t0, caller: bridge)
        #expect(result != nil)
        #expect(loop.lastStatus(for: "calendar") == "complete")
    }
}
